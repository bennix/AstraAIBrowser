# CEF password suggestion acceptance

## Runtime integration constraint

Astra uses CEF's native macOS event loop as the single owner of event dispatch:
`externalMessagePump = false` is paired with `runNativeMessageLoop()` from
the executable entry point. CefSwift starts its periodic work driver only
for clients that choose the external pump. Never combine the native loop
with periodic `cef_do_message_loop_work()` calls or `NSApplicationMain`.

In the bundled CEF `151.3.18+gbeff58d` external pump, `DirectRunWork` only
invokes `DoIdleWork` when there are neither immediate nor delayed tasks.
Pending future tasks can therefore starve idle callbacks. Chromium 151's
`AutofillPopupControllerImpl::AcceptSuggestion` rejects acceptance until
`NextIdleBarrier` has received a UI-thread idle callback. A popup can display
and highlight saved logins while every acceptance attempt returns early.

The native loop handles idle processing while future work is scheduled and
dispatches AppKit input through the standard CEF application integration.
Chromium's acceptance delay, focus checks, and password store remain intact.
The runtime waits for browser closure before quitting the native loop, then
notifies termination observers and shuts CEF down after the loop returns.
Deferred application termination resumes through CEFApplication's reply hook.
System quit Apple events are routed to the same asynchronous termination
handler. AppKit's default Apple-event handler can otherwise enter a nested
termination wait loop, which is incompatible with CEF lifecycle work.
The quit handler must be restored after `NSApplication.finishLaunching`:
AppKit installs its core event handlers during launch and can overwrite a
handler registered during CEF initialization. Testing only pre-launch event
dispatch does not cover this ordering constraint.

Sources for the bundled versions:

- [CEF external pump](https://github.com/chromiumembedded/cef/blob/beff58d/libcef/browser/browser_message_loop.cc)
- [Chromium acceptance check](https://github.com/chromium/chromium/blob/151.0.7922.138/chrome/browser/ui/autofill/autofill_popup_controller_impl.cc)
- [Chromium idle barrier](https://github.com/chromium/chromium/blob/151.0.7922.138/chrome/browser/ui/autofill/next_idle_barrier.cc)
- [Official macOS lifecycle](https://github.com/chromiumembedded/cef/blob/beff58d/tests/cefsimple/cefsimple_mac.mm)

`PhiApplication` must also inherit `CEFApplication`'s `handlingSendEvent`
storage and accessors. Redeclaring the property creates separate state and
hides the superclass's active event-dispatch state from Chromium. The
standalone `Tests/ApplicationEventStateRegression.m` test covers normal and
nested dispatch state restoration and deferred termination replies.
`Tests/CEFQuitEventRegression.m` dispatches a quit Apple event to the installed
handler after AppKit launch and verifies that neither it nor a deferred reply
bypasses CEF.

## Manual acceptance regression

Use an existing saved login, without inspecting or logging its secret:

1. Launch the newly built and signed executable, verifying its process path.
2. Open an authorized HTTPS login page with ongoing background timers.
3. Click the saved-login suggestion. Confirm the popup dismisses, the username
   appears, and the password field contains masked characters.
4. Reload without submitting. Repeat using arrow keys and Return while the
   popup is open. Do not send Return again after acceptance.
5. Repeat on a second authorized login site.
6. Check tab switching, page loading, and normal application termination.

An account list, highlighted row, successful build, or an already authenticated
page alone does not establish that autofill passed. Existing sessions must not
be cleared merely to run this test.

Build 103 used the native pump with a periodic work driver and regressed
AppKit input. Build 104 restored external pumping but the user reproduced
saved-login acceptance failure. Both symptoms must be tested together for
the native-loop integration; neither previous release establishes success.

Validation on 2026-09-28 for the local native-loop candidate:

- Release build and inside-out Developer ID signature verification passed.
- Event-state and quit-event standalone regressions passed.
- The isolated CEF smoke test loaded its expected page title and exited
  naturally with status 0, without killing the process.
- The user confirmed saved-login acceptance on Fudan eHall and working tab
  switching in the first native-loop candidate.
- Further testing exposed a nested AppKit quit loop, a CEF browser-creation
  crash, and a disabled application-menu Quit item. The final candidate routes
  quit Apple events asynchronously and targets the generated Quit menu item at
  AppController; UI checks confirmed the item is enabled, selecting it exits
  the app, and Command-Q exits after a cold launch. Build, signature,
  regression, and natural-exit smoke checks were repeated.
- Address-bar navigation, repeated tab switching after restart, and the mail
  site's saved-login acceptance still require complete manual confirmation on
  the final candidate. The automation tool selected CEF child windows and
  stale menus, so those attempts are not recorded as passes.
- The separate Touch ID path has not been verified by these tests.

## Credential-store boundary

Follow-up quit validation on 2026-09-28:

- Build 105 reproduced a hang with Settings open. A process sample showed
  `_handleAEQuit` / `_shouldTerminate` waiting inside the native CEF loop.
- The follow-up candidate restores the quit handler after AppKit launch and
  permits the explicit Quit selector when browser access is unavailable.
- Release compilation, Developer ID signature verification, launch-aware
  quit-event regression, and event-state regression passed.
- With Settings in front, menu Quit and Command-Q completed; process checks
  found no remaining Astra processes afterward.
- Further page/navigation regression was interrupted by candidate exits
  between UI operations. Their cause needs confirmation before treating those
  attempts as successful navigation or multi-tab coverage. The candidate has
  not replaced the installed application or been published.

Chromium's native saved-login popup and Astra's injected Touch ID button use
different credential stores. This message-loop fix does not migrate credentials
or bypass Keychain authentication. Test and report the two paths separately.
