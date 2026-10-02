// libFuzzer harness for the CFITSIO shim (HelioFITSExtension/cfitsio/fitsshim.c).
// Each input is written to one temp file, then read back through the two shim
// entry points the app calls on untrusted files. Outputs are freed so
// LeakSanitizer sees only real leaks. Built by Fuzz/build.sh.
//
// KNOWN FINDINGS, AWAITING GILLY'S DECISION ON A CAP IN THE SHIM (SECURITY.md,
// "Known findings (not fixed)"). The harness skips, without calling the shim, the
// two input kinds that trigger them, so the default libFuzzer malloc limit (2048 MB)
// stays in force and anything new above it is still reported:
//   1. gzip magic (1f 8b) or PKZIP magic ("PK"): CFITSIO's mem_compress_open mallocs
//      the uncompressed size the file declares (the last 4 bytes of a gzip file, byte
//      22 of a zip file), up to 4 GiB. Found by running this harness with the default
//      limit: the PKZIP form was the first thing it reported after the gzip form.
//   2. a header whose NAXIS1 * NAXIS2 (or ZNAXIS1 * ZNAXIS2) exceeds SKIP_PIXELS:
//      fitsshim_read_image mallocs naxes[0] * naxes[1] floats straight from the
//      header, with no cap and no overflow guard.
// Remove a skip when the shim is changed to cap or refuse that case.
// FUZZ_LOG_SKIPS=1 prints one line to stderr per skipped input.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "fitsshim.h"

static char path[4096];

#define SKIP_PIXELS (1LL << 26)   // 67,108,864 pixels: 256 MB of floats plus 64 MB of null flags

static int is_sized_archive(const uint8_t *data, size_t size, const char **kind) {
    if (size >= 2 && data[0] == 0x1f && data[1] == 0x8b) { *kind = "gzip magic"; return 1; }
    if (size >= 2 && data[0] == 'P' && data[1] == 'K') { *kind = "PKZIP magic"; return 1; }
    return 0;
}

// Value of an integer header card "KEY     =  123 / comment"; -1 when it is not one.
static long long card_int(const uint8_t *card) {
    char v[71];
    memcpy(v, card + 10, 70);
    v[70] = 0;
    char *end = NULL;
    long long n = strtoll(v, &end, 10);
    return (end == v || n < 0) ? -1 : n;
}

// Walks every 80-byte card of the input (the first HDU or any later one: the shim
// reads the first image HDU, which can be an extension) and reports whether some
// header declares NAXIS1 * NAXIS2 or ZNAXIS1 * ZNAXIS2 above SKIP_PIXELS. Cheap and
// deliberately over-inclusive: bytes in a data unit that look like cards only cause
// an extra skip.
static int asks_for_too_many_pixels(const uint8_t *data, size_t size) {
    long long n1 = 0, n2 = 0, z1 = 0, z2 = 0;
    for (size_t off = 0; off + 80 <= size; off += 80) {
        const uint8_t *c = data + off;
        if (memcmp(c, "SIMPLE  ", 8) == 0 || memcmp(c, "XTENSION", 8) == 0) n1 = n2 = z1 = z2 = 0;
        if (c[8] == '=') {
            if (memcmp(c, "NAXIS1  ", 8) == 0) n1 = card_int(c);
            else if (memcmp(c, "NAXIS2  ", 8) == 0) n2 = card_int(c);
            else if (memcmp(c, "ZNAXIS1 ", 8) == 0) z1 = card_int(c);
            else if (memcmp(c, "ZNAXIS2 ", 8) == 0) z2 = card_int(c);
        }
        // Divide rather than multiply: card_int can return up to LLONG_MAX.
        if (n1 > 0 && n2 > 0 && n1 > SKIP_PIXELS / n2) return 1;
        if (z1 > 0 && z2 > 0 && z1 > SKIP_PIXELS / z2) return 1;
    }
    return 0;
}

static int skip_known_finding(const uint8_t *data, size_t size) {
    const char *why = NULL;
    if (!is_sized_archive(data, size, &why) && asks_for_too_many_pixels(data, size)) why = "NAXIS1*NAXIS2 above 2^26";
    if (why && getenv("FUZZ_LOG_SKIPS")) fprintf(stderr, "skip (known finding): %s, %zu bytes\n", why, size);
    return why != NULL;
}

static void write_input(const uint8_t *data, size_t size) {
    if (path[0] == 0) {
        const char *tmp = getenv("TMPDIR");
        snprintf(path, sizeof(path), "%s/fitsshim_fuzz_XXXXXX", (tmp && *tmp) ? tmp : "/tmp");
        int fd = mkstemp(path);
        if (fd < 0) abort();
        close(fd);
    }
    FILE *f = fopen(path, "wb");
    if (!f) abort();
    if (size > 0 && fwrite(data, 1, size, f) != size) abort();
    fclose(f);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
#ifdef FUZZ_CANARY
    // Verification only (HF-11): a deliberate heap out-of-bounds read that the
    // fuzzer must report. Defined only by FUZZ_CANARY=1 Fuzz/build.sh.
    if (size >= 6 && memcmp(data, "SIMPLE", 6) == 0) {
        volatile char *p = malloc(8);
        volatile char c = p[8];
        (void)c;
        free((void *)p);
    }
#endif
    if (skip_known_finding(data, size)) return 0;
    write_input(data, size);

    long w = 0, h = 0;
    float *pixels = NULL;
    char *header = NULL;
    if (fitsshim_read_image(path, -1, -1, &w, &h, &pixels, &header) == 0) {
        free(pixels);
        free(header);
    }

    char *cards = NULL;
    if (fitsshim_header_cards(path, 0, &cards) == 0) free(cards);
    return 0;
}
