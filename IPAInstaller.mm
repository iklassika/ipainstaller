//
//  IPAInstaller.mm
//  IPA Installer Library
//
//  Implementation of the embeddable IPA installation library. The logic was
//  extracted from the original ipainstaller console tool (main.mm).
//

#import "IPAInstaller.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#import "ZipArchive/ZipArchive.h"
#import "UIDevice-Capabilities/UIDevice-Capabilities.h"

NSString * const IPAInstallerVersion = @"3.4.1";
NSString * const IPAInstallerErrorDomain = @"IPAInstallerErrorDomain";

#define KEY_INSTALL_TYPE @"User"
#define KEY_SDKPATH "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation"

typedef int (*MobileInstallationInstall)(NSString *path, NSDictionary *dict, void *na, NSString *backpath);
typedef int (*MobileInstallationUninstall)(NSString *bundleID, NSDictionary *dict, void *na);

@interface LSApplicationWorkspace : NSObject
+ (LSApplicationWorkspace *)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)path withOptions:(NSDictionary *)options;
- (BOOL)uninstallApplication:(NSString *)identifier withOptions:(NSDictionary *)options;
- (BOOL)applicationIsInstalled:(NSString *)appIdentifier;
- (NSArray *)applicationsOfType:(unsigned int)appType; // 0 for user, 1 for system
@end

@interface LSApplicationProxy : NSObject
+ (LSApplicationProxy *)applicationProxyForIdentifier:(id)appIdentifier;
@property(readonly) NSString * applicationIdentifier;
@property(readonly) NSString * bundleVersion;
@property(readonly) NSString * bundleExecutable;
@property(readonly) NSArray * deviceFamily;
@property(readonly) NSURL * bundleContainerURL;
@property(readonly) NSString * bundleIdentifier;
@property(readonly) NSURL * bundleURL;
@property(readonly) NSURL * containerURL;
@property(readonly) NSURL * dataContainerURL;
@property(readonly) NSString * localizedShortName;
@property(readonly) NSString * localizedName;
@property(readonly) NSString * shortVersionString;
@end

static NSString *SystemVersion = nil;
static NSString *DeviceString = nil;
static int DeviceModel = 0;
static BOOL IPAInitialized = NO;

static void IPAInitialize(void) {
    if (IPAInitialized)
        return;
    IPAInitialized = YES;

    SystemVersion = [[UIDevice currentDevice].systemVersion copy];
    DeviceString = [[UIDevice currentDevice].model copy];

    if ([DeviceString isEqualToString:@"iPhone"] || [DeviceString isEqualToString:@"iPod touch"])
        DeviceModel = 1;
    else if ([DeviceString isEqualToString:@"iPad"])
        DeviceModel = 2;
    else
        DeviceModel = 3; // Apple TV maybe?
}

static void IPASetError(NSError **error, IPAInstallerErrorCode code, NSString *description) {
    if (error == NULL)
        return;
    NSDictionary *userInfo = description
        ? [NSDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey]
        : nil;
    *error = [NSError errorWithDomain:IPAInstallerErrorDomain code:code userInfo:userInfo];
}

static NSString *IPARandomString(NSUInteger len) {
    NSMutableString *ret = [NSMutableString stringWithCapacity:len];
    NSString *letters = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for (NSUInteger i = 0; i < len; i++)
        [ret appendFormat:@"%C", [letters characterAtIndex:arc4random() % [letters length]]];
    return ret;
}

static BOOL IPARemoveAllContentsUnderPath(NSString *path) {
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if ([fileMgr fileExistsAtPath:path isDirectory:&isDirectory]) {
        if (isDirectory) {
            NSArray *dirContents = [fileMgr contentsOfDirectoryAtPath:path error:nil];
            BOOL allRemoved = YES;
            for (NSString *file in dirContents) {
                if (![fileMgr removeItemAtPath:[path stringByAppendingPathComponent:file] error:nil])
                    allRemoved = NO;
            }
            if (!allRemoved)
                return NO;
            if (![fileMgr removeItemAtPath:path error:nil])
                return NO;
        }
    }
    return YES;
}

/** Apply the mobile:mobile 0755/0644 ownership and permissions used by the App Store. */
static void IPASetDirectoryOwnershipAndPermissions(NSString *dirPath) {
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    NSDictionary *directoryAttributes = [fileMgr attributesOfItemAtPath:dirPath error:nil];
    if (directoryAttributes == nil)
        return;

    NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithDictionary:directoryAttributes];
    [attributes setObject:[NSNumber numberWithInt:501] forKey:NSFileOwnerAccountID];
    [attributes setObject:@"mobile" forKey:NSFileOwnerAccountName];
    [attributes setObject:[NSNumber numberWithInt:501] forKey:NSFileGroupOwnerAccountID];
    [attributes setObject:@"mobile" forKey:NSFileGroupOwnerAccountName];
    [attributes setObject:[NSNumber numberWithShort:0755] forKey:NSFilePosixPermissions];
    [fileMgr setAttributes:attributes ofItemAtPath:dirPath error:nil];
}

static void IPASetPermissionsForPath(NSString *path) {
    NSFileManager *fileMgr = [NSFileManager defaultManager];

    IPASetDirectoryOwnershipAndPermissions(path);

    for (NSString *subPath in [fileMgr contentsOfDirectoryAtPath:path error:nil]) {
        NSString *fullPath = [path stringByAppendingPathComponent:subPath];
        NSDictionary *attributes = [fileMgr attributesOfItemAtPath:fullPath error:nil];
        NSString *fileType = [attributes objectForKey:NSFileType];

        if ([fileType isEqualToString:NSFileTypeRegular]) {
            NSMutableDictionary *newAttributes = [NSMutableDictionary dictionaryWithDictionary:attributes];
            [newAttributes setObject:[NSNumber numberWithInt:501] forKey:NSFileOwnerAccountID];
            [newAttributes setObject:@"mobile" forKey:NSFileOwnerAccountName];
            [newAttributes setObject:[NSNumber numberWithInt:501] forKey:NSFileGroupOwnerAccountID];
            [newAttributes setObject:@"mobile" forKey:NSFileGroupOwnerAccountName];
            [newAttributes setObject:[NSNumber numberWithShort:0644] forKey:NSFilePosixPermissions];
            [fileMgr setAttributes:newAttributes ofItemAtPath:fullPath error:nil];
        } else if ([fileType isEqualToString:NSFileTypeDirectory]) {
            IPASetPermissionsForPath(fullPath);
        }
        // Symbolic links are ignored.
    }
}

static void IPASetExecutables(NSString *dirPath) {
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fileMgr fileExistsAtPath:dirPath isDirectory:&isDir] || !isDir)
        return;

    NSString *infoPlistPath = [dirPath stringByAppendingPathComponent:@"Info.plist"];
    if ([fileMgr fileExistsAtPath:infoPlistPath]) {
        NSDictionary *infoDict = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
        NSString *exeName = [infoDict objectForKey:@"CFBundleExecutable"];
        if ([exeName length] > 0) {
            NSString *exePath = [dirPath stringByAppendingPathComponent:exeName];
            NSDictionary *attributes = [fileMgr attributesOfItemAtPath:exePath error:nil];
            if ([[attributes objectForKey:NSFileType] isEqualToString:NSFileTypeRegular]) {
                NSMutableDictionary *executableAttributes = [NSMutableDictionary dictionaryWithDictionary:attributes];
                [executableAttributes setObject:[NSNumber numberWithShort:0755] forKey:NSFilePosixPermissions];
                [fileMgr setAttributes:executableAttributes ofItemAtPath:exePath error:nil];
            }
        }
    }

    for (NSString *subPath in [fileMgr contentsOfDirectoryAtPath:dirPath error:nil]) {
        NSString *subDirPath = [dirPath stringByAppendingPathComponent:subPath];
        NSDictionary *attributes = [fileMgr attributesOfItemAtPath:subDirPath error:nil];
        if ([[attributes objectForKey:NSFileType] isEqualToString:NSFileTypeDirectory])
            IPASetExecutables(subDirPath);
    }
}

static int IPAVersionCompare(NSString *ver1, NSString *ver2) {
    // -1: ver1 < ver2; 0: ver1 == ver2; 1: ver1 > ver2
    BOOL isEmpty1 = (ver1 == nil || [ver1 length] == 0);
    BOOL isEmpty2 = (ver2 == nil || [ver2 length] == 0);
    if (isEmpty1 && isEmpty2)
        return 0;
    else if (isEmpty1 && !isEmpty2)
        return -1;
    else if (!isEmpty1 && isEmpty2)
        return 1;

    NSArray *components1 = [ver1 componentsSeparatedByString:@"."];
    NSArray *components2 = [ver2 componentsSeparatedByString:@"."];
    NSUInteger count = MIN([components1 count], [components2 count]);

    for (NSUInteger i = 0; i < count; i++) {
        int num1 = [[components1 objectAtIndex:i] intValue];
        int num2 = [[components2 objectAtIndex:i] intValue];
        if (num1 < num2)
            return -1;
        else if (num1 > num2)
            return 1;

        NSString *part1 = [components1 objectAtIndex:i];
        NSString *part2 = [components2 objectAtIndex:i];
        if (![part1 isEqualToString:part2])
            return [part1 compare:part2] == NSOrderedDescending ? 1 : -1;
    }

    if ([components1 count] != [components2 count])
        return [components1 count] > [components2 count] ? 1 : -1;
    return 0;
}

static NSString *IPAFormatDictValue(id object) {
    return object ? (NSString *)object : @"";
}

static NSString *IPAGetBestString(NSString *main, NSString *minor) {
    return (minor && [minor length] > 0) ? minor : (main ? main : @"");
}

static int IPAInstallApp(NSString *ipaPath, NSString *ipaId) {
    int ret = -1;
    if (kCFCoreFoundationVersionNumber < 1140.10) {
        void *lib = dlopen(KEY_SDKPATH, RTLD_LAZY);
        if (lib) {
            MobileInstallationInstall install = (MobileInstallationInstall)dlsym(lib, "MobileInstallationInstall");
            if (install)
                ret = install(ipaPath, [NSDictionary dictionaryWithObject:KEY_INSTALL_TYPE forKey:@"ApplicationType"], 0, ipaPath);
            dlclose(lib);
        }
    } else {
        Class workspaceClass = objc_getClass("LSApplicationWorkspace");
        if (workspaceClass) {
            LSApplicationWorkspace *workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
            if (workspace &&
                [workspace installApplication:[NSURL fileURLWithPath:ipaPath]
                                  withOptions:[NSDictionary dictionaryWithObject:ipaId forKey:@"CFBundleIdentifier"]])
                ret = 0;
        }
    }
    return ret;
}

static BOOL IPAUninstallApp(NSString *appIdentifier) {
    if (kCFCoreFoundationVersionNumber < 1140.10) {
        void *lib = dlopen(KEY_SDKPATH, RTLD_LAZY);
        if (lib) {
            MobileInstallationUninstall uninstall = (MobileInstallationUninstall)dlsym(lib, "MobileInstallationUninstall");
            if (uninstall) {
                BOOL result = (0 == uninstall(appIdentifier, nil, nil));
                dlclose(lib);
                return result;
            }
            dlclose(lib);
        }
    } else {
        Class workspaceClass = objc_getClass("LSApplicationWorkspace");
        if (workspaceClass) {
            LSApplicationWorkspace *workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
            if (workspace && [workspace uninstallApplication:appIdentifier withOptions:nil])
                return YES;
        }
    }
    return NO;
}

#pragma mark - IPAInstallerOptions

@implementation IPAInstallerOptions

- (id)init {
    self = [super init];
    if (self) {
        _cleanInstall = NO;
        _force = NO;
        _restoreDocuments = YES;
        _removeiTunesMetadata = NO;
        _deleteIPAAfterInstall = NO;
        _suppressProgress = NO;
        _silent = NO;
    }
    return self;
}

+ (IPAInstallerOptions *)defaultOptions {
    return [[[self alloc] init] autorelease];
}

@end

#pragma mark - IPAInstaller

@interface IPAInstaller ()
- (void)_log:(NSString *)message level:(IPAInstallerLogLevel)level options:(IPAInstallerOptions *)options;
- (NSString *)_uniquePathInDirectory:(NSString *)directory suffix:(NSString *)suffix;
- (NSString *)_createWorkPathAndReturnError:(NSError **)error options:(IPAInstallerOptions *)options;
- (void)_cleanStaleWorkDirectories;
@end

@implementation IPAInstaller

+ (void)initialize {
    if (self == [IPAInstaller class])
        IPAInitialize();
}

+ (IPAInstaller *)sharedInstaller {
    static IPAInstaller *shared = nil;
    if (shared == nil)
        shared = [[self alloc] init];
    return shared;
}

- (id)init {
    self = [super init];
    if (self) {
        IPAInitialize();
        _delegate = nil;
    }
    return self;
}

- (void)dealloc {
    _delegate = nil;
    [super dealloc];
}

#pragma mark Logging

- (void)_log:(NSString *)message level:(IPAInstallerLogLevel)level options:(IPAInstallerOptions *)options {
    NSInteger verbosity = 0;
    if (options.silent)
        verbosity = 2;
    else if (options.suppressProgress)
        verbosity = 1;
    if (verbosity >= 2)
        return;
    if (verbosity == 1 && level == IPAInstallerLogLevelInfo)
        return;

    if ([_delegate respondsToSelector:@selector(installer:didLogMessage:level:)]) {
        [_delegate installer:self didLogMessage:message level:level];
    } else if (level != IPAInstallerLogLevelInfo) {
        NSLog(@"%@", message);
    }
}

#pragma mark Filesystem helpers

- (void)_cleanStaleWorkDirectories {
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    NSString *tempDirectory = NSTemporaryDirectory();
    for (NSString *file in [fileMgr contentsOfDirectoryAtPath:tempDirectory error:nil]) {
        NSString *path = [tempDirectory stringByAppendingPathComponent:[file lastPathComponent]];
        if ([[path lastPathComponent] hasPrefix:@"com.autopear.ipainstaller."])
            [fileMgr removeItemAtPath:path error:nil];
    }
}

- (NSString *)_uniquePathInDirectory:(NSString *)directory suffix:(NSString *)suffix {
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    while (YES) {
        NSString *name = [NSString stringWithFormat:@"com.autopear.ipainstaller.%@%@", IPARandomString(6), suffix];
        NSString *path = [directory stringByAppendingPathComponent:name];
        if (![fileMgr fileExistsAtPath:path])
            return path;
    }
}

- (NSString *)_createWorkPathAndReturnError:(NSError **)error options:(IPAInstallerOptions *)options {
    [self _cleanStaleWorkDirectories];
    NSString *workPath = [self _uniquePathInDirectory:NSTemporaryDirectory() suffix:@""];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:workPath
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:NULL]) {
        [self _log:@"Failed to create workspace." level:IPAInstallerLogLevelError options:options];
        IPASetError(error, IPAInstallerErrorOperationFailed, @"Failed to create workspace.");
        return nil;
    }
    return workPath;
}

#pragma mark Installed application queries

- (NSArray *)installedApplicationIdentifiers {
    IPAInitialize();
    if (kCFCoreFoundationVersionNumber < 1140.10) {
        NSDictionary *mobileInstallationPlist = [NSDictionary dictionaryWithContentsOfFile:@"/private/var/mobile/Library/Caches/com.apple.mobile.installation.plist"];
        NSDictionary *installedAppDict = [mobileInstallationPlist objectForKey:@"User"];
        NSArray *identifiers = [[installedAppDict allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        return identifiers;
    }

    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    if (workspaceClass) {
        LSApplicationWorkspace *workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
        if (workspace) {
            NSArray *allApps = [workspace applicationsOfType:0];
            NSMutableArray *identifiers = [NSMutableArray arrayWithCapacity:[allApps count]];
            for (LSApplicationProxy *appBundle in allApps) {
                if (appBundle.bundleIdentifier)
                    [identifiers addObject:appBundle.bundleIdentifier];
            }
            return [identifiers sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        }
    }
    return nil;
}

- (NSDictionary *)infoForApplicationWithIdentifier:(NSString *)identifier {
    IPAInitialize();
    if ([identifier length] == 0)
        return nil;

    if (kCFCoreFoundationVersionNumber < 1140.10) {
        NSDictionary *mobileInstallationPlist = [NSDictionary dictionaryWithContentsOfFile:@"/private/var/mobile/Library/Caches/com.apple.mobile.installation.plist"];
        NSDictionary *installedAppDict = [mobileInstallationPlist objectForKey:@"User"];
        NSDictionary *appInfo = [installedAppDict objectForKey:identifier];
        if (appInfo) {
            NSMutableDictionary *info = [NSMutableDictionary dictionaryWithCapacity:8];
            [info setObject:IPAFormatDictValue([appInfo objectForKey:@"CFBundleIdentifier"]) forKey:@"APP_ID"];
            [info setObject:IPAFormatDictValue([appInfo objectForKey:@"Container"]) forKey:@"BUNDLE_PATH"];
            [info setObject:IPAFormatDictValue([appInfo objectForKey:@"Path"]) forKey:@"APP_PATH"];
            [info setObject:IPAFormatDictValue([appInfo objectForKey:@"Container"]) forKey:@"DATA_PATH"];
            [info setObject:IPAFormatDictValue([appInfo objectForKey:@"CFBundleVersion"]) forKey:@"VERSION"];
            [info setObject:IPAFormatDictValue([appInfo objectForKey:@"CFBundleShortVersionString"]) forKey:@"SHORT_VERSION"];
            [info setObject:IPAFormatDictValue([appInfo objectForKey:@"CFBundleName"]) forKey:@"NAME"];
            [info setObject:IPAFormatDictValue([appInfo objectForKey:@"CFBundleDisplayName"]) forKey:@"DISPLAY_NAME"];
            return info;
        }
    } else {
        Class workspaceClass = objc_getClass("LSApplicationWorkspace");
        if (workspaceClass) {
            LSApplicationWorkspace *workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
            if (workspace && [workspace applicationIsInstalled:identifier]) {
                Class proxyClass = objc_getClass("LSApplicationProxy");
                if (proxyClass) {
                    LSApplicationProxy *app = [proxyClass performSelector:@selector(applicationProxyForIdentifier:) withObject:identifier];
                    if (app) {
                        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithCapacity:9];
                        [info setObject:IPAFormatDictValue(app.bundleIdentifier) forKey:@"APP_ID"];
                        [info setObject:IPAFormatDictValue([app.bundleContainerURL path]) forKey:@"BUNDLE_PATH"];
                        [info setObject:IPAFormatDictValue([app.bundleURL path]) forKey:@"APP_PATH"];
                        [info setObject:IPAFormatDictValue([app.dataContainerURL path]) forKey:@"DATA_PATH"];
                        [info setObject:IPAFormatDictValue(app.bundleVersion) forKey:@"VERSION"];
                        [info setObject:IPAFormatDictValue(app.shortVersionString) forKey:@"SHORT_VERSION"];
                        [info setObject:IPAFormatDictValue(app.localizedName) forKey:@"NAME"];
                        [info setObject:IPAFormatDictValue(app.localizedShortName) forKey:@"DISPLAY_NAME"];
                        return info;
                    }
                }
            }
        }
    }
    return nil;
}

#pragma mark Uninstall

- (BOOL)uninstallApplicationWithIdentifier:(NSString *)identifier error:(NSError **)error {
    IPAInitialize();
    if (error)
        *error = nil;

    if ([identifier length] == 0) {
        IPASetError(error, IPAInstallerErrorInvalidParameters, @"You must specify an application identifier.");
        return NO;
    }

    NSArray *installedApps = [self installedApplicationIdentifiers];
    if (![installedApps containsObject:identifier]) {
        [self _log:[NSString stringWithFormat:@"Application \"%@\" is not installed.", identifier]
             level:IPAInstallerLogLevelWarning
           options:nil];
        IPASetError(error, IPAInstallerErrorApplicationNotFound,
                    [NSString stringWithFormat:@"Application \"%@\" is not installed.", identifier]);
        return NO;
    }

    [self _log:[NSString stringWithFormat:@"Removing application \"%@\".", identifier]
         level:IPAInstallerLogLevelInfo
       options:nil];
    if (IPAUninstallApp(identifier)) {
        [self _log:[NSString stringWithFormat:@"Successfully removed application \"%@\".", identifier]
             level:IPAInstallerLogLevelInfo
           options:nil];
        return YES;
    }

    NSString *message = [NSString stringWithFormat:@"Failed to remove application \"%@\".", identifier];
    [self _log:message level:IPAInstallerLogLevelError options:nil];
    IPASetError(error, IPAInstallerErrorOperationFailed, message);
    return NO;
}

#pragma mark Install

- (BOOL)installIPAAtPath:(NSString *)path options:(IPAInstallerOptions *)options error:(NSError **)error {
    return ([self installIPAsAtPaths:[NSArray arrayWithObject:path] options:options error:error] == 1);
}

- (NSInteger)installIPAsAtPaths:(NSArray *)paths options:(IPAInstallerOptions *)options error:(NSError **)error {
    IPAInitialize();
    if (error)
        *error = nil;

    if ([paths count] == 0) {
        IPASetError(error, IPAInstallerErrorInvalidParameters, @"No IPA files were specified.");
        return 0;
    }
    if (options == nil)
        options = [IPAInstallerOptions defaultOptions];

    NSFileManager *fileMgr = [NSFileManager defaultManager];
    NSMutableArray *ipaFiles = [NSMutableArray arrayWithCapacity:[paths count]];

    for (id item in paths) {
        NSString *arg = nil;
        if ([item isKindOfClass:[NSString class]])
            arg = (NSString *)item;
        else if ([item isKindOfClass:[NSURL class]])
            arg = [(NSURL *)item path];
        if ([arg length] == 0)
            continue;

        NSURL *url = [NSURL fileURLWithPath:arg isDirectory:NO];
        NSString *resolvedPath = [[url absoluteURL] path];
        BOOL isDirectory = NO;
        if ([fileMgr fileExistsAtPath:resolvedPath isDirectory:&isDirectory] && !isDirectory) {
            [ipaFiles addObject:resolvedPath];
        } else {
            [self _log:[NSString stringWithFormat:@"File not found at path: %@.", resolvedPath]
                 level:IPAInstallerLogLevelError
               options:options];
        }
    }

    if ([ipaFiles count] == 0) {
        IPASetError(error, IPAInstallerErrorFileNotFound, @"Please specify any IPA file(s) to install.");
        return 0;
    }

    BOOL clean = options.cleanInstall;
    BOOL force = options.force;
    BOOL notRestore = (!options.restoreDocuments || clean);
    BOOL removeMetadata = options.removeiTunesMetadata;
    BOOL deleteFile = options.deleteIPAAfterInstall;

    if (clean)
        notRestore = YES;

    if (!options.suppressProgress && !options.silent) {
        if (clean)
            [self _log:@"Clean installation enabled." level:IPAInstallerLogLevelInfo options:options];
        if (force)
            [self _log:@"Force installation enabled." level:IPAInstallerLogLevelInfo options:options];
        if (notRestore)
            [self _log:@"Will not restore any saved documents and other resources." level:IPAInstallerLogLevelInfo options:options];
        if (removeMetadata)
            [self _log:@"iTunesMetadata.plist will be removed after installation." level:IPAInstallerLogLevelInfo options:options];
        if (deleteFile)
            [self _log:@"IPA files will be deleted after installation." level:IPAInstallerLogLevelInfo options:options];
    }

    NSString *workPath = [self _createWorkPathAndReturnError:error options:options];
    if (workPath == nil)
        return 0;
    NSString *installPath = [workPath stringByAppendingPathComponent:@"tmp.install.ipa"];

    NSInteger successfulInstalls = 0;
    NSUInteger total = [ipaFiles count];

    for (NSUInteger i = 0; i < total; i++) {
        if (!IPARemoveAllContentsUnderPath(workPath)) {
            [self _log:@"Failed to create workspace." level:IPAInstallerLogLevelError options:options];
            IPASetError(error, IPAInstallerErrorOperationFailed, @"Failed to create workspace.");
            return successfulInstalls;
        }

        NSString *ipa = [ipaFiles objectAtIndex:i];
        [self _log:[NSString stringWithFormat:@"Analyzing %@...", [ipa lastPathComponent]]
             level:IPAInstallerLogLevelInfo
           options:options];

        BOOL isValidIPA = YES;
        BOOL hasContainer = NO;
        NSString *pathInfoPlist = [self _uniquePathInDirectory:workPath suffix:@".Info.plist"];
        NSString *infoPath = nil;

        ZipArchive *ipaArchive = [[ZipArchive alloc] init];
        if ([ipaArchive unzipOpenFile:ipa]) {
            NSMutableArray *array = [ipaArchive getZipFileContents];
            NSMutableArray *infoStrings = [NSMutableArray array];
            NSString *appPathName = nil;
            int cnt = 0;

            for (NSString *name in array) {
                NSArray *components = [name pathComponents];
                if ([components count] > 1 && [[components objectAtIndex:0] isEqualToString:@"Container"]) {
                    hasContainer = YES;
                } else {
                    if ([components count] == 3 &&
                        [[components objectAtIndex:0] isEqualToString:@"Payload"] &&
                        [[components objectAtIndex:1] hasSuffix:@".app"] &&
                        [[components objectAtIndex:2] isEqualToString:@"Info.plist"]) {
                        appPathName = [@"Payload" stringByAppendingPathComponent:[components objectAtIndex:1]];
                        infoPath = name;
                        cnt++;
                    }
                    if ([components count] == 4 &&
                        [[components objectAtIndex:0] isEqualToString:@"Payload"] &&
                        [[components objectAtIndex:1] hasSuffix:@".app"] &&
                        [[components objectAtIndex:2] hasSuffix:@".lproj"] &&
                        [[components objectAtIndex:3] isEqualToString:@"InfoPlist.strings"]) {
                        [infoStrings addObject:[components objectAtIndex:2]];
                    }
                }
            }
            if (cnt != 1)
                isValidIPA = NO;

            if (isValidIPA) {
                [ipaArchive unzipFileWithName:infoPath toPath:pathInfoPlist overwrite:YES];

                for (NSString *lproj in infoStrings) {
                    NSString *lprojPath = [[workPath stringByAppendingPathComponent:@"localizations"] stringByAppendingPathComponent:lproj];
                    if ([fileMgr createDirectoryAtPath:lprojPath withIntermediateDirectories:YES attributes:nil error:NULL]) {
                        NSString *stringsPath = [[appPathName stringByAppendingPathComponent:lproj] stringByAppendingPathComponent:@"InfoPlist.strings"];
                        [ipaArchive unzipFileWithName:stringsPath
                                              toPath:[lprojPath stringByAppendingPathComponent:@"InfoPlist.strings"]
                                           overwrite:YES];
                    }
                }
            }
            [ipaArchive unzipCloseFile];
        } else {
            isValidIPA = NO;
        }
        [ipaArchive release];

        if (!isValidIPA) {
            [self _log:[NSString stringWithFormat:@"%@ is not a valid IPA.", ipa]
                 level:IPAInstallerLogLevelError
               options:options];
            IPARemoveAllContentsUnderPath(workPath);
            continue;
        }

        NSMutableDictionary *infoDict = [NSMutableDictionary dictionaryWithContentsOfFile:pathInfoPlist];
        if (infoDict == nil) {
            [self _log:[NSString stringWithFormat:@"%@ is not a valid IPA.", ipa]
                 level:IPAInstallerLogLevelError
               options:options];
            IPARemoveAllContentsUnderPath(workPath);
            continue;
        }

        NSString *appIdentifier = [infoDict objectForKey:@"CFBundleIdentifier"];
        NSString *appVersion = [infoDict objectForKey:@"CFBundleVersion"];
        NSString *appShortVersion = [infoDict objectForKey:@"CFBundleShortVersionString"];
        NSString *minSysVersion = [infoDict objectForKey:@"MinimumOSVersion"];
        id rawDevices = [infoDict objectForKey:@"UIDeviceFamily"];
        NSMutableArray *supportedDevices = [rawDevices isKindOfClass:[NSArray class]]
            ? [NSMutableArray arrayWithArray:rawDevices]
            : [NSMutableArray array];

        id requiredCapabilities = [infoDict objectForKey:@"UIRequiredDeviceCapabilities"];

        NSString *appDisplayName = [infoDict objectForKey:@"CFBundleDisplayName"]
            ? [infoDict objectForKey:@"CFBundleDisplayName"]
            : [infoDict objectForKey:@"CFBundleName"];

        // Obtain localized display name.
        BOOL isDirectory = NO;
        NSString *localizationsPath = [workPath stringByAppendingPathComponent:@"localizations"];
        if ([fileMgr fileExistsAtPath:localizationsPath isDirectory:&isDirectory] && isDirectory) {
            NSBundle *localizedBundle = [NSBundle bundleWithPath:localizationsPath];
            NSString *localizedName = [localizedBundle localizedStringForKey:@"CFBundleDisplayName" value:nil table:@"InfoPlist"];
            if (localizedName)
                appDisplayName = [localizedBundle localizedStringForKey:@"CFBundleDisplayName" value:appDisplayName table:@"InfoPlist"];
            else
                appDisplayName = [localizedBundle localizedStringForKey:@"CFBundleName" value:appDisplayName table:@"InfoPlist"];
            [fileMgr removeItemAtPath:localizationsPath error:nil];
        }

        if (!appIdentifier || !appDisplayName || !appVersion) {
            [self _log:[NSString stringWithFormat:@"%@ is not a valid IPA.", ipa]
                 level:IPAInstallerLogLevelError
               options:options];
            IPARemoveAllContentsUnderPath(workPath);
            continue;
        }

        // Make a copy of the extracted Info.plist (used to restore it after a forced install).
        NSString *pathOriginalInfoPlist = [NSString stringWithFormat:@"%@.original", pathInfoPlist];
        if ([fileMgr fileExistsAtPath:pathOriginalInfoPlist]) {
            if (![fileMgr removeItemAtPath:pathOriginalInfoPlist error:nil] &&
                ![fileMgr copyItemAtPath:pathInfoPlist toPath:pathOriginalInfoPlist error:nil]) {
                if (force)
                    [self _log:@"Force installation has to be disabled." level:IPAInstallerLogLevelWarning options:options];
                force = NO;
            }
        } else if (![fileMgr copyItemAtPath:pathInfoPlist toPath:pathOriginalInfoPlist error:nil]) {
            if (force)
                [self _log:@"Force installation has to be disabled." level:IPAInstallerLogLevelWarning options:options];
            force = NO;
        }

        // Check installed state.
        NSDictionary *installedAppInfo = [self infoForApplicationWithIdentifier:appIdentifier];
        BOOL appAlreadyInstalled = (installedAppInfo != nil);
        if (appAlreadyInstalled) {
            NSString *installedVersion = [installedAppInfo objectForKey:@"VERSION"];
            NSString *installedShortVersion = [installedAppInfo objectForKey:@"SHORT_VERSION"];
            BOOL downgrade = NO;

            if (installedShortVersion != nil && appShortVersion != nil)
                downgrade = (IPAVersionCompare(installedShortVersion, appShortVersion) == 1);
            else
                downgrade = (IPAVersionCompare(installedVersion, appVersion) == 1);

            if (downgrade) {
                NSString *installedVer = (installedShortVersion != nil && appShortVersion != nil) ? installedShortVersion : installedVersion;
                if (force) {
                    [self _log:[NSString stringWithFormat:@"%@ (v%@) is already installed. Will force to downgrade.", appDisplayName, installedVer]
                         level:IPAInstallerLogLevelInfo
                       options:options];
                } else {
                    [self _log:[NSString stringWithFormat:@"%@ (v%@) is already installed. You may use force option to force downgrade.", appDisplayName, installedVer]
                         level:IPAInstallerLogLevelWarning
                       options:options];
                    IPARemoveAllContentsUnderPath(workPath);
                    continue;
                }
            }
        }

        BOOL shouldUpdateInfoPlist = NO;

        // Check device family.
        BOOL supportiPhone = NO;
        BOOL supportiPad = NO;
        BOOL supportAppleTV = NO;
        if ([supportedDevices count] == 0) {
            supportiPhone = YES;
            supportiPad = YES;
            supportAppleTV = YES;
        } else {
            for (NSNumber *device in supportedDevices) {
                int d = [device intValue];
                if (d == 1) {
                    supportiPhone = YES;
                    supportiPad = YES;
                }
                if (d == 2)
                    supportiPad = YES;
                if (d == 3)
                    supportAppleTV = YES;
            }
        }

        NSString *supportedDevicesString = nil;
        if (!supportiPhone && supportiPad && !supportAppleTV)
            supportedDevicesString = @"iPad";
        else if (!supportiPhone && !supportiPad && supportAppleTV)
            supportedDevicesString = @"Apple TV";
        else if (supportiPhone && supportiPad && !supportAppleTV)
            supportedDevicesString = @"iPhone, iPod touch or iPad";
        else if (supportiPhone && !supportiPad && supportAppleTV)
            supportedDevicesString = @"iPhone, iPod touch or Apple TV";
        else if (!supportiPhone && supportiPad && supportAppleTV)
            supportedDevicesString = @"iPad or Apple TV";
        else if (supportiPhone && !supportiPad && !supportAppleTV)
            supportedDevicesString = @"iPhone or iPod touch";
        else
            supportedDevicesString = @"iPhone, iPod touch, iPad or Apple TV";

        if ((DeviceModel == 1 && !supportiPhone) ||
            (DeviceModel == 2 && !supportiPad) ||
            (DeviceModel == 3 && !supportAppleTV)) {
            NSString *version = appShortVersion ? appShortVersion : appVersion;
            NSString *message = [NSString stringWithFormat:@"%@ (v%@) requires %@ while your device is %@.",
                                 appDisplayName, version, supportedDevicesString, DeviceString];
            if (force) {
                [self _log:message level:IPAInstallerLogLevelInfo options:options];
                [supportedDevices addObject:[NSNumber numberWithInt:DeviceModel]];
                [infoDict setObject:[supportedDevices sortedArrayUsingSelector:@selector(compare:)] forKey:@"UIDeviceFamily"];
                shouldUpdateInfoPlist = YES;
            } else {
                [self _log:message level:IPAInstallerLogLevelWarning options:options];
                IPARemoveAllContentsUnderPath(workPath);
                continue;
            }
        }

        // Check minimum system requirement.
        if (minSysVersion && IPAVersionCompare(minSysVersion, SystemVersion) == 1) {
            NSString *version = appShortVersion ? appShortVersion : appVersion;
            NSString *message = [NSString stringWithFormat:@"%@ (v%@) requires iOS %@ while your system is %@.",
                                 appDisplayName, version, minSysVersion, SystemVersion];
            if (force) {
                [self _log:message level:IPAInstallerLogLevelInfo options:options];
                [infoDict setObject:SystemVersion forKey:@"MinimumOSVersion"];
                shouldUpdateInfoPlist = YES;
            } else {
                [self _log:message level:IPAInstallerLogLevelWarning options:options];
                IPARemoveAllContentsUnderPath(workPath);
                continue;
            }
        }

        // Check capabilities.
        if (requiredCapabilities) {
            BOOL isCapable = YES;
            if ([requiredCapabilities isKindOfClass:[NSArray class]]) {
                NSMutableArray *newCapabilities = [NSMutableArray arrayWithCapacity:0];
                for (NSString *capability in (NSArray *)requiredCapabilities) {
                    if ([[UIDevice currentDevice] supportsCapability:capability]) {
                        [newCapabilities addObject:capability];
                    } else {
                        isCapable = NO;
                        [self _log:[NSString stringWithFormat:@"Your device does not support %@ capability.", capability]
                             level:force ? IPAInstallerLogLevelInfo : IPAInstallerLogLevelWarning
                           options:options];
                        if (force)
                            shouldUpdateInfoPlist = YES;
                    }
                }
                if (!isCapable) {
                    if (force)
                        [infoDict setObject:[newCapabilities sortedArrayUsingSelector:@selector(compare:)] forKey:@"UIRequiredDeviceCapabilities"];
                    else {
                        IPARemoveAllContentsUnderPath(workPath);
                        continue;
                    }
                }
            } else if ([requiredCapabilities isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *newCapabilities = [NSMutableDictionary dictionaryWithCapacity:0];
                for (NSString *capabilityKey in [(NSDictionary *)requiredCapabilities allKeys]) {
                    BOOL capabilityValue = [[(NSDictionary *)requiredCapabilities objectForKey:capabilityKey] boolValue];
                    if (capabilityValue == [[UIDevice currentDevice] supportsCapability:capabilityKey]) {
                        [newCapabilities setObject:[NSNumber numberWithBool:!capabilityValue] forKey:capabilityKey];
                    } else {
                        isCapable = NO;
                        NSString *message = capabilityValue
                            ? [NSString stringWithFormat:@"Your device does not support %@ capability.", capabilityKey]
                            : [NSString stringWithFormat:@"Your device conflicts with %@ capability.", capabilityKey];
                        [self _log:message level:force ? IPAInstallerLogLevelInfo : IPAInstallerLogLevelWarning options:options];
                        if (force)
                            shouldUpdateInfoPlist = YES;
                    }
                }
                if (!isCapable) {
                    if (force)
                        [infoDict setObject:newCapabilities forKey:@"UIRequiredDeviceCapabilities"];
                    else {
                        IPARemoveAllContentsUnderPath(workPath);
                        continue;
                    }
                }
            }
        }

        if (shouldUpdateInfoPlist && ![infoDict writeToFile:pathInfoPlist atomically:YES]) {
            NSString *version = appShortVersion ? appShortVersion : appVersion;
            [self _log:[NSString stringWithFormat:@"Failed to use force installation mode, %@ (v%@) will not be installed.", appDisplayName, version]
                 level:IPAInstallerLogLevelError
               options:options];
            IPARemoveAllContentsUnderPath(workPath);
            continue;
        }

        // Copy file to install.
        if ([fileMgr fileExistsAtPath:installPath] && ![fileMgr removeItemAtPath:installPath error:nil]) {
            [self _log:@"Failed to delete temporary file." level:IPAInstallerLogLevelError options:options];
            IPASetError(error, IPAInstallerErrorOperationFailed, @"Failed to delete temporary file.");
            [fileMgr removeItemAtPath:workPath error:nil];
            return successfulInstalls;
        }
        if (![fileMgr copyItemAtPath:ipa toPath:installPath error:nil]) {
            [self _log:@"Failed to create temporary files." level:IPAInstallerLogLevelError options:options];
            IPASetError(error, IPAInstallerErrorOperationFailed, @"Failed to create temporary files.");
            [fileMgr removeItemAtPath:workPath error:nil];
            return successfulInstalls;
        }

        // Modify the IPA to force install.
        if (shouldUpdateInfoPlist) {
            BOOL shouldContinue = NO;
            ZipArchive *tmpArchive = [[ZipArchive alloc] init];
            if ([tmpArchive openZipFile2:installPath withZipModel:APPEND_STATUS_ADDINZIP] &&
                ![tmpArchive addFileToZip:pathInfoPlist newname:infoPath]) {
                NSString *version = appShortVersion ? appShortVersion : appVersion;
                [self _log:[NSString stringWithFormat:@"Failed to use force installation mode, %@ (v%@) will not be installed.", appDisplayName, version]
                     level:IPAInstallerLogLevelError
                   options:options];
                [fileMgr removeItemAtPath:installPath error:nil];
                shouldContinue = YES;
            }
            [tmpArchive release];
            [fileMgr removeItemAtPath:pathInfoPlist error:nil];

            if (shouldContinue) {
                IPARemoveAllContentsUnderPath(workPath);
                continue;
            }
        }

        NSString *version = appShortVersion ? appShortVersion : appVersion;
        [self _log:[NSString stringWithFormat:@"%@nstalling %@ (v%@)...", shouldUpdateInfoPlist ? @"Force i" : @"I", appDisplayName, version]
             level:IPAInstallerLogLevelInfo
           options:options];

        IPASetPermissionsForPath(workPath);

        int ret = IPAInstallApp(installPath, appIdentifier);
        if (ret == 0) {
            NSDictionary *installedAppDict = [self infoForApplicationWithIdentifier:appIdentifier];
            if (installedAppDict) {
                NSString *installedVersion = [installedAppDict objectForKey:@"VERSION"];
                NSString *installedShortVersion = [installedAppDict objectForKey:@"SHORT_VERSION"];
                NSString *installedAppLocation = [installedAppDict objectForKey:@"BUNDLE_PATH"];
                NSString *installedDataLocation = [installedAppDict objectForKey:@"DATA_PATH"];
                NSString *appDirPath = [installedAppDict objectForKey:@"APP_PATH"];

                BOOL appInstalled = YES;
                if (appInstalled && IPAVersionCompare(installedVersion, appVersion) != 0)
                    appInstalled = NO;
                if (appInstalled && IPAVersionCompare(installedShortVersion, appShortVersion) != 0)
                    appInstalled = NO;

                if (appInstalled) {
                    // Recover the original Info.plist in force installation.
                    if (shouldUpdateInfoPlist) {
                        NSArray *infoComponents = [infoPath pathComponents];
                        if ([infoComponents count] > 1) {
                            NSString *installedInfoPlist = [NSString stringWithFormat:@"%@/%@/Info.plist", installedAppLocation, [infoComponents objectAtIndex:1]];
                            BOOL isDir = NO;
                            if ([fileMgr fileExistsAtPath:installedInfoPlist isDirectory:&isDir] && !isDir) {
                                if ([fileMgr removeItemAtPath:installedInfoPlist error:nil]) {
                                    if ([fileMgr moveItemAtPath:pathOriginalInfoPlist toPath:installedInfoPlist error:nil] &&
                                        [fileMgr fileExistsAtPath:pathOriginalInfoPlist])
                                        [fileMgr removeItemAtPath:pathOriginalInfoPlist error:nil];
                                }
                            }
                        }
                    }

                    successfulInstalls++;
                    [self _log:[NSString stringWithFormat:@"%@nstalled %@ (v%@) successfully%@.",
                                shouldUpdateInfoPlist ? @"Force i" : @"I",
                                appDisplayName,
                                version,
                                shouldUpdateInfoPlist ? @", but it may not work properly" : @""]
                         level:IPAInstallerLogLevelInfo
                       options:options];

                    BOOL tempEnableClean = NO;
                    if (!clean && hasContainer && !notRestore) {
                        tempEnableClean = YES;
                        clean = YES;
                    }

                    // Clear documents, etc.
                    if (appAlreadyInstalled && clean) {
                        [self _log:[NSString stringWithFormat:@"Cleaning old contents of %@...", appDisplayName]
                             level:IPAInstallerLogLevelInfo
                           options:options];

                        BOOL allContentsCleaned = YES;
                        NSArray *dataContents = [fileMgr contentsOfDirectoryAtPath:installedDataLocation error:nil];
                        for (NSString *file in dataContents) {
                            if ([file hasSuffix:@".app"] ||
                                [file isEqualToString:@".com.apple.mobile_container_manager.metadata.plist"] ||
                                [file isEqualToString:@".com.apple.mobileinstallation.placeholder"] ||
                                [file isEqualToString:@"iTunesArtwork"] ||
                                [file isEqualToString:@"iTunesMetadata.plist"])
                                continue;

                            if ([file isEqualToString:@"Library"]) {
                                NSString *dirLibrary = [installedDataLocation stringByAppendingPathComponent:@"Library"];
                                NSString *dirPreferences = [dirLibrary stringByAppendingPathComponent:@"Preferences"];
                                NSString *dirCaches = [dirLibrary stringByAppendingPathComponent:@"Caches"];

                                for (NSString *fileName in [fileMgr contentsOfDirectoryAtPath:dirLibrary error:nil]) {
                                    if ([fileName isEqualToString:@"Preferences"]) {
                                        for (NSString *preferenceFile in [fileMgr contentsOfDirectoryAtPath:dirPreferences error:nil]) {
                                            if (![preferenceFile isEqualToString:@".GlobalPreferences.plist"] &&
                                                ![preferenceFile isEqualToString:@"com.apple.PeoplePicker.plist"]) {
                                                if (![fileMgr removeItemAtPath:[dirPreferences stringByAppendingPathComponent:preferenceFile] error:nil])
                                                    allContentsCleaned = NO;
                                            }
                                        }
                                    } else if ([fileName isEqualToString:@"Caches"]) {
                                        for (NSString *cacheFile in [fileMgr contentsOfDirectoryAtPath:dirCaches error:nil]) {
                                            if (![fileMgr removeItemAtPath:[dirCaches stringByAppendingPathComponent:cacheFile] error:nil])
                                                allContentsCleaned = NO;
                                        }
                                    } else {
                                        if (![fileMgr removeItemAtPath:[dirLibrary stringByAppendingPathComponent:fileName] error:nil])
                                            allContentsCleaned = NO;
                                    }
                                }
                            } else {
                                NSString *sourcePath = [installedDataLocation stringByAppendingPathComponent:file];
                                BOOL isDir = NO;
                                if ([fileMgr fileExistsAtPath:sourcePath isDirectory:&isDir] && isDir) {
                                    for (NSString *fileInDir in [fileMgr contentsOfDirectoryAtPath:sourcePath error:nil]) {
                                        if (![fileMgr removeItemAtPath:[sourcePath stringByAppendingPathComponent:fileInDir] error:nil])
                                            allContentsCleaned = NO;
                                    }
                                } else {
                                    if (![fileMgr removeItemAtPath:sourcePath error:nil])
                                        allContentsCleaned = NO;
                                }
                            }
                        }

                        if (!allContentsCleaned)
                            [self _log:[NSString stringWithFormat:@"Failed to clean old contents of %@.", appDisplayName]
                                 level:IPAInstallerLogLevelWarning
                               options:options];
                    }

                    if (tempEnableClean)
                        clean = NO;

                    // Recover documents.
                    if (!clean && hasContainer && !notRestore) {
                        ZipArchive *containerArchive = [[ZipArchive alloc] init];
                        if ([containerArchive unzipOpenFile:ipa]) {
                            NSString *containerPath = [workPath stringByAppendingPathComponent:@"Container"];
                            if ([containerArchive unzipFileWithName:@"Container" toPath:containerPath overwrite:YES]) {
                                NSArray *containerContents = [fileMgr contentsOfDirectoryAtPath:containerPath error:nil];
                                if ([containerContents count] > 0) {
                                    BOOL allSuccessful = YES;
                                    for (NSString *dirName in containerContents) {
                                        if ([dirName isEqualToString:@"Library"]) {
                                            NSString *containerLibraryPath = [containerPath stringByAppendingPathComponent:dirName];
                                            for (NSString *dirLibraryName in [fileMgr contentsOfDirectoryAtPath:containerLibraryPath error:nil]) {
                                                if ([dirLibraryName isEqualToString:@"Caches"]) {
                                                    NSString *dirCachePath = [containerLibraryPath stringByAppendingPathComponent:dirLibraryName];
                                                    for (NSString *cacheItem in [fileMgr contentsOfDirectoryAtPath:dirCachePath error:nil]) {
                                                        NSString *dest = [[[installedDataLocation stringByAppendingPathComponent:dirName]
                                                                           stringByAppendingPathComponent:dirLibraryName]
                                                                          stringByAppendingPathComponent:cacheItem];
                                                        if (![fileMgr moveItemAtPath:[dirCachePath stringByAppendingPathComponent:cacheItem] toPath:dest error:nil])
                                                            allSuccessful = NO;
                                                    }
                                                } else if ([dirLibraryName isEqualToString:@"Preferences"]) {
                                                    NSString *dirPreferencesPath = [containerLibraryPath stringByAppendingPathComponent:dirLibraryName];
                                                    for (NSString *preferencesFileName in [fileMgr contentsOfDirectoryAtPath:dirPreferencesPath error:nil]) {
                                                        if (![preferencesFileName isEqualToString:@".GlobalPreferences.plist"] &&
                                                            ![preferencesFileName isEqualToString:@"com.apple.PeoplePicker.plist"]) {
                                                            NSString *dest = [[[installedDataLocation stringByAppendingPathComponent:dirName]
                                                                               stringByAppendingPathComponent:dirLibraryName]
                                                                              stringByAppendingPathComponent:preferencesFileName];
                                                            if (![fileMgr moveItemAtPath:[dirPreferencesPath stringByAppendingPathComponent:preferencesFileName] toPath:dest error:nil])
                                                                allSuccessful = NO;
                                                        }
                                                    }
                                                } else {
                                                    NSString *dest = [[installedDataLocation stringByAppendingPathComponent:dirName]
                                                                      stringByAppendingPathComponent:dirLibraryName];
                                                    if (![fileMgr moveItemAtPath:[containerLibraryPath stringByAppendingPathComponent:dirLibraryName] toPath:dest error:nil])
                                                        allSuccessful = NO;
                                                }
                                            }
                                        } else {
                                            NSString *containerSourcePath = [containerPath stringByAppendingPathComponent:dirName];
                                            NSString *destPath = [installedDataLocation stringByAppendingPathComponent:dirName];
                                            if ([fileMgr fileExistsAtPath:destPath]) {
                                                if ([fileMgr removeItemAtPath:destPath error:nil]) {
                                                    if (![fileMgr moveItemAtPath:containerSourcePath toPath:destPath error:nil])
                                                        allSuccessful = NO;
                                                } else
                                                    allSuccessful = NO;
                                            } else {
                                                if (![fileMgr moveItemAtPath:containerSourcePath toPath:destPath error:nil])
                                                    allSuccessful = NO;
                                            }
                                        }
                                    }
                                    if (!allSuccessful)
                                        [self _log:@"Cannot restore all saved documents and other resources."
                                             level:IPAInstallerLogLevelWarning
                                           options:options];
                                }
                            }
                            [containerArchive unzipCloseFile];
                        }
                        [containerArchive release];
                    }

                    // Remove metadata.
                    if (removeMetadata) {
                        NSString *metadataPath = [installedAppLocation stringByAppendingPathComponent:@"iTunesMetadata.plist"];
                        BOOL isDir = NO;
                        if ([fileMgr fileExistsAtPath:metadataPath isDirectory:&isDir] && !isDir) {
                            [self _log:[NSString stringWithFormat:@"Removing iTunesMetadata.plist for %@...", appDisplayName]
                                 level:IPAInstallerLogLevelInfo
                               options:options];
                            if (![fileMgr removeItemAtPath:metadataPath error:nil])
                                [self _log:[NSString stringWithFormat:@"Failed to remove %@.", metadataPath]
                                     level:IPAInstallerLogLevelWarning
                                   options:options];
                        }
                    }

                    // Set overall permission.
                    if (kCFCoreFoundationVersionNumber < 793.00)
                        IPASetPermissionsForPath(installedAppLocation);
                    else
                        IPASetPermissionsForPath(installedDataLocation);
                    IPASetExecutables(appDirPath);
                } else {
                    [self _log:[NSString stringWithFormat:@"Failed to install %@ (v%@).", appDisplayName, version]
                         level:IPAInstallerLogLevelError
                       options:options];
                }
            } else {
                [self _log:[NSString stringWithFormat:@"Failed to install %@ (v%@).", appDisplayName, version]
                     level:IPAInstallerLogLevelError
                   options:options];
            }
        } else {
            [self _log:[NSString stringWithFormat:@"Failed to install %@ (v%@).", appDisplayName, version]
                 level:IPAInstallerLogLevelError
               options:options];
        }

        // Delete the temporary IPA.
        if (!IPARemoveAllContentsUnderPath(workPath)) {
            [self _log:[NSString stringWithFormat:@"Failed to delete %@.", installPath]
                 level:IPAInstallerLogLevelError
               options:options];
            IPASetError(error, IPAInstallerErrorOperationFailed, @"Failed to clean caches.");
            return successfulInstalls;
        }

        // Delete the original IPA.
        if (deleteFile && [fileMgr fileExistsAtPath:ipa]) {
            if (![fileMgr removeItemAtPath:ipa error:nil])
                [self _log:[NSString stringWithFormat:@"Failed to delete %@.", ipa]
                     level:IPAInstallerLogLevelWarning
                   options:options];
        }
    }

    if (!IPARemoveAllContentsUnderPath(workPath))
        [self _log:@"Failed to clean caches." level:IPAInstallerLogLevelWarning options:options];

    return successfulInstalls;
}

#pragma mark Backup

- (NSString *)backupApplicationWithIdentifier:(NSString *)identifier
                                         full:(BOOL)includeDocuments
                                   outputPath:(NSString *)outputPath
                                      options:(IPAInstallerOptions *)options
                                        error:(NSError **)error {
    IPAInitialize();
    if (error)
        *error = nil;
    if (options == nil)
        options = [IPAInstallerOptions defaultOptions];

    if ([identifier length] == 0) {
        IPASetError(error, IPAInstallerErrorInvalidParameters, @"You must specify an application identifier.");
        return nil;
    }

    NSFileManager *fileMgr = [NSFileManager defaultManager];
    NSString *savePath = outputPath;
    if (savePath) {
        if (![savePath hasPrefix:@"/"])
            savePath = [[fileMgr currentDirectoryPath] stringByAppendingPathComponent:savePath];
        savePath = [savePath stringByStandardizingPath];

        if ([fileMgr fileExistsAtPath:savePath]) {
            NSString *message = [NSString stringWithFormat:@"%@ already exists.", savePath];
            [self _log:message level:IPAInstallerLogLevelError options:options];
            IPASetError(error, IPAInstallerErrorOperationFailed, message);
            return nil;
        }
    }

    NSDictionary *installedAppInfo = [self infoForApplicationWithIdentifier:identifier];
    if (installedAppInfo == nil) {
        NSString *message = [NSString stringWithFormat:@"Application \"%@\" is not installed.", identifier];
        [self _log:message level:IPAInstallerLogLevelError options:options];
        IPASetError(error, IPAInstallerErrorApplicationNotFound, message);
        return nil;
    }
    [self _log:[NSString stringWithFormat:@"Backing up application with identifier \"%@\"...", identifier]
         level:IPAInstallerLogLevelInfo
       options:options];

    NSString *appDirPath = [installedAppInfo objectForKey:@"BUNDLE_PATH"];
    NSString *appPath = [installedAppInfo objectForKey:@"APP_PATH"];
    NSString *dataPath = [installedAppInfo objectForKey:@"DATA_PATH"];
    NSString *appName = [installedAppInfo objectForKey:@"NAME"];
    NSString *appDisplayName = [installedAppInfo objectForKey:@"DISPLAY_NAME"];
    NSString *appVersion = [installedAppInfo objectForKey:@"VERSION"];
    NSString *appShortVersion = [installedAppInfo objectForKey:@"SHORT_VERSION"];
    if ([appDisplayName length] < 1)
        appDisplayName = appName;
    if ([appShortVersion length] < 1)
        appShortVersion = appVersion;

    BOOL isDirectory = NO;
    BOOL directoriesValid = YES;
    NSArray *requiredDirectories = includeDocuments
        ? [NSArray arrayWithObjects:appDirPath, appPath, dataPath, nil]
        : [NSArray arrayWithObjects:appDirPath, appPath, nil];
    for (NSString *path in requiredDirectories) {
        if (![fileMgr fileExistsAtPath:path isDirectory:&isDirectory]) {
            [self _log:[NSString stringWithFormat:@"Cannot find %@.", path] level:IPAInstallerLogLevelError options:options];
            directoriesValid = NO;
        } else if (!isDirectory) {
            [self _log:[NSString stringWithFormat:@"%@ is not a directory.", path] level:IPAInstallerLogLevelError options:options];
            directoriesValid = NO;
        }
    }
    if (!directoriesValid) {
        IPASetError(error, IPAInstallerErrorOperationFailed, @"A required application directory could not be found.");
        return nil;
    }

    NSString *workPath = [self _createWorkPathAndReturnError:error options:options];
    if (workPath == nil)
        return nil;

    ZipArchive *ipaArchive = [[ZipArchive alloc] init];
    // APPEND_STATUS_ADDINZIP = 2
    if (![ipaArchive openZipFile2:[workPath stringByAppendingPathComponent:@"temp.zip"] withZipModel:APPEND_STATUS_ADDINZIP]) {
        [ipaArchive release];
        [self _log:@"Failed to create IPA file." level:IPAInstallerLogLevelError options:options];
        IPARemoveAllContentsUnderPath(workPath);
        IPASetError(error, IPAInstallerErrorOperationFailed, @"Failed to create IPA file.");
        return nil;
    }

    if (![ipaArchive addDirectoryToZip:appPath toPathInZip:[NSString stringWithFormat:@"Payload/%@/", [appPath lastPathComponent]]]) {
        [ipaArchive release];
        [self _log:@"Failed to create IPA file." level:IPAInstallerLogLevelError options:options];
        IPARemoveAllContentsUnderPath(workPath);
        IPASetError(error, IPAInstallerErrorOperationFailed, @"Failed to create IPA file.");
        return nil;
    }

    NSString *artwork = [appDirPath stringByAppendingPathComponent:@"iTunesArtwork"];
    if ([fileMgr fileExistsAtPath:artwork])
        [ipaArchive addFileToZip:artwork newname:@"iTunesArtwork"];

    NSString *metadata = [appDirPath stringByAppendingPathComponent:@"iTunesMetadata.plist"];
    if ([fileMgr fileExistsAtPath:metadata])
        [ipaArchive addFileToZip:metadata newname:@"iTunesMetadata.plist"];

    if (includeDocuments) {
        [self _log:@"Backing up application data..." level:IPAInstallerLogLevelInfo options:options];

        for (NSString *file in [fileMgr contentsOfDirectoryAtPath:dataPath error:nil]) {
            if ([file hasSuffix:@".app"] ||
                [file isEqualToString:@".com.apple.mobile_container_manager.metadata.plist"] ||
                [file isEqualToString:@".com.apple.mobileinstallation.placeholder"] ||
                [file isEqualToString:@".GlobalPreferences.plist"] ||
                [file isEqualToString:@"com.apple.PeoplePicker.plist"] ||
                [file isEqualToString:@"iTunesArtwork"] ||
                [file isEqualToString:@"iTunesMetadata.plist"])
                continue;

            if ([file isEqualToString:@"Library"]) {
                BOOL globalMoved = [fileMgr moveItemAtPath:[dataPath stringByAppendingPathComponent:@"Library/Preferences/.GlobalPreferences.plist"]
                                                    toPath:[dataPath stringByAppendingPathComponent:@".GlobalPreferences.plist"]
                                                     error:nil];
                BOOL pickerMoved = [fileMgr moveItemAtPath:[dataPath stringByAppendingPathComponent:@"Library/Preferences/com.apple.PeoplePicker.plist"]
                                                   toPath:[dataPath stringByAppendingPathComponent:@"com.apple.PeoplePicker.plist"]
                                                    error:nil];

                [ipaArchive addDirectoryToZip:[dataPath stringByAppendingPathComponent:@"Library"]
                                  toPathInZip:@"Container/Library/"];

                if (globalMoved)
                    [fileMgr moveItemAtPath:[dataPath stringByAppendingPathComponent:@".GlobalPreferences.plist"]
                                     toPath:[dataPath stringByAppendingPathComponent:@"Library/Preferences/.GlobalPreferences.plist"]
                                      error:nil];
                if (pickerMoved)
                    [fileMgr moveItemAtPath:[dataPath stringByAppendingPathComponent:@"com.apple.PeoplePicker.plist"]
                                     toPath:[dataPath stringByAppendingPathComponent:@"Library/Preferences/com.apple.PeoplePicker.plist"]
                                      error:nil];
            } else {
                NSString *sourcePath = [dataPath stringByAppendingPathComponent:file];
                BOOL isDir = NO;
                if ([fileMgr fileExistsAtPath:sourcePath isDirectory:&isDir] && isDir)
                    [ipaArchive addDirectoryToZip:sourcePath toPathInZip:[NSString stringWithFormat:@"Container/%@/", file]];
                else
                    [ipaArchive addFileToZip:sourcePath newname:[NSString stringWithFormat:@"Container/%@/", file]];
            }
        }
    }

    [ipaArchive release];

    // Prepare the destination directory.
    NSString *finalSavePath = savePath;
    if (finalSavePath == nil) {
        NSString *nameBase = includeDocuments
            ? [NSString stringWithFormat:@"%@ (%@) v%@ (Full)", IPAGetBestString(appName, appDisplayName), identifier, IPAGetBestString(appVersion, appShortVersion)]
            : [NSString stringWithFormat:@"%@ (%@) v%@", IPAGetBestString(appName, appDisplayName), identifier, IPAGetBestString(appVersion, appShortVersion)];
        NSString *documentsDir = @"/private/var/mobile/Documents";
        if (![fileMgr fileExistsAtPath:documentsDir]) {
            if (![fileMgr createDirectoryAtPath:documentsDir withIntermediateDirectories:YES attributes:nil error:NULL]) {
                [self _log:@"Failed to create /var/mobile/Documents." level:IPAInstallerLogLevelError options:options];
                IPARemoveAllContentsUnderPath(workPath);
                IPASetError(error, IPAInstallerErrorOperationFailed, @"Failed to create /var/mobile/Documents.");
                return nil;
            }
            IPASetDirectoryOwnershipAndPermissions(documentsDir);
        }

        finalSavePath = [[documentsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.ipa", nameBase]] stringByStandardizingPath];
        if ([fileMgr fileExistsAtPath:finalSavePath]) {
            for (int i = 1; ; i++) {
                NSString *candidate = [documentsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d.ipa", nameBase, i]];
                if (![fileMgr fileExistsAtPath:candidate]) {
                    finalSavePath = candidate;
                    break;
                }
            }
        }
    } else {
        NSString *saveDir = [finalSavePath stringByDeletingLastPathComponent];
        BOOL isDir = NO;
        if ([fileMgr fileExistsAtPath:saveDir isDirectory:&isDir]) {
            if (!isDir) {
                [self _log:[NSString stringWithFormat:@"%@ is not a directory.", saveDir]
                     level:IPAInstallerLogLevelError
                   options:options];
                IPARemoveAllContentsUnderPath(workPath);
                IPASetError(error, IPAInstallerErrorOperationFailed, [NSString stringWithFormat:@"%@ is not a directory.", saveDir]);
                return nil;
            }
        } else {
            if (![fileMgr createDirectoryAtPath:saveDir withIntermediateDirectories:YES attributes:nil error:NULL]) {
                [self _log:[NSString stringWithFormat:@"Failed to create directory %@.", saveDir]
                     level:IPAInstallerLogLevelError
                   options:options];
                IPARemoveAllContentsUnderPath(workPath);
                IPASetError(error, IPAInstallerErrorOperationFailed, [NSString stringWithFormat:@"Failed to create directory %@.", saveDir]);
                return nil;
            }
            IPASetDirectoryOwnershipAndPermissions(saveDir);
        }
    }

    if (![fileMgr moveItemAtPath:[workPath stringByAppendingPathComponent:@"temp.zip"] toPath:finalSavePath error:nil]) {
        [self _log:@"Failed to create IPA file." level:IPAInstallerLogLevelError options:options];
        IPARemoveAllContentsUnderPath(workPath);
        IPASetError(error, IPAInstallerErrorOperationFailed, @"Failed to create IPA file.");
        return nil;
    }

    if (!IPARemoveAllContentsUnderPath(workPath))
        [self _log:@"Failed to clean caches." level:IPAInstallerLogLevelWarning options:options];

    [self _log:[NSString stringWithFormat:@"The application has been backed up as %@.", finalSavePath]
         level:IPAInstallerLogLevelInfo
       options:options];
    return finalSavePath;
}

@end
