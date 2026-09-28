; ==============================================================================
; Antigravity OS - 64-bit 2D Graphics Engine Primitives & Bitmap Text Renderer
; 1024x768x32bpp TrueColor Framebuffer Drawing, Gradients, Shapes, and Cursor
; ==============================================================================

[bits 64]

%include "font.asm"

; Standard 32-bit Color Definitions (0x00RRGGBB)
COLOR_DESKTOP_TOP       equ 0x000F172A   ; Deep Obsidian / Slate
COLOR_DESKTOP_BOT       equ 0x00020617   ; Midnight Black
COLOR_TASKBAR_BG        equ 0x001E293B   ; Slate Panel
COLOR_TASKBAR_BORDER    equ 0x00334155   ; Border
COLOR_WIN_TITLE_ACTIVE  equ 0x001E293B   ; Window Title Active
COLOR_WIN_TITLE_ACCENT  equ 0x000284C7   ; Cyan Header Accent
COLOR_WIN_BG            equ 0x000F172A   ; Window Body Interior
COLOR_WIN_BORDER        equ 0x00334155   ; Window Border
COLOR_WIN_SHADOW        equ 0x00050811   ; Window Drop Shadow
COLOR_BTN_CLOSE         equ 0x00EF4444   ; Close Button Red
COLOR_BTN_START         equ 0x000284C7   ; Start Button Cyan
COLOR_TEXT_WHITE        equ 0x00FFFFFF   ; White
COLOR_TEXT_MUTED        equ 0x0094A3B8   ; Muted Light Slate
COLOR_TEXT_CYAN         equ 0x0000F0FF   ; Electric Cyan
COLOR_TEXT_GREEN        equ 0x0010B981   ; Emerald Green
COLOR_TEXT_YELLOW       equ 0x00F59E0B   ; Amber / Gold
COLOR_TERM_BG           equ 0x000A0E17   ; Terminal Dark Background

; Cursor Buffers
CURSOR_W                equ 16
CURSOR_H                equ 18
cursor_saved:           times (CURSOR_W * CURSOR_H) dd 0
cursor_saved_x:         dd -1
cursor_saved_y:         dd -1

; Cursor Shape Bitmap (18 rows of 16-bit masks):
; Bit 1 in mask = Outline (Black 0x00000000)
; Bit 1 in fill = Interior (Electric Cyan 0x0000F0FF / White 0x00FFFFFF)
cursor_mask:
    dw 0b1000000000000000
    dw 0b1100000000000000
    dw 0b1110000000000000
    dw 0b1111000000000000
    dw 0b1111100000000000
    dw 0b1111110000000000
    dw 0b1111111000000000
    dw 0b1111111100000000
    dw 0b1111111110000000
    dw 0b1111111111000000
    dw 0b1111111111100000
    dw 0b1111111111110000
    dw 0b1111111000000000
    dw 0b1101111000000000
    dw 0b1000111100000000
    dw 0b0000111100000000
    dw 0b0000011110000000
    dw 0b0000001100000000

cursor_fill:
    dw 0b0000000000000000
    dw 0b0100000000000000
    dw 0b0110000000000000
    dw 0b0111000000000000
    dw 0b0111100000000000
    dw 0b0111110000000000
    dw 0b0111111000000000
    dw 0b0111111100000000
    dw 0b0111111110000000
    dw 0b0111111111000000
    dw 0b0111110000000000
    dw 0b0110110000000000
    dw 0b0100011000000000
    dw 0b0000011000000000
    dw 0b0000001100000000
    dw 0b0000001100000000
    dw 0b0000000110000000
    dw 0b0000000000000000

; ------------------------------------------------------------------------------
; gfx_putpixel: Draws a single 32-bit pixel at (X, Y)
; Input: ECX = X, EDX = Y, EAX = Color (0x00RRGGBB)
; ------------------------------------------------------------------------------
gfx_putpixel:
    cmp ecx, GUI_SCREEN_WIDTH
    jae .done
    cmp edx, GUI_SCREEN_HEIGHT
    jae .done

    push rdi
    mov rdi, [bga_lfb_ptr]
    imul edx, GUI_SCREEN_WIDTH
    add edx, ecx
    shl edx, 2                  ; * 4 bytes per pixel
    mov [rdi + rdx], eax
    pop rdi
.done:
    ret

; ------------------------------------------------------------------------------
; gfx_getpixel: Reads a single 32-bit pixel from (X, Y)
; Input: ECX = X, EDX = Y
; Output: EAX = Color
; ------------------------------------------------------------------------------
gfx_getpixel:
    cmp ecx, GUI_SCREEN_WIDTH
    jae .black
    cmp edx, GUI_SCREEN_HEIGHT
    jae .black

    push rdi
    mov rdi, [bga_lfb_ptr]
    imul edx, GUI_SCREEN_WIDTH
    add edx, ecx
    shl edx, 2
    mov eax, [rdi + rdx]
    pop rdi
    ret
.black:
    xor eax, eax
    ret

; ------------------------------------------------------------------------------
; gfx_clear_screen: Fills entire 1024x768 framebuffer with a single color
; Input: EAX = Color (0x00RRGGBB)
; ------------------------------------------------------------------------------
gfx_clear_screen:
    push rcx
    push rdi
    mov rdi, [bga_lfb_ptr]
    mov ecx, (GUI_SCREEN_WIDTH * GUI_SCREEN_HEIGHT)
    rep stosd
    pop rdi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; gfx_fill_rect: Draws a solid filled rectangle
; Input:
;   ECX = X, EDX = Y, ESI = Width, R8D = Height, EAX = Color
; ------------------------------------------------------------------------------
gfx_fill_rect:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13

    ; Bounds validation
    cmp ecx, GUI_SCREEN_WIDTH
    jae .exit
    cmp edx, GUI_SCREEN_HEIGHT
    jae .exit
    test esi, esi
    jz .exit
    cmp esi, GUI_SCREEN_WIDTH
    ja .exit
    test r8d, r8d
    jz .exit
    cmp r8d, GUI_SCREEN_HEIGHT
    ja .exit

    ; Clip Width
    mov ebx, ecx
    add ebx, esi
    cmp ebx, GUI_SCREEN_WIDTH
    jbe .w_ok
    mov esi, GUI_SCREEN_WIDTH
    sub esi, ecx
.w_ok:

    ; Clip Height
    mov ebx, edx
    add ebx, r8d
    cmp ebx, GUI_SCREEN_HEIGHT
    jbe .h_ok
    mov r8d, GUI_SCREEN_HEIGHT
    sub r8d, edx
.h_ok:

    mov r9d, ecx                ; R9D = X
    mov r10d, edx               ; R10D = Y
    mov r11d, esi               ; R11D = Width
    mov r12d, r8d               ; R12D = Remaining Height
    mov r13d, eax               ; R13D = Color

.row_loop:
    ; Calculate row starting address: lfb + (y * 1024 + x) * 4
    mov rdi, [bga_lfb_ptr]
    mov eax, r10d
    imul eax, GUI_SCREEN_WIDTH
    add eax, r9d
    shl rax, 2
    add rdi, rax

    mov eax, r13d
    mov ecx, r11d
    rep stosd

    inc r10d                    ; Y++
    dec r12d
    jnz .row_loop

.exit:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; gfx_draw_rect: Draws a 1-pixel rectangle outline
; Input:
;   ECX = X, EDX = Y, ESI = Width, R8D = Height, EAX = Color
; ------------------------------------------------------------------------------
gfx_draw_rect:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8

    mov ebx, eax                ; EBX = color

    ; Top horizontal line (y, w)
    push rcx
    push rdx
    push rsi
    push r8
    mov r8d, 1
    mov eax, ebx
    call gfx_fill_rect
    pop r8
    pop rsi
    pop rdx
    pop rcx

    ; Bottom horizontal line (y + h - 1, w)
    push rcx
    push rdx
    push rsi
    push r8
    add edx, r8d
    dec edx
    mov r8d, 1
    mov eax, ebx
    call gfx_fill_rect
    pop r8
    pop rsi
    pop rdx
    pop rcx

    ; Left vertical line (x, h)
    push rcx
    push rdx
    push rsi
    push r8
    mov esi, 1
    mov eax, ebx
    call gfx_fill_rect
    pop r8
    pop rsi
    pop rdx
    pop rcx

    ; Right vertical line (x + w - 1, h)
    push rcx
    push rdx
    push rsi
    push r8
    add ecx, esi
    dec ecx
    mov esi, 1
    mov eax, ebx
    call gfx_fill_rect
    pop r8
    pop rsi
    pop rdx
    pop rcx

    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

grad_x:  dd 0
grad_y:  dd 0
grad_w:  dd 0
grad_h:  dd 0
grad_c1: dd 0
grad_c2: dd 0

; ------------------------------------------------------------------------------
; gfx_draw_gradient_v: Fills rectangle with smooth vertical gradient
; Input:
;   ECX = X, EDX = Y, ESI = Width, R8D = Height
;   R9D = Top Color (0x00RRGGBB), R10D = Bottom Color (0x00RRGGBB)
; ------------------------------------------------------------------------------
gfx_draw_gradient_v:
    push rax
    push rbx
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

    test r8d, r8d
    jz .done
    test esi, esi
    jz .done

    mov [grad_x], ecx
    mov [grad_y], edx
    mov [grad_w], esi
    mov [grad_h], r8d
    mov [grad_c1], r9d
    mov [grad_c2], r10d

    mov r11d, r8d               ; R11D = Height (total steps)
    xor r12d, r12d              ; R12D = Step (0 .. Height - 1)

.grad_loop:
    ; Top Color Components:
    mov eax, [grad_c1]
    movzx r13d, al              ; Top B
    shr eax, 8
    movzx r14d, al              ; Top G
    shr eax, 8
    movzx r15d, al              ; Top R

    ; Bot Color Components:
    mov eax, [grad_c2]
    movzx edx, al               ; Bot B
    shr eax, 8
    movzx ebx, al               ; Bot G
    shr eax, 8
    movzx ecx, al               ; Bot R

    ; Interpolate Red: Top R + (Bot R - Top R) * step / height
    sub ecx, r15d
    imul ecx, r12d
    mov eax, ecx
    cdq
    idiv r11d
    add eax, r15d
    and eax, 0xFF
    shl eax, 16
    push rax                    ; Save Red on stack

    ; Interpolate Green: Top G + (Bot G - Top G) * step / height
    sub ebx, r14d
    imul ebx, r12d
    mov eax, ebx
    cdq
    idiv r11d
    add eax, r14d
    and eax, 0xFF
    shl eax, 8
    push rax                    ; Save Green on stack

    ; Interpolate Blue: Top B + (Bot B - Top B) * step / height
    ; Need Bot B:
    mov eax, [grad_c2]
    and eax, 0xFF               ; Bot B
    sub eax, r13d
    imul eax, r12d
    cdq
    idiv r11d
    add eax, r13d
    and eax, 0xFF               ; EAX = Blue

    ; Combine R, G, B
    pop rbx                     ; Green
    or eax, ebx
    pop rbx                     ; Red
    or eax, ebx                 ; EAX = 0x00RRGGBB

    ; Write scanline to Framebuffer
    mov rdi, [bga_lfb_ptr]
    mov edx, [grad_y]
    add edx, r12d               ; Y + step
    imul edx, GUI_SCREEN_WIDTH
    add edx, [grad_x]
    shl rdx, 2
    add rdi, rdx

    mov ecx, [grad_w]
    rep stosd

    inc r12d
    cmp r12d, r11d
    jl .grad_loop

.done:
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
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gfx_draw_char: Renders a single 8x8 bitmap character at (X, Y)
; Input:
;   ECX = X, EDX = Y, AL = ASCII Char, ESI = FG Color, R8D = BG Color (-1 = transp)
; ------------------------------------------------------------------------------
gfx_draw_char:
    push rax
    push rbx
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

    ; Clamp character to printable range [32 .. 126]
    cmp al, 32
    jae .chk_max
    mov al, 32
.chk_max:
    cmp al, 126
    jbe .char_ok
    mov al, '?'
.char_ok:
    sub al, 32                  ; 0-based glyph index
    movzx eax, al
    shl eax, 3                  ; Index * 8 bytes per glyph
    lea rbx, [font_8x8_data]
    add rbx, rax                ; RBX = Pointer to 8 bytes of glyph data

    mov r9d, ecx                ; R9D = Base X
    mov r10d, edx               ; R10D = Base Y
    mov r11d, esi               ; R11D = FG Color
    mov r12d, r8d               ; R12D = BG Color

    xor r13d, r13d              ; R13D = row (0 .. 7)
.row_loop:
    movzx r14d, byte [rbx + r13] ; R14D = 8-bit glyph row pattern

    xor r15d, r15d              ; R15D = col (0 .. 7)
.col_loop:
    ; Bit 7 is leftmost pixel (col 0), Bit 0 is rightmost pixel (col 7)
    ; Test bit (7 - col)
    mov ecx, 7
    sub ecx, r15d
    bt r14d, ecx
    jc .draw_fg

    ; Background pixel
    cmp r12d, -1                ; Transparent?
    je .next_col
    mov ecx, r9d
    add ecx, r15d               ; X = Base X + col
    mov edx, r10d
    add edx, r13d               ; Y = Base Y + row
    mov eax, r12d               ; Color = BG Color
    call gfx_putpixel
    jmp .next_col

.draw_fg:
    mov ecx, r9d
    add ecx, r15d               ; X = Base X + col
    mov edx, r10d
    add edx, r13d               ; Y = Base Y + row
    mov eax, r11d               ; Color = FG Color
    call gfx_putpixel

.next_col:
    inc r15d
    cmp r15d, 8
    jl .col_loop

    inc r13d
    cmp r13d, 8
    jl .row_loop

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
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gfx_print_string: Draws null-terminated text string at (X, Y)
; Input:
;   ECX = X, EDX = Y, RSI = Pointer to string, EAX = FG Color, EBX = BG Color
; ------------------------------------------------------------------------------
gfx_print_string:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r11
    push r12
    push r13
    push r14
    push r15

    mov r11, rsi                ; R11 = String Pointer
    mov r12d, ecx               ; Initial X
    mov r13d, ecx               ; Margin X
    mov r14d, edx               ; Y
    mov r15d, eax               ; FG Color
    mov edi, ebx                ; BG Color

.loop:
    mov al, [r11]
    inc r11
    test al, al
    jz .done

    cmp al, 0x0A                ; Line feed '\n'
    je .newline
    cmp al, 0x0D                ; Carriage return '\r'
    je .loop

    ; Draw character
    mov ecx, r12d
    mov edx, r14d
    mov esi, r15d
    mov r8d, edi
    call gfx_draw_char

    add r12d, 8                 ; Advance 8 pixels
    jmp .loop

.newline:
    mov r12d, r13d              ; Reset to left margin
    add r14d, 10                ; Advance line (8 px font + 2 px padding)
    jmp .loop

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gfx_draw_cursor: Draws the 16x18 arrow pointer at (X, Y) with background save
; Input: ECX = X, EDX = Y
; ------------------------------------------------------------------------------
gfx_draw_cursor:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10

    mov [cursor_saved_x], ecx
    mov [cursor_saved_y], edx

    ; 1. Save background pixels into cursor_saved buffer
    lea rsi, [cursor_saved]
    xor r8d, r8d                ; Row 0 .. 17
.save_row:
    xor r9d, r9d                ; Col 0 .. 15
.save_col:
    mov ecx, [cursor_saved_x]
    add ecx, r9d
    mov edx, [cursor_saved_y]
    add edx, r8d
    call gfx_getpixel
    mov [rsi], eax
    add rsi, 4

    inc r9d
    cmp r9d, CURSOR_W
    jl .save_col

    inc r8d
    cmp r8d, CURSOR_H
    jl .save_row

    ; 2. Render Cursor Pixels
    xor r8d, r8d                ; Row 0 .. 17
.draw_row:
    movzx ebx, word [cursor_mask + r8 * 2]
    movzx r10d, word [cursor_fill + r8 * 2]
    xor r9d, r9d                ; Col 0 .. 15

.draw_col:
    mov cl, 15
    sub cl, r9b                 ; Bit index (15 - col)

    ; Test mask bit (Black outline)
    bt ebx, ecx
    jnc .next_cursor_px

    ; Test fill bit (Electric Cyan / White core)
    bt r10d, ecx
    jc .draw_fill

    ; Draw Black Outline
    mov ecx, [cursor_saved_x]
    add ecx, r9d
    mov edx, [cursor_saved_y]
    add edx, r8d
    mov eax, 0x00000000         ; Black
    call gfx_putpixel
    jmp .next_cursor_px

.draw_fill:
    mov ecx, [cursor_saved_x]
    add ecx, r9d
    mov edx, [cursor_saved_y]
    add edx, r8d
    mov eax, 0x0000F0FF         ; Electric Cyan Core
    call gfx_putpixel

.next_cursor_px:
    inc r9d
    cmp r9d, CURSOR_W
    jl .draw_col

    inc r8d
    cmp r8d, CURSOR_H
    jl .draw_row

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
; gfx_restore_cursor: Restores saved pixels under cursor to prevent ghosting
; ------------------------------------------------------------------------------
gfx_restore_cursor:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    mov eax, [cursor_saved_x]
    cmp eax, -1
    je .done                    ; Never drawn

    lea rsi, [cursor_saved]
    xor r8d, r8d                ; Row 0 .. 17
.rest_row:
    xor r9d, r9d                ; Col 0 .. 15
.rest_col:
    mov ecx, [cursor_saved_x]
    add ecx, r9d
    mov edx, [cursor_saved_y]
    add edx, r8d
    mov eax, [rsi]
    call gfx_putpixel
    add rsi, 4

    inc r9d
    cmp r9d, CURSOR_W
    jl .rest_col

    inc r8d
    cmp r8d, CURSOR_H
    jl .rest_row

    mov dword [cursor_saved_x], -1
    mov dword [cursor_saved_y], -1

.done:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
