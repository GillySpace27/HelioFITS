// Runs a fuzz harness once over each file named on the command line, without
// libFuzzer, for compilers that ship no libFuzzer runtime (Apple clang).
// Fuzz/build.sh links it when FUZZ_ENGINE=standalone. AddressSanitizer
// reports a crash and exits nonzero; a clean pass prints one line per file.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        if (!f) { fprintf(stderr, "cannot open %s\n", argv[i]); return 2; }
        fseek(f, 0, SEEK_END);
        long n = ftell(f);
        fseek(f, 0, SEEK_SET);
        size_t cap = n > 0 ? (size_t)n : 1;
        uint8_t *buf = malloc(cap);
        if (!buf) { fclose(f); return 2; }
        size_t got = n > 0 ? fread(buf, 1, (size_t)n, f) : 0;
        fclose(f);
        LLVMFuzzerTestOneInput(buf, got);
        free(buf);
        printf("ok %s (%zu bytes)\n", argv[i], got);
        fflush(stdout);
    }
    return 0;
}
