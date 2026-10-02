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
