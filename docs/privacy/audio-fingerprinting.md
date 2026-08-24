# Browser Fingerprinting Defense

## Threat model

WebAudio can produce stable device signals without microphone permission. A
page can generate a known waveform, process it through the browser and device
audio stack, and read the result through `AudioBuffer` or `AnalyserNode` APIs.
Small differences can contribute to a larger browser fingerprint.

A related resource problem occurs when an inaudible graph is connected to
`AudioContext.destination`. Even with a zero-valued `GainNode`, the operating
system may treat the graph as an active audio session. Reports about
AliExpress identified this behavior in `collina.js` and `fireyejs.js` and linked
it to Bluetooth multipoint handoff failures. The observable behavior is enough
to justify a defensive control; it does not, by itself, prove every claim about
the operator's intent.

## Astra policy

Astra installs one fingerprinting policy in every Chromium frame's default V8
context immediately after context creation and before document scripts run.
The same policy is installed at document start in the system-media WebKit
fallback. A process-scoped random seed is combined with the current host so
readback perturbations remain internally stable for a site during one browser
session but cannot be reused as a durable cross-session identifier.

The policy:

- perturbs Canvas and WebGL pixel readbacks without changing the visible page;
- replaces the precise WebGL GPU model with a generic Apple GPU identity and
  caps selected capability values to common tiers;
- applies a per-page-context perturbation to `AudioBuffer` and `AnalyserNode`
  readbacks used by common audio-fingerprinting probes;
- blocks local font enumeration, reports protected macOS and Chinese font
  families as unavailable, and neutralizes both direct font API checks and DOM
  text-metric probes by mapping explicit probes to a generic fallback while
  retaining normal Chinese text rendering;
- normalizes CPU count, memory hints, and display color depth to common values;
- derives Chromium's `Accept-Language` profile from the system time-zone region
  so language and time-zone exposure remain consistent without changing the
  application's interface language;
- tracks the WebAudio processing graph and prevents a chain with an upstream
  zero-valued `GainNode` from connecting to `AudioContext.destination`;
- defers other pre-activation WebAudio output until a trusted pointer, keyboard,
  or touch event; and
- leaves `HTMLAudioElement`, `HTMLVideoElement`, WebRTC permission handling,
  and browser automation APIs unchanged.

This design avoids disabling JavaScript, graphics, fonts, or WebAudio.
Legitimate rendering and audible WebAudio remain available, while high-entropy
readbacks no longer expose stable raw device output.

## Compatibility and limits

Web applications that intentionally connect a processing chain to the output
while its upstream gain is exactly zero must raise the gain and reconnect the
output before it can become audible. Canvas or WebGL applications that compare
exact exported pixels may observe a one-byte perturbation at sparse positions.
Pages that explicitly require a protected local Chinese font receive a generic
fallback, but Chinese glyphs remain available through normal system fallback.
Standard HTML media playback is not modified. WebRTC IP handling and one-time
camera or microphone approval are separate controls.

The document-start policy is defense in depth, not a claim that fingerprinting
can be eliminated. Dedicated workers and native Blink implementation details
cannot all be changed by a page-context policy. Screen dimensions are not
falsified because reporting dimensions that conflict with the visible window
creates a stronger anomaly; robust screen normalization requires native
letterboxing. TLS fingerprints, proxy headers, exit-IP reputation, open ports,
and destination reachability are network-layer properties and are outside this
policy's ownership.

## Verification

The release test suite covers Canvas and WebGL perturbation, GPU masking,
protected-font concealment, hardware normalization, Audio readback
perturbation, trusted activation, zero-gain processing chains, WebRTC policy,
YouTube playback policy, and the document-start script transport. A real CEF
smoke page verifies the policy in Chromium rather than only in JavaScriptCore.

## References

- [AliExpress WebAudio and Bluetooth multipoint report](https://blog.laserphile.com/2026/08/aliexpress-webpage-keeping-multipoint.html?m=1)
- [Technical reproduction and blocking rules](https://blog.zxce3.net/posts/aliexpress-webaudio-fingerprint-bluetooth-multipoint/)
- [Brave fingerprinting protections](https://github.com/brave/brave-browser/wiki/Fingerprinting-Protections)
- [Brave AudioContext fingerprinting research](https://github.com/brave/brave-browser/issues/51411)
- [Web Audio API privacy discussion](https://github.com/WebAudio/web-audio-api/issues/1500)
