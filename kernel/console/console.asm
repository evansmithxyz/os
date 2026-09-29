; ==============================================================================
; Antigravity OS - Console (output routing + key input queue)
; ------------------------------------------------------------------------------
; OUTPUT: every con_* routine ends up in con_putc, which
;   1. mirrors the character to the serial port (COM1), and
;   2. draws it on the VGA text screen, or - while the desktop is running -
;      appends it to the GUI terminal window (apps/terminal.asm).
; So shell commands print the same way no matter where they run.
; Colours are VGA text attributes (COLOR_* in drivers/vga_text.asm); the GUI
; terminal maps them to RGB.
;
; INPUT: keyboard IRQ and serial bytes both become key events (AL = ASCII,
; AH = scancode) in a small ring buffer. key_get pops one.
;
; Every routine preserves all registers except documented outputs.
; ==============================================================================

[bits 64]

KEYQ_SIZE               equ 256     ; power of two

section .data
con_attr:               db COLOR_LIGHT_GRAY
con_serial_last_cr:     db 0
align 4
keyq_head:              dd 0        ; next slot to write
keyq_tail:              dd 0        ; next slot to read

section .bss
alignb 16
keyq_buf:               resw KEYQ_SIZE
con_num_buf:            resb 24

section .text
; ==============================================================================
; Output
; ==============================================================================

; con_putc: AL = character
con_putc:
    push rbx
    ; 1. serial mirror
    cmp al, 0x08
    jne .serial_plain
    push rax                        ; backspace: erase on a terminal too
    call serial_putc
    mov al, ' '
    call serial_putc
    mov al, 0x08
    call serial_putc
    pop rax
    jmp .screen
.serial_plain:
    call serial_putc_text
.screen:
    ; 2. screen: GUI terminal while the desktop runs, else VGA text
    mov bl, [con_attr]
    cmp byte [bga_active], 0
    jne .gui
    call vga_putc
    pop rbx
    ret
.gui:
    call term_putc
    pop rbx
    ret

; con_newline
con_newline:
    push rax
    mov al, 0x0A
    call con_putc
    pop rax
    ret

; con_puts: RSI = NUL-terminated string
con_puts:
    push rax
    push rsi
.loop:
    lodsb
    test al, al
    jz .done
    call con_putc
    jmp .loop
.done:
    pop rsi
    pop rax
    ret

; con_puts_color: RSI = string, BL = attribute (con_attr is restored after)
con_puts_color:
    push rax
    mov al, [con_attr]
    mov [con_attr], bl
    call con_puts
    mov [con_attr], al
    pop rax
    ret

; con_puts_pad: RSI = string, RCX = column width. Prints the string, then
; spaces up to the width (at least one space).
con_puts_pad:
    push rax
    push rcx
    call con_puts
    call strlen
    sub rcx, rax
    cmp rcx, 1
    jge .pad
    mov ecx, 1
.pad:
    mov al, ' '
    call con_putc
    dec rcx
    jnz .pad
    pop rcx
    pop rax
    ret

; con_spaces: RCX = number of spaces
con_spaces:
    push rax
    push rcx
    test rcx, rcx
    jz .done
    mov al, ' '
.loop:
    call con_putc
    dec rcx
    jnz .loop
.done:
    pop rcx
    pop rax
    ret

; con_clear: clear the active screen (text console or GUI terminal)
con_clear:
    push rbx
    cmp byte [bga_active], 0
    jne .gui
    mov bl, [con_attr]
    call vga_clear
    pop rbx
    ret
.gui:
    call term_clear
    pop rbx
    ret

; con_dec: RAX = unsigned value, printed in decimal
con_dec:
    push rax
    push rcx
    push rdx
    push rsi
    lea rsi, [con_num_buf + 23]
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
    call con_puts
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; con_hex64 / con_hex32 / con_hex16 / con_hex8: "0x" + fixed-width hex
; (con_hex8 / con_hex16 print the digits only, for MACs and ports)
con_hex64:
    push rcx
    mov ecx, 16
    call con_hex_prefixed
    pop rcx
    ret
con_hex32:
    push rcx
    mov ecx, 8
    call con_hex_prefixed
    pop rcx
    ret
con_hex16:
    push rcx
    mov ecx, 4
    call con_hex_digits
    pop rcx
    ret
con_hex8:
    push rcx
    mov ecx, 2
    call con_hex_digits
    pop rcx
    ret

con_hex_prefixed:                   ; RAX = value, RCX = digit count
    push rax
    mov al, '0'
    call con_putc
    mov al, 'x'
    call con_putc
    pop rax
    ; fall through
con_hex_digits:                     ; RAX = value, RCX = digit count (1-16)
    push rax
    push rbx
    push rcx
    mov rbx, rax
    ; rotate so the most significant requested nibble is on top
    mov eax, 16
    sub eax, ecx
    shl eax, 2
    push rcx
    mov ecx, eax
    rol rbx, cl
    pop rcx
.loop:
    rol rbx, 4
    mov al, bl
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .digit
    add al, 'A' - '9' - 1
.digit:
    call con_putc
    dec ecx
    jnz .loop
    pop rcx
    pop rbx
    pop rax
    ret

; con_ip: RSI = 4-byte IPv4 address (network order) -> "a.b.c.d"
con_ip:
    push rax
    push rcx
    xor ecx, ecx
.loop:
    movzx eax, byte [rsi + rcx]
    call con_dec
    inc ecx
    cmp ecx, 4
    je .done
    mov al, '.'
    call con_putc
    jmp .loop
.done:
    pop rcx
    pop rax
    ret

; con_mac: RSI = 6-byte MAC -> "AA:BB:CC:DD:EE:FF"
con_mac:
    push rax
    push rcx
    xor ecx, ecx
.loop:
    movzx eax, byte [rsi + rcx]
    call con_hex8
    inc ecx
    cmp ecx, 6
    je .done
    mov al, ':'
    call con_putc
    jmp .loop
.done:
    pop rcx
    pop rax
    ret

; con_idle: call from long-running loops so the desktop keeps redrawing
con_idle:
    cmp byte [bga_active], 0
    je .ret
    call gui_idle
.ret:
    ret

; ==============================================================================
; Input
; ==============================================================================

; key_push: AX = key event. Safe to call from interrupt handlers.
key_push:
    push rbx
    push rcx
    pushfq
    cli
    mov ebx, [keyq_head]
    lea ecx, [ebx + 1]
    and ecx, KEYQ_SIZE - 1
    cmp ecx, [keyq_tail]
    je .full                        ; drop the key when the queue is full
    push rdx
    lea rdx, [keyq_buf]
    mov [rdx + rbx * 2], ax
    pop rdx
    mov [keyq_head], ecx
.full:
    popfq
    pop rcx
    pop rbx
    ret

; key_get: CF=1 and AX = key event if one is waiting, CF=0 if the queue is empty
key_get:
    call key_poll_serial
    push rbx
    pushfq
    cli
    mov ebx, [keyq_tail]
    cmp ebx, [keyq_head]
    je .empty
    push rdx
    lea rdx, [keyq_buf]
    mov ax, [rdx + rbx * 2]
    pop rdx
    inc ebx
    and ebx, KEYQ_SIZE - 1
    mov [keyq_tail], ebx
    popfq
    pop rbx
    stc
    ret
.empty:
    popfq
    pop rbx
    clc
    ret

; key_poll_serial: turn waiting COM1 bytes into key events
;   CR/LF -> Enter, DEL/BS -> Backspace, TAB, ESC, Ctrl+C, printable ASCII
key_poll_serial:
    push rax
.next:
    ; leave bytes in the UART while the queue is (nearly) full: QEMU and real
    ; terminals hold the rest back instead of losing it
    mov eax, [keyq_head]
    sub eax, [keyq_tail]
    and eax, KEYQ_SIZE - 1
    cmp eax, KEYQ_SIZE - 8
    jae .done
    call serial_getc
    jnc .done
    cmp al, 0x0A
    je .lf
    mov byte [con_serial_last_cr], 0
    cmp al, 0x0D
    je .enter
    cmp al, 0x7F
    je .backspace
    cmp al, 0x08
    je .backspace
    cmp al, 0x09
    je .tab
    cmp al, 0x1B
    je .escape
    cmp al, 0x03
    je .ctrl_c
    cmp al, 0x20
    jb .next
    cmp al, 0x7E
    ja .next
    xor ah, ah
    call key_push
    jmp .next
.lf:
    cmp byte [con_serial_last_cr], 0
    mov byte [con_serial_last_cr], 0
    jne .next                       ; CR LF counts as one Enter
    jmp .push_enter
.enter:
    mov byte [con_serial_last_cr], 1
.push_enter:
    mov ax, (SC_ENTER << 8) | 0x0D
    call key_push
    jmp .next
.backspace:
    mov ax, (SC_BACKSPACE << 8) | 0x08
    call key_push
    jmp .next
.tab:
    mov ax, (SC_TAB << 8) | 0x09
    call key_push
    jmp .next
.escape:
    mov ax, (SC_ESC << 8) | 27
    call key_push
    jmp .next
.ctrl_c:
    mov ax, (0x2E << 8) | 3
    call key_push
    jmp .next
.done:
    pop rax
    ret

; con_check_cancel: drain pending keys; CF=1 if Esc, 'q' or Ctrl+C was pressed.
; For long-running commands (e.g. the web server) that should be stoppable.
con_check_cancel:
    push rax
.next:
    call key_get
    jnc .none
    cmp al, 27
    je .cancel
    cmp al, 3
    je .cancel
    cmp al, 'q'
    je .cancel
    cmp al, 'Q'
    je .cancel
    jmp .next
.cancel:
    pop rax
    stc
    ret
.none:
    pop rax
    clc
    ret
