; ==============================================================================
; Antigravity OS - 2D Graphics
; ------------------------------------------------------------------------------
; All drawing goes to gfx_target (normally the RAM back buffer at
; GUI_BACKBUFFER_ADDR; the canvas app points it at its own bitmap), which is
; GFX_WIDTH pixels wide, 32-bit 0x00RRGGBB. Every primitive is clipped to the
; current clip rectangle, so callers may pass coordinates that are partly or
; completely off-screen (windows can be dragged past the edges).
;
; gfx_present copies the finished frame to the video card and draws the mouse
; pointer on top of it; gfx_cursor_move moves the pointer without a redraw.
;
; Every routine preserves all registers.
; ==============================================================================

[bits 64]

%include "gfx/font.asm"
%include "gui/theme.inc"

CURSOR_W                equ 12
CURSOR_H                equ 18
GFX_CLIP_STACK          equ 8

section .data
align 8
gfx_target:             dq GUI_BACKBUFFER_ADDR
gfx_clip_x0:            dd 0        ; clip rectangle [x0, x1) x [y0, y1)
gfx_clip_y0:            dd 0
gfx_clip_x1:            dd GFX_WIDTH
gfx_clip_y1:            dd GFX_HEIGHT
gfx_clip_depth:         dd 0
gfx_cursor_x:           dd -1       ; where the pointer is drawn on screen (-1 = hidden)
gfx_cursor_y:           dd -1

section .bss
gfx_clip_stack:         resd GFX_CLIP_STACK * 4

section .rodata
; Mouse pointer: '#' = outline (black), 'o' = fill (cyan), '.' = transparent
gfx_cursor_shape:
    db "#...........", "##..........", "#o#.........", "#oo#........"
    db "#ooo#.......", "#oooo#......", "#ooooo#.....", "#oooooo#...."
    db "#ooooooo#...", "#oooooooo#..", "#ooooo#####.", "#oo#oo#....."
    db "#o#.#oo#....", "##..#oo#....", "#....#oo#...", ".....#oo#...", "......#oo#..", ".......##..."

section .text
; ==============================================================================
; Clipping
; ==============================================================================

; gfx_reset_clip: clip to the whole screen and empty the clip stack
gfx_reset_clip:
    mov dword [gfx_clip_x0], 0
    mov dword [gfx_clip_y0], 0
    mov dword [gfx_clip_x1], GFX_WIDTH
    mov dword [gfx_clip_y1], GFX_HEIGHT
    mov dword [gfx_clip_depth], 0
    ret

; gfx_push_clip: ECX,EDX = x,y  ESI,R8D = w,h. Saves the current clip and
; narrows it to its intersection with the given rectangle.
gfx_push_clip:
    push rax
    push rbx
    push rdi
    mov eax, [gfx_clip_depth]
    cmp eax, GFX_CLIP_STACK
    jae .no_save                    ; too deep: still clip, but can't restore
    lea rdi, [gfx_clip_stack]
    shl eax, 4
    add rdi, rax
    mov eax, [gfx_clip_x0]
    mov [rdi], eax
    mov eax, [gfx_clip_y0]
    mov [rdi + 4], eax
    mov eax, [gfx_clip_x1]
    mov [rdi + 8], eax
    mov eax, [gfx_clip_y1]
    mov [rdi + 12], eax
    inc dword [gfx_clip_depth]
.no_save:
    mov eax, ecx                    ; x0 = max(x0, x)
    cmp eax, [gfx_clip_x0]
    jle .x0
    mov [gfx_clip_x0], eax
.x0:
    mov eax, edx
    cmp eax, [gfx_clip_y0]
    jle .y0
    mov [gfx_clip_y0], eax
.y0:
    lea eax, [ecx + esi]            ; x1 = min(x1, x + w)
    cmp eax, [gfx_clip_x1]
    jge .x1
    mov [gfx_clip_x1], eax
.x1:
    lea eax, [edx + r8d]
    cmp eax, [gfx_clip_y1]
    jge .y1
    mov [gfx_clip_y1], eax
.y1:
    pop rdi
    pop rbx
    pop rax
    ret

; gfx_pop_clip: restore the clip saved by the matching gfx_push_clip
gfx_pop_clip:
    push rax
    push rsi
    mov eax, [gfx_clip_depth]
    test eax, eax
    jz .done
    dec eax
    mov [gfx_clip_depth], eax
    shl eax, 4
    lea rsi, [gfx_clip_stack]
    add rsi, rax
    mov eax, [rsi]
    mov [gfx_clip_x0], eax
    mov eax, [rsi + 4]
    mov [gfx_clip_y0], eax
    mov eax, [rsi + 8]
    mov [gfx_clip_x1], eax
    mov eax, [rsi + 12]
    mov [gfx_clip_y1], eax
.done:
    pop rsi
    pop rax
    ret

; ==============================================================================
; Primitives
; ==============================================================================

; gfx_fill_rect: ECX,EDX = x,y  ESI,R8D = w,h  EAX = colour
gfx_fill_rect:
    push rbx
    push rcx
    push rdx
    push rdi
    push r9
    push r10
    push r11

    mov r9d, ecx                    ; r9 = x0, r10 = x1, edx = y0, r11 = y1
    lea r10d, [ecx + esi]
    lea r11d, [edx + r8d]
    cmp r9d, [gfx_clip_x0]
    jge .cx0
    mov r9d, [gfx_clip_x0]
.cx0:
    cmp r10d, [gfx_clip_x1]
    jle .cx1
    mov r10d, [gfx_clip_x1]
.cx1:
    cmp edx, [gfx_clip_y0]
    jge .cy0
    mov edx, [gfx_clip_y0]
.cy0:
    cmp r11d, [gfx_clip_y1]
    jle .cy1
    mov r11d, [gfx_clip_y1]
.cy1:
    sub r10d, r9d                   ; width
    jle .done
    cmp edx, r11d
    jge .done
    movsxd r9, r9d
.row:
    mov ebx, edx
    imul ebx, GFX_WIDTH
    movsxd rbx, ebx
    add rbx, r9
    mov rdi, [gfx_target]
    lea rdi, [rdi + rbx * 4]
    mov ecx, r10d
    rep stosd
    inc edx
    cmp edx, r11d
    jl .row
.done:
    pop r11
    pop r10
    pop r9
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; gfx_draw_rect: 1-pixel outline. ECX,EDX = x,y  ESI,R8D = w,h  EAX = colour
gfx_draw_rect:
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    mov r9d, esi
    mov r10d, r8d
    mov r8d, 1                      ; top
    call gfx_fill_rect
    add edx, r10d                   ; bottom
    dec edx
    call gfx_fill_rect
    sub edx, r10d
    inc edx
    mov esi, 1                      ; left
    mov r8d, r10d
    call gfx_fill_rect
    add ecx, r9d                    ; right
    dec ecx
    call gfx_fill_rect
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    ret

; gfx_putpixel: ECX,EDX = x,y  EAX = colour
gfx_putpixel:
    cmp ecx, [gfx_clip_x0]
    jl .done
    cmp ecx, [gfx_clip_x1]
    jge .done
    cmp edx, [gfx_clip_y0]
    jl .done
    cmp edx, [gfx_clip_y1]
    jge .done
    push rdi
    push rdx
    imul edx, GFX_WIDTH
    add edx, ecx
    movsxd rdx, edx
    mov rdi, [gfx_target]
    mov [rdi + rdx * 4], eax
    pop rdx
    pop rdi
.done:
    ret

; gfx_draw_char: ECX,EDX = x,y  AL = character  ESI = foreground colour
;                R8D = background colour, or -1 for transparent
gfx_draw_char:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push r9
    push r10
    push r11
    push r12

    movzx eax, al
    sub eax, FONT_FIRST_CHAR
    cmp eax, FONT_GLYPHS
    jb .glyph_ok
    mov eax, '?' - FONT_FIRST_CHAR
.glyph_ok:
    lea rbx, [font_8x8_data]
    lea rbx, [rbx + rax * 8]        ; RBX = glyph rows
    mov r12d, ecx                   ; left x
    xor r9d, r9d                    ; row
.row:
    lea r10d, [edx + r9d]           ; y of this row
    cmp r10d, [gfx_clip_y0]
    jl .next_row
    cmp r10d, [gfx_clip_y1]
    jge .done
    imul r10d, GFX_WIDTH
    movzx r11d, byte [rbx + r9]     ; bit pattern, bit 7 = leftmost pixel
    xor ecx, ecx                    ; column
.col:
    lea eax, [r12d + ecx]
    cmp eax, [gfx_clip_x0]
    jl .next_col
    cmp eax, [gfx_clip_x1]
    jge .next_row
    add eax, r10d
    movsxd rax, eax
    mov rdi, [gfx_target]
    lea rdi, [rdi + rax * 4]
    bt r11d, 7
    jnc .background
    mov [rdi], esi
    jmp .next_col
.background:
    cmp r8d, -1
    je .next_col
    mov [rdi], r8d
.next_col:
    shl r11d, 1
    inc ecx
    cmp ecx, FONT_W
    jb .col
.next_row:
    inc r9d
    cmp r9d, FONT_H
    jb .row
.done:
    pop r12
    pop r11
    pop r10
    pop r9
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gfx_print_string: ECX,EDX = x,y  RSI = string  EAX = foreground
;                   EBX = background or -1. "\n" moves down 10 pixels.
; Output: ECX = x just after the last character (on the last line)
gfx_print_string:
    push rax
    push rdx
    push rsi
    push r8
    push r9
    push r10
    mov r9, rsi
    mov r10d, ecx                   ; left margin
    mov esi, eax
    mov r8d, ebx
.loop:
    mov al, [r9]
    inc r9
    test al, al
    jz .done
    cmp al, 0x0A
    je .newline
    cmp al, 0x0D
    je .loop
    call gfx_draw_char
    add ecx, FONT_W
    jmp .loop
.newline:
    mov ecx, r10d
    add edx, 10
    jmp .loop
.done:
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rax
    ret

; gfx_text_width: RSI = string -> EAX = width in pixels (single line)
gfx_text_width:
    push rsi
    call strlen
    shl eax, 3
    pop rsi
    ret

; gfx_draw_gradient_v: ECX,EDX = x,y  ESI,R8D = w,h
;                      R9D = top colour  R10D = bottom colour
gfx_draw_gradient_v:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r11
    push r12
    push r13
    push r14
    test r8d, r8d
    jle .done
    mov r11d, r8d                   ; total rows
    xor r12d, r12d                  ; row index
    mov r13d, edx                   ; base y
.row:
    ; colour = top + (bottom - top) * row / rows, per channel
    xor ebx, ebx
    mov r14d, 16                    ; channel shift: 16 (R), 8 (G), 0 (B)
.channel:
    mov ecx, r14d
    mov eax, r9d
    shr eax, cl
    and eax, 0xFF
    mov edi, r10d
    shr edi, cl
    and edi, 0xFF
    sub edi, eax
    imul edi, r12d
    push rax
    mov eax, edi
    cdq
    idiv r11d
    mov edi, eax
    pop rax
    add eax, edi
    and eax, 0xFF
    shl eax, cl
    or ebx, eax
    sub r14d, 8
    jge .channel
    mov eax, ebx
    mov ecx, [rsp + 7 * 8]          ; original ECX (x)
    lea edx, [r13d + r12d]
    push r8
    mov r8d, 1
    call gfx_fill_rect
    pop r8
    inc r12d
    cmp r12d, r11d
    jb .row
.done:
    pop r14
    pop r13
    pop r12
    pop r11
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gfx_blit: copy a rectangle out of a 32-bpp bitmap that is GFX_WIDTH pixels
; wide (same pitch as the screen), clipped to the current clip rectangle.
;   RSI = source bitmap        R9D,R10D = source x,y
;   ECX,EDX = destination x,y  R11D,R8D = width,height
gfx_blit:
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
    ; clip left/top: shift the source by the same amount
    mov eax, [gfx_clip_x0]
    sub eax, ecx
    jle .left_ok
    add r9d, eax
    add ecx, eax
    sub r11d, eax
.left_ok:
    mov eax, [gfx_clip_y0]
    sub eax, edx
    jle .top_ok
    add r10d, eax
    add edx, eax
    sub r8d, eax
.top_ok:
    lea eax, [ecx + r11d]           ; clip right/bottom
    sub eax, [gfx_clip_x1]
    jle .right_ok
    sub r11d, eax
.right_ok:
    lea eax, [edx + r8d]
    sub eax, [gfx_clip_y1]
    jle .bottom_ok
    sub r8d, eax
.bottom_ok:
    test r11d, r11d
    jle .done
    test r8d, r8d
    jle .done
    mov r12, rsi
.row:
    mov eax, r10d                   ; source row pointer
    imul eax, GFX_WIDTH
    add eax, r9d
    lea rsi, [r12 + rax * 4]
    mov eax, edx                    ; destination row pointer
    imul eax, GFX_WIDTH
    add eax, ecx
    movsxd rax, eax
    mov rdi, [gfx_target]
    lea rdi, [rdi + rax * 4]
    push rcx
    mov ecx, r11d
    rep movsd
    pop rcx
    inc r10d
    inc edx
    dec r8d
    jnz .row
.done:
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

; gfx_copy_frame: RSI = full-screen source frame -> gfx_target
gfx_copy_frame:
    push rcx
    push rsi
    push rdi
    mov rdi, [gfx_target]
    mov ecx, GFX_FRAME_BYTES / 8
    rep movsq
    pop rdi
    pop rsi
    pop rcx
    ret

; ==============================================================================
; Screen output and the mouse pointer
; ==============================================================================

; gfx_present: copy the back buffer to the framebuffer, then draw the pointer
; at (ECX, EDX)
gfx_present:
    push rcx
    push rsi
    push rdi
    mov rsi, GUI_BACKBUFFER_ADDR
    mov rdi, [bga_lfb]
    push rcx
    mov ecx, GFX_FRAME_BYTES / 8
    rep movsq
    pop rcx
    mov dword [gfx_cursor_x], -1    ; the copy erased the old pointer
    pop rdi
    pop rsi
    pop rcx
    jmp gfx_cursor_draw

; gfx_cursor_move: move the pointer to (ECX, EDX) without redrawing the frame
gfx_cursor_move:
    call gfx_cursor_erase
    jmp gfx_cursor_draw

; gfx_cursor_erase: restore the framebuffer pixels under the pointer from the
; back buffer
gfx_cursor_erase:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov ebx, [gfx_cursor_x]
    cmp ebx, -1
    je .done
    xor edx, edx                    ; row
.row:
    mov eax, [gfx_cursor_y]
    add eax, edx
    cmp eax, GFX_HEIGHT
    jae .done
    imul eax, GFX_WIDTH
    add eax, ebx
    mov rsi, GUI_BACKBUFFER_ADDR
    lea rsi, [rsi + rax * 4]
    mov rdi, [bga_lfb]
    lea rdi, [rdi + rax * 4]
    mov ecx, GFX_WIDTH
    sub ecx, ebx                    ; don't run past the right edge
    cmp ecx, CURSOR_W
    jbe .count_ok
    mov ecx, CURSOR_W
.count_ok:
    rep movsd
    inc edx
    cmp edx, CURSOR_H
    jb .row
.done:
    mov dword [gfx_cursor_x], -1
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gfx_cursor_draw: draw the pointer directly on the framebuffer at (ECX, EDX)
gfx_cursor_draw:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov [gfx_cursor_x], ecx
    mov [gfx_cursor_y], edx
    lea rsi, [gfx_cursor_shape]
    xor r8d, r8d                    ; row
.row:
    lea eax, [edx + r8d]
    cmp eax, GFX_HEIGHT
    jae .done
    imul eax, GFX_WIDTH
    xor r9d, r9d                    ; column
.col:
    lea ebx, [ecx + r9d]
    cmp ebx, GFX_WIDTH
    jae .next_row
    mov bl, [rsi]
    cmp bl, '.'
    je .next_col
    mov edi, 0x00000000
    cmp bl, '#'
    je .plot
    mov edi, THEME_CYAN
.plot:
    push rax
    add eax, ecx
    add eax, r9d
    push rdx
    mov rdx, [bga_lfb]
    mov [rdx + rax * 4], edi
    pop rdx
    pop rax
.next_col:
    inc rsi
    inc r9d
    cmp r9d, CURSOR_W
    jb .col
    jmp .row_done
.next_row:
    ; skip the rest of this shape row
    mov ebx, CURSOR_W
    sub ebx, r9d
    add rsi, rbx
.row_done:
    inc r8d
    cmp r8d, CURSOR_H
    jb .row
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
