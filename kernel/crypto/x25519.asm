; ==============================================================================
; Antigravity OS - X25519 key agreement (RFC 7748)
; ------------------------------------------------------------------------------
; Field elements mod p = 2^255 - 19 are four little-endian 64-bit limbs,
; kept below 2^256 (not fully reduced) until the final result. 2^256 = 38 mod p
; is what every reduction uses. The ladder swaps with masks, not branches.
; ==============================================================================

[bits 64]

FE_SIZE                 equ 32

section .bss
alignb 16
fe_t:                   resq 8      ; 512-bit product
x25519_k:               resb 32     ; clamped scalar
x25519_x1:              resb FE_SIZE
x25519_x2:              resb FE_SIZE
x25519_z2:              resb FE_SIZE
x25519_x3:              resb FE_SIZE
x25519_z3:              resb FE_SIZE
x25519_a:               resb FE_SIZE
x25519_aa:              resb FE_SIZE
x25519_b:               resb FE_SIZE
x25519_bb:              resb FE_SIZE
x25519_e:               resb FE_SIZE
x25519_c:               resb FE_SIZE
x25519_d:               resb FE_SIZE
x25519_da:              resb FE_SIZE
x25519_cb:              resb FE_SIZE
x25519_inv:             resb FE_SIZE

section .rodata
align 8
fe_a24:                 dq 121665, 0, 0, 0
x25519_base_point:      db 9
                        times 31 db 0

section .text
; ------------------------------------------------------------------------------
; fe_add / fe_sub / fe_mul: RDI = out, RSI = a, RDX = b (out may be a or b)
; ------------------------------------------------------------------------------
fe_add:
    push rax
    push rcx
    push r8
    push r9
    push r10
    mov rax, [rsi]
    mov rcx, [rsi + 8]
    mov r8, [rsi + 16]
    mov r9, [rsi + 24]
    add rax, [rdx]
    adc rcx, [rdx + 8]
    adc r8, [rdx + 16]
    adc r9, [rdx + 24]
    sbb r10, r10                    ; carry out of 2^256 -> add 38
    and r10, 38
    add rax, r10
    adc rcx, 0
    adc r8, 0
    adc r9, 0
    sbb r10, r10
    and r10, 38
    add rax, r10
    mov [rdi], rax
    mov [rdi + 8], rcx
    mov [rdi + 16], r8
    mov [rdi + 24], r9
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rax
    ret

fe_sub:
    push rax
    push rcx
    push r8
    push r9
    push r10
    mov rax, [rsi]
    mov rcx, [rsi + 8]
    mov r8, [rsi + 16]
    mov r9, [rsi + 24]
    sub rax, [rdx]
    sbb rcx, [rdx + 8]
    sbb r8, [rdx + 16]
    sbb r9, [rdx + 24]
    sbb r10, r10                    ; borrow of 2^256 -> subtract 38
    and r10, 38
    sub rax, r10
    sbb rcx, 0
    sbb r8, 0
    sbb r9, 0
    sbb r10, r10
    and r10, 38
    sub rax, r10
    mov [rdi], rax
    mov [rdi + 8], rcx
    mov [rdi + 16], r8
    mov [rdi + 24], r9
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rax
    ret

fe_mul:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push r12

    mov rbx, rdx                    ; RBX = b
    lea r11, [fe_t]
    xor eax, eax
    mov [r11], rax
    mov [r11 + 8], rax
    mov [r11 + 16], rax
    mov [r11 + 24], rax

    ; schoolbook 4 x 4 limbs -> fe_t[0..7]
    xor ecx, ecx
.row:
    mov r8, [rsi + rcx * 8]         ; a[i]
    xor r9d, r9d                    ; carry
    xor r10d, r10d                  ; j
.col:
    mov rax, [rbx + r10 * 8]
    mul r8
    add rax, r9
    adc rdx, 0
    lea r12, [rcx + r10]
    add [r11 + r12 * 8], rax
    adc rdx, 0
    mov r9, rdx
    inc r10
    cmp r10, 4
    jb .col
    mov [r11 + rcx * 8 + 32], r9
    inc rcx
    cmp rcx, 4
    jb .row

    ; t[0..3] += 38 * t[4..7]
    mov r8d, 38
    xor r9d, r9d
    xor ecx, ecx
.reduce:
    mov rax, [r11 + rcx * 8 + 32]
    mul r8
    add rax, r9
    adc rdx, 0
    add [r11 + rcx * 8], rax
    adc rdx, 0
    mov r9, rdx
    inc ecx
    cmp ecx, 4
    jb .reduce
    ; fold the last carry word (< 40) the same way
    imul r9, r9, 38
    mov rax, [r11]
    mov rcx, [r11 + 8]
    mov rdx, [r11 + 16]
    mov r10, [r11 + 24]
    add rax, r9
    adc rcx, 0
    adc rdx, 0
    adc r10, 0
    sbb r9, r9
    and r9, 38
    add rax, r9                     ; cannot carry: after a wrap RAX is small
    mov [rdi], rax
    mov [rdi + 8], rcx
    mov [rdi + 16], rdx
    mov [rdi + 24], r10

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

; fe_sq: RDI = out, RSI = a
fe_sq:
    push rdx
    mov rdx, rsi
    call fe_mul
    pop rdx
    ret

; ------------------------------------------------------------------------------
; fe_cswap: RDI = a, RSI = b, RAX = 1 to swap them, 0 to leave them
; ------------------------------------------------------------------------------
fe_cswap:
    push rax
    push rcx
    push rdx
    push r8
    push r9
    neg rax                         ; 0 or all ones
    xor r9d, r9d
.limb:
    mov rcx, [rdi + r9 * 8]
    mov rdx, [rsi + r9 * 8]
    mov r8, rcx
    xor r8, rdx
    and r8, rax
    xor rcx, r8
    xor rdx, r8
    mov [rdi + r9 * 8], rcx
    mov [rsi + r9 * 8], rdx
    inc r9d
    cmp r9d, 4
    jb .limb
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; fe_invert: RDI = out, RSI = z  ->  z^(p-2). Every bit of p-2 = 2^255 - 21
; is set except bits 2 and 4. RDI must not be RSI.
; ------------------------------------------------------------------------------
fe_invert:
    push rcx
    push rdx
    push rsi
    ; out = z (bit 254)
    mov rcx, [rsi]
    mov [rdi], rcx
    mov rcx, [rsi + 8]
    mov [rdi + 8], rcx
    mov rcx, [rsi + 16]
    mov [rdi + 16], rcx
    mov rcx, [rsi + 24]
    mov [rdi + 24], rcx
    mov rdx, rsi                    ; RDX = z
    mov ecx, 253
.bit:
    mov rsi, rdi
    call fe_sq
    cmp ecx, 4
    je .next
    cmp ecx, 2
    je .next
    call fe_mul                     ; out = out * z
.next:
    dec ecx
    jns .bit
    pop rsi
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------------------------
; fe_freeze: RDI = element, reduced in place to the unique value below p
; ------------------------------------------------------------------------------
fe_freeze:
    push rax
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    mov rax, [rdi]
    mov rcx, [rdi + 8]
    mov rdx, [rdi + 16]
    mov r8, [rdi + 24]
    ; fold bit 255 (2^255 = 19 mod p)
    mov r9, r8
    shr r9, 63
    imul r9, r9, 19
    btr r8, 63
    add rax, r9
    adc rcx, 0
    adc rdx, 0
    adc r8, 0
    ; now value < 2^255 + 19; if value + 19 reaches 2^255 it was >= p
    mov r9, rax
    mov r10, rcx
    mov r11, rdx
    add r9, 19
    adc r10, 0
    adc r11, 0
    push r8
    adc r8, 0
    bt r8, 63
    jnc .keep
    btr r8, 63
    mov rax, r9
    mov rcx, r10
    mov rdx, r11
    add rsp, 8
    jmp .store
.keep:
    pop r8
.store:
    mov [rdi], rax
    mov [rdi + 8], rcx
    mov [rdi + 16], rdx
    mov [rdi + 24], r8
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; x25519: RDI = 32-byte output, RSI = 32-byte scalar, RDX = 32-byte u-coordinate
; x25519_base: the same with RDX = the base point (public key from a secret)
; ------------------------------------------------------------------------------
x25519_base:
    push rdx
    lea rdx, [x25519_base_point]
    call x25519
    pop rdx
    ret

x25519:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14

    ; k = clamp(scalar), x1 = u with bit 255 cleared
    mov rax, [rsi]
    mov [x25519_k], rax
    mov rax, [rsi + 8]
    mov [x25519_k + 8], rax
    mov rax, [rsi + 16]
    mov [x25519_k + 16], rax
    mov rax, [rsi + 24]
    mov [x25519_k + 24], rax
    and byte [x25519_k], 248
    and byte [x25519_k + 31], 127
    or byte [x25519_k + 31], 64
    mov rax, [rdx]
    mov [x25519_x1], rax
    mov [x25519_x3], rax
    mov rax, [rdx + 8]
    mov [x25519_x1 + 8], rax
    mov [x25519_x3 + 8], rax
    mov rax, [rdx + 16]
    mov [x25519_x1 + 16], rax
    mov [x25519_x3 + 16], rax
    mov rax, [rdx + 24]
    btr rax, 63
    mov [x25519_x1 + 24], rax
    mov [x25519_x3 + 24], rax
    ; x2 = 1, z2 = 0, z3 = 1
    xor eax, eax
    mov [x25519_x2 + 8], rax
    mov [x25519_x2 + 16], rax
    mov [x25519_x2 + 24], rax
    mov [x25519_z2], rax
    mov [x25519_z2 + 8], rax
    mov [x25519_z2 + 16], rax
    mov [x25519_z2 + 24], rax
    mov [x25519_z3 + 8], rax
    mov [x25519_z3 + 16], rax
    mov [x25519_z3 + 24], rax
    inc eax
    mov [x25519_x2], rax
    mov [x25519_z3], rax

    xor r12d, r12d                  ; R12 = swap
    mov r13d, 254                   ; R13 = bit index t
.ladder:
    ; bit = (k >> t) & 1
    mov ecx, r13d
    shr ecx, 3
    lea rbx, [x25519_k]
    movzx r14d, byte [rbx + rcx]
    mov ecx, r13d
    and ecx, 7
    shr r14d, cl
    and r14d, 1
    xor r12d, r14d
    mov eax, r12d
    lea rdi, [x25519_x2]
    lea rsi, [x25519_x3]
    call fe_cswap
    lea rdi, [x25519_z2]
    lea rsi, [x25519_z3]
    call fe_cswap
    mov r12d, r14d

    ; A = x2 + z2, AA = A^2, B = x2 - z2, BB = B^2, E = AA - BB
    lea rdi, [x25519_a]
    lea rsi, [x25519_x2]
    lea rdx, [x25519_z2]
    call fe_add
    lea rdi, [x25519_b]
    call fe_sub
    lea rdi, [x25519_aa]
    lea rsi, [x25519_a]
    call fe_sq
    lea rdi, [x25519_bb]
    lea rsi, [x25519_b]
    call fe_sq
    lea rdi, [x25519_e]
    lea rsi, [x25519_aa]
    lea rdx, [x25519_bb]
    call fe_sub
    ; C = x3 + z3, D = x3 - z3, DA = D * A, CB = C * B
    lea rdi, [x25519_c]
    lea rsi, [x25519_x3]
    lea rdx, [x25519_z3]
    call fe_add
    lea rdi, [x25519_d]
    call fe_sub
    lea rdi, [x25519_da]
    lea rsi, [x25519_d]
    lea rdx, [x25519_a]
    call fe_mul
    lea rdi, [x25519_cb]
    lea rsi, [x25519_c]
    lea rdx, [x25519_b]
    call fe_mul
    ; x3 = (DA + CB)^2
    lea rdi, [x25519_x3]
    lea rsi, [x25519_da]
    lea rdx, [x25519_cb]
    call fe_add
    mov rsi, rdi
    call fe_sq
    ; z3 = x1 * (DA - CB)^2
    lea rdi, [x25519_z3]
    lea rsi, [x25519_da]
    lea rdx, [x25519_cb]
    call fe_sub
    mov rsi, rdi
    call fe_sq
    lea rdx, [x25519_x1]
    call fe_mul
    ; x2 = AA * BB
    lea rdi, [x25519_x2]
    lea rsi, [x25519_aa]
    lea rdx, [x25519_bb]
    call fe_mul
    ; z2 = E * (AA + a24 * E)
    lea rdi, [x25519_z2]
    lea rsi, [x25519_e]
    lea rdx, [fe_a24]
    call fe_mul
    mov rsi, rdi
    lea rdx, [x25519_aa]
    call fe_add
    lea rdx, [x25519_e]
    call fe_mul

    dec r13d
    jns .ladder

    mov eax, r12d
    lea rdi, [x25519_x2]
    lea rsi, [x25519_x3]
    call fe_cswap
    lea rdi, [x25519_z2]
    lea rsi, [x25519_z3]
    call fe_cswap

    ; out = x2 / z2
    lea rdi, [x25519_inv]
    lea rsi, [x25519_z2]
    call fe_invert
    mov rsi, rdi
    lea rdx, [x25519_x2]
    call fe_mul
    call fe_freeze
    mov rsi, rdi
    mov rdi, [rsp + 24]             ; saved RDI = output
    mov rax, [rsi]
    mov [rdi], rax
    mov rax, [rsi + 8]
    mov [rdi + 8], rax
    mov rax, [rsi + 16]
    mov [rdi + 16], rax
    mov rax, [rsi + 24]
    mov [rdi + 24], rax

    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
