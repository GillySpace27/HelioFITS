#ifndef FITSSHIM_H
#define FITSSHIM_H

// Input limit. By default the shim is unlimited, which is what the main app uses.
// The Finder Quick Look and Thumbnail extensions (macOS and iOS) parse files
// they did not choose, so each calls fitsshim_set_max_pixels(1 << 28) once at
// start (16384 x 16384, FITSRenderer.extensionMaxPixels). While the limit is
// above 0, in this process:
//   - fitsshim_read_image returns FITSSHIM_ERR_TOO_LARGE when the chosen HDU's
//     NAXIS1 * NAXIS2 (one plane) exceeds the limit or the product overflows 64
//     bits, or, for a tile-compressed image, when the tile size does, all before
//     any allocation;
//   - every entry point returns FITSSHIM_ERR_COMPRESSED, without calling CFITSIO,
//     for a gzip, PKZIP, bzip2, compress, pack or LZH wrapped file (CFITSIO
//     inflates those into memory at the size the file declares, up to 4 GiB);
//   - only a real readable file is opened: a name that cannot be fopen'ed
//     (stdin "-", a URL, mem://, or a name CFITSIO would retry as name.gz) gets
//     CFITSIO status 104 (FILE_NOT_OPENED) instead of reaching CFITSIO.
// The limit is process-wide. Set it once before other threads call the shim.
// 0 or a negative value means unlimited. Without a limit only the overflow check
// applies, so an impossible size is refused (FITSSHIM_ERR_TOO_LARGE) instead of
// wrapping to a tiny allocation.
#define FITSSHIM_ERR_NO_IMAGE   (-1)   /* no image HDU anywhere in the file */
#define FITSSHIM_ERR_ALLOC      (-2)   /* malloc failed */
#define FITSSHIM_ERR_TOO_LARGE  (-3)   /* over the pixel limit, or the size overflows */
#define FITSSHIM_ERR_COMPRESSED (-4)   /* gzip/PKZIP/... wrapped file, refused under a limit */
void fitsshim_set_max_pixels(long long max_pixels);
long long fitsshim_max_pixels(void);

// Reads an image HDU (transparently decompresses CompImageHDU).
// hdu_wanted: 0-based HDU index (astropy numbering) to display, or -1 for
// auto (first HDU with a >=2D image). If the requested HDU has no 2D image,
// falls back to auto.
// plane_wanted: 0-based index into the HDU's 3rd axis (e.g. the Stokes/
// polarization axis of a data cube such as a PUNCH PAM file), or -1 for
// plane 0. Ignored (always plane 0) when the HDU is a plain 2D image.
// On success returns 0, sets *width/*height and mallocs *pixels (row-major,
// bottom-up FITS order, exactly ONE plane's worth of samples) and *header
// (NUL-terminated summary including which HDU/plane rendered and an
// inventory of all HDUs). Caller frees *pixels and *header. Nonzero return
// is a CFITSIO status, or one of the negative FITSSHIM_ERR_* codes above.
int fitsshim_read_image(const char *path, long hdu_wanted, long plane_wanted,
                        long *width, long *height,
                        float **pixels, char **header);

// Same, but reads only every *step-th pixel on each axis, step chosen so the
// longest side is <= max_side (max_side <= 0: step 1, the call above). The
// buffer is (width/step) x (height/step), sampling pixels 0, step, 2*step, ...
// (the same nearest decimation FITSRenderer.render does), and a compressed
// image is decoded one tile at a time, so a big frame never sits in memory
// whole. *width/*height are still the FULL image size. For the iOS
// extensions, which have tight memory limits.
int fitsshim_read_image_max(const char *path, long hdu_wanted, long plane_wanted,
                            long max_side, long *width, long *height, long *step,
                            float **pixels, char **header);


// 0-based indices of HDUs containing >=2D images. Writes up to max_indices
// into indices; returns the total number of image HDUs found (may exceed
// max_indices), or negative CFITSIO status on error (FITSSHIM_ERR_COMPRESSED
// under an input limit).
int fitsshim_image_hdus(const char *path, long *indices, int max_indices);

// Number of selectable planes in one 0-based image HDU: 1 for a plain 2D
// image, or the length of the 3rd axis for a data cube (any 4th+ axis is
// assumed singleton and ignored). Returns 0 if `hdu` is not an image HDU, or
// a negative CFITSIO status on error.
int fitsshim_image_planes(const char *path, long hdu);

// All header cards of the given 0-based HDU, newline-joined, malloc'd into
// *cards (caller frees). Returns 0 on success.
int fitsshim_header_cards(const char *path, long hdu, char **cards);

#endif
