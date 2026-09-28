; ==============================================================================
; Antigravity OS - Window Manager & Desktop Event Loop
; ------------------------------------------------------------------------------
; Windows live in one table (wm_windows) of WIN_SIZE-byte structs; everything
; here is generic over that table. An app plugs in by providing callbacks:
;
;   WIN_DRAW   draw the client area. In: RBX = window, ECX,EDX = client x,y,
;              ESI,R8D = client w,h. The clip rectangle is already the client
;              area, so apps may draw anywhere.
;   WIN_KEY    key press. In: RBX = window, AX = key event. Out: CF=1 if used.
;   WIN_MOUSE  mouse in the client area. In: RBX = window, AL = WM_MOUSE_PRESS /
;              WM_MOUSE_DRAG / WM_MOUSE_RELEASE, ECX,EDX = position relative
;              to the client area (can be outside it while dragging).
;              AL = WM_MOUSE_WHEEL: ECX = wheel notches (positive = down), to
;              the window under the pointer.
;   WIN_OPEN   called when the window is opened from the closed state (or 0).
;   WIN_TICK   called ~4x per second while visible. Out: CF=1 = redraw needed.
; Callbacks may clobber every register except RSP; the WM saves them.
;
; Rendering: any state change sets gui_dirty; the loop then recomposes the
; whole frame into the RAM back buffer and copies it to the screen
; (gui_redraw). Mouse movement alone only moves the pointer.
;
; Workspaces work like i3: every window belongs to workspace 1-4, only the
; active workspace is shown. F1-F4 / Alt+1-4 switch, Shift+F1-F4 moves the
; focused window.
; ==============================================================================

[bits 64]

; --- window ids (index into wm_windows) ---------------------------------------
WIN_SYSMON              equ 0
WIN_TERM                equ 1
WIN_CANVAS              equ 2
WIN_BROWSER             equ 3
WIN_COUNT               equ 4
WIN_NONE                equ 0xFF

WM_WORKSPACES           equ 4

; --- window states -------------------------------------------------------------
WIN_STATE_CLOSED        equ 0
WIN_STATE_OPEN          equ 1
WIN_STATE_MINIMIZED     equ 2
WIN_STATE_MAXIMIZED     equ 3

; --- window struct --------------------------------------------------------------
WIN_STATE               equ 0       ; db
WIN_WS                  equ 1       ; db workspace 1-4
WIN_DEF_WS              equ 2       ; db
WIN_X                   equ 4       ; dd  frame position and size
WIN_Y                   equ 8
WIN_W                   equ 12
WIN_H                   equ 16
WIN_SAVE_X              equ 20      ; dd  geometry before maximize
WIN_SAVE_Y              equ 24
WIN_SAVE_W              equ 28
WIN_SAVE_H              equ 32
WIN_DEF_X               equ 36      ; dd  default geometry
WIN_DEF_Y               equ 40
WIN_DEF_W               equ 44
WIN_DEF_H               equ 48
WIN_TITLE               equ 56      ; dq -> title string
WIN_LABEL               equ 64      ; dq -> short name
WIN_DRAW                equ 72      ; dq callbacks (see above)
WIN_KEY                 equ 80
WIN_MOUSE               equ 88
WIN_OPEN                equ 96
WIN_TICK                equ 104
WIN_SIZE                equ 128

; --- layout ------------------------------------------------------------------------
TASKBAR_H               equ 36
FOOTER_Y                equ 742
FOOTER_H                equ GFX_HEIGHT - FOOTER_Y
TITLE_H                 equ 28
WIN_BORDER              equ 2
WIN_MIN_W               equ 240
WIN_MIN_H               equ 140
WM_MAX_X                equ 20
WM_MAX_Y                equ 45
WM_MAX_W                equ 984
WM_MAX_H                equ 690

; --- hit test results ------------------------------------------------------------
HIT_NONE                equ 0
HIT_CLOSE               equ 1
HIT_MINIMIZE            equ 2
HIT_MAXIMIZE            equ 3
HIT_RESIZE              equ 4
HIT_TITLE               equ 5
HIT_CLIENT              equ 6
HIT_WS_BADGE            equ 7

WM_MOUSE_PRESS          equ 1
WM_MOUSE_DRAG           equ 2
WM_MOUSE_RELEASE        equ 3
WM_MOUSE_WHEEL          equ 4

DRAG_NONE               equ 0
DRAG_MOVE               equ 1
DRAG_RESIZE             equ 2

GUI_TICK_MS             equ 250
GUI_IDLE_REDRAW_MS      equ 40

; WINDOW ws, x, y, w, h, title, label, draw, key, mouse, open, tick
%macro WINDOW 12
    db WIN_STATE_OPEN, %1, %1, 0
    dd %2, %3, %4, %5               ; current
    dd %2, %3, %4, %5               ; saved (maximize)
    dd %2, %3, %4, %5               ; defaults
    dd 0
    dq %6, %7, %8, %9, %10, %11, %12
    times WIN_SIZE - 112 db 0
%endmacro

section .data
align 16
wm_windows:
    WINDOW 4, 60, 52, 904, 670, sysmon_title,   sysmon_label,   sysmon_draw,   sysmon_key,   0,              0,            sysmon_tick
    WINDOW 1, 60, 52, 904, 670, term_title,     term_label,     term_draw,     term_key,     0,              0,            0
    WINDOW 3, 60, 52, 904, 670, canvas_title,   canvas_label,   canvas_draw,   canvas_key,   canvas_mouse,   0,            0
    WINDOW 2, 60, 52, 904, 670, browser_page_title, browser_label, browser_draw, browser_key, browser_mouse, browser_open, 0

wm_zorder:              db WIN_SYSMON, WIN_CANVAS, WIN_BROWSER, WIN_TERM   ; bottom -> top
wm_zorder_default:      db WIN_SYSMON, WIN_CANVAS, WIN_BROWSER, WIN_TERM
wm_active_ws:           db 1
wm_focus:               db WIN_TERM
gui_running:            db 0
gui_dirty:              db 1
gui_exit_request:       db 0
gui_launch_window:      db WIN_NONE
gui_prev_buttons:       db 0
gui_capture:            db WIN_NONE     ; window receiving drag/release events
gui_drag_mode:          db DRAG_NONE
gui_drag_win:           db 0
align 4
gui_last_x:             dd -1
gui_last_y:             dd -1
gui_drag_mouse_x:       dd 0
gui_drag_mouse_y:       dd 0
gui_drag_orig_x:        dd 0
gui_drag_orig_y:        dd 0
gui_drag_orig_w:        dd 0
gui_drag_orig_h:        dd 0
gui_last_second:        dd 0
align 8
gui_last_redraw:        dq 0
gui_last_tick:          dq 0

section .rodata
klog_gui_start:         db "gui: started", 0
klog_gui_stop:          db "gui: stopped", 0
klog_gui_press:         db "gui: press ", 0
klog_wm_ws:             db "wm: workspace ", 0
klog_wm_open:           db "wm: open ", 0
klog_wm_close:          db "wm: close ", 0
klog_wm_min:            db "wm: minimize ", 0
klog_wm_max:            db "wm: maximize ", 0
klog_wm_restore:        db "wm: restore ", 0
klog_wm_focus:          db "wm: focus ", 0
klog_wm_move:           db "wm: moved to workspace ", 0

section .text
; ==============================================================================
; Desktop session
; ==============================================================================

; ------------------------------------------------------------------------------
; gui_run: start the desktop and run its event loop until Esc / Exit, then
; restore the text console. Opens gui_launch_window first if set.
; ------------------------------------------------------------------------------
gui_run:
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

    call bga_enable
    jc .out
    call mouse_init
    mov byte [gui_running], 1
    mov byte [gui_exit_request], 0
    mov byte [gui_prev_buttons], 0
    mov byte [gui_capture], WIN_NONE
    mov byte [gui_drag_mode], DRAG_NONE
    lea rsi, [klog_gui_start]
    call klog

    call gfx_reset_clip
    call desktop_render_wallpaper
    call canvas_init
    call wm_reset_layout
    call term_reset                 ; clears the terminal, prints the prompt
    call browser_init               ; home page, or the URL from `browser <url>`

    mov al, [gui_launch_window]
    mov byte [gui_launch_window], WIN_NONE
    cmp al, WIN_NONE
    je .loop_start
    call wm_open
.loop_start:
    mov byte [gui_dirty], 1

.loop:
    call net_poll
    call gui_handle_mouse
.keys:
    call key_get
    jnc .keys_done
    call gui_handle_key
    jmp .keys
.keys_done:
    cmp byte [gui_exit_request], 0
    jne .exit
    call gui_ticks
    call browser_js_tick            ; page timers (setTimeout, animation frames)
    cmp byte [gui_dirty], 0
    je .no_redraw
    call gui_redraw
    jmp .sleep
.no_redraw:
    call gui_update_cursor
.sleep:
    hlt                             ; the 1 kHz timer wakes us up
    jmp .loop

.exit:
    mov byte [gui_running], 0
    call mouse_disable
    call vga_restore_text_mode      ; also turns the BGA off
    mov qword [shell_input_len], 0  ; drop any half-typed terminal line
    mov byte [shell_input], 0
    lea rsi, [klog_gui_stop]
    call klog
.out:
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

; gui_mark_dirty: request a full redraw
gui_mark_dirty:
    mov byte [gui_dirty], 1
    ret

; ------------------------------------------------------------------------------
; gui_redraw: compose the whole desktop into the back buffer and show it
; ------------------------------------------------------------------------------
gui_redraw:
    push rax
    push rcx
    push rdx
    call wm_compose
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    mov [gui_last_x], ecx
    mov [gui_last_y], edx
    call gfx_present
    mov byte [gui_dirty], 0
    mov rax, [timer_ticks]
    mov [gui_last_redraw], rax
    pop rdx
    pop rcx
    pop rax
    ret

; gui_update_cursor: move the pointer if the mouse moved since the last frame
gui_update_cursor:
    push rcx
    push rdx
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    cmp ecx, [gui_last_x]
    jne .move
    cmp edx, [gui_last_y]
    je .done
.move:
    mov [gui_last_x], ecx
    mov [gui_last_y], edx
    call gfx_cursor_move
.done:
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------------------------
; gui_idle: keep the desktop alive while a long shell command runs inside the
; terminal (called through con_idle). Moves the pointer and redraws at most
; every GUI_IDLE_REDRAW_MS; clicks are swallowed until the command finishes.
; ------------------------------------------------------------------------------
gui_idle:
    cmp byte [gui_running], 0
    je .ret
    push rax
    call mouse_poll
    mov al, [mouse_buttons]
    and al, 1
    mov [gui_prev_buttons], al
    cmp byte [gui_dirty], 0
    je .cursor
    mov rax, [timer_ticks]
    sub rax, [gui_last_redraw]
    cmp rax, TICKS(GUI_IDLE_REDRAW_MS)
    jb .cursor
    call gui_redraw
    pop rax
    ret
.cursor:
    call gui_update_cursor
    pop rax
.ret:
    ret

; gui_ticks: periodic work (window tick callbacks, the footer clock)
gui_ticks:
    push rax
    push rbx
    push rcx
    mov rax, [timer_ticks]
    sub rax, [gui_last_tick]
    cmp rax, TICKS(GUI_TICK_MS)
    jb .done
    mov rax, [timer_ticks]
    mov [gui_last_tick], rax

    call timer_uptime_seconds       ; footer clock changes once per second
    cmp eax, [gui_last_second]
    je .windows
    mov [gui_last_second], eax
    mov byte [gui_dirty], 1
.windows:
    xor ecx, ecx
.loop:
    mov eax, ecx
    call wm_window_ptr
    call wm_is_visible
    jnc .next
    cmp qword [rbx + WIN_TICK], 0
    je .next
    push rcx
    call wm_call_tick
    pop rcx
    jnc .next
    mov byte [gui_dirty], 1
.next:
    inc ecx
    cmp ecx, WIN_COUNT
    jb .loop
.done:
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; Input
; ==============================================================================

; gui_handle_key: AX = key event
gui_handle_key:
    push rax
    push rbx
    push rcx
    cmp al, 27                      ; Esc: back to the text console
    jne .not_esc
    mov byte [gui_exit_request], 1
    jmp .done
.not_esc:
    ; F1-F4: switch workspace (Shift: move the focused window there)
    test al, al
    jnz .mod_digits
    cmp ah, SC_F1
    jb .mod_digits
    cmp ah, SC_F4
    ja .mod_digits
    mov al, ah
    sub al, SC_F1 - 1
    jmp .workspace_key
.mod_digits:
    ; Alt+1..4 / Ctrl+1..4 (i3's Mod+1..4)
    cmp byte [kbd_alt], 0
    jne .check_digit
    cmp byte [kbd_ctrl], 0
    je .to_window
.check_digit:
    cmp ah, 0x02                    ; scancodes of '1'..'4'
    jb .to_window
    cmp ah, 0x05
    ja .to_window
    mov al, ah
    dec al
.workspace_key:
    cmp byte [kbd_shift], 0
    je .switch
    mov bl, [wm_focus]
    cmp bl, WIN_NONE
    je .done
    call wm_move_to_workspace
    jmp .done
.switch:
    call wm_switch_workspace
    jmp .done

.to_window:
    movzx ecx, byte [wm_focus]
    cmp ecx, WIN_NONE
    je .nudge
    push rax
    mov eax, ecx
    call wm_window_ptr
    pop rax
    cmp qword [rbx + WIN_KEY], 0
    je .nudge
    call wm_call_key
    jnc .nudge
    mov byte [gui_dirty], 1
    jmp .done
.nudge:
    ; Unused arrow keys move the mouse pointer
    test al, al
    jnz .done
    cmp ah, SC_UP
    je .up
    cmp ah, SC_DOWN
    je .down
    cmp ah, SC_LEFT
    je .left
    cmp ah, SC_RIGHT
    je .right
    jmp .done
.up:
    sub dword [mouse_y], 12
    jns .done
    mov dword [mouse_y], 0
    jmp .done
.down:
    add dword [mouse_y], 12
    cmp dword [mouse_y], GFX_HEIGHT - 1
    jle .done
    mov dword [mouse_y], GFX_HEIGHT - 1
    jmp .done
.left:
    sub dword [mouse_x], 12
    jns .done
    mov dword [mouse_x], 0
    jmp .done
.right:
    add dword [mouse_x], 12
    cmp dword [mouse_x], GFX_WIDTH - 1
    jle .done
    mov dword [mouse_x], GFX_WIDTH - 1
.done:
    pop rcx
    pop rbx
    pop rax
    ret

; gui_handle_mouse: poll the mouse and turn button edges into events
gui_handle_mouse:
    push rax
    push rbx
    push rcx
    push rdx
    call mouse_poll
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    xor eax, eax
    xchg eax, [mouse_wheel]
    test eax, eax
    jz .no_wheel
    call gui_mouse_wheel
.no_wheel:
    mov al, [mouse_buttons]
    and al, 1
    mov ah, [gui_prev_buttons]
    mov [gui_prev_buttons], al
    test al, al
    jz .released
    test ah, ah
    jnz .held
    call gui_mouse_press
    jmp .done
.held:
    cmp ecx, [gui_last_x]
    jne .moved
    cmp edx, [gui_last_y]
    je .done
.moved:
    cmp byte [gui_drag_mode], DRAG_NONE
    je .drag_client
    call gui_drag_update
    jmp .done
.drag_client:
    mov al, WM_MOUSE_DRAG
    call gui_send_mouse
    jmp .done
.released:
    test ah, ah
    jz .done
    mov byte [gui_drag_mode], DRAG_NONE
    mov al, WM_MOUSE_RELEASE
    call gui_send_mouse
    mov byte [gui_capture], WIN_NONE
.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gui_mouse_wheel: EAX = notches, ECX,EDX = pointer -> WM_MOUSE_WHEEL to the
; client area under the pointer
gui_mouse_wheel:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    mov r8d, eax
    cmp edx, TASKBAR_H
    jb .done
    cmp edx, FOOTER_Y
    jae .done
    call wm_hit_test                ; AL = window, AH = hit code
    cmp al, WIN_NONE
    je .done
    cmp ah, HIT_CLIENT
    jne .done
    movzx eax, al
    call wm_window_ptr
    cmp qword [rbx + WIN_MOUSE], 0
    je .done
    mov al, WM_MOUSE_WHEEL
    mov ecx, r8d
    call wm_call_mouse
    mov byte [gui_dirty], 1
.done:
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gui_send_mouse: AL = event, ECX,EDX = screen position -> captured window
gui_send_mouse:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    movzx ebx, byte [gui_capture]
    cmp ebx, WIN_NONE
    je .done
    push rax
    mov eax, ebx
    call wm_window_ptr
    pop rax
    cmp qword [rbx + WIN_MOUSE], 0
    je .done
    push rcx
    push rdx
    push rax
    call wm_client_rect             ; ECX,EDX = client origin
    mov esi, ecx
    mov r8d, edx
    pop rax
    pop rdx
    pop rcx
    sub ecx, esi
    sub edx, r8d
    call wm_call_mouse
    mov byte [gui_dirty], 1
.done:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gui_mouse_press: left button went down at ECX,EDX
gui_mouse_press:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov eax, ecx                    ; "[klog] gui: press x*10000+y" for tests
    imul eax, 10000
    add eax, edx
    lea rsi, [klog_gui_press]
    call klog_dec
    pop rsi
    cmp edx, TASKBAR_H
    jae .windows
    call desktop_taskbar_click
    jmp .done
.windows:
    cmp edx, FOOTER_Y               ; the footer covers the bottom of windows
    jae .done
    call wm_hit_test                ; AL = window, AH = hit code
    cmp al, WIN_NONE
    je .done
    push rax
    call wm_raise
    pop rax
    movzx ebx, ah
    cmp ebx, HIT_CLOSE
    je .close
    cmp ebx, HIT_MINIMIZE
    je .minimize
    cmp ebx, HIT_MAXIMIZE
    je .maximize
    cmp ebx, HIT_WS_BADGE
    je .badge
    cmp ebx, HIT_TITLE
    je .move
    cmp ebx, HIT_RESIZE
    je .resize
    ; client area: capture the mouse and forward the press
    mov [gui_capture], al
    mov al, WM_MOUSE_PRESS
    call gui_send_mouse
    jmp .done
.close:
    call wm_close
    jmp .done
.minimize:
    call wm_minimize
    jmp .done
.maximize:
    call wm_toggle_maximize
    jmp .done
.badge:
    call wm_cycle_window_ws
    jmp .done
.move:
    mov bl, DRAG_MOVE
    jmp .start_drag
.resize:
    mov bl, DRAG_RESIZE
.start_drag:
    push rdi
    mov dil, bl                     ; DIL = drag mode
    call wm_window_ptr              ; RBX = window AL
    cmp byte [rbx + WIN_STATE], WIN_STATE_MAXIMIZED
    je .drag_done                   ; maximized windows stay put
    mov [gui_drag_mode], dil
    mov [gui_drag_win], al
    mov [gui_drag_mouse_x], ecx
    mov [gui_drag_mouse_y], edx
    mov eax, [rbx + WIN_X]
    mov [gui_drag_orig_x], eax
    mov eax, [rbx + WIN_Y]
    mov [gui_drag_orig_y], eax
    mov eax, [rbx + WIN_W]
    mov [gui_drag_orig_w], eax
    mov eax, [rbx + WIN_H]
    mov [gui_drag_orig_h], eax
.drag_done:
    pop rdi
.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gui_drag_update: move/resize the dragged window to follow the mouse (ECX,EDX)
gui_drag_update:
    push rax
    push rbx
    push rcx
    push rdx
    movzx eax, byte [gui_drag_win]
    call wm_window_ptr
    sub ecx, [gui_drag_mouse_x]     ; ECX,EDX = mouse delta
    sub edx, [gui_drag_mouse_y]
    cmp byte [gui_drag_mode], DRAG_RESIZE
    je .resize

    mov eax, [gui_drag_orig_x]
    add eax, ecx
    cmp eax, -200                   ; keep part of the window reachable
    jge .x_min
    mov eax, -200
.x_min:
    cmp eax, GFX_WIDTH - 64
    jle .x_max
    mov eax, GFX_WIDTH - 64
.x_max:
    mov [rbx + WIN_X], eax
    mov eax, [gui_drag_orig_y]
    add eax, edx
    cmp eax, TASKBAR_H
    jge .y_min
    mov eax, TASKBAR_H
.y_min:
    cmp eax, FOOTER_Y - TITLE_H
    jle .y_max
    mov eax, FOOTER_Y - TITLE_H
.y_max:
    mov [rbx + WIN_Y], eax
    jmp .dirty

.resize:
    mov eax, [gui_drag_orig_w]
    add eax, ecx
    cmp eax, WIN_MIN_W
    jge .w_min
    mov eax, WIN_MIN_W
.w_min:
    mov ecx, GFX_WIDTH
    sub ecx, [rbx + WIN_X]
    cmp ecx, WIN_MIN_W
    jge .w_room
    mov ecx, WIN_MIN_W
.w_room:
    cmp eax, ecx
    jle .w_max
    mov eax, ecx
.w_max:
    mov [rbx + WIN_W], eax
    mov eax, [gui_drag_orig_h]
    add eax, edx
    cmp eax, WIN_MIN_H
    jge .h_min
    mov eax, WIN_MIN_H
.h_min:
    mov ecx, FOOTER_Y
    sub ecx, [rbx + WIN_Y]
    cmp ecx, WIN_MIN_H
    jge .h_room
    mov ecx, WIN_MIN_H
.h_room:
    cmp eax, ecx
    jle .h_max
    mov eax, ecx
.h_max:
    mov [rbx + WIN_H], eax
.dirty:
    mov byte [gui_dirty], 1
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; Window operations (AL = window id unless noted). All mark the desktop dirty.
; ==============================================================================

; wm_window_ptr: EAX = window id -> RBX = window struct
wm_window_ptr:
    push rax
    movzx eax, al
    imul eax, WIN_SIZE
    lea rbx, [wm_windows]
    add rbx, rax
    pop rax
    ret

; wm_is_visible: RBX = window -> CF=1 if it is drawn on the active workspace
wm_is_visible:
    push rax
    mov al, [rbx + WIN_STATE]
    cmp al, WIN_STATE_OPEN
    je .check_ws
    cmp al, WIN_STATE_MAXIMIZED
    jne .no
.check_ws:
    mov al, [rbx + WIN_WS]
    cmp al, [wm_active_ws]
    jne .no
    pop rax
    stc
    ret
.no:
    pop rax
    clc
    ret

; wm_client_rect: RBX = window -> ECX,EDX = client x,y  ESI,R8D = client w,h
wm_client_rect:
    mov ecx, [rbx + WIN_X]
    add ecx, WIN_BORDER
    mov edx, [rbx + WIN_Y]
    add edx, TITLE_H
    mov esi, [rbx + WIN_W]
    sub esi, WIN_BORDER * 2
    mov r8d, [rbx + WIN_H]
    sub r8d, TITLE_H + WIN_BORDER
    ret

; wm_raise: put window AL on top of the stacking order and focus it
wm_raise:
    push rax
    push rcx
    push rdx
    push rsi
    lea rsi, [wm_zorder]
    xor ecx, ecx
.find:
    cmp [rsi + rcx], al
    je .found
    inc ecx
    cmp ecx, WIN_COUNT
    jb .find
    jmp .set_focus
.found:
    inc ecx                         ; shift everything above it down one slot
.shift:
    cmp ecx, WIN_COUNT
    jae .place
    mov dl, [rsi + rcx]
    mov [rsi + rcx - 1], dl
    inc ecx
    jmp .shift
.place:
    mov [rsi + WIN_COUNT - 1], al
.set_focus:
    cmp [wm_focus], al
    je .same
    mov [wm_focus], al
    push rbx
    push rdi
    call wm_window_ptr
    mov rdi, [rbx + WIN_LABEL]
    lea rsi, [klog_wm_focus]
    call klog2
    pop rdi
    pop rbx
.same:
    mov byte [gui_dirty], 1
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; wm_pick_focus: focus the topmost visible window (or none)
wm_pick_focus:
    push rax
    push rbx
    push rcx
    push rsi
    lea rsi, [wm_zorder]
    mov ecx, WIN_COUNT
.loop:
    dec ecx
    js .none
    movzx eax, byte [rsi + rcx]
    call wm_window_ptr
    call wm_is_visible
    jnc .loop
    mov [wm_focus], al
    jmp .done
.none:
    mov byte [wm_focus], WIN_NONE
.done:
    mov byte [gui_dirty], 1
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; wm_log: RSI = message prefix, RBX = window -> "[klog] <prefix><label>"
wm_log:
    push rdi
    mov rdi, [rbx + WIN_LABEL]
    call klog2
    pop rdi
    ret

; wm_open: open window AL (restoring or unhiding it), switch to its workspace
; and focus it
wm_open:
    push rax
    push rbx
    push rsi
    call wm_window_ptr
    mov ah, [rbx + WIN_STATE]
    cmp ah, WIN_STATE_CLOSED
    jne .not_closed
    call wm_reset_geometry
    mov ah, [wm_active_ws]
    mov [rbx + WIN_WS], ah
    mov byte [rbx + WIN_STATE], WIN_STATE_OPEN
    cmp qword [rbx + WIN_OPEN], 0
    je .opened
    call wm_call_open
    jmp .opened
.not_closed:
    cmp ah, WIN_STATE_MINIMIZED
    jne .opened
    mov byte [rbx + WIN_STATE], WIN_STATE_OPEN
.opened:
    mov ah, [rbx + WIN_WS]
    mov [wm_active_ws], ah
    lea rsi, [klog_wm_open]
    call wm_log
    call wm_raise
    pop rsi
    pop rbx
    pop rax
    ret

; wm_close: close window AL
wm_close:
    push rbx
    push rsi
    call wm_window_ptr
    mov byte [rbx + WIN_STATE], WIN_STATE_CLOSED
    lea rsi, [klog_wm_close]
    call wm_log
    call wm_pick_focus
    pop rsi
    pop rbx
    ret

; wm_minimize: hide window AL (taskbar pills bring it back)
wm_minimize:
    push rbx
    push rsi
    call wm_window_ptr
    mov byte [rbx + WIN_STATE], WIN_STATE_MINIMIZED
    lea rsi, [klog_wm_min]
    call wm_log
    call wm_pick_focus
    pop rsi
    pop rbx
    ret

; wm_toggle_maximize: maximize window AL, or restore its previous geometry
wm_toggle_maximize:
    push rax
    push rbx
    push rsi
    call wm_window_ptr
    cmp byte [rbx + WIN_STATE], WIN_STATE_MAXIMIZED
    je .restore
    mov eax, [rbx + WIN_X]
    mov [rbx + WIN_SAVE_X], eax
    mov eax, [rbx + WIN_Y]
    mov [rbx + WIN_SAVE_Y], eax
    mov eax, [rbx + WIN_W]
    mov [rbx + WIN_SAVE_W], eax
    mov eax, [rbx + WIN_H]
    mov [rbx + WIN_SAVE_H], eax
    mov dword [rbx + WIN_X], WM_MAX_X
    mov dword [rbx + WIN_Y], WM_MAX_Y
    mov dword [rbx + WIN_W], WM_MAX_W
    mov dword [rbx + WIN_H], WM_MAX_H
    mov byte [rbx + WIN_STATE], WIN_STATE_MAXIMIZED
    lea rsi, [klog_wm_max]
    jmp .log
.restore:
    mov eax, [rbx + WIN_SAVE_X]
    mov [rbx + WIN_X], eax
    mov eax, [rbx + WIN_SAVE_Y]
    mov [rbx + WIN_Y], eax
    mov eax, [rbx + WIN_SAVE_W]
    mov [rbx + WIN_W], eax
    mov eax, [rbx + WIN_SAVE_H]
    mov [rbx + WIN_H], eax
    mov byte [rbx + WIN_STATE], WIN_STATE_OPEN
    lea rsi, [klog_wm_restore]
.log:
    call wm_log
    mov byte [gui_dirty], 1
    pop rsi
    pop rbx
    pop rax
    ret

; wm_reset_geometry: RBX = window -> default position and size
wm_reset_geometry:
    push rax
    mov eax, [rbx + WIN_DEF_X]
    mov [rbx + WIN_X], eax
    mov eax, [rbx + WIN_DEF_Y]
    mov [rbx + WIN_Y], eax
    mov eax, [rbx + WIN_DEF_W]
    mov [rbx + WIN_W], eax
    mov eax, [rbx + WIN_DEF_H]
    mov [rbx + WIN_H], eax
    pop rax
    ret

; wm_switch_workspace: AL = workspace 1-4
wm_switch_workspace:
    cmp al, 1
    jb .ret
    cmp al, WM_WORKSPACES
    ja .ret
    push rax
    push rsi
    mov [wm_active_ws], al
    call wm_pick_focus
    movzx eax, al
    lea rsi, [klog_wm_ws]
    call klog_dec
    pop rsi
    pop rax
.ret:
    ret

; wm_move_to_workspace: AL = workspace 1-4, BL = window. Follows the window.
wm_move_to_workspace:
    cmp al, 1
    jb .ret
    cmp al, WM_WORKSPACES
    ja .ret
    push rax
    push rbx
    push rsi
    push rax
    mov al, bl
    call wm_window_ptr
    pop rax
    mov [rbx + WIN_WS], al
    mov [wm_active_ws], al
    movzx eax, al
    lea rsi, [klog_wm_move]
    call klog_dec
    mov rax, [rsp + 8]              ; saved RBX: BL = window id
    call wm_raise
    pop rsi
    pop rbx
    pop rax
.ret:
    ret

; wm_cycle_window_ws: send window AL to the next workspace (title bar badge)
wm_cycle_window_ws:
    push rax
    push rbx
    call wm_window_ptr
    mov al, [rbx + WIN_WS]
    inc al
    cmp al, WM_WORKSPACES
    jbe .ok
    mov al, 1
.ok:
    mov [rbx + WIN_WS], al
    call wm_pick_focus
    pop rbx
    pop rax
    ret

; wm_reset_layout: every window open on its default workspace and geometry
wm_reset_layout:
    push rax
    push rbx
    push rcx
    xor ecx, ecx
.loop:
    mov eax, ecx
    call wm_window_ptr
    mov byte [rbx + WIN_STATE], WIN_STATE_OPEN
    mov al, [rbx + WIN_DEF_WS]
    mov [rbx + WIN_WS], al
    call wm_reset_geometry
    inc ecx
    cmp ecx, WIN_COUNT
    jb .loop
    mov eax, [wm_zorder_default]
    mov [wm_zorder], eax
    mov byte [wm_active_ws], 1
    mov byte [wm_focus], WIN_TERM
    mov byte [gui_dirty], 1
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; wm_hit_test: ECX,EDX = screen point -> AL = window (WIN_NONE if none),
; AH = HIT_* code. Tests from the top of the stacking order down.
; ------------------------------------------------------------------------------
wm_hit_test:
    push rbx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    lea rsi, [wm_zorder]
    mov edi, WIN_COUNT
.loop:
    dec edi
    js .miss
    movzx eax, byte [rsi + rdi]
    call wm_window_ptr
    call wm_is_visible
    jnc .loop
    mov r8d, [rbx + WIN_X]
    mov r9d, [rbx + WIN_Y]
    cmp ecx, r8d
    jl .loop
    cmp edx, r9d
    jl .loop
    mov r10d, r8d
    add r10d, [rbx + WIN_W]
    cmp ecx, r10d
    jge .loop
    mov r10d, r9d
    add r10d, [rbx + WIN_H]
    cmp edx, r10d
    jge .loop

    ; Inside window EAX. Title-bar buttons (y+5 .. y+24)
    mov r10d, edx
    sub r10d, r9d                   ; r10 = y within window
    mov edi, ecx
    sub edi, r8d                    ; edi = x within window
    cmp r10d, 5
    jl .not_button
    cmp r10d, 24
    jg .not_button
    mov ah, HIT_CLOSE
    cmp edi, 8
    jl .not_button
    cmp edi, 24
    jle .hit
    mov ah, HIT_MINIMIZE
    cmp edi, 39
    jle .hit
    mov ah, HIT_MAXIMIZE
    cmp edi, 56
    jle .hit
.not_button:
    cmp byte [rbx + WIN_STATE], WIN_STATE_MAXIMIZED
    je .title_or_client
    ; Resize: bottom-right 20x20 corner, 6 px right edge, 6 px bottom edge
    mov ah, HIT_RESIZE
    mov r8d, [rbx + WIN_W]
    mov r9d, [rbx + WIN_H]
    lea esi, [r8d - 20]
    cmp edi, esi
    jl .edges
    lea esi, [r9d - 20]
    cmp r10d, esi
    jge .hit
.edges:
    lea esi, [r8d - 6]
    cmp edi, esi
    jl .bottom_edge
    cmp r10d, TITLE_H
    jge .hit
.bottom_edge:
    lea esi, [r9d - 6]
    cmp r10d, esi
    jge .hit
.title_or_client:
    mov ah, HIT_CLIENT
    cmp r10d, TITLE_H
    jge .hit
    mov ah, HIT_TITLE
    mov r8d, [rbx + WIN_W]
    cmp r8d, 140                    ; narrow windows have no badge
    jl .hit
    lea esi, [r8d - 58]
    cmp edi, esi
    jl .hit
    lea esi, [r8d - 12]
    cmp edi, esi
    jg .hit
    mov ah, HIT_WS_BADGE
.hit:
    jmp .done
.miss:
    mov al, WIN_NONE
    mov ah, HIT_NONE
.done:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbx
    ret

; ==============================================================================
; Callback trampolines: save everything, call the app, restore everything.
; The CF result of key/tick callbacks is passed back.
; ==============================================================================
%macro WM_SAVE 0
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
%endmacro
%macro WM_RESTORE 0
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
%endmacro

wm_call_key:                        ; RBX = window, AX = key -> CF
    WM_SAVE
    call [rbx + WIN_KEY]
    WM_RESTORE
    ret

wm_call_mouse:                      ; RBX = window, AL = event, ECX,EDX
    WM_SAVE
    call [rbx + WIN_MOUSE]
    WM_RESTORE
    ret

wm_call_open:                       ; RBX = window
    WM_SAVE
    call [rbx + WIN_OPEN]
    WM_RESTORE
    ret

wm_call_tick:                       ; RBX = window -> CF
    WM_SAVE
    call [rbx + WIN_TICK]
    WM_RESTORE
    ret

wm_call_draw:                       ; RBX = window (clip already set)
    WM_SAVE
    call wm_client_rect
    call [rbx + WIN_DRAW]
    WM_RESTORE
    ret

; ==============================================================================
; Drawing
; ==============================================================================

; wm_compose: draw the complete desktop into the back buffer
wm_compose:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r12

    mov qword [gfx_target], GUI_BACKBUFFER_ADDR
    call gfx_reset_clip
    mov rsi, GUI_WALLPAPER_ADDR
    call gfx_copy_frame

    ; Windows, bottom to top, clipped to the area between the two bars
    xor ecx, ecx
    mov edx, TASKBAR_H
    mov esi, GFX_WIDTH
    mov r8d, FOOTER_Y - TASKBAR_H
    call gfx_push_clip
    xor r12d, r12d
.loop:
    lea rax, [wm_zorder]
    movzx eax, byte [rax + r12]
    call wm_window_ptr
    call wm_is_visible
    jnc .next
    call wm_draw_window
.next:
    inc r12d
    cmp r12d, WIN_COUNT
    jb .loop
    call gfx_pop_clip

    call desktop_draw_taskbar
    call desktop_draw_footer

    pop r12
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; wm_draw_window: RBX = window, EAX = its id
wm_draw_window:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    call wm_draw_frame
    call wm_client_rect
    call gfx_push_clip
    call wm_call_draw
    call gfx_pop_clip
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; wm_draw_frame: RBX = window, EAX = its id. Shadow, border, title bar,
; traffic-light buttons, title, workspace badge and resize grip.
wm_draw_frame:
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

    xor r13d, r13d                  ; r13 = 1 if focused
    cmp al, [wm_focus]
    jne .unfocused
    mov r13d, 1
.unfocused:
    mov r9d, [rbx + WIN_X]
    mov r10d, [rbx + WIN_Y]
    mov r11d, [rbx + WIN_W]
    mov r12d, [rbx + WIN_H]

    lea ecx, [r9d + 6]              ; drop shadow
    lea edx, [r10d + 6]
    mov esi, r11d
    mov r8d, r12d
    mov eax, THEME_SHADOW
    call gfx_fill_rect

    mov ecx, r9d                    ; body
    mov edx, r10d
    mov eax, THEME_WIN_BODY
    call gfx_fill_rect

    mov r8d, TITLE_H                ; title bar
    mov eax, THEME_PANEL
    test r13d, r13d
    jz .title_fill
    mov eax, THEME_TITLE_ACTIVE
.title_fill:
    call gfx_fill_rect

    mov edi, THEME_BORDER           ; border colour for accent line + outline
    test r13d, r13d
    jz .have_border
    mov edi, THEME_ACCENT
.have_border:
    lea edx, [r10d + TITLE_H - 1]
    mov r8d, 1
    mov eax, edi
    call gfx_fill_rect
    mov edx, r10d
    mov r8d, r12d
    call gfx_draw_rect

    mov edx, r10d                   ; close / minimize / maximize dots
    add edx, 9
    mov esi, 10
    mov r8d, 10
    lea ecx, [r9d + 12]
    mov eax, THEME_RED
    call gfx_fill_rect
    lea ecx, [r9d + 27]
    mov eax, THEME_YELLOW
    call gfx_fill_rect
    lea ecx, [r9d + 42]
    mov eax, THEME_GREEN
    call gfx_fill_rect

    ; Title text, clipped so it never runs under the badge
    mov ecx, r9d
    mov edx, r10d
    lea esi, [r11d - 64]
    mov r8d, TITLE_H
    call gfx_push_clip
    lea ecx, [r9d + 62]
    lea edx, [r10d + 10]
    mov rsi, [rbx + WIN_TITLE]
    mov eax, THEME_TEXT_MUTED
    test r13d, r13d
    jz .title_text
    mov eax, THEME_TEXT
.title_text:
    push rbx
    mov ebx, -1
    call gfx_print_string
    pop rbx
    call gfx_pop_clip

    ; Workspace badge "WS n"
    cmp r11d, 140
    jl .no_badge
    lea ecx, [r9d + r11d - 58]
    lea edx, [r10d + 5]
    mov esi, 46
    mov r8d, 18
    mov eax, THEME_BADGE_BG
    call gfx_fill_rect
    mov eax, THEME_SKY
    call gfx_draw_rect
    add ecx, 7
    add edx, 5
    push rbx
    mov al, [rbx + WIN_WS]
    add al, '0'
    mov [wm_badge_digit], al
    lea rsi, [wm_badge_text]
    mov eax, THEME_CYAN
    mov ebx, -1
    call gfx_print_string
    pop rbx
.no_badge:

    ; Resize grip (not for maximized windows)
    cmp byte [rbx + WIN_STATE], WIN_STATE_MAXIMIZED
    je .done
    mov eax, THEME_BORDER
    test r13d, r13d
    jz .grip
    mov eax, THEME_CYAN
.grip:
    mov esi, 2
    mov r8d, 2
    lea ecx, [r9d + r11d - 5]
    lea edx, [r10d + r12d - 5]
    call gfx_fill_rect
    sub ecx, 4
    call gfx_fill_rect
    sub ecx, 4
    call gfx_fill_rect
    add ecx, 4
    sub edx, 4
    call gfx_fill_rect
    add ecx, 4
    call gfx_fill_rect
    sub edx, 4
    call gfx_fill_rect
.done:
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

section .data
wm_badge_text:          db "WS "
wm_badge_digit:         db "1", 0
