#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "../utf8.h"
#include "utf8-encode.h"

static int count_pass;
static int count_fail;

#define TEST(x, s, ...) \
    do { \
        if (x) { \
            printf("\033[32;1mPASS\033[0m " s "\n", __VA_ARGS__); \
            count_pass++; \
        } else { \
            printf("\033[31;1mFAIL\033[0m " s "\n", __VA_ARGS__); \
            count_fail++; \
        } \
    } while (0)

#define utf8_decode utf8_decode_asm_once

int utf8_decode_asm(const unsigned char **restrict inbufp, size_t inbufsz, unsigned int **restrict outbufp, size_t outbufsz);
int utf8_decode_simd(const unsigned char **restrict inbufp, size_t inbufsz, unsigned int **restrict outbufp, size_t outbufsz);

/*unsigned char *utf8_decode_asm_once(const unsigned char *buf, uint32_t *c, int *e) {
    *e = !utf8_decode_asm(&buf, 4, &c, 4);
    return (unsigned char *)buf;
}
*/

int utf8_decode_simd_core(const unsigned char **restrict inbufp, size_t inbufsz, unsigned int **restrict outbufp, size_t outbufsz);

void check_simd_once(const unsigned char *buf, size_t bufsize, int *embedpattern) {
    static unsigned char embedbuf[32] = {0};
    static unsigned int result_asm[32] = {0}, result_simd[32] = {0};

    unsigned char *srcptr = embedbuf;
    for (int i = 0; i < 4; i++) {
        switch (embedpattern[i]) {
            case 0:
                memcpy(srcptr, buf, bufsize);
                srcptr += bufsize;
                break;
            case 1:
                *srcptr++ = 0x10 + i;
                break;
            case 2:
                *srcptr++ = 0xC2;
                *srcptr++ = 0x80;
                break;
            case 3:
                *srcptr++ = 0xE0;
                *srcptr++ = 0xA0;
                *srcptr++ = 0x80;
                break;
            case 4:
                *srcptr++ = 0xF0;
                *srcptr++ = 0x90;
                *srcptr++ = 0x80;
                *srcptr++ = 0x80;
                break;
        }
    }
    for (size_t i = (srcptr - embedbuf); i < sizeof(embedbuf); i++) {
        embedbuf[i] = 0x20 + i;
    }

    const unsigned char *endp_asm = embedbuf;
    const unsigned char *endp_simd = embedbuf;

    unsigned int *resp_asm = result_asm;
    unsigned int *resp_simd = result_simd;

    int rv_asm, rv_simd;

    rv_asm = utf8_decode_asm(&endp_asm, sizeof(embedbuf), &resp_asm, sizeof(result_asm));
    rv_simd = utf8_decode_simd_core(&endp_simd, sizeof(embedbuf), &resp_simd, sizeof(result_simd));

    int consumed_asm = endp_asm - embedbuf;
    int consumed_simd = endp_simd - embedbuf;

    int wrote_asm = resp_asm - result_asm;
    int wrote_simd = resp_simd - result_simd;

    if (consumed_simd <= consumed_asm && wrote_simd <= wrote_asm) {
        if (consumed_asm - consumed_simd < 16 || wrote_asm - wrote_simd < 16) {
            consumed_asm = consumed_simd;
            wrote_asm = wrote_simd;
        }
    }

    if (rv_asm == rv_simd && consumed_simd == consumed_asm && wrote_simd == wrote_asm
        && !memcmp(result_asm, result_simd, wrote_simd * 4)) {
        return;
    }

    printf("Mismatch for utf8 sequence:\n\t");
    for (size_t i = 0; i < sizeof(embedbuf); i++) {
        printf("%02x ", embedbuf[i]);
    }
    printf("\nReturn values: asm=%d simd=%d\n", rv_asm, rv_simd);
    printf("Bytes consumed: asm=%ld simd=%ld\n", endp_asm - embedbuf, endp_simd - embedbuf);
    printf("Codepoints produced: asm=%ld simd=%ld\n", resp_asm - result_asm, resp_simd - result_simd);
    printf("Codepoints produced (adjusted): asm=%ld simd=%ld\n", wrote_asm, wrote_simd);
    if (memcmp(result_asm, result_simd, wrote_simd * 4)) {
        printf("Output buffers differ:\n");
        printf("ASM:  ");
        for (int i = 0; i < wrote_asm; i++) printf("U+%x ", result_asm[i]);
        printf("\nSIMD: ");
        for (int i = 0; i < wrote_simd; i++) printf("U+%x ", result_simd[i]);
        printf("\n");
    }

    // Rerun for gdb

    endp_simd = embedbuf;
    resp_simd = result_simd;
    rv_simd = utf8_decode_simd_core(&endp_simd, sizeof(embedbuf), &resp_simd, sizeof(result_simd));

    exit(1);
}

void check_simd(const unsigned char *buf, size_t charlen) {
    for (int chpos = 0; chpos < 4; chpos++) {
        int pattern[5] = {1,1,1,1,1};
        pattern[chpos + 1] = 0;

        while (pattern[0] == 1) {
            int idx = 4;

            while (1) {
                if (pattern[idx] == 0) {
                    idx--;
                } else if (pattern[idx] == 3) {
                    for (int j = idx; j < 5; j++) {
                        pattern[idx] = 1;
                    }
                    idx--;
                } else {
                    pattern[idx]++;
                    break;
                }
            }
        }

        check_simd_once(buf, charlen, &pattern[1]);

    }

}

unsigned char *utf8_decode_asm_once(const unsigned char *buf, uint32_t *c, int *e) {
    // Try it in each character position to make sure the result is consistent
    *e = !utf8_decode_asm(&buf, 4, &c, 4);

    return (unsigned char *)buf;
}

int
main(void)
{
    /* Make sure it can decode every character */
    {
        long failures = 0;
        for (unsigned long i = 0; i < 0x1ffff; i++) {
            if (!IS_SURROGATE(i)) {
                int e;
                uint32_t c;
                unsigned char buf[8] = {0};
                unsigned char *end = utf8_encode(buf, i);
                unsigned char *res = utf8_decode(buf, &c, &e);

                check_simd(buf, end - buf);
                failures += end != res || c != i || e;
            }
        }
        TEST(failures == 0, "decode all, errors: %ld", failures);
    }

    /* Does it reject all surrogate halves? */
    {
        long failures = 0;
        for (unsigned long i = 0xd800; i <= 0xdfff; i++) {
            int e;
            uint32_t c;
            unsigned char buf[8] = {0};
            int len = (unsigned char *)utf8_encode(buf, i) - buf;
            utf8_decode(buf, &c, &e);
            check_simd(buf, len);
            failures += !e;
        }
        TEST(failures == 0, "surrogate halves, errors: %ld", failures);
    }

    /* How about non-canonical encodings? */
    {
        int e;
        uint32_t c;
        unsigned char *end;

        unsigned char buf2[8] = {0xc0, 0xA4};
        end = utf8_decode(buf2, &c, &e);
        TEST(e, "non-canonical len 2, 0x%02x", e);
        TEST(end == buf2 + 2, "non-canonical recover 2, U+%04lx",
             (unsigned long)c);
        check_simd(buf2, 2);

        unsigned char buf3[8] = {0xe0, 0x80, 0xA4};
        end = utf8_decode(buf3, &c, &e);
        TEST(e, "non-canonical len 3, 0x%02x", e);
        TEST(end == buf3 + 3, "non-canonical recover 3, U+%04lx",
             (unsigned long)c);
        check_simd(buf2, 3);

        unsigned char buf4[8] = {0xf0, 0x80, 0x80, 0xA4};
        end = utf8_decode(buf4, &c, &e);
        TEST(e, "non-canonical encoding len 4, 0x%02x", e);
        TEST(end == buf4 + 4, "non-canonical recover 4, U+%04lx",
             (unsigned long)c);
        check_simd(buf2, 4);
    }

    /* Let's try some bogus byte sequences */
    {
        int len, e;
        uint32_t c;

        /* Invalid first byte */
        unsigned char buf0[4] = {0xff};
        len = (unsigned char *)utf8_decode(buf0, &c, &e) - buf0;
        TEST(e, "bogus [ff] 0x%02x U+%04lx", e, (unsigned long)c);
        TEST(len == 1, "bogus [ff] recovery %d", len);
        check_simd(buf0, 1);

        /* Invalid first byte */
        unsigned char buf1[4] = {0x80};
        len = (unsigned char *)utf8_decode(buf1, &c, &e) - buf1;
        TEST(e, "bogus [80] 0x%02x U+%04lx", e, (unsigned long)c);
        TEST(len == 1, "bogus [80] recovery %d", len);
        check_simd(buf1, 1);

        /* Looks like a two-byte sequence but second byte is wrong */
        unsigned char buf2[4] = {0xc0, 0x0a};
        len = (unsigned char *)utf8_decode(buf2, &c, &e) - buf2;
        TEST(e, "bogus [c0 0a] 0x%02x U+%04lx", e, (unsigned long)c);
        TEST(len == 2, "bogus [c0 0a] recovery %d", len);
        check_simd(buf2, 2);
    }

    printf("%d fail, %d pass\n", count_fail, count_pass);
    return count_fail != 0;
}
