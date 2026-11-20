//
//  IPAInstaller.h
//  IPA Installer Library
//
//  Embeddable library for installing, inspecting, uninstalling and backing up
//  IPA files on jailbroken iOS devices.
//
//  The library is not thread-safe. Use a single instance from a single thread,
//  or serialize calls externally.
//

#import <Foundation/Foundation.h>

/** Current library version. */
extern NSString * const IPAInstallerVersion;

/** Error domain used by all NSError objects produced by the library. */
extern NSString * const IPAInstallerErrorDomain;

typedef NS_ENUM(NSInteger, IPAInstallerErrorCode) {
    IPAInstallerErrorInvalidParameters   = -1,
    IPAInstallerErrorInvalidIPA          = -2,
    IPAInstallerErrorFileNotFound        = -3,
    IPAInstallerErrorOperationFailed     = -4,
    IPAInstallerErrorApplicationNotFound = -5
};

typedef NS_ENUM(NSInteger, IPAInstallerLogLevel) {
    IPAInstallerLogLevelInfo     = 0,
    IPAInstallerLogLevelWarning  = 1,
    IPAInstallerLogLevelError    = 2
};

@class IPAInstaller, IPAInstallerOptions;

/**
 * Optional delegate used to receive human readable progress/error messages.
 * When no delegate is set, only warnings and errors are sent to NSLog.
 */
@protocol IPAInstallerDelegate <NSObject>
@optional
- (void)installer:(IPAInstaller *)installer didLogMessage:(NSString *)message level:(IPAInstallerLogLevel)level;
@end

/** Options controlling installation and backup behaviour. */
@interface IPAInstallerOptions : NSObject

/** Remove existing documents and data before installing. Implies NO restore. Default: NO. */
@property (nonatomic, assign) BOOL cleanInstall;

/** Bypass version, device-family, OS-version and capability checks. Default: NO. */
@property (nonatomic, assign) BOOL force;

/** Restore documents contained in the IPA's Container/ directory. Default: YES. */
@property (nonatomic, assign) BOOL restoreDocuments;

/** Remove iTunesMetadata.plist after a successful installation. Default: NO. */
@property (nonatomic, assign) BOOL removeiTunesMetadata;

/** Delete the source IPA file after a successful installation. Default: NO. */
@property (nonatomic, assign) BOOL deleteIPAAfterInstall;

/** Suppress progress messages (warnings/errors are still reported). Default: NO. */
@property (nonatomic, assign) BOOL suppressProgress;

/** Suppress all messages. Default: NO. */
@property (nonatomic, assign) BOOL silent;

+ (IPAInstallerOptions *)defaultOptions;

@end

/**
 * Main library entry point.
 */
@interface IPAInstaller : NSObject

@property (nonatomic, assign) id<IPAInstallerDelegate> delegate;

+ (IPAInstaller *)sharedInstaller;

/** Identifiers of all installed App Store applications, sorted alphabetically. */
- (NSArray *)installedApplicationIdentifiers;

/**
 * Information about an installed application.
 * Returns a dictionary with keys: APP_ID, BUNDLE_PATH, APP_PATH, DATA_PATH,
 * VERSION, SHORT_VERSION, NAME, DISPLAY_NAME. Returns nil if not installed.
 */
- (NSDictionary *)infoForApplicationWithIdentifier:(NSString *)identifier;

/** Uninstall the application with the given identifier. */
- (BOOL)uninstallApplicationWithIdentifier:(NSString *)identifier error:(NSError **)error;

/**
 * Install one or more IPAs.
 * Returns the number of applications installed successfully.
 */
- (NSInteger)installIPAsAtPaths:(NSArray *)paths options:(IPAInstallerOptions *)options error:(NSError **)error;

/** Convenience wrapper around installIPAsAtPaths:options:error: for a single IPA. */
- (BOOL)installIPAAtPath:(NSString *)path options:(IPAInstallerOptions *)options error:(NSError **)error;

/**
 * Back up an installed application into an IPA file.
 * When includeDocuments is YES the application's documents and settings are
 * stored under Container/ inside the IPA. When outputPath is nil the IPA is
 * saved into /private/var/mobile/Documents with a generated name.
 * Returns the final path of the created IPA, or nil on failure.
 */
- (NSString *)backupApplicationWithIdentifier:(NSString *)identifier
                                         full:(BOOL)includeDocuments
                                   outputPath:(NSString *)outputPath
                                      options:(IPAInstallerOptions *)options
                                        error:(NSError **)error;

@end
