#ifndef FITS_HEADER_H
#define FITS_HEADER_H

#include <stddef.h>

// Self-contained FITS header reader. No cfitsio required: FITS headers are
// plain ASCII, laid out as 2880-byte blocks of 80-char cards. We scan every
// HDU, computing each HDU's data-segment length from its own header so we can
// jump to the next one, and collect a handful of interesting keywords.

typedef struct {
    int    has_telescop;   char telescop[72];
    int    has_instrume;   char instrume[72];
    int    has_detector;   char detector[72];
    int    has_obsrvtry;   char obsrvtry[72];
    int    has_object;     char object[72];

    int    has_wavelnth;   double wavelnth;
    int    has_waveunit;   char waveunit[72];

    int    has_dateobs;    char dateobs[72];   // DATE-OBS
    int    has_tobs;       char tobs[72];      // T_OBS

    int    has_exptime;    double exptime;

    int    has_bitpix;     int bitpix;         // BITPIX or ZBITPIX of image HDU

    int    has_dims;       long width;         // NAXIS1 or ZNAXIS1
                           long height;        // NAXIS2 or ZNAXIS2

    int    nhdus;
} fits_meta;

// Parse the FITS file at `path`. Returns 0 on success (at least the primary
// header read), nonzero on I/O/format error. Fills *out.
int fits_read_meta(const char *path, fits_meta *out);

#endif
