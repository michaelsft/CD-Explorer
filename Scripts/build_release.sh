#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
version=${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Info.plist")}
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Info.plist")

if [[ "$version" != "$plist_version" ]]; then
  echo "Requested version $version does not match Info.plist version $plist_version." >&2
  exit 1
fi

for tool in /opt/homebrew/bin/create-dmg /opt/homebrew/bin/magick /usr/bin/hdiutil /usr/bin/codesign; do
  if [[ ! -x "$tool" ]]; then
    echo "Missing release tool: $tool" >&2
    exit 1
  fi
done

work_dir=$(mktemp -d "/tmp/cd-explorer-release-${version//[^A-Za-z0-9]/_}.XXXXXX")
stage_dir="$work_dir/dmg"
background="$work_dir/dmg-background.png"
output_dir="$project_dir/dist"
dmg="$output_dir/CD-Explorer-$version.dmg"

cleanup() {
  /bin/rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$stage_dir" "$output_dir"
/bin/rm -f "$output_dir/CD-Explorer-$version.dmg" \
  "$output_dir/CD-Explorer-$version-Third-Party-Source.tar.gz" \
  "$output_dir/SHA256SUMS-$version.txt"

"$project_dir/build.sh"
/usr/bin/ditto "$project_dir/build/CD Explorer.app" "$stage_dir/CD Explorer.app"

# Keep the installer focused on the one required action. Full application and
# third-party licence texts remain bundled inside the app itself.
/opt/homebrew/bin/magick -size 640x360 gradient:'#eef4ff-#cadbf2' \
  -font '/System/Library/Fonts/SFNS.ttf' \
  -fill '#13284a' -gravity north -pointsize 32 -annotate +0+28 'CD Explorer' \
  -fill '#45658f' -pointsize 16 -annotate +0+70 'Drag the app to Applications' \
  -fill '#5e88c7' -stroke '#5e88c7' -strokewidth 4 -draw 'line 270,185 370,185' \
  -fill '#5e88c7' -stroke none -draw 'polygon 370,185 348,171 348,199' \
  "$background"

/opt/homebrew/bin/create-dmg \
  --volname "CD Explorer $version" \
  --volicon "$project_dir/build/CD Explorer.app/Contents/Resources/AppIcon.icns" \
  --background "$background" \
  --window-pos 180 120 \
  --window-size 640 360 \
  --icon-size 88 \
  --text-size 13 \
  --icon 'CD Explorer.app' 155 190 \
  --app-drop-link 485 190 \
  --hide-extension 'CD Explorer.app' \
  --no-internet-enable \
  "$dmg" "$stage_dir"

"$project_dir/Scripts/collect_third_party_source.sh" "$version" "$output_dir"

(
  cd "$output_dir"
  /usr/bin/shasum -a 256 "CD-Explorer-$version.dmg" \
    "CD-Explorer-$version-Third-Party-Source.tar.gz" > "SHA256SUMS-$version.txt"
)

"$project_dir/Scripts/verify_release.sh" "$version"

echo "Release files created in $output_dir"

