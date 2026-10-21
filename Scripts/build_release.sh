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

mkdir -p "$stage_dir/Open Source Licences" "$output_dir"
/bin/rm -f "$output_dir/CD-Explorer-$version.dmg" \
  "$output_dir/CD-Explorer-$version-Third-Party-Source.tar.gz" \
  "$output_dir/SHA256SUMS-$version.txt"

"$project_dir/build.sh"
/usr/bin/ditto "$project_dir/build/CD Explorer.app" "$stage_dir/CD Explorer.app"
/bin/cp "$project_dir/LICENSE" "$stage_dir/Open Source Licences/CD Explorer GPLv3.txt"
/bin/cp "$project_dir/ThirdParty/THIRD_PARTY_NOTICES.md" "$stage_dir/Open Source Licences/"
/bin/cp "$project_dir/ThirdParty/DEPENDENCIES.md" "$stage_dir/Open Source Licences/"
/bin/cp "$project_dir/ThirdParty/MPVKit-LICENSE.txt" "$stage_dir/Open Source Licences/MPVKit LGPLv3.txt"
/bin/cp "$project_dir/BundledTools/COPYING.GPLv2" "$stage_dir/Open Source Licences/FFmpeg GPLv2.txt"
/bin/cp "$project_dir/BundledTools/COPYING.x264" "$stage_dir/Open Source Licences/x264 GPLv2.txt"

/usr/bin/printf '%s\n' \
  'CD Explorer' \
  '' \
  'Drag CD Explorer to Applications.' \
  '' \
  'Source code, documentation and issue tracking are available from the CD Explorer GitHub repository.' \
  'Licence information is included in the Open Source Licences folder.' \
  > "$stage_dir/Read Me.txt"

/opt/homebrew/bin/magick -size 720x460 gradient:'#13284a-#081426' \
  -font '/System/Library/Fonts/SFNS.ttf' \
  -fill '#f3f7ff' -gravity north -pointsize 34 -annotate +0+44 'CD Explorer' \
  -fill '#a9c7ff' -pointsize 17 -annotate +0+94 'Drag the app to Applications' \
  -fill '#5e88c7' -stroke '#5e88c7' -strokewidth 4 -draw 'line 300,245 420,245' \
  -fill '#5e88c7' -stroke none -draw 'polygon 420,245 396,230 396,260' \
  "$background"

/opt/homebrew/bin/create-dmg \
  --volname "CD Explorer $version" \
  --volicon "$project_dir/build/CD Explorer.app/Contents/Resources/AppIcon.icns" \
  --background "$background" \
  --window-pos 180 120 \
  --window-size 720 460 \
  --icon-size 112 \
  --text-size 13 \
  --icon 'CD Explorer.app' 170 250 \
  --app-drop-link 550 250 \
  --icon 'Open Source Licences' 270 370 \
  --icon 'Read Me.txt' 450 370 \
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

