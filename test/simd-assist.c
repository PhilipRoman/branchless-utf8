#include <stdlib.h>
int utf8_decode_simd_core(const unsigned char **restrict inbufp, size_t inbufsz, unsigned int **restrict outbufp, size_t outbufsz);
int utf8_decode_simd(const unsigned char **restrict inbufp, size_t inbufsz, unsigned int **restrict outbufp, size_t outbufsz) {
    unsigned char *in_start = *inbufp;
    unsigned int *out_start = *outbufp;

    utf8_decode_simd_core(inbufp, inbufsz, outbufp, outbufsz);
    return utf8_decode_asm(inbufp, inbufsz - (*inbufp - in_start), outbufp, outbufsz - 4*(*outbufp - out_start));
}
