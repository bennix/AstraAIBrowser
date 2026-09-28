// Standalone regression test for the CEF application event-state contract.
#define PhiLogging_h
#define AppLogDebug(...) ((void)0)
#import "../Sources/Application/PhiApplication.m"
#import <objc/runtime.h>

static BOOL observedHandlingEvent;
static NSUInteger terminationRequests;

static BOOL deferTermination(void) {
    terminationRequests += 1;
    return NO;
}

static void inspectEventState(id application, SEL selector, NSEvent *event) {
    (void)selector;
    (void)event;
    observedHandlingEvent = [application isHandlingSendEvent];
}

int main(void) {
    @autoreleasepool {
        PhiApplication *application = [PhiApplication sharedApplication];
        Method method = class_getInstanceMethod(NSApplication.class, @selector(sendEvent:));
        IMP original = method_setImplementation(method, (IMP)inspectEventState);
        NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                          location:NSZeroPoint
                                     modifierFlags:0
                                         timestamp:0
                                      windowNumber:0
                                           context:nil
                                           subtype:0
                                             data1:0
                                             data2:0];
        [application setHandlingSendEvent:NO];
        [application sendEvent:event];
        BOOL passed = observedHandlingEvent && ![application isHandlingSendEvent];
        [application setHandlingSendEvent:YES];
        observedHandlingEvent = NO;
        [application sendEvent:event];
        passed = passed && observedHandlingEvent && [application isHandlingSendEvent];
        [application setHandlingSendEvent:NO];
        method_setImplementation(method, original);
        puts(passed ? "PASS: event state is visible during dispatch and restored afterward"
                    : "FAIL: application hides the CEF event state");
        [CEFApplication setTerminateHandler:deferTermination];
        [application replyToApplicationShouldTerminate:NO];
        BOOL terminationPassed = terminationRequests == 0;
        [application replyToApplicationShouldTerminate:YES];
        terminationPassed = terminationPassed && terminationRequests == 1;
        [CEFApplication setTerminateHandler:NULL];
        puts(terminationPassed ? "PASS: deferred termination replies preserve CEF shutdown ownership"
                               : "FAIL: deferred termination bypasses the CEF handler");
        passed = passed && terminationPassed;
        return passed ? 0 : 1;
    }
}
