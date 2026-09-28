; ==============================================================================
; Antigravity OS - ChaCha20, Poly1305 and the ChaCha20-Poly1305 AEAD (RFC 8439)
; ------------------------------------------------------------------------------
; One Poly1305 computation at a time (a single global state); TLS only ever
; needs one.
; ==============================================================================

[bits 64]

section .bss
alignb 16
chacha_state:           resd 16     ; input block
chacha_x:               resd 16     ; working copy
chacha_ks:              resb 64     ; key stream block
poly_r0:                resq 1
poly_r1:                resq 1
poly_s1:                resq 1      ; r1 + r1/4
poly_h0:                resq 1
poly_h1:                resq 1
poly_h2:                resq 1
poly_pad:               resq 2      ; s, added at the end
poly_buf:               resb 16
poly_buflen:            resd 1
aead_otk:               resb 64     ; one-time Poly1305 key (first 32 bytes)
aead_lens:              resq 2
aead_tag:               resb 16

section .rodata
chacha_zero16:          times 16 db 0

section .text

%macro CHACHA_QR 4
    mov eax, [rsi + %1 * 4]
    mov ebx, [rsi + %2 * 4]
    mov ecx, [rsi + %3 * 4]
    mov edx, [rsi + %4 * 4]
    add eax, ebx
    xor edx, eax
    rol edx, 16
    add ecx, edx
    xor ebx, ecx
    rol ebx, 12
    add eax, ebx
    xor edx, eax
    rol edx, 8
    add ecx, edx
    xor ebx, ecx
    rol ebx, 7
    mov [rsi + %1 * 4], eax
    mov [rsi + %2 * 4], ebx
    mov [rsi + %3 * 4], ecx
    mov [rsi + %4 * 4], edx
%endmacro

; ------------------------------------------------------------------------------
; chacha20_block: RSI = 32-byte key, RDX = 12-byte nonce, ECX = block counter,
;                 RDI = 64-byte output (key stream)
; ------------------------------------------------------------------------------
chacha20_block:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    ; state = constants | key | counter | nonce
    lea r8, [chacha_state]
    mov dword [r8 + 0], 0x61707865
    mov dword [r8 + 4], 0x3320646e
    mov dword [r8 + 8], 0x79622d32
    mov dword [r8 + 12], 0x6b206574
    mov rax, [rsi + 0]
    mov [r8 + 16], rax
    mov rax, [rsi + 8]
    mov [r8 + 24], rax
    mov rax, [rsi + 16]
    mov [r8 + 32], rax
    mov rax, [rsi + 24]
    mov [r8 + 40], rax
    mov [r8 + 48], ecx
    mov eax, [rdx + 0]
    mov [r8 + 52], eax
    mov rax, [rdx + 4]
    mov [r8 + 56], rax

    ; x = state, 10 double rounds
    lea rsi, [chacha_x]
    xor ecx, ecx
.copy:
    mov rax, [r8 + rcx * 8]
    mov [rsi + rcx * 8], rax
    inc ecx
    cmp ecx, 8
    jb .copy
    mov r9d, 10
.double_round:
    CHACHA_QR 0, 4, 8, 12
    CHACHA_QR 1, 5, 9, 13
    CHACHA_QR 2, 6, 10, 14
    CHACHA_QR 3, 7, 11, 15
    CHACHA_QR 0, 5, 10, 15
    CHACHA_QR 1, 6, 11, 12
    CHACHA_QR 2, 7, 8, 13
    CHACHA_QR 3, 4, 9, 14
    dec r9d
    jnz .double_round

    ; out = x + state (little-endian words, already in memory order)
    xor ecx, ecx
.add:
    mov eax, [rsi + rcx * 4]
    add eax, [r8 + rcx * 4]
    mov [rdi + rcx * 4], eax
    inc ecx
    cmp ecx, 16
    jb .add

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
; chacha20_xor: RSI = key, RDX = nonce, ECX = first block counter,
;               RDI = data (encrypted or decrypted in place), R8 = length
; ------------------------------------------------------------------------------
chacha20_xor:
    push rax
    push rbx
    push rcx
    push rdi
    push r8
    push r9
.block:
    test r8, r8
    jz .done
    push rdi
    lea rdi, [chacha_ks]
    call chacha20_block
    pop rdi
    inc ecx
    xor ebx, ebx
.byte:
    lea r9, [chacha_ks]
    mov al, [r9 + rbx]
    xor [rdi], al
    inc rdi
    dec r8
    jz .done
    inc ebx
    cmp ebx, 64
    jb .byte
    jmp .block
.done:
    pop r9
    pop r8
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; poly1305_init: RSI = 32-byte one-time key (r | s)
; ------------------------------------------------------------------------------
poly1305_init:
    push rax
    push rdx
    mov rax, [rsi + 0]
    mov rdx, 0x0ffffffc0fffffff
    and rax, rdx
    mov [poly_r0], rax
    mov rax, [rsi + 8]
    mov rdx, 0x0ffffffc0ffffffc
    and rax, rdx
    mov [poly_r1], rax
    mov rdx, rax
    shr rdx, 2
    add rax, rdx
    mov [poly_s1], rax
    mov rax, [rsi + 16]
    mov [poly_pad], rax
    mov rax, [rsi + 24]
    mov [poly_pad + 8], rax
    xor eax, eax
    mov [poly_h0], rax
    mov [poly_h1], rax
    mov [poly_h2], rax
    mov [poly_buflen], eax
    pop rdx
    pop rax
    ret

; ------------------------------------------------------------------------------
; poly1305_update: RSI = data, RCX = length
; ------------------------------------------------------------------------------
poly1305_update:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
.loop:
    test rcx, rcx
    jz .done
    mov edx, [poly_buflen]
    test edx, edx
    jnz .buffer
    cmp rcx, 16                     ; whole blocks straight from the input
    jb .buffer
    mov eax, 1
    call poly1305_block
    add rsi, 16
    sub rcx, 16
    jmp .loop
.buffer:
    lea rdi, [poly_buf]
    mov al, [rsi]
    mov [rdi + rdx], al
    inc rsi
    dec rcx
    inc edx
    mov [poly_buflen], edx
    cmp edx, 16
    jb .loop
    push rsi
    mov rsi, rdi
    mov eax, 1
    call poly1305_block
    pop rsi
    mov dword [poly_buflen], 0
    jmp .loop
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; poly1305_block: RSI = 16 bytes, EAX = 1 to add 2^128 (full block) or 0
; h = (h + m) * r  mod 2^130 - 5, with h in three 64-bit limbs
; ------------------------------------------------------------------------------
poly1305_block:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13

    ; h += m
    mov r8, [poly_h0]
    mov r9, [poly_h1]
    mov r10, [poly_h2]
    add r8, [rsi]
    adc r9, [rsi + 8]
    adc r10, rax

    ; d0 = h0*r0 + h1*s1
    mov rax, r8
    mul qword [poly_r0]
    mov r11, rax
    mov r12, rdx
    mov rax, r9
    mul qword [poly_s1]
    add r11, rax
    adc r12, rdx                    ; R12:R11 = d0
    ; d1 = h0*r1 + h1*r0 + h2*s1
    mov rax, r8
    mul qword [poly_r1]
    mov rbx, rax
    mov rcx, rdx
    mov rax, r9
    mul qword [poly_r0]
    add rbx, rax
    adc rcx, rdx
    mov rax, r10
    mul qword [poly_s1]
    add rbx, rax
    adc rcx, rdx                    ; RCX:RBX = d1
    ; d2 = h2*r0
    mov rax, r10
    mul qword [poly_r0]
    mov r13, rax                    ; R13 = d2 (h2 is tiny, so it fits)

    ; carry: h0 = lo(d0), d1 += hi(d0), h1 = lo(d1), h2 = d2 + hi(d1)
    add rbx, r12
    adc rcx, 0
    add r13, rcx
    ; partial reduction: the bits of h2 above 2 are multiples of 2^130 = 5
    mov rax, r13
    shr rax, 2
    and r13, 3
    lea rax, [rax + rax * 4]
    add r11, rax
    adc rbx, 0
    adc r13, 0

    mov [poly_h0], r11
    mov [poly_h1], rbx
    mov [poly_h2], r13

    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; poly1305_final: RDI = 16-byte tag output
; ------------------------------------------------------------------------------
poly1305_final:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10

    ; last partial block: bytes, then 0x01, then zeros; no 2^128 bit
    mov edx, [poly_buflen]
    test edx, edx
    jz .reduce
    lea rsi, [poly_buf]
    mov byte [rsi + rdx], 1
.zero:
    inc edx
    cmp edx, 16
    jae .last
    mov byte [rsi + rdx], 0
    jmp .zero
.last:
    xor eax, eax
    call poly1305_block

.reduce:
    mov r8, [poly_h0]
    mov r9, [poly_h1]
    mov r10, [poly_h2]
    ; fold h2 bits above 2 once more
    mov rax, r10
    shr rax, 2
    and r10, 3
    lea rax, [rax + rax * 4]
    add r8, rax
    adc r9, 0
    adc r10, 0
    ; g = h + 5; if g >= 2^130 then h = g - 2^130 (h was >= p)
    mov rax, r8
    mov rbx, r9
    mov rcx, r10
    add rax, 5
    adc rbx, 0
    adc rcx, 0
    shr rcx, 2
    jz .add_s
    mov r8, rax
    mov r9, rbx
.add_s:
    ; tag = (h + s) mod 2^128
    add r8, [poly_pad]
    adc r9, [poly_pad + 8]
    mov [rdi], r8
    mov [rdi + 8], r9

    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; aead_mac: shared by seal and open. RSI = key, RDX = nonce,
;           R9 = AAD, R10 = AAD length, RDI = ciphertext, R8 = its length
; Output: aead_tag
; ------------------------------------------------------------------------------
aead_mac:
    push rax
    push rcx
    push rsi
    push rdi
    ; one-time key = first 32 bytes of block 0
    push rdi
    lea rdi, [aead_otk]
    xor ecx, ecx
    call chacha20_block
    pop rdi
    lea rsi, [aead_otk]
    call poly1305_init
    ; AAD || pad16 || ciphertext || pad16 || le64(len AAD) || le64(len ct)
    mov rsi, r9
    mov rcx, r10
    call poly1305_update
    mov rcx, r10
    call .pad16
    mov rsi, rdi
    mov rcx, r8
    call poly1305_update
    mov rcx, r8
    call .pad16
    mov [aead_lens], r10
    mov [aead_lens + 8], r8
    lea rsi, [aead_lens]
    mov ecx, 16
    call poly1305_update
    lea rdi, [aead_tag]
    call poly1305_final
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret
; .pad16: feed zeros up to the next multiple of 16 after RCX bytes
.pad16:
    neg rcx
    and ecx, 15
    jz .no_pad
    push rsi
    lea rsi, [chacha_zero16]
    call poly1305_update
    pop rsi
.no_pad:
    ret

; ------------------------------------------------------------------------------
; aead_seal: RSI = key, RDX = nonce, R9 = AAD, R10 = AAD length,
;            RDI = plaintext (encrypted in place), R8 = length.
; The 16-byte tag is written right after the data (RDI + R8).
; ------------------------------------------------------------------------------
aead_seal:
    push rax
    push rcx
    push rsi
    push rdi
    mov ecx, 1
    call chacha20_xor
    call aead_mac
    lea rsi, [aead_tag]
    add rdi, r8
    mov ecx, 16
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; aead_open: RSI = key, RDX = nonce, R9 = AAD, R10 = AAD length,
;            RDI = ciphertext followed by its tag, R8 = ciphertext length
; Output: CF=1 if the tag is wrong (nothing is decrypted); otherwise the data
; is decrypted in place.
; ------------------------------------------------------------------------------
aead_open:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    call aead_mac
    ; compare all 16 bytes without an early exit
    lea rbx, [rdi + r8]             ; received tag
    lea rdi, [aead_tag]             ; computed tag
    xor eax, eax
    xor ecx, ecx
.cmp:
    mov dl, [rbx + rcx]
    xor dl, [rdi + rcx]
    or al, dl
    inc ecx
    cmp ecx, 16
    jb .cmp
    mov rdi, [rsp]
    mov rdx, [rsp + 8]
    test al, al
    jnz .bad
    mov ecx, 1
    call chacha20_xor
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret
.bad:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret
