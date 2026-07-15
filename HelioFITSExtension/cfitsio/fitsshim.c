#include "fitsshim.h"
#include "fitsio.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

int fitsshim_read_image(const char *path, long hdu_wanted, long plane_wanted,
                        long *width, long *height,
                        float **pixels, char **header) {
    fitsfile *fptr = NULL;
    int status = 0;
    if (fits_open_file(&fptr, path, READONLY, &status)) return status;

    int nhdus = 0;
    fits_get_num_hdus(fptr, &nhdus, &status);

    // Scan every HDU: build an inventory, find the first image HDU (auto
    // fallback) and check whether the requested HDU is a usable image.
    // CFITSIO HDU numbers are 1-based; hdu_wanted is 0-based (astropy style).
    char inventory[2048]; inventory[0] = 0;
    char line[192];
    int first_image = -1;     /* 1-based cfitsio number */
    int wanted_ok = 0;
    for (int i = 1; i <= nhdus; i++) {
        int htype = 0; status = 0;
        fits_movabs_hdu(fptr, i, &htype, &status);
        char extname[FLEN_VALUE] = ""; int s2 = 0;
        fits_read_key(fptr, TSTRING, "EXTNAME", extname, NULL, &s2);

        int naxis = 0; long ax[2] = {0, 0};
        status = 0;
        fits_get_img_dim(fptr, &naxis, &status);
        int is_image = 0;
        long cube_planes = 1;
        if (status == 0 && naxis >= 2) {
            fits_get_img_size(fptr, 2, ax, &status);
            if (status == 0 && ax[0] > 0 && ax[1] > 0) {
                is_image = 1;
                if (naxis >= 3) {
                    long ax3[3] = {0, 0, 0}; int s4 = 0;
                    fits_get_img_size(fptr, 3, ax3, &s4);
                    if (s4 == 0 && ax3[2] > 0) cube_planes = ax3[2];
                }
            }
        }

        const char *kind = is_image ? "image"
                         : (htype == ASCII_TBL || htype == BINARY_TBL) ? "table" : "empty";
        if (is_image && cube_planes > 1)
            snprintf(line, sizeof(line), "  %d: image %ld × %ld ×%ld planes%s%s\n",
                     i - 1, ax[0], ax[1], cube_planes, extname[0] ? "  " : "", extname);
        else if (is_image)
            snprintf(line, sizeof(line), "  %d: image %ld × %ld%s%s\n",
                     i - 1, ax[0], ax[1], extname[0] ? "  " : "", extname);
        else
            snprintf(line, sizeof(line), "  %d: %s%s%s\n",
                     i - 1, kind, extname[0] ? "  " : "", extname);
        strlcat(inventory, line, sizeof(inventory));

        if (is_image) {
            if (first_image < 0) first_image = i;
            if (hdu_wanted >= 0 && i == (int)hdu_wanted + 1) wanted_ok = 1;
        }
    }

    int chosen = wanted_ok ? (int)hdu_wanted + 1 : first_image;
    if (chosen < 0) { int s = 0; fits_close_file(fptr, &s); return -1; }

    int htype = 0; status = 0;
    fits_movabs_hdu(fptr, chosen, &htype, &status);

    // Real dimensionality of the chosen HDU. A plain 2D image has naxis==2; a
    // data cube (e.g. PUNCH's PAM: Stokes/polarization planes) has naxis==3+.
    // Capped at 4 — nobody ships a FITS image with a meaningful 4th axis here,
    // and it keeps the fixed-size arrays below simple.
    int naxis = 0; status = 0;
    fits_get_img_dim(fptr, &naxis, &status);
    if (status || naxis < 2) naxis = 2;
    if (naxis > 4) naxis = 4;

    long naxes[4] = {0, 0, 0, 0};
    status = 0;
    fits_get_img_size(fptr, naxis, naxes, &status);
    if (status || naxes[0] <= 0 || naxes[1] <= 0) {
        int s = 0; fits_close_file(fptr, &s); return status ? status : -1;
    }

    long nplanes = (naxis >= 3 && naxes[2] > 0) ? naxes[2] : 1;
    long plane = (plane_wanted >= 0 && plane_wanted < nplanes) ? plane_wanted : 0;

    long npix = naxes[0] * naxes[1];
    float *buf = (float *)malloc(sizeof(float) * (size_t)npix);
    char *nulls = (char *)malloc((size_t)npix);
    if (!buf || !nulls) { free(buf); free(nulls); int s = 0; fits_close_file(fptr, &s); return -2; }

    // fpixel needs one entry per axis of the HDU, not a hardcoded 2. The old
    // code passed a 2-element array to an HDU that could have 3+ axes, so
    // CFITSIO read one uninitialized stack value past the array's end as the
    // starting index on the 3rd (Stokes/cube) axis — undefined behavior:
    // sometimes an out-of-range value CFITSIO rejects outright (status
    // BAD_ELEM_NUM=308), sometimes a silently wrong plane. Sizing fpixel to
    // `naxis` and setting the cube axis explicitly reads exactly the requested
    // plane, and nothing else, every time.
    long fpixel[4] = {1, 1, 1, 1};
    fpixel[2] = plane + 1;     /* CFITSIO pixel indices are 1-based */
    int anynul = 0; status = 0;

    // fits_read_pixnull, not fits_read_pix: for a scaled INTEGER image (e.g. an
    // HMI magnetogram, BITPIX=32 BSCALE=0.1 BLANK=-2^31) fits_read_pix's nulval
    // substitution does NOT catch the BLANK — it scales the sentinel straight
    // through as a real value (-2^31*0.1 = -2.1e8). Off-disk pixels (26% of an
    // HMI frame) then dominate the percentile clip, blowing the display scale
    // to ±2e8 so the whole disk collapses to the colormap midpoint (a flat grey
    // disk — the reported bug). The `nullarray` mask marks exactly which pixels
    // were undefined; we set those to NaN, which every downstream consumer
    // (levels/readout/stats/render) already treats as "no data" and skips.
    if (fits_read_pixnull(fptr, TFLOAT, fpixel, npix, buf, nulls, &anynul, &status)) {
        free(buf); free(nulls); int s = 0; fits_close_file(fptr, &s); return status;
    }
    if (anynul) for (long i = 0; i < npix; i++) if (nulls[i]) buf[i] = NAN;
    free(nulls);

    // Plane label: PUNCH cubes carry it in OBSLAYR<n> (1-based), e.g.
    // OBSLAYR1='Polar_B', OBSLAYR2='Polar_pB', OBSLAYR3='Polar_pBp'. Fall back
    // to a bare "plane i/n" when the convention isn't present.
    char planeLabel[80] = "";
    if (nplanes > 1) {
        char key[16]; snprintf(key, sizeof(key), "OBSLAYR%ld", plane + 1);
        char val[FLEN_VALUE] = ""; int s5 = 0;
        fits_read_key(fptr, TSTRING, key, val, NULL, &s5);
        if (s5 == 0 && val[0])
            snprintf(planeLabel, sizeof(planeLabel), "  ·  %s (%ld/%ld)", val, plane + 1, nplanes);
        else
            snprintf(planeLabel, sizeof(planeLabel), "  ·  plane %ld/%ld", plane + 1, nplanes);
    }

    char *hdr = (char *)malloc(4096); hdr[0] = 0;
    char extname[FLEN_VALUE] = ""; int s3 = 0;
    fits_read_key(fptr, TSTRING, "EXTNAME", extname, NULL, &s3);
    snprintf(line, sizeof(line), "HDU %d%s%s — %ld × %ld pixels%s%s\n",
             chosen - 1, extname[0] ? " " : "", extname, naxes[0], naxes[1], planeLabel,
             (hdu_wanted >= 0 && !wanted_ok) ? "  (requested HDU has no image; auto)" : "");
    strlcat(hdr, line, 4096);
    const char *keys[] = {"TELESCOP","INSTRUME","DETECTOR","OBSRVTRY","WAVELNTH",
                          "DATE-OBS","T_OBS","EXPTIME","BUNIT","WAVEUNIT", NULL};
    for (int k = 0; keys[k]; k++) {
        char val[FLEN_VALUE]; int s2 = 0;
        if (fits_read_key(fptr, TSTRING, keys[k], val, NULL, &s2) == 0) {
            snprintf(line, sizeof(line), "%-9s %s\n", keys[k], val);
            strlcat(hdr, line, 4096);
        }
    }
    strlcat(hdr, "\nHDUs in file:\n", 4096);
    strlcat(hdr, inventory, 4096);

    *width = naxes[0]; *height = naxes[1];
    *pixels = buf; *header = hdr;
    int s = 0; fits_close_file(fptr, &s);
    return 0;
}

int fitsshim_image_hdus(const char *path, long *indices, int max_indices) {
    fitsfile *fptr = NULL;
    int status = 0;
    if (fits_open_file(&fptr, path, READONLY, &status)) return -status;
    int nhdus = 0, found = 0;
    fits_get_num_hdus(fptr, &nhdus, &status);
    for (int i = 1; i <= nhdus; i++) {
        int htype = 0; status = 0;
        fits_movabs_hdu(fptr, i, &htype, &status);
        int naxis = 0; long ax[2] = {0, 0};
        fits_get_img_dim(fptr, &naxis, &status);
        if (status == 0 && naxis >= 2) {
            fits_get_img_size(fptr, 2, ax, &status);
            if (status == 0 && ax[0] > 0 && ax[1] > 0) {
                if (found < max_indices) indices[found] = i - 1;
                found++;
            }
        }
    }
    int s = 0; fits_close_file(fptr, &s);
    return found;
}

int fitsshim_image_planes(const char *path, long hdu) {
    fitsfile *fptr = NULL;
    int status = 0;
    if (fits_open_file(&fptr, path, READONLY, &status)) return -status;
    int htype = 0;
    fits_movabs_hdu(fptr, (int)hdu + 1, &htype, &status);
    int naxis = 0; status = 0;
    fits_get_img_dim(fptr, &naxis, &status);
    if (status || naxis < 2) { int s = 0; fits_close_file(fptr, &s); return 0; }
    if (naxis > 4) naxis = 4;
    long naxes[4] = {0, 0, 0, 0};
    fits_get_img_size(fptr, naxis, naxes, &status);
    int s = 0; fits_close_file(fptr, &s);
    if (status || naxes[0] <= 0 || naxes[1] <= 0) return 0;
    return (naxis >= 3 && naxes[2] > 0) ? (int)naxes[2] : 1;
}

int fitsshim_header_cards(const char *path, long hdu, char **cards) {
    fitsfile *fptr = NULL;
    int status = 0;
    if (fits_open_file(&fptr, path, READONLY, &status)) return status;
    int htype = 0;
    fits_movabs_hdu(fptr, (int)hdu + 1, &htype, &status);
    char *raw = NULL; int nkeys = 0;
    if (fits_hdr2str(fptr, 0, NULL, 0, &raw, &nkeys, &status)) {
        int s = 0; fits_close_file(fptr, &s); return status;
    }
    /* raw is nkeys concatenated 80-char cards; re-join with newlines */
    size_t outlen = (size_t)nkeys * 81 + 1;
    char *out = (char *)malloc(outlen);
    char *w = out;
    for (int k = 0; k < nkeys; k++) {
        const char *card = raw + (size_t)k * 80;
        int len = 80;
        while (len > 0 && card[len - 1] == ' ') len--;   /* rstrip */
        memcpy(w, card, (size_t)len);
        w += len;
        *w++ = '\n';
    }
    *w = 0;
    fits_free_memory(raw, &status);
    *cards = out;
    int s = 0; fits_close_file(fptr, &s);
    return 0;
}
