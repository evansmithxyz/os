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
CURSOR_H                equ 19
GFX_CLIP_STACK          equ 8
GFX_LINE_H              equ 18      ; line step of multi-line text
GFX_RADIUS_MAX          equ 16      ; largest rounded-corner radius
GFX_SHADOW_MAX          equ 32      ; widest shadow blur

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
gfx_bold:               resb 1      ; 1 while gfx_print_ui draws bold
gfx_cov_ready:          resb GFX_RADIUS_MAX + 1
gfx_cov_table:          resb (GFX_RADIUS_MAX + 1) * 256     ; 16x16 bytes per radius
alignb 4
gfx_corner_save:        resd 4 * GFX_RADIUS_MAX * GFX_RADIUS_MAX
gfx_sh_x:               resd 1      ; gfx_shadow: the box...
gfx_sh_y:               resd 1
gfx_sh_x1:              resd 1
gfx_sh_y1:              resd 1
gfx_sh_r:               resd 1
gfx_sh_ix0:             resd 1      ; ...and the shadow's inner rectangle
gfx_sh_iy0:             resd 1
gfx_sh_ix1:             resd 1
gfx_sh_iy1:             resd 1
gfx_sh_q:               resd 1      ; 4 x blur
alignb 8
gfx_sh_cov:             resq 1      ; coverage table of the box's corners
gfx_sh_alpha:           resd 4 * GFX_SHADOW_MAX + 1

section .rodata
; Mouse pointer: '#' = outline, 'o' = fill, '.' = transparent
gfx_cursor_shape:
    db "#...........", "##..........", "#o#.........", "#oo#........"
    db "#ooo#.......", "#oooo#......", "#ooooo#.....", "#oooooo#...."
    db "#ooooooo#...", "#oooooooo#..", "#ooooooooo#.", "#oooooo#####"
    db "#ooo#oo#....", "#oo##oo#....", "#o#..#oo#...", "##...#oo#..."
    db "#.....#oo#..", "......#oo#..", ".......##..."

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
    shl eax, 4
    lea rbx, [font_data]
    add rbx, rax                    ; RBX = glyph rows (16 bytes)
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

; gfx_print_string: monospace text. ECX,EDX = x,y  RSI = string
;                   EAX = foreground  EBX = background or -1.
;                   "\n" moves down GFX_LINE_H pixels.
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
    add edx, GFX_LINE_H
    jmp .loop
.done:
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rax
    ret

; gfx_text_width: RSI = string -> EAX = monospace width in pixels (one line)
gfx_text_width:
    push rsi
    call strlen
    shl eax, 3
    pop rsi
    ret

; ==============================================================================
; Proportional UI text: each glyph takes its inked columns plus one pixel
; (font_prop), a space 4. Bold draws every glyph twice, one pixel apart.
; ==============================================================================

; gfx_print_ui: ECX,EDX = x,y  RSI = string  EAX = colour (transparent
; background). Output: ECX = x after the last character.
gfx_print_ui:
    push rax
    push rbx
    push rsi
    push r8
    push r9
    push r10
    push r11
    mov r9, rsi
    mov esi, eax                    ; gfx_draw_char: ESI = colour
    mov r8d, -1
    lea r10, [font_prop]
.loop:
    movzx eax, byte [r9]
    inc r9
    test eax, eax
    jz .done
    lea ebx, [eax - FONT_FIRST_CHAR]
    cmp ebx, FONT_GLYPHS
    jb .known
    mov eax, '?'
    mov ebx, '?' - FONT_FIRST_CHAR
.known:
    movzx r11d, byte [r10 + rbx * 2]        ; first inked column
    movzx ebx, byte [r10 + rbx * 2 + 1]     ; advance
    sub ecx, r11d
    call gfx_draw_char
    cmp byte [gfx_bold], 0
    je .advance
    inc ecx                         ; (and the advance grows by that pixel)
    call gfx_draw_char
.advance:
    add ecx, r11d
    add ecx, ebx
    jmp .loop
.done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rbx
    pop rax
    ret

; gfx_print_ui_bold: gfx_print_ui in bold
gfx_print_ui_bold:
    mov byte [gfx_bold], 1
    call gfx_print_ui
    mov byte [gfx_bold], 0
    ret

; gfx_ui_width: RSI = string -> EAX = its gfx_print_ui width in pixels
gfx_ui_width:
    push rbx
    push rsi
    push r10
    xor eax, eax
    lea r10, [font_prop]
.loop:
    movzx ebx, byte [rsi]
    inc rsi
    test ebx, ebx
    jz .done
    sub ebx, FONT_FIRST_CHAR
    cmp ebx, FONT_GLYPHS
    jb .known
    mov ebx, '?' - FONT_FIRST_CHAR
.known:
    movzx ebx, byte [r10 + rbx * 2 + 1]
    add eax, ebx
    cmp byte [gfx_bold], 0
    je .loop
    inc eax
    jmp .loop
.done:
    pop r10
    pop rsi
    pop rbx
    ret

; gfx_ui_width_bold: RSI = string -> EAX = its gfx_print_ui_bold width
gfx_ui_width_bold:
    mov byte [gfx_bold], 1
    call gfx_ui_width
    mov byte [gfx_bold], 0
    ret

; gfx_print_ui_centered: ECX = x of the centre, EDX = y, RSI = string,
; EAX = colour. Output: ECX = x after the last character.
gfx_print_ui_centered:
    push rax
    call gfx_ui_width
    shr eax, 1
    sub ecx, eax
    pop rax
    jmp gfx_print_ui

; ==============================================================================
; Alpha blending. Alpha runs 0 (keep the destination) to 256 (the colour).
; ==============================================================================

; gfx_mix: EAX = colour, EBX = destination pixel, EDI = alpha -> EBX = blend
gfx_mix:
    push rax
    push rcx
    push rdx
    push r8
    push r9
    mov r8d, edi
    mov r9d, 256
    sub r9d, r8d
    mov ecx, eax                    ; red and blue together...
    and ecx, 0x00FF00FF
    imul rcx, r8
    mov edx, ebx
    and edx, 0x00FF00FF
    imul rdx, r9
    add rcx, rdx
    shr rcx, 8
    and ecx, 0x00FF00FF
    and eax, 0x0000FF00             ; ...then green
    imul rax, r8
    and ebx, 0x0000FF00
    imul rbx, r9
    add rax, rbx
    shr rax, 8
    and eax, 0x0000FF00
    or eax, ecx
    mov ebx, eax
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret

; gfx_blend_pixel: ECX,EDX = x,y  EAX = colour  EDI = alpha (clipped)
gfx_blend_pixel:
    cmp ecx, [gfx_clip_x0]
    jl .done
    cmp ecx, [gfx_clip_x1]
    jge .done
    cmp edx, [gfx_clip_y0]
    jl .done
    cmp edx, [gfx_clip_y1]
    jge .done
    push rbx
    push rdx
    push rsi
    imul edx, GFX_WIDTH
    add edx, ecx
    movsxd rdx, edx
    mov rsi, [gfx_target]
    lea rsi, [rsi + rdx * 4]
    mov ebx, [rsi]
    call gfx_mix
    mov [rsi], ebx
    pop rsi
    pop rdx
    pop rbx
.done:
    ret

; gfx_blend_rect: ECX,EDX = x,y  ESI,R8D = w,h  EAX = colour  EDI = alpha
gfx_blend_rect:
    cmp edi, 256
    jae gfx_fill_rect
    test edi, edi
    jle .ret
    push rbx
    push rcx
    push rdx
    push rsi
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
.row:
    mov esi, edx
    imul esi, GFX_WIDTH
    add esi, r9d
    movsxd rsi, esi
    shl rsi, 2
    add rsi, [gfx_target]
    mov ecx, r10d
.pixel:
    mov ebx, [rsi]
    call gfx_mix
    mov [rsi], ebx
    add rsi, 4
    dec ecx
    jnz .pixel
    inc edx
    cmp edx, r11d
    jl .row
.done:
    pop r11
    pop r10
    pop r9
    pop rsi
    pop rdx
    pop rcx
    pop rbx
.ret:
    ret

; ==============================================================================
; Rounded rectangles. Corners are anti-aliased with a coverage table per
; radius: 4x4 samples per pixel, computed the first time a radius is used.
; ==============================================================================

; gfx_cov_get: R9D = radius (1..GFX_RADIUS_MAX) -> RSI = its table. Byte
; [j * 16 + i] = samples (0-16) of corner pixel (i, j) inside the arc; i and
; j count from the corner's outer edges.
gfx_cov_get:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r10
    push r11
    push r12
    mov eax, r9d
    shl eax, 8
    lea rsi, [gfx_cov_table]
    add rsi, rax
    mov eax, r9d
    lea rcx, [gfx_cov_ready]
    cmp byte [rcx + rax], 0
    jne .done
    mov byte [rcx + rax], 1
    lea r8d, [r9d * 8]              ; R = radius in 1/8 pixels
    mov r10d, r8d
    imul r10d, r10d                 ; R^2
    xor edx, edx                    ; j
.row:
    xor r11d, r11d                  ; i
.pixel:
    xor r12d, r12d                  ; samples inside
    xor ebx, ebx                    ; sample row b
.sample_row:
    lea eax, [edx * 8 + 1]          ; Y = R - (8j + 2b + 1)
    lea eax, [eax + ebx * 2]
    mov ecx, r8d
    sub ecx, eax
    imul ecx, ecx                   ; ECX = Y^2
    xor edi, edi                    ; sample column a
.sample:
    lea eax, [r11d * 8 + 1]         ; X = R - (8i + 2a + 1)
    lea eax, [eax + edi * 2]
    neg eax
    add eax, r8d
    imul eax, eax
    add eax, ecx
    cmp eax, r10d
    ja .outside
    inc r12d
.outside:
    inc edi
    cmp edi, 4
    jb .sample
    inc ebx
    cmp ebx, 4
    jb .sample_row
    mov eax, edx
    shl eax, 4
    add eax, r11d
    mov [rsi + rax], r12b
    inc r11d
    cmp r11d, r9d
    jb .pixel
    inc edx
    cmp edx, r9d
    jb .row
.done:
    pop r12
    pop r11
    pop r10
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gfx_clamp_radius: ESI,R8D = w,h, R9D = radius -> R9D limited to half the
; smaller side and to GFX_RADIUS_MAX (0 = square corners)
gfx_clamp_radius:
    push rax
    cmp r9d, GFX_RADIUS_MAX
    jle .max_ok
    mov r9d, GFX_RADIUS_MAX
.max_ok:
    mov eax, esi
    shr eax, 1
    cmp r9d, eax
    jle .w_ok
    mov r9d, eax
.w_ok:
    mov eax, r8d
    shr eax, 1
    cmp r9d, eax
    jle .h_ok
    mov r9d, eax
.h_ok:
    test r9d, r9d
    jns .done
    xor r9d, r9d
.done:
    pop rax
    ret

; gfx_corner_point: R12D-R15D = box x,y,w,h, AL = corner (bit 0 = right,
; bit 1 = bottom), R11D,EBX = i,j from the corner's outer edges
; -> ECX,EDX = that pixel
gfx_corner_point:
    lea ecx, [r12d + r11d]
    test al, 1
    jz .x_done
    lea ecx, [r12d + r14d - 1]
    sub ecx, r11d
.x_done:
    lea edx, [r13d + ebx]
    test al, 2
    jz .y_done
    lea edx, [r13d + r15d - 1]
    sub edx, ebx
.y_done:
    ret

; gfx_fill_round_rect: ECX,EDX = x,y  ESI,R8D = w,h  EAX = colour
;                      R9D = corner radius
gfx_fill_round_rect:
    push rdi
    mov edi, 256
    call gfx_blend_round_rect
    pop rdi
    ret

; gfx_blend_round_rect: gfx_fill_round_rect with EDI = alpha
gfx_blend_round_rect:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    call gfx_clamp_radius
    test r9d, r9d
    jnz .rounded
    call gfx_blend_rect
    jmp .done
.rounded:
    mov r12d, ecx
    mov r13d, edx
    mov r14d, esi
    mov r15d, r8d
    mov ebp, edi                    ; EBP = alpha
    lea edx, [r13d + r9d]           ; middle band (full width)
    sub r8d, r9d
    sub r8d, r9d
    call gfx_blend_rect
    lea ecx, [r12d + r9d]           ; top and bottom bands between the corners
    mov edx, r13d
    sub esi, r9d
    sub esi, r9d
    mov r8d, r9d
    call gfx_blend_rect
    lea edx, [r13d + r15d]
    sub edx, r9d
    call gfx_blend_rect
    call gfx_cov_get
    mov r10, rsi
    xor ebx, ebx                    ; j
.row:
    xor r11d, r11d                  ; i
.pixel:
    mov edi, ebx
    shl edi, 4
    add edi, r11d
    movzx edi, byte [r10 + rdi]     ; samples
    test edi, edi
    jz .next
    imul edi, ebp                   ; alpha = samples / 16 * alpha
    shr edi, 4
    push rax
    xor eax, eax
.corner:
    push rax
    call gfx_corner_point
    mov eax, [rsp + 8]              ; the colour
    call gfx_blend_pixel
    pop rax
    inc eax
    cmp eax, 4
    jb .corner
    pop rax
.next:
    inc r11d
    cmp r11d, r9d
    jb .pixel
    inc ebx
    cmp ebx, r9d
    jb .row
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gfx_stroke_round_rect: 1-pixel anti-aliased outline of a rounded box.
; ECX,EDX = x,y  ESI,R8D = w,h  EAX = colour  R9D = corner radius
gfx_stroke_round_rect:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    call gfx_clamp_radius
    mov r12d, ecx
    mov r13d, edx
    mov r14d, esi
    mov r15d, r8d
    ; straight edges between the corners
    lea ecx, [r12d + r9d]
    sub esi, r9d
    sub esi, r9d
    mov r8d, 1
    call gfx_fill_rect              ; top
    lea edx, [r13d + r15d - 1]
    call gfx_fill_rect              ; bottom
    mov ecx, r12d
    lea edx, [r13d + r9d]
    mov esi, 1
    mov r8d, r15d
    sub r8d, r9d
    sub r8d, r9d
    call gfx_fill_rect              ; left
    lea ecx, [r12d + r14d - 1]
    call gfx_fill_rect              ; right
    cmp r9d, 1
    jbe .square                     ; radius 0/1: the corner pixel is the stroke
    ; corners: coverage of the outline minus coverage of the arc one pixel in
    call gfx_cov_get
    mov r10, rsi                    ; outer arc (radius r)
    push r9
    dec r9d
    call gfx_cov_get
    mov rbp, rsi                    ; inner arc (radius r - 1, shifted by 1)
    pop r9
    xor ebx, ebx
.row:
    xor r11d, r11d
.pixel:
    mov edi, ebx
    shl edi, 4
    add edi, r11d
    movzx edi, byte [r10 + rdi]
    test ebx, ebx
    jz .ring
    test r11d, r11d
    jz .ring
    lea esi, [ebx - 1]
    shl esi, 4
    lea esi, [esi + r11d - 1]
    movzx esi, byte [rbp + rsi]
    sub edi, esi
    jle .next
.ring:
    test edi, edi
    jz .next
    shl edi, 4
    push rax
    xor eax, eax
.corner:
    push rax
    call gfx_corner_point
    mov eax, [rsp + 8]
    call gfx_blend_pixel
    pop rax
    inc eax
    cmp eax, 4
    jb .corner
    pop rax
.next:
    inc r11d
    cmp r11d, r9d
    jb .pixel
    inc ebx
    cmp ebx, r9d
    jb .row
    jmp .done
.square:
    test r9d, r9d
    jz .done
    xor eax, eax                    ; radius 1: fill the four corner pixels
    xor ebx, ebx
    xor r11d, r11d
.square_corner:
    push rax
    call gfx_corner_point
    mov eax, [rsp + 8 * 15]         ; the colour (saved RAX)
    call gfx_putpixel
    pop rax
    inc eax
    cmp eax, 4
    jb .square_corner
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gfx_corners_save: ECX,EDX = x,y  ESI,R8D = w,h  R9D = corner radius.
; Remembers the pixels under the box's four corner squares for
; gfx_corners_cut.
gfx_corners_save:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r11
    push r12
    push r13
    push r14
    push r15
    call gfx_clamp_radius
    mov r12d, ecx
    mov r13d, edx
    mov r14d, esi
    mov r15d, r8d
    lea rdi, [gfx_corner_save]
    xor eax, eax                    ; corner
.corner:
    xor ebx, ebx
.row:
    xor r11d, r11d
.pixel:
    call gfx_corner_point
    xor esi, esi                    ; off screen: nothing to keep
    cmp ecx, GFX_WIDTH
    jae .store
    cmp edx, GFX_HEIGHT
    jae .store
    imul edx, GFX_WIDTH
    add edx, ecx
    mov rsi, [gfx_target]
    mov esi, [rsi + rdx * 4]
.store:
    mov [rdi], esi
    add rdi, 4
    inc r11d
    cmp r11d, r9d
    jb .pixel
    inc ebx
    cmp ebx, r9d
    jb .row
    inc eax
    cmp eax, 4
    jb .corner
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gfx_corners_cut: same inputs as gfx_corners_save. Blends the saved pixels
; back over the parts of the corners outside the rounded outline, so all
; that was drawn in the box since the save gets anti-aliased round corners.
gfx_corners_cut:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    call gfx_clamp_radius
    test r9d, r9d
    jz .done
    mov r12d, ecx
    mov r13d, edx
    mov r14d, esi
    mov r15d, r8d
    call gfx_cov_get
    mov r10, rsi
    lea rbp, [gfx_corner_save]
    xor eax, eax
.corner:
    xor ebx, ebx
.row:
    xor r11d, r11d
.pixel:
    mov edi, ebx
    shl edi, 4
    add edi, r11d
    movzx edi, byte [r10 + rdi]
    cmp edi, 16
    je .next                        ; fully inside: keep the new pixel
    call gfx_corner_point
    cmp ecx, [gfx_clip_x0]
    jl .next
    cmp ecx, [gfx_clip_x1]
    jge .next
    cmp edx, [gfx_clip_y0]
    jl .next
    cmp edx, [gfx_clip_y1]
    jge .next
    push rax
    push rbx
    imul edx, GFX_WIDTH
    add edx, ecx
    movsxd rdx, edx
    mov rsi, [gfx_target]
    lea rsi, [rsi + rdx * 4]
    mov eax, [rsi]                  ; new pixel, weighted by its coverage
    mov ebx, [rbp]                  ; over the saved one
    shl edi, 4
    call gfx_mix
    mov [rsi], ebx
    pop rbx
    pop rax
.next:
    add rbp, 4
    inc r11d
    cmp r11d, r9d
    jb .pixel
    inc ebx
    cmp ebx, r9d
    jb .row
    inc eax
    cmp eax, 4
    jb .corner
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gfx_shadow: soft shadow of a rounded box, THEME_SHADOW fading out over
; R10D pixels (at most GFX_SHADOW_MAX). ECX,EDX = x,y  ESI,R8D = w,h of the
; box  R9D = corner radius  R11D = how far the shadow sits below the box
; EDI = alpha right next to the box. What the rounded box itself covers is
; left alone, so the box may be translucent.
gfx_shadow:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    call gfx_clamp_radius
    cmp r10d, GFX_SHADOW_MAX
    jle .blur_ok
    mov r10d, GFX_SHADOW_MAX
.blur_ok:
    test r10d, r10d
    jle .done
    mov [gfx_sh_x], ecx
    mov [gfx_sh_y], edx
    lea eax, [ecx + esi]
    mov [gfx_sh_x1], eax
    lea eax, [edx + r8d]
    mov [gfx_sh_y1], eax
    mov [gfx_sh_r], r9d
    push rsi
    call gfx_cov_get
    mov [gfx_sh_cov], rsi
    pop rsi
    ; the shadow shape's inner rectangle: the box moved down, inset by r
    lea eax, [ecx + r9d]
    mov [gfx_sh_ix0], eax
    lea eax, [ecx + esi - 1]
    sub eax, r9d
    mov [gfx_sh_ix1], eax
    lea eax, [edx + r11d]
    add eax, r9d
    mov [gfx_sh_iy0], eax
    lea eax, [edx + r11d - 1]
    add eax, r8d
    sub eax, r9d
    mov [gfx_sh_iy1], eax
    ; alpha by distance in quarter pixels: edge alpha * ((4B - d) / 4B)^2
    lea ebx, [r10d * 4]             ; 4B
    mov ebp, ebx
    imul ebp, ebp                   ; (4B)^2
    xor ecx, ecx
    lea rsi, [gfx_sh_alpha]
.table:
    mov eax, ebx
    sub eax, ecx
    imul eax, eax
    imul eax, edi
    xor edx, edx
    div ebp
    mov [rsi + rcx * 4], eax
    inc ecx
    cmp ecx, ebx
    jbe .table
    mov [gfx_sh_q], ebx
    ; area: the moved box grown by the blur, clipped
    mov r12d, [gfx_sh_x]
    sub r12d, r10d                  ; R12 = x0
    mov r13d, [gfx_sh_x1]
    add r13d, r10d                  ; R13 = x1
    mov r14d, [gfx_sh_y]
    add r14d, r11d
    sub r14d, r10d                  ; R14 = y0
    mov r15d, [gfx_sh_y1]
    add r15d, r11d
    add r15d, r10d                  ; R15 = y1
    cmp r12d, [gfx_clip_x0]
    jge .c0
    mov r12d, [gfx_clip_x0]
.c0:
    cmp r13d, [gfx_clip_x1]
    jle .c1
    mov r13d, [gfx_clip_x1]
.c1:
    cmp r14d, [gfx_clip_y0]
    jge .c2
    mov r14d, [gfx_clip_y0]
.c2:
    cmp r15d, [gfx_clip_y1]
    jle .c3
    mov r15d, [gfx_clip_y1]
.c3:
    cmp r12d, r13d
    jge .done
    mov edx, r14d                   ; EDX = y
.row:
    cmp edx, r15d
    jge .done
    ; dy: distance below/above the inner rectangle
    xor r9d, r9d
    mov eax, [gfx_sh_iy0]
    sub eax, edx
    jle .below_top
    mov r9d, eax
    jmp .dy_done
.below_top:
    mov eax, edx
    sub eax, [gfx_sh_iy1]
    jle .dy_done
    mov r9d, eax
.dy_done:
    ; is this row inside the box itself, and within its straight part?
    xor r8d, r8d                    ; R8 = 1: row is in the box, 2: also clear of its corners
    cmp edx, [gfx_sh_y]
    jl .row_flags
    cmp edx, [gfx_sh_y1]
    jge .row_flags
    mov r8d, 1
    mov r10d, edx                   ; R10 = row within a corner, from the outer edge
    sub r10d, [gfx_sh_y]
    cmp r10d, [gfx_sh_r]
    jl .row_flags
    mov r10d, [gfx_sh_y1]
    dec r10d
    sub r10d, edx
    cmp r10d, [gfx_sh_r]
    jl .row_flags
    mov r8d, 2
.row_flags:
    mov eax, edx
    imul eax, GFX_WIDTH
    add eax, r12d
    movsxd rsi, eax
    shl rsi, 2
    add rsi, [gfx_target]
    mov ecx, r12d                   ; ECX = x
.pixel:
    test r8d, r8d
    jz .outside_box
    cmp ecx, [gfx_sh_x]
    jl .outside_box
    cmp ecx, [gfx_sh_x1]
    jge .outside_box
    cmp r8d, 2
    je .next                        ; under the box, away from its corners
    mov r11d, ecx                   ; column within a corner, from the outer edge
    sub r11d, [gfx_sh_x]
    cmp r11d, [gfx_sh_r]
    jl .corner
    mov r11d, [gfx_sh_x1]
    dec r11d
    sub r11d, ecx
    cmp r11d, [gfx_sh_r]
    jge .next                       ; under the box's straight top/bottom edge
.corner:
    mov eax, r10d                   ; in a corner square: only the part the
    shl eax, 4                      ; rounded box leaves uncovered
    add eax, r11d
    mov rbx, [gfx_sh_cov]
    movzx eax, byte [rbx + rax]
    mov r11d, 16
    sub r11d, eax                   ; R11 = sixteenths uncovered
    jz .next
    jmp .distance
.outside_box:
    mov r11d, 16
.distance:
    xor ebx, ebx                    ; dx
    mov eax, [gfx_sh_ix0]
    sub eax, ecx
    jle .right_of_left
    mov ebx, eax
    jmp .dx_done
.right_of_left:
    mov eax, ecx
    sub eax, [gfx_sh_ix1]
    jle .dx_done
    mov ebx, eax
.dx_done:
    ; distance in quarter pixels from the inner rectangle
    test ebx, ebx
    jnz .dx_nonzero
    lea eax, [r9d * 4]
    jmp .have_distance
.dx_nonzero:
    test r9d, r9d
    jnz .diagonal
    lea eax, [ebx * 4]
    jmp .have_distance
.diagonal:
    mov eax, ebx
    imul eax, eax
    mov edi, r9d
    imul edi, edi
    add eax, edi
    shl eax, 4                      ; 16 (dx^2 + dy^2) = (4d)^2
    cvtsi2sd xmm0, eax
    sqrtsd xmm0, xmm0
    cvttsd2si eax, xmm0
.have_distance:
    mov edi, [gfx_sh_r]             ; minus the radius: distance from the outline
    shl edi, 2
    sub eax, edi
    jge .positive
    xor eax, eax
.positive:
    cmp eax, [gfx_sh_q]
    jae .next
    lea rdi, [gfx_sh_alpha]
    mov edi, [rdi + rax * 4]
    imul edi, r11d
    shr edi, 4
    test edi, edi
    jz .next
    mov ebx, [rsi]
    mov eax, THEME_SHADOW
    call gfx_mix
    mov [rsi], ebx
.next:
    add rsi, 4
    inc ecx
    cmp ecx, r13d
    jl .pixel
    inc edx
    jmp .row
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
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
    mov edi, THEME_CURSOR_EDGE
    cmp bl, '#'
    je .plot
    mov edi, THEME_CURSOR
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
