; ==============================================================================
; Antigravity OS - 16550 UART (COM1) Driver
; ------------------------------------------------------------------------------
; Every console character is mirrored here (see console/console.asm), and bytes
; received on COM1 are fed into the key queue exactly like keyboard input. That
; makes the whole OS scriptable over a serial line:
;     python tools/build.py run --headless      (serial console in your terminal)
;     tests/harness.py                          (automated tests)
; klog/klog_* write to the serial port only, for debug traces that should not
; clutter the screen.
; ==============================================================================

[bits 64]

COM1_PORT               equ 0x3F8
UART_DATA               equ 0
UART_IER                equ 1
UART_FCR                equ 2
UART_LCR                equ 3
UART_MCR                equ 4
UART_LSR                equ 5
UART_LSR_DATA_READY     equ 0x01
UART_LSR_THR_EMPTY      equ 0x20

section .data
serial_present:         db 0

section .text
; ------------------------------------------------------------------------------
; serial_init: 115200 baud, 8N1, FIFOs on, no interrupts
; ------------------------------------------------------------------------------
serial_init:
    push rax
    push rdx
    mov dx, COM1_PORT + UART_IER
    xor al, al
    out dx, al
    mov dx, COM1_PORT + UART_LCR
    mov al, 0x80                    ; DLAB
    out dx, al
    mov dx, COM1_PORT + UART_DATA
    mov al, 1                       ; divisor 1 = 115200 baud
    out dx, al
    mov dx, COM1_PORT + UART_IER
    xor al, al
    out dx, al
    mov dx, COM1_PORT + UART_LCR
    mov al, 0x03                    ; 8N1
    out dx, al
    mov dx, COM1_PORT + UART_FCR
    mov al, 0xC7
    out dx, al
    mov dx, COM1_PORT + UART_MCR
    mov al, 0x03
    out dx, al
    ; A missing UART reads back 0xFF from LSR
    mov dx, COM1_PORT + UART_LSR
    in al, dx
    cmp al, 0xFF
    je .absent
    mov byte [serial_present], 1
.absent:
    pop rdx
    pop rax
    ret

; ------------------------------------------------------------------------------
; serial_putc: AL = byte (raw, no newline translation)
; ------------------------------------------------------------------------------
serial_putc:
    cmp byte [serial_present], 0
    je .ret
    push rax
    push rcx
    push rdx
    mov ah, al
    mov dx, COM1_PORT + UART_LSR
    mov ecx, 100000                 ; don't hang forever if nobody is listening
.wait:
    in al, dx
    test al, UART_LSR_THR_EMPTY
    jnz .send
    pause
    dec ecx
    jnz .wait
.send:
    mov dx, COM1_PORT + UART_DATA
    mov al, ah
    out dx, al
    pop rdx
    pop rcx
    pop rax
.ret:
    ret

; ------------------------------------------------------------------------------
; serial_getc: CF=1 and AL = byte if one is waiting, CF=0 otherwise
; ------------------------------------------------------------------------------
serial_getc:
    push rdx
    cmp byte [serial_present], 0
    je .none
    mov dx, COM1_PORT + UART_LSR
    in al, dx
    test al, UART_LSR_DATA_READY
    jz .none
    mov dx, COM1_PORT + UART_DATA
    in al, dx
    pop rdx
    stc
    ret
.none:
    pop rdx
    clc
    ret

; ------------------------------------------------------------------------------
; serial_puts: RSI = string (newlines become CR LF)
; ------------------------------------------------------------------------------
serial_puts:
    push rax
    push rsi
.loop:
    lodsb
    test al, al
    jz .done
    call serial_putc_text
    jmp .loop
.done:
    pop rsi
    pop rax
    ret

; serial_putc_text: like serial_putc but "\n" -> "\r\n"
serial_putc_text:
    cmp al, 0x0A
    jne serial_putc
    push rax
    mov al, 0x0D
    call serial_putc
    pop rax
    jmp serial_putc

; ------------------------------------------------------------------------------
; klog: RSI = message. Serial-only debug line, prefixed with "[klog] ".
; klog_hex: RSI = message, RAX = value -> "[klog] <msg>0x<value>"
; ------------------------------------------------------------------------------
klog:
    push rsi
    lea rsi, [klog_prefix]
    call serial_puts
    pop rsi
    call serial_puts
    push rax
    mov al, 0x0A
    call serial_putc_text
    pop rax
    ret

klog_hex:
    push rax
    push rcx
    push rsi
    lea rsi, [klog_prefix]
    call serial_puts
    mov rsi, [rsp]
    call serial_puts
    mov rcx, 16
.hex:
    rol rax, 4
    push rax
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .digit
    add al, 'A' - '9' - 1
.digit:
    call serial_putc
    pop rax
    dec rcx
    jnz .hex
    mov al, 0x0A
    call serial_putc_text
    pop rsi
    pop rcx
    pop rax
    ret

; klog2: RSI = message, RDI = second string -> "[klog] <msg><second>"
klog2:
    push rax
    push rsi
    lea rsi, [klog_prefix]
    call serial_puts
    mov rsi, [rsp]
    call serial_puts
    mov rsi, rdi
    call serial_puts
    mov al, 0x0A
    call serial_putc_text
    pop rsi
    pop rax
    ret

; klog_dec: RSI = message, RAX = value -> "[klog] <msg><decimal>"
klog_dec:
    push rdi
    sub rsp, 32
    mov rdi, rsp
    call fmt_dec
    mov rdi, rsp
    call klog2
    add rsp, 32
    pop rdi
    ret

section .rodata
klog_prefix:            db "[klog] ", 0
