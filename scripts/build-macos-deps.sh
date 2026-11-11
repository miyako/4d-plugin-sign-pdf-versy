#!/bin/bash
# Builds a/libversypdf.a, the static library the Xcode project links, as a
# universal (arm64 + x86_64) archive from pinned upstream source:
#   VersyPDF (github.com/sybrexsys/VersyPDF, no tags) at commit
#   9d67f26075eaf0d1eeded0c956796dd8c0ff99d2 (2019-05-18), the last commit
#   before this plugin's library was built (release build-library-mac,
#   2020-03-10). The committed include/versypdf/*.h match that commit except
#   for the encoding of comments and a Windows-only _CRT_SECURE_NO_DEPRECATE.
# It bundles its own zlib (flate), FreeType, libjpeg, libpng and libtiff,
# compiled from the same tree.
#
# The committed headers in include/versypdf/ are shared with the Windows
# build and are not modified: the patches below apply to the build tree only.
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

VERSY_SHA1=9d67f26075eaf0d1eeded0c956796dd8c0ff99d2
VERSY_URL=https://github.com/sybrexsys/VersyPDF/archive/$VERSY_SHA1.tar.gz
VERSY_SHA=88a1d90e4b1ab30ac212fc1b7b3110e55a6a1bf6115b29e49c94909d2138ec43

# keep Homebrew headers and libraries out of the build
unset CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH PKG_CONFIG_PATH || true
export MACOSX_DEPLOYMENT_TARGET="$MIN"
# the sources are cp1251 text: let sed treat them as bytes
export LC_ALL=C

mkdir -p "$WORK/dl" "$OUT"

# fetch <url> <sha256> <file>: download with retries, verify the checksum
fetch() {
  local f="$WORK/dl/$3" i
  if [ -f "$f" ] && echo "$2  $f" | shasum -a 256 -c - >/dev/null 2>&1; then
    return 0
  fi
  for i in 1 2 3; do
    curl -fsSL --retry 3 -o "$f.tmp" "$1" && break
    [ "$i" = 3 ] && { echo "::error::download failed: $1"; return 1; }
    echo "download $1 failed, retrying"; sleep 10
  done
  echo "$2  $f.tmp" | shasum -a 256 -c - || { echo "::error::checksum mismatch: $1"; rm -f "$f.tmp"; return 1; }
  mv "$f.tmp" "$f"
}

# patch_file <file> <grep -q pattern that must match afterwards> <sed args...>
patch_file() {
  local f="$1" check="$2"; shift 2
  sed -i '' "$@" "$f"
  grep -q -- "$check" "$f" || { echo "::error::patch did not apply: $f ($check)"; exit 1; }
}

fetch "$VERSY_URL" "$VERSY_SHA" "versypdf-$VERSY_SHA1.tar.gz"

SRC="$WORK/versypdf"
BLD="$WORK/versypdf-build"

if [ ! -f "$BLD/libversypdf.a" ]; then
  echo "::group::versypdf"
  rm -rf "${SRC:?}" "${BLD:?}"; mkdir -p "$SRC" "$BLD"
  tar -xzf "$WORK/dl/versypdf-$VERSY_SHA1.tar.gz" -C "$SRC" --strip-components 1
  S="$SRC/sources"

  # 1. arm64: VSPlatform.h treats every Unix CPU other than i386/alpha/ia64/
  #    x86_64 as big-endian, and enables PDFLARGEINT (ppInt32 = int instead
  #    of long) only on 64-bit alpha/ia64/x86_64. On arm64 that made ppInt32
  #    and ppUns32 64-bit and byte-swapped every integer read/written as
  #    big-endian. Add the arm64 macros to both tests. The plugin defines
  #    PDFLARGEINT itself on arm64 (4DPlugin-VersyPDF.h), since it compiles
  #    the committed header.
  patch_file "$S/versypdf/VSPlatform.h" 'defined(__x86_64 ) || defined(__aarch64__)' \
    -e 's/defined(__x86_64 )$/defined(__x86_64 ) || defined(__aarch64__) || defined(__arm64__)/' \
    -e 's/defined(__x86_64 )\r$/defined(__x86_64 ) || defined(__aarch64__) || defined(__arm64__)/'
  patch_file "$S/versypdf/VSPlatform.h" 'defined(__x86_64) || defined(__aarch64__)' \
    -e 's/defined(__ia64) || defined(__x86_64)$/defined(__ia64) || defined(__x86_64) || defined(__aarch64__) || defined(__arm64__)/' \
    -e 's/defined(__ia64) || defined(__x86_64)\r$/defined(__ia64) || defined(__x86_64) || defined(__aarch64__) || defined(__arm64__)/'

  # 2. libtiff in this fork is set up for Windows only (upstream's own
  #    project compiles tif_win32.c, not tif_unix.c). The 2020 Xcode build
  #    (versypdf.zip of release build-library-mac) fixed the header name
  #    typo, the extra TIFFClientOpen arguments of this fork and unistd.h for
  #    lseek/read/write. The first two are redone here: TIFFClientOpen in
  #    this fork takes an opaque first argument, (seek, size, close) in that
  #    order and three allocators, and no map/unmap procs, so the 2020 call
  #    (two NULLs appended) passed every procedure in the wrong slot; the
  #    call is rewritten to the fork's signature. Its #ifndef guards
  #    around tiffiop.h's _TIFFfree/_TIFFmalloc/_TIFFrealloc macros are NOT
  #    reused: they let tiffredef.h's renames win and left calls to the
  #    undefined vspdft__TIFFfree/... (implicit declarations). Without them
  #    tiffiop.h redefines the macros as upstream intends (per-TIFF
  #    allocators). The fallback allocators _TIFFmallocA/_TIFFfreeA/
  #    _TIFFreallocA exist only in tif_win32.c (GlobalAlloc), so tif_unix.c
  #    gets malloc-based ones.
  patch_file "$S/tiff/tiffio.h" '#include "tiffredef.h"' -e 's/#include "tiffredeff.h"/#include "tiffredef.h"/'
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

  # 2b. libpng 1.2's pngconf.h takes TARGET_OS_MAC for classic Mac OS and
  #     includes <fp.h> (Carbon), which current SDKs no longer have.
  patch_file "$S/png/pngconf.h" '^#      include <math.h> /\* was <fp.h> \*/' \
    -e 's|^#      include <fp.h>|#      include <math.h> /* was <fp.h> */|'

  # 3. A truncated or malformed file that starts with %PDF-1. crashed:
  #    PDFDocLoadFromStream's error path frees CryptoInfo.Algorithms and
  #    CryptoInfo.AlgList, which are only set after the cross-reference table
  #    was read (uninitialised malloc memory before that).
  patch_file "$S/versypdf/sources/VSDocA.c" 'tmp->CryptoInfo.AlgList = NULL; /\* build-macos-deps \*/' \
    -e 's/^\([[:space:]]*\)_CosNullNew (tmp, tmp->CryptoInfo.FileID);/&\
\1tmp->CryptoInfo.Algorithms = _CosNull(tmp); tmp->CryptoInfo.AlgList = NULL; \/* build-macos-deps *\//'
  #    ULCheckDocumentHeader dereferenced NULL when the first line has no '%',
  #    and freed an interior pointer when '%' is not the first byte.
  patch_file "$S/versypdf/sources/VSXref.c" 'mfree ( _LIB, st1 ); /\* build-macos-deps \*/' \
    -e '/^void ULCheckDocumentHeader(PDFDocHandle Doc)/,/^}/{
s/^\([[:space:]]*\)st = strchr(st,.%.);/\1st = strchr(st,'"'"'%'"'"'); if ( !st ) { mfree ( _LIB, st1 ); _RAISE ( ErrCosLevel, cleNoHeaderError ); }/
s/^\([[:space:]]*\)mfree ( _LIB, st );/\1mfree ( _LIB, st1 ); \/* build-macos-deps *\//
}'
  [ "$(sed -n '/^void ULCheckDocumentHeader/,/^}/p' "$S/versypdf/sources/VSXref.c" | grep -c 'mfree ( _LIB, st1 )')" = 3 ] \
    || { echo "::error::VSXref.c patch"; exit 1; }
  # (Windows line endings would defeat the anchors above; the checks fail then.)

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
