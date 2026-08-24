#!/bin/zsh

set -euo pipefail

script_name="${0:t}"
project_root="${0:A:h:h}"

usage() {
  >&2 echo "Usage: $script_name --app '/path/to/Astra Browser.app' [--output /path/to/Astra-Browser.dmg] [--profile keychain-profile] [--apple-id email --team-id id] [--identity 'Developer ID Application: ...']"
  exit 64
}

app_path=""
output_path=""
notary_profile="${NOTARY_KEYCHAIN_PROFILE:-PhiBrowser-Notary}"
signing_identity="${DEVELOPER_ID_APPLICATION:-}"
notary_apple_id=""
notary_team_id=""

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || usage
      app_path="$2"
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || usage
      output_path="$2"
      shift 2
      ;;
    --profile)
      (( $# >= 2 )) || usage
      notary_profile="$2"
      shift 2
      ;;
    --identity)
      (( $# >= 2 )) || usage
      signing_identity="$2"
      shift 2
      ;;
    --apple-id)
      (( $# >= 2 )) || usage
      notary_apple_id="$2"
      shift 2
      ;;
    --team-id)
      (( $# >= 2 )) || usage
      notary_team_id="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$app_path" && -d "$app_path" && "$app_path" == *.app ]] || usage

for command_name in codesign hdiutil security spctl xcrun; do
  command -v "$command_name" >/dev/null || {
    >&2 echo "Required command is unavailable: $command_name"
    exit 69
  }
done

if [[ -z "$signing_identity" ]]; then
  signing_identity="$({ security find-identity -v -p codesigning 2>/dev/null || true; } \
    | sed -nE 's/^.*"(Developer ID Application: [^"]+)".*$/\1/p' \
    | head -n 1)"
fi

if [[ -z "$signing_identity" ]]; then
  >&2 echo "No Developer ID Application identity was found."
  exit 78
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
app_authorities="$(codesign -dvv "$app_path" 2>&1 || true)"
if [[ "$app_authorities" != *"Authority=Developer ID Application:"* ]]; then
  >&2 echo "The app is not signed with Developer ID Application. Archive/export it with Developer ID signing before creating the DMG."
  exit 65
fi

app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist")"
app_executable_path="$app_path/Contents/MacOS/$app_executable"
[[ -x "$app_executable_path" ]] || {
  >&2 echo "The app executable is missing: $app_executable_path"
  exit 66
}
if ! smoke_output="$(
  "$app_executable_path" \
    --cef-smoke-test \
    '--astra-initial-url=data:text/html,<title>Astra%20Release%20Smoke</title><main>Astra%20release%20smoke</main>' \
    2>&1
)"; then
  >&2 echo "The signed app failed its real-launch smoke test."
  >&2 echo "$smoke_output"
  exit 65
fi
if [[ "$smoke_output" != *"[cef-smoke] loaded title:"* ]]; then
  >&2 echo "The signed app launched but did not complete its CEF smoke test."
  >&2 echo "$smoke_output"
  exit 65
fi
echo "$smoke_output"

if [[ -z "$output_path" ]]; then
  output_path="$(pwd)/Astra-Browser.dmg"
fi
if [[ "$output_path" != /* ]]; then
  output_path="$(pwd)/$output_path"
fi
[[ "$output_path" == *.dmg ]] || {
  >&2 echo "The output path must end in .dmg."
  exit 64
}

release_build="$(basename "$output_path" | sed -nE 's/^Astra-Browser-build([0-9]+)\.dmg$/\1/p')"
verification_arguments=(--app "$app_path")
if [[ -n "$release_build" ]]; then
  verification_arguments+=(--release-build "$release_build")
fi
"$project_root/scripts/verify_astra_release.sh" "${verification_arguments[@]}"

if [[ -e "$output_path" ]]; then
  >&2 echo "Refusing to overwrite existing output: $output_path"
  exit 73
fi

release_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/phi-notary.XXXXXX")"
cleanup() {
  if [[ -n "${release_temp_dir:-}" && -d "$release_temp_dir" && "$release_temp_dir" == *"/phi-notary."* ]]; then
    rm -rf "$release_temp_dir"
  fi
}
trap cleanup EXIT INT TERM

staging_dir="$release_temp_dir/dmg-root"
mkdir -p "$staging_dir"
ditto "$app_path" "$staging_dir/${app_path:t}"
ln -s /Applications "$staging_dir/Applications"

hdiutil create \
  -volname "Astra Browser" \
  -fs HFS+ \
  -srcfolder "$staging_dir" \
  -format UDZO \
  "$output_path"

codesign --force --timestamp --sign "$signing_identity" "$output_path"
codesign --verify --verbose=2 "$output_path"

notary_arguments=(--wait)
if [[ -n "$notary_apple_id" || -n "$notary_team_id" ]]; then
  [[ -n "$notary_apple_id" && -n "$notary_team_id" && -n "${NOTARY_APP_PASSWORD:-}" ]] || {
    >&2 echo "Direct notarization requires --apple-id, --team-id, and NOTARY_APP_PASSWORD."
    exit 64
  }
  notary_arguments+=(
    --apple-id "$notary_apple_id"
    --team-id "$notary_team_id"
    --password "$NOTARY_APP_PASSWORD"
  )
else
  notary_arguments+=(--keychain-profile "$notary_profile")
fi

xcrun notarytool submit "$output_path" "${notary_arguments[@]}"

xcrun stapler staple -v "$output_path"
xcrun stapler validate -v "$output_path"
spctl --assess --type open --context context:primary-signature --verbose=2 "$output_path"

echo "Notarized DMG: $output_path"
