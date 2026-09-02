#!/bin/zsh

set -euo pipefail

script_name="${0:t}"

usage() {
  >&2 echo "Usage: $script_name --app '/path/to/Astra Browser.app' [--release-build number]"
  exit 64
}

app_path=""
release_build=""

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || usage
      app_path="$2"
      shift 2
      ;;
    --release-build)
      (( $# >= 2 )) || usage
      release_build="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -d "$app_path/Contents" && "$app_path" == *.app ]] || usage
[[ -z "$release_build" || "$release_build" == <-> ]] || usage

info_plist="$app_path/Contents/Info.plist"
resources_path="$app_path/Contents/Resources"
[[ -f "$info_plist" ]] || {
  >&2 echo "Astra release Info.plist is missing: $info_plist"
  exit 66
}

read_plist() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist" 2>/dev/null || true
}

assert_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(read_plist "$key")"
  [[ "$actual" == "$expected" ]] || {
    >&2 echo "Invalid $key: expected '$expected', found '$actual'."
    exit 65
  }
}

assert_missing_plist_key() {
  local key="$1"
  local actual
  actual="$(read_plist "$key")"
  [[ -z "$actual" ]] || {
    >&2 echo "Forbidden updater key remains in Astra release: $key"
    exit 65
  }
}

assert_plist_value CFBundleDisplayName "Astra Browser"
assert_plist_value CFBundleIdentifier "com.phibrowser.Mac"
assert_plist_value CFBundleIconFile "AstraIcon"
assert_plist_value CFBundleIconName "AstraIcon"

bundle_version="$(read_plist CFBundleVersion)"
[[ "$bundle_version" == <-> ]] || {
  >&2 echo "CFBundleVersion must be an integer, found '$bundle_version'."
  exit 65
}

minimum_astra_bundle_version=10000
(( bundle_version >= minimum_astra_bundle_version )) || {
  >&2 echo "CFBundleVersion $bundle_version can be replaced by legacy Phi build 616."
  exit 65
}

if [[ -n "$release_build" ]]; then
  expected_bundle_version=$((minimum_astra_bundle_version + release_build))
  (( bundle_version == expected_bundle_version )) || {
    >&2 echo "Release Build $release_build must use CFBundleVersion $expected_bundle_version, found $bundle_version."
    exit 65
  }
fi

assert_plist_value SUAutomaticallyUpdate false
assert_plist_value SUEnableAutomaticChecks true
assert_plist_value SUFeedURL "https://github.com/bennix/AstraAIBrowser/releases/latest/download/appcast.xml"
assert_plist_value SUPublicEDKey "rWXUlON9obaJqG7YbfFwDLeqNwkr4eB/da+/GGvZ2mE="
assert_plist_value SURequireSignedFeed true
assert_plist_value SUSignedFeedFailureExpirationInterval 0
assert_plist_value SUVerifyUpdateBeforeExtraction true
assert_missing_plist_key SUScheduledCheckInterval

[[ -f "$resources_path/AstraIcon.icns" ]] || {
  >&2 echo "AstraIcon.icns is missing from the release bundle."
  exit 66
}

[[ -x "$resources_path/MediaTools/yt-dlp" ]] || {
  >&2 echo "Verified media helper is missing from the Astra release."
  exit 66
}
if ! media_tool_version="$("$resources_path/MediaTools/yt-dlp" --version 2>&1)"; then
  >&2 echo "The signed media helper cannot launch in this Astra release."
  >&2 echo "$media_tool_version"
  exit 65
fi

legacy_icon="$(find "$resources_path" -iname 'PhiIcon*' -print -quit)"
[[ -z "$legacy_icon" ]] || {
  >&2 echo "Legacy Phi app icon remains in the release bundle: $legacy_icon"
  exit 65
}

[[ ! -e "$resources_path/TimeMachineRollbackPolicy.json" ]] || {
  >&2 echo "Legacy Phi rollback policy remains in the release bundle."
  exit 65
}

legacy_update_reference="$(rg -a -l 'ota\.phibrowser\.com|PhiBrowserMacUpdate\.xml|Phi_1\.6\.0_616' "$app_path" 2>/dev/null | head -n 1 || true)"
[[ -z "$legacy_update_reference" ]] || {
  >&2 echo "Legacy Phi update reference remains in the release bundle: $legacy_update_reference"
  exit 65
}

echo "Verified Astra release identity: Build $bundle_version, AstraIcon, no Phi updater or rollback."
