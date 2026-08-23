#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
cef_swift_root="${1:-$repository_root/Vendor/CefSwift}"
patch_file="$repository_root/patches/cefswift/capture-visible-page-screenshot.patch"
target_file="$cef_swift_root/Sources/CefKit/CefBrowser.swift"

if [[ ! -f "$target_file" ]]; then
  >&2 echo "CefSwift source is missing: $target_file"
  exit 66
fi

if /usr/bin/grep -q "public func captureVisiblePageScreenshot" "$target_file"; then
  echo "CefSwift patches are already applied."
  exit 0
fi

git apply --check --unsafe-paths --directory="$cef_swift_root" "$patch_file"
git apply --unsafe-paths --directory="$cef_swift_root" "$patch_file"
echo "Applied Astra CefSwift patches."
