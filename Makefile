CC     = cc -std=c99
CFLAGS = -Wall -Wextra -O3 -g3 -march=native
ASM = test/decode.s test/decode-simd.s test/simd-assist.c

all: benchmark tests

benchmark: test/benchmark.c utf8.h test/utf8-encode.h test/bh-utf8.h $(ASM)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ test/benchmark.c $(ASM) $(LDLIBS)

tests: test/tests.c utf8.h test/utf8-encode.h $(ASM)
	$(CC) $(CFLAGS) -O0 $(LDFLAGS) -o $@ test/tests.c $(ASM) $(LDLIBS)

bench: benchmark
	./benchmark

check: tests
	./tests

clean:
	rm -f benchmark tests
