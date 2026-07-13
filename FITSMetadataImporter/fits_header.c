#include "fits_header.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define CARD_LEN   80
#define BLOCK_LEN  2880
#define CARDS_PER_BLOCK (BLOCK_LEN / CARD_LEN)

// ---- small card helpers -------------------------------------------------

// The keyword occupies columns 0..7. Return it trimmed into `kw` (<=9 bytes).
static void card_keyword(const char *card, char *kw) {
    int n = 0;
    for (int i = 0; i < 8; i++) {
        char c = card[i];
        if (c == ' ') break;
        kw[n++] = c;
    }
    kw[n] = '\0';
}

// True if this is a value card ("KEYWORD = ..."): columns 8,9 == "= ".
static int card_has_value(const char *card) {
    return card[8] == '=' && card[9] == ' ';
}

// Extract a string value (single-quoted, starting near col 10). Trailing
// blanks are stripped, doubled quotes collapsed. Writes up to cap-1 chars.
static int card_string_value(const char *card, char *out, size_t cap) {
    int i = 10;
    while (i < CARD_LEN && card[i] == ' ') i++;
    if (i >= CARD_LEN || card[i] != '\'') return 0;
    i++;                       // past opening quote
    size_t n = 0;
    while (i < CARD_LEN) {
        char c = card[i];
        if (c == '\'') {
            if (i + 1 < CARD_LEN && card[i + 1] == '\'') { // doubled quote
                if (n < cap - 1) out[n++] = '\'';
                i += 2;
                continue;
            }
            break;             // closing quote
        }
        if (n < cap - 1) out[n++] = c;
        i++;
    }
    // strip trailing blanks
    while (n > 0 && out[n - 1] == ' ') n--;
    out[n] = '\0';
    return 1;
}

// Extract a numeric value: take the field between col 10 and a '/' comment.
static int card_number_value(const char *card, double *out) {
    char buf[CARD_LEN + 1];
    int n = 0;
    for (int i = 10; i < CARD_LEN; i++) {
        char c = card[i];
        if (c == '/') break;   // comment
        buf[n++] = c;
    }
    buf[n] = '\0';
    // find first token that parses as a number
    char *p = buf;
    while (*p == ' ') p++;
    if (*p == '\0') return 0;
    char *end = NULL;
    double v = strtod(p, &end);
    if (end == p) return 0;
    *out = v;
    return 1;
}

static int card_int_value(const char *card, long *out) {
    double d;
    if (!card_number_value(card, &d)) return 0;
    *out = (long)d;
    return 1;
}

// Copy a string value into a destination field only if not already set.
static void set_str_once(int *has, char *dst, size_t cap, const char *card) {
    if (*has) return;
    char tmp[128];
    if (card_string_value(card, tmp, sizeof tmp) && tmp[0] != '\0') {
        strncpy(dst, tmp, cap - 1);
        dst[cap - 1] = '\0';
        *has = 1;
    }
}

// ---- per-HDU accumulator -----------------------------------------------

typedef struct {
    // structural keywords needed to size the data segment
    int   is_primary;
    long  bitpix;
    long  naxis;
    long  naxisn[10];   // NAXIS1..NAXIS9 (index 1..9)
    long  pcount;
    long  gcount;
    int   has_pcount, has_gcount;

    // compressed-image keywords
    int   zimage;       // ZIMAGE = T
    long  zbitpix;      int has_zbitpix;
    long  znaxis;
    long  znaxisn[10];  int has_znaxisn[10];
} hdu_struct;

// After reading a header, compute the data-segment length in bytes (unpadded).
static long hdu_data_bytes(const hdu_struct *h) {
    if (h->naxis <= 0) return 0;
    long elem = (h->bitpix < 0 ? -h->bitpix : h->bitpix) / 8;
    long prod = 1;
    for (long i = 1; i <= h->naxis && i < 10; i++) prod *= h->naxisn[i];
    long gcount = h->has_gcount ? h->gcount : 1;
    long pcount = h->has_pcount ? h->pcount : 0;
    return elem * gcount * (pcount + prod);
}

static long round_up_block(long n) {
    long r = n % BLOCK_LEN;
    if (r == 0) return n;
    return n + (BLOCK_LEN - r);
}

// ---- main scan ----------------------------------------------------------

int fits_read_meta(const char *path, fits_meta *out) {
    memset(out, 0, sizeof *out);

    FILE *f = fopen(path, "rb");
    if (!f) return 1;

    char block[BLOCK_LEN];
    long file_pos = 0;         // byte offset of the current block start
    int  hdu_index = 0;
    int  ok_any = 0;

    for (;;) {
        // Begin a new HDU: read its header (possibly many blocks).
        hdu_struct hs;
        memset(&hs, 0, sizeof hs);
        hs.is_primary = (hdu_index == 0);
        hs.bitpix = 8;
        hs.gcount = 1;

        int end_seen = 0;
        int header_blocks = 0;

        // First value card of a header identifies primary (SIMPLE) vs
        // extension (XTENSION). We do not strictly need it for sizing.
        while (!end_seen) {
            if (fseek(f, file_pos + (long)header_blocks * BLOCK_LEN, SEEK_SET) != 0) {
                end_seen = 1; break;
            }
            size_t got = fread(block, 1, BLOCK_LEN, f);
            if (got < BLOCK_LEN) {            // no full block -> stop
                if (got == 0 && header_blocks == 0) { fclose(f); goto done; }
                end_seen = 1; break;
            }
            header_blocks++;

            for (int c = 0; c < CARDS_PER_BLOCK; c++) {
                const char *card = block + c * CARD_LEN;
                char kw[16];
                card_keyword(card, kw);

                if (strcmp(kw, "END") == 0) { end_seen = 1; break; }
                if (!card_has_value(card)) continue;

                // ---- structural keywords ----
                if (strcmp(kw, "BITPIX") == 0) { card_int_value(card, &hs.bitpix); }
                else if (strcmp(kw, "NAXIS") == 0) { card_int_value(card, &hs.naxis); }
                else if (strncmp(kw, "NAXIS", 5) == 0 && isdigit((unsigned char)kw[5])) {
                    int n = atoi(kw + 5);
                    if (n >= 1 && n < 10) card_int_value(card, &hs.naxisn[n]);
                }
                else if (strcmp(kw, "PCOUNT") == 0) { card_int_value(card, &hs.pcount); hs.has_pcount = 1; }
                else if (strcmp(kw, "GCOUNT") == 0) { card_int_value(card, &hs.gcount); hs.has_gcount = 1; }
                else if (strcmp(kw, "ZIMAGE") == 0) {
                    // logical T
                    int i = 10; while (i < CARD_LEN && card[i] == ' ') i++;
                    if (i < CARD_LEN && (card[i] == 'T' || card[i] == 't')) hs.zimage = 1;
                }
                else if (strcmp(kw, "ZBITPIX") == 0) { card_int_value(card, &hs.zbitpix); hs.has_zbitpix = 1; }
                else if (strcmp(kw, "ZNAXIS") == 0) { card_int_value(card, &hs.znaxis); }
                else if (strncmp(kw, "ZNAXIS", 6) == 0 && isdigit((unsigned char)kw[6])) {
                    int n = atoi(kw + 6);
                    if (n >= 1 && n < 10) { card_int_value(card, &hs.znaxisn[n]); hs.has_znaxisn[n] = 1; }
                }

                // ---- metadata keywords (first non-empty across HDUs wins) ----
                else if (strcmp(kw, "TELESCOP") == 0) set_str_once(&out->has_telescop, out->telescop, sizeof out->telescop, card);
                else if (strcmp(kw, "INSTRUME") == 0) set_str_once(&out->has_instrume, out->instrume, sizeof out->instrume, card);
                else if (strcmp(kw, "DETECTOR") == 0) set_str_once(&out->has_detector, out->detector, sizeof out->detector, card);
                else if (strcmp(kw, "OBSRVTRY") == 0) set_str_once(&out->has_obsrvtry, out->obsrvtry, sizeof out->obsrvtry, card);
                else if (strcmp(kw, "OBJECT") == 0)   set_str_once(&out->has_object,   out->object,   sizeof out->object,   card);
                else if (strcmp(kw, "WAVEUNIT") == 0) set_str_once(&out->has_waveunit, out->waveunit, sizeof out->waveunit, card);
                else if (strcmp(kw, "DATE-OBS") == 0) set_str_once(&out->has_dateobs,  out->dateobs,  sizeof out->dateobs,  card);
                else if (strcmp(kw, "T_OBS") == 0)    set_str_once(&out->has_tobs,     out->tobs,     sizeof out->tobs,     card);
                else if (strcmp(kw, "WAVELNTH") == 0) {
                    if (!out->has_wavelnth) { double v; if (card_number_value(card, &v)) { out->wavelnth = v; out->has_wavelnth = 1; } }
                }
                else if (strcmp(kw, "EXPTIME") == 0) {
                    if (!out->has_exptime) { double v; if (card_number_value(card, &v)) { out->exptime = v; out->has_exptime = 1; } }
                }
            }
        }

        ok_any = 1;
        out->nhdus = hdu_index + 1;

        // Decide whether THIS hdu supplies the image dimensions / bitpix.
        if (!out->has_dims) {
            if (hs.zimage && hs.znaxis >= 2 && hs.has_znaxisn[1] && hs.has_znaxisn[2]) {
                out->width  = hs.znaxisn[1];
                out->height = hs.znaxisn[2];
                out->has_dims = 1;
                if (hs.has_zbitpix) { out->bitpix = (int)hs.zbitpix; out->has_bitpix = 1; }
            } else if (hs.naxis >= 2 && hs.naxisn[1] > 0 && hs.naxisn[2] > 0) {
                out->width  = hs.naxisn[1];
                out->height = hs.naxisn[2];
                out->has_dims = 1;
                out->bitpix = (int)hs.bitpix;
                out->has_bitpix = 1;
            }
        }

        // Advance to next HDU: past the header blocks + padded data segment.
        long header_bytes = round_up_block((long)header_blocks * BLOCK_LEN);
        long data_bytes   = round_up_block(hdu_data_bytes(&hs));
        file_pos += header_bytes + data_bytes;

        // Try to peek whether another HDU exists.
        if (fseek(f, file_pos, SEEK_SET) != 0) break;
        char probe[CARD_LEN];
        size_t got = fread(probe, 1, CARD_LEN, f);
        if (got < CARD_LEN) break;
        // Extensions start with XTENSION; if neither that nor a printable
        // keyword, stop.
        if (strncmp(probe, "XTENSION", 8) != 0 && strncmp(probe, "SIMPLE", 6) != 0) break;

        hdu_index++;
        if (hdu_index > 512) break;   // sanity guard
    }

done:
    fclose(f);
    return ok_any ? 0 : 1;
}
