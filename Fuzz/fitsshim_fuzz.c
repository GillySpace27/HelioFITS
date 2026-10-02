// libFuzzer harness for the CFITSIO shim (HelioFITSExtension/cfitsio/fitsshim.c).
// Each input is written to one temp file, then read back through the two shim
// entry points the app calls on untrusted files. Outputs are freed so
// LeakSanitizer sees only real leaks. Built by Fuzz/build.sh.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "fitsshim.h"

static char path[4096];

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
