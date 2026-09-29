; ==============================================================================
; Antigravity OS - ECDSA signature verification on NIST P-256 and P-384
; ------------------------------------------------------------------------------
; Both curves are y^2 = x^3 - 3x + b over a prime field. Field elements live in
; Montgomery form (bignum.asm) with the curve's field context; points are
; Jacobian (X, Y, Z) with Z = 0 for the point at infinity. u1*G + u2*Q is
; computed with Shamir's trick. Verification only, so nothing here is
; constant time.
; ==============================================================================

[bits 64]

EC_MAX_LIMBS            equ 6
EC_FE                   equ EC_MAX_LIMBS * 8        ; bytes per field element

; curve record
EC_READY                equ 0       ; db 1 once the contexts are built
EC_BYTES                equ 4       ; dd 32 or 48
EC_CONST                equ 8       ; dq big-endian constants: p, n, b, Gx, Gy
EC_P                    equ 16                      ; Montgomery context mod p
EC_N                    equ EC_P + MONT_SIZE        ; Montgomery context mod n
EC_B                    equ EC_N + MONT_SIZE        ; b (Montgomery form)
EC_GX                   equ EC_B + EC_FE            ; G (Montgomery form)
EC_GY                   equ EC_GX + EC_FE
EC_ONE                  equ EC_GY + EC_FE           ; 1 (Montgomery form)
EC_SIZE                 equ EC_ONE + EC_FE

; Jacobian point
PT_X                    equ 0
PT_Y                    equ EC_FE
PT_Z                    equ EC_FE * 2
PT_SIZE                 equ EC_FE * 3

%macro FMUL 3                       ; %1 = %2 * %3 (field, RBX = p context)
    lea rdi, [%1]
    lea rsi, [%2]
    lea rdx, [%3]
    call mont_mul
%endmacro
%macro FADD 3
    lea rdi, [%1]
    lea rsi, [%2]
    lea rdx, [%3]
    call mont_modadd
%endmacro
%macro FSUB 3
    lea rdi, [%1]
    lea rsi, [%2]
    lea rdx, [%3]
    call mont_modsub
%endmacro
%macro FCOPY 2
    lea rdi, [%1]
    lea rsi, [%2]
    call ec_fe_copy
%endmacro

section .bss
alignb 16
ec_p256:                resb EC_SIZE
ec_p384:                resb EC_SIZE
ec_curve:               resq 1      ; the curve in use
ec_limbs:               resd 1
alignb 16
ec_t0:                  resb EC_FE
ec_t1:                  resb EC_FE
ec_t2:                  resb EC_FE
ec_t3:                  resb EC_FE
ec_t4:                  resb EC_FE
ec_t5:                  resb EC_FE
ec_t6:                  resb EC_FE
ec_t7:                  resb EC_FE
ec_r:                   resb EC_FE  ; signature r
ec_s:                   resb EC_FE  ; signature s
ec_e:                   resb EC_FE  ; hash as a number
ec_w:                   resb EC_FE
ec_u1:                  resb EC_FE
ec_u2:                  resb EC_FE
ec_exp:                 resb EC_FE  ; p - 2 or n - 2, big-endian
ec_hash:                resb HASH_MAX_LEN
ec_ptG:                 resb PT_SIZE
ec_ptQ:                 resb PT_SIZE
ec_ptGQ:                resb PT_SIZE
ec_ptR:                 resb PT_SIZE
ec_ptTmp:               resb PT_SIZE

section .rodata
; P-256 (secp256r1): p, n, b, Gx, Gy
ec_p256_const:
    db 0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xBC,0xE6,0xFA,0xAD,0xA7,0x17,0x9E,0x84,0xF3,0xB9,0xCA,0xC2,0xFC,0x63,0x25,0x51
    db 0x5A,0xC6,0x35,0xD8,0xAA,0x3A,0x93,0xE7,0xB3,0xEB,0xBD,0x55,0x76,0x98,0x86,0xBC
    db 0x65,0x1D,0x06,0xB0,0xCC,0x53,0xB0,0xF6,0x3B,0xCE,0x3C,0x3E,0x27,0xD2,0x60,0x4B
    db 0x6B,0x17,0xD1,0xF2,0xE1,0x2C,0x42,0x47,0xF8,0xBC,0xE6,0xE5,0x63,0xA4,0x40,0xF2
    db 0x77,0x03,0x7D,0x81,0x2D,0xEB,0x33,0xA0,0xF4,0xA1,0x39,0x45,0xD8,0x98,0xC2,0x96
    db 0x4F,0xE3,0x42,0xE2,0xFE,0x1A,0x7F,0x9B,0x8E,0xE7,0xEB,0x4A,0x7C,0x0F,0x9E,0x16
    db 0x2B,0xCE,0x33,0x57,0x6B,0x31,0x5E,0xCE,0xCB,0xB6,0x40,0x68,0x37,0xBF,0x51,0xF5
; P-384 (secp384r1): p, n, b, Gx, Gy
ec_p384_const:
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFE
    db 0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF,0xFF,0xFF,0xFF
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xC7,0x63,0x4D,0x81,0xF4,0x37,0x2D,0xDF
    db 0x58,0x1A,0x0D,0xB2,0x48,0xB0,0xA7,0x7A,0xEC,0xEC,0x19,0x6A,0xCC,0xC5,0x29,0x73
    db 0xB3,0x31,0x2F,0xA7,0xE2,0x3E,0xE7,0xE4,0x98,0x8E,0x05,0x6B,0xE3,0xF8,0x2D,0x19
    db 0x18,0x1D,0x9C,0x6E,0xFE,0x81,0x41,0x12,0x03,0x14,0x08,0x8F,0x50,0x13,0x87,0x5A
    db 0xC6,0x56,0x39,0x8D,0x8A,0x2E,0xD1,0x9D,0x2A,0x85,0xC8,0xED,0xD3,0xEC,0x2A,0xEF
    db 0xAA,0x87,0xCA,0x22,0xBE,0x8B,0x05,0x37,0x8E,0xB1,0xC7,0x1E,0xF3,0x20,0xAD,0x74
    db 0x6E,0x1D,0x3B,0x62,0x8B,0xA7,0x9B,0x98,0x59,0xF7,0x41,0xE0,0x82,0x54,0x2A,0x38
    db 0x55,0x02,0xF2,0x5D,0xBF,0x55,0x29,0x6C,0x3A,0x54,0x5E,0x38,0x72,0x76,0x0A,0xB7
    db 0x36,0x17,0xDE,0x4A,0x96,0x26,0x2C,0x6F,0x5D,0x9E,0x98,0xBF,0x92,0x92,0xDC,0x29
    db 0xF8,0xF4,0x1D,0xBD,0x28,0x9A,0x14,0x7C,0xE9,0xDA,0x31,0x13,0xB5,0xF0,0xB8,0xC0
    db 0x0A,0x60,0xB1,0xCE,0x1D,0x7E,0x81,0x9D,0x7A,0x43,0x1D,0x7C,0x90,0xEA,0x0E,0x5F

section .text
; ------------------------------------------------------------------------------
; ec_select: AL = PK_TYPE_P256 / PK_TYPE_P384 -> RBX = the curve's field
; context (ec_curve, ec_limbs set, contexts built on first use); CF=1 otherwise
; ------------------------------------------------------------------------------
ec_select:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    cmp al, PK_TYPE_P256
    jne .p384
    lea r8, [ec_p256]
    lea rsi, [ec_p256_const]
    mov ecx, 32
    jmp .have
.p384:
    cmp al, PK_TYPE_P384
    jne .unknown
    lea r8, [ec_p384]
    lea rsi, [ec_p384_const]
    mov ecx, 48
.have:
    mov [ec_curve], r8
    mov eax, ecx
    shr eax, 3
    mov [ec_limbs], eax
    cmp byte [r8 + EC_READY], 1
    je .ready
    mov [r8 + EC_BYTES], ecx
    mov [r8 + EC_CONST], rsi
    lea rbx, [r8 + EC_P]            ; field
    call mont_setup
    add rsi, rcx
    lea rbx, [r8 + EC_N]            ; group order
    call mont_setup
    add rsi, rcx
    ; b, Gx, Gy and 1 into Montgomery form
    lea rbx, [r8 + EC_P]
    lea rdi, [r8 + EC_B]
    call ec_load_mont
    add rsi, rcx
    lea rdi, [r8 + EC_GX]
    call ec_load_mont
    add rsi, rcx
    lea rdi, [r8 + EC_GY]
    call ec_load_mont
    call bn_set_one
    lea rsi, [bn_one]
    lea rdi, [r8 + EC_ONE]
    call mont_to
    mov byte [r8 + EC_READY], 1
.ready:
    lea rbx, [r8 + EC_P]
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.unknown:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; ec_load_mont: RSI = big-endian bytes (ECX of them), RDI = out, RBX = context
; -> out = value in Montgomery form (the value must be below the modulus)
ec_load_mont:
    push rcx
    push rdx
    push rsi
    mov rdx, rcx
    mov ecx, [rbx + MONT_K]
    call bn_from_bytes
    mov rsi, rdi
    call mont_to
    pop rsi
    pop rdx
    pop rcx
    ret

; ec_fe_copy: RDI = out, RSI = field element (ec_limbs limbs)
ec_fe_copy:
    push rcx
    mov ecx, [ec_limbs]
    call bn_copy
    pop rcx
    ret

; ------------------------------------------------------------------------------
; ec_double: RDI = out point, RSI = point (may be the same), RBX = field
; (dbl-2001-b for a = -3)
; ------------------------------------------------------------------------------
ec_double:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    mov r12, rsi
    mov r13, rdi
    lea rsi, [r12 + PT_Z]
    mov ecx, [ec_limbs]
    call bn_is_zero
    jz .infinity
    FMUL ec_t0, r12 + PT_Z, r12 + PT_Z          ; delta = Z^2
    FMUL ec_t1, r12 + PT_Y, r12 + PT_Y          ; gamma = Y^2
    FMUL ec_t2, r12 + PT_X, ec_t1               ; beta = X * gamma
    FSUB ec_t3, r12 + PT_X, ec_t0
    FADD ec_t4, r12 + PT_X, ec_t0
    FMUL ec_t3, ec_t3, ec_t4                    ; (X - delta)(X + delta)
    FADD ec_t4, ec_t3, ec_t3
    FADD ec_t3, ec_t4, ec_t3                    ; alpha = 3 * that
    ; Z3 = (Y + Z)^2 - gamma - delta
    FADD ec_t5, r12 + PT_Y, r12 + PT_Z
    FMUL ec_t5, ec_t5, ec_t5
    FSUB ec_t5, ec_t5, ec_t1
    FSUB ec_t5, ec_t5, ec_t0
    ; X3 = alpha^2 - 8 beta
    FADD ec_t4, ec_t2, ec_t2                    ; 2 beta
    FADD ec_t4, ec_t4, ec_t4                    ; 4 beta
    FADD ec_t6, ec_t4, ec_t4                    ; 8 beta
    FMUL ec_t7, ec_t3, ec_t3
    FSUB ec_t7, ec_t7, ec_t6                    ; X3
    ; Y3 = alpha (4 beta - X3) - 8 gamma^2
    FSUB ec_t4, ec_t4, ec_t7
    FMUL ec_t4, ec_t3, ec_t4
    FMUL ec_t1, ec_t1, ec_t1                    ; gamma^2
    FADD ec_t1, ec_t1, ec_t1
    FADD ec_t1, ec_t1, ec_t1
    FADD ec_t1, ec_t1, ec_t1                    ; 8 gamma^2
    FSUB ec_t4, ec_t4, ec_t1                    ; Y3
    FCOPY r13 + PT_X, ec_t7
    FCOPY r13 + PT_Y, ec_t4
    FCOPY r13 + PT_Z, ec_t5
    jmp .done
.infinity:
    lea rdi, [r13 + PT_Z]
    mov ecx, [ec_limbs]
    xor eax, eax
    rep stosq
.done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; ec_add: RDI = out point, RSI = P, RDX = Q (out may be P or Q), RBX = field
; (add-1998-cmo-2, falling back to doubling when P = Q)
; ------------------------------------------------------------------------------
ec_add:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    mov r12, rsi                    ; P
    mov r13, rdx                    ; Q
    mov r14, rdi                    ; out
    mov ecx, [ec_limbs]
    lea rsi, [r12 + PT_Z]
    call bn_is_zero
    jz .return_q
    lea rsi, [r13 + PT_Z]
    call bn_is_zero
    jz .return_p

    FMUL ec_t0, r12 + PT_Z, r12 + PT_Z          ; Z1Z1
    FMUL ec_t1, r13 + PT_Z, r13 + PT_Z          ; Z2Z2
    FMUL ec_t2, r12 + PT_X, ec_t1               ; U1 = X1 Z2Z2
    FMUL ec_t3, r13 + PT_X, ec_t0               ; U2 = X2 Z1Z1
    FMUL ec_t4, r13 + PT_Z, ec_t1
    FMUL ec_t4, r12 + PT_Y, ec_t4               ; S1 = Y1 Z2^3
    FMUL ec_t5, r12 + PT_Z, ec_t0
    FMUL ec_t5, r13 + PT_Y, ec_t5               ; S2 = Y2 Z1^3
    FSUB ec_t3, ec_t3, ec_t2                    ; H = U2 - U1
    FSUB ec_t5, ec_t5, ec_t4                    ; r = S2 - S1
    lea rsi, [ec_t3]
    mov ecx, [ec_limbs]
    call bn_is_zero
    jnz .general
    lea rsi, [ec_t5]
    call bn_is_zero
    jnz .infinity                   ; P = -Q
    mov rsi, r12                    ; P = Q
    mov rdi, r14
    call ec_double
    jmp .done
.general:
    FMUL ec_t6, ec_t3, ec_t3                    ; HH
    FMUL ec_t7, ec_t3, ec_t6                    ; HHH
    FMUL ec_t6, ec_t2, ec_t6                    ; V = U1 HH
    ; Z3 = Z1 Z2 H (before P or Q might be overwritten)
    FMUL ec_t0, r12 + PT_Z, r13 + PT_Z
    FMUL ec_t0, ec_t0, ec_t3
    ; X3 = r^2 - HHH - 2V
    FMUL ec_t1, ec_t5, ec_t5
    FSUB ec_t1, ec_t1, ec_t7
    FSUB ec_t1, ec_t1, ec_t6
    FSUB ec_t1, ec_t1, ec_t6
    ; Y3 = r (V - X3) - S1 HHH
    FSUB ec_t6, ec_t6, ec_t1
    FMUL ec_t6, ec_t5, ec_t6
    FMUL ec_t7, ec_t4, ec_t7
    FSUB ec_t6, ec_t6, ec_t7
    FCOPY r14 + PT_X, ec_t1
    FCOPY r14 + PT_Y, ec_t6
    FCOPY r14 + PT_Z, ec_t0
    jmp .done
.return_q:
    mov rsi, r13
    jmp .copy_point
.return_p:
    mov rsi, r12
.copy_point:
    mov rdi, r14
    mov ecx, PT_SIZE / 8
    rep movsq
    jmp .done
.infinity:
    lea rdi, [r14 + PT_Z]
    mov ecx, [ec_limbs]
    xor eax, eax
    rep stosq
.done:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; ec_affine_x: RSI = point, RBX = field -> ec_t7 = affine x as a plain number;
; CF=1 for the point at infinity
; ------------------------------------------------------------------------------
ec_affine_x:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    mov r12, rsi
    lea rsi, [r12 + PT_Z]
    mov ecx, [ec_limbs]
    call bn_is_zero
    jz .infinity
    ; zinv = Z^(p-2), all plain
    lea rdi, [ec_t0]
    call mont_from                  ; Z plain
    mov rax, [ec_curve]
    mov rsi, [rax + EC_CONST]       ; p, big-endian
    call ec_minus_two
    lea rsi, [ec_t0]
    lea rdi, [ec_t1]
    lea rdx, [ec_exp]
    mov rax, [ec_curve]
    mov ecx, [rax + EC_BYTES]
    call bn_modexp                  ; t1 = 1/Z
    lea rdi, [ec_t2]
    lea rsi, [ec_t1]
    lea rdx, [ec_t1]
    call mont_modmul                ; t2 = 1/Z^2
    lea rdi, [ec_t3]
    lea rsi, [r12 + PT_X]
    call mont_from                  ; X plain
    lea rdi, [ec_t7]
    lea rsi, [ec_t3]
    lea rdx, [ec_t2]
    call mont_modmul                ; x = X / Z^2
    clc
    jmp .out
.infinity:
    stc
.out:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ec_minus_two: RSI = modulus (big-endian, the curve's size) -> ec_exp = it - 2
; (the last byte of p and n is at least 2 on both curves, so no borrow)
ec_minus_two:
    push rax
    push rcx
    push rsi
    push rdi
    mov rax, [ec_curve]
    mov ecx, [rax + EC_BYTES]
    lea rdi, [ec_exp]
    push rcx
    rep movsb
    pop rcx
    sub byte [ec_exp + rcx - 1], 2
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; ec_scalar_bit: RSI = scalar (plain limbs), ECX = bit index -> CF = that bit
; ------------------------------------------------------------------------------
ec_scalar_bit:
    push rax
    push rcx
    mov eax, ecx
    shr eax, 6
    and ecx, 63
    mov rax, [rsi + rax * 8]
    bt rax, rcx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; ec_mul_add: ec_ptR = u1*G + u2*Q (ec_u1, ec_u2 plain; ec_ptQ set), RBX = field
; ------------------------------------------------------------------------------
ec_mul_add:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    ; G as a Jacobian point with Z = 1
    mov r8, [ec_curve]
    FCOPY ec_ptG + PT_X, r8 + EC_GX
    FCOPY ec_ptG + PT_Y, r8 + EC_GY
    FCOPY ec_ptG + PT_Z, r8 + EC_ONE
    lea rdi, [ec_ptGQ]
    lea rsi, [ec_ptG]
    lea rdx, [ec_ptQ]
    call ec_add
    ; R = infinity
    lea rdi, [ec_ptR + PT_Z]
    mov ecx, [ec_limbs]
    xor eax, eax
    rep stosq
    mov ecx, [r8 + EC_BYTES]
    shl ecx, 3                      ; bit count
.bit:
    dec ecx
    js .done
    lea rdi, [ec_ptR]
    lea rsi, [ec_ptR]
    call ec_double
    xor eax, eax
    lea rsi, [ec_u1]
    call ec_scalar_bit
    adc eax, 0
    lea rsi, [ec_u2]
    call ec_scalar_bit
    jnc .no_q
    or eax, 2
.no_q:
    test eax, eax
    jz .bit
    lea rdx, [ec_ptG]
    cmp eax, 1
    je .add
    lea rdx, [ec_ptQ]
    cmp eax, 2
    je .add
    lea rdx, [ec_ptGQ]
.add:
    lea rdi, [ec_ptR]
    lea rsi, [ec_ptR]
    call ec_add
    jmp .bit
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; ec_der_int: RSI = DER at an INTEGER, R9 = end -> RDI (number, ec_limbs limbs,
; EC_N width) filled; RSI advanced past it. CF=1 if malformed or too wide.
; ------------------------------------------------------------------------------
ec_der_int:
    push rax
    push rcx
    push rdx
    lea rax, [rsi + 2]
    cmp rax, r9
    ja .bad
    cmp byte [rsi], 0x02
    jne .bad
    movzx edx, byte [rsi + 1]
    cmp edx, 0x80
    jae .bad                        ; always short form at these sizes
    add rsi, 2
    lea rax, [rsi + rdx]
    cmp rax, r9
    ja .bad
    mov ecx, [ec_limbs]
    call bn_from_bytes
    jc .bad
    add rsi, rdx
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.bad:
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; ec_check_range: RSI = number -> CF=1 unless 0 < number < n
ec_check_range:
    push rcx
    push rdi
    push rax
    mov ecx, [ec_limbs]
    call bn_is_zero
    jz .bad
    mov rax, [ec_curve]
    lea rdi, [rax + EC_N + MONT_N]
    call bn_cmp
    jae .bad
    pop rax
    pop rdi
    pop rcx
    clc
    ret
.bad:
    pop rax
    pop rdi
    pop rcx
    stc
    ret

; ------------------------------------------------------------------------------
; ecdsa_verify: RBX = public key (PK_TYPE_P256 / P384), AL = HASH_*,
;               RSI = signed message, RCX = its length,
;               RDX = DER signature SEQUENCE { r, s }, R8 = its length
; Output: CF=1 if the signature is not valid
; ------------------------------------------------------------------------------
ecdsa_verify:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r12
    mov r12, rbx                    ; R12 = public key
    ; e = leftmost curve-size bytes of the hash
    lea rdi, [ec_hash]
    call hash_compute
    call hash_len
    mov r10d, ecx                   ; R10 = hash length
    push rax
    mov al, [r12 + PK_TYPE]
    call ec_select                  ; RBX = field
    pop rax
    jc .bad
    mov r9, [ec_curve]
    mov eax, [r9 + EC_BYTES]
    cmp r10d, eax
    jbe .e_len
    mov r10d, eax
.e_len:
    push rdx
    lea rdi, [ec_e]
    lea rsi, [ec_hash]
    mov rdx, r10
    mov ecx, [ec_limbs]
    call bn_from_bytes
    pop rdx
    ; e mod n (e < 2^bits < 2n)
    lea rsi, [ec_e]
    lea rdi, [r9 + EC_N + MONT_N]
    mov ecx, [ec_limbs]
    call bn_cmp
    jb .e_ok
    lea rdi, [ec_e]
    lea rsi, [r9 + EC_N + MONT_N]
    call bn_sub_in
.e_ok:

    ; signature: 30 len 02 r 02 s
    lea r9, [rdx + r8]              ; R9 = end
    cmp r8, 8
    jb .bad
    cmp byte [rdx], 0x30
    jne .bad
    lea rsi, [rdx + 2]
    cmp byte [rdx + 1], 0x81        ; P-384 signatures can be 128+ bytes
    jne .sig_seq
    inc rsi
.sig_seq:
    lea rdi, [ec_r]
    call ec_der_int
    jc .bad
    lea rdi, [ec_s]
    call ec_der_int
    jc .bad
    lea rsi, [ec_r]
    call ec_check_range
    jc .bad
    lea rsi, [ec_s]
    call ec_check_range
    jc .bad

    ; Q = 04 | X | Y, on the curve
    call ec_load_public
    jc .bad

    ; w = 1/s mod n, u1 = e w, u2 = r w
    mov r9, [ec_curve]
    lea rbx, [r9 + EC_N]
    mov rsi, [r9 + EC_CONST]
    mov ecx, [r9 + EC_BYTES]
    add rsi, rcx                    ; n, big-endian
    call ec_minus_two
    lea rsi, [ec_s]
    lea rdx, [ec_exp]
    lea rdi, [ec_w]
    call bn_modexp
    lea rdi, [ec_u1]
    lea rsi, [ec_e]
    lea rdx, [ec_w]
    call mont_modmul
    lea rdi, [ec_u2]
    lea rsi, [ec_r]
    call mont_modmul

    ; R = u1 G + u2 Q; valid if R.x mod n == r
    lea rbx, [r9 + EC_P]
    call ec_mul_add
    lea rsi, [ec_ptR]
    call ec_affine_x                ; ec_t7
    jc .bad
    lea rsi, [ec_t7]
    lea rdi, [r9 + EC_N + MONT_N]
    mov ecx, [ec_limbs]
    call bn_cmp
    jb .x_ok
    lea rdi, [ec_t7]
    lea rsi, [r9 + EC_N + MONT_N]
    call bn_sub_in
.x_ok:
    lea rsi, [ec_t7]
    lea rdi, [ec_r]
    call bn_cmp
    jne .bad
    clc
    jmp .out
.bad:
    stc
.out:
    pop r12
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
; ec_load_public: R12 = public key -> ec_ptQ (Montgomery, Z = 1), RBX = field.
; CF=1 unless it is an uncompressed point on the curve.
; ------------------------------------------------------------------------------
ec_load_public:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    mov r9, [ec_curve]
    lea rbx, [r9 + EC_P]
    mov ecx, [r9 + EC_BYTES]
    lea eax, [ecx * 2 + 1]
    cmp [r12 + PK_A_LEN], eax
    jne .bad
    mov rsi, [r12 + PK_A]
    cmp byte [rsi], 4
    jne .bad
    inc rsi
    ; x, y below p
    lea rdi, [ec_t0]
    call .load_coord
    jc .bad
    add rsi, rcx
    lea rdi, [ec_t1]
    call .load_coord
    jc .bad
    ; to Montgomery form
    lea rsi, [ec_t0]
    lea rdi, [ec_ptQ + PT_X]
    call mont_to
    lea rsi, [ec_t1]
    lea rdi, [ec_ptQ + PT_Y]
    call mont_to
    FCOPY ec_ptQ + PT_Z, r9 + EC_ONE
    ; y^2 = x^3 - 3x + b
    FMUL ec_t2, ec_ptQ + PT_Y, ec_ptQ + PT_Y
    FMUL ec_t3, ec_ptQ + PT_X, ec_ptQ + PT_X
    FMUL ec_t3, ec_t3, ec_ptQ + PT_X
    FSUB ec_t3, ec_t3, ec_ptQ + PT_X
    FSUB ec_t3, ec_t3, ec_ptQ + PT_X
    FSUB ec_t3, ec_t3, ec_ptQ + PT_X
    FADD ec_t3, ec_t3, r9 + EC_B
    lea rsi, [ec_t2]
    lea rdi, [ec_t3]
    mov ecx, [ec_limbs]
    call bn_cmp
    jne .bad
    clc
    jmp .out
.bad:
    stc
.out:
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
; .load_coord: RSI = big-endian coordinate (ECX bytes) -> RDI; CF=1 if >= p
.load_coord:
    push rcx
    push rdx
    push rsi
    mov rdx, rcx
    mov ecx, [ec_limbs]
    call bn_from_bytes
    mov rsi, rdi
    lea rdi, [rbx + MONT_N]
    call bn_cmp
    cmc                             ; CF=1 if coordinate >= p
    mov rdi, rsi
    pop rsi
    pop rdx
    pop rcx
    ret
