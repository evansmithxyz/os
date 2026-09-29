; ==============================================================================
; Antigravity OS - Desktop chrome: wallpaper, top bar and dock
; ------------------------------------------------------------------------------
; Top bar (y 0 - TASKBAR_H), a strip of glass over the wallpaper:
;   left    logo + "Antigravity" (click: every window back to its default
;           workspace and position), then the workspace buttons 1-4
;           (filled = active, brighter = has windows)
;   centre  date and time (the CMOS clock, UTC)
;   right   network address, memory, and the power button (back to the text
;           console)
; Dock (bottom centre): one icon per app; a dot under an icon means the
; window is open (accent = focused). Click: open / focus / minimize.
; ==============================================================================

[bits 64]

TB_TEXT_Y               equ 6
TB_LOGO_X               equ 12
TB_NAME_X               equ 32
TB_WS_X                 equ 132      ; first workspace button
TB_WS_Y                 equ 5
TB_WS_W                 equ 24
TB_WS_H                 equ 18
TB_WS_STEP              equ 28
TB_POWER_X              equ GFX_WIDTH - 32  ; the power button runs to the right edge
TB_STATUS_RIGHT         equ GFX_WIDTH - 44  ; right end of the status text

DOCK_ICON               equ 44
DOCK_GAP                equ 14
DOCK_PAD                equ 10
DOCK_APPS               equ 4
DOCK_W                  equ DOCK_APPS * DOCK_ICON + (DOCK_APPS - 1) * DOCK_GAP + 2 * DOCK_PAD
DOCK_H                  equ DOCK_ICON + 2 * DOCK_PAD + 2
DOCK_X                  equ (GFX_WIDTH - DOCK_W) / 2
DOCK_Y                  equ GFX_HEIGHT - DOCK_H - 6
DOCK_ICON_Y             equ DOCK_Y + 8
DOCK_RADIUS             equ 16
ICON_RADIUS             equ 11

section .rodata
str_os_name:            db "Antigravity", 0
str_badge_offline:      db "offline", 0
str_badge_mb:           db " MB", 0
desktop_months:         db "JanFebMarAprMayJunJulAugSepOctNovDec"

; Wallpaper glows: centre x, y, radius, colour, strength (0-256)
align 4
desktop_glows:
    dd 150,  720, 640, THEME_GLOW_1, 150
    dd 910,   40, 560, THEME_GLOW_2, 120
    dd 860,  840, 430, THEME_GLOW_3, 80
DESKTOP_GLOWS           equ 3
GLOW_SIZE               equ 20
; 4x4 ordered dither, so the gradient has no bands
desktop_bayer:          db 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5

align 8
; dock: window id, icon painter
desktop_dock_apps:
    dq WIN_TERM,    desktop_icon_terminal
    dq WIN_BROWSER, desktop_icon_browser
    dq WIN_CANVAS,  desktop_icon_canvas
    dq WIN_SYSMON,  desktop_icon_sysmon

section .data
desktop_wall_ready:     db 0

section .bss
desktop_text_buf:       resb 64
alignb 8
desktop_glow_r2:        resq DESKTOP_GLOWS   ; radius^2
desktop_glow_inv:       resq DESKTOP_GLOWS   ; 2^32 / radius^2

section .text
; ------------------------------------------------------------------------------
; desktop_render_wallpaper: paint the wallpaper into GUI_WALLPAPER_ADDR (once:
; it never changes). A vertical gradient, three glows added on top (falloff
; (1 - d^2/r^2)^2), then 4x4 ordered dithering. Channels are 8.8 fixed point.
; ------------------------------------------------------------------------------
desktop_render_wallpaper:
    cmp byte [desktop_wall_ready], 0
    jne .ret
    mov byte [desktop_wall_ready], 1
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

    lea rsi, [desktop_glows]        ; radius^2 and its reciprocal per glow
    xor ecx, ecx
.glow_setup:
    mov eax, [rsi + 8]
    imul rax, rax
    lea rbx, [desktop_glow_r2]
    mov [rbx + rcx * 8], rax
    mov rbx, rax
    mov rax, 1 << 32
    xor edx, edx
    div rbx
    lea rbx, [desktop_glow_inv]
    mov [rbx + rcx * 8], rax
    add rsi, GLOW_SIZE
    inc ecx
    cmp ecx, DESKTOP_GLOWS
    jb .glow_setup

    mov rdi, GUI_WALLPAPER_ADDR
    xor r15d, r15d                  ; y
.row:
    ; the gradient at this row, per channel in 8.8: top + (bottom - top) * y / (H - 1)
    mov ecx, 16
    call .gradient
    mov r11d, eax                   ; red
    mov ecx, 8
    call .gradient
    mov r12d, eax                   ; green
    xor ecx, ecx
    call .gradient
    mov r13d, eax                   ; blue
    xor r14d, r14d                  ; x
.pixel:
    mov r8d, r11d
    mov r9d, r12d
    mov r10d, r13d
    lea rsi, [desktop_glows]
    xor ebp, ebp                    ; glow index
.glow:
    mov eax, r14d
    sub eax, [rsi]
    imul eax, eax
    mov ebx, r15d
    sub ebx, [rsi + 4]
    imul ebx, ebx
    add rax, rbx                    ; RAX = d^2
    lea rbx, [desktop_glow_r2]
    mov rbx, [rbx + rbp * 8]
    sub rbx, rax
    jle .next_glow                  ; outside the glow
    lea rax, [desktop_glow_inv]
    imul rbx, [rax + rbp * 8]
    shr rbx, 16                     ; f = 1 - d^2/r^2 in 0.16
    imul rbx, rbx
    shr rbx, 16                     ; f^2
    mov eax, [rsi + 16]
    imul rbx, rax
    shr rbx, 8                      ; times the strength
    mov edx, [rsi + 12]             ; colour: add colour * f per channel
    mov eax, edx
    shr eax, 16
    and eax, 0xFF
    imul rax, rbx
    shr rax, 8
    add r8d, eax
    mov eax, edx
    shr eax, 8
    and eax, 0xFF
    imul rax, rbx
    shr rax, 8
    add r9d, eax
    mov eax, edx
    and eax, 0xFF
    imul rax, rbx
    shr rax, 8
    add r10d, eax
.next_glow:
    add rsi, GLOW_SIZE
    inc ebp
    cmp ebp, DESKTOP_GLOWS
    jb .glow

    ; dither threshold: -120 .. +128 in 8.8
    mov eax, r15d
    and eax, 3
    shl eax, 2
    mov ebx, r14d
    and ebx, 3
    add eax, ebx
    lea rbx, [desktop_bayer]
    movzx ebx, byte [rbx + rax]
    shl ebx, 4
    sub ebx, 120
    xor edx, edx                    ; EDX = the pixel
    mov eax, r8d
    call .channel
    shl eax, 16
    or edx, eax
    mov eax, r9d
    call .channel
    shl eax, 8
    or edx, eax
    mov eax, r10d
    call .channel
    or edx, eax
    mov [rdi], edx
    add rdi, 4
    inc r14d
    cmp r14d, GFX_WIDTH
    jb .pixel
    inc r15d
    cmp r15d, GFX_HEIGHT
    jb .row

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
.ret:
    ret

; ECX = channel shift -> EAX = gradient value at row R15D, 8.8
.gradient:
    mov eax, THEME_WALL_TOP
    shr eax, cl
    and eax, 0xFF
    mov edx, THEME_WALL_BOTTOM
    shr edx, cl
    and edx, 0xFF
    sub edx, eax
    shl eax, 8
    imul edx, r15d
    shl edx, 8
    push rax
    mov eax, edx
    cdq
    mov ebp, GFX_HEIGHT - 1
    idiv ebp
    mov edx, eax
    pop rax
    add eax, edx
    ret

; EAX = channel in 8.8, EBX = dither -> EAX = 0-255
.channel:
    add eax, ebx
    jns .not_negative
    xor eax, eax
.not_negative:
    shr eax, 8
    cmp eax, 255
    jbe .in_range
    mov eax, 255
.in_range:
    ret

; ------------------------------------------------------------------------------
; desktop_update_clock: read the CMOS clock (called once a second)
; ------------------------------------------------------------------------------
desktop_update_clock:
    jmp rtc_read

; ------------------------------------------------------------------------------
; desktop_draw_taskbar: the top bar
; ------------------------------------------------------------------------------
desktop_draw_taskbar:
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

    xor ecx, ecx                    ; glass strip with a faint bottom edge
    xor edx, edx
    mov esi, GFX_WIDTH
    mov r8d, TASKBAR_H
    mov eax, THEME_BAR
    mov edi, THEME_BAR_ALPHA
    call gfx_blend_rect
    mov edx, TASKBAR_H - 1
    mov r8d, 1
    mov eax, THEME_HOVER
    mov edi, 20
    call gfx_blend_rect

    ; logo: a ring with a dot, then the name
    mov ecx, TB_LOGO_X
    mov edx, 7
    mov esi, 14
    mov r8d, 14
    mov r9d, 7
    mov eax, THEME_ACCENT
    call gfx_stroke_round_rect
    mov ecx, TB_LOGO_X + 4
    mov edx, 11
    mov esi, 6
    mov r8d, 6
    mov r9d, 3
    mov eax, THEME_MAGENTA
    call gfx_fill_round_rect
    mov ecx, TB_NAME_X
    mov edx, TB_TEXT_Y
    lea rsi, [str_os_name]
    mov eax, THEME_TEXT
    call gfx_print_ui_bold

    ; workspace buttons
    xor r11d, r11d                  ; workspace index 0-3
.ws_loop:
    mov ecx, r11d
    imul ecx, TB_WS_STEP
    add ecx, TB_WS_X
    mov edx, TB_WS_Y
    mov esi, TB_WS_W
    mov r8d, TB_WS_H
    mov r9d, 6
    lea eax, [r11d + '1']
    mov [desktop_text_buf], al
    mov byte [desktop_text_buf + 1], 0
    lea eax, [r11d + 1]
    cmp al, [wm_active_ws]
    jne .ws_inactive
    mov eax, THEME_ACCENT
    call gfx_fill_round_rect
    mov r10d, THEME_BAR             ; dark digit on the accent
    jmp .ws_label
.ws_inactive:
    mov r10d, THEME_TEXT_FAINT
    call desktop_ws_occupied        ; AL = workspace -> CF=1 if it has windows
    jnc .ws_label
    mov eax, THEME_HOVER
    mov edi, THEME_HOVER_ALPHA
    call gfx_blend_round_rect
    mov r10d, THEME_TEXT_SOFT
.ws_label:
    add ecx, TB_WS_W / 2
    mov edx, TB_TEXT_Y
    lea rsi, [desktop_text_buf]
    mov eax, r10d
    call gfx_print_ui_centered
    inc r11d
    cmp r11d, WM_WORKSPACES
    jb .ws_loop

    ; centre: "Sep 28  14:05"
    lea rdi, [desktop_text_buf]
    movzx eax, byte [rtc_month]
    dec eax
    cmp eax, 11
    jbe .month_ok
    xor eax, eax
.month_ok:
    lea rsi, [desktop_months]
    lea rsi, [rsi + rax * 2]
    add rsi, rax
    mov ecx, 3
    rep movsb
    mov al, ' '
    call fmt_char
    movzx eax, byte [rtc_day]
    call fmt_dec
    lea rsi, [desktop_text_buf]
    call gfx_ui_width
    mov r10d, eax                   ; date width
    lea rdi, [desktop_text_buf + 16]
    movzx eax, byte [rtc_hour]
    call desktop_fmt_2digits
    mov al, ':'
    call fmt_char
    movzx eax, byte [rtc_minute]
    call desktop_fmt_2digits
    lea rsi, [desktop_text_buf + 16]
    call gfx_ui_width_bold
    lea ecx, [r10d + eax + 10]      ; total width, centred
    shr ecx, 1
    neg ecx
    add ecx, GFX_WIDTH / 2
    mov edx, TB_TEXT_Y
    lea rsi, [desktop_text_buf]
    mov eax, THEME_TEXT_MUTED
    call gfx_print_ui
    add ecx, 9
    lea rsi, [desktop_text_buf + 16]
    mov eax, THEME_TEXT
    call gfx_print_ui_bold

    ; right: memory, then the network address with a status dot
    lea rdi, [desktop_text_buf]
    call memory_total_mb
    call fmt_dec
    lea rsi, [str_badge_mb]
    call fmt_str
    lea rsi, [desktop_text_buf]
    call gfx_ui_width
    mov ecx, TB_STATUS_RIGHT
    sub ecx, eax
    mov r10d, ecx                   ; R10 = where the next item must end
    mov edx, TB_TEXT_Y
    mov eax, THEME_TEXT_SOFT
    call gfx_print_ui

    lea rdi, [desktop_text_buf]
    lea rsi, [str_badge_offline]
    mov r11d, THEME_RED
    cmp byte [net_present], 1
    jne .ip_text
    lea rsi, [net_ip]
    call fmt_ip
    mov r11d, THEME_GREEN
    jmp .ip_draw
.ip_text:
    call fmt_str
.ip_draw:
    lea rsi, [desktop_text_buf]
    call gfx_ui_width
    mov ecx, r10d
    sub ecx, 22
    sub ecx, eax
    push rcx
    mov edx, TB_TEXT_Y
    mov eax, THEME_TEXT_SOFT
    call gfx_print_ui
    pop rcx
    sub ecx, 12                     ; status dot
    mov edx, 11
    mov esi, 6
    mov r8d, 6
    mov r9d, 3
    mov eax, r11d
    call gfx_fill_round_rect

    call desktop_draw_power

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

; desktop_fmt_2digits: RDI = buffer, AL = 0-99 -> two digits appended
desktop_fmt_2digits:
    push rax
    push rdx
    movzx eax, al
    mov dl, 10
    div dl                          ; AL = tens, AH = units
    add ax, '00'
    mov [rdi], al
    mov [rdi + 1], ah
    add rdi, 2
    mov byte [rdi], 0
    pop rdx
    pop rax
    ret

; desktop_draw_power: the power symbol (a broken ring and a bar)
desktop_draw_power:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov ecx, TB_POWER_X + 9
    mov edx, 7
    mov esi, 14
    mov r8d, 14
    mov r9d, 7
    mov eax, THEME_TEXT_SOFT
    call gfx_stroke_round_rect
    mov rax, [gfx_target]           ; open the ring at the top (in the bar's
    mov eax, [rax + (5 * GFX_WIDTH + TB_POWER_X) * 4]   ; colour, from beside it)...
    mov ecx, TB_POWER_X + 13
    mov edx, 5
    mov esi, 6
    mov r8d, 5
    call gfx_fill_rect
    mov ecx, TB_POWER_X + 15        ; ...and drop the bar into the gap
    mov edx, 5
    mov esi, 2
    mov r8d, 8
    mov eax, THEME_TEXT_SOFT
    call gfx_fill_rect
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; desktop_ws_occupied: AL = workspace -> CF=1 if an open window is on it
desktop_ws_occupied:
    push rax
    push rbx
    push rcx
    push rdx
    mov dl, al
    xor ecx, ecx
.loop:
    mov eax, ecx
    call wm_window_ptr
    cmp byte [rbx + WIN_STATE], WIN_STATE_CLOSED
    je .next
    cmp [rbx + WIN_WS], dl
    je .yes
.next:
    inc ecx
    cmp ecx, WIN_COUNT
    jb .loop
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret
.yes:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; desktop_draw_dock: glass shelf, app icons and their open/focused dots
; ------------------------------------------------------------------------------
desktop_draw_dock:
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

    mov ecx, DOCK_X
    mov edx, DOCK_Y
    mov esi, DOCK_W
    mov r8d, DOCK_H
    mov r9d, DOCK_RADIUS
    mov r10d, 18
    mov r11d, 4
    mov edi, 110
    call gfx_shadow
    mov eax, THEME_DOCK
    mov edi, THEME_DOCK_ALPHA
    call gfx_blend_round_rect
    mov eax, THEME_DOCK_EDGE
    call gfx_stroke_round_rect

    xor r12d, r12d                  ; app index
.app:
    mov ecx, r12d
    imul ecx, DOCK_ICON + DOCK_GAP
    add ecx, DOCK_X + DOCK_PAD
    mov edx, DOCK_ICON_Y
    mov rax, r12
    shl rax, 4
    lea rbx, [desktop_dock_apps]
    push rax
    push rbx
    call [rbx + rax + 8]            ; the icon, at ECX,EDX
    pop rbx
    pop rax
    mov rax, [rbx + rax]            ; window id -> its dot
    call wm_window_ptr
    mov dl, [rbx + WIN_STATE]
    cmp dl, WIN_STATE_CLOSED
    je .next
    mov r10d, THEME_TEXT_FAINT
    cmp dl, WIN_STATE_MINIMIZED
    je .dot
    mov r10d, THEME_TEXT_SOFT
    cmp al, [wm_focus]
    jne .dot
    mov r10d, THEME_ACCENT
.dot:
    add ecx, DOCK_ICON / 2 - 2
    mov edx, DOCK_Y + DOCK_H - 8
    mov esi, 4
    mov r8d, 4
    mov r9d, 2
    mov eax, r10d
    call gfx_fill_round_rect
.next:
    inc r12d
    cmp r12d, DOCK_APPS
    jb .app

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
; Dock icons: ECX,EDX = top left of a DOCK_ICON square. Preserve everything.
; ------------------------------------------------------------------------------

; desktop_icon_tile: ECX,EDX = icon, EAX = colour -> rounded tile with a
; soft highlight on its top half
desktop_icon_tile:
    push rax
    push rsi
    push rdi
    push r8
    push r9
    mov esi, DOCK_ICON
    mov r8d, DOCK_ICON
    mov r9d, ICON_RADIUS
    call gfx_fill_round_rect
    push rcx
    push rdx
    push rsi
    push r8
    mov r8d, DOCK_ICON / 2
    call gfx_push_clip
    pop r8
    pop rsi
    pop rdx
    pop rcx
    mov eax, THEME_HOVER
    mov edi, 22
    call gfx_blend_round_rect
    call gfx_pop_clip
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rax
    ret

; Terminal: a dark window with traffic lights and a green prompt
desktop_icon_terminal:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    mov eax, 0x001E2332
    call desktop_icon_tile
    mov esi, 4
    mov r8d, 4
    mov r9d, 2
    add ecx, 8
    add edx, 8
    mov eax, THEME_LIGHT_RED
    call gfx_fill_round_rect
    add ecx, 6
    mov eax, THEME_LIGHT_YELLOW
    call gfx_fill_round_rect
    add ecx, 6
    mov eax, THEME_LIGHT_GREEN
    call gfx_fill_round_rect
    sub ecx, 11
    add edx, 10
    lea rsi, [desktop_str_prompt]
    mov eax, THEME_GREEN
    call gfx_print_ui_bold
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; Browser: a blue tile with a globe
desktop_icon_browser:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push rdi
    mov eax, 0x002563EB
    call desktop_icon_tile
    mov eax, 0x00E8F0FF
    add ecx, 8
    add edx, 8
    mov esi, 28
    mov r8d, 28
    mov r9d, 14
    call gfx_stroke_round_rect      ; outline
    add ecx, 7
    mov esi, 14
    mov r9d, 7
    call gfx_stroke_round_rect      ; meridian
    sub ecx, 7
    add edx, 13
    mov esi, 28
    mov r8d, 1
    call gfx_fill_rect              ; equator
    add ecx, 3
    sub edx, 7
    mov esi, 22
    mov edi, 150
    call gfx_blend_rect             ; latitudes
    add edx, 14
    call gfx_blend_rect
    pop rdi
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; Canvas: a sheet of paper with four paint dots
desktop_icon_canvas:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    mov eax, 0x00EEEAE2
    call desktop_icon_tile
    mov esi, 11
    mov r8d, 11
    mov r9d, 6
    add ecx, 9
    add edx, 9
    mov eax, THEME_LIGHT_RED
    call gfx_fill_round_rect
    add ecx, 15
    mov eax, THEME_LIGHT_YELLOW
    call gfx_fill_round_rect
    add edx, 15
    mov eax, THEME_BLUE
    call gfx_fill_round_rect
    sub ecx, 15
    mov eax, THEME_LIGHT_GREEN
    call gfx_fill_round_rect
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; System monitor: a bar chart on dark teal
desktop_icon_sysmon:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    mov eax, 0x00123A36
    call desktop_icon_tile
    lea r10, [desktop_icon_bars]
    add ecx, 9
.bar:
    movzx r8d, byte [r10]
    test r8d, r8d
    jz .done
    push rdx
    add edx, 35
    sub edx, r8d
    mov esi, 5
    mov r9d, 2
    mov eax, THEME_TEAL
    call gfx_fill_round_rect
    pop rdx
    add ecx, 7
    inc r10
    jmp .bar
.done:
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

section .rodata
desktop_str_prompt:     db ">_", 0
desktop_icon_bars:      db 11, 19, 14, 25, 0

section .text
; ------------------------------------------------------------------------------
; desktop_taskbar_click: ECX = x of a click inside the top bar
; ------------------------------------------------------------------------------
desktop_taskbar_click:
    push rax
    push rbx
    push rcx
    push rdx
    cmp ecx, TB_POWER_X
    jb .not_power
    mov byte [gui_exit_request], 1
    jmp .done
.not_power:
    cmp ecx, TB_WS_X - 8
    jae .not_logo
    call wm_reset_layout
    jmp .done
.not_logo:
    mov eax, ecx                    ; workspace buttons
    sub eax, TB_WS_X
    jb .done
    xor edx, edx
    mov ebx, TB_WS_STEP
    div ebx                         ; EAX = button, EDX = x inside its step
    cmp eax, WM_WORKSPACES
    jae .done
    cmp edx, TB_WS_W
    jae .done
    inc eax
    call wm_switch_workspace
.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; desktop_dock_click: ECX,EDX = a click -> CF=1 if it was on the dock (an
; icon click opens, focuses or minimizes that app)
; ------------------------------------------------------------------------------
desktop_dock_click:
    call desktop_in_dock
    jnc .ret
    push rax
    push rbx
    push rdx
    mov eax, ecx
    sub eax, DOCK_X + DOCK_PAD
    jb .done
    xor edx, edx
    mov ebx, DOCK_ICON + DOCK_GAP
    div ebx
    cmp eax, DOCK_APPS
    jae .done
    cmp edx, DOCK_ICON
    jae .done
    shl eax, 4
    lea rbx, [desktop_dock_apps]
    mov rax, [rbx + rax]            ; window id
    call desktop_toggle_app
.done:
    pop rdx
    pop rbx
    pop rax
    stc
.ret:
    ret

; desktop_in_dock: ECX,EDX = a point -> CF=1 if it is on the dock
desktop_in_dock:
    cmp ecx, DOCK_X
    jl .no
    cmp ecx, DOCK_X + DOCK_W
    jge .no
    cmp edx, DOCK_Y
    jl .no
    cmp edx, DOCK_Y + DOCK_H
    jge .no
    stc
    ret
.no:
    clc
    ret

; desktop_toggle_app: AL = window. Closed/minimized -> open; on another
; workspace -> go there; focused -> minimize; otherwise focus it.
desktop_toggle_app:
    push rbx
    push rdx
    call wm_window_ptr
    mov dl, [rbx + WIN_STATE]
    cmp dl, WIN_STATE_CLOSED
    je .open
    cmp dl, WIN_STATE_MINIMIZED
    je .open
    mov dl, [rbx + WIN_WS]
    cmp dl, [wm_active_ws]
    jne .open                       ; wm_open switches to its workspace
    cmp al, [wm_focus]
    jne .open
    call wm_minimize
    jmp .done
.open:
    call wm_open
.done:
    pop rdx
    pop rbx
    ret
