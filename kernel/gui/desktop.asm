; ==============================================================================
; Antigravity OS - Desktop chrome: wallpaper, taskbar and footer
; ------------------------------------------------------------------------------
; Taskbar (y 0-35), left to right:
;   [AGY OS 64]         reset every window to its default workspace/position
;   [1:TERM]..[4:SYS]   workspace pills (bright = active, cyan text = occupied)
;   [+Term] [+Web] ...  app pills: open / focus / minimize that window
;   [i3 [WS] n]         active workspace
;   [IP] [RAM] [Exit]   live status badges, Exit returns to the text console
; ==============================================================================

[bits 64]

TB_Y                    equ 6
TB_H                    equ 23
TB_TEXT_Y               equ 14
TB_START_X              equ 6
TB_START_W              equ 84
TB_WS_X                 equ 96       ; first workspace pill
TB_WS_W                 equ 58
TB_WS_STEP              equ 62
TB_APP_X                equ 350      ; first app pill
TB_APP_W                equ 50
TB_APP_STEP             equ 54
TB_STATUS_X             equ 570
TB_STATUS_W             equ 100
TB_IP_X                 equ 678
TB_IP_W                 equ 124
TB_RAM_X                equ 808
TB_RAM_W                equ 100
TB_EXIT_X               equ 914
TB_EXIT_W               equ 104

section .rodata
str_start_btn:          db "AGY OS 64", 0
str_ws_1:               db "1:TERM", 0
str_ws_2:               db "2:WEB", 0
str_ws_3:               db "3:DEV", 0
str_ws_4:               db "4:SYS", 0
str_app_term:           db "+Term", 0
str_app_web:            db "+Web", 0
str_app_dev:            db "+Dev", 0
str_app_sys:            db "+Sys", 0
str_ws_status:          db "i3 [WS] ", 0
str_badge_ip:           db "IP: ", 0
str_badge_no_net:       db "IP: offline", 0
str_badge_ram:          db "RAM: ", 0
str_badge_mb:           db " MB", 0
str_badge_exit:         db "Exit (Esc)", 0
str_footer_left:        db " F1-F4 / Alt+1-4: workspace | Shift+F1-F4: move window | Esc: text console", 0
str_footer_up:          db "up ", 0

align 8
desktop_ws_labels:      dq str_ws_1, str_ws_2, str_ws_3, str_ws_4
; app pills: label, window id
desktop_app_pills:
    dq str_app_term, WIN_TERM
    dq str_app_web,  WIN_BROWSER
    dq str_app_dev,  WIN_CANVAS
    dq str_app_sys,  WIN_SYSMON
DESKTOP_APP_PILLS       equ 4

section .bss
desktop_text_buf:       resb 64

section .text
; ------------------------------------------------------------------------------
; desktop_render_wallpaper: pre-render the background into GUI_WALLPAPER_ADDR
; ------------------------------------------------------------------------------
desktop_render_wallpaper:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    mov qword [gfx_target], GUI_WALLPAPER_ADDR
    call gfx_reset_clip
    xor ecx, ecx
    xor edx, edx
    mov esi, GFX_WIDTH
    mov r8d, GFX_HEIGHT
    mov r9d, THEME_DESK_TOP
    mov r10d, THEME_DESK_BOTTOM
    call gfx_draw_gradient_v
    mov qword [gfx_target], GUI_BACKBUFFER_ADDR
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; desktop_pill: ECX = x, ESI = width, EAX = fill, EDI = border, R9D = text
; colour, R10 = label
desktop_pill:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov edx, TB_Y
    mov r8d, TB_H
    call gfx_fill_rect
    mov eax, edi
    call gfx_draw_rect
    add ecx, 6
    mov edx, TB_TEXT_Y
    mov rsi, r10
    mov eax, r9d
    mov ebx, -1
    call gfx_print_string
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; desktop_draw_taskbar
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

    xor ecx, ecx
    xor edx, edx
    mov esi, GFX_WIDTH
    mov r8d, TASKBAR_H - 1
    mov eax, THEME_PANEL
    call gfx_fill_rect
    mov edx, TASKBAR_H - 1
    mov r8d, 1
    mov eax, THEME_BORDER
    call gfx_fill_rect

    ; Start pill
    mov ecx, TB_START_X
    mov esi, TB_START_W
    mov eax, THEME_ACCENT
    mov edi, THEME_ACCENT
    mov r9d, THEME_TEXT
    lea r10, [str_start_btn]
    call desktop_pill

    ; Workspace pills
    xor r11d, r11d                  ; workspace index 0-3
.ws_loop:
    mov ecx, r11d
    imul ecx, TB_WS_STEP
    add ecx, TB_WS_X
    mov esi, TB_WS_W
    lea rax, [desktop_ws_labels]
    mov r10, [rax + r11 * 8]
    lea eax, [r11d + 1]
    cmp al, [wm_active_ws]
    jne .ws_inactive
    mov eax, THEME_ACCENT
    mov edi, THEME_SKY
    mov r9d, THEME_TEXT
    jmp .ws_draw
.ws_inactive:
    call desktop_ws_occupied        ; AL = workspace -> CF=1 if it has windows
    mov eax, THEME_PANEL_DARK
    mov edi, THEME_PANEL
    mov r9d, THEME_TEXT_MUTED
    jnc .ws_draw
    mov eax, THEME_PANEL
    mov edi, THEME_BORDER_MUTED
    mov r9d, THEME_CYAN
.ws_draw:
    call desktop_pill
    inc r11d
    cmp r11d, WM_WORKSPACES
    jb .ws_loop

    ; App pills
    xor r11d, r11d
.app_loop:
    mov ecx, r11d
    imul ecx, TB_APP_STEP
    add ecx, TB_APP_X
    mov esi, TB_APP_W
    mov rax, r11
    shl rax, 4
    lea rdx, [desktop_app_pills]
    mov r10, [rdx + rax]
    mov rax, [rdx + rax + 8]        ; window id
    call wm_window_ptr
    mov dl, [rbx + WIN_STATE]
    cmp dl, WIN_STATE_CLOSED
    je .app_dim
    cmp dl, WIN_STATE_MINIMIZED
    je .app_dim
    cmp al, [wm_focus]
    jne .app_open
    mov eax, THEME_GREEN_MID
    mov edi, THEME_GREEN_LIGHT
    mov r9d, THEME_TEXT
    jmp .app_draw
.app_open:
    mov eax, THEME_NAVY
    mov edi, THEME_SKY
    mov r9d, THEME_TEXT
    jmp .app_draw
.app_dim:
    mov eax, THEME_PANEL_DARK
    mov edi, THEME_BORDER
    mov r9d, THEME_TEXT_MUTED
.app_draw:
    call desktop_pill
    inc r11d
    cmp r11d, DESKTOP_APP_PILLS
    jb .app_loop

    ; Active workspace status
    lea rdi, [desktop_text_buf]
    lea rsi, [str_ws_status]
    call fmt_str
    movzx eax, byte [wm_active_ws]
    call fmt_dec
    mov ecx, TB_STATUS_X
    mov esi, TB_STATUS_W
    mov eax, THEME_PANEL_DARK
    mov edi, THEME_BORDER
    mov r9d, THEME_CYAN
    lea r10, [desktop_text_buf]
    call desktop_pill

    ; IP badge
    lea rdi, [desktop_text_buf]
    lea rsi, [str_badge_no_net]
    cmp byte [net_present], 1
    jne .ip_text
    lea rsi, [str_badge_ip]
    call fmt_str
    lea rsi, [net_ip]
    call fmt_ip
    jmp .ip_draw
.ip_text:
    call fmt_str
.ip_draw:
    mov ecx, TB_IP_X
    mov esi, TB_IP_W
    mov eax, THEME_GREEN_DARK
    mov edi, THEME_GREEN
    mov r9d, THEME_GREEN_PALE
    lea r10, [desktop_text_buf]
    call desktop_pill

    ; RAM badge
    lea rdi, [desktop_text_buf]
    lea rsi, [str_badge_ram]
    call fmt_str
    call memory_total_mb
    call fmt_dec
    lea rsi, [str_badge_mb]
    call fmt_str
    mov ecx, TB_RAM_X
    mov esi, TB_RAM_W
    mov eax, THEME_NAVY
    mov edi, THEME_SKY
    mov r9d, THEME_SKY_PALE
    lea r10, [desktop_text_buf]
    call desktop_pill

    ; Exit
    mov ecx, TB_EXIT_X
    mov esi, TB_EXIT_W
    mov eax, THEME_RED_DARK
    mov edi, THEME_RED
    mov r9d, THEME_TEXT
    lea r10, [str_badge_exit]
    call desktop_pill

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
; desktop_draw_footer: key hints on the left, uptime on the right
; ------------------------------------------------------------------------------
desktop_draw_footer:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    xor ecx, ecx
    mov edx, FOOTER_Y
    mov esi, GFX_WIDTH
    mov r8d, FOOTER_H
    mov eax, THEME_FOOTER
    call gfx_fill_rect
    mov r8d, 1
    mov eax, THEME_PANEL
    call gfx_fill_rect
    mov ecx, 8
    mov edx, FOOTER_Y + 9
    lea rsi, [str_footer_left]
    mov eax, THEME_TEXT_MUTED
    mov ebx, -1
    call gfx_print_string

    lea rdi, [desktop_text_buf]
    lea rsi, [str_footer_up]
    call fmt_str
    call fmt_uptime
    lea rsi, [desktop_text_buf]
    call gfx_text_width
    mov ecx, GFX_WIDTH - 12
    sub ecx, eax
    mov edx, FOOTER_Y + 9
    mov eax, THEME_CYAN
    call gfx_print_string
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; desktop_taskbar_click: ECX = x of a click inside the taskbar
; ------------------------------------------------------------------------------
desktop_taskbar_click:
    push rax
    push rbx
    push rcx
    push rdx
    cmp ecx, TB_EXIT_X
    jb .not_exit
    mov byte [gui_exit_request], 1
    jmp .done
.not_exit:
    cmp ecx, TB_START_X
    jb .done
    cmp ecx, TB_START_X + TB_START_W
    jae .not_start
    call wm_reset_layout
    jmp .done
.not_start:
    ; workspace pills
    mov eax, ecx
    sub eax, TB_WS_X
    jb .done
    xor edx, edx
    mov ebx, TB_WS_STEP
    div ebx                         ; EAX = pill index, EDX = x inside the step
    cmp eax, WM_WORKSPACES
    jae .apps
    cmp edx, TB_WS_W
    jae .done
    inc eax
    call wm_switch_workspace
    jmp .done
.apps:
    mov eax, ecx
    sub eax, TB_APP_X
    jb .done
    xor edx, edx
    mov ebx, TB_APP_STEP
    div ebx
    cmp eax, DESKTOP_APP_PILLS
    jae .done
    cmp edx, TB_APP_W
    jae .done
    shl eax, 4
    lea rbx, [desktop_app_pills]
    mov rax, [rbx + rax + 8]        ; window id
    call desktop_toggle_app
.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
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
