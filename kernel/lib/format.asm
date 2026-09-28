; ==============================================================================
; Antigravity OS - Formatting into memory buffers
; ------------------------------------------------------------------------------
; Like the con_* printers, but they write into a buffer at RDI and return RDI
; pointing at the terminating NUL, so calls can be chained:
;     lea rdi, [buf]
;     lea rsi, [label]  / call fmt_str
;     mov rax, 42       / call fmt_dec
; All routines preserve every register except RDI (advanced).
; ==============================================================================

[bits 64]
section .text

; fmt_str: append string RSI
fmt_str:
    push rax
    push rsi
.loop:
    lodsb
    mov [rdi], al
    test al, al
    jz .done
    inc rdi
    jmp .loop
.done:
    pop rsi
    pop rax
    ret

; fmt_char: append AL
fmt_char:
    mov [rdi], al
    inc rdi
    mov byte [rdi], 0
    ret

; fmt_dec: append RAX in decimal
fmt_dec:
    push rax
    push rcx
    push rdx
    push rsi
    sub rsp, 24
    lea rsi, [rsp + 23]
    mov byte [rsi], 0
    mov ecx, 10
.loop:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .loop
    call fmt_str
    add rsp, 24
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; fmt_dec2: append RAX (0-99) as two digits
fmt_dec2:
    push rax
    push rdx
    push rcx
    xor edx, edx
    mov ecx, 10
    div rcx
    add al, '0'
    call fmt_char
    mov al, dl
    add al, '0'
    call fmt_char
    pop rcx
    pop rdx
    pop rax
    ret

; fmt_hex8: append AL as two hex digits
fmt_hex8:
    push rax
    push rbx
    mov bl, al
    shr al, 4
    call .nibble
    mov al, bl
    and al, 0x0F
    call .nibble
    pop rbx
    pop rax
    ret
.nibble:
    add al, '0'
    cmp al, '9'
    jbe .digit
    add al, 'A' - '9' - 1
.digit:
    jmp fmt_char

; fmt_ip: append the IPv4 address at RSI as a.b.c.d
fmt_ip:
    push rax
    push rcx
    xor ecx, ecx
.loop:
    movzx eax, byte [rsi + rcx]
    call fmt_dec
    inc ecx
    cmp ecx, 4
    je .done
    mov al, '.'
    call fmt_char
    jmp .loop
.done:
    pop rcx
    pop rax
    ret

; fmt_mac: append the MAC address at RSI as AA:BB:CC:DD:EE:FF
fmt_mac:
    push rax
    push rcx
    xor ecx, ecx
.loop:
    mov al, [rsi + rcx]
    call fmt_hex8
    inc ecx
    cmp ecx, 6
    je .done
    mov al, ':'
    call fmt_char
    jmp .loop
.done:
    pop rcx
    pop rax
    ret

; fmt_uptime: append the time since boot as H:MM:SS
fmt_uptime:
    push rax
    push rcx
    push rdx
    call timer_uptime_seconds
    xor edx, edx
    mov ecx, 3600
    div rcx
    call fmt_dec
    mov al, ':'
    call fmt_char
    mov rax, rdx
    xor edx, edx
    mov ecx, 60
    div rcx
    call fmt_dec2
    mov al, ':'
    call fmt_char
    mov rax, rdx
    call fmt_dec2
    pop rdx
    pop rcx
    pop rax
    ret
