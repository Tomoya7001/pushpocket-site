#!/bin/bash
# F-105 / D-015 checks. Read-only.
#
#   check-lgpl.sh <RenPyLGPL.xcframework>
#     - exactly two slices: ios-arm64 (platform 2) and ios-arm64-simulator (platform 7)
#     - each binary: arm64 only (no x86_64), Mach-O MH_DYLIB, install name @rpath/RenPyLGPL.framework/RenPyLGPL
#     - linked libraries: only /usr/lib/*, /System/* and @rpath/SDL2.framework/SDL2
#     - undefined symbols: none from a non-system library except the declared SDL2 sibling, none flat-namespace
#     - every symbol in tools/renpy/required-exports.txt is exported
#   check-lgpl.sh --host-binary <Mach-O>
#     - the binary defines no LGPL symbol (FFmpeg, fribidi, pygame alphablit, SDL_gfx primitives)
set -euo pipefail
TOOL=$(cd "$(dirname "$0")" && pwd)
LGPL_RE=' _(av_|avcodec_|avformat_|avfilter_|avio_|avresample_|avutil_|swr_|sws_|swresample_|swscale_|fribidi_|pygame_AlphaBlit|pygame_Blit|pixelColor|pixelRGBA|lineRGBA|aalineRGBA|hlineRGBA|vlineRGBA|filledPolygonRGBA|roundedRectangleRGBA)'
fail() { echo "check-lgpl: FAIL $*" >&2; exit 1; }

if [ "${1:-}" = "--host-binary" ]; then
  bin=${2:?usage: check-lgpl.sh --host-binary <Mach-O>}
  [ -f "$bin" ] || fail "no such binary: $bin"
  n=$( (xcrun nm -U "$bin" 2>/dev/null || true) | grep -cE "$LGPL_RE" || true)
  [ "$n" = 0 ] || fail "$bin defines $n LGPL symbol(s), e.g. $(xcrun nm -U "$bin" | grep -E "$LGPL_RE" | head -3 | awk '{print $3}' | paste -sd' ' -)"
  echo "check-lgpl: OK $bin defines 0 LGPL symbols"
  exit 0
fi

xcf=${1:?usage: check-lgpl.sh <RenPyLGPL.xcframework> | --host-binary <Mach-O>}
[ -f "$xcf/Info.plist" ] || fail "$xcf: no Info.plist"
slices=$(cd "$xcf" && find . -mindepth 1 -maxdepth 1 -type d | sed 's#^\./##' | sort | paste -sd' ' -)
[ "$slices" = "ios-arm64 ios-arm64-simulator" ] || fail "$xcf: slices are '$slices', want 'ios-arm64 ios-arm64-simulator'"

required=$(grep -vE '^(#|$)' "$TOOL/required-exports.txt")
for slice in ios-arm64 ios-arm64-simulator; do
  bin="$xcf/$slice/RenPyLGPL.framework/RenPyLGPL"
  [ -f "$bin" ] || fail "$slice: no $bin"
  [ -f "$xcf/$slice/RenPyLGPL.framework/Info.plist" ] || fail "$slice: framework has no Info.plist"
  archs=$(lipo -archs "$bin")
  [ "$archs" = arm64 ] || fail "$slice: architectures '$archs', want 'arm64' only"
  ftype=$(otool -hv "$bin" | awk 'NR==4 {print $5}')
  [ "$ftype" = DYLIB ] || fail "$slice: Mach-O filetype '$ftype', want DYLIB (MH_DYLIB)"
  want_plat=2; [ "$slice" = ios-arm64-simulator ] && want_plat=7
  plat=$(otool -l "$bin" | awk '/LC_BUILD_VERSION/ {f=1} f && /platform/ {print $2; exit}')
  [ "$plat" = "$want_plat" ] || fail "$slice: LC_BUILD_VERSION platform '$plat', want $want_plat"
  id=$(otool -D "$bin" | sed -n 2p)
  [ "$id" = "@rpath/RenPyLGPL.framework/RenPyLGPL" ] || fail "$slice: install name '$id'"
  while read -r dep _; do
    case "$dep" in
      /usr/lib/*|/System/*|@rpath/SDL2.framework/SDL2) ;;
      *) fail "$slice: links non-system library $dep" ;;
    esac
  done < <(otool -L "$bin" | tail -n +3)
  undef=$(xcrun nm -m -u "$bin")
  flat=$(echo "$undef" | grep -c 'dynamically looked up' || true)
  [ "$flat" = 0 ] || fail "$slice: $flat flat-namespace (dynamically looked up) undefined symbol(s)"
  bad=$(echo "$undef" | grep -vE '\(from (libSystem|libz|libc\+\+|libobjc|SDL2)\)$' | grep -v '^$' || true)
  [ -z "$bad" ] || fail "$slice: undefined symbols from non-system libraries: $(echo "$bad" | head -5 | paste -sd';' -)"
  total=$(echo "$undef" | grep -c . || true)
  sdl=$(echo "$undef" | grep -c '(from SDL2)$' || true)
  exports=$(xcrun nm -gU "$bin" | awk '{print $3}' | sort -u)
  missing=$(comm -23 <(echo "$required" | sort -u) <(echo "$exports"))
  [ -z "$missing" ] || fail "$slice: required exports missing: $(echo "$missing" | head -5 | paste -sd' ' -)"
  nlgpl=$(xcrun nm -gU "$bin" | grep -cE "$LGPL_RE" || true)
  echo "check-lgpl: OK $slice arm64 DYLIB platform=$plat undefined=$total (non-system=0, SDL2 sibling=$sdl) lgpl-exports=$nlgpl required=$(echo "$required" | wc -l | tr -d ' ')/ok"
done
