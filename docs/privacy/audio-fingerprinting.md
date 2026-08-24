# WebAudio Fingerprinting Defense

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

Astra installs its WebAudio policy in every Chromium frame's default V8
context immediately after context creation and before document scripts run.
The same policy is installed at document start in the system-media WebKit
fallback.

The policy:

- applies a per-page-context perturbation to `AudioBuffer` and `AnalyserNode`
  readbacks used by common audio-fingerprinting probes;
- tracks the WebAudio processing graph and prevents a chain with an upstream
  zero-valued `GainNode` from connecting to `AudioContext.destination`;
- defers other pre-activation WebAudio output until a trusted pointer, keyboard,
  or touch event; and
- leaves `HTMLAudioElement`, `HTMLVideoElement`, WebRTC permission handling,
  and browser automation APIs unchanged.

This design avoids disabling all WebAudio. Legitimate audible WebAudio remains
available after user interaction, while the reported zero-volume graph cannot
claim the system audio output and fingerprint readbacks are made unstable.

## Compatibility and limits

Web applications that intentionally connect a processing chain to the output
while its upstream gain is exactly zero must raise the gain and reconnect the
output before it can become audible. Standard HTML media playback is not
modified. WebRTC IP handling and one-time camera or microphone approval are
separate controls.

This is a focused defense, not a claim that every fingerprinting surface is
eliminated. Canvas, WebGL, fonts, timing, and other browser signals require
their own controls.

## Verification

The release test suite covers readback perturbation, trusted activation,
zero-gain processing chains, WebRTC policy, YouTube playback policy, and the
document-start script transport. A real CEF smoke page also verifies that the
policy is visible to the first page script.

## References

- [AliExpress WebAudio and Bluetooth multipoint report](https://blog.laserphile.com/2026/08/aliexpress-webpage-keeping-multipoint.html?m=1)
- [Technical reproduction and blocking rules](https://blog.zxce3.net/posts/aliexpress-webaudio-fingerprint-bluetooth-multipoint/)
- [Brave fingerprinting protections](https://github.com/brave/brave-browser/wiki/Fingerprinting-Protections)
- [Brave AudioContext fingerprinting research](https://github.com/brave/brave-browser/issues/51411)
- [Web Audio API privacy discussion](https://github.com/WebAudio/web-audio-api/issues/1500)
