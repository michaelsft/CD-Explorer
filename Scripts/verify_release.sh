#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
version=${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Info.plist")}
output_dir="$project_dir/dist"
dmg="$output_dir/CD-Explorer-$version.dmg"
source_archive="$output_dir/CD-Explorer-$version-Third-Party-Source.tar.gz"
checksums="$output_dir/SHA256SUMS-$version.txt"

for item in "$dmg" "$source_archive" "$checksums"; do
  if [[ ! -f "$item" ]]; then
    echo "Missing release file: $item" >&2
    exit 1
  fi
done

(
  cd "$output_dir"
  /usr/bin/shasum -a 256 -c "SHA256SUMS-$version.txt"
)

/usr/bin/hdiutil verify "$dmg" >/dev/null
mount_dir=$(mktemp -d "/tmp/cd-explorer-verify-${version//[^A-Za-z0-9]/_}.XXXXXX")

cleanup() {
  /usr/bin/hdiutil detach "$mount_dir" >/dev/null 2>&1 || true
  /bin/rmdir "$mount_dir" >/dev/null 2>&1 || true
}
trap cleanup EXIT

/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$dmg" >/dev/null
app="$mount_dir/CD Explorer.app"

[[ -d "$app" ]]
[[ -L "$mount_dir/Applications" ]]
[[ -x "$app/Contents/Resources/Tools/ffmpeg" ]]
[[ -x "$app/Contents/Resources/Tools/ffprobe" ]]
[[ -f "$app/Contents/Resources/Open Source Licences/CD Explorer GPLv3.txt" ]]
[[ -f "$app/Contents/Resources/Open Source Licences/MPVKit LGPLv3.txt" ]]
[[ -f "$app/Contents/Resources/Open Source Licences/THIRD_PARTY_NOTICES.md" ]]
[[ -f "$app/Contents/Resources/Open Source Licences/DEPENDENCIES.md" ]]

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
/usr/bin/lipo -verify_arch arm64 "$app/Contents/MacOS/CDExplorer"
/usr/bin/lipo -verify_arch x86_64 "$app/Contents/MacOS/CDExplorer"

bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ "$bundle_version" != "$version" ]]; then
  echo "DMG app version $bundle_version does not match $version." >&2
  exit 1
fi

/usr/bin/tar -tzf "$source_archive" | /usr/bin/grep -q 'ffmpeg-9.0.2.tar.xz'
/usr/bin/tar -tzf "$source_archive" | /usr/bin/grep -q 'x264-0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee.tar.gz'

echo "CD Explorer $version release verified."

