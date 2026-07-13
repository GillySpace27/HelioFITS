#include "fitsshim.h"
#include "fitsio.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

int fitsshim_read_image(const char *path, long hdu_wanted,
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
        if (status == 0 && naxis >= 2) {
            fits_get_img_size(fptr, 2, ax, &status);
            if (status == 0 && ax[0] > 0 && ax[1] > 0) is_image = 1;
        }

        const char *kind = is_image ? "image"
                         : (htype == ASCII_TBL || htype == BINARY_TBL) ? "table" : "empty";
        if (is_image)
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
    long naxes[2] = {0, 0};
    fits_get_img_size(fptr, 2, naxes, &status);
    if (status || naxes[0] <= 0 || naxes[1] <= 0) {
        int s = 0; fits_close_file(fptr, &s); return status ? status : -1;
    }

    long npix = naxes[0] * naxes[1];
    float *buf = (float *)malloc(sizeof(float) * (size_t)npix);
    if (!buf) { int s = 0; fits_close_file(fptr, &s); return -2; }

    long fpixel[2] = {1, 1};
    int anynul = 0; status = 0;
    float nulval = 0.0f;   /* NaN/blank -> 0 so scaling ignores them */
    if (fits_read_pix(fptr, TFLOAT, fpixel, npix, &nulval, buf, &anynul, &status)) {
        free(buf); int s = 0; fits_close_file(fptr, &s); return status;
    }

    char *hdr = (char *)malloc(4096); hdr[0] = 0;
    char extname[FLEN_VALUE] = ""; int s3 = 0;
    fits_read_key(fptr, TSTRING, "EXTNAME", extname, NULL, &s3);
    snprintf(line, sizeof(line), "HDU %d%s%s — %ld × %ld pixels%s\n",
             chosen - 1, extname[0] ? " " : "", extname, naxes[0], naxes[1],
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
