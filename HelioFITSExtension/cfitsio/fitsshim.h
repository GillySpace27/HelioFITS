#ifndef FITSSHIM_H
#define FITSSHIM_H

// Reads an image HDU (transparently decompresses CompImageHDU).
// hdu_wanted: 0-based HDU index (astropy numbering) to display, or -1 for
// auto (first HDU with a >=2D image). If the requested HDU has no 2D image,
// falls back to auto. On success returns 0, sets *width/*height and mallocs
// *pixels (row-major, bottom-up FITS order) and *header (NUL-terminated
// summary including which HDU rendered and an inventory of all HDUs).
// Caller frees *pixels and *header. Nonzero return is a CFITSIO status
// (or -1 no image anywhere).
int fitsshim_read_image(const char *path, long hdu_wanted,
                        long *width, long *height,
                        float **pixels, char **header);


// 0-based indices of HDUs containing >=2D images. Writes up to max_indices
// into indices; returns the total number of image HDUs found (may exceed
// max_indices), or negative CFITSIO status on error.
int fitsshim_image_hdus(const char *path, long *indices, int max_indices);

// All header cards of the given 0-based HDU, newline-joined, malloc'd into
// *cards (caller frees). Returns 0 on success.
int fitsshim_header_cards(const char *path, long hdu, char **cards);

#endif
