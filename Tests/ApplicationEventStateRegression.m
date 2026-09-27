// Standalone regression test for the CEF application event-state contract.
#define PhiLogging_h
#define AppLogDebug(...) ((void)0)
#import "../Sources/Application/PhiApplication.m"
#import <objc/runtime.h>

static BOOL observedHandlingEvent;

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
        return passed ? 0 : 1;
    }
}
