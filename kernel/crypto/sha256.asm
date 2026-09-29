; ==============================================================================
; Antigravity OS - SHA-256 (FIPS 180-4) and HMAC-SHA256 (RFC 2104)
; ------------------------------------------------------------------------------
; A context is SHA256_CTX_SIZE bytes: eight state words, the byte count and a
; 64-byte block buffer. Copy a context to hash a prefix without disturbing it
; (the TLS transcript does this).
; ==============================================================================

[bits 64]

SHA256_CTX_SIZE         equ 112
SHA256_H                equ 0       ; 8 x dd state
SHA256_COUNT            equ 32      ; dq total bytes hashed
SHA256_BUF              equ 40      ; 64-byte partial block
SHA256_BUFLEN           equ 104     ; dd bytes in the buffer

section .bss
alignb 16
sha256_w:               resd 64     ; message schedule
hmac_ctx:               resb SHA256_CTX_SIZE
sha256_tmp_ctx:         resb SHA256_CTX_SIZE
hmac_pad:               resb 64
hmac_inner:             resb 32

section .rodata
align 4
sha256_init_h:
    dd 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    dd 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
sha256_k:
    dd 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
    dd 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
    dd 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
    dd 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
    dd 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
    dd 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
    dd 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
    dd 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
sha256_zero_block:      times 64 db 0

section .text
; ------------------------------------------------------------------------------
; sha256_init: RDI = context -> empty hash
; ------------------------------------------------------------------------------
sha256_init:
    push rcx
    push rsi
    push rdi
    lea rsi, [sha256_init_h]
    mov ecx, 32
    rep movsb
    xor ecx, ecx
    mov [rdi], rcx                  ; SHA256_COUNT (rdi is ctx + 32 here)
    mov dword [rdi + SHA256_BUFLEN - SHA256_COUNT], ecx
    pop rdi
    pop rsi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; sha256_update: RDI = context, RSI = data, RCX = length
; ------------------------------------------------------------------------------
sha256_update:
    push rax
    push rcx
    push rdx
    push rsi
    add [rdi + SHA256_COUNT], rcx
.loop:
    test rcx, rcx
    jz .done
    mov edx, [rdi + SHA256_BUFLEN]
    mov al, [rsi]
    mov [rdi + SHA256_BUF + rdx], al
    inc rsi
    dec rcx
    inc edx
    mov [rdi + SHA256_BUFLEN], edx
    cmp edx, 64
    jb .loop
    push rsi
    lea rsi, [rdi + SHA256_BUF]
    call sha256_compress
    pop rsi
    mov dword [rdi + SHA256_BUFLEN], 0
    jmp .loop
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; sha256_final: RDI = context, RSI = 32-byte output. The context is used up.
; ------------------------------------------------------------------------------
sha256_final:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov rdx, [rdi + SHA256_COUNT]
    shl rdx, 3                      ; length in bits
    push rsi
    ; 0x80, zeros up to 56 mod 64, then the 64-bit big-endian bit length
    lea rsi, [sha256_pad_80]
    mov ecx, 1
    call sha256_update
.pad:
    cmp dword [rdi + SHA256_BUFLEN], 56
    je .len
    lea rsi, [sha256_zero_block]
    mov ecx, 1
    call sha256_update
    jmp .pad
.len:
    bswap rdx
    mov [rdi + SHA256_BUF + 56], rdx
    lea rsi, [rdi + SHA256_BUF]
    call sha256_compress
    pop rsi
    ; output the state big-endian
    xor ecx, ecx
.out:
    mov eax, [rdi + rcx * 4]
    bswap eax
    mov [rsi + rcx * 4], eax
    inc ecx
    cmp ecx, 8
    jb .out
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; sha256: RSI = data, RCX = length, RDI = 32-byte output (one call)
; ------------------------------------------------------------------------------
sha256:
    push rsi
    push rdi
    lea rdi, [sha256_tmp_ctx]
    call sha256_init
    call sha256_update
    mov rsi, [rsp]                  ; output
    call sha256_final
    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------------------------
; sha256_compress: RDI = context, RSI = 64-byte block
; ------------------------------------------------------------------------------
sha256_compress:
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

    ; W[0..15] = big-endian words of the block
    lea rbp, [sha256_w]
    xor ecx, ecx
.load:
    mov eax, [rsi + rcx * 4]
    bswap eax
    mov [rbp + rcx * 4], eax
    inc ecx
    cmp ecx, 16
    jb .load
    ; W[t] = s1(W[t-2]) + W[t-7] + s0(W[t-15]) + W[t-16]
.expand:
    mov eax, [rbp + rcx * 4 - 2 * 4]
    mov edx, eax
    ror edx, 17
    mov ebx, eax
    ror ebx, 19
    xor edx, ebx
    shr eax, 10
    xor edx, eax                    ; s1
    add edx, [rbp + rcx * 4 - 7 * 4]
    mov eax, [rbp + rcx * 4 - 15 * 4]
    mov ebx, eax
    ror ebx, 7
    mov esi, eax
    ror esi, 18
    xor ebx, esi
    shr eax, 3
    xor ebx, eax                    ; s0
    add edx, ebx
    add edx, [rbp + rcx * 4 - 16 * 4]
    mov [rbp + rcx * 4], edx
    inc ecx
    cmp ecx, 64
    jb .expand

    ; a..h = r8d..r15d
    mov r8d, [rdi + 0]
    mov r9d, [rdi + 4]
    mov r10d, [rdi + 8]
    mov r11d, [rdi + 12]
    mov r12d, [rdi + 16]
    mov r13d, [rdi + 20]
    mov r14d, [rdi + 24]
    mov r15d, [rdi + 28]
    xor ecx, ecx
.round:
    ; T1 = h + S1(e) + Ch(e,f,g) + K[t] + W[t]
    mov eax, r12d
    ror eax, 6
    mov ebx, r12d
    ror ebx, 11
    xor eax, ebx
    mov ebx, r12d
    ror ebx, 25
    xor eax, ebx                    ; S1
    mov ebx, r12d
    and ebx, r13d
    mov edx, r12d
    not edx
    and edx, r14d
    xor ebx, edx                    ; Ch
    add eax, ebx
    add eax, r15d
    lea rsi, [sha256_k]
    add eax, [rsi + rcx * 4]
    add eax, [rbp + rcx * 4]        ; EAX = T1
    ; T2 = S0(a) + Maj(a,b,c)
    mov ebx, r8d
    ror ebx, 2
    mov edx, r8d
    ror edx, 13
    xor ebx, edx
    mov edx, r8d
    ror edx, 22
    xor ebx, edx                    ; S0
    mov edx, r8d
    and edx, r9d
    mov esi, r8d
    and esi, r10d
    xor edx, esi
    mov esi, r9d
    and esi, r10d
    xor edx, esi                    ; Maj
    add ebx, edx                    ; EBX = T2
    mov r15d, r14d                  ; h = g
    mov r14d, r13d                  ; g = f
    mov r13d, r12d                  ; f = e
    lea r12d, [r11d + eax]          ; e = d + T1
    mov r11d, r10d                  ; d = c
    mov r10d, r9d                   ; c = b
    mov r9d, r8d                    ; b = a
    lea r8d, [eax + ebx]            ; a = T1 + T2
    inc ecx
    cmp ecx, 64
    jb .round

    add [rdi + 0], r8d
    add [rdi + 4], r9d
    add [rdi + 8], r10d
    add [rdi + 12], r11d
    add [rdi + 16], r12d
    add [rdi + 20], r13d
    add [rdi + 24], r14d
    add [rdi + 28], r15d

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

; ------------------------------------------------------------------------------
; hmac_sha256: RSI = key (at most 64 bytes), RCX = key length,
;              RDX = message, R8 = message length, RDI = 32-byte output
; The output may overlap the key or the message.
; ------------------------------------------------------------------------------
hmac_sha256:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    mov rbx, rdi                    ; RBX = output

    ; inner = SHA256((key ^ ipad) || message)
    mov al, 0x36
    call .make_pad
    lea rdi, [hmac_ctx]
    call sha256_init
    lea rsi, [hmac_pad]
    push rcx
    mov ecx, 64
    call sha256_update
    pop rcx
    push rsi
    push rcx
    mov rsi, rdx
    mov rcx, r8
    call sha256_update
    lea rsi, [hmac_inner]
    call sha256_final
    pop rcx
    pop rsi

    ; output = SHA256((key ^ opad) || inner). The key is read again here,
    ; so an output overlapping the key is only written at the very end.
    mov rsi, [rsp + 8]              ; key (saved RSI)
    mov al, 0x5c
    call .make_pad
    lea rdi, [hmac_ctx]
    call sha256_init
    lea rsi, [hmac_pad]
    mov ecx, 64
    call sha256_update
    lea rsi, [hmac_inner]
    mov ecx, 32
    call sha256_update
    mov rsi, rbx
    call sha256_final

    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; .make_pad: hmac_pad = key (RSI, RCX bytes) zero-padded to 64, XOR AL
.make_pad:
    push rcx
    push rdx
    push rdi
    lea rdi, [hmac_pad]
    xor edx, edx
.pad_byte:
    xor ah, ah
    cmp rdx, rcx
    jae .pad_store
    mov ah, [rsi + rdx]
.pad_store:
    xor ah, al
    mov [rdi + rdx], ah
    inc edx
    cmp edx, 64
    jb .pad_byte
    pop rdi
    pop rdx
    pop rcx
    ret

section .rodata
sha256_pad_80:          db 0x80
section .text
