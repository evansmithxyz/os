; ==============================================================================
; Antigravity OS - JavaScript numbers: text <-> double
; ------------------------------------------------------------------------------
; Both directions are correctly rounded, like every browser:
;   jsnum_scan            longest decimal literal prefix -> nearest double
;   jsnum_to_string       double -> Number::toString (shortest round-trip text)
;   jsnum_string_to_number  ToNumber(string): trims, hex/octal/binary, Infinity
; The quick path uses double arithmetic when it is exact; otherwise the value
; is settled with exact big-integer arithmetic (jsbig_*): parsing compares the
; decimal against the midpoints between neighbouring doubles, printing uses the
; Steele-White / Burger-Dybvig free-format digit generator.
; ==============================================================================

[bits 64]

JSBIG_LIMBS             equ 80          ; 5120 bits (780 digits x 10^1110 fits)
JSBIG_LEN               equ 0           ; dword, limbs in use (top limb non-zero)
JSBIG_D                 equ 8           ; qword limbs, least significant first
JSBIG_SIZE              equ JSBIG_D + JSBIG_LIMBS * 8
JSNUM_MAX_DIGITS        equ 780         ; later digits collapse into a sticky 1

section .rodata
align 8
jsnum_pow10_f64:
    dq 1.0e0,  1.0e1,  1.0e2,  1.0e3,  1.0e4,  1.0e5,  1.0e6,  1.0e7
    dq 1.0e8,  1.0e9,  1.0e10, 1.0e11, 1.0e12, 1.0e13, 1.0e14, 1.0e15
    dq 1.0e16, 1.0e17, 1.0e18, 1.0e19, 1.0e20, 1.0e21, 1.0e22
jsnum_pow10_u64:
    dq 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000
    dq 1000000000, 10000000000, 100000000000, 1000000000000
    dq 10000000000000, 100000000000000, 1000000000000000
    dq 10000000000000000, 100000000000000000, 1000000000000000000
    dq 10000000000000000000
jsnum_str_nan:          db "NaN", 0
jsnum_str_inf:          db "Infinity", 0

section .bss
alignb 8
jsbig_a:                resb JSBIG_SIZE
jsbig_b:                resb JSBIG_SIZE
jsbig_d:                resb JSBIG_SIZE
jsbig_r:                resb JSBIG_SIZE
jsbig_s:                resb JSBIG_SIZE
jsbig_mp:               resb JSBIG_SIZE
jsbig_mm:               resb JSBIG_SIZE
jsbig_t:                resb JSBIG_SIZE
jsnum_digits:           resb JSNUM_MAX_DIGITS + 8
jsnum_tmp:              resb 32

section .text

; ==============================================================================
; Big integers (fixed capacity, unsigned)
; ==============================================================================

; jsbig_set: RDI = bigint, RAX = value
jsbig_set:
    push rax
    mov [rdi + JSBIG_D], rax
    test rax, rax
    setnz al
    movzx eax, al
    mov [rdi + JSBIG_LEN], eax
    pop rax
    ret

; jsbig_copy: RDI = destination, RSI = source
jsbig_copy:
    push rcx
    push rsi
    push rdi
    mov ecx, [rsi + JSBIG_LEN]
    mov [rdi + JSBIG_LEN], ecx
    add rsi, JSBIG_D
    add rdi, JSBIG_D
    rep movsq
    pop rdi
    pop rsi
    pop rcx
    ret

; jsbig_mul_small: RDI = bigint *= RAX (RAX != 0)
jsbig_mul_small:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    mov r8, rax
    mov ecx, [rdi + JSBIG_LEN]
    xor r9d, r9d                    ; carry
    xor ebx, ebx
.loop:
    cmp ebx, ecx
    jae .carry
    mov rax, [rdi + JSBIG_D + rbx*8]
    mul r8
    add rax, r9
    adc rdx, 0
    mov [rdi + JSBIG_D + rbx*8], rax
    mov r9, rdx
    inc ebx
    jmp .loop
.carry:
    test r9, r9
    jz .done
    cmp ecx, JSBIG_LIMBS
    jae .done                       ; cannot happen within the documented bounds
    mov [rdi + JSBIG_D + rcx*8], r9
    inc ecx
    mov [rdi + JSBIG_LEN], ecx
.done:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsbig_add_small: RDI = bigint += RAX
jsbig_add_small:
    push rax
    push rbx
    push rcx
    mov ecx, [rdi + JSBIG_LEN]
    xor ebx, ebx
.loop:
    cmp ebx, ecx
    jae .extend
    add [rdi + JSBIG_D + rbx*8], rax
    jnc .done
    mov eax, 1
    inc ebx
    jmp .loop
.extend:
    test rax, rax
    jz .done
    cmp ecx, JSBIG_LIMBS
    jae .done
    mov [rdi + JSBIG_D + rcx*8], rax
    inc ecx
    mov [rdi + JSBIG_LEN], ecx
.done:
    pop rcx
    pop rbx
    pop rax
    ret

; jsbig_mul_pow10: RDI = bigint *= 10^ECX (ECX >= 0)
jsbig_mul_pow10:
    push rax
    push rcx
    push rdx
.big:
    cmp ecx, 19
    jb .rest
    mov rax, 10000000000000000000
    call jsbig_mul_small
    sub ecx, 19
    jmp .big
.rest:
    test ecx, ecx
    jz .done
    lea rdx, [jsnum_pow10_u64]
    mov rax, [rdx + rcx*8]
    call jsbig_mul_small
.done:
    pop rdx
    pop rcx
    pop rax
    ret

; jsbig_shl: RDI = bigint <<= ECX bits
jsbig_shl:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    mov r8d, [rdi + JSBIG_LEN]
    test r8d, r8d
    jz .done
    mov r9d, ecx
    shr r9d, 6                      ; whole limbs
    and ecx, 63                     ; bits
    mov eax, r8d
    add eax, r9d
    cmp eax, JSBIG_LIMBS
    jae .done                       ; out of range (cannot happen)
    ; move the limbs up by r9d
    test r9d, r9d
    jz .bits
    mov ebx, r8d
.move:
    dec ebx
    mov rax, [rdi + JSBIG_D + rbx*8]
    lea edx, [rbx + r9]
    mov [rdi + JSBIG_D + rdx*8], rax
    test ebx, ebx
    jnz .move
    xor ebx, ebx
.zero:
    mov qword [rdi + JSBIG_D + rbx*8], 0
    inc ebx
    cmp ebx, r9d
    jb .zero
    add r8d, r9d
    mov [rdi + JSBIG_LEN], r8d
.bits:
    test ecx, ecx
    jz .done
    ; new top limb
    mov rax, [rdi + JSBIG_D + r8*8 - 8]
    mov rdx, rax
    neg cl
    shr rdx, cl                     ; cl = 64 - bits (mod 64)
    neg cl
    test rdx, rdx
    jz .shift
    mov [rdi + JSBIG_D + r8*8], rdx
    inc dword [rdi + JSBIG_LEN]
.shift:
    mov ebx, r8d
.limb:
    dec ebx
    jz .low
    mov rax, [rdi + JSBIG_D + rbx*8]
    mov rdx, [rdi + JSBIG_D + rbx*8 - 8]
    shld rax, rdx, cl
    mov [rdi + JSBIG_D + rbx*8], rax
    jmp .limb
.low:
    shl qword [rdi + JSBIG_D], cl
.done:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsbig_cmp: RSI = a, RDI = b -> EAX = -1, 0 or 1 (sign of a - b)
jsbig_cmp:
    push rbx
    push rcx
    mov ecx, [rsi + JSBIG_LEN]
    cmp ecx, [rdi + JSBIG_LEN]
    ja .greater
    jb .less
.loop:
    test ecx, ecx
    jz .equal
    dec ecx
    mov rbx, [rsi + JSBIG_D + rcx*8]
    cmp rbx, [rdi + JSBIG_D + rcx*8]
    ja .greater
    jb .less
    jmp .loop
.equal:
    xor eax, eax
    jmp .out
.greater:
    mov eax, 1
    jmp .out
.less:
    mov eax, -1
.out:
    pop rcx
    pop rbx
    ret

; jsbig_add: RDI = a += RSI (b)
jsbig_add:
    push rax
    push rbx
    push rcx
    push rdx
    mov ecx, [rdi + JSBIG_LEN]
    mov edx, [rsi + JSBIG_LEN]
    ; zero-extend a to b's length
.extend:
    cmp ecx, edx
    jae .add
    mov qword [rdi + JSBIG_D + rcx*8], 0
    inc ecx
    jmp .extend
.add:
    mov [rdi + JSBIG_LEN], ecx
    xor ebx, ebx
    clc
    pushf
.loop:
    cmp ebx, edx
    jae .carry
    popf
    mov rax, [rsi + JSBIG_D + rbx*8]
    adc [rdi + JSBIG_D + rbx*8], rax
    pushf
    inc ebx
    jmp .loop
.carry:
    popf
    jnc .done
.propagate:
    cmp ebx, ecx
    jae .newlimb
    add qword [rdi + JSBIG_D + rbx*8], 1
    jnc .done
    inc ebx
    jmp .propagate
.newlimb:
    cmp ecx, JSBIG_LIMBS
    jae .done
    mov qword [rdi + JSBIG_D + rcx*8], 1
    inc ecx
    mov [rdi + JSBIG_LEN], ecx
.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsbig_sub: RDI = a -= RSI (b), requires a >= b
jsbig_sub:
    push rax
    push rbx
    push rcx
    push rdx
    mov ecx, [rdi + JSBIG_LEN]
    mov edx, [rsi + JSBIG_LEN]
    xor ebx, ebx
    clc
    pushf
.loop:
    cmp ebx, edx
    jae .borrow
    popf
    mov rax, [rsi + JSBIG_D + rbx*8]
    sbb [rdi + JSBIG_D + rbx*8], rax
    pushf
    inc ebx
    jmp .loop
.borrow:
    popf
    jnc .norm
.propagate:
    cmp ebx, ecx
    jae .norm
    sub qword [rdi + JSBIG_D + rbx*8], 1
    jnc .norm
    inc ebx
    jmp .propagate
.norm:
    test ecx, ecx
    jz .store
    cmp qword [rdi + JSBIG_D + rcx*8 - 8], 0
    jne .store
    dec ecx
    jmp .norm
.store:
    mov [rdi + JSBIG_LEN], ecx
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsbig_load_digits: RSI = ASCII digits, ECX = count -> jsbig_d = their value
jsbig_load_digits:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    lea rdi, [jsbig_d]
    xor eax, eax
    call jsbig_set
.chunk:
    test ecx, ecx
    jz .done
    mov r8d, ecx
    cmp r8d, 18
    jbe .take
    mov r8d, 18
.take:
    sub ecx, r8d
    xor eax, eax
    mov ebx, r8d
.digit:
    imul rax, rax, 10
    movzx edx, byte [rsi]
    sub edx, '0'
    add rax, rdx
    inc rsi
    dec ebx
    jnz .digit
    push rax
    lea rdx, [jsnum_pow10_u64]
    mov rax, [rdx + r8*8]
    call jsbig_mul_small
    pop rax
    call jsbig_add_small
    jmp .chunk
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; Text -> double
; ==============================================================================

; ------------------------------------------------------------------------------
; jsnum_scan: parse the longest decimal literal at RSI (at most RCX bytes):
;   digits [. digits] [e|E [+|-] digits], at least one mantissa digit
;   (".5" and "5." are fine). EDX bit 0 = allow `_` between digits (source code).
; -> RAX = double bits, RCX = bytes consumed (0 = no number there)
; ------------------------------------------------------------------------------
jsnum_scan:
    push rbx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    mov r8, rsi                     ; start
    lea r9, [rsi + rcx]             ; end
    mov r12d, edx                   ; flags
    xor r10d, r10d                  ; digits kept
    xor r11d, r11d                  ; decimal exponent
    xor r13d, r13d                  ; bit0 = saw a digit, bit1 = sticky
    lea rdi, [jsnum_digits]
    ; integer part
.int:
    call .digit
    jc .int_done
    or r13d, 1
    test r10d, r10d
    jnz .int_keep
    cmp al, '0'
    je .int                         ; leading zero
.int_keep:
    cmp r10d, JSNUM_MAX_DIGITS
    jae .int_drop
    mov [rdi + r10], al
    inc r10d
    jmp .int
.int_drop:
    inc r11d
    cmp al, '0'
    je .int
    or r13d, 2
    jmp .int
.int_done:
    cmp rsi, r9
    jae .mantissa_done
    cmp byte [rsi], '.'
    jne .mantissa_done
    ; "." needs a digit on at least one side
    test r13d, 1
    jnz .frac_start
    lea rax, [rsi + 1]
    cmp rax, r9
    jae .mantissa_done
    movzx eax, byte [rax]
    sub eax, '0'
    cmp eax, 9
    ja .mantissa_done
.frac_start:
    inc rsi
.frac:
    call .digit
    jc .mantissa_done
    or r13d, 1
    test r10d, r10d
    jnz .frac_keep
    cmp al, '0'
    jne .frac_keep
    dec r11d                        ; 0.000ddd
    jmp .frac
.frac_keep:
    cmp r10d, JSNUM_MAX_DIGITS
    jae .frac_drop
    mov [rdi + r10], al
    inc r10d
    dec r11d
    jmp .frac
.frac_drop:
    cmp al, '0'
    je .frac
    or r13d, 2
    jmp .frac
.mantissa_done:
    test r13d, 1
    jz .none
    mov rbx, rsi                    ; end of the number without an exponent
    cmp rsi, r9
    jae .have
    mov al, [rsi]
    or al, 0x20
    cmp al, 'e'
    jne .have
    inc rsi
    xor edx, edx                    ; sign
    cmp rsi, r9
    jae .no_exp
    cmp byte [rsi], '+'
    je .exp_sign
    cmp byte [rsi], '-'
    jne .exp_digits
    mov edx, 1
.exp_sign:
    inc rsi
.exp_digits:
    xor ecx, ecx                    ; exponent value
    push r13
    and r13d, ~1                    ; reuse bit 0: saw an exponent digit
.exp_loop:
    call .digit
    jc .exp_end
    or r13d, 1
    movzx eax, al
    sub eax, '0'
    cmp ecx, 100000
    jae .exp_loop                   ; clamp: already far beyond any double
    imul ecx, ecx, 10
    add ecx, eax
    jmp .exp_loop
.exp_end:
    test r13d, 1
    pop r13
    jz .no_exp
    test edx, edx
    jz .exp_add
    neg ecx
.exp_add:
    add r11d, ecx
    mov rbx, rsi
    jmp .have
.no_exp:
    mov rsi, rbx                    ; "1e" / "1e+" : the e is not part of it
.have:
    test r13d, 2
    jz .strip
    mov byte [rdi + r10], '1'       ; sticky digit below everything kept
    inc r10d
    dec r11d
.strip:
    test r10d, r10d
    jz .zero
    cmp byte [rdi + r10 - 1], '0'
    jne .convert
    dec r10d
    inc r11d
    jmp .strip
.convert:
    push rsi
    mov rsi, rdi
    mov ecx, r10d
    mov edx, r11d
    call jsnum_digits_to_double
    pop rsi
    jmp .out
.zero:
    xor eax, eax
.out:
    mov rcx, rsi
    sub rcx, r8
    jmp .ret
.none:
    xor eax, eax
    xor ecx, ecx
.ret:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    ret

; .digit: next digit at RSI (skipping a `_` between digits when allowed)
;   -> AL = digit character and RSI advanced, CF=1 if no digit
.digit:
    cmp rsi, r9
    jae .no_digit
    mov al, [rsi]
    cmp al, '_'
    jne .check
    test r12d, 1
    jz .no_digit
    cmp rsi, r8
    je .no_digit
    mov ah, [rsi - 1]
    sub ah, '0'
    cmp ah, 9
    ja .no_digit
    lea rax, [rsi + 1]
    cmp rax, r9
    jae .no_digit
    mov al, [rsi + 1]
    sub al, '0'
    cmp al, 9
    ja .no_digit
    inc rsi
    mov al, [rsi]
.check:
    cmp al, '0'
    jb .no_digit
    cmp al, '9'
    ja .no_digit
    inc rsi
    clc
    ret
.no_digit:
    stc
    ret

; ------------------------------------------------------------------------------
; jsnum_digits_to_double: RSI = significant digits (first non-zero), ECX =
; count (1..JSNUM_MAX_DIGITS+1), EDX = decimal exponent E (signed)
; -> RAX = bits of the double nearest to digits x 10^E (ties to even)
; ------------------------------------------------------------------------------
jsnum_digits_to_double:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    test ecx, ecx
    jz .zero
    movsxd r8, edx                  ; E
    mov r9d, ecx                    ; n
    lea rax, [r8 + r9]
    cmp rax, 310
    jg .inf
    cmp rax, -330
    jl .zero
    ; the first (up to) 18 digits as an integer
    mov r10d, r9d
    cmp r10d, 18
    jbe .acc_start
    mov r10d, 18
.acc_start:
    xor eax, eax
    xor ebx, ebx
.acc:
    imul rax, rax, 10
    movzx r11d, byte [rsi + rbx]
    sub r11d, '0'
    add rax, r11
    inc ebx
    cmp ebx, r10d
    jb .acc
    lea r11, [jsnum_pow10_f64]
    ; exact: <= 15 digits and a power of ten that is itself exact
    cmp r9d, 15
    ja .approx
    cmp r8, 22
    jg .approx
    cmp r8, -22
    jl .approx
    cvtsi2sd xmm0, rax
    mov rbx, r8
    test rbx, rbx
    js .fast_div
    mulsd xmm0, [r11 + rbx*8]
    movq rax, xmm0
    jmp .out
.fast_div:
    neg rbx
    divsd xmm0, [r11 + rbx*8]
    movq rax, xmm0
    jmp .out
.approx:
    ; a guess within a few ulps, then settle it exactly
    cvtsi2sd xmm0, rax
    mov rbx, r8
    add rbx, r9
    sub rbx, r10                    ; exponent still to apply
    movsd xmm2, [r11 + 22*8]
.scale_up:
    cmp rbx, 22
    jle .scale_down
    mulsd xmm0, xmm2
    sub rbx, 22
    jmp .scale_up
.scale_down:
    cmp rbx, -22
    jge .scale_last
    divsd xmm0, xmm2
    add rbx, 22
    jmp .scale_down
.scale_last:
    test rbx, rbx
    js .scale_neg
    mulsd xmm0, [r11 + rbx*8]
    jmp .scaled
.scale_neg:
    neg rbx
    divsd xmm0, [r11 + rbx*8]
.scaled:
    movq rax, xmm0
    mov rbx, JS_INF
    cmp rax, rbx
    jb .finite
    mov rax, 0x7FEFFFFFFFFFFFFF     ; largest double
.finite:
    test rax, rax
    jnz .guess
    mov eax, 1                      ; smallest subnormal
.guess:
    push rcx
    mov ecx, r9d
    call jsbig_load_digits
    pop rcx
    mov r10d, 4000                  ; iteration guard
.refine:
    dec r10d
    jz .out
    mov r11, rax                    ; candidate bits
    mov rcx, rax
    shr rcx, 52                     ; biased exponent
    mov rdx, 0x000FFFFFFFFFFFFF
    and rdx, rax                    ; fraction
    mov rbx, rdx
    test ecx, ecx
    jz .subnormal
    bts rbx, 52                     ; m
    sub ecx, 1075                   ; e
    jmp .upper
.subnormal:
    mov ecx, -1074
.upper:
    ; above the midpoint (2m+1) * 2^(e-1) -> next double up
    lea rax, [rbx*2 + 1]
    push rcx
    dec ecx
    call jsnum_cmp_exact
    pop rcx
    test eax, eax
    jg .go_up
    jl .lower
    test r11, 1
    jz .settled                     ; tie, even stays
.go_up:
    lea rax, [r11 + 1]
    mov rdx, JS_INF
    cmp rax, rdx
    jae .inf
    jmp .refine
.lower:
    test r11, r11
    jz .settled
    ; below the midpoint to the next double down -> go down
    mov rax, r11
    shr rax, 52
    test rdx, rdx
    jnz .lower_normal
    cmp eax, 1
    jbe .lower_normal
    lea rax, [rbx*4 - 1]            ; 2^k boundary: the gap below is half as wide
    push rcx
    sub ecx, 2
    call jsnum_cmp_exact
    pop rcx
    jmp .lower_cmp
.lower_normal:
    lea rax, [rbx*2 - 1]
    push rcx
    dec ecx
    call jsnum_cmp_exact
    pop rcx
.lower_cmp:
    test eax, eax
    jg .settled
    jl .go_down
    test r11, 1
    jz .settled
.go_down:
    lea rax, [r11 - 1]
    jmp .refine
.settled:
    mov rax, r11
    jmp .out
.inf:
    mov rax, JS_INF
    jmp .out
.zero:
    xor eax, eax
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsnum_cmp_exact: sign of (jsbig_d x 10^R8) - (RAX x 2^ECX) -> EAX
jsnum_cmp_exact:
    push rbx
    push rcx
    push rsi
    push rdi
    mov ebx, ecx
    lea rdi, [jsbig_b]
    call jsbig_set
    lea rdi, [jsbig_a]
    lea rsi, [jsbig_d]
    call jsbig_copy
    test r8, r8
    js .e_neg
    mov ecx, r8d
    lea rdi, [jsbig_a]
    call jsbig_mul_pow10
    jmp .k
.e_neg:
    mov rcx, r8
    neg ecx
    lea rdi, [jsbig_b]
    call jsbig_mul_pow10
.k:
    test ebx, ebx
    js .k_neg
    mov ecx, ebx
    lea rdi, [jsbig_b]
    call jsbig_shl
    jmp .cmp
.k_neg:
    mov ecx, ebx
    neg ecx
    lea rdi, [jsbig_a]
    call jsbig_shl
.cmp:
    lea rsi, [jsbig_a]
    lea rdi, [jsbig_b]
    call jsbig_cmp
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; jsnum_parse_radix: digits of base EBX (2..36) at RSI, at most RCX bytes
; -> RAX = double bits, RCX = bytes consumed (0 = no digit)
; ------------------------------------------------------------------------------
jsnum_parse_radix:
    push rdx
    push rsi
    push r8
    lea r8, [rsi + rcx]
    xorpd xmm0, xmm0
    cvtsi2sd xmm1, rbx
    xor ecx, ecx
.loop:
    cmp rsi, r8
    jae .done
    movzx eax, byte [rsi]
    call jsnum_digit_value
    cmp eax, ebx
    jae .done
    mulsd xmm0, xmm1
    cvtsi2sd xmm2, rax
    addsd xmm0, xmm2
    inc rsi
    inc ecx
    jmp .loop
.done:
    movq rax, xmm0
    pop r8
    pop rsi
    pop rdx
    ret

; jsnum_digit_value: EAX = character -> EAX = digit value (0-35), or 99
jsnum_digit_value:
    cmp eax, '0'
    jb .bad
    cmp eax, '9'
    jbe .dec
    or eax, 0x20
    cmp eax, 'a'
    jb .bad
    cmp eax, 'z'
    ja .bad
    sub eax, 'a' - 10
    ret
.dec:
    sub eax, '0'
    ret
.bad:
    mov eax, 99
    ret

; ------------------------------------------------------------------------------
; jsnum_skip_space: skip JavaScript white space and line terminators
;   RSI = text, RCX = length -> RSI, RCX past the white space
; jsnum_trim_end: RSI = text, RCX = length -> RCX without trailing white space
; ------------------------------------------------------------------------------
jsnum_skip_space:
    push rax
.loop:
    call jsnum_space_len
    test eax, eax
    jz .done
    add rsi, rax
    sub rcx, rax
    jmp .loop
.done:
    pop rax
    ret

jsnum_trim_end:
    push rax
    push rdx
.loop:
    test rcx, rcx
    jz .done
    movzx eax, byte [rsi + rcx - 1]
    cmp al, ' '
    je .one
    cmp al, 9
    jb .multi
    cmp al, 13
    jbe .one
.multi:
    ; U+00A0 (C2 A0), U+FEFF (EF BB BF), U+2028/9 (E2 80 A8/A9)
    cmp rcx, 2
    jb .done
    cmp al, 0xA0
    jne .three
    cmp byte [rsi + rcx - 2], 0xC2
    jne .three
    sub rcx, 2
    jmp .loop
.three:
    cmp rcx, 3
    jb .done
    lea rdx, [rsi + rcx - 3]
    push rsi
    push rcx
    mov rsi, rdx
    mov ecx, 3
    call jsnum_space_len
    pop rcx
    pop rsi
    cmp eax, 3
    jne .done
    sub rcx, 3
    jmp .loop
.one:
    dec rcx
    jmp .loop
.done:
    pop rdx
    pop rax
    ret

; jsnum_space_len: RSI = text, RCX = length -> EAX = bytes of the white space
; character at RSI, 0 if none
jsnum_space_len:
    xor eax, eax
    test rcx, rcx
    jz .ret
    mov al, [rsi]
    cmp al, ' '
    je .one
    cmp al, 9
    jb .none
    cmp al, 13
    jbe .one
    cmp al, 0xC2
    je .c2
    cmp al, 0xEF
    je .ef
    cmp al, 0xE2
    je .e2
.none:
    xor eax, eax
.ret:
    ret
.one:
    mov eax, 1
    ret
.c2:
    cmp rcx, 2
    jb .none
    cmp byte [rsi + 1], 0xA0
    jne .none
    mov eax, 2
    ret
.ef:
    cmp rcx, 3
    jb .none
    cmp word [rsi + 1], 0xBFBB
    jne .none
    mov eax, 3
    ret
.e2:
    cmp rcx, 3
    jb .none
    cmp byte [rsi + 1], 0x80
    jne .none
    mov al, [rsi + 2]
    cmp al, 0xA8
    je .three
    cmp al, 0xA9
    jne .none
.three:
    mov eax, 3
    ret

; ------------------------------------------------------------------------------
; jsnum_string_to_number: ToNumber for a string. RSI = text, RCX = length
; -> RAX = double bits (NaN when the whole string is not a number)
; ------------------------------------------------------------------------------
jsnum_string_to_number:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    call jsnum_skip_space
    call jsnum_trim_end
    test rcx, rcx
    jz .zero
    cmp rcx, 2
    jb .decimal
    cmp byte [rsi], '0'
    jne .decimal
    mov al, [rsi + 1]
    or al, 0x20
    mov ebx, 16
    cmp al, 'x'
    je .radix
    mov ebx, 8
    cmp al, 'o'
    je .radix
    mov ebx, 2
    cmp al, 'b'
    jne .decimal
.radix:
    add rsi, 2
    sub rcx, 2
    mov r8, rcx
    call jsnum_parse_radix
    test rcx, rcx
    jz .nan
    cmp rcx, r8
    jne .nan
    jmp .out
.decimal:
    xor r8d, r8d                    ; sign bit
    mov al, [rsi]
    cmp al, '+'
    je .sign
    cmp al, '-'
    jne .unsigned
    mov r8, 0x8000000000000000
.sign:
    inc rsi
    dec rcx
.unsigned:
    cmp rcx, 8
    jne .scan
    mov rax, "Infinity"
    cmp [rsi], rax
    jne .scan
    mov rax, JS_INF
    or rax, r8
    jmp .out
.scan:
    mov rbx, rcx
    xor edx, edx
    call jsnum_scan
    test rcx, rcx
    jz .nan
    cmp rcx, rbx
    jne .nan
    or rax, r8
    jmp .out
.zero:
    xor eax, eax
    jmp .out
.nan:
    mov rax, JS_NAN
.out:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ==============================================================================
; Double -> text
; ==============================================================================

; ------------------------------------------------------------------------------
; jsnum_to_string: Number::toString(10). RAX = double bits, RDI = buffer
; (32 bytes is always enough) -> RCX = length (no NUL is written)
; ------------------------------------------------------------------------------
jsnum_to_string:
    push rax
    push rbx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, rdi
    mov rdx, rax
    btr rdx, 63                     ; |x|
    mov rbx, JS_INF
    cmp rdx, rbx
    ja .nan
    je .inf
    test rdx, rdx
    jz .zero
    bt rax, 63
    jnc .positive
    mov byte [rdi], '-'
    inc rdi
.positive:
    ; integers below 2^53: plain decimal
    mov rbx, 0x4340000000000000
    cmp rdx, rbx
    jae .general
    movq xmm0, rdx
    cvttsd2si rax, xmm0
    cvtsi2sd xmm1, rax
    ucomisd xmm0, xmm1
    jne .general
    call jsnum_write_u64
    jmp .end
.general:
    mov rax, rdx
    call jsnum_shortest             ; ECX = digit count, EDX = n
    lea rsi, [jsnum_digits]
    cmp edx, 21
    jg .exponent
    cmp ecx, edx
    jg .fraction
    ; digits then zeros (n >= count)
    mov r9d, edx
    sub r9d, ecx
    rep movsb
.zeros:
    test r9d, r9d
    jz .end
    mov byte [rdi], '0'
    inc rdi
    dec r9d
    jmp .zeros
.fraction:
    cmp edx, 0
    jle .small
    ; ddd.ddd
    mov r9d, ecx
    sub r9d, edx
    mov ecx, edx
    rep movsb
    mov byte [rdi], '.'
    inc rdi
    mov ecx, r9d
    rep movsb
    jmp .end
.small:
    cmp edx, -6
    jle .exponent
    ; 0.000ddd
    mov word [rdi], '0.'
    add rdi, 2
    mov r9d, edx
    neg r9d
.lead:
    test r9d, r9d
    jz .lead_done
    mov byte [rdi], '0'
    inc rdi
    dec r9d
    jmp .lead
.lead_done:
    rep movsb
    jmp .end
.exponent:
    movsb
    dec ecx
    jz .e
    mov byte [rdi], '.'
    inc rdi
    rep movsb
.e:
    mov byte [rdi], 'e'
    inc rdi
    lea eax, [rdx - 1]
    mov byte [rdi], '+'
    test eax, eax
    jns .e_sign
    mov byte [rdi], '-'
    neg eax
.e_sign:
    inc rdi
    call jsnum_write_u64
    jmp .end
.nan:
    lea rsi, [jsnum_str_nan]
    jmp .word
.inf:
    bt rax, 63
    jnc .inf_pos
    mov byte [rdi], '-'
    inc rdi
.inf_pos:
    lea rsi, [jsnum_str_inf]
.word:
    lodsb
    test al, al
    jz .end
    stosb
    jmp .word
.zero:
    mov byte [rdi], '0'
    inc rdi
.end:
    mov rcx, rdi
    sub rcx, r8
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    pop rax
    ret

; jsnum_write_u64: RAX = value, RDI = destination -> RDI advanced past the digits
jsnum_write_u64:
    push rax
    push rcx
    push rdx
    push rsi
    lea rsi, [jsnum_tmp + 24]
    mov ecx, 10
.loop:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .loop
.copy:
    lea rcx, [jsnum_tmp + 24]
    sub rcx, rsi
    rep movsb
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsnum_shortest: RAX = bits of a positive finite non-zero double
; -> jsnum_digits = the fewest digits that read back as the same double (the
;    closest such digits, ties to even), ECX = digit count, EDX = n with
;    value = 0.d1d2... x 10^n
; ------------------------------------------------------------------------------
jsnum_shortest:
    push rax
    push rbx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    ; m (RBX), e (R8D)
    mov rcx, rax
    shr rcx, 52
    mov rbx, 0x000FFFFFFFFFFFFF
    and rbx, rax
    xor r10d, r10d                  ; 1 = the gap below is half the gap above
    test ecx, ecx
    jz .subnormal
    test rbx, rbx
    jnz .normal
    cmp ecx, 1
    jbe .normal
    mov r10d, 1
.normal:
    bts rbx, 52
    lea r8d, [rcx - 1075]
    jmp .decoded
.subnormal:
    mov r8d, -1074
.decoded:
    mov r9d, ebx
    not r9d
    and r9d, 1                      ; 1 = m even: boundaries round to us
    ; r = m << (max(e,0) + 1 + r10), s = 1 << (max(-e,0) + 1 + r10),
    ; mm = 1 << max(e,0), mp = mm << r10
    xor r11d, r11d                  ; max(e, 0)
    xor r12d, r12d                  ; max(-e, 0)
    test r8d, r8d
    js .e_neg
    mov r11d, r8d
    jmp .setup
.e_neg:
    mov r12d, r8d
    neg r12d
.setup:
    lea rdi, [jsbig_r]
    mov rax, rbx
    call jsbig_set
    lea ecx, [r11 + r10 + 1]
    call jsbig_shl
    lea rdi, [jsbig_s]
    mov eax, 1
    call jsbig_set
    lea ecx, [r12 + r10 + 1]
    call jsbig_shl
    lea rdi, [jsbig_mm]
    mov eax, 1
    call jsbig_set
    mov ecx, r11d
    call jsbig_shl
    lea rdi, [jsbig_mp]
    lea rsi, [jsbig_mm]
    call jsbig_copy
    mov ecx, r10d
    call jsbig_shl
    ; estimate n = floor(log10(2) * floor(log2 v)) + 1, at most one too small
    bsr rax, rbx
    add eax, r8d
    movsxd rax, eax
    imul rax, rax, 1292913986       ; log10(2) * 2^32
    sar rax, 32
    inc eax
    mov edx, eax
    test edx, edx
    js .scale_r
    lea rdi, [jsbig_s]
    mov ecx, edx
    call jsbig_mul_pow10
    jmp .fixup
.scale_r:
    mov ecx, edx
    neg ecx
    lea rdi, [jsbig_r]
    call jsbig_mul_pow10
    lea rdi, [jsbig_mp]
    call jsbig_mul_pow10
    lea rdi, [jsbig_mm]
    call jsbig_mul_pow10
.fixup:
    call .high_reached
    jnc .digits
    inc edx
    lea rdi, [jsbig_s]
    mov eax, 10
    call jsbig_mul_small
.digits:
    xor r11d, r11d                  ; digit count
    lea r12, [jsnum_digits]
.next:
    mov eax, 10
    lea rdi, [jsbig_r]
    call jsbig_mul_small
    lea rdi, [jsbig_mp]
    call jsbig_mul_small
    lea rdi, [jsbig_mm]
    call jsbig_mul_small
    ; d = r / s, r = r mod s (quotient is 0..9)
    xor ebx, ebx
.divide:
    lea rsi, [jsbig_r]
    lea rdi, [jsbig_s]
    call jsbig_cmp
    test eax, eax
    js .divided
    lea rdi, [jsbig_r]
    lea rsi, [jsbig_s]
    call jsbig_sub
    inc ebx
    jmp .divide
.divided:
    ; low = r < mm (<= when inclusive)
    lea rsi, [jsbig_r]
    lea rdi, [jsbig_mm]
    call jsbig_cmp
    xor ecx, ecx
    test eax, eax
    js .low_yes
    jnz .low_done
    test r9d, r9d
    jz .low_done
.low_yes:
    mov ecx, 1
.low_done:
    call .high_reached              ; CF = r + mp > s (>= when inclusive)
    jc .high_yes
    test ecx, ecx
    jnz .emit_d
    ; neither: keep going
    lea eax, [rbx + '0']
    mov [r12 + r11], al
    inc r11d
    cmp r11d, 20
    jb .next
    jmp .emit_d                     ; cannot happen for doubles
.high_yes:
    test ecx, ecx
    jz .emit_d1
    ; both: the closer one; 2r vs s
    lea rdi, [jsbig_t]
    lea rsi, [jsbig_r]
    call jsbig_copy
    mov ecx, 1
    call jsbig_shl
    lea rsi, [jsbig_t]
    lea rdi, [jsbig_s]
    call jsbig_cmp
    test eax, eax
    js .emit_d
    jnz .emit_d1
    test ebx, 1
    jz .emit_d
.emit_d1:
    inc ebx
.emit_d:
    lea eax, [rbx + '0']
    mov [r12 + r11], al
    inc r11d
    mov ecx, r11d
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbx
    pop rax
    ret

; .high_reached: CF=1 if r + mp > s (>= when R9D = 1)
.high_reached:
    push rax
    push rsi
    push rdi
    lea rdi, [jsbig_t]
    lea rsi, [jsbig_r]
    call jsbig_copy
    lea rsi, [jsbig_mp]
    call jsbig_add
    lea rsi, [jsbig_t]
    lea rdi, [jsbig_s]
    call jsbig_cmp
    test eax, eax
    jg .hr_yes
    jl .hr_no
    test r9d, r9d
    jnz .hr_yes
.hr_no:
    pop rdi
    pop rsi
    pop rax
    clc
    ret
.hr_yes:
    pop rdi
    pop rsi
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; jsnum_to_int32: RAX = double bits -> EAX = ToInt32 (upper half of RAX = 0)
; ------------------------------------------------------------------------------
jsnum_to_int32:
    push rcx
    push rdx
    mov rdx, rax
    shr rdx, 52
    and edx, 0x7FF
    cmp edx, 0x7FF
    je .zero                        ; NaN, Infinity
    cmp edx, 1023 + 63
    jae .big
    movq xmm0, rax
    cvttsd2si rax, xmm0
    mov eax, eax
    jmp .out
.big:
    ; |x| >= 2^63: an integer; only its low 32 bits matter
    lea ecx, [rdx - 1075]           ; shift of the 53-bit mantissa (>= 11)
    cmp ecx, 64
    jae .zero
    mov rdx, rax
    mov rax, 0x000FFFFFFFFFFFFF
    and rax, rdx
    bts rax, 52
    shl rax, cl
    bt rdx, 63
    jnc .trunc
    neg rax
.trunc:
    mov eax, eax
    jmp .out
.zero:
    xor eax, eax
.out:
    pop rdx
    pop rcx
    ret
