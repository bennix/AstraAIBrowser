// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

// Main entry point for Astra Browser with CefSwift integration.

#import <Cocoa/Cocoa.h>
#import "PhiApplication.h"
#import "PhiLogging.h"
#import "Phi-Swift.h"

int main(int argc, const char * argv[]) {
    @try {
        // Reassert Phi's explicit language before any code accesses Bundle.main.
        [AppLanguageBootstrap reconcileBeforeBundleAccess];

        [PhiLoggingRuntime installSharedLogging];
        AppLogInfo(@"PhiBrowser starting with main entry point...");
        AppLogInfo(@"Command line arguments: argc=%d", argc);
        
        for (int i = 0; i < argc; i++) {
            AppLogDebug(@"argv[%d]: %s", i, argv[i]);
        }
#if DEBUG
        if (EnvironmentChecker.isRunningPreview) {
            AppLogInfo(@"Running in Xcode Preview environment");
            [[NSThread currentThread] setName:@"main"];
        }
#endif

        // Finish any interrupted user-data removal before Chromium — or the
        // Time Machine bootstrap below — reads or writes any state: stops a
        // still-running detached cleaner, clears canonical-path residue, and
        // sweeps moved-aside leftovers. See UserDataRemoval.
        [UserDataRemovalBootstrap takeOverPendingRemovalIfNeeded];

        if ([TimeMachineBootstrap recoverPendingRestoreIfNeeded]) {
            AppLogInfo(@"Time Machine restore recovery is handling startup; exiting current process.");
            return 0;
        }

        [TimeMachineBootstrap prepareBackupIfNeeded];
        
        [PhiApplication sharedApplication];
        if (![CefBrowserRuntime bootstrapApplication]) {
            AppLogError(@"Failed to initialize CefSwift");
            return 1;
        }
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        return NSApplicationMain(argc, (const char **)argv);
    } @catch (NSException *exception) {
        AppLogError(@"Exception in main: %@ - %@", exception.name, exception.reason);
        AppLogError(@"Exception callstack: %@", exception.callStackSymbols);
        return 1;
    }
}
