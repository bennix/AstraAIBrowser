#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
cef_swift_root="${1:-$repository_root/Vendor/CefSwift}"
patches=(
  "$repository_root/patches/cefswift/capture-visible-page-screenshot.patch"
  "$repository_root/patches/cefswift/evaluate-javascript-result.patch"
  "$repository_root/patches/cefswift/configure-accept-language.patch"
  "$repository_root/patches/cefswift/integrate-unmanaged-browser-windows.patch"
  "$repository_root/patches/cefswift/install-document-start-script.patch"
  "$repository_root/patches/cefswift/export-session-cookies.patch"
  "$repository_root/patches/cefswift/support-embedded-profile-and-popovers.patch"
  "$repository_root/patches/cefswift/forward-mouse-release-flags.patch"
  "$repository_root/patches/cefswift/configure-do-not-track.patch"
)
targets=(
  "$cef_swift_root/Sources/CefKit/CefBrowser.swift"
  "$cef_swift_root/Sources/CefKit/CefBrowser.swift"
  "$cef_swift_root/Sources/CefKit/BrowserClient.swift"
  "$cef_swift_root/Sources/CefKit/CefRuntime.swift"
  "$cef_swift_root/Sources/CefKit/CefConfiguration.swift"
  "$cef_swift_root/Sources/CefKit/CefBrowser.swift"
  "$cef_swift_root/Sources/CefKit/CefChromeBrowser.swift"
  "$cef_swift_root/Sources/CefSwiftUI/CefMetalHostView+Input.swift"
  "$cef_swift_root/Sources/CefKit/CefConfiguration.swift"
)
markers=(
  "public func captureVisiblePageScreenshot"
  "public func evaluateJavaScriptResult"
  "public var acceptLanguageList"
  "public func closeUnmanagedBrowserWindow"
  "public var documentStartJavaScript"
  "public func cookies(for url: URL"
  "public func activate()"
  "eventType: NSEvent.EventType? = nil"
  "final class CefDoNotTrackPolicy"
)

applied_any=false
for index in "${!patches[@]}"; do
  patch_file="${patches[$index]}"
  target_file="${targets[$index]}"
  marker="${markers[$index]}"

  if [[ ! -f "$target_file" ]]; then
    >&2 echo "CefSwift source is missing: $target_file"
    exit 66
  fi
  if /usr/bin/grep -q "$marker" "$target_file"; then
    continue
  fi

  git -C "$cef_swift_root" apply --check "$patch_file"
  git -C "$cef_swift_root" apply "$patch_file"
  applied_any=true
done

if [[ "$applied_any" == true ]]; then
  echo "Applied Astra CefSwift patches."
else
  echo "CefSwift patches are already applied."
fi
