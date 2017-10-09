#define _POSIX_C_SOURCE 200112L
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <signal.h>

#include <unistd.h> // alarm()

#include "../utf8.h"
#include "utf8-encode.h"
#include "bh-utf8.h"

#define SECONDS 6
#define BUFLEN  8 // MB

int utf8_decode_asm(const unsigned char **restrict inbufp, size_t inbufsz, unsigned int **restrict outbufp, size_t outbufsz);
int utf8_decode_simd(const unsigned char **restrict inbufp, size_t inbufsz, unsigned int **restrict outbufp, size_t outbufsz);

static uint32_t
pcg32(uint64_t *s)
{
    uint64_t m = 0x9b60933458e17d7d;
    uint64_t a = 0xd737232eeccdf7ed;
    *s = *s * m + a;
    int shift = 29 - (*s >> 61);
    return *s >> shift;
}

/* Generate a random codepoint whose UTF-8 length is uniformly selected. */
static long
randchar(uint64_t *s)
{
    uint32_t r = pcg32(s);
    int len = 1 + (r & 0x3);
    r >>= 2;
    switch (len) {
        case 1:
            return r % 128;
        case 2:
            return 128 + r % (2048 - 128);
        case 3:
            return 2048 + r % (65536 - 2048);
        case 4:
            return 65536 + r % (131072 - 65536);
    }
    abort();
}

static volatile sig_atomic_t running;

static void
alarm_handler(int signum)
{
    (void)signum;
    running = 0;
}

/* Fill buffer with random characters, with evenly-distributed encoded
 * lengths.
 */
static void *
buffer_fill(void *buf, size_t z)
{
    uint64_t s = 0;
    char *p = buf;
    char *end = p + z;
    while (p < end) {
        long c;
        do
            c = randchar(&s);
        while (IS_SURROGATE(c));
        p = utf8_encode(p, c);
    }
    return p;
}

int
main(void)
{
    long errors, n;
    size_t z = BUFLEN * 1024L * 1024;
    unsigned char *buffer = malloc(z);
    unsigned char *end = buffer_fill(buffer, z);
    unsigned int *outbuf = malloc(z * 4);
    double rate;

#if 1
    /* Benchmark the asm decoder */
    running = 1;
    signal(SIGALRM, alarm_handler);
    alarm(SECONDS);
    errors = n = 0;
    do {
        const unsigned char *p = buffer;
        long count = 0;
        while (p < end) {
            unsigned int *outbufp = outbuf;
            if (utf8_decode_asm(&p, end - p, &outbufp, z * 4) <= 0) {
                errors++;
            }
            count++;
        }
        if (p == end) // reached the end successfully?
            n++;
    } while (running);

    rate = n * (end - buffer) / (double)SECONDS / 1024 / 1024;
    printf("asm: %f MB/s, %ld errors\n", rate, errors);
#endif

    /* Benchmark the simd decoder */
    running = 1;
    signal(SIGALRM, alarm_handler);
    alarm(SECONDS);
    errors = n = 0;
    do {
        const unsigned char *p = buffer;
        long count = 0;
        while (p < end) {
            unsigned int *outbufp = outbuf;
            if (utf8_decode_simd(&p, end - p, &outbufp, z * 4) <= 0) {
                errors++;
            }
            count++;
        }
        if (p == end) // reached the end successfully?
            n++;
    } while (running);

    rate = n * (end - buffer) / (double)SECONDS / 1024 / 1024;
    printf("simd: %f MB/s, %ld errors\n", rate, errors);

#if 1
    /* Benchmark the branchless decoder */
    running = 1;
    signal(SIGALRM, alarm_handler);
    alarm(SECONDS);
    errors = n = 0;
    do {
        unsigned char *p = buffer;
        int e = 0;
        uint32_t c;
        long count = 0;
        while (p < end) {
            p = utf8_decode(p, &c, &e);
            errors += !!e;  // force errors to be checked
            count++;
        }
        if (p == end) // reached the end successfully?
            n++;
    } while (running);

    rate = n * (end - buffer) / (double)SECONDS / 1024 / 1024;
    printf("branchless: %f MB/s, %ld errors\n", rate, errors);

    /* Benchmark Bjoern Hoehrmann's decoder */
    running = 1;
    signal(SIGALRM, alarm_handler);
    alarm(SECONDS);
    errors = n = 0;
    do {
        unsigned char *p = buffer;
        uint32_t c;
        uint32_t state = 0;
        long count = 0;
        for (; p < end; p++) {
            if (!bh_utf8_decode(&state, &c, *p))
                count++;
            else if (state == UTF8_REJECT)
                errors++;  // force errors to be checked
        }
        if (p == end) // reached the end successfully?
            n++;
    } while (running);

    rate = n * (end - buffer) / (double)SECONDS / 1024 / 1024;
    printf("Hoehrmann:  %f MB/s, %ld errors\n", rate, errors);
#endif

    free(buffer);
}
