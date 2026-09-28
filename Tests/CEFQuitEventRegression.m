// Standalone regression for quit events bypassing AppKit's modal quit loop.
@import CCefAppKit;

static NSUInteger terminationRequests;

static BOOL deferTermination(void) {
    terminationRequests += 1;
    return NO;
}

int main(void) {
    @autoreleasepool {
        CEFApplication *application = [CEFApplication sharedApplication];
        [CEFApplication setTerminateHandler:deferTermination];
        // Exercise real AppKit launch setup, which can replace early handlers.
        [application finishLaunching];
        NSAppleEventDescriptor *event = [NSAppleEventDescriptor
            appleEventWithEventClass:kCoreEventClass
                             eventID:kAEQuitApplication
                    targetDescriptor:nil
                            returnID:kAutoGenerateReturnID
                       transactionID:kAnyTransactionID];
        AppleEvent reply = {typeNull, NULL};
        OSErr result = [[NSAppleEventManager sharedAppleEventManager]
            dispatchRawAppleEvent:event.aeDesc
                     withRawReply:&reply
                    handlerRefCon:(SRefCon)&terminationRequests];
        AEDisposeDesc(&reply);
        BOOL passed = result == noErr && terminationRequests == 1;
        [application replyToApplicationShouldTerminate:NO];
        passed = passed && terminationRequests == 1;
        [application replyToApplicationShouldTerminate:YES];
        passed = passed && terminationRequests == 2;
        [CEFApplication setTerminateHandler:NULL];
        puts(passed ? "PASS: quit events and deferred replies use the asynchronous CEF termination handler"
                    : "FAIL: quit routing bypasses the CEF termination handler");
        return passed ? 0 : 1;
    }
}
