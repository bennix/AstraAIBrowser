#!/bin/zsh

set -euo pipefail

script_name="${0:t}"

usage() {
  >&2 echo "Usage: $script_name --app '/path/to/Astra Browser.app'"
  exit 64
}

app_path=""
while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || usage
      app_path="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -d "$app_path/Contents/Resources" && "$app_path" == *.app ]] || usage

yt_dlp_version="2026.08.19"
yt_dlp_sha256="0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202"
yt_dlp_license_sha256="7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c"
yt_dlp_third_party_sha256="472aefe951c7db35e1657c1d13fd337140511ed6f2b329205105ad441c5a02b7"
yt_dlp_url="https://github.com/yt-dlp/yt-dlp/releases/download/$yt_dlp_version/yt-dlp_macos"
tools_dir="$app_path/Contents/Resources/MediaTools"
cache_dir="${TMPDIR:-/tmp}/astra-media-tools-$yt_dlp_version"
cached_tool="$cache_dir/yt-dlp"
cached_license="$cache_dir/yt-dlp-LICENSE.txt"
cached_third_party="$cache_dir/yt-dlp-THIRD-PARTY-LICENSES.txt"

download_verified_file() {
  local url="$1"
  local destination="$2"
  local expected_sha256="$3"
  if [[ -f "$destination" ]] && [[ "$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')" == "$expected_sha256" ]]; then
    return
  fi
  /usr/bin/curl --fail --location --silent --show-error \
    --retry 4 --retry-all-errors --connect-timeout 20 \
    "$url" --output "$destination"
  local actual_sha256
  actual_sha256="$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')"
  [[ "$actual_sha256" == "$expected_sha256" ]] || {
    >&2 echo "Downloaded file checksum mismatch: expected $expected_sha256, found $actual_sha256"
    exit 65
  }
}

mkdir -p "$cache_dir"
download_verified_file "$yt_dlp_url" "$cached_tool" "$yt_dlp_sha256"
download_verified_file \
  "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$yt_dlp_version/LICENSE" \
  "$cached_license" \
  "$yt_dlp_license_sha256"
download_verified_file \
  "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$yt_dlp_version/THIRD_PARTY_LICENSES.txt" \
  "$cached_third_party" \
  "$yt_dlp_third_party_sha256"

actual_sha256="$(/usr/bin/shasum -a 256 "$cached_tool" | /usr/bin/awk '{print $1}')"
[[ "$actual_sha256" == "$yt_dlp_sha256" ]] || {
  >&2 echo "yt-dlp checksum mismatch: expected $yt_dlp_sha256, found $actual_sha256"
  exit 65
}

mkdir -p "$tools_dir"
/usr/bin/ditto "$cached_tool" "$tools_dir/yt-dlp"
/bin/chmod 755 "$tools_dir/yt-dlp"
/usr/bin/xattr -d com.apple.quarantine "$tools_dir/yt-dlp" 2>/dev/null || true
/usr/bin/ditto "$cached_license" "$tools_dir/yt-dlp-LICENSE.txt"
/usr/bin/ditto "$cached_third_party" "$tools_dir/yt-dlp-THIRD-PARTY-LICENSES.txt"

echo "Bundled verified media helper into: $tools_dir"
