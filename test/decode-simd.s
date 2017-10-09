.align 16
    # Converts an index of dwords in the range 0-3 to a pshufb index vector that
    # can be used to look up the corresponding dwords in another vector.
    # (we're emulating a non-immediate pshufd here)
.macro pshufd_emu index

    # Since x86 doesn't have a non-immediate pshufd, we have to emulate it
    # by computing the appropriate indices, using a multiply (by 0x04040404) and add.
    pmulld tbl_0x04_rep(%rip), \index

    # Now go grab the base value and add that in
    paddd tbl_0123(%rip), \index
.endm

    # Parameters: RDI - pointer to pointer to input character, RSI - input buffer size (must be padded with at least 3 zeros)
    # rdi: &&input
    # rsi: input length
    # rdx: &&outbuf
    # rcx: outlen

    # Return value: eax = 1 for success, 0 for error
    # &input, &outbuf are updated to reflect the data processed
    
    # Locals (we use literally every general purpose register)
    # rax-rdx: Scratch registers
    # rbp: Unused/preserved
    # r9: result flag
    # r12-r15: Unused/preserved

    # rdi: Input pointer
    # rsi: Input buffer remaining

    # r8: Actual character block length
    # r10: Output buffer remaining
    # r11: Output pointer


    

.text
.globl utf8_decode_simd_core
.type utf8_decode_simd_core, @function
utf8_decode_simd_core:
    # Register saves
    sub $72, %rsp # The extra $8 aligns rsp for SIMD moves later on
    mov %rbx, 16(%rsp)
    mov %r12, 24(%rsp)
    mov %r13, 32(%rsp)
    mov %r14, 40(%rsp)
    mov %r15, 48(%rsp)
    mov %rdi, 56(%rsp) # Not callee-save, but we need them later
    mov %rdx, 64(%rsp)

    mov $1, %r9 # result flag

    # output buffer remaining to r10
    # (we need rcx for barrel shifts later)
    mov %rcx, %r10

    # Deref in/out pointers
    mov (%rdi), %rdi #in
    mov (%rdx), %r11 #out

    .align 16           # align for hot path jump target
.loop:
    sub $16, %rsi       # Input remaining
    js .eoi
    sub $16, %r10       # Output remaining
    js .outbuf_full

    movdqu (%rdi), %xmm0 # xmm0 = input data buffer
    # Before we can really start doing parallel decode, we need to identify character
    # boundaries. This is done as follows:
    # 1. Speculatively identify, for each possible starting character, the length that
    #    character would be, and put the result in an xmm register
    # 2. Transfer the register to the stack, then use ordinary byte loads to chase lengths
    #    for four characters
    # 3. Put this length back into an xmm register

    # To identify lengths, we'll shift the bytes right by 4, then do a table lookup by
    # the top nibble. This is enough to identify what the length would be, assuming the
    # character is valid.
    movdqa tbl_charlen(%rip), %xmm3
    movdqa %xmm0, %xmm1
    psrlq $4, %xmm1
    pand mask_low_nibble(%rip), %xmm1
    pshufb %xmm1, %xmm3
    # Write to the stack so we can read bytewise next
    movdqa %xmm3, (%rsp)

    pxor %xmm1, %xmm1 # Shuffle mask output
    pxor %xmm2, %xmm2 # Character length output

    xor %edx, %edx # Temporary
    xor %r8, %r8 # Character length accumulator (+ stack pointer for now)
    lea tbl_shuffle(%rip), %rax

    pextrb $0, %xmm3, %rdx # For the first character we don't need to read from memory
    pinsrd $0, tbl_shuffle(%rip), %xmm1
    add %rdx, %r8
    pinsrd $0, %edx, %xmm2 # insert character 0 length

    mov (%rsp, %r8), %dl  # Load character length
    pinsrd $1, (%rax, %r8, 4), %xmm1 # Load and insert shuffle pattern
    add %rdx, %r8        # Advance pointer
    pinsrd $1, %edx, %xmm2 # insert character length in vector reg

    mov (%rsp, %r8), %dl  # Load character length
    pinsrd $2, (%rax, %r8, 4), %xmm1 # Load and insert shuffle pattern
    add %rdx, %r8        # Advance pointer
    pinsrd $2, %edx, %xmm2 # insert character length in vector reg

    mov (%rsp, %r8), %dl  # Load character length
    pinsrd $3, (%rax, %r8, 4), %xmm1 # Load and insert shuffle pattern
    add %rdx, %r8        # Advance pointer
    pinsrd $3, %edx, %xmm2 # insert character length in vector reg

    # Okay, now we can vectorize! We'll shuffle bytes around to make each dword in xmm0
    # a separate codepoint (pre-byteswapped)
    vpshufb %xmm1, %xmm0, %xmm0

    # Now:
    # xmm0 = raw utf-8 codepoints
    # xmm1 = dead
    # xmm2 = lengths of those codepoints

    # We now need to build some padding masks. These will represent the bits of xmm0
    # that correspond to padding, and their expected values

    # Basic strategy: Table lookups with PSHUFD
    # 1. Lookup padding and mask, check padding
    # 2. Remove padding from vector
    # 3. Separate top byte from remaining bytes
    # 4. Compress lower bytes together
    # 5. Take top byte, shift it to the bottom using pshufb, then multiply by an appropriate shift factor
    # 6. Add top byte to bottom bytes
    # 7. Profit?

    # Since we'll be doing a bunch of table lookups, we'll need to prep our indexes.
    # pshufd only takes immediates, so we'll use a macro defined above to convert the
    # character-length indexes to byte indexes suitable for PSHUFB

    # First, we need them zero-based.
    movdqa %xmm2, %xmm1
    psubd tbl_1111(%rip), %xmm2
    # CLOBBER: xmm13-15
    pshufd_emu %xmm2
    # Now :
    # xmm0 = character data
    # xmm1 = character lengths
    # xmm2 = shuffle indices for dword table lookups based on character lengths

    movdqa tbl_padding_mask(%rip), %xmm15
    vpshufb %xmm2, %xmm15, %xmm15 # xmm15 = padding mask

    movdqa tbl_padding_expected(%rip), %xmm14
    vpshufb %xmm2, %xmm14, %xmm14

    vpand %xmm0, %xmm15, %xmm7 # xmm6 = padding bits
    pxor %xmm14, %xmm7         # xmm7 = expected ^ actual
    # Check if there was any mismatching padding now
    ptest %xmm7, %xmm7
    jnz .error

    # Okay, we know we have valid padding, now it's time to decode it.
    # First, let's get rid of those padding bits.
    vpandn %xmm0, %xmm15, %xmm0 # xmm0 = character ^ ~padding_mask

    # Now, we want to extract off the top byte - easily done with a shuffle
    movdqa tbl_extract_top(%rip), %xmm9 # xmm9 has our shuffle indices now
    vpshufb %xmm9, %xmm0, %xmm3         # xmm3 now has just our top bytes on their own
    # We now need to shift that top byte to its true bit position.
    # To do this we need to do a multiply by a value we obtain from a table
    movdqa tbl_shift_top(%rip), %xmm9
    vpshufb %xmm2, %xmm9, %xmm9
    pmulld %xmm9, %xmm3                # xmm3 has our top bytes, at the appropriate bit position

    # Now go mask out the bottom bytes, byteswap, and shift to right-justify them
    movdqa tbl_len_shift(%rip), %xmm9
    vpshufb %xmm2, %xmm9, %xmm9
    paddd tbl_len_shift_posn(%rip), %xmm9
    vpshufb %xmm9, %xmm0, %xmm4        # xmm4 has the bottom component now

    # Byte-swap them to put them into little-endian now.

    # Okay, now we need to compact the bottom bytes. From this point forward we don't
    # really need any length information; excess bits are zeroed in xmm5
    # Register map:
    # xmm0: Character (dead)
    # xmm1: Character length
    # xmm2: Character table index vector
    # xmm3: Top byte (shifted)
    # xmm4: Bottom bytes (not packed)

    # Our bottom byte layout looks like this:
    # 0000 0000 00xx xxxx 00xx xxxx 00xx xxxx
    # We need to shift these bytes by:
    # ---------         4         2         0
    vpand mask_byte2(%rip), %xmm4, %xmm12
    vpand mask_byte1(%rip), %xmm4, %xmm11
    pand mask_byte0(%rip), %xmm4
    psrld $4, %xmm12
    psrld $2, %xmm11
    por %xmm11, %xmm4
    por %xmm12, %xmm4
    # Now mix in the top byte
    vpor %xmm4, %xmm3, %xmm0
    # xmm0 = decoded character
    # xmm1 = original character lengths
    # xmm2 = length table lookups

    # Time to check for errors
    # First, is this an illegal surrogate character (between 0xD800..0xDFFF)?
    movdqa %xmm0, %xmm10
    pcmpgtd mask_D7FF(%rip), %xmm10 # Sets xmm10 elements to ~0 if xmm10 > mask
    movdqa %xmm0, %xmm11
    pcmpgtd mask_DFFF(%rip), %xmm11
    vpandn %xmm10, %xmm11, %xmm10
    ptest %xmm10, %xmm10
    jnz .error

    # Next, is this an illegal non-canonical encoding? We'll look up the minimum
    # codepoint in a table
    movdqa tbl_mincodepoint(%rip), %xmm10
    vpshufb %xmm2, %xmm10, %xmm10
    pcmpgtd %xmm0, %xmm10 # If the minimum is higher, its element is now nonzero in xmm10
    ptest %xmm10, %xmm10
    jnz .error

    # Everything checks out; write back our results and prepare for the next loop. 
    movdqu %xmm0, (%r11)

    # Increment pointers
    add %r8, %rdi
    add $16, %r11

    # Fixup %rsi (input remaining) now that we know how long the characters actually were
    add $16, %rsi
    sub %r8, %rsi

    jmp .loop

    # When we hit a buffer-end condition or a decode error, undo the work in the
    # current loop and pass control to a fallback character-at-a-time decode routine
.error:
    xor %r9, %r9
.outbuf_full:
    add $16, %r10
.eoi:
    add $16, %rsi

    mov 56(%rsp), %rdx   # rdx = original input buffer ptr-to-ptr
    mov %rdi, (%rdx)    # *inputpp = inptr

    mov 64(%rsp), %rdx   # rdx = original output buffer ptr-to-ptr
    mov %r11, (%rdx)    # save output ptr

    # Restore registers
    mov 16(%rsp), %rbx
    mov 24(%rsp), %r12
    mov 32(%rsp), %r13
    mov 40(%rsp), %r14
    mov 48(%rsp), %r15

    mov %r9, %rax

    add $72, %rsp
    retq

.section .rodata
.align 16
.size tbl_0x04_rep, 16
.type tbl_0x04_rep, @object
tbl_0x04_rep: # used
    .long 0x04040404
    .long 0x04040404
    .long 0x04040404
    .long 0x04040404
.type tbl_0123, @object
tbl_0123: # used
    .long 0x03020100
    .long 0x03020100
    .long 0x03020100
    .long 0x03020100
.type tbl_1111, @object
tbl_1111: # used
    .long 1, 1, 1, 1
.type tbl_padding_mask, @object
tbl_padding_mask: # used
# Note! We haven't done the byteswap yet, so padding bytes are backwards
    .long 0x80
    .long 0xC0E0 # 1100 0000 1110 0000
    .long 0xC0C0F0
    .long 0xC0C0C0F8
.type tbl_padding_expected, @object
tbl_padding_expected: # used
    .long 0
    .long 0x80C0 # 10xx xxxx 110x xxxx
    .long 0x8080E0 # 10xx xxxx 10xx xxxx 1110 xxxx
    .long 0x808080F0 # [..] 1111 0xxx
.type tbl_extract_top, @object
tbl_extract_top: # used
    .long 0x80808000
    .long 0x80808004
    .long 0x80808008
    .long 0x8080800c
.type tbl_len_shift, @object
tbl_len_shift: # used
    .long 0x80808080 # For len=1 we don't use any bottom bytes
    .long 0x80808001 # len=2
    .long 0x80800102
    .long 0x80010203
.type tbl_len_shift_posn, @object
tbl_len_shift_posn: # used
    .long 0
    .long 0x04040404
    .long 0x08080808
    .long 0x0c0c0c0c
.type mask_byte2, @object
mask_byte2: # used
    .long 0x00FF0000
    .long 0x00FF0000
    .long 0x00FF0000
    .long 0x00FF0000
.type mask_byte1, @object
mask_byte1: # used
    .long 0x0000FF00
    .long 0x0000FF00
    .long 0x0000FF00
    .long 0x0000FF00
.type mask_byte0, @object
mask_byte0: # used
    .long 0x000000FF
    .long 0x000000FF
    .long 0x000000FF
    .long 0x000000FF
.type mask_D7FF, @object
mask_D7FF: # used
    .long 0xD7FF
    .long 0xD7FF
    .long 0xD7FF
    .long 0xD7FF
.type mask_DFFF, @object
mask_DFFF: # used
    .long 0xDFFF
    .long 0xDFFF
    .long 0xDFFF
    .long 0xDFFF
.type tbl_shift_top, @object
tbl_shift_top: # used
    .long 1
    .long 64 # 2^6
    .long 4096 # 2^12
    .long 262144 # 2^18
.type tbl_mincodepoint, @object
tbl_mincodepoint: # used
    .long 0
    .long 0x80
    .long 0x800
    .long 0x10000    
.type tbl_charlen, @object
tbl_charlen: # used
    # 0000 - 0111
.rept 8
    .byte 1
.endr
    # 1000 - 1011 (illegal - any value will do)
.rept 4
    .byte 1
.endr
    # 1100 - 1101
    .byte 2
    .byte 2
    # 1110
    .byte 3
    # 1111
    .byte 4
.type mask_low_nibble, @object
mask_low_nibble: # used
.rept 16
    .byte 0x0F
.endr
.type tbl_shuffle, @object
tbl_shuffle: # used
.rept 16
    .long 0x03020100 + 0x01010101 * ((. - tbl_shuffle) / 4)
.endr
