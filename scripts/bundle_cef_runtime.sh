#!/bin/zsh

set -euo pipefail

script_name="${0:t}"
project_root="${0:A:h:h}"

usage() {
  >&2 echo "Usage: $script_name --app '/path/to/Astra Browser.app' --cef-swift /path/to/CefSwift [--configuration debug|release] [--identity -|certificate] [--entitlements /path/to/file]"
  exit 64
}

app_path=""
cef_swift_root=""
configuration="release"
signing_identity="-"
entitlements_path=""

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || usage
      app_path="$2"
      shift 2
      ;;
    --cef-swift)
      (( $# >= 2 )) || usage
      cef_swift_root="$2"
      shift 2
      ;;
    --configuration)
      (( $# >= 2 )) || usage
      configuration="$2"
      shift 2
      ;;
    --identity)
      (( $# >= 2 )) || usage
      signing_identity="$2"
      shift 2
      ;;
    --entitlements)
      (( $# >= 2 )) || usage
      entitlements_path="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$configuration" == "debug" || "$configuration" == "release" ]] || usage
[[ -d "$app_path/Contents/MacOS" && "$app_path" == *.app ]] || usage
[[ -f "$cef_swift_root/Package.swift" && -f "$cef_swift_root/CEF_VERSION.json" ]] || usage
if [[ -n "$entitlements_path" && ! -f "$entitlements_path" ]]; then
  >&2 echo "Entitlements file does not exist: $entitlements_path"
  exit 66
fi

if [[ "$signing_identity" != "-" ]]; then
  [[ -n "$entitlements_path" ]] || {
    >&2 echo "Developer ID CEF builds require an entitlements file."
    exit 64
  }
  required_cef_entitlements=(
    "com.apple.security.cs.allow-jit"
    "com.apple.security.cs.allow-unsigned-executable-memory"
    "com.apple.security.cs.disable-library-validation"
  )
  for entitlement in "${required_cef_entitlements[@]}"; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$entitlements_path" 2>/dev/null || true)"
    [[ "$value" == "true" ]] || {
      >&2 echo "Missing required CEF entitlement: $entitlement"
      exit 65
    }
  done
fi

app_path="${app_path:A}"
cef_swift_root="${cef_swift_root:A}"
app_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
minimum_system_version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_path/Contents/Info.plist")"

case "$(uname -m)" in
  arm64) cef_platform="macosarm64" ;;
  x86_64) cef_platform="macosx64" ;;
  *)
    >&2 echo "Unsupported build architecture: $(uname -m)"
    exit 69
    ;;
esac

swift package \
  --package-path "$cef_swift_root" \
  --allow-writing-to-package-directory \
  --allow-network-connections all \
  cef download \
  --platform "$cef_platform" \
  --flavor minimal

helper_scratch_path="$cef_swift_root/.cef/helper-build"
swift build \
  --package-path "$cef_swift_root" \
  --scratch-path "$helper_scratch_path" \
  --configuration "$configuration" \
  --product cef-helper

helper_bin_dir="$(swift build --package-path "$cef_swift_root" --scratch-path "$helper_scratch_path" --configuration "$configuration" --show-bin-path)"
helper_executable="$helper_bin_dir/cef-helper"
framework_source="$(find "$cef_swift_root/.cef/dist" -path "*_${cef_platform}_minimal/Release/Chromium Embedded Framework.framework" -type d -print -quit)"

[[ -x "$helper_executable" ]] || {
  >&2 echo "CEF helper executable was not produced: $helper_executable"
  exit 70
}
[[ -d "$framework_source" ]] || {
  >&2 echo "CEF framework was not prepared under $cef_swift_root/.cef/dist"
  exit 70
}

frameworks_dir="$app_path/Contents/Frameworks"
resources_dir="$app_path/Contents/Resources"
mkdir -p "$frameworks_dir"
mkdir -p "$resources_dir"

runtime_targets=(
  "$frameworks_dir/Chromium Embedded Framework.framework"
  "$frameworks_dir/$app_name Helper.app"
  "$frameworks_dir/$app_name Helper (Alerts).app"
  "$frameworks_dir/$app_name Helper (GPU).app"
  "$frameworks_dir/$app_name Helper (Plugin).app"
  "$frameworks_dir/$app_name Helper (Renderer).app"
)
for target in "${runtime_targets[@]}"; do
  if [[ -e "$target" || -L "$target" ]]; then
    rm -rf "$target"
  fi
done

/usr/bin/ditto "$framework_source" "$frameworks_dir/Chromium Embedded Framework.framework"
/usr/bin/ditto "$cef_swift_root/LICENSE" "$resources_dir/CefSwift-LICENSE.txt"
/usr/bin/ditto "${framework_source:h:h}/LICENSE.txt" "$resources_dir/CEF-LICENSE.txt"

make_helper() {
  local suffix="$1"
  local bundle_id_suffix="$2"
  local helper_name="$app_name Helper"
  if [[ -n "$suffix" ]]; then
    helper_name="$helper_name ($suffix)"
  fi

  local helper_app="$frameworks_dir/$helper_name.app"
  local helper_contents="$helper_app/Contents"
  local helper_macos="$helper_contents/MacOS"
  local helper_plist="$helper_contents/Info.plist"
  mkdir -p "$helper_macos"
  /usr/bin/ditto "$helper_executable" "$helper_macos/$helper_name"
  chmod 755 "$helper_macos/$helper_name"
  /usr/bin/plutil -create xml1 "$helper_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$helper_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $helper_name" "$helper_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id$bundle_id_suffix" "$helper_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$helper_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string $helper_name" "$helper_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $helper_name" "$helper_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$helper_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0" "$helper_plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$helper_plist"
  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $minimum_system_version" "$helper_plist"
  /usr/libexec/PlistBuddy -c "Add :NSSupportsAutomaticGraphicsSwitching bool true" "$helper_plist"
  /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$helper_plist"
  /usr/libexec/PlistBuddy -c "Add :LSFileQuarantineEnabled bool true" "$helper_plist"
  print -n 'APPL????' > "$helper_contents/PkgInfo"
}

make_helper "" ".helper"
make_helper "Alerts" ".helper.alerts"
make_helper "GPU" ".helper.gpu"
make_helper "Plugin" ".helper.plugin"
make_helper "Renderer" ".helper.renderer"

sign_target() {
  local target="$1"
  local include_entitlements="${2:-false}"
  local arguments=(--force --sign "$signing_identity")
  if [[ "$signing_identity" == "-" ]]; then
    arguments+=(--timestamp=none)
  else
    arguments+=(--options runtime --timestamp)
  fi
  if [[ "$include_entitlements" == "true" && -n "$entitlements_path" ]]; then
    arguments+=(--entitlements "$entitlements_path")
  fi
  /usr/bin/codesign "${arguments[@]}" "$target"
}

cef_framework="$frameworks_dir/Chromium Embedded Framework.framework"
for runtime_library in "$cef_framework"/Versions/A/Libraries/*.dylib(.N); do
  sign_target "$runtime_library"
done
sign_target "$cef_framework"

sparkle_framework="$frameworks_dir/Sparkle.framework"
if [[ -d "$sparkle_framework" ]]; then
  sparkle_version="$sparkle_framework/Versions/Current"
  [[ -f "$sparkle_version/Autoupdate" ]] && sign_target "$sparkle_version/Autoupdate"
  for sparkle_service in "$sparkle_version"/XPCServices/*.xpc(N); do
    sign_target "$sparkle_service"
  done
  [[ -d "$sparkle_version/Updater.app" ]] && sign_target "$sparkle_version/Updater.app"
  sign_target "$sparkle_framework"
fi

for release_helper in "$app_path"/Contents/Helpers/*(N.); do
  [[ -f "$release_helper" ]] && sign_target "$release_helper"
done

# Xcode leaves package frameworks signed for local development when the app is
# built without signing. Re-sign every embedded framework explicitly so a
# Developer ID release never retains an ad-hoc inner binary.
for embedded_framework in "$frameworks_dir"/*.framework(N/); do
  sign_target "$embedded_framework"
done

for helper_app in "$frameworks_dir"/"$app_name Helper"*.app; do
  sign_target "$helper_app" true
done
if [[ "$signing_identity" == "-" ]]; then
  # Unsigned Xcode products can contain stripped development frameworks whose
  # original seals no longer match. Deep ad-hoc signing is limited to local
  # smoke-test builds; Developer ID releases always use explicit inside-out
  # signing above.
  /usr/bin/codesign --force --deep --timestamp=none --sign - "$app_path"
else
  sign_target "$app_path" true
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
echo "Bundled CEF runtime into: $app_path"
