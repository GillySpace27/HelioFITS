#ifndef FITSSHIM_H
#define FITSSHIM_H

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
// is a CFITSIO status (or -1 no image anywhere).
int fitsshim_read_image(const char *path, long hdu_wanted, long plane_wanted,
                        long *width, long *height,
                        float **pixels, char **header);


// 0-based indices of HDUs containing >=2D images. Writes up to max_indices
// into indices; returns the total number of image HDUs found (may exceed
// max_indices), or negative CFITSIO status on error.
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
