#!/bin/bash
# Rebuild the vendored universal (arm64 + x86_64) libcfitsio.a from source.
#
# The app links this ONE static library; it must be a fat binary so HelioFITS
# ships as a universal app that runs on both Apple Silicon and Intel Macs. The
# custom fitsshim.c is baked into the archive (the app calls fitsshim_* directly),
# so it is compiled per-arch and `ar r`'d into each slice before the lipo.
#
# Run this after editing fitsshim.c, or to move to a new CFITSIO version. It must
# run on an Apple Silicon Mac with Rosetta 2 installed (the x86_64 slice is built
# with `clang -arch x86_64`; its configure test programs run under Rosetta).
#
#   ./build-universal.sh          # uses CFITSIO_VERSION below
#
set -euo pipefail
cd "$(dirname "$0")"
SHIM="$PWD"

CFITSIO_VERSION="4.6.4"
MIN_MACOS="14.5"                # must match MACOSX_DEPLOYMENT_TARGET in the project
CONFIGURE_OPTS="--disable-curl --enable-reentrant"   # curl-free: no libcurl dependency

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "==> working in $work"

echo "==> fetching CFITSIO $CFITSIO_VERSION"
curl -sL -o "$work/cfitsio.tar.gz" \
  "https://heasarc.gsfc.nasa.gov/FTP/software/fitsio/c/cfitsio-$CFITSIO_VERSION.tar.gz"
tar xzf "$work/cfitsio.tar.gz" -C "$work"
src="$work/cfitsio-$CFITSIO_VERSION"

for arch in arm64 x86_64; do
  echo "==> building $arch slice"
  d="$work/build-$arch"
  cp -R "$src" "$d"
  ( cd "$d"
    host=""; [ "$arch" = x86_64 ] && host="--host=x86_64-apple-darwin"
    CC="clang -arch $arch -mmacosx-version-min=$MIN_MACOS" \
      ./configure $CONFIGURE_OPTS $host >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null )
  # bake the current fitsshim into this slice
  clang -c -O2 -arch "$arch" -mmacosx-version-min=$MIN_MACOS -I"$SHIM" \
    "$SHIM/fitsshim.c" -o "$work/fitsshim-$arch.o"
  ar r "$d/.libs/libcfitsio.a" "$work/fitsshim-$arch.o"
done

echo "==> lipo -> universal libcfitsio.a"
lipo -create "$work/build-arm64/.libs/libcfitsio.a" \
             "$work/build-x86_64/.libs/libcfitsio.a" \
     -output "$SHIM/libcfitsio.a"

lipo -info "$SHIM/libcfitsio.a"
echo "==> done. Rebuild the app and run the test suite on BOTH arches:"
echo "    xcodebuild test ... -destination 'platform=macOS,arch=arm64'"
echo "    xcodebuild test ... -destination 'platform=macOS,arch=x86_64'   # Rosetta"
