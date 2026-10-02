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

## Known findings (not fixed)

Found by the libFuzzer job over the CFITSIO shim (`Fuzz/fitsshim_fuzz.c`). Both are
open. The harness skips exactly these two input kinds, so the job runs with
libFuzzer's default malloc limit and still reports any other large allocation.

- **The shim allocates a header-driven size with no cap.** `fitsshim_read_image`
  (`HelioFITSExtension/cfitsio/fitsshim.c`, around lines 92 to 94) mallocs
  `naxes[0] * naxes[1]` floats plus one flag byte per pixel straight from the header,
  with no upper bound and no overflow guard on the product. A 5760-byte file with
  `NAXIS1 = NAXIS2 = 30000` asks for about 3.6 GB. The harness skips inputs whose
  first-HDU or any later HDU `NAXIS1 * NAXIS2` (or `ZNAXIS1 * ZNAXIS2`) exceeds 2^26
  pixels.
- **Compressed inputs make CFITSIO allocate up to 4 GiB.** For a gzip or PKZIP file,
  CFITSIO's `mem_compress_open` (`drvrmem.c`) mallocs the uncompressed size the file
  declares (the last 4 bytes of a gzip file, byte 22 of a zip file). An 18-byte file is
  enough. This is CFITSIO behaviour, not shim code. The harness skips inputs that start
  with the gzip magic `1f 8b` or the PKZIP magic `PK`.

Whether the shim should cap the pixel count, refuse oversized or compressed input,
or accept both as they are is Gilly's decision. Nothing in the shipped app changed.
When it is decided, remove the matching skip from `Fuzz/fitsshim_fuzz.c`.
