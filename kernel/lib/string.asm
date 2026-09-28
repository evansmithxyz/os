; ==============================================================================
; Antigravity OS - String & Memory Helpers
; All routines preserve every register except the documented outputs.
; ==============================================================================

[bits 64]
section .text

; ------------------------------------------------------------------------------
; strlen: RSI = string -> RAX = length
; ------------------------------------------------------------------------------
strlen:
    xor eax, eax
.loop:
    cmp byte [rsi + rax], 0
    je .done
    inc rax
    jmp .loop
.done:
    ret

; ------------------------------------------------------------------------------
; strcmp: compare strings at RSI and RDI -> ZF=1 if equal
; ------------------------------------------------------------------------------
strcmp:
    push rsi
    push rdi
    push rax
.loop:
    mov al, [rsi]
    cmp al, [rdi]
    jne .done                       ; ZF=0
    test al, al
    jz .done                        ; ZF=1
    inc rsi
    inc rdi
    jmp .loop
.done:
    pop rax
    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------------------------
; strncmp: compare at most RCX bytes of RSI and RDI -> ZF=1 if equal
; ------------------------------------------------------------------------------
strncmp:
    push rsi
    push rdi
    push rcx
    push rax
.loop:
    test rcx, rcx
    jz .equal
    mov al, [rsi]
    cmp al, [rdi]
    jne .done                       ; ZF=0
    test al, al
    jz .done                        ; ZF=1
    inc rsi
    inc rdi
    dec rcx
    jmp .loop
.equal:
    cmp eax, eax                    ; ZF=1
.done:
    pop rax
    pop rcx
    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------------------------
; strcpy: copy NUL-terminated string RSI -> RDI (unbounded; prefer strlcpy)
; ------------------------------------------------------------------------------
strcpy:
    push rsi
    push rdi
    push rax
.loop:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .loop
    pop rax
    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------------------------
; strlcpy: copy string RSI -> RDI, writing at most RCX bytes including the NUL
; (RCX must be >= 1). Always NUL-terminates.
; ------------------------------------------------------------------------------
strlcpy:
    push rsi
    push rdi
    push rcx
    push rax
    dec rcx
.loop:
    test rcx, rcx
    jz .term
    mov al, [rsi]
    test al, al
    jz .term
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .loop
.term:
    mov byte [rdi], 0
    pop rax
    pop rcx
    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------------------------
; memcpy: copy RCX bytes RSI -> RDI
; memset: fill RCX bytes at RDI with AL
; ------------------------------------------------------------------------------
memcpy:
    push rsi
    push rdi
    push rcx
    rep movsb
    pop rcx
    pop rdi
    pop rsi
    ret

memset:
    push rdi
    push rcx
    rep stosb
    pop rcx
    pop rdi
    ret

; ------------------------------------------------------------------------------
; skip_spaces: advance RSI past spaces
; ------------------------------------------------------------------------------
skip_spaces:
.loop:
    cmp byte [rsi], ' '
    jne .done
    inc rsi
    jmp .loop
.done:
    ret

; ------------------------------------------------------------------------------
; next_word: copy the space-delimited word at RSI into RDI (buffer of RCX bytes
; including the NUL), then advance RSI past the word and any following spaces.
; Output: RAX = word length (0 if RSI was at end of string)
; ------------------------------------------------------------------------------
next_word:
    push rdi
    push rcx
    push rdx
    call skip_spaces
    xor eax, eax
    dec rcx                         ; room for the NUL
.loop:
    mov dl, [rsi]
    test dl, dl
    jz .end
    cmp dl, ' '
    je .end
    inc rsi
    cmp rax, rcx
    jae .loop                       ; too long: truncate but keep consuming
    mov [rdi + rax], dl
    inc rax
    jmp .loop
.end:
    mov byte [rdi + rax], 0
    call skip_spaces
    pop rdx
    pop rcx
    pop rdi
    ret

; ------------------------------------------------------------------------------
; parse_dec: parse an unsigned decimal number at RSI
; Output: RAX = value, RSI advanced past the digits, CF=1 if no digits found
; ------------------------------------------------------------------------------
parse_dec:
    push rdx
    push rcx
    xor eax, eax
    xor ecx, ecx                    ; digit count
.loop:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .done
    imul rax, rax, 10
    add rax, rdx
    inc rsi
    inc ecx
    jmp .loop
.done:
    cmp ecx, 1                      ; CF=1 when ecx == 0
    pop rcx
    pop rdx
    ret

; ------------------------------------------------------------------------------
; str_has_prefix: ZF=1 if the string at RSI starts with the string at RDI
; ------------------------------------------------------------------------------
str_has_prefix:
    push rsi
    push rdi
    push rax
.loop:
    mov al, [rdi]
    test al, al
    jz .done                        ; end of prefix: ZF=1
    cmp al, [rsi]
    jne .done                       ; ZF=0
    inc rsi
    inc rdi
    jmp .loop
.done:
    pop rax
    pop rdi
    pop rsi
    ret
