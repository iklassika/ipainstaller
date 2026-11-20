IPA Installer Library
=====================

An embeddable Objective-C library for installing, inspecting, uninstalling and
backing up IPA files on jailbroken iOS devices (iOS 5.1+).

This project is the former `ipainstaller` console tool converted into a static
library. All of the tool's logic now lives in the `IPAInstaller` class; there is
no CLI binary anymore. It builds for `armv7` and `arm64` with a minimum
deployment target of iOS 5.1.

Building
--------

Build with Theos (uses `$(THEOS)`, defaulting to `~/theos`; override with
`TARGET_SDK=...` if needed):

    make

This produces `.theos/obj/<arch>/libipainstaller.a` (and a fat
`libipainstaller.a` when building multiple architectures). To stage the library
and the public header:

    make stage

The staged layout is:

    /usr/lib/libipainstaller.a
    /usr/include/IPAInstaller/IPAInstaller.h

Using the library
-----------------

Add the library and header to your project and import the public header:

```objc
#import <IPAInstaller/IPAInstaller.h>

IPAInstaller *installer = [IPAInstaller sharedInstaller];

// Optional: receive progress and error messages.
// installer.delegate = self;

IPAInstallerOptions *options = [IPAInstallerOptions defaultOptions];
options.cleanInstall = YES;
options.force = NO;
options.restoreDocuments = YES;
options.removeiTunesMetadata = YES;
options.deleteIPAAfterInstall = NO;

NSError *error = nil;
BOOL ok = [installer installIPAAtPath:@"/path/to/App.ipa"
                              options:options
                                error:&error];
if (!ok)
    NSLog(@"Install failed: %@", error);
```

Batch installation returns the number of successfully installed applications:

```objc
NSInteger installed = [installer installIPAsAtPaths:@[ @"a.ipa", @"b.ipa" ]
                                            options:options
                                              error:&error];
```

Other operations:

```objc
NSArray *identifiers = [installer installedApplicationIdentifiers];
NSDictionary *info = [installer infoForApplicationWithIdentifier:@"com.example.app"];
[installer uninstallApplicationWithIdentifier:@"com.example.app" error:&error];

// Back up an application, including its documents, to a specific path.
NSString *ipa = [installer backupApplicationWithIdentifier:@"com.example.app"
                                                      full:YES
                                                outputPath:@"/var/mobile/Documents/backup.ipa"
                                                   options:options
                                                     error:&error];
```

The library is not thread-safe: use one instance from one thread, or serialize
calls externally.

Linking requirements
--------------------

When linking against `libipainstaller.a`, the host executable needs:

- Frameworks: Foundation, UIKit, ImageIO, CoreGraphics
- Private frameworks: GraphicsServices, MobileCoreServices
- System libraries: `libz` (used by minizip)
- On iOS 6 and older, the host must be entitled/signed to use
  `MobileInstallationInstall` / `MobileInstallationUninstall` (the original
  `sign.plist` is kept for reference). On iOS 7+ installation goes through
  `LSApplicationWorkspace`, resolved at runtime via the Objective-C runtime.

Bundled third-party code
------------------------

- ZipArchive from https://github.com/mattconnolly/ZipArchive (with minizip)
- UIDevice-Extension from https://github.com/erica/uidevice-extension
- Capability check from https://github.com/a3tweaks/Flipswitch/blob/master/FSCapability.m

`fixblankicon` and `MobileInstallation` are kept from the original repository
but are not used by the library build.
