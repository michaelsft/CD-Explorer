#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
version=${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Info.plist")}
output_dir=${2:-"$project_dir/dist"}
cache_dir="$project_dir/.source-cache"
stage_dir=$(mktemp -d "/tmp/cd-explorer-source-${version//[^A-Za-z0-9]/_}.XXXXXX")

cleanup() {
  /bin/rm -rf "$stage_dir"
}
trap cleanup EXIT

mkdir -p "$cache_dir" "$output_dir" "$stage_dir/CD-Explorer-$version-Third-Party-Source"

ffmpeg_name='ffmpeg-9.0.2.tar.xz'
ffmpeg_url='https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz'
ffmpeg_sha='8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e'
x264_name='x264-0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee.tar.gz'
x264_url='https://code.videolan.org/videolan/x264/-/archive/0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee/x264-0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee.tar.gz'
x264_sha='d0967a1348c85dfde363bb52610403be898171493100561efa0dd05d5fd1ae50'

fetch_and_verify() {
  local url=$1
  local name=$2
  local expected=$3
  local target="$cache_dir/$name"
  if [[ ! -f "$target" ]]; then
    /usr/bin/curl -fL "$url" -o "$target"
  fi
  local actual
  actual=$(/usr/bin/shasum -a 256 "$target" | /usr/bin/awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for $name" >&2
    exit 1
  fi
}

fetch_and_verify "$ffmpeg_url" "$ffmpeg_name" "$ffmpeg_sha"
fetch_and_verify "$x264_url" "$x264_name" "$x264_sha"
# MP3 and Opus encoder sources, fetched and checked by build_audio_encoders.sh.
(cd "$cache_dir" && /usr/bin/shasum -a 256 -c "$script_dir/audio_encoder_sources.sha256")

source_root="$stage_dir/CD-Explorer-$version-Third-Party-Source"
/bin/cp "$cache_dir/$ffmpeg_name" "$source_root/"
/bin/cp "$cache_dir/$x264_name" "$source_root/"
for name in $(/usr/bin/awk '{print $2}' "$script_dir/audio_encoder_sources.sha256"); do
  /bin/cp "$cache_dir/$name" "$source_root/"
done
/bin/cp "$script_dir/build_audio_encoders.sh" "$source_root/"
/bin/cp "$project_dir/BundledTools/FFmpeg-NOTICE.txt" "$source_root/"
/bin/cp "$project_dir/BundledTools/COPYING.GPLv2" "$source_root/"
/bin/cp "$project_dir/BundledTools/COPYING.x264" "$source_root/"
/bin/cp "$project_dir/ThirdParty/DEPENDENCIES.md" "$source_root/"
/bin/cp "$project_dir/ThirdParty/THIRD_PARTY_NOTICES.md" "$source_root/"
/bin/cp "$project_dir/ThirdParty/MPVKit-LICENSE.txt" "$source_root/"
/bin/cp "$project_dir/Package.swift" "$source_root/"
/bin/cp "$project_dir/Package.resolved" "$source_root/"

(
  cd "$stage_dir"
  /usr/bin/tar -czf "$output_dir/CD-Explorer-$version-Third-Party-Source.tar.gz" "CD-Explorer-$version-Third-Party-Source"
)

echo "$output_dir/CD-Explorer-$version-Third-Party-Source.tar.gz"

