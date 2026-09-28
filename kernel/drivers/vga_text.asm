; ==============================================================================
; Antigravity OS - VGA 80x25 Color Text Mode Driver
; ------------------------------------------------------------------------------
; Low-level text screen only. Everything else should print through the console
; layer (console/console.asm), which also mirrors output to the serial port and
; redirects it to the GUI terminal while the desktop is running.
; ==============================================================================

[bits 64]

VGA_BUFFER          equ 0x000B8000
VGA_COLS            equ 80
VGA_ROWS            equ 25
VGA_CELLS           equ VGA_COLS * VGA_ROWS
VGA_PORT_INDEX      equ 0x3D4
VGA_PORT_DATA       equ 0x3D5

; Text attribute colours (foreground in the low nibble, background high)
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

section .data
vga_row:            db 0
vga_col:            db 0

section .text
; ------------------------------------------------------------------------------
; vga_init: hide nothing, just home the cursor
; ------------------------------------------------------------------------------
vga_init:
    mov byte [vga_row], 0
    mov byte [vga_col], 0
    ret

; ------------------------------------------------------------------------------
; vga_clear: clear the screen with attribute BL and home the cursor
; ------------------------------------------------------------------------------
vga_clear:
    push rax
    push rcx
    push rdi
    mov rdi, VGA_BUFFER
    mov ecx, VGA_CELLS
    mov ah, bl
    mov al, ' '
    rep stosw
    mov byte [vga_row], 0
    mov byte [vga_col], 0
    call vga_update_cursor
    pop rdi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_putc: AL = character, BL = attribute. Handles \n, \r and \b.
; ------------------------------------------------------------------------------
vga_putc:
    push rax
    push rcx
    push rdi

    cmp al, 0x0A
    je .newline
    cmp al, 0x0D
    je .cr
    cmp al, 0x08
    je .backspace

    call .cell_ptr
    mov ah, bl
    mov [rdi], ax
    inc byte [vga_col]
    cmp byte [vga_col], VGA_COLS
    jb .done
.newline:
    mov byte [vga_col], 0
    inc byte [vga_row]
    cmp byte [vga_row], VGA_ROWS
    jb .done
    call vga_scroll
    jmp .done
.cr:
    mov byte [vga_col], 0
    jmp .done
.backspace:
    cmp byte [vga_col], 0
    je .done
    dec byte [vga_col]
    call .cell_ptr
    mov al, ' '
    mov ah, bl
    mov [rdi], ax
.done:
    call vga_update_cursor
    pop rdi
    pop rcx
    pop rax
    ret

.cell_ptr:                          ; RDI = &cell[row][col]
    movzx ecx, byte [vga_row]
    imul ecx, VGA_COLS
    movzx edi, byte [vga_col]
    add ecx, edi
    lea rdi, [VGA_BUFFER + rcx * 2]
    ret

; ------------------------------------------------------------------------------
; vga_scroll: move every row up by one and blank the last row (attribute BL)
; ------------------------------------------------------------------------------
vga_scroll:
    push rax
    push rcx
    push rsi
    push rdi
    mov rdi, VGA_BUFFER
    mov rsi, VGA_BUFFER + VGA_COLS * 2
    mov ecx, (VGA_ROWS - 1) * VGA_COLS
    rep movsw
    mov ecx, VGA_COLS
    mov ah, bl
    mov al, ' '
    rep stosw
    mov byte [vga_row], VGA_ROWS - 1
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_update_cursor: move the blinking hardware cursor to (vga_row, vga_col)
; ------------------------------------------------------------------------------
vga_update_cursor:
    push rax
    push rcx
    push rdx
    movzx ecx, byte [vga_row]
    imul ecx, VGA_COLS
    movzx eax, byte [vga_col]
    add ecx, eax
    mov dx, VGA_PORT_INDEX
    mov al, 0x0F
    out dx, al
    inc dx
    mov al, cl
    out dx, al
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
; vga_restore_text_mode: program standard mode 03h registers (80x25 colour
; text) after the BGA framebuffer was used, reload a font into plane 2 and
; clear the screen. Clears bga_active.
; ------------------------------------------------------------------------------
vga_restore_text_mode:
    push rax
    push rbx
    push rcx
    push rdx

    call bga_disable

    mov dx, 0x3C2                   ; Miscellaneous Output
    mov al, 0x67
    out dx, al

    mov dx, 0x3C4                   ; Sequencer 0-4
    xor ecx, ecx
.seq:
    mov al, cl
    mov ah, [vga_m3_seq + rcx]
    out dx, ax
    inc ecx
    cmp ecx, 5
    jb .seq

    mov dx, 0x3D4                   ; unlock CRTC 0-7
    mov al, 0x11
    out dx, al
    inc dx
    in al, dx
    and al, 0x7F
    out dx, al
    dec dx
    xor ecx, ecx
.crtc:
    mov al, cl
    mov ah, [vga_m3_crtc + rcx]
    out dx, ax
    inc ecx
    cmp ecx, 25
    jb .crtc

    mov dx, 0x3CE                   ; Graphics Controller 0-8
    xor ecx, ecx
.gc:
    mov al, cl
    mov ah, [vga_m3_gc + rcx]
    out dx, ax
    inc ecx
    cmp ecx, 9
    jb .gc

    mov dx, 0x3DA                   ; reset the attribute controller flip-flop
    in al, dx
    mov dx, 0x3C0
    xor ecx, ecx
.ac:
    mov al, cl
    out dx, al
    mov al, [vga_m3_ac + rcx]
    out dx, al
    inc ecx
    cmp ecx, 21
    jb .ac
    mov al, 0x20                    ; re-enable video
    out dx, al

    call vga_load_font

    mov bl, 0x07
    call vga_clear

    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_load_font: copy the 8x8 GUI font into VGA plane 2. Text mode uses 16
; scanlines per glyph, so every font row is written twice (8x16 cells).
; ------------------------------------------------------------------------------
vga_load_font:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov dx, 0x3C4
    mov ax, 0x0402                  ; map mask: plane 2
    out dx, ax
    mov ax, 0x0604                  ; sequential addressing
    out dx, ax
    mov dx, 0x3CE
    mov ax, 0x0005                  ; write mode 0
    out dx, ax
    mov ax, 0x0006                  ; map 0xA0000-0xAFFFF
    out dx, ax

    mov rdi, 0xA0000                ; clear all 256 glyph slots (32 bytes each)
    xor eax, eax
    mov ecx, 256 * 32 / 4
    rep stosd

    xor ebx, ebx                    ; glyph index 0 .. FONT_GLYPHS-1 (ASCII 32..)
.glyph:
    lea rsi, [font_8x8_data + rbx * 8]
    lea eax, [ebx + FONT_FIRST_CHAR]
    shl eax, 5
    mov rdi, 0xA0000
    add rdi, rax
    mov ecx, 8
.row:
    lodsb
    mov [rdi], al
    mov [rdi + 1], al
    add rdi, 2
    loop .row
    inc ebx
    cmp ebx, FONT_GLYPHS
    jb .glyph

    mov dx, 0x3C4
    mov ax, 0x0302                  ; planes 0 + 1
    out dx, ax
    mov ax, 0x0204                  ; odd/even
    out dx, ax
    mov dx, 0x3CE
    mov ax, 0x1005                  ; odd/even
    out dx, ax
    mov ax, 0x0E06                  ; map 0xB8000
    out dx, ax

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

section .rodata
vga_m3_seq:
    db 0x03, 0x00, 0x03, 0x00, 0x02
vga_m3_crtc:
    db 0x5F, 0x4F, 0x50, 0x82, 0x55, 0x81, 0xBF, 0x1F
    db 0x00, 0x4F, 0x0D, 0x0E, 0x00, 0x00, 0x00, 0x00
    db 0x9C, 0x8E, 0x8F, 0x28, 0x1F, 0x96, 0xB9, 0xA3, 0xFF
vga_m3_gc:
    db 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0E, 0x00, 0xFF
vga_m3_ac:
    db 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07
    db 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F
    db 0x0C, 0x00, 0x0F, 0x08, 0x00
