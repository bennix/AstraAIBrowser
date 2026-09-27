# CEF password suggestion acceptance

## Runtime integration constraint

Astra uses the native macOS CEF message pump (`externalMessagePump = false`)
with CefSwift's existing periodic `cef_do_message_loop_work()` driver. Keep
this choice when updating CefSwift or changing the application run loop.

In the bundled CEF `151.3.18+gbeff58d` external pump, `DirectRunWork` only
invokes `DoIdleWork` when there are neither immediate nor delayed tasks.
Pending future tasks can therefore starve idle callbacks. Chromium 151's
`AutofillPopupControllerImpl::AcceptSuggestion` rejects acceptance until
`NextIdleBarrier` has received a UI-thread idle callback. A popup can display
and highlight saved logins while every acceptance attempt returns early.

The native macOS pump permits idle processing between ready tasks even when
future tasks remain scheduled. This preserves Chromium's acceptance delay and
security checks instead of disabling them or extracting passwords into page
scripts.

Sources for the bundled versions:

- [CEF external pump](https://github.com/chromiumembedded/cef/blob/beff58d/libcef/browser/browser_message_loop.cc)
- [Chromium acceptance check](https://github.com/chromium/chromium/blob/151.0.7922.138/chrome/browser/ui/autofill/autofill_popup_controller_impl.cc)
- [Chromium idle barrier](https://github.com/chromium/chromium/blob/151.0.7922.138/chrome/browser/ui/autofill/next_idle_barrier.cc)

`PhiApplication` must also inherit `CEFApplication`'s `handlingSendEvent`
storage and accessors. Redeclaring the property creates separate state and
hides the superclass's active event-dispatch state from Chromium. The
standalone `Tests/ApplicationEventStateRegression.m` test covers normal and
nested dispatch state restoration.

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

Validation on 2026-09-28: the signed local Release build compiled successfully,
the standalone event-state regression passed, and the user confirmed saved-login
selection filled the Fudan eHall login after restarting into this build. This
fix ships in Build 103. Keyboard-only acceptance, the mail login, and the
separate Touch ID path were not verified in that interaction.

## Credential-store boundary

Chromium's native saved-login popup and Astra's injected Touch ID button use
different credential stores. This message-loop fix does not migrate credentials
or bypass Keychain authentication. Test and report the two paths separately.
