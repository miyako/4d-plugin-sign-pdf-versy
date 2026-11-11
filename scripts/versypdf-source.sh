# Sourced by build-macos-deps.sh and build-windows-deps.sh: the pinned
# VersyPDF source and the patches both platforms need.
#
# VersyPDF (github.com/sybrexsys/VersyPDF, no tags) at commit
# 9d67f26075eaf0d1eeded0c956796dd8c0ff99d2 (2019-05-18), the last commit
# before this plugin's libraries were built (release build-library-mac,
# 2020-03-10). The committed include/versypdf/*.h match that commit except for
# the encoding of comments and a Windows-only _CRT_SECURE_NO_DEPRECATE.
# It bundles its own zlib (flate), FreeType, libjpeg, libpng and libtiff.
#
# The committed headers in include/versypdf/ are not modified: the patches
# apply to the build tree only, each checked with grep. Works with BSD sed
# (macOS) and GNU sed (Git Bash on the Windows runner).

VERSY_SHA1=9d67f26075eaf0d1eeded0c956796dd8c0ff99d2
VERSY_URL=https://github.com/sybrexsys/VersyPDF/archive/$VERSY_SHA1.tar.gz
VERSY_SHA=88a1d90e4b1ab30ac212fc1b7b3110e55a6a1bf6115b29e49c94909d2138ec43
VERSY_TGZ=versypdf-$VERSY_SHA1.tar.gz

# the sources are cp1251 text: let sed and grep treat them as bytes
export LC_ALL=C

sha256_ok() { # <sha256> <file>
  if command -v sha256sum >/dev/null 2>&1; then
    echo "$1  $2" | sha256sum -c - >/dev/null 2>&1
  else
    echo "$1  $2" | shasum -a 256 -c - >/dev/null 2>&1
  fi
}

# versypdf_fetch <download dir>: download with retries, verify the checksum
versypdf_fetch() {
  local f="$1/$VERSY_TGZ" i
  mkdir -p "$1"
  sha256_ok "$VERSY_SHA" "$f" && return 0
  for i in 1 2 3; do
    curl -fsSL --retry 3 -o "$f.tmp" "$VERSY_URL" && break
    [ "$i" = 3 ] && { echo "::error::download failed: $VERSY_URL"; return 1; }
    echo "download failed, retrying"; sleep 10
  done
  sha256_ok "$VERSY_SHA" "$f.tmp" || { echo "::error::checksum mismatch: $VERSY_URL"; rm -f "$f.tmp"; return 1; }
  mv "$f.tmp" "$f"
}

# patch_file <file> <grep pattern that must match afterwards> <sed args...>
patch_file() {
  local f="$1" check="$2"; shift 2
  sed -i.orig "$@" "$f" && rm -f "$f.orig"
  grep -q -- "$check" "$f" || { echo "::error::patch did not apply: $f ($check)"; exit 1; }
}

# versypdf_unpack <download dir> <source dir>: fresh extraction plus the
# patches every platform needs; leaves S=<source dir>/sources
versypdf_unpack() {
  rm -rf "${2:?}"; mkdir -p "$2"
  # read from stdin: Git Bash's GNU tar treats an absolute "D:/..." archive
  # path as a remote host:path ("Cannot connect to D: resolve failed")
  # and extract inside the target dir so tar never sees a drive path at all
  ( cd "$2" && tar -xzf - --strip-components 1 ) < "$1/$VERSY_TGZ"
  S="$2/sources"

  # arm64: VSPlatform.h treats every Unix CPU other than i386/alpha/ia64/
  # x86_64 as big-endian, and enables PDFLARGEINT (ppInt32 = int instead of
  # long) only on 64-bit alpha/ia64/x86_64. On arm64 that made ppInt32 and
  # ppUns32 64-bit and byte-swapped every integer read/written as big-endian.
  # Add the arm64 macros to both tests (no effect on Windows, which takes its
  # own branch). The plugin defines PDFLARGEINT itself on arm64
  # (4DPlugin-VersyPDF.h), since it compiles the committed header.
  patch_file "$S/versypdf/VSPlatform.h" 'defined(__x86_64 ) || defined(__aarch64__)' \
    -e 's/defined(__x86_64 )$/defined(__x86_64 ) || defined(__aarch64__) || defined(__arm64__)/'
  patch_file "$S/versypdf/VSPlatform.h" 'defined(__x86_64) || defined(__aarch64__)' \
    -e 's/defined(__ia64) || defined(__x86_64)$/defined(__ia64) || defined(__x86_64) || defined(__aarch64__) || defined(__arm64__)/'

  # libtiff: tiffio.h includes "tiffredeff.h" (typo; the file is tiffredef.h,
  # which gives libtiff's symbols a vspdft_ prefix, as in both 2020 libraries).
  patch_file "$S/tiff/tiffio.h" '#include "tiffredef.h"' -e 's/#include "tiffredeff.h"/#include "tiffredef.h"/'

  # libpng 1.2's pngconf.h takes TARGET_OS_MAC for classic Mac OS and
  # includes <fp.h> (Carbon), which current SDKs no longer have.
  patch_file "$S/png/pngconf.h" '^#      include <math.h> /\* was <fp.h> \*/' \
    -e 's|^#      include <fp.h>|#      include <math.h> /* was <fp.h> */|'

  # A truncated or malformed file that starts with %PDF-1. crashed:
  # PDFDocLoadFromStream's error path frees CryptoInfo.Algorithms and
  # CryptoInfo.AlgList, which are only set after the cross-reference table
  # was read (uninitialised malloc memory before that).
  patch_file "$S/versypdf/sources/VSDocA.c" 'tmp->CryptoInfo.AlgList = NULL; /\* build-deps \*/' \
    -e 's/^\([[:space:]]*\)_CosNullNew (tmp, tmp->CryptoInfo.FileID);/&\
\1tmp->CryptoInfo.Algorithms = _CosNull(tmp); tmp->CryptoInfo.AlgList = NULL; \/* build-deps *\//'
  [ "$(grep -c 'build-deps' "$S/versypdf/sources/VSDocA.c")" = 1 ] || { echo "::error::VSDocA.c patch"; exit 1; }
  # ULCheckDocumentHeader dereferenced NULL when the first line has no '%',
  # and freed an interior pointer when '%' is not the first byte.
  patch_file "$S/versypdf/sources/VSXref.c" 'mfree ( _LIB, st1 ); /\* build-deps \*/' \
    -e '/^void ULCheckDocumentHeader(PDFDocHandle Doc)/,/^}/{
s/^\([[:space:]]*\)st = strchr(st,.%.);/\1st = strchr(st,'"'"'%'"'"'); if ( !st ) { mfree ( _LIB, st1 ); _RAISE ( ErrCosLevel, cleNoHeaderError ); }/
s/^\([[:space:]]*\)mfree ( _LIB, st );/\1mfree ( _LIB, st1 ); \/* build-deps *\//
}'
  [ "$(sed -n '/^void ULCheckDocumentHeader/,/^}/p' "$S/versypdf/sources/VSXref.c" | grep -c 'mfree ( _LIB, st1 )')" = 3 ] \
    || { echo "::error::VSXref.c patch"; exit 1; }
}
