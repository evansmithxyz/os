; ==============================================================================
; Antigravity OS - SHA-512 and SHA-384 (FIPS 180-4)
; ------------------------------------------------------------------------------
; Same shape as sha256.asm: a context of SHA512_CTX_SIZE bytes, init / update /
; final. SHA-384 is SHA-512 with other initial values, cut to 48 bytes; the
; context remembers which one it is.
; ==============================================================================

[bits 64]

SHA512_CTX_SIZE         equ 216
SHA512_H                equ 0       ; 8 x dq state
SHA512_COUNT            equ 64      ; dq total bytes hashed (2^64 is plenty)
SHA512_BUF              equ 72      ; 128-byte partial block
SHA512_BUFLEN           equ 200     ; dd bytes in the buffer
SHA512_OUTLEN           equ 204     ; dd 64 or 48

section .bss
alignb 16
sha512_w:               resq 80     ; message schedule
sha512_tmp_ctx:         resb SHA512_CTX_SIZE

section .rodata
align 8
sha512_init_h:
    dq 0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1
    dq 0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
sha384_init_h:
    dq 0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17, 0x152fecd8f70e5939
    dq 0x67332667ffc00b31, 0x8eb44a8768581511, 0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4
sha512_k:
    dq 0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc
    dq 0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118
    dq 0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2
    dq 0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694
    dq 0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65
    dq 0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5
    dq 0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4
    dq 0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70
    dq 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df
    dq 0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b
    dq 0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30
    dq 0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8
    dq 0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8
    dq 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3
    dq 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec
    dq 0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b
    dq 0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178
    dq 0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b
    dq 0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c
    dq 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817

section .text
; ------------------------------------------------------------------------------
; sha512_init / sha384_init: RDI = context
; ------------------------------------------------------------------------------
sha512_init:
    push rsi
    lea rsi, [sha512_init_h]
    mov dword [rdi + SHA512_OUTLEN], 64
    jmp sha512_init_common
sha384_init:
    push rsi
    lea rsi, [sha384_init_h]
    mov dword [rdi + SHA512_OUTLEN], 48
sha512_init_common:
    push rcx
    push rdi
    mov ecx, 64
    rep movsb
    pop rdi
    pop rcx
    mov qword [rdi + SHA512_COUNT], 0
    mov dword [rdi + SHA512_BUFLEN], 0
    pop rsi
    ret

; ------------------------------------------------------------------------------
; sha512_update: RDI = context, RSI = data, RCX = length (SHA-384 too)
; ------------------------------------------------------------------------------
sha512_update:
    push rax
    push rcx
    push rdx
    push rsi
    add [rdi + SHA512_COUNT], rcx
.loop:
    test rcx, rcx
    jz .done
    mov edx, [rdi + SHA512_BUFLEN]
    mov al, [rsi]
    mov [rdi + SHA512_BUF + rdx], al
    inc rsi
    dec rcx
    inc edx
    mov [rdi + SHA512_BUFLEN], edx
    cmp edx, 128
    jb .loop
    push rsi
    lea rsi, [rdi + SHA512_BUF]
    call sha512_compress
    pop rsi
    mov dword [rdi + SHA512_BUFLEN], 0
    jmp .loop
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; sha512_final: RDI = context, RSI = output (64 bytes, or 48 for SHA-384)
; ------------------------------------------------------------------------------
sha512_final:
    push rax
    push rcx
    push rdx
    push rsi
    mov rdx, [rdi + SHA512_COUNT]
    shl rdx, 3                      ; bit length (high 64 bits are zero)
    push rsi
    lea rsi, [sha256_pad_80]
    mov ecx, 1
    call sha512_update
.pad:
    cmp dword [rdi + SHA512_BUFLEN], 112
    je .len
    lea rsi, [sha256_zero_block]
    mov ecx, 1
    call sha512_update
    jmp .pad
.len:
    mov qword [rdi + SHA512_BUF + 112], 0
    bswap rdx
    mov [rdi + SHA512_BUF + 120], rdx
    lea rsi, [rdi + SHA512_BUF]
    call sha512_compress
    pop rsi
    mov ecx, [rdi + SHA512_OUTLEN]
    shr ecx, 3
    xor edx, edx
.out:
    mov rax, [rdi + rdx * 8]
    bswap rax
    mov [rsi + rdx * 8], rax
    inc edx
    cmp edx, ecx
    jb .out
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; sha512 / sha384: RSI = data, RCX = length, RDI = output (one call)
; ------------------------------------------------------------------------------
sha512:
    push rsi
    push rdi
    lea rdi, [sha512_tmp_ctx]
    call sha512_init
    jmp sha512_oneshot
sha384:
    push rsi
    push rdi
    lea rdi, [sha512_tmp_ctx]
    call sha384_init
sha512_oneshot:
    call sha512_update
    mov rsi, [rsp]                  ; output
    call sha512_final
    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------------------------
; sha512_compress: RDI = context, RSI = 128-byte block
; ------------------------------------------------------------------------------
sha512_compress:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    push rbp

    lea rbp, [sha512_w]
    xor ecx, ecx
.load:
    mov rax, [rsi + rcx * 8]
    bswap rax
    mov [rbp + rcx * 8], rax
    inc ecx
    cmp ecx, 16
    jb .load
.expand:
    ; s1 = rotr19 ^ rotr61 ^ shr6 of W[t-2]; s0 = rotr1 ^ rotr8 ^ shr7 of W[t-15]
    mov rax, [rbp + rcx * 8 - 2 * 8]
    mov rdx, rax
    ror rdx, 19
    mov rbx, rax
    ror rbx, 61
    xor rdx, rbx
    shr rax, 6
    xor rdx, rax
    add rdx, [rbp + rcx * 8 - 7 * 8]
    mov rax, [rbp + rcx * 8 - 15 * 8]
    mov rbx, rax
    ror rbx, 1
    mov rsi, rax
    ror rsi, 8
    xor rbx, rsi
    shr rax, 7
    xor rbx, rax
    add rdx, rbx
    add rdx, [rbp + rcx * 8 - 16 * 8]
    mov [rbp + rcx * 8], rdx
    inc ecx
    cmp ecx, 80
    jb .expand

    mov r8, [rdi + 0]
    mov r9, [rdi + 8]
    mov r10, [rdi + 16]
    mov r11, [rdi + 24]
    mov r12, [rdi + 32]
    mov r13, [rdi + 40]
    mov r14, [rdi + 48]
    mov r15, [rdi + 56]
    xor ecx, ecx
.round:
    ; T1 = h + S1(e) + Ch(e,f,g) + K[t] + W[t], S1 = rotr14 ^ rotr18 ^ rotr41
    mov rax, r12
    ror rax, 14
    mov rbx, r12
    ror rbx, 18
    xor rax, rbx
    mov rbx, r12
    ror rbx, 41
    xor rax, rbx
    mov rbx, r12
    and rbx, r13
    mov rdx, r12
    not rdx
    and rdx, r14
    xor rbx, rdx
    add rax, rbx
    add rax, r15
    lea rsi, [sha512_k]
    add rax, [rsi + rcx * 8]
    add rax, [rbp + rcx * 8]
    ; T2 = S0(a) + Maj(a,b,c), S0 = rotr28 ^ rotr34 ^ rotr39
    mov rbx, r8
    ror rbx, 28
    mov rdx, r8
    ror rdx, 34
    xor rbx, rdx
    mov rdx, r8
    ror rdx, 39
    xor rbx, rdx
    mov rdx, r8
    and rdx, r9
    mov rsi, r8
    and rsi, r10
    xor rdx, rsi
    mov rsi, r9
    and rsi, r10
    xor rdx, rsi
    add rbx, rdx
    mov r15, r14
    mov r14, r13
    mov r13, r12
    lea r12, [r11 + rax]
    mov r11, r10
    mov r10, r9
    mov r9, r8
    lea r8, [rax + rbx]
    inc ecx
    cmp ecx, 80
    jb .round

    add [rdi + 0], r8
    add [rdi + 8], r9
    add [rdi + 16], r10
    add [rdi + 24], r11
    add [rdi + 32], r12
    add [rdi + 40], r13
    add [rdi + 48], r14
    add [rdi + 56], r15

    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
