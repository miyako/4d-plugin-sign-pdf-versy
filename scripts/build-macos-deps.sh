#!/bin/bash
# Builds a/libversypdf.a, the static library the Xcode project links, as a
# universal (arm64 + x86_64) archive from the pinned VersyPDF source in
# scripts/versypdf-source.sh (pin and shared patches, also used by
# build-windows-deps.sh). The macOS-only patches are below.
#
# usage: scripts/build-macos-deps.sh [output-dir]   (default: a/)
# WORK (default build/deps) holds downloads and builds; a rerun reuses them.
# Needs: Xcode command line tools, curl.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/a}"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
WORK="${WORK:-$ROOT/build/deps}"
MIN="${MACOSX_DEPLOYMENT_TARGET:-11.5}"
JOBS="$(sysctl -n hw.ncpu)"

# keep Homebrew headers and libraries out of the build
unset CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH PKG_CONFIG_PATH || true
export MACOSX_DEPLOYMENT_TARGET="$MIN"

. "$ROOT/scripts/versypdf-source.sh"

mkdir -p "$WORK/dl" "$OUT"
versypdf_fetch "$WORK/dl"

SRC="$WORK/versypdf"
BLD="$WORK/versypdf-build"

if [ ! -f "$BLD/libversypdf.a" ]; then
  echo "::group::versypdf"
  rm -rf "${BLD:?}"; mkdir -p "$BLD"
  versypdf_unpack "$WORK/dl" "$SRC"   # sets S

  # macOS-only: libtiff in this fork is set up for Windows (tif_win32.c).
  # The 2020 Xcode build (versypdf.zip of release build-library-mac) fixed
  # the TIFFClientOpen call in tif_unix.c and added unistd.h. The call is
  # redone here: this fork's TIFFClientOpen takes an opaque first argument,
  # (seek, size, close) in that order and three allocators, and no map/unmap
  # procs (as tif_win32.c calls it); the 2020 fix (two NULLs appended)
  # passed every procedure in the wrong slot. The 2020 #ifndef guards around
  # tiffiop.h's _TIFFfree/_TIFFmalloc/_TIFFrealloc macros are NOT reused:
  # they let tiffredef.h's renames win and left calls to the undefined
  # vspdft__TIFFfree/... Without them tiffiop.h redefines the macros as
  # upstream intends (per-TIFF allocators). The fallback allocators
  # _TIFFmallocA/_TIFFfreeA/_TIFFreallocA exist only in tif_win32.c
  # (GlobalAlloc), so tif_unix.c gets malloc-based ones.
  patch_file "$S/tiff/tif_unix.c" '_tiffSeekProc, _tiffSizeProc, _tiffCloseProc, NULL, NULL, NULL);' \
    -e 's/TIFFClientOpen(name, mode,/TIFFClientOpen(NULL, name, mode,/' \
    -e 's/_tiffSeekProc, _tiffCloseProc, _tiffSizeProc,/_tiffSeekProc, _tiffSizeProc, _tiffCloseProc, NULL, NULL, NULL);/' \
    -e '/^[[:space:]]*_tiffMapProc, _tiffUnmapProc);$/d'
  grep -q 'TIFFClientOpen(NULL, name, mode,' "$S/tiff/tif_unix.c" || { echo "::error::tif_unix.c patch"; exit 1; }
  ! grep -q '_tiffMapProc, _tiffUnmapProc);' "$S/tiff/tif_unix.c" || { echo "::error::tif_unix.c patch"; exit 1; }
  patch_file "$S/tiff/tiffconf.h" '^#define HAVE_UNISTD_H 1' \
    -e 's/^#endif \/\* COMPRESSION_SUPPORT \*\//&\
#define HAVE_UNISTD_H 1/'
  cat >> "$S/tiff/tif_unix.c" <<'C'

/* build-macos-deps: fallback allocators (tif_win32.c has the Windows ones) */
tdata_t _TIFFmallocA(tsize_t s) { return (tdata_t)malloc((size_t)s); }
void _TIFFfreeA(tdata_t p) { free(p); }
tdata_t _TIFFreallocA(tdata_t p, tsize_t s) { return (tdata_t)realloc(p, (size_t)s); }
C
  grep -q '^void _TIFFfreeA(tdata_t p) { free(p); }' "$S/tiff/tif_unix.c" || { echo "::error::tif_unix.c patch"; exit 1; }

  # compile everything as fat objects; Apple's libtool archives them
  INC=()
  for d in versypdf versypdf/sources flate freetype jpeg png tiff; do INC+=(-I"$S/$d"); done
  # All .c files except VSTextOut.c, which upstream's own project
  # (bind/DotNet/2.0/versypdfsrc.vcproj) leaves out too: it is not reachable
  # from any public header and its operator table does not compile with
  # current clang (ppBool handlers in a table of void procedures).
  find "$S" -name '*.c' ! -name VSTextOut.c | sort > "$BLD/sources.txt"
  [ "$(wc -l < "$BLD/sources.txt")" -eq 199 ] || { echo "::error::expected 199 sources"; exit 1; }
  # object names: path below sources/ with / -> _ (no basename clashes then)
  # -include string.h: many VersyPDF files call memcpy/strlen/... without
  # including it (an implicit declaration is an error in current clang).
  # -w: hides ~200 legacy warnings (macro redefinitions in libtiff, shifts of
  # negative values, libtiff's lossless int<->pointer idioms). Errors stay
  # errors (incompatible function pointer types included), and the two
  # -Werror flags keep implicit declarations fatal.
  mkdir -p "$BLD/obj"
  cc1() {
    local f="$1" o
    o="$BLD/obj/$(echo "${f#"$S"/}" | sed 's/\.c$//' | tr / _).o"
    clang -arch arm64 -arch x86_64 -mmacosx-version-min="$MIN" -O2 -DNDEBUG -fPIC \
      -w -Werror=implicit-function-declaration -Werror=implicit-int \
      -include string.h \
      "${INC[@]}" -c "$f" -o "$o" || { echo "::error::compile failed: $f" >&2; return 1; }
  }
  # parallel compile ($JOBS lanes; bash 3.2 has no wait -n): lane k takes
  # every $JOBS-th source
  pids=()
  for k in $(seq 1 "$JOBS"); do
    ( awk -v k="$k" -v j="$JOBS" 'NR % j == k % j' "$BLD/sources.txt" |
        while read -r f; do cc1 "$f" || exit 1; done ) &
    pids+=($!)
  done
  fail=0
  for p in "${pids[@]}"; do wait "$p" || fail=1; done
  [ "$fail" = 0 ] || exit 1
  libtool -static -no_warning_for_no_symbols -o "$BLD/libversypdf.a" "$BLD"/obj/*.o
  echo "::endgroup::"
fi
cp "$BLD/libversypdf.a" "$OUT/libversypdf.a"

# the output must carry both slices, every object built for macOS $MIN or
# older (vtool reads no archives; otool -l does)
L="$OUT/libversypdf.a"
for A in arm64 x86_64; do
  lipo "$L" -verify_arch "$A" || { echo "::error::libversypdf.a lacks $A"; exit 1; }
  M="$(otool -arch "$A" -l "$L" | awk '$1=="minos"{print $2}' | sort -u)"
  [ -n "$M" ] || { echo "::error::libversypdf.a ($A): no minos"; exit 1; }
  for m in $M; do
    [ "$(printf '%s\n%s\n' "$m" "$MIN" | sort -V | tail -1)" = "$MIN" ] \
      || { echo "::error::libversypdf.a ($A) has minos $m > $MIN"; exit 1; }
  done
  echo "libversypdf.a $A: minos $(echo $M)"
done
echo "libversypdf.a: $(lipo -archs "$L")"
