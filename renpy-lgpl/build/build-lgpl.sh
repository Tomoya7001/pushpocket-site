#!/bin/bash
# F-105 stage B (decision D-015): build RenPyLGPL.xcframework FROM SOURCE.
#
# The LGPL parts of Ren'Py 8.5.3 (FFmpeg 4.3.1 + 2 renpy patches, fribidi 1.0.7, and the two LGPL C files
# of renpy.pygame: alphablit.c, SDL_gfxPrimitives.c) go into ONE separate, relinkable dynamic framework.
# libaom 3.5.0 (BSD-2-Clause, AV1 decoder used by libavcodec) is linked statically inside it.
# SDL2 (zlib) is NOT built here: the framework imports its SDL symbols from @rpath/SDL2.framework/SDL2
# through a generated .tbd stub (the real SDL2.framework is embedded by the app, a later stage).
#
# Output: third_party/renpy-ios/RenPyLGPL.xcframework with two slices, both arm64 only, MH_DYLIB:
#   ios-arm64 (iphoneos, platform 2) and ios-arm64-simulator (iphonesimulator, platform 7).
# Inputs: tools/renpy/inputs.lock (url + sha256), cached in build/renpy-lgpl/cache.
# Work:   build/renpy-lgpl/work (wiped per run); the xcframework is assembled in a temp dir under
#         build/renpy-lgpl and moved into place only when it is complete and verified.
# Stamp:  third_party/renpy-ios/BUILD-INPUTS.sha256 = sha256 of this script + inputs.lock + check-lgpl.sh.
#         With a matching stamp and output the run is a no-op ("up to date"). --force rebuilds.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TOOL="$ROOT/tools/renpy"
LOCK="$TOOL/inputs.lock"
BASE="$ROOT/build/renpy-lgpl"
CACHE="$BASE/cache"
WORK="$BASE/work"
OUT_DIR="$ROOT/third_party/renpy-ios"
OUT="$OUT_DIR/RenPyLGPL.xcframework"
STAMP="$OUT_DIR/BUILD-INPUTS.sha256"
MINOS=14.0
JOBS=$(sysctl -n hw.ncpu)
export ZERO_AR_DATE=1 LC_ALL=C

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

die() { echo "renpy-lgpl: FAIL $*" >&2; exit 1; }

stamp_value() {
  cat "$0" "$LOCK" "$TOOL/check-lgpl.sh" | shasum -a 256 | cut -d' ' -f1
}

if [ "$FORCE" = 0 ] && [ -d "$OUT" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$(stamp_value)" ]; then
  "$TOOL/check-lgpl.sh" "$OUT" >/dev/null || die "existing $OUT fails check-lgpl.sh (rerun with --force)"
  echo "renpy-lgpl: up to date ($OUT)"
  exit 0
fi

for tool in curl shasum cmake pkg-config perl xcrun xcodebuild patch; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done

# 1) Fetch + verify every pinned input. Nothing is read from anywhere else.
mkdir -p "$CACHE"
input() { # name -> cached path (checked)
  local name=$1 line sha url f
  line=$(grep -E "^$name " "$LOCK") || die "input $name not in $LOCK"
  sha=$(echo "$line" | cut -d' ' -f2); url=$(echo "$line" | cut -d' ' -f3)
  f="$CACHE/$name"
  if [ ! -f "$f" ] || [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" != "$sha" ]; then
    rm -f "$f" "$f.part"
    echo "renpy-lgpl: fetch $url" >&2
    curl -fsSL --retry 3 -o "$f.part" "$url" || die "download failed: $url"
    local got; got=$(shasum -a 256 "$f.part" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || { rm -f "$f.part"; die "checksum mismatch for $name: expected $sha, got $got ($url)"; }
    mv "$f.part" "$f"
  fi
  echo "$f"
}
while read -r name _; do
  case "$name" in ''|'#'*) continue ;; esac
  input "$name" >/dev/null
done < "$LOCK"

rm -rf "$WORK"
mkdir -p "$WORK"

# 2) Unpack once (sources are per-slice copies so the two builds cannot share state).
unpack_sources() { # dir
  local d=$1
  mkdir -p "$d"
  tar -xzf "$(input ffmpeg-4.3.1.tar.gz)" -C "$d"
  (cd "$d/ffmpeg-4.3.1" \
    && patch -p1 --forward --quiet < "$(input ffmpeg-4.3.1-sse.diff)" \
    && patch -p1 --forward --quiet < "$(input ffmpeg-4.3.1-ff_seek_frame_binary.diff)") || die "ffmpeg patches do not apply"
  tar -xjf "$(input fribidi-1.0.7.tar.bz2)" -C "$d"
  tar -xzf "$(input libaom-3.5.0.tar.gz)" -C "$d"
  tar -xzf "$(input SDL2-2.0.20.tar.gz)" -C "$d" SDL2-2.0.20/include
  mkdir -p "$d/renpy/pygame"
  for f in alphablit.c surface.h SDL_gfxPrimitives.c SDL_gfxPrimitives.h SDL_gfxPrimitives_font.h; do
    cp "$(input "renpy-$f")" "$d/renpy/pygame/$f"
  done
}

# FFmpeg configuration of renpy-build tasks/ffmpeg.py (ios), with --disable-programs added
# (the ffmpeg/ffplay executables are not shipped; the libraries are unchanged).
FFMPEG_FEATURES=(
  --enable-pic --enable-static --disable-shared
  --disable-all --disable-everything
  --enable-cross-compile --enable-runtime-cpudetect
  --disable-mmx --disable-mmxext
  --disable-programs --disable-doc
  --enable-avcodec --enable-avformat --enable-swresample --enable-swscale --enable-avfilter --enable-avresample
  --enable-libaom --disable-bzlib
  --enable-demuxer=au --enable-demuxer=avi --enable-demuxer=flac --enable-demuxer=m4v --enable-demuxer=matroska
  --enable-demuxer=mov --enable-demuxer=mp3 --enable-demuxer=mpegps --enable-demuxer=mpegts --enable-demuxer=mpegtsraw
  --enable-demuxer=mpegvideo --enable-demuxer=ogg --enable-demuxer=wav --enable-demuxer=av1
  --enable-decoder=flac --enable-decoder=mp2 --enable-decoder=mp3 --enable-decoder=mp3on4
  --enable-decoder=mpeg1video --enable-decoder=mpeg2video --enable-decoder=mpegvideo
  --enable-decoder=msmpeg4v1 --enable-decoder=msmpeg4v2 --enable-decoder=msmpeg4v3 --enable-decoder=mpeg4
  --enable-decoder=pcm_dvd --enable-decoder=pcm_s16be --enable-decoder=pcm_s16le --enable-decoder=pcm_s8
  --enable-decoder=pcm_u16be --enable-decoder=pcm_u16le --enable-decoder=pcm_u8
  --enable-decoder=theora --enable-decoder=vorbis --enable-decoder=opus --enable-decoder=vp3
  --enable-decoder=vp8 --enable-decoder=vp9 --enable-decoder=libaom_av1
  --enable-parser=mpegaudio --enable-parser=mpegvideo --enable-parser=mpeg4video --enable-parser=vp3
  --enable-parser=vp8 --enable-parser=vp9 --enable-parser=av1
  --disable-iconv --disable-alsa --disable-libxcb --disable-lzma --disable-sndio --disable-xlib
  --disable-amf --disable-audiotoolbox --disable-cuda-llvm --disable-d3d11va --disable-dxva2 --disable-ffnvcodec
  --disable-nvdec --disable-nvenc --disable-v4l2-m2m --disable-vaapi --disable-vdpau --disable-videotoolbox
)
FORCE_LOAD_LIBS=(libfribidi libavformat libavcodec libavfilter libavresample libswresample libswscale libavutil)

build_slice() { # sdk target platform-name
  local sdk=$1 target=$2 plat=$3
  local W="$WORK/$sdk" sysroot cc cflags prefix
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  cc=$(xcrun --sdk "$sdk" -f clang)
  cflags="-target $target -isysroot $sysroot -O2 -fPIC"
  prefix="$W/prefix"
  echo "renpy-lgpl: [$sdk] unpack" >&2
  unpack_sources "$W/src"

  echo "renpy-lgpl: [$sdk] libaom 3.5.0 (decoder only, static)" >&2
  cmake -S "$W/src/libaom-3.5.0" -B "$W/aom-build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$MINOS \
    -DCMAKE_C_COMPILER="$cc" -DCMAKE_CXX_COMPILER="$(xcrun --sdk "$sdk" -f clang++)" \
    -DCMAKE_C_FLAGS="-target $target" -DCMAKE_CXX_FLAGS="-target $target" -DCMAKE_ASM_FLAGS="-target $target" \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DBUILD_SHARED_LIBS=0 -DAOM_TARGET_CPU=arm64 \
    -DCONFIG_AV1_ENCODER=0 -DENABLE_EXAMPLES=0 -DENABLE_TOOLS=0 -DENABLE_TESTS=0 -DENABLE_DOCS=0 \
    -DCONFIG_PIC=1 -DCONFIG_RUNTIME_CPU_DETECT=0 >"$W/aom-configure.log" 2>&1 || die "libaom configure ($W/aom-configure.log)"
  cmake --build "$W/aom-build" -j "$JOBS" >"$W/aom-build.log" 2>&1 || die "libaom build ($W/aom-build.log)"
  cmake --install "$W/aom-build" >>"$W/aom-build.log" 2>&1 || die "libaom install ($W/aom-build.log)"

  echo "renpy-lgpl: [$sdk] fribidi 1.0.7 (static)" >&2
  (cd "$W/src/fribidi-1.0.7" && ./configure --host=aarch64-apple-darwin --prefix="$prefix" \
      --disable-shared --enable-static --disable-docs CC="$cc" CFLAGS="$cflags" LDFLAGS="$cflags" \
    && make -j "$JOBS" -C lib && make -C lib install && make install-pkgconfigDATA) >"$W/fribidi.log" 2>&1 \
    || die "fribidi build ($W/fribidi.log)"

  echo "renpy-lgpl: [$sdk] FFmpeg 4.3.1 (static, LGPL configuration)" >&2
  (cd "$W/src/ffmpeg-4.3.1" && PKG_CONFIG_PATH="$prefix/lib/pkgconfig" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" \
    ./configure --prefix="$prefix" --arch=aarch64 --target-os=darwin \
      --cc="$cc" --cxx="$(xcrun --sdk "$sdk" -f clang++)" --ld="$cc" \
      --ar="$(xcrun --sdk "$sdk" -f ar)" --ranlib="$(xcrun --sdk "$sdk" -f ranlib)" \
      --nm="$(xcrun --sdk "$sdk" -f nm)" --strip="$(xcrun --sdk "$sdk" -f strip)" \
      --pkg-config=pkg-config --pkg-config-flags=--static \
      --extra-cflags="$cflags" --extra-cxxflags="$cflags" --extra-ldflags="$cflags" \
      "${FFMPEG_FEATURES[@]}" \
    && make -j "$JOBS" && make install) >"$W/ffmpeg.log" 2>&1 || die "FFmpeg build ($W/ffmpeg.log)"
  # LGPL-2.1 only: GPL, nonfree and version3 (LGPLv3) must all be off.
  for flag in GPL NONFREE VERSION3; do
    grep -q "^#define CONFIG_$flag 0\$" "$W/src/ffmpeg-4.3.1/config.h" || die "FFmpeg CONFIG_$flag is not 0"
  done

  echo "renpy-lgpl: [$sdk] renpy.pygame LGPL objects" >&2
  mkdir -p "$W/obj"
  for f in alphablit SDL_gfxPrimitives; do
    "$cc" $cflags -std=gnu99 -I "$W/src/renpy" -I "$W/src/SDL2-2.0.20/include" \
      -c "$W/src/renpy/pygame/$f.c" -o "$W/obj/$f.o" || die "compile $f.c"
  done

  # SDL2 import stub: exactly the SDL symbols the two objects use, from @rpath/SDL2.framework/SDL2.
  local syms
  syms=$(xcrun nm -u "$W/obj/alphablit.o" "$W/obj/SDL_gfxPrimitives.o" | grep -E '^_SDL_' | sort -u | paste -sd, - | sed 's/,/, /g')
  [ -n "$syms" ] || die "no SDL imports found (unexpected)"
  mkdir -p "$W/stub/SDL2.framework"
  cat >"$W/stub/SDL2.framework/SDL2.tbd" <<EOF
--- !tapi-tbd
tbd-version:     4
targets:         [ $plat ]
install-name:    '@rpath/SDL2.framework/SDL2'
exports:
  - targets:         [ $plat ]
    symbols:         [ $syms ]
...
EOF

  echo "renpy-lgpl: [$sdk] link RenPyLGPL.framework" >&2
  local fw="$W/out/RenPyLGPL.framework" loads=()
  mkdir -p "$fw"
  for l in "${FORCE_LOAD_LIBS[@]}"; do
    [ -f "$prefix/lib/$l.a" ] || die "missing $prefix/lib/$l.a"
    loads+=("-Wl,-force_load,$prefix/lib/$l.a")
  done
  "$cc" $cflags -dynamiclib -o "$fw/RenPyLGPL" \
    -install_name @rpath/RenPyLGPL.framework/RenPyLGPL -compatibility_version 1 -current_version 1 \
    "$W/obj/alphablit.o" "$W/obj/SDL_gfxPrimitives.o" "${loads[@]}" "$prefix/lib/libaom.a" \
    -F "$W/stub" -framework SDL2 -lz -lm >"$W/link.log" 2>&1 || die "link ($W/link.log)"
  xcrun strip -x "$fw/RenPyLGPL"
  local platname
  if [ "$sdk" = iphoneos ]; then platname=iPhoneOS; else platname=iPhoneSimulator; fi
  cat >"$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>RenPyLGPL</string>
	<key>CFBundleIdentifier</key>
	<string>com.pushpocket.RenPyLGPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>RenPyLGPL</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>8.5.3</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>$platname</string>
	</array>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>MinimumOSVersion</key>
	<string>$MINOS</string>
</dict>
</plist>
EOF
}

build_slice iphoneos "arm64-apple-ios$MINOS" arm64-ios
build_slice iphonesimulator "arm64-apple-ios$MINOS-simulator" arm64-ios-simulator

# 3) Assemble in a temp dir, verify, then swap into place atomically.
TMP=$(mktemp -d "$BASE/out.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
xcodebuild -create-xcframework \
  -framework "$WORK/iphoneos/out/RenPyLGPL.framework" \
  -framework "$WORK/iphonesimulator/out/RenPyLGPL.framework" \
  -output "$TMP/RenPyLGPL.xcframework" >"$WORK/xcframework.log" 2>&1 || die "create-xcframework ($WORK/xcframework.log)"
"$TOOL/check-lgpl.sh" "$TMP/RenPyLGPL.xcframework" || die "new xcframework fails check-lgpl.sh"
mkdir -p "$OUT_DIR"
if [ -d "$OUT" ]; then mv "$OUT" "$TMP/old"; fi
mv "$TMP/RenPyLGPL.xcframework" "$OUT"
stamp_value >"$STAMP"
echo "renpy-lgpl: built $OUT"
