; ==============================================================================
; Antigravity OS - Cyber Canvas window (paint program)
; ------------------------------------------------------------------------------
; The picture lives in its own bitmap (GUI_CANVAS_ADDR, same pitch as the
; screen), so it survives redraws, window moves and workspace switches. The
; client area is a toolbar row plus the visible part of that bitmap; all
; coordinates are relative to the window, so moving it just works.
;
; Mouse: paint (strokes are joined with lines). Keys 1-8: colour, C: clear,
; D: demo art, Space/Enter: dab at the pointer.
; ==============================================================================

[bits 64]

CANVAS_TOOLBAR_H        equ 44
CANVAS_MARGIN           equ 10
CANVAS_BRUSH            equ 5
CANVAS_SWATCH_X         equ 14      ; round swatches
CANVAS_SWATCH_Y         equ 12
CANVAS_SWATCH_STEP      equ 28
CANVAS_SWATCH_W         equ 20
CANVAS_BTN_Y            equ 10      ; buttons (the swatches' click band too)
CANVAS_BTN_H            equ 24
CANVAS_CLEAR_X          equ 252
CANVAS_CLEAR_W          equ 64
CANVAS_ART_X            equ 324
CANVAS_ART_W            equ 88
CANVAS_HINT_X           equ 428
CANVAS_ART_CX           equ 440     ; demo art centre inside the bitmap
CANVAS_ART_CY           equ 300

section .data
canvas_ready:           db 0
align 4
canvas_color:           dd THEME_CYAN
canvas_last_x:          dd -1       ; previous stroke point (bitmap coords)
canvas_last_y:          dd -1
canvas_origin_x:        dd 0        ; screen position of bitmap (0,0), from the last draw
canvas_origin_y:        dd 0
canvas_swatches:
    dd THEME_TEXT, THEME_CYAN, THEME_BLUE, THEME_RED
    dd THEME_ORANGE, THEME_YELLOW, THEME_GREEN, THEME_MAGENTA

section .rodata
canvas_title:           db "Cyber Canvas", 0
canvas_label:           db "Canvas", 0
canvas_str_clear:       db "Clear", 0
canvas_str_art:         db "Draw art", 0
canvas_str_hint:        db "Mouse paints   1-8 colour   C clear   D art", 0
canvas_str_banner:      db "ANTIGRAVITY OS", 0

section .text
; ------------------------------------------------------------------------------
; canvas_init: first desktop start only - blank bitmap plus the demo art
; ------------------------------------------------------------------------------
canvas_init:
    cmp byte [canvas_ready], 0
    jne .ret
    mov byte [canvas_ready], 1
    call canvas_clear
    call canvas_demo_art
.ret:
    ret

; canvas_target_begin / canvas_target_end: point gfx at the canvas bitmap
canvas_target_begin:
    mov qword [gfx_target], GUI_CANVAS_ADDR
    push rcx
    push rdx
    push rsi
    push r8
    xor ecx, ecx
    xor edx, edx
    mov esi, GFX_WIDTH
    mov r8d, GFX_HEIGHT
    call gfx_push_clip
    pop r8
    pop rsi
    pop rdx
    pop rcx
    ret

canvas_target_end:
    call gfx_pop_clip
    mov qword [gfx_target], GUI_BACKBUFFER_ADDR
    ret

canvas_clear:
    push rax
    push rcx
    push rdi
    mov rdi, GUI_CANVAS_ADDR
    mov eax, THEME_CANVAS_BG
    mov ecx, GFX_WIDTH * GFX_HEIGHT
    rep stosd
    pop rdi
    pop rcx
    pop rax
    ret

; canvas_demo_art: rounded rings in three colours, a crosshair, a banner and
; corner marks
canvas_demo_art:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    call canvas_target_begin
    mov ebx, 16
    xor edi, edi                    ; ring number
.ring:
    mov ecx, CANVAS_ART_CX
    sub ecx, ebx
    mov edx, CANVAS_ART_CY
    sub edx, ebx
    lea esi, [ebx * 2]
    mov r8d, esi
    mov eax, edi                    ; colour: ring number mod 3
    push rdx
    xor edx, edx
    mov r9d, 3
    div r9d
    lea rax, [canvas_art_colours]
    mov eax, [rax + rdx * 4]
    pop rdx
    mov r9d, 16
    call gfx_stroke_round_rect
    inc edi
    add ebx, 14
    cmp ebx, 128
    jl .ring

    mov ecx, CANVAS_ART_CX - 260    ; crosshair
    mov edx, CANVAS_ART_CY
    mov esi, 520
    mov r8d, 1
    mov eax, THEME_ACCENT_DIM
    call gfx_fill_rect
    mov ecx, CANVAS_ART_CX
    mov edx, CANVAS_ART_CY - 130
    mov esi, 1
    mov r8d, 260
    call gfx_fill_rect

    lea rsi, [canvas_str_banner]    ; banner on a pill
    call gfx_ui_width_bold
    lea esi, [eax + 28]
    mov ecx, CANVAS_ART_CX
    mov edx, esi
    shr edx, 1
    sub ecx, edx
    mov edx, CANVAS_ART_CY - 13
    mov r8d, 26
    mov r9d, 13
    mov eax, THEME_SURFACE
    call gfx_fill_round_rect
    mov eax, THEME_ACCENT
    call gfx_stroke_round_rect
    add ecx, 14
    add edx, 5
    lea rsi, [canvas_str_banner]
    mov eax, THEME_TEXT
    call gfx_print_ui_bold

    mov eax, THEME_TEAL             ; corner marks
    mov ecx, 12
    mov edx, 12
    call .corner_h
    mov ecx, 12
    call .corner_v
    mov ecx, 2 * CANVAS_ART_CX - 32
    call .corner_h
    mov ecx, 2 * CANVAS_ART_CX - 14
    call .corner_v
    mov ecx, 12
    mov edx, 2 * CANVAS_ART_CY - 14
    call .corner_h
    mov edx, 2 * CANVAS_ART_CY - 32
    call .corner_v
    mov ecx, 2 * CANVAS_ART_CX - 32
    mov edx, 2 * CANVAS_ART_CY - 14
    call .corner_h
    mov ecx, 2 * CANVAS_ART_CX - 14
    mov edx, 2 * CANVAS_ART_CY - 32
    call .corner_v
    call canvas_target_end
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.corner_h:
    mov esi, 20
    mov r8d, 2
    jmp gfx_fill_rect
.corner_v:
    mov esi, 2
    mov r8d, 20
    jmp gfx_fill_rect

section .rodata
canvas_art_colours:     dd THEME_ACCENT, THEME_MAGENTA, THEME_TEAL

section .text
; canvas_dab: paint one brush dab at bitmap coords ECX,EDX
canvas_dab:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    call canvas_target_begin
    sub ecx, CANVAS_BRUSH / 2
    sub edx, CANVAS_BRUSH / 2
    mov esi, CANVAS_BRUSH
    mov r8d, CANVAS_BRUSH
    push r9
    mov r9d, CANVAS_BRUSH / 2
    mov eax, [canvas_color]
    call gfx_fill_round_rect
    pop r9
    call canvas_target_end
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; canvas_stroke: paint from (canvas_last_x, canvas_last_y) to ECX,EDX with
; dabs every pixel along the longer axis (simple DDA)
canvas_stroke:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov eax, [canvas_last_x]
    cmp eax, -1
    je .single
    mov r8d, ecx                    ; target
    mov r9d, edx
    mov esi, r8d
    sub esi, eax                    ; dx
    mov edi, r9d
    sub edi, [canvas_last_y]        ; dy
    mov ebx, esi                    ; steps = max(|dx|, |dy|)
    test ebx, ebx
    jns .abs_dx
    neg ebx
.abs_dx:
    mov eax, edi
    test eax, eax
    jns .abs_dy
    neg eax
.abs_dy:
    cmp eax, ebx
    jle .steps
    mov ebx, eax
.steps:
    test ebx, ebx
    jz .single
    xor ecx, ecx                    ; i = 1..steps
.loop:
    inc ecx
    mov eax, esi                    ; x = last_x + dx * i / steps
    imul eax, ecx
    cdq
    idiv ebx
    add eax, [canvas_last_x]
    push rax
    mov eax, edi
    imul eax, ecx
    cdq
    idiv ebx
    add eax, [canvas_last_y]
    mov edx, eax
    pop rax
    push rcx
    mov ecx, eax
    call canvas_dab
    pop rcx
    cmp ecx, ebx
    jb .loop
    mov ecx, r8d
    mov edx, r9d
    jmp .remember
.single:
    call canvas_dab
.remember:
    mov [canvas_last_x], ecx
    mov [canvas_last_y], edx
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
; canvas_draw: WIN_DRAW callback
; ------------------------------------------------------------------------------
canvas_draw:
    mov r12d, ecx
    mov r13d, edx
    mov r14d, esi
    mov r15d, r8d
    mov eax, THEME_WIN_BODY
    call gfx_fill_rect

    xor ebx, ebx                    ; swatches: dots, the current one ringed
.swatch:
    mov ecx, ebx
    imul ecx, CANVAS_SWATCH_STEP
    add ecx, r12d
    add ecx, CANVAS_SWATCH_X
    lea edx, [r13d + CANVAS_SWATCH_Y]
    mov esi, CANVAS_SWATCH_W
    mov r8d, CANVAS_SWATCH_W
    mov r9d, CANVAS_SWATCH_W / 2
    lea rax, [canvas_swatches]
    mov eax, [rax + rbx * 4]
    call gfx_fill_round_rect
    cmp eax, [canvas_color]
    jne .next_swatch
    sub ecx, 3
    sub edx, 3
    add esi, 6
    add r8d, 6
    add r9d, 3
    mov eax, THEME_TEXT_SOFT
    call gfx_stroke_round_rect
.next_swatch:
    inc ebx
    cmp ebx, 8
    jb .swatch

    lea ecx, [r12d + CANVAS_CLEAR_X]    ; buttons
    lea edx, [r13d + CANVAS_BTN_Y]
    mov esi, CANVAS_CLEAR_W
    mov r8d, CANVAS_BTN_H
    mov r9d, 7
    mov eax, THEME_SURFACE_HI
    call gfx_fill_round_rect
    add ecx, CANVAS_CLEAR_W / 2
    add edx, 4
    lea rsi, [canvas_str_clear]
    mov eax, THEME_TEXT
    call gfx_print_ui_centered
    lea ecx, [r12d + CANVAS_ART_X]
    lea edx, [r13d + CANVAS_BTN_Y]
    mov esi, CANVAS_ART_W
    mov eax, THEME_ACCENT
    call gfx_fill_round_rect
    add ecx, CANVAS_ART_W / 2
    add edx, 4
    lea rsi, [canvas_str_art]
    mov eax, THEME_WIN_BODY
    call gfx_print_ui_centered
    lea ecx, [r12d + CANVAS_HINT_X]
    lea rsi, [canvas_str_hint]
    mov eax, THEME_TEXT_MUTED
    call gfx_print_ui

    ; The picture
    lea ecx, [r12d + CANVAS_MARGIN]
    lea edx, [r13d + CANVAS_TOOLBAR_H]
    mov [canvas_origin_x], ecx
    mov [canvas_origin_y], edx
    lea r11d, [r14d - 2 * CANVAS_MARGIN]
    lea r8d, [r15d - CANVAS_TOOLBAR_H - CANVAS_MARGIN]
    cmp r11d, GFX_WIDTH             ; the bitmap is only screen-sized; a window
    jle .w_ok                       ; dragged off-screen can be wider
    mov r11d, GFX_WIDTH
.w_ok:
    cmp r8d, GFX_HEIGHT
    jle .h_ok
    mov r8d, GFX_HEIGHT
.h_ok:
    push rcx
    push rdx
    push r8
    mov esi, r11d
    call gfx_push_clip
    mov rsi, GUI_CANVAS_ADDR
    xor r9d, r9d
    xor r10d, r10d
    call gfx_blit
    call gfx_pop_clip
    pop r8
    pop rdx
    pop rcx
    dec ecx                         ; hairline frame around the picture
    dec edx
    lea esi, [r11d + 2]
    add r8d, 2
    mov eax, THEME_WIN_EDGE
    call gfx_draw_rect
    ret

; ------------------------------------------------------------------------------
; canvas_mouse: WIN_MOUSE callback (AL = event, ECX,EDX = client coords)
; ------------------------------------------------------------------------------
canvas_mouse:
    cmp al, WM_MOUSE_WHEEL          ; nothing to scroll
    je .done
    cmp al, WM_MOUSE_RELEASE
    je .release
    cmp edx, CANVAS_TOOLBAR_H
    jge .paint
    cmp al, WM_MOUSE_PRESS          ; toolbar only reacts to presses
    jne .done
    cmp edx, CANVAS_BTN_Y
    jl .done
    cmp edx, CANVAS_BTN_Y + CANVAS_BTN_H
    jg .done
    mov eax, ecx                    ; swatch?
    sub eax, CANVAS_SWATCH_X
    jl .done
    xor edx, edx
    mov ebx, CANVAS_SWATCH_STEP
    div ebx
    cmp eax, 8
    jae .buttons
    cmp edx, CANVAS_SWATCH_W
    jae .done
    lea rbx, [canvas_swatches]
    mov eax, [rbx + rax * 4]
    mov [canvas_color], eax
    ret
.buttons:
    cmp ecx, CANVAS_CLEAR_X
    jl .done
    cmp ecx, CANVAS_CLEAR_X + CANVAS_CLEAR_W
    jl canvas_clear
    cmp ecx, CANVAS_ART_X
    jl .done
    cmp ecx, CANVAS_ART_X + CANVAS_ART_W
    jl canvas_demo_art
    ret
.paint:
    sub ecx, CANVAS_MARGIN          ; client -> bitmap coordinates
    sub edx, CANVAS_TOOLBAR_H
    cmp al, WM_MOUSE_PRESS
    jne .stroke
    mov dword [canvas_last_x], -1   ; a new stroke
.stroke:
    jmp canvas_stroke
.release:
    mov dword [canvas_last_x], -1
.done:
    ret

; ------------------------------------------------------------------------------
; canvas_key: WIN_KEY callback
; ------------------------------------------------------------------------------
canvas_key:
    cmp al, 'c'
    je .clear
    cmp al, 'C'
    je .clear
    cmp al, 'd'
    je .art
    cmp al, 'D'
    je .art
    cmp al, ' '
    je .dab
    cmp al, 0x0D
    je .dab
    cmp al, '1'
    jb .unused
    cmp al, '8'
    ja .unused
    movzx eax, al
    sub eax, '1'
    lea rbx, [canvas_swatches]
    mov eax, [rbx + rax * 4]
    mov [canvas_color], eax
    stc
    ret
.clear:
    call canvas_clear
    stc
    ret
.art:
    call canvas_demo_art
    stc
    ret
.dab:
    mov ecx, [mouse_x]
    sub ecx, [canvas_origin_x]
    mov edx, [mouse_y]
    sub edx, [canvas_origin_y]
    mov dword [canvas_last_x], -1
    call canvas_stroke
    stc
    ret
.unused:
    clc
    ret
