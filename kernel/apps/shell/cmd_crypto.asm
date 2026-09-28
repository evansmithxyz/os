; ==============================================================================
; Shell commands: cryptotest
; Handlers: RSI = arguments; may clobber any register except RSP.
; ------------------------------------------------------------------------------
; cryptotest runs every primitive the TLS client uses on fixed inputs (mostly
; the RFC test vectors) and prints the results in hex. tests/test_tls.py
; compares each line with tests/crypto_ref.py.
; ==============================================================================

[bits 64]

CT_AEAD_LEN             equ 114     ; length of ct_aead_plain

section .bss
alignb 16
ct_out:                 resb 64
ct_buf:                 resb 256

section .rodata
ct_msg_sha_abc:         db "sha256 abc: ", 0
ct_msg_sha_long:        db "sha256 200: ", 0
ct_msg_hmac:            db "hmac jefe: ", 0
ct_msg_chacha:          db "chacha20 block: ", 0
ct_msg_poly:            db "poly1305: ", 0
ct_msg_aead:            db "aead seal: ", 0
ct_msg_open_ok:         db "aead open: ok", 0x0A, 0
ct_msg_open_bad:        db "aead open: FAILED", 0x0A, 0
ct_msg_tamper_ok:       db "aead tamper: rejected", 0x0A, 0
ct_msg_tamper_bad:      db "aead tamper: ACCEPTED", 0x0A, 0
ct_msg_x_rfc:           db "x25519 rfc: ", 0
ct_msg_x_base:          db "x25519 base: ", 0
ct_msg_x_shared:        db "x25519 shared: ", 0
ct_msg_rand:            db "random: ", 0

ct_abc:                 db "abc"
ct_jefe:                db "Jefe"
ct_jefe_msg:            db "what do ya want for nothing?"
ct_jefe_msg_len         equ $ - ct_jefe_msg
ct_chacha_nonce:        db 0, 0, 0, 9, 0, 0, 0, 0x4a, 0, 0, 0, 0
ct_poly_key:
    db 0x85, 0xd6, 0xbe, 0x78, 0x57, 0x55, 0x6d, 0x33, 0x7f, 0x44, 0x52, 0xfe, 0x42, 0xd5, 0x06, 0xa8
    db 0x01, 0x03, 0x80, 0x8a, 0xfb, 0x0d, 0xb2, 0xfd, 0x4a, 0xbf, 0xf6, 0xaf, 0x41, 0x49, 0xf5, 0x1b
ct_poly_msg:            db "Cryptographic Forum Research Group"
ct_poly_msg_len         equ $ - ct_poly_msg
ct_aead_nonce:          db 0x07, 0, 0, 0, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47
ct_aead_aad:            db 0x50, 0x51, 0x52, 0x53, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7
ct_aead_plain:
    db "Ladies and Gentlemen of the class of '99: If I could offer you only one "
    db "tip for the future, sunscreen would be it."
ct_x_scalar:
    db 0xa5, 0x46, 0xe3, 0x6b, 0xf0, 0x52, 0x7c, 0x9d, 0x3b, 0x16, 0x15, 0x4b, 0x82, 0x46, 0x5e, 0xdd
    db 0x62, 0x14, 0x4c, 0x0a, 0xc1, 0xfc, 0x5a, 0x18, 0x50, 0x6a, 0x22, 0x44, 0xba, 0x44, 0x9a, 0xc4
ct_x_u:
    db 0xe6, 0xdb, 0x68, 0x67, 0x58, 0x30, 0x30, 0xdb, 0x35, 0x94, 0xc1, 0xa4, 0x24, 0xb1, 0x5f, 0x7c
    db 0x72, 0x66, 0x24, 0xec, 0x26, 0xb3, 0x35, 0x3b, 0x10, 0xa9, 0x03, 0xa6, 0xd0, 0xab, 0x1c, 0x4c
ct_x_alice:
    db 0x77, 0x07, 0x6d, 0x0a, 0x73, 0x18, 0xa5, 0x7d, 0x3c, 0x16, 0xc1, 0x72, 0x51, 0xb2, 0x66, 0x45
    db 0xdf, 0x4c, 0x2f, 0x87, 0xeb, 0xc0, 0x99, 0x2a, 0xb1, 0x77, 0xfb, 0xa5, 0x1d, 0xb9, 0x2c, 0x2a
ct_x_bob_pub:
    db 0xde, 0x9e, 0xdb, 0x7d, 0x7b, 0x7d, 0xc1, 0xb4, 0xd3, 0x5b, 0x61, 0xc2, 0xec, 0xe4, 0x35, 0x37
    db 0x3f, 0x83, 0x43, 0xc8, 0x5b, 0x78, 0x67, 0x4d, 0xad, 0xfc, 0x7e, 0x14, 0x6f, 0x88, 0x2b, 0x4f

section .text
; ct_hex_line: RSI = label, RDI = bytes, ECX = count -> "label" + hex + newline
ct_hex_line:
    push rax
    push rcx
    push rdi
    call con_puts
.byte:
    mov al, [rdi]
    call con_hex8
    inc rdi
    dec ecx
    jnz .byte
    call con_newline
    pop rdi
    pop rcx
    pop rax
    ret

; ct_counting_bytes: RDI = buffer, ECX = count, AL = first value -> AL, AL+1, ...
ct_counting_bytes:
    push rcx
    push rdi
.fill:
    stosb
    inc al
    dec ecx
    jnz .fill
    pop rdi
    pop rcx
    ret

cmd_cryptotest:
    ; SHA-256 of "abc" and of bytes 0..199 (several blocks, partial last one)
    lea rsi, [ct_abc]
    mov ecx, 3
    lea rdi, [ct_out]
    call sha256
    lea rsi, [ct_msg_sha_abc]
    mov ecx, 32
    call ct_hex_line
    lea rdi, [ct_buf]
    mov ecx, 200
    xor eax, eax
    call ct_counting_bytes
    mov rsi, rdi
    lea rdi, [ct_out]
    call sha256
    lea rsi, [ct_msg_sha_long]
    mov ecx, 32
    call ct_hex_line

    ; HMAC-SHA256, RFC 4231 test case 2
    lea rsi, [ct_jefe]
    mov ecx, 4
    lea rdx, [ct_jefe_msg]
    mov r8d, ct_jefe_msg_len
    lea rdi, [ct_out]
    call hmac_sha256
    lea rsi, [ct_msg_hmac]
    mov ecx, 32
    call ct_hex_line

    ; ChaCha20 block, RFC 8439 2.3.2 (key 00..1f, counter 1)
    lea rdi, [ct_buf]
    mov ecx, 32
    xor eax, eax
    call ct_counting_bytes
    mov rsi, rdi
    lea rdx, [ct_chacha_nonce]
    mov ecx, 1
    lea rdi, [ct_out]
    call chacha20_block
    lea rsi, [ct_msg_chacha]
    mov ecx, 64
    call ct_hex_line

    ; Poly1305, RFC 8439 2.5.2
    lea rsi, [ct_poly_key]
    call poly1305_init
    lea rsi, [ct_poly_msg]
    mov ecx, ct_poly_msg_len
    call poly1305_update
    lea rdi, [ct_out]
    call poly1305_final
    lea rsi, [ct_msg_poly]
    mov ecx, 16
    call ct_hex_line

    ; AEAD, RFC 8439 2.8.2 (key 80..9f): seal, open, and reject a flipped bit
    lea rdi, [ct_out]
    mov ecx, 32
    mov al, 0x80
    call ct_counting_bytes
    lea rsi, [ct_aead_plain]
    lea rdi, [ct_buf]
    mov ecx, CT_AEAD_LEN
    rep movsb
    lea rsi, [ct_out]
    lea rdx, [ct_aead_nonce]
    lea r9, [ct_aead_aad]
    mov r10d, 12
    lea rdi, [ct_buf]
    mov r8d, CT_AEAD_LEN
    call aead_seal
    push rsi
    lea rsi, [ct_msg_aead]
    mov ecx, CT_AEAD_LEN + 16
    call ct_hex_line
    pop rsi
    call aead_open
    jc .open_bad
    push rsi
    lea rsi, [ct_aead_plain]
    mov ecx, CT_AEAD_LEN
    repe cmpsb
    pop rsi
    jne .open_bad
    push rsi
    lea rsi, [ct_msg_open_ok]
    call con_puts
    pop rsi
    jmp .tamper
.open_bad:
    push rsi
    lea rsi, [ct_msg_open_bad]
    call con_puts
    pop rsi
.tamper:
    lea rdi, [ct_buf]
    call aead_seal
    xor byte [rdi + 5], 1
    call aead_open
    lea rsi, [ct_msg_tamper_ok]
    jc .tamper_msg
    lea rsi, [ct_msg_tamper_bad]
.tamper_msg:
    call con_puts

    ; X25519: RFC 7748 5.2 vector, Alice's public key, Alice x Bob
    lea rsi, [ct_x_scalar]
    lea rdx, [ct_x_u]
    lea rdi, [ct_out]
    call x25519
    lea rsi, [ct_msg_x_rfc]
    mov ecx, 32
    call ct_hex_line
    lea rsi, [ct_x_alice]
    lea rdi, [ct_out]
    call x25519_base
    lea rsi, [ct_msg_x_base]
    mov ecx, 32
    call ct_hex_line
    lea rsi, [ct_x_alice]
    lea rdx, [ct_x_bob_pub]
    lea rdi, [ct_out]
    call x25519
    lea rsi, [ct_msg_x_shared]
    mov ecx, 32
    call ct_hex_line

    ; two blocks of random bytes (the test checks they differ)
    lea rdi, [ct_out]
    mov ecx, 16
    call rand_bytes
    lea rsi, [ct_msg_rand]
    call ct_hex_line
    call rand_bytes
    call ct_hex_line
    ret
