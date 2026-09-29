#!/bin/bash
# Rebuild the vendored universal (arm64 + x86_64) CFITSIO from source, as
# HelioFITSCore/CFITSIO.xcframework.
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
MIN_IOS="17.0"                  # must match the iOS targets and HelioFITSCore/Package.swift
CONFIGURE_OPTS="--disable-curl --enable-reentrant"   # curl-free: no libcurl dependency

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "==> working in $work"

echo "==> fetching CFITSIO $CFITSIO_VERSION"
curl -sL -o "$work/cfitsio.tar.gz" \
  "https://heasarc.gsfc.nasa.gov/FTP/software/fitsio/c/cfitsio-$CFITSIO_VERSION.tar.gz"
tar xzf "$work/cfitsio.tar.gz" -C "$work"
src="$work/cfitsio-$CFITSIO_VERSION"

# One slice per <sdk>:<arch>. The iOS slices are cross-compiles: a --host that
# differs from this Mac's own triple stops configure from running its test
# programs (which could not execute here).
for slice in macosx:arm64 macosx:x86_64 iphoneos:arm64 iphonesimulator:arm64; do
  sdk="${slice%%:*}"; arch="${slice##*:}"
  case "$sdk" in
    macosx)          min="-mmacosx-version-min=$MIN_MACOS"
                     host=""; [ "$arch" = x86_64 ] && host="--host=x86_64-apple-darwin" ;;
    iphoneos)        min="-miphoneos-version-min=$MIN_IOS";        host="--host=arm-apple-darwin" ;;
    iphonesimulator) min="-mios-simulator-version-min=$MIN_IOS";   host="--host=arm-apple-darwin" ;;
  esac
  cc="xcrun -sdk $sdk clang -arch $arch $min"
  echo "==> building $sdk $arch slice"
  d="$work/build-$sdk-$arch"
  cp -R "$src" "$d"
  ( cd "$d"
    CC="$cc" ./configure $CONFIGURE_OPTS $host >/dev/null
    make -j"$(sysctl -n hw.ncpu)" libcfitsio.la >/dev/null )   # the library only: the
                                                   # fpack/funpack utilities call system(), absent on iOS
  # bake the current fitsshim into this slice
  $cc -c -O2 -I"$SHIM" "$SHIM/fitsshim.c" -o "$work/fitsshim-$arch.o"
  ar r "$d/.libs/libcfitsio.a" "$work/fitsshim-$arch.o"
done

echo "==> lipo -> universal macOS libcfitsio.a"
mkdir -p "$work/macos" "$work/ios" "$work/iossim"
lipo -create "$work/build-macosx-arm64/.libs/libcfitsio.a" \
             "$work/build-macosx-x86_64/.libs/libcfitsio.a" \
     -output "$work/macos/libcfitsio.a"
lipo -info "$work/macos/libcfitsio.a"
cp "$work/build-iphoneos-arm64/.libs/libcfitsio.a" "$work/ios/"
cp "$work/build-iphonesimulator-arm64/.libs/libcfitsio.a" "$work/iossim/"

# The app links CFITSIO through the HelioFITSCore Swift package, as an xcframework
# whose module map lets Swift `import CFITSIO`. That xcframework is the ONE copy of
# the library in the repo; tests read the .a inside it.
echo "==> xcframework -> HelioFITSCore/CFITSIO.xcframework"
hdrs="$work/headers"; mkdir -p "$hdrs"
cp "$SHIM/fitsshim.h" "$SHIM/fitsio.h" "$SHIM/longnam.h" "$hdrs/"
cat > "$hdrs/module.modulemap" <<'MAP'
module CFITSIO {
    header "fitsshim.h"
    link "z"
    export *
}
MAP
xcf="$SHIM/../../HelioFITSCore/CFITSIO.xcframework"
rm -rf "$xcf"
xcodebuild -create-xcframework \
  -library "$work/macos/libcfitsio.a"  -headers "$hdrs" \
  -library "$work/ios/libcfitsio.a"    -headers "$hdrs" \
  -library "$work/iossim/libcfitsio.a" -headers "$hdrs" \
  -output "$xcf"
echo "==> done. Rebuild the app and run the test suite on BOTH arches:"
echo "    xcodebuild test ... -destination 'platform=macOS,arch=arm64'"
echo "    xcodebuild test ... -destination 'platform=macOS,arch=x86_64'   # Rosetta"
