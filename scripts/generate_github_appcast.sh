#!/bin/zsh

set -euo pipefail

script_name="${0:t}"

usage() {
  >&2 echo "Usage: $script_name --dmg /path/to/Astra-Browser-buildN.dmg --tag v1.0.N [--output /path/to/appcast.xml] [--account keychain-account]"
  exit 64
}

dmg_path=""
release_tag=""
output_path=""
keychain_account="com.phibrowser.Mac.astra-github"
repository="bennix/AstraAIBrowser"

while (( $# > 0 )); do
  case "$1" in
    --dmg)
      (( $# >= 2 )) || usage
      dmg_path="$2"
      shift 2
      ;;
    --tag)
      (( $# >= 2 )) || usage
      release_tag="$2"
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || usage
      output_path="$2"
      shift 2
      ;;
    --account)
      (( $# >= 2 )) || usage
      keychain_account="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -f "$dmg_path" && "$dmg_path" == *.dmg ]] || usage
[[ "$release_tag" =~ '^v[0-9A-Za-z._-]+$' ]] || usage

if [[ -z "$output_path" ]]; then
  output_path="${dmg_path:h}/appcast.xml"
elif [[ "$output_path" != /* ]]; then
  output_path="$(pwd)/$output_path"
fi

[[ "$output_path" == *.xml ]] || {
  >&2 echo "The appcast output path must end in .xml."
  exit 64
}
[[ ! -e "$output_path" ]] || {
  >&2 echo "Refusing to overwrite existing appcast: $output_path"
  exit 73
}

generate_appcast_tool="${SPARKLE_GENERATE_APPCAST:-}"
sign_update_tool="${SPARKLE_SIGN_UPDATE:-}"
if [[ -z "$generate_appcast_tool" || -z "$sign_update_tool" ]]; then
  sparkle_bin_dir="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin' \
    -type d \
    -print \
    -quit 2>/dev/null || true)"
  [[ -n "$generate_appcast_tool" ]] || generate_appcast_tool="$sparkle_bin_dir/generate_appcast"
  [[ -n "$sign_update_tool" ]] || sign_update_tool="$sparkle_bin_dir/sign_update"
fi

[[ -x "$generate_appcast_tool" ]] || {
  >&2 echo "Sparkle generate_appcast was not found. Build Astra once or set SPARKLE_GENERATE_APPCAST."
  exit 69
}
[[ -x "$sign_update_tool" ]] || {
  >&2 echo "Sparkle sign_update was not found. Build Astra once or set SPARKLE_SIGN_UPDATE."
  exit 69
}

appcast_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/astra-appcast.XXXXXX")"
cleanup() {
  if [[ -n "${appcast_temp_dir:-}" && -d "$appcast_temp_dir" && "$appcast_temp_dir" == *'/astra-appcast.'* ]]; then
    rm -rf -- "$appcast_temp_dir"
  fi
}
trap cleanup EXIT INT TERM

asset_name="${dmg_path:t}"
temp_dmg="$appcast_temp_dir/$asset_name"
temp_appcast="$appcast_temp_dir/appcast.xml"
cp -p "$dmg_path" "$temp_dmg"

release_url="https://github.com/$repository/releases/tag/$release_tag"
download_prefix="https://github.com/$repository/releases/download/$release_tag/"

"$generate_appcast_tool" \
  --account "$keychain_account" \
  --maximum-deltas 0 \
  --download-url-prefix "$download_prefix" \
  --link "$release_url" \
  -o "$temp_appcast" \
  "$appcast_temp_dir"

xmllint --noout "$temp_appcast"
rg -Fq "url=\"$download_prefix$asset_name\"" "$temp_appcast" || {
  >&2 echo "Generated appcast does not reference the expected GitHub Release asset."
  exit 65
}
rg -q 'sparkle:edSignature="[^"]+"' "$temp_appcast" || {
  >&2 echo "Generated appcast does not contain a signed update enclosure."
  exit 65
}
rg -Fq '<!-- sparkle-signatures:' "$temp_appcast" || {
  >&2 echo "Generated appcast is not signed as a feed."
  exit 65
}
"$sign_update_tool" --account "$keychain_account" --verify "$temp_appcast"

mkdir -p "${output_path:h}"
install -m 0644 "$temp_appcast" "$output_path"

echo "Signed GitHub Releases appcast: $output_path"
echo "Upload it as an asset named appcast.xml on $release_tag."
