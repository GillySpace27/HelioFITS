# Security

HelioFITS parses untrusted FITS files inside Finder-invoked extensions, so
malformed-file handling is a security surface we take seriously. The Swift
header reader is tested against hand-built hostile and truncated inputs, and
the C parsers (the CFITSIO shim with CFITSIO itself, and the Spotlight
importer's header reader) are fuzz-tested weekly with libFuzzer and
AddressSanitizer (`Fuzz/`, `.github/workflows/fuzz.yml`).

To report a vulnerability privately, use GitHub's private vulnerability
reporting on this repository (Security tab → Report a vulnerability). Please
include a proof-of-concept FITS file if the issue is parser-related.

Non-security bugs: open a regular
[issue](https://github.com/GillySpace27/HelioFITS/issues).

## Known findings

Found by the libFuzzer job over the CFITSIO shim (`Fuzz/fitsshim_fuzz.c`). Both are
**fixed in the Finder extensions** (decision by Gilly, 2026-10-02: "cap in the extensions
only"), and both stay **open in the main app** on purpose.

- **The shim allocated a header-driven size with no cap.** `fitsshim_read_image`
  (`HelioFITSExtension/cfitsio/fitsshim.c`) mallocs `naxes[0] * naxes[1]` floats plus one
  flag byte per pixel straight from the header. A 5760-byte file with
  `NAXIS1 = NAXIS2 = 30000` asked for 3.6 GB. The product also had no overflow guard:
  `NAXIS1 = NAXIS2 = 4294967296` wrapped to 0, so the shim returned success with a
  0-byte buffer and dimensions of 2^32 x 2^32.
- **Compressed inputs made CFITSIO allocate up to 4 GiB.** For a gzip or PKZIP file,
  CFITSIO's `mem_compress_open` (`drvrmem.c`) mallocs the uncompressed size the file
  declares (the last 4 bytes of a gzip file, byte 22 of a zip file). An 18-byte file is
  enough. This is CFITSIO behaviour, not shim code.

**The fix (2026-10-02).** The shim has a process-wide input limit,
`fitsshim_set_max_pixels(n)`, default 0 (unlimited). The Quick Look preview and
Thumbnail extensions (macOS and iOS) set it once at start to 2^28 pixels (16384 x 16384,
`FITSRenderer.extensionMaxPixels`). While it is set:

- an image whose `NAXIS1 * NAXIS2` (one plane) is over the limit, or whose product
  overflows 64 bits, or whose tile-compressed tile size (`ZTILEn` product) is over the
  limit, is refused with `FITSSHIM_ERR_TOO_LARGE` (-3) before any allocation;
- a file that starts with a gzip, PKZIP, bzip2, compress, pack or LZH magic is refused
  with `FITSSHIM_ERR_COMPRESSED` (-4) before CFITSIO opens it, by every shim entry point;
- only a real readable file is opened (no stdin, URL or `mem://` name, no CFITSIO retry
  of `name.fits` as `name.fits.gz`).

The extensions already treat a thrown read error as "cannot preview" (the Quick Look card,
the generic thumbnail), so a refusal needs no new UI. Side effect: a `.fits.gz` file no
longer previews in the extensions; the main app still opens it.

**What stays unlimited, and why.** The main app passes no limit. A person who opens a
file in the app chose it and may have a real 20000 x 20000 image or a `.fits.gz`; capping
it would change results that users and tests depend on, and the app is not parsing files
it was handed by Finder in the background. The one change that applies without a limit is
the overflow check: a size that cannot be allocated (product above 64 bits, or more floats
than `SIZE_MAX`) now returns `FITSSHIM_ERR_TOO_LARGE` instead of wrapping to a small
buffer; no valid file is affected. A file in the main app can still ask for gigabytes
that do fit in 64 bits, and a gzip file can still make CFITSIO allocate its declared size.

**How it is tested.** `Fuzz/fitsshim_fuzz.c` sets the extension limit and no longer skips
any input (the 2^26 pixel skip and the gzip/PKZIP skip are gone); libFuzzer's default
2048 MB malloc limit stays on. `Fuzz/shim_cap_test.c` covers the exact cap boundary,
overflowing sizes, wrapped inputs, tile sizes and the unlimited path (same bytes as the
limited path for a small file); the `fuzz` workflow runs it. The giant, overflowing,
gzip and PKZIP inputs are kept in `Fuzz/regressions/fitsshim_fuzz/`.

**Rebuild required.** `fitsshim.c` is baked into `HelioFITSCore/CFITSIO.xcframework`, which
is not rebuilt by Xcode. The limit takes effect in a shipped build only after
`HelioFITSExtension/cfitsio/build-universal.sh` is run on a Mac and the xcframework is
committed.

One more item is recorded here but is not a vulnerability: a binary-table header with
a huge `TFIELDS` makes CFITSIO's `ffbinit` call `calloc(tfield, sizeof(tcolumn))` with an
overflowing product. In the shipped app `calloc` returns NULL and `ffbinit` returns
`ARRAY_TOO_BIG`, so the file is rejected. Under AddressSanitizer the default is to abort,
so the fuzz job sets `ASAN_OPTIONS=allocator_may_return_null=1` to behave like the app.
