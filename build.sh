#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
build_dir="$project_dir/build"
app_dir="$build_dir/CD Explorer.app"
contents="$app_dir/Contents"
iconset="$project_dir/Assets.xcassets/AppIcon.appiconset"

if [[ -d "$app_dir" ]]; then
  /bin/rm -rf "$app_dir"
fi

mkdir -p "$build_dir" "$contents/MacOS" "$contents/Resources" "$iconset"

for tool in ffmpeg ffprobe; do
  if [[ ! -x "$project_dir/BundledTools/$tool" ]]; then
    echo "Missing bundled tool: $project_dir/BundledTools/$tool" >&2
    exit 1
  fi
done

if [[ ! -f "$iconset/icon_512x512@2x.png" || "$project_dir/AppIcon.png" -nt "$iconset/icon_512x512@2x.png" ]]; then
  for spec in '16 16x16' '32 16x16@2x' '32 32x32' '64 32x32@2x' '128 128x128' '256 128x128@2x' '256 256x256' '512 256x256@2x' '512 512x512' '1024 512x512@2x'; do
    pixels=${spec%% *}
    name=${spec#* }
    /opt/homebrew/bin/magick -background none "$project_dir/AppIcon.png" -resize "${pixels}x${pixels}" -depth 8 \
      -type TrueColorAlpha -define png:color-type=6 "$iconset/icon_${name}.png"
  done
fi
/usr/bin/xcrun actool --compile "$contents/Resources" --platform macosx \
  --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist "$build_dir/asset-info.plist" "$project_dir/Assets.xcassets"

/usr/bin/swift build --package-path "$project_dir" -c release --arch arm64 --arch x86_64
swift_bin_dir=$(/usr/bin/swift build --package-path "$project_dir" -c release \
  --arch arm64 --arch x86_64 --show-bin-path)
/bin/cp "$swift_bin_dir/CDExplorer" "$contents/MacOS/CDExplorer"
/bin/cp "$project_dir/Info.plist" "$contents/Info.plist"
mkdir -p "$contents/Resources/Tools" "$contents/Resources/FFmpeg" "$contents/Resources/Open Source Licences"
/bin/cp "$project_dir/BundledTools/ffmpeg" "$contents/Resources/Tools/ffmpeg"
/bin/cp "$project_dir/BundledTools/ffprobe" "$contents/Resources/Tools/ffprobe"
# MP3 (LAME) and Opus (opusenc) encoders, built by Scripts/build_audio_encoders.sh.
for tool in lame opusenc; do
  if [[ -x "$project_dir/BundledTools/$tool" ]]; then
    /bin/cp "$project_dir/BundledTools/$tool" "$contents/Resources/Tools/$tool"
  else
    echo "Warning: BundledTools/$tool is missing; run Scripts/build_audio_encoders.sh for MP3 and Opus output." >&2
  fi
done
for notice in COPYING.LAME COPYING.Opus; do
  if [[ -f "$project_dir/BundledTools/$notice" ]]; then
    /bin/cp "$project_dir/BundledTools/$notice" "$contents/Resources/Open Source Licences/$notice.txt"
  fi
done
/bin/chmod 755 "$contents/Resources/Tools/ffmpeg" "$contents/Resources/Tools/ffprobe"
/bin/cp "$project_dir/BundledTools/FFmpeg-NOTICE.txt" "$contents/Resources/FFmpeg/FFmpeg-NOTICE.txt"
/bin/cp "$project_dir/BundledTools/COPYING.GPLv2" "$contents/Resources/FFmpeg/COPYING.GPLv2"
/bin/cp "$project_dir/BundledTools/COPYING.x264" "$contents/Resources/FFmpeg/COPYING.x264"
/bin/cp "$project_dir/LICENSE" "$contents/Resources/Open Source Licences/CD Explorer GPLv3.txt"
/bin/cp "$project_dir/ThirdParty/THIRD_PARTY_NOTICES.md" "$contents/Resources/Open Source Licences/THIRD_PARTY_NOTICES.md"
/bin/cp "$project_dir/ThirdParty/DEPENDENCIES.md" "$contents/Resources/Open Source Licences/DEPENDENCIES.md"
/bin/cp "$project_dir/ThirdParty/MPVKit-LICENSE.txt" "$contents/Resources/Open Source Licences/MPVKit LGPLv3.txt"
/usr/bin/codesign --force --sign - "$contents/Resources/Tools/ffmpeg"
/usr/bin/codesign --force --sign - "$contents/Resources/Tools/ffprobe"
for tool in lame opusenc; do
  if [[ -f "$contents/Resources/Tools/$tool" ]]; then
    /usr/bin/codesign --force --sign - "$contents/Resources/Tools/$tool"
  fi
done
/usr/bin/codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
