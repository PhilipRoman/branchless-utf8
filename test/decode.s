    # Parameters: RDI - pointer to pointer to input character, RSI - input buffer size (must be padded with at least 3 zeros)
    # rdi: &&input
    # rsi: input length
    # rdx: &&outbuf
    # rcx: outlen

    # Return value: eax = 1 for success, 0 for error
    # &input, &outbuf are updated to reflect the data processed
    
    # Locals:
    # rdi: Input pointer
    # rsi: Input buffer remaining
    # rdx: Output buffer pointer
    # r12: Output buffer remaining (callee preserve)

    # rax: scratch
    # rcx: scratch (barrel shifts use %cl for the shift count)
    # r8: character data (raw and decoded)
    # r9: character length
    # r10: Encoding table base
    # r11: Table index

    # Stack frame:
    # 16(%rsp): return instruction pointer
    # 12(%rsp): saved %rbx
    # 8(%rsp): saved %r12
    # 4(%rsp): &&input
    # 0(%rsp): &&outbuf
    
.text
.globl utf8_decode_asm
.type utf8_decode_asm, @function
utf8_decode_asm:
    push %r12
    push %rdi
    push %rdx

    # output buffer remaining to r12
    # (we need rcx for barrel shifts later)
    mov %rcx, %r12

    # Deref in/out pointers
    mov (%rdi), %rdi
    mov (%rdx), %rdx

    # Since we can't use rip-relative addressing with an index,
    # get our table base into a register for later use
    lea encoding_table(%rip), %r10

    .align 16           # align for hot path jump target
.loop:
    sub $4, %r12
    js .done            # Output buffer limit reached

    mov (%rdi), %r8d    # r8 = raw character data
    mov %r8d, %r11d     # r11 = raw character data as well
    
    and $0xf8, %r11d    # r11 now contains just the first byte of the character
    # r11 = index << 3 = table offset / 2, so we need to multiply by two to index the table
    
    mov 12(%r10, %r11, 2), %r9d # Get the character length
    add %r9, %rdi               # inptr += len

    # pext GNU syntax: mask, input, output
    pext 4(%r10, %r11, 2), %r8d, %eax # eax = just the padding bits (packed, byteswapped)

    bswap %r8d              # Get the codepoint into big-endian representation
    pext (%r10, %r11, 2), %r8d, %r8d # extract the actual character data bits
    
    cmp 8(%r10, %r11, 2), %eax       # check padding bits against expected values
    jnz .padding_error

    # Surrogate check
    mov $0xDFFF, %eax
    sub %r8d, %eax # eax = 0xDFFF - codepoint
    # Surrogates will now be in the range 0 - 0x7ff

    # If negative, the codepoint is above the surrogate range and therefore safe.
    # We'll just make it >= 0x800 for the check later... but cmov can't take an
    # immediate. Fortunately we know the codepoint itself is >= 0x800 so we can use
    # that instead.
    cmovs %r8d, %eax
    cmp $0x800, %eax    # if 0xD8FF - codepoint < 0x800, we're in the surrogate range
    js .decode_error    # treat it as a decode error
    
    # Non-canonical encoding check
    xor %ecx, %ecx      # Re-zeroing here actually _improves_ performance vs having
                        # an always-zero register.
                        # Why? Probably related to bottlenecks between the reorder
                        # buffer and the physical register file.
                
    lea -8(%ecx,%r9d,8), %ecx # cl = (length - 1) * 8
    # Mini-LUT for the log-2 of the minimum codepoint for a particular length
    # Note that for the 1-byte case we use a 2^32 shift in order to shift
    # the minimum value completely out of the 32-bit portion of the register 
    # (thus effectively zeroing it)
    mov $0x100B0720, %eax
    shr %cl, %eax           # al = desired shift left
    mov %eax, %ecx          # get the next shift into cl (shl requires it be in cl)
    mov $1, %eax
    shl %cl, %rax           # rax = 1 << ((lookup >> ((length - 1) * 8)) & 0x3F)
    cmp %eax, %r8d          # Note we use eax here to ignore the top 32 bits    
    js .decode_error        # If codepoint is too small, bail out

    mov %r8d, (%rdx)        # Save result
    
    add $4, %rdx            # outptr += 4
    sub %r9, %rsi           # remain -= len

    jc .decode_error        # if remain is now < 0 goto error
    jnz .loop                # if remain was >= len, loop again

    .align 16               # align for normal path jump target
.done:
    mov $1, %eax            # success result, return 1

.out:
    # Write back in/out pointers
    mov (%rsp), %r8         # r8 = original output buffer ptr-to-ptr
    mov %rdx, (%r8)         # *outpp = outp

    mov 8(%rsp), %rdx       # rdx = original input buffer ptr-to-ptr
    mov %rdi, (%rdx)        # *inputpp = inptr

    add $16, %rsp # Throw away saved rdi, rdx
    pop %r12
    retq
.padding_error:
    # Fixup position pointer to be one byte after the start of the "character"
    sub %r9, %rdi
    inc %rdi
.decode_error:
    # Return zero
    xor %eax, %eax
    jmp .out
   
.section .rodata
.align 16
.type encoding_table, @object
.size encoding_table, 16 * 32
encoding_table:
    # extraction mask (correct order, left aligned)
    # padding mask (byteswapped, right aligned)
    # extracted padding value (byteswapped), length
    # 00000xxx - 01111xxx
    .rept 16
    .long 0x7F000000, 0x00000080, 0x00, 1
    .endr
    # 10000xxx - 10111xxx (invalid)
    .rept 8
    .long 0, 0xFFFFFFFF, 0, 1 # The padding will never match here, forcing an error return
    .endr
    # 11000xxx - 11011xxx (two bytes) - mask 0xE0, 0xC0 (swapped), padding value 1 0110
    .rept 4
    .long 0x1F3F0000, 0x0000C0E0, 0x16, 2
    .endr
    # 11100xxx - 11101xxx (three bytes) - padding value 1010 1110
    .rept 2
    .long 0x0F3F3F00, 0x00C0C0F0, 0xAE, 3
    .endr
    # 11110xxx (four bytes) - padding value 0101 0101 1110
    .long 0x073F3F3F, 0xC0C0C0F8, 0x55E, 4
