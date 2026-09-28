; ==============================================================================
; Antigravity OS - big numbers and Montgomery arithmetic
; ------------------------------------------------------------------------------
; A number is an array of 64-bit limbs, least significant first (so in memory
; it is simply a little-endian byte string). Sizes are given in limbs, up to
; BN_MAX_LIMBS (4096-bit RSA). A Montgomery context holds an odd modulus n
; with the constants for multiplying mod n without division; RSA and both
; elliptic curves (their field and their group order) each use one.
;
; These routines are for verifying signatures: they are not constant time.
; ==============================================================================

[bits 64]

BN_MAX_LIMBS            equ 64

MONT_K                  equ 0       ; dd number of limbs
MONT_N0                 equ 8       ; dq -n^-1 mod 2^64
MONT_N                  equ 16      ; n
MONT_RR                 equ MONT_N + BN_MAX_LIMBS * 8     ; R^2 mod n (R = 2^(64k))
MONT_SIZE               equ MONT_RR + BN_MAX_LIMBS * 8

section .bss
alignb 16
mont_t:                 resq BN_MAX_LIMBS + 2
bn_acc:                 resq BN_MAX_LIMBS
bn_base:                resq BN_MAX_LIMBS
bn_one:                 resq BN_MAX_LIMBS

section .text
; ------------------------------------------------------------------------------
; bn_from_bytes: RDI = number (ECX limbs), RSI = big-endian bytes, RDX = length
; Output: CF=1 if the value does not fit (leading zero bytes are skipped)
; ------------------------------------------------------------------------------
bn_from_bytes:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    ; zero the destination
    push rdi
    push rcx
    xor eax, eax
    shl ecx, 3
    rep stosb
    pop rcx
    pop rdi
.skip_zero:
    test rdx, rdx
    jz .ok
    cmp byte [rsi], 0
    jne .fits
    inc rsi
    dec rdx
    jmp .skip_zero
.fits:
    mov r8d, ecx
    shl r8d, 3
    cmp rdx, r8
    ja .too_big
    ; dst byte i = src byte len-1-i
    xor ecx, ecx
.copy:
    mov al, [rsi + rdx - 1]
    mov [rdi + rcx], al
    inc ecx
    dec rdx
    jnz .copy
.ok:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.too_big:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; bn_to_bytes: RSI = number, RDI = output, ECX = output length (big-endian,
; the number's low ECX bytes)
; ------------------------------------------------------------------------------
bn_to_bytes:
    push rax
    push rcx
    push rdx
    mov edx, ecx
    xor eax, eax
.byte:
    test edx, edx
    jz .done
    dec edx
    push rcx
    mov cl, [rsi + rax]
    mov [rdi + rdx], cl
    pop rcx
    inc eax
    jmp .byte
.done:
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; bn_cmp: RSI = a, RDI = b, ECX = limbs -> flags as for an unsigned "cmp a, b"
; (CF=1 if a < b, ZF=1 if equal)
; ------------------------------------------------------------------------------
bn_cmp:
    push rax
    push rcx
.limb:
    dec ecx
    js .equal
    mov rax, [rsi + rcx * 8]
    cmp rax, [rdi + rcx * 8]
    je .limb
    pop rcx
    pop rax
    ret
.equal:
    xor eax, eax                    ; ZF=1, CF=0
    pop rcx
    pop rax
    ret

; bn_is_zero: RSI = number, ECX = limbs -> ZF=1 if it is zero
bn_is_zero:
    push rax
    push rcx
    xor eax, eax
.limb:
    dec ecx
    js .done
    or rax, [rsi + rcx * 8]
    jmp .limb
.done:
    test rax, rax
    pop rcx
    pop rax
    ret

; bn_copy: RDI = destination, RSI = source, ECX = limbs
bn_copy:
    push rcx
    push rsi
    push rdi
    rep movsq
    pop rdi
    pop rsi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; bn_sub_in: RDI = a, RSI = b, ECX = limbs -> a -= b, CF = borrow out
; bn_add_in: the same for a += b, CF = carry out
; ------------------------------------------------------------------------------
bn_sub_in:
    push rax
    push rcx
    push rdx
    xor edx, edx                    ; also clears CF
.limb:
    mov rax, [rsi + rdx * 8]
    sbb [rdi + rdx * 8], rax
    inc rdx                         ; INC/DEC keep CF
    dec ecx
    jnz .limb
    pop rdx
    pop rcx
    pop rax
    ret

bn_add_in:
    push rax
    push rcx
    push rdx
    xor edx, edx
.limb:
    mov rax, [rsi + rdx * 8]
    adc [rdi + rdx * 8], rax
    inc rdx
    dec ecx
    jnz .limb
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; mont_setup: RBX = context, RSI = modulus as big-endian bytes, RCX = length
; Output: CF=1 if the modulus is even, zero or wider than BN_MAX_LIMBS
; ------------------------------------------------------------------------------
mont_setup:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    ; limbs = ceil(significant bytes / 8)
    mov rdx, rcx
.skip_zero:
    test rdx, rdx
    jz .bad
    cmp byte [rsi], 0
    jne .sized
    inc rsi
    dec rdx
    jmp .skip_zero
.sized:
    lea rcx, [rdx + 7]
    shr rcx, 3
    cmp rcx, BN_MAX_LIMBS
    ja .bad
    mov [rbx + MONT_K], ecx
    lea rdi, [rbx + MONT_N]
    call bn_from_bytes
    test byte [rbx + MONT_N], 1
    jz .bad
    call mont_finish
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.bad:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; mont_finish: RBX = context with MONT_K and MONT_N filled in -> MONT_N0, MONT_RR
; ------------------------------------------------------------------------------
mont_finish:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    ; n0 = -(n[0]^-1) mod 2^64 by Newton: x = x * (2 - n*x), doubling the bits
    mov r8, [rbx + MONT_N]
    mov rax, r8                     ; correct to 3 bits for odd n
    mov ecx, 5
.newton:
    mov rdx, r8
    imul rdx, rax
    neg rdx
    add rdx, 2
    imul rax, rdx
    dec ecx
    jnz .newton
    neg rax
    mov [rbx + MONT_N0], rax

    ; RR = 2^(2*64k) mod n: start at 1 and double 128k times
    mov ecx, [rbx + MONT_K]
    lea rdi, [rbx + MONT_RR]
    push rcx
    push rdi
    xor eax, eax
    rep stosq
    pop rdi
    pop rcx
    mov qword [rdi], 1
    mov r8d, ecx
    shl r8d, 7
    lea rsi, [rbx + MONT_N]
.double:
    ; x = 2x (carry out in CF)
    push rcx
    xor edx, edx
    clc
.shl:
    rcl qword [rdi + rdx * 8], 1
    inc rdx
    dec ecx
    jnz .shl
    pop rcx
    jc .reduce                      ; 2x >= 2^(64k) > n
    xchg rsi, rdi
    call bn_cmp                     ; x vs n
    xchg rsi, rdi                   ; (XCHG keeps the flags)
    jb .next                        ; x < n
.reduce:
    call bn_sub_in
.next:
    dec r8d
    jnz .double
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; mont_mul: RDI = out, RSI = a, RDX = b, RBX = context -> a * b / R mod n
; a and b must be below n; out may be a or b.
; ------------------------------------------------------------------------------
mont_mul:
    push rax
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
    mov r15, rdx                    ; R15 = b
    mov ecx, [rbx + MONT_K]         ; RCX = k
    lea r8, [mont_t]                ; R8 = t (k + 2 limbs)
    push rcx
    push rdi
    mov rdi, r8
    xor eax, eax
    add ecx, 2
    rep stosq
    pop rdi
    pop rcx

    xor r9d, r9d                    ; i
.outer:
    ; t += a * b[i]
    mov r10, [r15 + r9 * 8]
    xor r12d, r12d                  ; carry limb
    xor r11d, r11d                  ; j
.mul_a:
    mov rax, [rsi + r11 * 8]
    mul r10
    add rax, [r8 + r11 * 8]
    adc rdx, 0
    add rax, r12
    adc rdx, 0
    mov [r8 + r11 * 8], rax
    mov r12, rdx
    inc r11
    cmp r11, rcx
    jb .mul_a
    xor r14d, r14d
    add [r8 + rcx * 8], r12
    adc r14, 0
    mov [r8 + rcx * 8 + 8], r14

    ; t = (t + m * n) / 2^64 with m = t[0] * n0, which clears the low limb
    mov r13, [r8]
    imul r13, [rbx + MONT_N0]
    mov rax, [rbx + MONT_N]
    mul r13
    add rax, [r8]
    adc rdx, 0
    mov r12, rdx
    mov r11d, 1
.mul_n:
    cmp r11, rcx
    jae .mul_n_done
    mov rax, [rbx + MONT_N + r11 * 8]
    mul r13
    add rax, [r8 + r11 * 8]
    adc rdx, 0
    add rax, r12
    adc rdx, 0
    mov [r8 + r11 * 8 - 8], rax
    mov r12, rdx
    inc r11
    jmp .mul_n
.mul_n_done:
    mov rax, [r8 + rcx * 8]
    add rax, r12
    mov [r8 + rcx * 8 - 8], rax
    mov rax, [r8 + rcx * 8 + 8]
    adc rax, 0
    mov [r8 + rcx * 8], rax
    inc r9
    cmp r9, rcx
    jb .outer

    ; t < 2n: subtract n once if t >= n
    cmp qword [r8 + rcx * 8], 0
    jne .subtract
    mov r11, rcx
.compare:
    dec r11
    js .subtract                    ; equal
    mov rax, [r8 + r11 * 8]
    cmp rax, [rbx + MONT_N + r11 * 8]
    ja .subtract
    jb .copy
    jmp .compare
.subtract:
    push rdi
    push rsi
    mov rdi, r8
    lea rsi, [rbx + MONT_N]
    call bn_sub_in
    pop rsi
    pop rdi
.copy:
    mov rsi, r8
    rep movsq

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
    pop rax
    ret

; mont_to: RDI = out, RSI = a (< n), RBX = context -> a * R mod n
mont_to:
    push rdx
    lea rdx, [rbx + MONT_RR]
    call mont_mul
    pop rdx
    ret

; mont_from: RDI = out, RSI = a (Montgomery form), RBX = context -> a / R mod n
mont_from:
    push rdx
    call bn_set_one
    lea rdx, [bn_one]
    call mont_mul
    pop rdx
    ret

; bn_set_one: bn_one = 1 in the context's width (RBX)
bn_set_one:
    push rax
    push rcx
    push rdi
    lea rdi, [bn_one]
    mov ecx, [rbx + MONT_K]
    xor eax, eax
    rep stosq
    mov qword [bn_one], 1
    pop rdi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; mont_modmul: RDI = out, RSI = a, RDX = b (plain values below n), RBX = context
; -> a * b mod n (plain)
; ------------------------------------------------------------------------------
mont_modmul:
    push rsi
    push rdx
    call mont_mul                   ; a*b/R
    mov rsi, rdi
    lea rdx, [rbx + MONT_RR]
    call mont_mul                   ; * R^2 / R
    pop rdx
    pop rsi
    ret

; ------------------------------------------------------------------------------
; bn_modexp: RDI = out, RSI = base (plain, below n), RDX = exponent as
; big-endian bytes, RCX = exponent length, RBX = context -> base^exp mod n
; ------------------------------------------------------------------------------
bn_modexp:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, rdx                     ; R8 = exponent bytes
    mov r9, rcx                     ; R9 = exponent length
    push rdi
    ; base in Montgomery form, acc = 1 in Montgomery form (R mod n)
    lea rdi, [bn_base]
    call mont_to
    call bn_set_one
    lea rsi, [bn_one]
    lea rdi, [bn_acc]
    call mont_to
    ; left to right over the exponent bits
    xor ecx, ecx                    ; byte index
.byte:
    cmp rcx, r9
    jae .done
    mov al, [r8 + rcx]
    mov ah, 8
.bit:
    lea rdi, [bn_acc]
    lea rsi, [bn_acc]
    mov rdx, rsi
    call mont_mul                   ; acc = acc^2
    shl al, 1
    jnc .no_mul
    lea rdx, [bn_base]
    call mont_mul                   ; acc = acc * base
.no_mul:
    dec ah
    jnz .bit
    inc rcx
    jmp .byte
.done:
    pop rdi
    lea rsi, [bn_acc]
    call mont_from
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; mont_modadd / mont_modsub: RDI = out, RSI = a, RDX = b (below n), RBX =
; context -> (a + b) mod n, (a - b) mod n. out may be a or b. The same in
; Montgomery form, since it is linear.
; ------------------------------------------------------------------------------
mont_modadd:
    push rax
    push rcx
    push rsi
    push rdi
    push r8
    mov ecx, [rbx + MONT_K]
    xor r8d, r8d                    ; limb index; also clears CF
.add:
    mov rax, [rsi + r8 * 8]
    adc rax, [rdx + r8 * 8]
    mov [rdi + r8 * 8], rax
    inc r8
    dec ecx
    jnz .add
    mov ecx, [rbx + MONT_K]
    lea rsi, [rbx + MONT_N]
    jc .sub_n                       ; a + b >= 2^(64k) > n
    xchg rsi, rdi
    call bn_cmp                     ; sum vs n
    xchg rsi, rdi
    jb .done
.sub_n:
    call bn_sub_in
.done:
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

mont_modsub:
    push rax
    push rcx
    push rsi
    push rdi
    push r8
    mov ecx, [rbx + MONT_K]
    xor r8d, r8d
.sub:
    mov rax, [rsi + r8 * 8]
    sbb rax, [rdx + r8 * 8]
    mov [rdi + r8 * 8], rax
    inc r8
    dec ecx
    jnz .sub
    jnc .done
    mov ecx, [rbx + MONT_K]
    lea rsi, [rbx + MONT_N]
    call bn_add_in                  ; borrowed: add n back
.done:
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret
