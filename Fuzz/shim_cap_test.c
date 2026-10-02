// Deterministic test for the CFITSIO shim's input limit (HF-SHIM). The fuzz harness
// runs with the extension limit set; this program covers what random bytes would
// rarely hit: the exact cap boundary, 64-bit overflow of NAXIS1 * NAXIS2, gzip and
// PKZIP wrapped input, and the unlimited path the main app uses (limit 0), which
// must return byte-for-byte what the limited path returns for the same small file.
// Built and run by Fuzz/build.sh and .github/workflows/fuzz.yml. Exit 0 = all passed.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "fitsshim.h"

#define EXTENSION_CAP (1LL << 28)   // what the Finder extensions pass: 16384 x 16384

static int failures = 0;
static char dir[4096];

#define CHECK(cond, ...) do { \
    if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d  %s  ", __FILE__, __LINE__, #cond); \
                   fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

// Appends one 80-byte header card.
static size_t card(char *buf, size_t n, const char *text) {
    char c[81];
    snprintf(c, sizeof(c), "%-80s", text);
    memcpy(buf + n, c, 80);
    return n + 80;
}

// A FITS file with a single image HDU. `data_bytes` of zero data follow the header
// (0 for a header that only claims a size).
static char *write_fits(const char *name, long long n1, long long n2, size_t data_bytes) {
    static char path[8][4200];
    static int slot = 0;
    char *p = path[slot++ & 7];
    snprintf(p, 4200, "%s/%s", dir, name);
    size_t total = 2880 + ((data_bytes + 2879) / 2880) * 2880;
    char *buf = calloc(1, total);
    memset(buf, ' ', 2880);
    char line[81];
    size_t n = 0;
    n = card(buf, n, "SIMPLE  =                    T");
    n = card(buf, n, "BITPIX  =                   16");
    n = card(buf, n, "NAXIS   =                    2");
    snprintf(line, sizeof(line), "NAXIS1  = %20lld", n1); n = card(buf, n, line);
    snprintf(line, sizeof(line), "NAXIS2  = %20lld", n2); n = card(buf, n, line);
    n = card(buf, n, "END");
    FILE *f = fopen(p, "wb");
    if (!f || fwrite(buf, 1, total, f) != total) { perror(p); exit(2); }
    fclose(f);
    free(buf);
    return p;
}

static char *write_bytes(const char *name, const uint8_t *bytes, size_t len) {
    static char path[8][4200];
    static int slot = 0;
    char *p = path[slot++ & 7];
    snprintf(p, 4200, "%s/%s", dir, name);
    FILE *f = fopen(p, "wb");
    if (!f || fwrite(bytes, 1, len, f) != len) { perror(p); exit(2); }
    fclose(f);
    return p;
}

static int read_one(const char *path, long *w, long *h, float **pix, char **hdr) {
    *w = *h = 0; *pix = NULL; *hdr = NULL;
    return fitsshim_read_image(path, -1, -1, w, h, pix, hdr);
}

static void test_boundary_and_identity(void) {
    const char *p = write_fits("small.fits", 64, 32, 64 * 32 * 2);   // 2048 pixels
    long w, h; float *pix_u, *pix_l; char *hdr_u, *hdr_l;

    fitsshim_set_max_pixels(0);
    int rc_u = read_one(p, &w, &h, &pix_u, &hdr_u);
    CHECK(rc_u == 0 && w == 64 && h == 32, "unlimited read: rc %d %ldx%ld", rc_u, w, h);

    fitsshim_set_max_pixels(2048);                      // exactly the pixel count: allowed
    int rc_l = read_one(p, &w, &h, &pix_l, &hdr_l);
    CHECK(rc_l == 0, "limit == pixel count must read, rc %d", rc_l);
    if (rc_u == 0 && rc_l == 0) {
        CHECK(memcmp(pix_u, pix_l, sizeof(float) * 2048) == 0, "pixels differ between limited and unlimited");
        CHECK(strcmp(hdr_u, hdr_l) == 0, "header text differs between limited and unlimited");
    }
    if (rc_u == 0) { free(pix_u); free(hdr_u); }
    if (rc_l == 0) { free(pix_l); free(hdr_l); }

    fitsshim_set_max_pixels(2047);                      // one pixel under: refused
    float *pix = NULL; char *hdr = NULL;
    int rc = read_one(p, &w, &h, &pix, &hdr);
    CHECK(rc == FITSSHIM_ERR_TOO_LARGE, "limit 2047 on 2048 pixels: rc %d, want %d", rc, FITSSHIM_ERR_TOO_LARGE);
    CHECK(pix == NULL && hdr == NULL, "a refused read must not hand back buffers");

    // The other entry points keep working on a plain file under a limit.
    long idx[4]; char *cards = NULL;
    CHECK(fitsshim_image_hdus(p, idx, 4) == 1, "image_hdus under a limit");
    CHECK(fitsshim_image_planes(p, 0) == 1, "image_planes under a limit");
    CHECK(fitsshim_header_cards(p, 0, &cards) == 0 && cards != NULL, "header_cards under a limit");
    free(cards);
    fitsshim_set_max_pixels(0);
}

static void test_giant_header(void) {
    // The finding: 5,760 bytes claiming 30000 x 30000 pixels (3.6 GB of floats and flags).
    const char *p = write_fits("giant.fits", 30000, 30000, 0);
    long w, h; float *pix; char *hdr;
    fitsshim_set_max_pixels(EXTENSION_CAP);
    int rc = read_one(p, &w, &h, &pix, &hdr);
    CHECK(rc == FITSSHIM_ERR_TOO_LARGE, "30000x30000 under the extension cap: rc %d, want %d", rc, FITSSHIM_ERR_TOO_LARGE);
    CHECK(pix == NULL && hdr == NULL, "buffers must stay NULL");

    // 16384 x 16384 is exactly the cap: not refused as too large. (The file has no data, so
    // the read itself then fails inside CFITSIO; it must not be the cap that says no.)
    const char *q = write_fits("atcap.fits", 16384, 16384, 0);
    rc = read_one(q, &w, &h, &pix, &hdr);
    CHECK(rc != FITSSHIM_ERR_TOO_LARGE && rc != FITSSHIM_ERR_COMPRESSED, "16384x16384 is within the cap, rc %d", rc);
    if (rc == 0) { free(pix); free(hdr); }
    fitsshim_set_max_pixels(0);
}

static void test_overflow(void) {
    // Products that wrap a signed 64-bit multiply: 2^32 * 2^32 wraps to 0, so a
    // malloc(0) would be satisfied and the reported size would be 2^32 x 2^32.
    static const long long dims[][2] = {
        {4294967296LL, 4294967296LL}, {3037000500LL, 3037000500LL}, {4611686018427387904LL, 4LL},
        {9223372036854775807LL, 2LL},
    };
    for (size_t i = 0; i < sizeof(dims) / sizeof(dims[0]); i++) {
        const char *p = write_fits("overflow.fits", dims[i][0], dims[i][1], 0);
        long w, h; float *pix; char *hdr;
        for (int limited = 0; limited < 2; limited++) {     // both modes: overflow is never a valid size
            fitsshim_set_max_pixels(limited ? EXTENSION_CAP : 0);
            int rc = read_one(p, &w, &h, &pix, &hdr);
            CHECK(rc != 0 && pix == NULL && hdr == NULL, "overflowing %lld x %lld (limited=%d): rc %d",
                  dims[i][0], dims[i][1], limited, rc);
            if (limited) CHECK(rc == FITSSHIM_ERR_TOO_LARGE, "%lld x %lld limited: rc %d, want %d",
                               dims[i][0], dims[i][1], rc, FITSSHIM_ERR_TOO_LARGE);
        }
    }
    fitsshim_set_max_pixels(0);
}

static void test_wrapped_input(void) {
    // gzip: magic, then a trailer whose last 4 bytes declare the uncompressed size.
    // CFITSIO would malloc that size (up to 4 GiB) before reading anything.
    uint8_t gz[18] = {0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 3, 0, 0, 0, 0, 0, 0xff, 0xff};
    uint8_t zip[64]; memset(zip, 0, sizeof(zip));
    memcpy(zip, "PK\x03\x04", 4); zip[22] = zip[23] = zip[24] = 0xff; zip[25] = 0x7f;
    uint8_t bz[16] = {'B', 'Z', 'h', '9'};
    uint8_t lzw[16] = {0x1f, 0x9d, 0x90};
    struct { const char *name; const uint8_t *b; size_t n; } inputs[] = {
        {"a.gz", gz, sizeof(gz)}, {"a.zip", zip, sizeof(zip)}, {"a.bz2", bz, sizeof(bz)}, {"a.Z", lzw, sizeof(lzw)},
    };
    for (size_t i = 0; i < sizeof(inputs) / sizeof(inputs[0]); i++) {
        const char *p = write_bytes(inputs[i].name, inputs[i].b, inputs[i].n);
        long w, h; float *pix; char *hdr; long idx[2]; char *cards = NULL;
        fitsshim_set_max_pixels(EXTENSION_CAP);
        CHECK(read_one(p, &w, &h, &pix, &hdr) == FITSSHIM_ERR_COMPRESSED, "%s read_image", inputs[i].name);
        CHECK(fitsshim_image_hdus(p, idx, 2) == FITSSHIM_ERR_COMPRESSED, "%s image_hdus", inputs[i].name);
        CHECK(fitsshim_image_planes(p, 0) == FITSSHIM_ERR_COMPRESSED, "%s image_planes", inputs[i].name);
        CHECK(fitsshim_header_cards(p, 0, &cards) == FITSSHIM_ERR_COMPRESSED && cards == NULL,
              "%s header_cards", inputs[i].name);
    }
    fitsshim_set_max_pixels(0);
}

static void test_missing_and_extended_names(void) {
    long w, h; float *pix; char *hdr;
    char missing[4200]; snprintf(missing, sizeof(missing), "%s/does-not-exist.fits", dir);
    fitsshim_set_max_pixels(EXTENSION_CAP);
    int rc = read_one(missing, &w, &h, &pix, &hdr);
    CHECK(rc > 0, "a missing file under a limit is a CFITSIO status, rc %d", rc);
    // Under a limit only a real, readable file is opened: no stdin, no URL, no
    // "name.fits" falling back to "name.fits.gz".
    CHECK(read_one("-", &w, &h, &pix, &hdr) > 0, "stdin name refused under a limit");
    CHECK(read_one("mem://x", &w, &h, &pix, &hdr) > 0, "mem:// refused under a limit");
    fitsshim_set_max_pixels(0);
}

// A tile-compressed image HDU (Rice, one 1PB descriptor column) after an empty primary HDU,
// with no heap data. The image is 100 x 100; the tile size comes from the caller.
static char *write_tiled(const char *name, long long tile1, long long tile2) {
    static char path[4200];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    char buf[2880 * 2]; memset(buf, ' ', sizeof(buf));
    char line[81]; size_t n = 0;
    n = card(buf, n, "SIMPLE  =                    T");
    n = card(buf, n, "BITPIX  =                    8");
    n = card(buf, n, "NAXIS   =                    0");
    n = card(buf, n, "EXTEND  =                    T");
    n = card(buf, n, "END");
    n = 2880;
    n = card(buf, n, "XTENSION= 'BINTABLE'");
    n = card(buf, n, "BITPIX  =                    8");
    n = card(buf, n, "NAXIS   =                    2");
    n = card(buf, n, "NAXIS1  =                    8");
    n = card(buf, n, "NAXIS2  =                    1");
    n = card(buf, n, "PCOUNT  =                    0");
    n = card(buf, n, "GCOUNT  =                    1");
    n = card(buf, n, "TFIELDS =                    1");
    n = card(buf, n, "TTYPE1  = 'COMPRESSED_DATA'");
    n = card(buf, n, "TFORM1  = '1PB(0)'");
    n = card(buf, n, "ZIMAGE  =                    T");
    n = card(buf, n, "ZCMPTYPE= 'RICE_1  '");
    n = card(buf, n, "ZBITPIX =                   16");
    n = card(buf, n, "ZNAXIS  =                    2");
    n = card(buf, n, "ZNAXIS1 =                  100");
    n = card(buf, n, "ZNAXIS2 =                  100");
    n = card(buf, n, "ZNAME1  = 'BLOCKSIZE'");
    n = card(buf, n, "ZVAL1   =                   32");
    n = card(buf, n, "ZNAME2  = 'BYTEPIX '");
    n = card(buf, n, "ZVAL2   =                    2");
    snprintf(line, sizeof(line), "ZTILE1  = %20lld", tile1); n = card(buf, n, line);
    snprintf(line, sizeof(line), "ZTILE2  = %20lld", tile2); n = card(buf, n, line);
    n = card(buf, n, "END");
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(buf, 1, sizeof(buf), f) != sizeof(buf)) { perror(path); exit(2); }
    fclose(f);
    return path;
}

static void test_tile_size(void) {
    long w, h; float *pix; char *hdr;
    fitsshim_set_max_pixels(EXTENSION_CAP);
    // 100 x 100 = 10,000 pixels is far under the cap, but a 2^20 x 2^20 tile is not.
    const char *big = write_tiled("bigtile.fits", 1LL << 20, 1LL << 20);
    int rc = read_one(big, &w, &h, &pix, &hdr);
    CHECK(rc == FITSSHIM_ERR_TOO_LARGE, "huge ZTILE under the cap: rc %d, want %d", rc, FITSSHIM_ERR_TOO_LARGE);
    const char *wrap = write_tiled("wraptile.fits", 1LL << 40, 1LL << 40);   // product wraps 64 bits
    rc = read_one(wrap, &w, &h, &pix, &hdr);
    CHECK(rc == FITSSHIM_ERR_TOO_LARGE, "wrapping ZTILE product: rc %d, want %d", rc, FITSSHIM_ERR_TOO_LARGE);
    // Control: a normal 100 x 1 tile is not refused for size (the heap is empty, so
    // CFITSIO may still fail the read itself).
    const char *ok = write_tiled("oktile.fits", 100, 1);
    rc = read_one(ok, &w, &h, &pix, &hdr);
    CHECK(rc != FITSSHIM_ERR_TOO_LARGE, "a 100 x 1 tile must not be refused as too large, rc %d", rc);
    if (rc == 0) { free(pix); free(hdr); }
    fitsshim_set_max_pixels(0);
}

static void test_limit_accessors(void) {
    fitsshim_set_max_pixels(EXTENSION_CAP);
    CHECK(fitsshim_max_pixels() == EXTENSION_CAP, "accessor returns what was set");
    fitsshim_set_max_pixels(-5);
    CHECK(fitsshim_max_pixels() == 0, "a negative limit means unlimited");
    fitsshim_set_max_pixels(0);
    CHECK(fitsshim_max_pixels() == 0, "default is unlimited");
}

int main(void) {
    const char *tmp = getenv("TMPDIR");
    snprintf(dir, sizeof(dir), "%s/shim_cap_test_XXXXXX", (tmp && *tmp) ? tmp : "/tmp");
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 2; }
    test_limit_accessors();
    test_boundary_and_identity();
    test_giant_header();
    test_overflow();
    test_tile_size();
    test_wrapped_input();
    test_missing_and_extended_names();
    char cmd[4300]; snprintf(cmd, sizeof(cmd), "rm -rf '%s'", dir); if (system(cmd)) {}
    if (failures) { fprintf(stderr, "%d check(s) failed\n", failures); return 1; }
    puts("shim_cap_test: all checks passed");
    return 0;
}
