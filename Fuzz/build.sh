#!/usr/bin/env bash
# Build the fuzz harnesses for the two C parsers that read untrusted FITS bytes:
# the CFITSIO shim (HelioFITSExtension/cfitsio/fitsshim.c, linked into every
# HelioFITS target) and the Spotlight importer's header reader
# (FITSMetadataImporter/fits_header.c). CFITSIO itself is built from the tarball
# whose version and SHA-256 build-universal.sh pins, with the same sanitizers.
#
#   bash Fuzz/build.sh                          # libFuzzer + ASan (Linux clang, or Homebrew llvm on macOS)
#   FUZZ_ENGINE=standalone bash Fuzz/build.sh   # ASan only, runs given inputs once (Apple clang works)
#   FUZZ_CANARY=1 bash Fuzz/build.sh            # adds a deliberate out-of-bounds read (verification only)
#   CC=clang-18 bash Fuzz/build.sh              # pick the compiler
#   bash Fuzz/build.sh fits_header_fuzz         # build only the named harness(es); the
#                                               # importer harness needs no CFITSIO
#
# Everything lands in Fuzz/out/ (git-ignored): the harness binaries
# Fuzz/out/fitsshim_fuzz and Fuzz/out/fits_header_fuzz, the CFITSIO build, and
# Fuzz/out/corpus/<harness>/ seeded from HelioFITSTests/Fixtures/*.fits and
# Fuzz/regressions/<harness>/*. Nothing outside Fuzz/out/ is written.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
ROOT="$PWD"
OUT="$ROOT/Fuzz/out"
CC="${CC:-clang}"
ENGINE="${FUZZ_ENGINE:-libfuzzer}"
UNIVERSAL="HelioFITSExtension/cfitsio/build-universal.sh"
SHIM_DIR="$ROOT/HelioFITSExtension/cfitsio"
IMPORTER_DIR="$ROOT/FITSMetadataImporter"
HARNESSES="${*:-fitsshim_fuzz fits_header_fuzz}"
for h in $HARNESSES; do
  case "$h" in fitsshim_fuzz|fits_header_fuzz) ;; *) echo "error: unknown harness '$h'" >&2; exit 2 ;; esac
done
wants() { case " $HARNESSES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
stamp() { date -u +%Y%m%dT%H%M%SZ; }

case "$ENGINE" in
  libfuzzer)  SAN_COMPILE="-fsanitize=fuzzer-no-link,address"; SAN_LINK="-fsanitize=fuzzer,address"; DRIVER="" ;;
  standalone) SAN_COMPILE="-fsanitize=address"; SAN_LINK="-fsanitize=address"; DRIVER="$ROOT/Fuzz/standalone_main.c" ;;
  *) echo "error: FUZZ_ENGINE must be libfuzzer or standalone, got '$ENGINE'" >&2; exit 2 ;;
esac
CFLAGS_FUZZ="-g -O1 -fno-omit-frame-pointer $SAN_COMPILE"
DEFS=""
if [ "${FUZZ_CANARY:-}" = "1" ]; then DEFS="-DFUZZ_CANARY"; fi

mkdir -p "$OUT"
if wants fitsshim_fuzz; then
  # Version, checksum and configure options come from the one script that builds
  # the shipped library, so the fuzzed CFITSIO is the shipped CFITSIO.
  CFITSIO_VERSION="$(sed -n 's/^CFITSIO_VERSION="\(.*\)"/\1/p' "$UNIVERSAL")"
  CFITSIO_SHA256="$(sed -n 's/^CFITSIO_SHA256="\(.*\)"/\1/p' "$UNIVERSAL")"
  CONFIGURE_OPTS="$(sed -n 's/^CONFIGURE_OPTS="\([^"]*\)".*/\1/p' "$UNIVERSAL")"
  if [ -z "$CFITSIO_VERSION" ] || [ -z "$CFITSIO_SHA256" ]; then
    echo "error: CFITSIO_VERSION or CFITSIO_SHA256 missing from $UNIVERSAL (HF-6 pins both)" >&2
    exit 2
  fi

  tarball="$OUT/cfitsio-$CFITSIO_VERSION.tar.gz"
  if [ ! -f "$tarball" ]; then
    echo "==> fetching CFITSIO $CFITSIO_VERSION"
    curl -fsSL -o "$tarball.part" \
      "https://heasarc.gsfc.nasa.gov/FTP/software/fitsio/c/cfitsio-$CFITSIO_VERSION.tar.gz"
    mv "$tarball.part" "$tarball"
  fi
  if ! echo "$CFITSIO_SHA256  $tarball" | shasum -a 256 -c - >/dev/null; then
    bad="$tarball.mismatch-$(stamp)"
    got="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
    mv "$tarball" "$bad"
    echo "error: CFITSIO tarball does not match CFITSIO_SHA256; kept as $bad" >&2
    echo "       pinned   $CFITSIO_SHA256" >&2
    echo "       computed $got" >&2
    exit 3
  fi

  src="$OUT/cfitsio-$CFITSIO_VERSION-$ENGINE-$(uname -s)"   # Linux and macOS builds can share Fuzz/out
  lib="$src/.libs/libcfitsio.a"
  if [ ! -f "$lib" ]; then
    if [ -d "$src" ]; then mv "$src" "$src.incomplete-$(stamp)"; fi
    echo "==> building CFITSIO $CFITSIO_VERSION ($ENGINE)"
    mkdir -p "$src"
    tar xzf "$tarball" -C "$src" --strip-components=1
    ( cd "$src"
      CC="$CC" CFLAGS="$CFLAGS_FUZZ" ./configure $CONFIGURE_OPTS >/dev/null
      make -j"$(getconf _NPROCESSORS_ONLN)" libcfitsio.la >/dev/null )
  fi
fi

echo "==> building harnesses ($ENGINE${DEFS:+, canary})"
if wants fitsshim_fuzz; then
  "$CC" $CFLAGS_FUZZ -I"$SHIM_DIR" -c "$SHIM_DIR/fitsshim.c" -o "$OUT/fitsshim.o"
  "$CC" $CFLAGS_FUZZ $SAN_LINK $DEFS -I"$SHIM_DIR" \
    "$ROOT/Fuzz/fitsshim_fuzz.c" $DRIVER "$OUT/fitsshim.o" "$lib" -lz -lm -lpthread \
    -o "$OUT/fitsshim_fuzz"
fi
if wants fits_header_fuzz; then
  "$CC" $CFLAGS_FUZZ $SAN_LINK $DEFS -I"$IMPORTER_DIR" \
    "$ROOT/Fuzz/fits_header_fuzz.c" $DRIVER "$IMPORTER_DIR/fits_header.c" \
    -o "$OUT/fits_header_fuzz"
fi

echo "==> seeding corpora"
for h in $HARNESSES; do
  mkdir -p "$OUT/corpus/$h"
  n=0
  for f in "$ROOT"/HelioFITSTests/Fixtures/*.fits "$ROOT"/Fuzz/regressions/"$h"/*; do
    [ -f "$f" ] || continue
    cp "$f" "$OUT/corpus/$h/"
    n=$((n + 1))
  done
  echo "    $h: $n seed file(s)"
  if [ "$n" -eq 0 ]; then echo "warning: no seeds for $h (HelioFITSTests/Fixtures/ is HF-5's)" >&2; fi
done
echo "==> done: $HARNESSES in $OUT"
