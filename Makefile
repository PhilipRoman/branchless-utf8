CC     = cc -std=c99
CFLAGS = -Wall -Wextra -O3 -g3 -march=native

all: benchmark tests

benchmark: test/benchmark.c utf8.h test/utf8-encode.h test/bh-utf8.h test/decode.s
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ test/benchmark.c test/decode.s $(LDLIBS)

tests: test/tests.c utf8.h test/utf8-encode.h test/decode.s
	$(CC) $(CFLAGS) -O0 $(LDFLAGS) -o $@ test/tests.c test/decode.s $(LDLIBS)

bench: benchmark
	./benchmark

check: tests
	./tests

clean:
	rm -f benchmark tests
