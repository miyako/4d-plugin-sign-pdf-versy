#!/usr/bin/env bash
# Builds lib/windows64/libversypdf.lib, the static library VersyPDF.vcxproj
# links (Release|x64), from the pinned VersyPDF source in
# scripts/versypdf-source.sh (same pin, SHA-256 and shared patches as the
# macOS build). The old committed library was 198 LTCG (/GL) objects from
# v140, which no other toolset can link, and it lacked the load-crash fixes.
#
# Sources: every .c file under sources/ except tif_unix.c (tif_win32.c is
# the Windows port, compiled with WIN defined, as in the 2020 library) and
# VSTextOut.c (unreachable from the public headers; left out on macOS too).
# Defines: WIN32/_WINDOWS (VSPlatform.h's Windows branch) and the CRT
# warning switches, as upstream's bind/C/Windows/Compx64.bat; not DOTNET
# (that switches the PDFTRY macros to C++ exceptions, the plugin uses
# setjmp) and not PDFDLL (static library: LIB_API stays empty). ppInt32 is
# long there, 32-bit on Windows, as in the plugin's own compile.
#
# Usage (Git Bash on the windows-latest runner, MSVC + CMake on PATH):
#   scripts/build-windows-deps.sh <output .lib> [platform toolset, default v143]
# On a non-Windows host it only configures and builds the same source list
# with the local compiler (no Windows defines), to check the list and the
# patches; the output and the MSVC checks are skipped then.
set -euo pipefail

OUT_ARG="${1:?usage: $0 <output .lib> [toolset]}"
TOOLSET="${2:-v143}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/versypdf-source.sh"

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WINDOWS=1 ;; *) WINDOWS=0 ;; esac

TMPBASE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
# RUNNER_TEMP is a Windows path (D:\a\_temp); Git Bash's tar can't use it
command -v cygpath >/dev/null 2>&1 && TMPBASE="$(cygpath -u "$TMPBASE")"
WORK="$TMPBASE/versypdf-win-build"
mkdir -p "$WORK"
versypdf_fetch "$WORK/dl"
versypdf_unpack "$WORK/dl" "$WORK/src"   # sets S

# The CMake project lives in the source tree, listing files relative to it.
( cd "$S" && find . -name '*.c' ! -name tif_unix.c ! -name VSTextOut.c | sed 's|^\./||' | sort ) > "$WORK/sources.txt"
N="$(wc -l < "$WORK/sources.txt" | tr -d ' ')"
[ "$N" = 198 ] || { echo "::error::expected 198 sources, found $N"; exit 1; }
{
  echo 'cmake_minimum_required(VERSION 3.15)'
  echo 'project(versypdf C)'
  echo 'add_library(versypdf STATIC'
  sed 's/^/  /' "$WORK/sources.txt"
  echo ')'
  echo 'set_target_properties(versypdf PROPERTIES OUTPUT_NAME libversypdf)'
  echo 'target_include_directories(versypdf PRIVATE versypdf versypdf/sources flate freetype jpeg png tiff)'
  echo 'if(MSVC)'
  # WIN: tif_win32.c is wrapped in #ifdef WIN. /FIstring.h: many files call
  # memcpy/strlen/... without including it. /we4013: an implicit declaration
  # returns int, which would truncate pointers on x64, so it is an error.
  echo '  target_compile_definitions(versypdf PRIVATE WIN32 _WINDOWS WIN NDEBUG _CRT_SECURE_NO_WARNINGS _CRT_SECURE_NO_DEPRECATE _CRT_NONSTDC_NO_DEPRECATE)'
  echo '  target_compile_options(versypdf PRIVATE /FIstring.h /we4013)'
  echo 'else()'
  echo '  target_compile_definitions(versypdf PRIVATE NDEBUG)'
  echo '  target_compile_options(versypdf PRIVATE -include string.h -w -Werror=implicit-function-declaration -Werror=implicit-int)'
  echo 'endif()'
} > "$S/CMakeLists.txt"

rm -rf "${WORK:?}/build"
if [ "$WINDOWS" = 1 ]; then
  # Same toolset as the plugin (an older linker can't read newer objects),
  # static CRT (/MT) like the vcxproj Release|x64 config, no /GL.
  cmake -S "$S" -B "$WORK/build" -A x64 -T "$TOOLSET" \
    -DCMAKE_POLICY_DEFAULT_CMP0091=NEW \
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
  # --parallel, not "-- /m": Git Bash rewrites /-prefixed arguments as paths
  cmake --build "$WORK/build" --config Release --target versypdf --parallel
else
  cmake -S "$S" -B "$WORK/build" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$WORK/build" --target versypdf -j 8
  echo "non-Windows host: built the source list with $(cc --version | head -1); nothing copied to $OUT_ARG"
  exit 0
fi

LIB="$(find "$WORK/build" -iname 'libversypdf.lib' -ipath '*release*' | head -1)"
[ -n "$LIB" ] || { echo "::error::libversypdf.lib not found"; find "$WORK/build" -iname '*.lib'; exit 1; }
mkdir -p "$(dirname "$OUT_ARG")"
cp "$LIB" "$OUT_ARG"

# No LTCG objects (anonymous object header, Sig1 0 / Sig2 0xFFFF, Version >= 1),
# static CRT (C objects carry /DEFAULTLIB:LIBCMT, not MSVCRT), and the
# functions the plugin calls (x64 C names are undecorated).
PY=
for c in python python3; do "$c" -c 'import sys' >/dev/null 2>&1 && { PY="$c"; break; }; done
[ -n "$PY" ] || { echo "::error::python not found for the library check"; exit 1; }
"$PY" -I - "$OUT_ARG" <<'PY'
import re, sys
p = sys.argv[1]; d = open(p, 'rb').read()
assert d.startswith(b'!<arch>\n'), 'not an archive'
pos, members, ltcg = 8, 0, 0
while pos + 60 <= len(d):
    name = d[pos:pos + 16]; size = int(d[pos + 48:pos + 58].strip() or b'0')
    body = d[pos + 60:pos + 60 + size]
    if not (name.startswith(b'/ ') or name.startswith(b'// ')):
        members += 1
        if body[0:4] == b'\x00\x00\xff\xff' and int.from_bytes(body[4:6], 'little') >= 1:
            ltcg += 1
    pos += 60 + size + (size & 1)
bad = []
if ltcg: bad.append(f'{ltcg} LTCG objects')
low = d.lower()
if not re.search(rb'/defaultlib:"?libcmt', low): bad.append('no /DEFAULTLIB:LIBCMT (not /MT)')
if re.search(rb'/defaultlib:"?msvcrt', low): bad.append('/DEFAULTLIB:MSVCRT (built /MD)')
for s in ('InitPDFLibrary', 'DonePDFLibrary', 'PPGetLastError', 'VSGetErrorStr',
          'PPPushExceptionBuffer', 'PPPopExceptionBuffer', 'PPCallException',
          'PDFDocLoadFromBuffer', 'PDFDocAppendSignatureFromBuffer', 'PDFDocSaveToStream',
          'PDFDocClose', 'ULStreamMemNew', 'ULStreamGetSize', 'ULStreamSetPosition',
          'ULStreamReadBuffer', 'ULStreamClose'):
    if b'\x00' + s.encode() + b'\x00' not in d: bad.append('missing ' + s)
print(f'{p}: members={members} ltcg={ltcg}')
if bad:
    print('::error::' + '; '.join(bad)); sys.exit(1)
PY
echo "built $OUT_ARG (VersyPDF ${VERSY_SHA1:0:12}, $TOOLSET, /MT, no LTCG)"
