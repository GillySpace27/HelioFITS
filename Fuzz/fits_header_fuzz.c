// libFuzzer harness for the Spotlight importer's header reader
// (FITSMetadataImporter/fits_header.c). Each input is written to one temp
// file and parsed with fits_read_meta, the importer's only entry point.
// Built by Fuzz/build.sh.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "fits_header.h"

static char path[4096];

static void write_input(const uint8_t *data, size_t size) {
    if (path[0] == 0) {
        const char *tmp = getenv("TMPDIR");
        snprintf(path, sizeof(path), "%s/fits_header_fuzz_XXXXXX", (tmp && *tmp) ? tmp : "/tmp");
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
    fits_meta meta;
    (void)fits_read_meta(path, &meta);
    return 0;
}
