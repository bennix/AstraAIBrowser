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
yt_dlp_url="https://github.com/yt-dlp/yt-dlp/releases/download/$yt_dlp_version/yt-dlp_macos"
tools_dir="$app_path/Contents/Resources/MediaTools"
cache_dir="${TMPDIR:-/tmp}/astra-media-tools-$yt_dlp_version"
cached_tool="$cache_dir/yt-dlp"

mkdir -p "$cache_dir"
if [[ ! -f "$cached_tool" ]] || [[ "$(/usr/bin/shasum -a 256 "$cached_tool" | /usr/bin/awk '{print $1}')" != "$yt_dlp_sha256" ]]; then
  /usr/bin/curl --fail --location --silent --show-error "$yt_dlp_url" --output "$cached_tool"
fi

actual_sha256="$(/usr/bin/shasum -a 256 "$cached_tool" | /usr/bin/awk '{print $1}')"
[[ "$actual_sha256" == "$yt_dlp_sha256" ]] || {
  >&2 echo "yt-dlp checksum mismatch: expected $yt_dlp_sha256, found $actual_sha256"
  exit 65
}

mkdir -p "$tools_dir"
/usr/bin/ditto "$cached_tool" "$tools_dir/yt-dlp"
/bin/chmod 755 "$tools_dir/yt-dlp"
/usr/bin/xattr -d com.apple.quarantine "$tools_dir/yt-dlp" 2>/dev/null || true

/usr/bin/curl --fail --location --silent --show-error \
  "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$yt_dlp_version/LICENSE" \
  --output "$tools_dir/yt-dlp-LICENSE.txt"
/usr/bin/curl --fail --location --silent --show-error \
  "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$yt_dlp_version/THIRD_PARTY_LICENSES.txt" \
  --output "$tools_dir/yt-dlp-THIRD-PARTY-LICENSES.txt"

echo "Bundled verified media helper into: $tools_dir"
