; ==============================================================================
; Antigravity OS - 64-bit VGA 80x25 Color Text Mode Driver
; Manages Video RAM at 0x000B8000, hardware cursor, 64-bit hex/dec formatting
; ==============================================================================

[bits 64]

VGA_BUFFER      equ 0x000B8000
VGA_COLS        equ 80
VGA_ROWS        equ 25
VGA_CELLS       equ VGA_COLS * VGA_ROWS

; Color Codes
COLOR_BLACK         equ 0x00
COLOR_BLUE          equ 0x01
COLOR_GREEN         equ 0x02
COLOR_CYAN          equ 0x03
COLOR_RED           equ 0x04
COLOR_MAGENTA       equ 0x05
COLOR_BROWN         equ 0x06
COLOR_LIGHT_GRAY    equ 0x07
COLOR_DARK_GRAY     equ 0x08
COLOR_LIGHT_BLUE    equ 0x09
COLOR_LIGHT_GREEN   equ 0x0A
COLOR_LIGHT_CYAN    equ 0x0B
COLOR_LIGHT_RED     equ 0x0C
COLOR_LIGHT_MAGENTA equ 0x0D
COLOR_YELLOW        equ 0x0E
COLOR_WHITE         equ 0x0F

; VGA I/O Ports
VGA_PORT_INDEX      equ 0x3D4
VGA_PORT_DATA       equ 0x3D5

cursor_row:         db 0
cursor_col:         db 0
current_attr:       db 0x0F     ; Default: White on Black
hex64_buffer:       db "0x0000000000000000", 0
hex32_buffer:       db "0x00000000", 0
dec_buffer:         times 24 db 0

; ------------------------------------------------------------------------------
; vga_clear_screen: Clears the entire text display with the current attribute
; ------------------------------------------------------------------------------
vga_clear_screen:
    push rax
    push rcx
    push rdi

    mov rdi, VGA_BUFFER
    mov rcx, VGA_CELLS
    mov ah, [current_attr]
    mov al, ' '
    rep stosw

    mov byte [cursor_row], 0
    mov byte [cursor_col], 0
    call vga_update_cursor

    pop rdi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_print_char: Prints character in AL to screen at current cursor position
; Handles: '\n' (0x0A), '\r' (0x0D), '\b' (0x08)
; ------------------------------------------------------------------------------
vga_print_char:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi

    cmp al, 0x0A                ; Line Feed
    je .newline
    cmp al, 0x0D                ; Carriage Return
    je .carriagereturn
    cmp al, 0x08                ; Backspace
    je .backspace

    ; Normal printable character
    movzx rcx, byte [cursor_row]
    imul rcx, VGA_COLS
    movzx rdx, byte [cursor_col]
    add rcx, rdx
    shl rcx, 1                  ; 2 bytes per cell

    mov rdi, VGA_BUFFER
    add rdi, rcx
    mov ah, [current_attr]
    mov [rdi], ax

    ; Advance cursor
    inc byte [cursor_col]
    cmp byte [cursor_col], VGA_COLS
    jl .done
    mov byte [cursor_col], 0
    inc byte [cursor_row]
    jmp .check_scroll

.newline:
    mov byte [cursor_col], 0
    inc byte [cursor_row]
    jmp .check_scroll

.carriagereturn:
    mov byte [cursor_col], 0
    jmp .done

.backspace:
    cmp byte [cursor_col], 0
    je .done                    ; Cannot backspace past left edge
    dec byte [cursor_col]

    movzx rcx, byte [cursor_row]
    imul rcx, VGA_COLS
    movzx rdx, byte [cursor_col]
    add rcx, rdx
    shl rcx, 1
    mov rdi, VGA_BUFFER
    add rdi, rcx
    mov byte [rdi], ' '
    mov al, [current_attr]
    mov byte [rdi+1], al
    jmp .done

.check_scroll:
    cmp byte [cursor_row], VGA_ROWS
    jl .done
    call vga_scroll

.done:
    call vga_update_cursor
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_scroll: Scrolls screen content up by 1 row when bottom is reached
; ------------------------------------------------------------------------------
vga_scroll:
    push rax
    push rcx
    push rdi
    push rsi
    cld

    mov rdi, VGA_BUFFER
    mov rsi, VGA_BUFFER + (VGA_COLS * 2)
    mov rcx, (VGA_ROWS - 1) * VGA_COLS
    rep movsw

    mov rdi, VGA_BUFFER + ((VGA_ROWS - 1) * VGA_COLS * 2)
    mov rcx, VGA_COLS
    mov ah, [current_attr]
    mov al, ' '
    rep stosw

    mov byte [cursor_row], VGA_ROWS - 1
    pop rsi
    pop rdi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_update_cursor: Updates hardware text cursor position via CRT controller
; ------------------------------------------------------------------------------
vga_update_cursor:
    push rax
    push rcx
    push rdx

    movzx rcx, byte [cursor_row]
    imul rcx, VGA_COLS
    movzx rdx, byte [cursor_col]
    add rcx, rdx                ; RCX = position (0 .. 1999)

    ; Low byte to port 0x3D4/0x3D5
    mov dx, VGA_PORT_INDEX
    mov al, 0x0F
    out dx, al
    inc dx
    mov al, cl
    out dx, al

    ; High byte to port 0x3D4/0x3D5
    dec dx
    mov al, 0x0E
    out dx, al
    inc dx
    mov al, ch
    out dx, al

    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_print_string: Prints null-terminated string at RSI with current attribute
; ------------------------------------------------------------------------------
vga_print_string:
    push rax
    push rsi
.loop:
    lodsb
    test al, al
    jz .done
    call vga_print_char
    jmp .loop
.done:
    pop rsi
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_print_string_color: Prints string at RSI with color specified in BL
; ------------------------------------------------------------------------------
vga_print_string_color:
    push rax
    mov al, [current_attr]
    push rax
    mov [current_attr], bl
    call vga_print_string
    pop rax
    mov [current_attr], al
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_print_hex64: Prints 64-bit value in RAX as 16-digit hexadecimal string
; ------------------------------------------------------------------------------
vga_print_hex64:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    mov rdi, hex64_buffer + 2   ; Skip "0x"
    mov rcx, 16                 ; 16 nibbles (64 bits)
.hex_loop:
    rol rax, 4
    mov rdx, rax
    and rdx, 0x0F
    cmp dl, 9
    jle .digit
    add dl, 'A' - 10
    jmp .store
.digit:
    add dl, '0'
.store:
    mov [rdi], dl
    inc rdi
    loop .hex_loop

    mov byte [rdi], 0
    mov rsi, hex64_buffer
    call vga_print_string

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_print_hex32: Prints 32-bit value in EAX as 8-digit hexadecimal string
; ------------------------------------------------------------------------------
vga_print_hex32:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    mov rdi, hex32_buffer + 2
    mov rcx, 8
.hex_loop:
    rol eax, 4
    mov edx, eax
    and edx, 0x0F
    cmp dl, 9
    jle .digit
    add dl, 'A' - 10
    jmp .store
.digit:
    add dl, '0'
.store:
    mov [rdi], dl
    inc rdi
    loop .hex_loop

    mov byte [rdi], 0
    mov rsi, hex32_buffer
    call vga_print_string

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_print_dec: Prints 64-bit unsigned integer in RAX as decimal
; ------------------------------------------------------------------------------
vga_print_dec:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi

    mov rdi, dec_buffer + 23
    mov byte [rdi], 0
    test rax, rax
    jnz .convert
    dec rdi
    mov byte [rdi], '0'
    jmp .print

.convert:
    mov rcx, 10
.loop:
    xor rdx, rdx
    div rcx                     ; RAX = quotient, RDX = remainder
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .loop

.print:
    mov rsi, rdi
    call vga_print_string

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_print_hex8: Prints 8-bit value in AL as 2 hexadecimal uppercase digits
; ------------------------------------------------------------------------------
vga_print_hex8:
    push rax
    push rbx
    mov bl, al
    shr al, 4
    and al, 0x0F
    call .nibble
    call vga_print_char
    mov al, bl
    and al, 0x0F
    call .nibble
    call vga_print_char
    pop rbx
    pop rax
    ret
.nibble:
    cmp al, 10
    jl .digit
    add al, 'A' - 10
    ret
.digit:
    add al, '0'
    ret

; ------------------------------------------------------------------------------
; vga_print_hex16: Prints 16-bit value in AX as 4 hexadecimal uppercase digits
; ------------------------------------------------------------------------------
vga_print_hex16:
    push rax
    push rbx
    mov bx, ax
    mov al, bh
    call vga_print_hex8
    mov al, bl
    call vga_print_hex8
    pop rbx
    pop rax
    ret

