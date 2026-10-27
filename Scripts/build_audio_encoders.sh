#!/bin/zsh
# Builds the universal (Apple silicon and Intel) MP3 and Opus encoders bundled
# with CD Explorer: LAME's `lame` and opus-tools' `opusenc`, statically linked so
# they depend only on macOS. Sources are fetched into .source-cache and checked
# against the SHA-256 values below.
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
cache_dir="$project_dir/.source-cache"
work=$(mktemp -d "/tmp/cd-explorer-audio-encoders.XXXXXX")
trap '/bin/rm -rf "$work"' EXIT
mkdir -p "$cache_dir"

typeset -A urls sums
urls[lame-3.100.tar.gz]='https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz'
urls[libogg-1.3.5.tar.gz]='https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz'
urls[opus-1.5.2.tar.gz]='https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz'
urls[libopusenc-0.2.1.tar.gz]='https://downloads.xiph.org/releases/opus/libopusenc-0.2.1.tar.gz'
urls[opusfile-0.12.tar.gz]='https://downloads.xiph.org/releases/opus/opusfile-0.12.tar.gz'
urls[opus-tools-0.2.tar.gz]='https://downloads.xiph.org/releases/opus/opus-tools-0.2.tar.gz'
sums_file="$script_dir/audio_encoder_sources.sha256"

for name in ${(k)urls}; do
  [[ -f "$cache_dir/$name" ]] || /usr/bin/curl -fL --retry 3 "${urls[$name]}" -o "$cache_dir/$name"
done
(cd "$cache_dir" && /usr/bin/shasum -a 256 -c "$sums_file")

jobs=$(/usr/sbin/sysctl -n hw.ncpu)
sdk=$(/usr/bin/xcrun --show-sdk-path)

build_arch() {
  local arch=$1 host=$2
  local prefix="$work/$arch/prefix"
  mkdir -p "$work/$arch/src" "$prefix"
  export CC="/usr/bin/clang -arch $arch -isysroot $sdk -mmacosx-version-min=13.0"
  export CFLAGS="-O2" CPPFLAGS="-I$prefix/include" LDFLAGS="-L$prefix/lib"
  export PKG_CONFIG_PATH="$prefix/lib/pkgconfig" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  local common=(--host="$host" --prefix="$prefix" --disable-shared --enable-static)
  for name in lame-3.100 libogg-1.3.5 opus-1.5.2 libopusenc-0.2.1 opusfile-0.12 opus-tools-0.2; do
    /usr/bin/tar -xzf "$cache_dir/$name.tar.gz" -C "$work/$arch/src"
  done
  (cd "$work/$arch/src/lame-3.100" && ./configure $common --disable-decoder --disable-gtktest >/dev/null \
    && make -j$jobs >/dev/null && make install >/dev/null)
  (cd "$work/$arch/src/libogg-1.3.5" && ./configure $common >/dev/null && make -j$jobs >/dev/null && make install >/dev/null)
  (cd "$work/$arch/src/opus-1.5.2" && ./configure $common --disable-doc --disable-extra-programs >/dev/null \
    && make -j$jobs >/dev/null && make install >/dev/null)
  (cd "$work/$arch/src/libopusenc-0.2.1" && ./configure $common --disable-doc --disable-examples >/dev/null \
    && make -j$jobs >/dev/null && make install >/dev/null)
  (cd "$work/$arch/src/opusfile-0.12" && ./configure $common --disable-http --disable-doc --disable-examples >/dev/null \
    && make -j$jobs >/dev/null && make install >/dev/null)
  (cd "$work/$arch/src/opus-tools-0.2" && ./configure $common --without-flac >/dev/null \
    && make -j$jobs opusenc >/dev/null && cp opusenc "$prefix/bin/opusenc")
}

build_arch arm64 aarch64-apple-darwin
build_arch x86_64 x86_64-apple-darwin

for tool in lame opusenc; do
  /usr/bin/lipo -create "$work/arm64/prefix/bin/$tool" "$work/x86_64/prefix/bin/$tool" \
    -output "$project_dir/BundledTools/$tool"
  /usr/bin/strip -x "$project_dir/BundledTools/$tool"
done
/bin/cp "$work/arm64/src/lame-3.100/COPYING" "$project_dir/BundledTools/COPYING.LAME"
{
  echo "opus-tools 0.2"; echo; cat "$work/arm64/src/opus-tools-0.2/COPYING"
  echo; echo "Opus 1.5.2"; echo; cat "$work/arm64/src/opus-1.5.2/COPYING"
  echo; echo "libopusenc 0.2.1"; echo; cat "$work/arm64/src/libopusenc-0.2.1/COPYING"
  echo; echo "opusfile 0.12"; echo; cat "$work/arm64/src/opusfile-0.12/COPYING"
  echo; echo "libogg 1.3.5"; echo; cat "$work/arm64/src/libogg-1.3.5/COPYING"
} > "$project_dir/BundledTools/COPYING.Opus"
echo "Built $project_dir/BundledTools/lame and $project_dir/BundledTools/opusenc"
