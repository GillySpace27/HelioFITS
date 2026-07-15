# Security

HelioFITS parses untrusted FITS files inside Finder-invoked extensions, so
malformed-file handling is a security surface we take seriously (the header
parser is fuzz-tested against hostile inputs).

To report a vulnerability privately, use GitHub's private vulnerability
reporting on this repository (Security tab → Report a vulnerability). Please
include a proof-of-concept FITS file if the issue is parser-related.

Non-security bugs: open a regular
[issue](https://github.com/GillySpace27/HelioFITS/issues).
