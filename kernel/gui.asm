; ==============================================================================
; Antigravity OS - 64-bit Graphical User Interface & Desktop Environment
; Interactive Window Manager (Open/Close/Min/Max) & Live Interactive Terminal
; 1024x768x32bpp TrueColor Framebuffer, PS/2 Mouse & Hardware Restoration
; ==============================================================================

[bits 64]

; GUI Palette & Theme Colors
GUI_CLR_DESK_TOP        equ 0x000F172A   ; Deep Obsidian Slate
GUI_CLR_DESK_BOT        equ 0x00020617   ; Midnight Abyss Black
GUI_CLR_TASKBAR         equ 0x001E293B   ; Slate Taskbar
GUI_CLR_TASKBAR_BORDER  equ 0x00334155   ; Taskbar Border
GUI_CLR_WIN_BORDER      equ 0x00334155   ; Window Outline Border
GUI_CLR_WIN_BORDER_ACT  equ 0x000284C7   ; Active Window Border Accent
GUI_CLR_WIN_TITLE       equ 0x001E293B   ; Titlebar Inactive
GUI_CLR_WIN_TITLE_ACT   equ 0x0024344D   ; Titlebar Active (Glowing Navy)
GUI_CLR_WIN_SHADOW      equ 0x00050811   ; Window Drop Shadow
GUI_CLR_WIN_BODY        equ 0x000F172A   ; Window Interior Slate
GUI_CLR_TERM_BG         equ 0x000A0E17   ; Deep Terminal Background
GUI_CLR_CANVAS_BG       equ 0x000D1117   ; Canvas Dark Background
GUI_CLR_CYAN_ACCENT     equ 0x000284C7   ; Electric Blue / Cyan Accent
GUI_CLR_CYAN_GLOW       equ 0x0000F0FF   ; Glowing Cyber Cyan

; Window States
WIN_STATE_CLOSED        equ 0
WIN_STATE_OPEN          equ 1
WIN_STATE_MINIMIZED     equ 2
WIN_STATE_MAXIMIZED     equ 3

; Window Geometry Constants
WIN0_DEF_X              equ 60
WIN0_DEF_Y              equ 52
WIN0_DEF_W              equ 904
WIN0_DEF_H              equ 670

WIN1_DEF_X              equ 60
WIN1_DEF_Y              equ 52
WIN1_DEF_W              equ 904
WIN1_DEF_H              equ 670

WIN2_DEF_X              equ 60
WIN2_DEF_Y              equ 52
WIN2_DEF_W              equ 904
WIN2_DEF_H              equ 670

WIN_MAX_X               equ 20
WIN_MAX_Y               equ 45
WIN_MAX_W               equ 984
WIN_MAX_H               equ 685

; i3 / Linux Window Manager Workspaces (1:TERM, 2:WEB, 3:DEV, 4:SYS)
gui_active_ws:          db 1             ; Active Workspace: 1..4
win0_ws:                db 4             ; System Monitor -> WS 4
win1_ws:                db 1             ; Terminal Console -> WS 1
win2_ws:                db 3             ; Cyber Canvas -> WS 3
win3_ws:                db 2             ; CyberSurf Web Browser -> WS 2
HIT_CODE_WS_BADGE       equ 7            ; Titlebar Workspace Badge Hit Code

; GUI Global State Variables
gui_cur_x:              dd 512
gui_cur_y:              dd 384
gui_active_color:       dd 0x0000F0FF    ; Default drawing color = Electric Cyan
win_focused:            db 1             ; 0: System, 1: Terminal, 2: Canvas, 3: Browser (0xFF = None)

; Window 0: System Monitor
win0_state:             db WIN_STATE_OPEN
win0_x:                 dd WIN0_DEF_X
win0_y:                 dd WIN0_DEF_Y
win0_w:                 dd WIN0_DEF_W
win0_h:                 dd WIN0_DEF_H

; Window 1: Terminal Console
win1_state:             db WIN_STATE_OPEN
win1_x:                 dd WIN1_DEF_X
win1_y:                 dd WIN1_DEF_Y
win1_w:                 dd WIN1_DEF_W
win1_h:                 dd WIN1_DEF_H

; Window 2: Cyber Canvas
win2_state:             db WIN_STATE_OPEN
win2_x:                 dd WIN2_DEF_X
win2_y:                 dd WIN2_DEF_Y
win2_w:                 dd WIN2_DEF_W
win2_h:                 dd WIN2_DEF_H

; Window Drag & Resize State
DRAG_MODE_NONE          equ 0
DRAG_MODE_MOVE          equ 1
DRAG_MODE_RESIZE        equ 2

WIN_MIN_W               equ 240
WIN_MIN_H               equ 140

drag_mode:              db DRAG_MODE_NONE
drag_win:               db 0             ; 0: Win0, 1: Win1, 2: Win2, 3: Win3
drag_start_mouse_x:     dd 0
drag_start_mouse_y:     dd 0
drag_orig_pos_x:        dd 0
drag_orig_pos_y:        dd 0
drag_orig_dim_w:        dd 0
drag_orig_dim_h:        dd 0

; Interactive Terminal State (10 lines x 56 chars)
GUI_TERM_MAX_LINES      equ 10
GUI_TERM_LINE_LEN       equ 56
gui_term_line_count:    dd 6
gui_term_lines:         times (GUI_TERM_MAX_LINES * GUI_TERM_LINE_LEN) db 0
term_input_buf:         times 64 db 0
term_input_len:         dd 0

; Palette Colors (8 swatches)
gui_swatches:
    dd 0x00000000   ; 0: Black
    dd 0x00FFFFFF   ; 1: White
    dd 0x0000F0FF   ; 2: Electric Cyan
    dd 0x00EF4444   ; 3: Red
    dd 0x0010B981   ; 4: Emerald Green
    dd 0x00F59E0B   ; 5: Amber Yellow
    dd 0x00EC4899   ; 6: Neon Magenta
    dd 0x003B82F6   ; 7: Vivid Blue

; ------------------------------------------------------------------------------
; gui_run: Launches 1024x768x32bpp GUI Desktop Environment
; Returns when user presses Esc, 'q', or clicks [Exit]
; ------------------------------------------------------------------------------
gui_run:
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

    ; 1. Ensure BGA hardware driver is initialized
    cmp byte [bga_available], 1
    je .bga_ready
    call bga_init

.bga_ready:
    ; 2. Switch BGA to 1024x768x32bpp TrueColor Framebuffer Mode
    call bga_set_graphics_mode

    ; 3. Initialize PS/2 Mouse Controller
    call mouse_init

    ; 4. Set default window states & positions on workspaces
    mov byte [gui_active_ws], 1
    mov byte [win0_ws], 4                ; WS 4: System Monitor
    mov byte [win1_ws], 1                ; WS 1: Terminal Console
    mov byte [win2_ws], 3                ; WS 3: Cyber Canvas
    mov byte [win3_ws], 2                ; WS 2: Web Browser

    mov byte [win0_state], WIN_STATE_OPEN
    mov dword [win0_x], WIN0_DEF_X
    mov dword [win0_y], WIN0_DEF_Y
    mov dword [win0_w], WIN0_DEF_W
    mov dword [win0_h], WIN0_DEF_H

    mov byte [win1_state], WIN_STATE_OPEN
    mov dword [win1_x], WIN1_DEF_X
    mov dword [win1_y], WIN1_DEF_Y
    mov dword [win1_w], WIN1_DEF_W
    mov dword [win1_h], WIN1_DEF_H

    mov byte [win2_state], WIN_STATE_OPEN
    mov dword [win2_x], WIN2_DEF_X
    mov dword [win2_y], WIN2_DEF_Y
    mov dword [win2_w], WIN2_DEF_W
    mov dword [win2_h], WIN2_DEF_H

    mov byte [win3_state], WIN_STATE_OPEN
    mov dword [win3_x], WIN3_DEF_X
    mov dword [win3_y], WIN3_DEF_Y
    mov dword [win3_w], WIN3_DEF_W
    mov dword [win3_h], WIN3_DEF_H

    cmp byte [win_focused], 3
    je .browser_focused_launch
    mov byte [gui_active_ws], 1
    mov byte [win_focused], 1             ; Focus Terminal by default on WS 1!
    jmp .focus_setup_done
.browser_focused_launch:
    mov byte [gui_active_ws], 2           ; Focus Browser on WS 2!
    mov byte [win_focused], 3
.focus_setup_done:

    mov dword [mouse_x], 512
    mov dword [mouse_y], 384
    mov dword [gui_cur_x], 512
    mov dword [gui_cur_y], 384
    mov dword [gui_active_color], 0x0000F0FF
    mov byte [drag_mode], DRAG_MODE_NONE

    ; 5. Initialize Terminal history lines if first launch
    call gui_term_init

    ; Initialize Browser subsystem
    call browser_init

    ; 6. Render complete desktop UI layout (double-buffered, flicker-free)
    call gui_flip_redraw_desktop

; ------------------------------------------------------------------------------
; GUI Main Event Loop
; ------------------------------------------------------------------------------
gui_main_loop:
    ; 1. Poll RTL8139 Network Card for background packets (Pings, ARP, TCP)
    call net_poll

    ; 2. Poll PS/2 Mouse Controller
    call mouse_poll

    ; Direct keyboard port poll for instantaneous key capture
    in al, 0x64
    test al, 0x01
    jz .no_direct_key
    test al, 0x20               ; Bit 5 set = mouse data
    jnz .no_direct_key
    in al, 0x60
    call keyboard_process_scancode
.no_direct_key:

    ; 3. Check for Keyboard Events
    mov al, [gui_last_key]
    mov bl, [gui_last_scancode]
    mov byte [gui_last_key], 0
    mov byte [gui_last_scancode], 0

    ; Check for Global Exit (Esc = ASCII 27 or scancode 0x01)
    cmp al, 27
    je .exit_gui
    cmp bl, 0x01
    je .exit_gui

    ; --------------------------------------------------------------------------
    ; i3 / Linux Window Manager Workspace Shortcuts
    ; --------------------------------------------------------------------------
    ; 1. Check Function Keys F1 .. F4 (scancodes 0x3B .. 0x3E)
    cmp bl, 0x3B
    jb .chk_mod_ws
    cmp bl, 0x3E
    ja .chk_mod_ws

    mov al, bl
    sub al, 0x3A                ; 0x3B -> 1, 0x3C -> 2, 0x3D -> 3, 0x3E -> 4
    cmp byte [shift_state], 1
    je .move_win_fkey
    call gui_switch_workspace
    jmp .loop_delay
.move_win_fkey:
    movzx ebx, byte [win_focused]
    call gui_move_window_to_ws
    jmp .loop_delay

.chk_mod_ws:
    ; 2. Check Alt + 1..4 or Ctrl + 1..4 (i3 Mod+1..4)
    cmp byte [alt_state], 1
    je .handle_mod_ws
    cmp byte [ctrl_state], 1
    je .handle_mod_ws
    jmp .chk_arrows

.handle_mod_ws:
    cmp bl, 0x02                ; Scancode 0x02 = '1'
    jb .chk_arrows
    cmp bl, 0x05                ; Scancode 0x05 = '4'
    ja .chk_arrows
    mov al, bl
    sub al, 0x01                ; 0x02 -> 1, 0x03 -> 2, 0x04 -> 3, 0x05 -> 4
    cmp byte [shift_state], 1
    je .move_win_mod
    call gui_switch_workspace
    jmp .loop_delay
.move_win_mod:
    movzx ebx, byte [win_focused]
    call gui_move_window_to_ws
    jmp .loop_delay

.chk_arrows:
    ; Check Arrow keys for cursor nudging (available in all focus modes)
    cmp bl, 0x48                ; Up Arrow
    je .nudge_up
    cmp bl, 0x50                ; Down Arrow
    je .nudge_down
    cmp bl, 0x4B                ; Left Arrow
    je .nudge_left
    cmp bl, 0x4D                ; Right Arrow
    je .nudge_right

    ; --------------------------------------------------------------------------
    ; Dispatch Keystrokes Based on Active Focused Window
    ; --------------------------------------------------------------------------
    cmp byte [win_focused], 1    ; Is Terminal Focused?
    je .handle_term_key

    cmp byte [win_focused], 2    ; Is Canvas Focused?
    je .handle_canvas_key

    cmp byte [win_focused], 3    ; Is Browser Focused?
    je .handle_browser_key

    ; System Monitor focused: check 'q' / 'Q' for exit
    cmp al, 'q'
    je .exit_gui
    cmp al, 'Q'
    je .exit_gui
    jmp .chk_mouse

.handle_term_key:
    test al, al
    jz .chk_mouse

    ; Enter Key -> Execute command in GUI Terminal
    cmp al, 0x0D
    je .term_enter

    ; Backspace Key -> Delete character in GUI Terminal
    cmp al, 0x08
    je .term_backspace

    ; Printable ASCII Character (32 .. 126)
    cmp al, 32
    jb .chk_mouse
    cmp al, 126
    ja .chk_mouse
    call gui_term_handle_char
    jmp .chk_mouse

.term_enter:
    call gui_term_handle_enter
    jmp .chk_mouse

.term_backspace:
    call gui_term_handle_backspace
    jmp .chk_mouse

.handle_browser_key:
    test al, al
    jz .chk_mouse

    ; Enter Key -> Navigate to URL
    cmp al, 0x0D
    je .browser_enter

    ; Backspace Key -> Delete character in URL
    cmp al, 0x08
    je .browser_backspace

    ; Printable ASCII Character (32 .. 126)
    cmp al, 32
    jb .chk_mouse
    cmp al, 126
    ja .chk_mouse
    call browser_handle_char
    jmp .chk_mouse

.browser_enter:
    call browser_handle_enter
    jmp .chk_mouse

.browser_backspace:
    call browser_handle_backspace
    jmp .chk_mouse

.handle_canvas_key:
    ; Canvas actions
    cmp al, 'q'
    je .exit_gui
    cmp al, 'Q'
    je .exit_gui
    cmp al, 'c'
    je .do_clear_canvas
    cmp al, 'C'
    je .do_clear_canvas
    cmp al, 'd'
    je .do_demo_art
    cmp al, 'D'
    je .do_demo_art

    ; Check Palette number keys '1' .. '8'
    cmp al, '1'
    jb .chk_canvas_draw_btn
    cmp al, '8'
    ja .chk_canvas_draw_btn
    sub al, '1'
    movzx eax, al
    mov edx, [gui_swatches + rax * 4]
    mov [gui_active_color], edx
    call gfx_restore_cursor
    call gui_draw_palette_indicators
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    call gfx_draw_cursor
    jmp .chk_mouse

.chk_canvas_draw_btn:
    cmp al, ' '                 ; Space = Draw at cursor
    je .do_space_click
    cmp al, 0x0D
    je .do_space_click
    jmp .chk_mouse

.nudge_up:
    sub dword [mouse_y], 12
    cmp dword [mouse_y], 0
    jge .chk_mouse
    mov dword [mouse_y], 0
    jmp .chk_mouse

.nudge_down:
    add dword [mouse_y], 12
    cmp dword [mouse_y], 767
    jle .chk_mouse
    mov dword [mouse_y], 767
    jmp .chk_mouse

.nudge_left:
    sub dword [mouse_x], 12
    cmp dword [mouse_x], 0
    jge .chk_mouse
    mov dword [mouse_x], 0
    jmp .chk_mouse

.nudge_right:
    add dword [mouse_x], 12
    cmp dword [mouse_x], 1023
    jle .chk_mouse
    mov dword [mouse_x], 1023
    jmp .chk_mouse

.do_space_click:
    call gfx_restore_cursor
    call gui_handle_canvas_drag
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    call gfx_draw_cursor
    jmp .chk_mouse

.do_clear_canvas:
    call gfx_restore_cursor
    call gui_clear_canvas
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    call gfx_draw_cursor
    jmp .loop_delay

.do_demo_art:
    call gfx_restore_cursor
    call gui_draw_demo_art
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    call gfx_draw_cursor
    jmp .loop_delay

.chk_mouse:
    ; Check if mouse left button was released
    test byte [mouse_buttons], 0x01
    jnz .chk_active_drag
    mov byte [drag_mode], DRAG_MODE_NONE
    jmp .chk_cursor_move

.chk_active_drag:
    cmp byte [drag_mode], DRAG_MODE_NONE
    je .chk_cursor_move
    ; We are actively dragging or resizing a window!
    call gui_update_window_drag
    jmp .loop_delay

.chk_cursor_move:
    ; 4. Check if cursor position changed
    mov eax, [mouse_x]
    mov edx, [mouse_y]
    cmp eax, [gui_cur_x]
    jne .move_cursor
    cmp edx, [gui_cur_y]
    jne .move_cursor
    jmp .check_clicks

.move_cursor:
    ; Restore background under old cursor
    call gfx_restore_cursor
    mov eax, [mouse_x]
    mov edx, [mouse_y]
    mov [gui_cur_x], eax
    mov [gui_cur_y], edx

    ; Check if mouse button is held while moving inside canvas (Brush Dragging)
    test byte [mouse_buttons], 0x01
    jz .draw_new_cursor
    cmp byte [win2_state], WIN_STATE_OPEN
    jne .draw_new_cursor
    cmp byte [win_focused], 2    ; Only paint if Canvas is focused!
    jne .draw_new_cursor
    call gui_handle_canvas_drag

.draw_new_cursor:
    mov ecx, [gui_cur_x]
    mov edx, [gui_cur_y]
    call gfx_draw_cursor

.check_clicks:
    ; 5. Check Left Click Events
    test byte [mouse_buttons], 0x01
    jz .loop_delay
    cmp byte [drag_mode], DRAG_MODE_NONE
    jne .loop_delay

    ; Left button is down -> handle click target
    call gui_handle_click
    test eax, eax               ; If returns 1, exit requested
    jnz .exit_gui

.loop_delay:
    pause
    mov ecx, 1500
.wait_sub:
    dec ecx
    jnz .wait_sub
    jmp gui_main_loop

.exit_gui:
    ; Cleanly restore 80x25 text mode (Mode 03h)
    call bga_set_text_mode

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
; gui_handle_click: Dispatches click based on (mouse_x, mouse_y)
; Output: RAX = 1 if Exit GUI requested, 0 otherwise
; ------------------------------------------------------------------------------
gui_handle_click:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov ecx, [mouse_x]
    mov edx, [mouse_y]

    ; --------------------------------------------------------------------------
    ; 1. Check Top Taskbar (y: 0 .. 35)
    ; --------------------------------------------------------------------------
    cmp edx, 35
    ja .chk_windows

    ; Taskbar Exit Button (x: 900 .. 1015)
    cmp ecx, 900
    jb .chk_ws_pills
    cmp ecx, 1015
    ja .no_action
    mov rax, 1                  ; Exit GUI requested!
    jmp .done

.chk_ws_pills:
    ; WS 1: [1:TERM] (x: 84 .. 144)
    cmp ecx, 84
    jb .chk_tb_start
    cmp ecx, 144
    ja .chk_ws2
    mov al, 1
    call gui_switch_workspace
    xor rax, rax
    jmp .done

.chk_ws2:
    ; WS 2: [2:WEB] (x: 148 .. 208)
    cmp ecx, 148
    jb .chk_tb_start
    cmp ecx, 208
    ja .chk_ws3
    mov al, 2
    call gui_switch_workspace
    xor rax, rax
    jmp .done

.chk_ws3:
    ; WS 3: [3:DEV] (x: 212 .. 272)
    cmp ecx, 212
    jb .chk_tb_start
    cmp ecx, 272
    ja .chk_ws4
    mov al, 3
    call gui_switch_workspace
    xor rax, rax
    jmp .done

.chk_ws4:
    ; WS 4: [4:SYS] (x: 276 .. 336)
    cmp ecx, 276
    jb .chk_tb_start
    cmp ecx, 336
    ja .chk_tb_apps
    mov al, 4
    call gui_switch_workspace
    xor rax, rax
    jmp .done

.chk_tb_apps:
    ; App Toggle: [+Term] (x: 348 .. 400)
    cmp ecx, 348
    jb .chk_tb_start
    cmp ecx, 400
    ja .chk_tb_web
    mov al, [win1_ws]
    cmp al, [gui_active_ws]
    jne .switch_to_w1_ws
    ; On current workspace: toggle open/min/focus
    cmp byte [win1_state], WIN_STATE_CLOSED
    je .open_term
    cmp byte [win1_state], WIN_STATE_MINIMIZED
    je .open_term
    cmp byte [win_focused], 1
    je .min_term
    mov byte [win_focused], 1
    jmp .refresh_desktop
.switch_to_w1_ws:
    call gui_switch_workspace
    mov byte [win_focused], 1
    jmp .refresh_desktop
.open_term:
    mov byte [win1_state], WIN_STATE_OPEN
    mov al, [gui_active_ws]
    mov [win1_ws], al
    mov al, 1
    call gui_reset_win_def_geometry
    mov byte [win_focused], 1
    jmp .refresh_desktop
.min_term:
    mov byte [win1_state], WIN_STATE_MINIMIZED
    call gui_pick_next_focus
    jmp .refresh_desktop

.chk_tb_web:
    ; App Toggle: [+Web] (x: 404 .. 454)
    cmp ecx, 404
    jb .chk_tb_start
    cmp ecx, 454
    ja .chk_tb_canvas
    mov al, [win3_ws]
    cmp al, [gui_active_ws]
    jne .switch_to_w3_ws
    cmp byte [win3_state], WIN_STATE_CLOSED
    je .open_browser
    cmp byte [win3_state], WIN_STATE_MINIMIZED
    je .open_browser
    cmp byte [win_focused], 3
    je .min_browser
    mov byte [win_focused], 3
    jmp .refresh_desktop
.switch_to_w3_ws:
    call gui_switch_workspace
    mov byte [win_focused], 3
    jmp .refresh_desktop
.open_browser:
    mov byte [win3_state], WIN_STATE_OPEN
    mov al, [gui_active_ws]
    mov [win3_ws], al
    mov al, 3
    call gui_reset_win_def_geometry
    mov byte [win_focused], 3
    jmp .refresh_desktop
.min_browser:
    mov byte [win3_state], WIN_STATE_MINIMIZED
    call gui_pick_next_focus
    jmp .refresh_desktop

.chk_tb_canvas:
    ; App Toggle: [+Dev] (x: 458 .. 508)
    cmp ecx, 458
    jb .chk_tb_start
    cmp ecx, 508
    ja .chk_tb_sys
    mov al, [win2_ws]
    cmp al, [gui_active_ws]
    jne .switch_to_w2_ws
    cmp byte [win2_state], WIN_STATE_CLOSED
    je .open_canvas
    cmp byte [win2_state], WIN_STATE_MINIMIZED
    je .open_canvas
    cmp byte [win_focused], 2
    je .min_canvas
    mov byte [win_focused], 2
    jmp .refresh_desktop
.switch_to_w2_ws:
    call gui_switch_workspace
    mov byte [win_focused], 2
    jmp .refresh_desktop
.open_canvas:
    mov byte [win2_state], WIN_STATE_OPEN
    mov al, [gui_active_ws]
    mov [win2_ws], al
    mov al, 2
    call gui_reset_win_def_geometry
    mov byte [win_focused], 2
    jmp .refresh_desktop
.min_canvas:
    mov byte [win2_state], WIN_STATE_MINIMIZED
    call gui_pick_next_focus
    jmp .refresh_desktop

.chk_tb_sys:
    ; App Toggle: [+Sys] (x: 512 .. 562)
    cmp ecx, 512
    jb .chk_tb_start
    cmp ecx, 562
    ja .chk_tb_start
    mov al, [win0_ws]
    cmp al, [gui_active_ws]
    jne .switch_to_w0_ws
    cmp byte [win0_state], WIN_STATE_CLOSED
    je .open_sys
    cmp byte [win0_state], WIN_STATE_MINIMIZED
    je .open_sys
    cmp byte [win_focused], 0
    je .min_sys
    mov byte [win_focused], 0
    jmp .refresh_desktop
.switch_to_w0_ws:
    call gui_switch_workspace
    mov byte [win_focused], 0
    jmp .refresh_desktop
.open_sys:
    mov byte [win0_state], WIN_STATE_OPEN
    mov al, [gui_active_ws]
    mov [win0_ws], al
    mov al, 0
    call gui_reset_win_def_geometry
    mov byte [win_focused], 0
    jmp .refresh_desktop
.min_sys:
    mov byte [win0_state], WIN_STATE_MINIMIZED
    call gui_pick_next_focus
    jmp .refresh_desktop

.chk_tb_start:
    ; Start Button [AGY 64] (x: 6 .. 80)
    cmp ecx, 6
    jb .no_action
    cmp ecx, 80
    ja .no_action
    ; Reset windows to default workspaces & positions!
    mov byte [gui_active_ws], 1
    mov byte [win0_ws], 4
    mov byte [win1_ws], 1
    mov byte [win2_ws], 3
    mov byte [win3_ws], 2

    mov byte [win0_state], WIN_STATE_OPEN
    mov al, 0
    call gui_reset_win_def_geometry

    mov byte [win1_state], WIN_STATE_OPEN
    mov al, 1
    call gui_reset_win_def_geometry

    mov byte [win2_state], WIN_STATE_OPEN
    mov al, 2
    call gui_reset_win_def_geometry

    mov byte [win3_state], WIN_STATE_OPEN
    mov al, 3
    call gui_reset_win_def_geometry

    mov byte [win_focused], 1
    jmp .refresh_desktop

.refresh_desktop:
    call gui_flip_redraw_desktop
    ; Wait for button release to avoid rapid toggling
    call gui_wait_mouse_release
    xor rax, rax
    jmp .done

.refresh_desktop_no_wait:
    call gui_flip_redraw_desktop
    xor rax, rax
    jmp .done

; ------------------------------------------------------------------------------
; 2. Check Window Control Buttons, Resize Handle, Titlebar Drag & Bodies
; ------------------------------------------------------------------------------
.chk_windows:
    ; If a window is currently being moved or resized, do not process new clicks
    cmp byte [drag_mode], DRAG_MODE_NONE
    jne .no_action

    ; Hit test windows in Z-order!
    ; 1. Test FOCUSED window FIRST!
    movzx eax, byte [win_focused]
    mov ebx, eax                ; EBX = Focused Window ID
    mov al, bl
    call gui_hit_test_window
    test eax, eax
    jnz .dispatch_window_hit

    ; 2. Focused window missed. Test background open windows in reverse order (3, 2, 1, 0)
    cmp byte [win_focused], 3
    je .test_bg_w2
    mov ebx, 3
    mov al, 3
    call gui_hit_test_window
    test eax, eax
    jnz .dispatch_window_hit

.test_bg_w2:
    cmp byte [win_focused], 2
    je .test_bg_w1
    mov ebx, 2
    mov al, 2
    call gui_hit_test_window
    test eax, eax
    jnz .dispatch_window_hit

.test_bg_w1:
    cmp byte [win_focused], 1
    je .test_bg_w0
    mov ebx, 1
    mov al, 1
    call gui_hit_test_window
    test eax, eax
    jnz .dispatch_window_hit

.test_bg_w0:
    cmp byte [win_focused], 0
    je .no_action
    mov ebx, 0
    mov al, 0
    call gui_hit_test_window
    test eax, eax
    jz .no_action

.dispatch_window_hit:
    ; EBX = Window ID (0 .. 3)
    ; EAX = Hit Code:
    ;   1: Close button
    ;   2: Minimize button
    ;   3: Maximize button
    ;   4: Resize handle / borders
    ;   5: Titlebar / Move
    ;   6: Window Body
    mov [win_focused], bl       ; Bring clicked window to top!

    cmp eax, 1
    je .do_close_win
    cmp eax, 2
    je .do_min_win
    cmp eax, 3
    je .do_toggle_max_win
    cmp eax, 4
    je .start_resize_win
    cmp eax, 5
    je .start_move_win
    cmp eax, 6
    je .dispatch_body_click
    cmp eax, 7
    je .do_cycle_ws
    jmp .no_action

.do_cycle_ws:
    mov al, bl
    call gui_cycle_window_ws
    call gui_pick_next_focus
    jmp .refresh_desktop

.do_close_win:
    mov al, bl
    call gui_get_win_ptrs
    mov byte [r12], WIN_STATE_CLOSED
    mov al, bl
    call gui_reset_win_def_geometry
    call gui_pick_next_focus
    jmp .refresh_desktop

.do_min_win:
    mov al, bl
    call gui_get_win_ptrs
    mov byte [r12], WIN_STATE_MINIMIZED
    call gui_pick_next_focus
    jmp .refresh_desktop

.do_toggle_max_win:
    mov al, bl
    call gui_get_win_ptrs
    cmp byte [r12], WIN_STATE_MAXIMIZED
    je .restore_from_max
    mov byte [r12], WIN_STATE_MAXIMIZED
    mov dword [r8], WIN_MAX_X
    mov dword [r9], WIN_MAX_Y
    mov dword [r10], WIN_MAX_W
    mov dword [r11], WIN_MAX_H
    jmp .refresh_desktop
.restore_from_max:
    mov byte [r12], WIN_STATE_OPEN
    mov al, bl
    call gui_reset_win_def_geometry
    jmp .refresh_desktop

.start_resize_win:
    mov al, bl
    call gui_get_win_ptrs
    mov byte [drag_mode], DRAG_MODE_RESIZE
    mov [drag_win], bl
    mov eax, [mouse_x]
    mov [drag_start_mouse_x], eax
    mov eax, [mouse_y]
    mov [drag_start_mouse_y], eax
    mov eax, [r10]
    mov [drag_orig_dim_w], eax
    mov eax, [r11]
    mov [drag_orig_dim_h], eax
    jmp .refresh_desktop_no_wait

.start_move_win:
    mov al, bl
    call gui_get_win_ptrs
    mov byte [drag_mode], DRAG_MODE_MOVE
    mov [drag_win], bl
    mov eax, [mouse_x]
    mov [drag_start_mouse_x], eax
    mov eax, [mouse_y]
    mov [drag_start_mouse_y], eax
    mov eax, [r8]
    mov [drag_orig_pos_x], eax
    mov eax, [r9]
    mov [drag_orig_pos_y], eax
    jmp .refresh_desktop_no_wait

.dispatch_body_click:
    cmp bl, 0
    je .refresh_desktop_no_wait
    cmp bl, 1
    je .refresh_desktop_no_wait
    cmp bl, 2
    je .body_win2
    cmp bl, 3
    je .body_win3
    jmp .no_action

.body_win2:
    call gui_flip_redraw_desktop
    call gui_handle_canvas_body_click
    jmp .no_action

.body_win3:
    call gui_flip_redraw_desktop
    call browser_handle_click
    jmp .no_action

.no_action:
    xor rax, rax
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; gui_get_win_ptrs: Returns pointers to window AL state and geometry
; Input:  AL = Window ID (0 .. 3)
; Output: R8  = &winX_x, R9 = &winX_y, R10 = &winX_w, R11 = &winX_h, R12 = &winX_state
; ------------------------------------------------------------------------------
gui_get_win_ptrs:
    cmp al, 0
    jne .gwp_1
    lea r8, [win0_x]
    lea r9, [win0_y]
    lea r10, [win0_w]
    lea r11, [win0_h]
    lea r12, [win0_state]
    ret
.gwp_1:
    cmp al, 1
    jne .gwp_2
    lea r8, [win1_x]
    lea r9, [win1_y]
    lea r10, [win1_w]
    lea r11, [win1_h]
    lea r12, [win1_state]
    ret
.gwp_2:
    cmp al, 2
    jne .gwp_3
    lea r8, [win2_x]
    lea r9, [win2_y]
    lea r10, [win2_w]
    lea r11, [win2_h]
    lea r12, [win2_state]
    ret
.gwp_3:
    lea r8, [win3_x]
    lea r9, [win3_y]
    lea r10, [win3_w]
    lea r11, [win3_h]
    lea r12, [win3_state]
    ret

; ------------------------------------------------------------------------------
; gui_reset_win_def_geometry: Resets window AL geometry to defaults
; ------------------------------------------------------------------------------
gui_reset_win_def_geometry:
    push rax
    cmp al, 0
    jne .rst_w1
    mov dword [win0_x], WIN0_DEF_X
    mov dword [win0_y], WIN0_DEF_Y
    mov dword [win0_w], WIN0_DEF_W
    mov dword [win0_h], WIN0_DEF_H
    jmp .rst_fin
.rst_w1:
    cmp al, 1
    jne .rst_w2
    mov dword [win1_x], WIN1_DEF_X
    mov dword [win1_y], WIN1_DEF_Y
    mov dword [win1_w], WIN1_DEF_W
    mov dword [win1_h], WIN1_DEF_H
    jmp .rst_fin
.rst_w2:
    cmp al, 2
    jne .rst_w3
    mov dword [win2_x], WIN2_DEF_X
    mov dword [win2_y], WIN2_DEF_Y
    mov dword [win2_w], WIN2_DEF_W
    mov dword [win2_h], WIN2_DEF_H
    jmp .rst_fin
.rst_w3:
    mov dword [win3_x], WIN3_DEF_X
    mov dword [win3_y], WIN3_DEF_Y
    mov dword [win3_w], WIN3_DEF_W
    mov dword [win3_h], WIN3_DEF_H
.rst_fin:
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_get_win_ws_val: Returns workspace ID of window AL
; Input:  AL = Window ID (0 .. 3)
; Output: AL = Workspace ID (1 .. 4)
; ------------------------------------------------------------------------------
gui_get_win_ws_val:
    cmp al, 0
    jne .gww_1
    mov al, [win0_ws]
    ret
.gww_1:
    cmp al, 1
    jne .gww_2
    mov al, [win1_ws]
    ret
.gww_2:
    cmp al, 2
    jne .gww_3
    mov al, [win2_ws]
    ret
.gww_3:
    mov al, [win3_ws]
    ret

; ------------------------------------------------------------------------------
; gui_cycle_window_ws: Cycles window AL to next workspace (1 -> 2 -> 3 -> 4 -> 1)
; ------------------------------------------------------------------------------
gui_cycle_window_ws:
    cmp al, 0
    jne .gws_1
    inc byte [win0_ws]
    cmp byte [win0_ws], 4
    jbe .gws_done
    mov byte [win0_ws], 1
    ret
.gws_1:
    cmp al, 1
    jne .gws_2
    inc byte [win1_ws]
    cmp byte [win1_ws], 4
    jbe .gws_done
    mov byte [win1_ws], 1
    ret
.gws_2:
    cmp al, 2
    jne .gws_3
    inc byte [win2_ws]
    cmp byte [win2_ws], 4
    jbe .gws_done
    mov byte [win2_ws], 1
    ret
.gws_3:
    inc byte [win3_ws]
    cmp byte [win3_ws], 4
    jbe .gws_done
    mov byte [win3_ws], 1
.gws_done:
    ret

; ------------------------------------------------------------------------------
; gui_switch_workspace: Switches active workspace to AL (1 .. 4)
; ------------------------------------------------------------------------------
gui_switch_workspace:
    push rax
    push rbx
    cmp al, 1
    jb .sw_fin
    cmp al, 4
    ja .sw_fin
    mov [gui_active_ws], al
    call gui_pick_next_focus
    call gui_flip_redraw_desktop
.sw_fin:
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_move_window_to_ws: Moves window BL (0..3) to workspace AL (1..4)
; ------------------------------------------------------------------------------
gui_move_window_to_ws:
    push rax
    push rbx
    cmp al, 1
    jb .mv_fin
    cmp al, 4
    ja .mv_fin

    cmp bl, 0
    jne .mv_1
    mov [win0_ws], al
    jmp .mv_follow
.mv_1:
    cmp bl, 1
    jne .mv_2
    mov [win1_ws], al
    jmp .mv_follow
.mv_2:
    cmp bl, 2
    jne .mv_3
    mov [win2_ws], al
    jmp .mv_follow
.mv_3:
    cmp bl, 3
    jne .mv_fin
    mov [win3_ws], al

.mv_follow:
    mov [gui_active_ws], al      ; Follow window to target workspace!
    mov [win_focused], bl        ; Keep window focused!
    call gui_flip_redraw_desktop

.mv_fin:
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_pick_next_focus: Picks open window on current workspace to focus
; ------------------------------------------------------------------------------
gui_pick_next_focus:
    push rax
    push rbx
    mov bl, [gui_active_ws]

    ; Check if window currently focused is already open and on this workspace
    movzx eax, byte [win_focused]
    cmp al, 0
    jne .chk_cur_1
    cmp byte [win0_state], WIN_STATE_OPEN
    jne .find_open
    cmp byte [win0_ws], bl
    je .done_pick
.chk_cur_1:
    cmp al, 1
    jne .chk_cur_2
    cmp byte [win1_state], WIN_STATE_OPEN
    jne .find_open
    cmp byte [win1_ws], bl
    je .done_pick
.chk_cur_2:
    cmp al, 2
    jne .chk_cur_3
    cmp byte [win2_state], WIN_STATE_OPEN
    jne .find_open
    cmp byte [win2_ws], bl
    je .done_pick
.chk_cur_3:
    cmp al, 3
    jne .find_open
    cmp byte [win3_state], WIN_STATE_OPEN
    jne .find_open
    cmp byte [win3_ws], bl
    je .done_pick

.find_open:
    ; Pick open window on current workspace (prefer 1, 3, 2, 0)
    cmp byte [win1_ws], bl
    jne .try_w3
    cmp byte [win1_state], WIN_STATE_OPEN
    je .pick_1
.try_w3:
    cmp byte [win3_ws], bl
    jne .try_w2
    cmp byte [win3_state], WIN_STATE_OPEN
    je .pick_3
.try_w2:
    cmp byte [win2_ws], bl
    jne .try_w0
    cmp byte [win2_state], WIN_STATE_OPEN
    je .pick_2
.try_w0:
    cmp byte [win0_ws], bl
    jne .no_win
    cmp byte [win0_state], WIN_STATE_OPEN
    je .pick_0

.no_win:
    mov byte [win_focused], 0xFF
    jmp .done_pick

.pick_1:
    mov byte [win_focused], 1
    jmp .done_pick
.pick_3:
    mov byte [win_focused], 3
    jmp .done_pick
.pick_2:
    mov byte [win_focused], 2
    jmp .done_pick
.pick_0:
    mov byte [win_focused], 0

.done_pick:
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_hit_test_window: Hit tests window AL at (mouse_x, mouse_y)
; Input:  AL  = Window ID (0 .. 3)
; Output: EAX = Hit code:
;         0 = Outside window
;         1 = Close Button (Red)
;         2 = Minimize Button (Yellow)
;         3 = Maximize Button (Green)
;         4 = Resize Handle (Bottom-Right / Borders)
;         5 = Titlebar (Move / Drag)
;         6 = Window Body
; ------------------------------------------------------------------------------
gui_hit_test_window:
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

    call gui_get_win_ptrs

    ; Check if window is open or maximized
    cmp byte [r12], WIN_STATE_CLOSED
    je .hit_none
    cmp byte [r12], WIN_STATE_MINIMIZED
    je .hit_none

    ; Check if window belongs to active workspace
    push rax
    call gui_get_win_ws_val
    cmp al, [gui_active_ws]
    pop rax
    jne .hit_none

    ; Check if inside window bounding box: [win_x .. win_x + win_w], [win_y .. win_y + win_h]
    mov eax, [r8]
    mov ebx, [r9]
    mov esi, [r10]
    mov edi, [r11]
    call gui_pt_in_rect
    jz .hit_none

    ; Inside window! Check red/yellow/green control buttons first
    mov eax, [r8]
    mov ebx, [r9]
    call gui_check_win_buttons
    test eax, eax
    jnz .hit_done

    ; If window is maximized, it has no move or resize
    cmp byte [r12], WIN_STATE_MAXIMIZED
    je .hit_body

    ; 1. Check Bottom-Right Resize Handle:
    ; x >= win_x + win_w - 20 AND y >= win_y + win_h - 20
    mov ecx, [mouse_x]
    mov edx, [mouse_y]

    mov eax, [r8]
    add eax, [r10]
    sub eax, 20
    cmp ecx, eax
    jb .chk_right_border
    mov eax, [r9]
    add eax, [r11]
    sub eax, 20
    cmp edx, eax
    jae .hit_resize

.chk_right_border:
    ; Right border: x >= win_x + win_w - 6 AND y >= win_y + 28
    mov eax, [r8]
    add eax, [r10]
    sub eax, 6
    cmp ecx, eax
    jb .chk_bottom_border
    mov eax, [r9]
    add eax, 28
    cmp edx, eax
    jae .hit_resize

.chk_bottom_border:
    ; Bottom border: y >= win_y + win_h - 6 AND x >= win_x
    mov eax, [r9]
    add eax, [r11]
    sub eax, 6
    cmp edx, eax
    jb .chk_titlebar
    mov eax, [r8]
    cmp ecx, eax
    jae .hit_resize

.chk_titlebar:
    ; 2. Check Titlebar Drag Zone: y < win_y + 28
    mov eax, [r9]
    add eax, 28
    cmp edx, eax
    jae .hit_body

    ; Inside titlebar! Check if clicked Workspace Badge (x >= win_x + win_w - 58 AND x <= win_x + win_w - 12)
    mov eax, [r8]
    add eax, [r10]
    sub eax, 58
    cmp ecx, eax
    jb .hit_titlebar
    add eax, 46
    cmp ecx, eax
    ja .hit_titlebar

    ; Clicked Workspace Badge!
    mov eax, 7                  ; HIT_CODE_WS_BADGE
    jmp .hit_done

.hit_body:
    mov eax, 6
    jmp .hit_done

.hit_resize:
    mov eax, 4
    jmp .hit_done

.hit_titlebar:
    mov eax, 5
    jmp .hit_done

.hit_none:
    xor eax, eax
.hit_done:
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
    ret

; ------------------------------------------------------------------------------
; gui_update_window_drag: Updates dragged or resized window on mouse movement
; ------------------------------------------------------------------------------
gui_update_window_drag:
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

    mov al, [drag_win]
    call gui_get_win_ptrs

    cmp byte [drag_mode], DRAG_MODE_MOVE
    je .do_move
    cmp byte [drag_mode], DRAG_MODE_RESIZE
    je .do_resize
    jmp .drag_update_done

.do_move:
    ; Calculate new X = drag_orig_pos_x + (mouse_x - drag_start_mouse_x)
    mov eax, [mouse_x]
    sub eax, [drag_start_mouse_x]
    add eax, [drag_orig_pos_x]

    ; Calculate new Y = drag_orig_pos_y + (mouse_y - drag_start_mouse_y)
    mov edx, [mouse_y]
    sub edx, [drag_start_mouse_y]
    add edx, [drag_orig_pos_y]

    ; Clamp Y: at least 36 (below top taskbar), at most 700
    cmp edx, 36
    jge .y_not_top
    mov edx, 36
.y_not_top:
    cmp edx, 700
    jle .y_not_bot
    mov edx, 700
.y_not_bot:

    ; Clamp X: at least -200, at most 960
    cmp eax, -200
    jge .x_not_left
    mov eax, -200
.x_not_left:
    cmp eax, 960
    jle .x_not_right
    mov eax, 960
.x_not_right:

    ; Check if position actually changed
    cmp eax, [r8]
    jne .apply_pos
    cmp edx, [r9]
    je .drag_update_done

.apply_pos:
    mov [r8], eax               ; Update winX_x
    mov [r9], edx               ; Update winX_y

    ; Render completely in backbuffer with ZERO screen flashing!
    call bga_prepare_backbuffer
    call gui_draw_desktop
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    mov [gui_cur_x], ecx
    mov [gui_cur_y], edx
    call gfx_draw_cursor
    call bga_flip_page
    jmp .drag_update_done

.do_resize:
    ; Calculate new W = drag_orig_dim_w + (mouse_x - drag_start_mouse_x)
    mov eax, [mouse_x]
    sub eax, [drag_start_mouse_x]
    add eax, [drag_orig_dim_w]

    ; Calculate new H = drag_orig_dim_h + (mouse_y - drag_start_mouse_y)
    mov edx, [mouse_y]
    sub edx, [drag_start_mouse_y]
    add edx, [drag_orig_dim_h]

    ; Clamp minimum W (signed compare so negatives become WIN_MIN_W)
    cmp eax, WIN_MIN_W
    jge .w_not_min
    mov eax, WIN_MIN_W
.w_not_min:

    ; Clamp maximum W: at most 1024 - win_x, but NEVER below WIN_MIN_W
    mov ecx, 1024
    sub ecx, [r8]
    cmp ecx, WIN_MIN_W
    jge .w_max_valid
    mov ecx, WIN_MIN_W
.w_max_valid:
    cmp eax, ecx
    jle .w_not_max
    mov eax, ecx
.w_not_max:

    ; Clamp minimum H: at least WIN_MIN_H (140)
    cmp edx, WIN_MIN_H
    jge .h_not_min
    mov edx, WIN_MIN_H
.h_not_min:

    ; Clamp maximum H: at most 740 - win_y, but NEVER below WIN_MIN_H
    mov ecx, 740
    sub ecx, [r9]
    cmp ecx, WIN_MIN_H
    jge .h_max_valid
    mov ecx, WIN_MIN_H
.h_max_valid:
    cmp edx, ecx
    jle .h_not_max
    mov edx, ecx
.h_not_max:

    ; Check if size actually changed
    cmp eax, [r10]
    jne .apply_dim
    cmp edx, [r11]
    je .drag_update_done

.apply_dim:
    mov [r10], eax              ; Update winX_w
    mov [r11], edx              ; Update winX_h

    ; Render completely in backbuffer with ZERO screen flashing!
    call bga_prepare_backbuffer
    call gui_draw_desktop
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    mov [gui_cur_x], ecx
    mov [gui_cur_y], edx
    call gfx_draw_cursor
    call bga_flip_page

.drag_update_done:
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
; gui_handle_canvas_body_click: Handles clicks inside Window 2 (Cyber Canvas) body
; ------------------------------------------------------------------------------
gui_handle_canvas_body_click:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi

    mov ecx, [mouse_x]
    mov edx, [mouse_y]

    ; Check Palette Swatches (y: win2_y + 31 .. win2_y + 53)
    mov eax, [win2_y]
    add eax, 31
    cmp edx, eax
    jb .chk_canvas_area
    add eax, 22
    cmp edx, eax
    ja .chk_canvas_area

    ; Check Swatches 0 .. 7
    xor ebx, ebx
.swatch_loop:
    mov eax, ebx
    imul eax, 30
    add eax, [win2_x]
    add eax, 15
    cmp ecx, eax
    jb .next_swatch
    add eax, 24
    cmp ecx, eax
    ja .next_swatch
    ; Swatch matched!
    mov eax, [gui_swatches + rbx * 4]
    mov [gui_active_color], eax
    call gfx_restore_cursor
    call gui_draw_palette_indicators
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    call gfx_draw_cursor
    call gui_wait_mouse_release
    jmp .canvas_click_done

.next_swatch:
    inc ebx
    cmp ebx, 8
    jl .swatch_loop

    ; [ Clear Canvas ] button (x: win2_x + 265 .. win2_x + 375)
    mov eax, [win2_x]
    add eax, 265
    cmp ecx, eax
    jb .chk_demo_btn
    add eax, 110
    cmp ecx, eax
    ja .chk_demo_btn
    call gfx_restore_cursor
    call gui_clear_canvas
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    call gfx_draw_cursor
    call gui_wait_mouse_release
    jmp .canvas_click_done

.chk_demo_btn:
    ; [ Draw Cyber Art ] button (x: win2_x + 385 .. win2_x + 520)
    mov eax, [win2_x]
    add eax, 385
    cmp ecx, eax
    jb .chk_canvas_area
    add eax, 135
    cmp ecx, eax
    ja .chk_canvas_area
    call gfx_restore_cursor
    call gui_draw_demo_art
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    call gfx_draw_cursor
    call gui_wait_mouse_release
    jmp .canvas_click_done

.chk_canvas_area:
    call gui_handle_canvas_drag

.canvas_click_done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_wait_mouse_release: Spins until left mouse button is released
; ------------------------------------------------------------------------------
gui_wait_mouse_release:
    push rax
    push rcx
    mov ecx, 2000000
.spin:
    call mouse_poll
    test byte [mouse_buttons], 0x01
    jz .released
    pause
    dec ecx
    jnz .spin
.released:
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_check_win_buttons: Checks if click hit Red, Yellow, or Green dot
; Input: EAX = win_x, EBX = win_y, [mouse_x], [mouse_y]
; Output: RAX = 1 (Red/Close), 2 (Yellow/Min), 3 (Green/Max), 0 (None)
; ------------------------------------------------------------------------------
gui_check_win_buttons:
    push rbx
    push rcx
    push rdx

    mov ecx, [mouse_x]
    mov edx, [mouse_y]

    ; Y check (win_y + 5 .. win_y + 24)
    mov esi, ebx
    add esi, 5
    cmp edx, esi
    jb .none
    add esi, 19
    cmp edx, esi
    ja .none

    ; Red Dot (Close): win_x + 8 .. win_x + 24
    mov esi, eax
    add esi, 8
    cmp ecx, esi
    jb .none
    add esi, 16
    cmp ecx, esi
    ja .chk_yellow
    mov rax, 1                  ; Close!
    jmp .fin

.chk_yellow:
    ; Yellow Dot (Minimize): win_x + 25 .. win_x + 39
    mov esi, eax
    add esi, 25
    cmp ecx, esi
    jb .none
    add esi, 15
    cmp ecx, esi
    ja .chk_green
    mov rax, 2                  ; Minimize!
    jmp .fin

.chk_green:
    ; Green Dot (Maximize): win_x + 40 .. win_x + 56
    mov esi, eax
    add esi, 40
    cmp ecx, esi
    jb .none
    add esi, 16
    cmp ecx, esi
    ja .none
    mov rax, 3                  ; Maximize!
    jmp .fin

.none:
    xor rax, rax
.fin:
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; gui_pt_in_rect: Tests if (mouse_x, mouse_y) is inside (EAX, EBX, ESI, EDI)
; Output: ZF = 0 if inside (match), ZF = 1 if outside
; ------------------------------------------------------------------------------
gui_pt_in_rect:
    push rcx
    push rdx

    mov ecx, [mouse_x]
    mov edx, [mouse_y]

    cmp ecx, eax
    jb .outside
    add eax, esi
    cmp ecx, eax
    ja .outside

    cmp edx, ebx
    jb .outside
    add ebx, edi
    cmp edx, ebx
    ja .outside

    ; Inside! Set ZF = 0
    pop rdx
    pop rcx
    test esp, esp
    ret

.outside:
    pop rdx
    pop rcx
    xor eax, eax                ; Set ZF = 1
    ret

; ------------------------------------------------------------------------------
; gui_handle_canvas_drag: Draws brush mark on canvas at current mouse location
; ------------------------------------------------------------------------------
gui_handle_canvas_drag:
    push rax
    push rcx
    push rdx
    push rsi
    push r8

    mov ecx, [mouse_x]
    mov edx, [mouse_y]

    ; Check canvas boundary (x: 58 .. 966, y: 462 .. 713)
    cmp ecx, 58
    jb .drag_done
    cmp ecx, 966
    ja .drag_done
    cmp edx, 462
    jb .drag_done
    cmp edx, 713
    ja .drag_done

    ; Draw 4x4 brush dot
    dec ecx
    dec edx
    mov esi, 4
    mov r8d, 4
    mov eax, [gui_active_color]
    call gfx_fill_rect

.drag_done:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_flip_redraw_desktop: Flicker-free backbuffer render & hardware page flip
; ------------------------------------------------------------------------------
gui_flip_redraw_desktop:
    push rax
    push rcx
    push rdx
    call bga_prepare_backbuffer
    call gui_draw_desktop
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    mov [gui_cur_x], ecx
    mov [gui_cur_y], edx
    call gfx_draw_cursor
    call bga_flip_page
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_draw_desktop: Renders wallpaper, taskbar, active windows, and status panel
; ------------------------------------------------------------------------------
gui_draw_desktop:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10

    ; 1. Desktop Background Gradient (1024x768)
    xor ecx, ecx
    xor edx, edx
    mov esi, GUI_SCREEN_WIDTH
    mov r8d, GUI_SCREEN_HEIGHT
    mov r9d, GUI_CLR_DESK_TOP
    mov r10d, GUI_CLR_DESK_BOT
    call gfx_draw_gradient_v

    ; 2. Render Top Taskbar
    call gui_draw_taskbar

    ; 3. Check if any window ON CURRENT WORKSPACE is maximized
    movzx ebx, byte [gui_active_ws]

    cmp byte [win0_state], WIN_STATE_MAXIMIZED
    jne .chk_max1
    cmp byte [win0_ws], bl
    je .draw_max_w0
.chk_max1:
    cmp byte [win1_state], WIN_STATE_MAXIMIZED
    jne .chk_max2
    cmp byte [win1_ws], bl
    je .draw_max_w1
.chk_max2:
    cmp byte [win2_state], WIN_STATE_MAXIMIZED
    jne .chk_max3
    cmp byte [win2_ws], bl
    je .draw_max_w2
.chk_max3:
    cmp byte [win3_state], WIN_STATE_MAXIMIZED
    jne .chk_max_done
    cmp byte [win3_ws], bl
    je .draw_max_w3
.chk_max_done:

    ; 4. Render all open Background (non-focused) Windows ON CURRENT WORKSPACE
    cmp byte [win_focused], 0
    je .skip_bg_w0
    cmp byte [win0_state], WIN_STATE_OPEN
    jne .skip_bg_w0
    cmp byte [win0_ws], bl
    jne .skip_bg_w0
    call gui_draw_sys_window
.skip_bg_w0:

    cmp byte [win_focused], 1
    je .skip_bg_w1
    cmp byte [win1_state], WIN_STATE_OPEN
    jne .skip_bg_w1
    cmp byte [win1_ws], bl
    jne .skip_bg_w1
    call gui_draw_term_window
.skip_bg_w1:

    cmp byte [win_focused], 2
    je .skip_bg_w2
    cmp byte [win2_state], WIN_STATE_OPEN
    jne .skip_bg_w2
    cmp byte [win2_ws], bl
    jne .skip_bg_w2
    call gui_draw_canvas_window
.skip_bg_w2:

    cmp byte [win_focused], 3
    je .skip_bg_w3
    cmp byte [win3_state], WIN_STATE_OPEN
    jne .skip_bg_w3
    cmp byte [win3_ws], bl
    jne .skip_bg_w3
    call browser_draw_window
.skip_bg_w3:

    ; 5. Render the FOCUSED Window on top of all other windows!
    cmp byte [win_focused], 0
    jne .chk_fg_w1
    cmp byte [win0_state], WIN_STATE_OPEN
    jne .draw_footer
    cmp byte [win0_ws], bl
    jne .draw_footer
    call gui_draw_sys_window
    jmp .draw_footer

.chk_fg_w1:
    cmp byte [win_focused], 1
    jne .chk_fg_w2
    cmp byte [win1_state], WIN_STATE_OPEN
    jne .draw_footer
    cmp byte [win1_ws], bl
    jne .draw_footer
    call gui_draw_term_window
    jmp .draw_footer

.chk_fg_w2:
    cmp byte [win_focused], 2
    jne .chk_fg_w3
    cmp byte [win2_state], WIN_STATE_OPEN
    jne .draw_footer
    cmp byte [win2_ws], bl
    jne .draw_footer
    call gui_draw_canvas_window
    jmp .draw_footer

.chk_fg_w3:
    cmp byte [win_focused], 3
    jne .draw_footer
    cmp byte [win3_state], WIN_STATE_OPEN
    jne .draw_footer
    cmp byte [win3_ws], bl
    jne .draw_footer
    call browser_draw_window
    jmp .draw_footer

.draw_max_w0:
    call gui_draw_sys_window
    jmp .draw_footer

.draw_max_w1:
    call gui_draw_term_window
    jmp .draw_footer

.draw_max_w2:
    call gui_draw_canvas_window
    jmp .draw_footer

.draw_max_w3:
    call browser_draw_window
    jmp .draw_footer

.draw_footer:
    ; 6. Render Bottom System Status Panel (y: 742 .. 767)
    xor ecx, ecx
    mov edx, 742
    mov esi, GUI_SCREEN_WIDTH
    mov r8d, 26
    mov eax, 0x000B1120
    call gfx_fill_rect

    xor ecx, ecx
    mov edx, 742
    mov esi, GUI_SCREEN_WIDTH
    mov r8d, 1
    mov eax, 0x001E293B
    call gfx_fill_rect

    mov ecx, 14
    mov edx, 750
    lea rsi, [str_footer_left]
    mov eax, COLOR_TEXT_MUTED
    mov ebx, -1
    call gfx_print_string

    mov ecx, 790
    mov edx, 750
    lea rsi, [str_footer_right]
    mov eax, COLOR_TEXT_CYAN
    mov ebx, -1
    call gfx_print_string

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
; gui_draw_taskbar: Renders top panel, start pill, window pills, and status badges
; ------------------------------------------------------------------------------
gui_draw_taskbar:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10

    ; Taskbar base background
    xor ecx, ecx
    xor edx, edx
    mov esi, GUI_SCREEN_WIDTH
    mov r8d, 35
    mov eax, GUI_CLR_TASKBAR
    call gfx_fill_rect

    ; Bottom border line
    xor ecx, ecx
    mov edx, 35
    mov esi, GUI_SCREEN_WIDTH
    mov r8d, 1
    mov eax, GUI_CLR_TASKBAR_BORDER
    call gfx_fill_rect

    ; Start Pill: [ AGY 64 ] (x: 6, w: 72, h: 23, y: 6)
    mov ecx, 6
    mov edx, 6
    mov esi, 72
    mov r8d, 23
    mov eax, GUI_CLR_CYAN_ACCENT
    call gfx_fill_rect

    mov ecx, 14
    mov edx, 14
    lea rsi, [str_start_btn]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; Render Workspace Pills 1 .. 4
    ; WS 1: [ 1:TERM ] (x: 84)
    mov bl, 1
    mov ecx, 84
    lea rdi, [str_ws_pill1]
    call gui_draw_ws_pill

    ; WS 2: [ 2:WEB ] (x: 148)
    mov bl, 2
    mov ecx, 148
    lea rdi, [str_ws_pill2]
    call gui_draw_ws_pill

    ; WS 3: [ 3:DEV ] (x: 212)
    mov bl, 3
    mov ecx, 212
    lea rdi, [str_ws_pill3]
    call gui_draw_ws_pill

    ; WS 4: [ 4:SYS ] (x: 276)
    mov bl, 4
    mov ecx, 276
    lea rdi, [str_ws_pill4]
    call gui_draw_ws_pill

    ; App Launchers / Quick Toggles
    ; [+Term] (x: 348)
    mov al, 1
    mov ecx, 348
    lea rdi, [str_app_term]
    call gui_draw_app_toggle_pill

    ; [+Web] (x: 404)
    mov al, 3
    mov ecx, 404
    lea rdi, [str_app_web]
    call gui_draw_app_toggle_pill

    ; [+Dev] (x: 458)
    mov al, 2
    mov ecx, 458
    lea rdi, [str_app_dev]
    call gui_draw_app_toggle_pill

    ; [+Sys] (x: 512)
    mov al, 0
    mov ecx, 512
    lea rdi, [str_app_sys]
    call gui_draw_app_toggle_pill

    ; Active Workspace Status Badge (x: 572 .. 670)
    mov ecx, 572
    mov edx, 6
    mov esi, 98
    mov r8d, 23
    mov eax, 0x000F172A
    call gfx_fill_rect
    mov ecx, 572
    mov edx, 6
    mov esi, 98
    mov r8d, 23
    mov eax, 0x00334155
    call gfx_draw_rect

    mov ecx, 580
    mov edx, 14
    lea rsi, [str_i3_label]
    mov eax, COLOR_TEXT_CYAN
    mov ebx, -1
    call gfx_print_string

    movzx eax, byte [gui_active_ws]
    add al, '0'
    mov [str_ws_digit], al
    mov ecx, 648
    mov edx, 14
    lea rsi, [str_ws_digit_buf]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; Right Badges
    ; Badge 1: IP: 10.0.2.15 (x: 680)
    mov ecx, 680
    mov edx, 6
    mov esi, 115
    mov r8d, 23
    mov eax, 0x00064E3B          ; Deep forest emerald
    call gfx_fill_rect
    mov ecx, 680
    mov edx, 6
    mov esi, 115
    mov r8d, 23
    mov eax, 0x0010B981
    call gfx_draw_rect
    mov ecx, 690
    mov edx, 14
    lea rsi, [str_badge_ip]
    mov eax, 0x00A7F3D0
    mov ebx, -1
    call gfx_print_string

    ; Badge 2: RAM: 4 GB (x: 805)
    mov ecx, 805
    mov edx, 6
    mov esi, 90
    mov r8d, 23
    mov eax, 0x001E3A8A          ; Dark navy blue
    call gfx_fill_rect
    mov ecx, 805
    mov edx, 6
    mov esi, 90
    mov r8d, 23
    mov eax, 0x0038BDF8
    call gfx_draw_rect
    mov ecx, 815
    mov edx, 14
    lea rsi, [str_badge_ram]
    mov eax, 0x00BAE6FD
    mov ebx, -1
    call gfx_print_string

    ; Badge 3: [ Exit (Esc) ] (x: 905)
    mov ecx, 905
    mov edx, 6
    mov esi, 110
    mov r8d, 23
    mov eax, 0x007F1D1D          ; Dark wine red
    call gfx_fill_rect
    mov ecx, 905
    mov edx, 6
    mov esi, 110
    mov r8d, 23
    mov eax, 0x00EF4444
    call gfx_draw_rect
    mov ecx, 915
    mov edx, 14
    lea rsi, [str_badge_exit]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

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
; gui_draw_ws_pill: Renders single workspace pill (BL = 1..4, ECX = X, RDI = label)
; ------------------------------------------------------------------------------
gui_draw_ws_pill:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10

    mov r10d, ecx
    mov edx, 6
    mov esi, 60
    mov r8d, 23

    ; Active workspace?
    cmp bl, [gui_active_ws]
    jne .ws_not_active

    ; Active style
    mov eax, 0x000284C7
    call gfx_fill_rect
    mov ecx, r10d
    mov edx, 6
    mov esi, 60
    mov r8d, 23
    mov eax, 0x0038BDF8
    call gfx_draw_rect
    mov eax, COLOR_TEXT_WHITE
    jmp .draw_ws_lbl

.ws_not_active:
    ; Occupied?
    cmp [win0_ws], bl
    je .ws_occupied
    cmp [win1_ws], bl
    je .ws_occupied
    cmp [win2_ws], bl
    je .ws_occupied
    cmp [win3_ws], bl
    je .ws_occupied

    ; Empty style
    mov eax, 0x000F172A
    call gfx_fill_rect
    mov ecx, r10d
    mov edx, 6
    mov esi, 60
    mov r8d, 23
    mov eax, 0x001E293B
    call gfx_draw_rect
    mov eax, COLOR_TEXT_MUTED
    jmp .draw_ws_lbl

.ws_occupied:
    ; Occupied style
    mov eax, 0x001E293B
    call gfx_fill_rect
    mov ecx, r10d
    mov edx, 6
    mov esi, 60
    mov r8d, 23
    mov eax, 0x00475569
    call gfx_draw_rect
    mov eax, COLOR_TEXT_CYAN

.draw_ws_lbl:
    push rax
    mov ecx, r10d
    add ecx, 6
    mov edx, 14
    mov rsi, rdi
    pop rax
    mov ebx, -1
    call gfx_print_string

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
; gui_draw_app_toggle_pill: Renders app launcher pill (AL = win_id, ECX = X, RDI = label)
; ------------------------------------------------------------------------------
gui_draw_app_toggle_pill:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10

    mov r10d, ecx
    movzx ebx, al
    mov edx, 6
    mov esi, 50
    mov r8d, 23

    call gui_get_win_ptrs
    cmp byte [r12], WIN_STATE_CLOSED
    je .app_dim
    cmp byte [r12], WIN_STATE_MINIMIZED
    je .app_dim

    cmp bl, [win_focused]
    jne .app_open_unfocused

    ; Focused!
    mov eax, 0x00047857          ; Emerald
    call gfx_fill_rect
    mov ecx, r10d
    mov edx, 6
    mov esi, 50
    mov r8d, 23
    mov eax, 0x0034D399
    call gfx_draw_rect
    mov eax, COLOR_TEXT_WHITE
    jmp .draw_app_lbl

.app_open_unfocused:
    mov eax, 0x001E3A8A          ; Blue
    call gfx_fill_rect
    mov ecx, r10d
    mov edx, 6
    mov esi, 50
    mov r8d, 23
    mov eax, 0x0038BDF8
    call gfx_draw_rect
    mov eax, COLOR_TEXT_WHITE
    jmp .draw_app_lbl

.app_dim:
    mov eax, 0x000F172A
    call gfx_fill_rect
    mov ecx, r10d
    mov edx, 6
    mov esi, 50
    mov r8d, 23
    mov eax, 0x00334155
    call gfx_draw_rect
    mov eax, COLOR_TEXT_MUTED

.draw_app_lbl:
    push rax
    mov ecx, r10d
    add ecx, 5
    mov edx, 14
    mov rsi, rdi
    pop rax
    mov ebx, -1
    call gfx_print_string

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
; gui_draw_window_frame: Renders shadow, border, titlebar, and control dots
; Input:
;   ECX = X, EDX = Y, ESI = Width, R8D = Height, RDI = Title String Pointer
;   AL  = Is Focused? (1 = yes, 0 = no)
;   AH  = Window ID (0..3)
; ------------------------------------------------------------------------------
gui_draw_window_frame:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov r9d, ecx                ; X
    mov r10d, edx               ; Y
    mov r11d, esi               ; W
    mov r12d, r8d               ; H
    movzx r13d, al              ; Focused flag
    shr eax, 8
    movzx r14d, al              ; Window ID (0..3)

    ; 1. Window Drop Shadow (+6, +6)
    mov ecx, r9d
    add ecx, 6
    mov edx, r10d
    add edx, 6
    mov esi, r11d
    mov r8d, r12d
    mov eax, GUI_CLR_WIN_SHADOW
    call gfx_fill_rect

    ; 2. Window Body Fill
    mov ecx, r9d
    mov edx, r10d
    mov esi, r11d
    mov r8d, r12d
    mov eax, GUI_CLR_WIN_BODY
    call gfx_fill_rect

    ; 3. Titlebar Fill (28px height)
    mov ecx, r9d
    mov edx, r10d
    mov esi, r11d
    mov r8d, 28
    cmp r13d, 1
    je .active_title
    mov eax, GUI_CLR_WIN_TITLE
    jmp .do_title_fill
.active_title:
    mov eax, GUI_CLR_WIN_TITLE_ACT
.do_title_fill:
    call gfx_fill_rect

    ; Titlebar bottom accent line
    mov ecx, r9d
    mov edx, r10d
    add edx, 27
    mov esi, r11d
    mov r8d, 1
    cmp r13d, 1
    je .active_accent
    mov eax, GUI_CLR_WIN_BORDER
    jmp .do_accent
.active_accent:
    mov eax, GUI_CLR_WIN_BORDER_ACT
.do_accent:
    call gfx_fill_rect

    ; 4. Window Outer Border (1px)
    mov ecx, r9d
    mov edx, r10d
    mov esi, r11d
    mov r8d, r12d
    cmp r13d, 1
    je .act_border
    mov eax, GUI_CLR_WIN_BORDER
    jmp .do_border
.act_border:
    mov eax, GUI_CLR_WIN_BORDER_ACT
.do_border:
    call gfx_draw_rect

    ; 5. Control Buttons (Red, Yellow, Green dots)
    ; Red Dot (Close)
    mov ecx, r9d
    add ecx, 12
    mov edx, r10d
    add edx, 9
    mov esi, 10
    mov r8d, 10
    mov eax, COLOR_BTN_CLOSE
    call gfx_fill_rect

    ; Yellow Dot (Minimize)
    mov ecx, r9d
    add ecx, 27
    mov edx, r10d
    add edx, 9
    mov esi, 10
    mov r8d, 10
    mov eax, COLOR_TEXT_YELLOW
    call gfx_fill_rect

    ; Green Dot (Maximize)
    mov ecx, r9d
    add ecx, 42
    mov edx, r10d
    add edx, 9
    mov esi, 10
    mov r8d, 10
    mov eax, COLOR_TEXT_GREEN
    call gfx_fill_rect

    ; 6. Window Title String
    mov ecx, r9d
    add ecx, 62
    mov edx, r10d
    add edx, 10
    mov rsi, rdi
    cmp r13d, 1
    je .act_title_text
    mov eax, COLOR_TEXT_MUTED
    jmp .print_title
.act_title_text:
    mov eax, COLOR_TEXT_WHITE
.print_title:
    mov ebx, -1
    call gfx_print_string

    ; 6b. Workspace Badge in Titlebar (e.g. [WS 1])
    cmp r11d, 140
    jb .skip_ws_badge

    lea ecx, [r9d + r11d - 58]
    lea edx, [r10d + 5]
    mov esi, 46
    mov r8d, 18
    mov eax, 0x00131D2E
    call gfx_fill_rect

    lea ecx, [r9d + r11d - 58]
    lea edx, [r10d + 5]
    mov esi, 46
    mov r8d, 18
    mov eax, 0x0038BDF8
    call gfx_draw_rect

    ; Get workspace number for window r14d
    mov al, r14b
    call gui_get_win_ws_val     ; AL = workspace (1..4)
    add al, '0'
    mov [str_ws_badge_digit], al

    lea ecx, [r9d + r11d - 51]
    lea edx, [r10d + 6]
    lea rsi, [str_ws_badge_text]
    mov eax, 0x0000F0FF          ; Cyan
    mov ebx, -1
    call gfx_print_string

.skip_ws_badge:

    ; 7. Visual Resize Grip Handle (Bottom-Right Corner)
    ; Only draw if not maximized
    cmp r11d, WIN_MAX_W
    jae .skip_grip
    cmp r12d, WIN_MAX_H
    jae .skip_grip

    mov eax, 0x00334155          ; Slate dots if unfocused
    cmp r13d, 1
    jne .draw_grip_dots
    mov eax, GUI_CLR_CYAN_GLOW   ; Glowing cyber cyan if focused!
.draw_grip_dots:
    ; Dot 1: (x + w - 5, y + h - 5)
    lea ecx, [r9d + r11d - 5]
    lea edx, [r10d + r12d - 5]
    mov esi, 2
    mov r8d, 2
    call gfx_fill_rect

    ; Dot 2: (x + w - 9, y + h - 5)
    lea ecx, [r9d + r11d - 9]
    lea edx, [r10d + r12d - 5]
    mov esi, 2
    mov r8d, 2
    call gfx_fill_rect

    ; Dot 3: (x + w - 5, y + h - 9)
    lea ecx, [r9d + r11d - 5]
    lea edx, [r10d + r12d - 9]
    mov esi, 2
    mov r8d, 2
    call gfx_fill_rect

    ; Dot 4: (x + w - 13, y + h - 5)
    lea ecx, [r9d + r11d - 13]
    lea edx, [r10d + r12d - 5]
    mov esi, 2
    mov r8d, 2
    call gfx_fill_rect

    ; Dot 5: (x + w - 9, y + h - 9)
    lea ecx, [r9d + r11d - 9]
    lea edx, [r10d + r12d - 9]
    mov esi, 2
    mov r8d, 2
    call gfx_fill_rect

    ; Dot 6: (x + w - 5, y + h - 13)
    lea ecx, [r9d + r11d - 5]
    lea edx, [r10d + r12d - 13]
    mov esi, 2
    mov r8d, 2
    call gfx_fill_rect

.skip_grip:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_draw_sys_window: Renders Window 0 (System Monitor & Hardware specs)
; ------------------------------------------------------------------------------
gui_draw_sys_window:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    mov ecx, [win0_x]
    mov edx, [win0_y]
    mov esi, [win0_w]
    mov r8d, [win0_h]
    lea rdi, [str_win0_title]
    xor al, al
    cmp byte [win_focused], 0
    jne .frame0
    mov al, 1
.frame0:
    mov ah, 0                   ; Window ID 0
    call gui_draw_window_frame

    ; Content
    mov ecx, [win0_x]
    add ecx, 12
    mov edx, [win0_y]
    add edx, 34

    lea rsi, [str_w0_sec1]
    mov eax, COLOR_TEXT_CYAN
    mov ebx, -1
    call gfx_print_string
    add edx, 16

    lea rsi, [str_w0_cpu]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string
    add edx, 16

    lea rsi, [str_w0_mem]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string
    add edx, 16

    lea rsi, [str_w0_page]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string
    add edx, 16

    lea rsi, [str_w0_disp]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string
    add edx, 24

    lea rsi, [str_w0_sec2]
    mov eax, COLOR_TEXT_CYAN
    mov ebx, -1
    call gfx_print_string
    add edx, 16

    lea rsi, [str_w0_fs]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string
    add edx, 16

    lea rsi, [str_w0_nic]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string
    add edx, 16

    lea rsi, [str_w0_ip]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string
    add edx, 16

    lea rsi, [str_w0_gw]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string
    add edx, 16

    lea rsi, [str_w0_tcp]
    mov eax, COLOR_TEXT_GREEN
    mov ebx, -1
    call gfx_print_string
    add edx, 16

    lea rsi, [str_w0_mouse]
    mov eax, COLOR_TEXT_YELLOW
    mov ebx, -1
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
; gui_draw_term_window: Renders Window 1 (Interactive Live Terminal)
; ------------------------------------------------------------------------------
gui_draw_term_window:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10

    mov ecx, [win1_x]
    mov edx, [win1_y]
    mov esi, [win1_w]
    mov r8d, [win1_h]
    cmp byte [win_focused], 1
    je .active_term_title
    lea rdi, [str_win1_title]
    xor al, al
    jmp .draw_term_frame
.active_term_title:
    lea rdi, [str_win1_title_act]
    mov al, 1
.draw_term_frame:
    mov ah, 1                   ; Window ID 1 (Terminal)
    call gui_draw_window_frame

    ; Terminal interior black fill
    mov ecx, [win1_x]
    add ecx, 2
    mov edx, [win1_y]
    add edx, 28
    mov esi, [win1_w]
    sub esi, 4
    mov r8d, [win1_h]
    sub r8d, 30
    mov eax, GUI_CLR_TERM_BG
    call gfx_fill_rect

    ; Render history lines
    xor r9d, r9d                ; Line index 0 .. line_count - 1
.line_loop:
    cmp r9d, [gui_term_line_count]
    jge .draw_active_prompt

    mov ecx, [win1_x]
    add ecx, 10
    mov edx, [win1_y]
    add edx, 34
    mov eax, r9d
    imul eax, 16
    add edx, eax                ; Y position

    mov eax, r9d
    imul eax, GUI_TERM_LINE_LEN
    lea rsi, [gui_term_lines + rax]

    ; Color based on line content
    mov eax, COLOR_TEXT_WHITE
    cmp byte [rsi], 'a'         ; "antigravity>"
    jne .chk_ok
    mov eax, COLOR_TEXT_GREEN
    jmp .print_line
.chk_ok:
    cmp byte [rsi], '['         ; "[OK]" or "[ERROR]"
    jne .chk_ping
    mov eax, 0x0034D399
    cmp byte [rsi + 1], 'E'     ; "[ERROR]"
    jne .print_line
    mov eax, COLOR_TEXT_YELLOW
    jmp .print_line
.chk_ping:
    cmp byte [rsi], '6'         ; "64 bytes..."
    jne .print_line
    mov eax, COLOR_TEXT_CYAN

.print_line:
    mov ebx, -1
    call gfx_print_string

    inc r9d
    cmp r9d, GUI_TERM_MAX_LINES
    jl .line_loop

.draw_active_prompt:
    ; Draw active input line: "antigravity> " + term_input_buf + cursor
    mov ecx, [win1_x]
    add ecx, 10
    mov edx, [win1_y]
    add edx, 34
    mov eax, [gui_term_line_count]
    imul eax, 16
    add edx, eax

    lea rsi, [str_term_prompt]
    mov eax, COLOR_TEXT_GREEN
    mov ebx, -1
    call gfx_print_string

    ; User typed text
    mov ecx, [win1_x]
    add ecx, 114
    lea rsi, [term_input_buf]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; Cursor block
    mov ecx, [win1_x]
    add ecx, 114
    mov eax, [term_input_len]
    shl eax, 3                  ; len * 8 px
    add ecx, eax
    mov esi, 8
    mov r8d, 10
    cmp byte [win_focused], 1
    je .bright_cursor
    mov eax, 0x00475569          ; Dim cursor when unfocused
    jmp .draw_cursor_blk
.bright_cursor:
    mov eax, COLOR_TEXT_CYAN
.draw_cursor_blk:
    call gfx_fill_rect

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
; gui_draw_canvas_window: Renders Window 2 (Interactive Cyber Canvas)
; ------------------------------------------------------------------------------
gui_draw_canvas_window:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    mov ecx, [win2_x]
    mov edx, [win2_y]
    mov esi, [win2_w]
    mov r8d, [win2_h]
    lea rdi, [str_win2_title]
    xor al, al
    cmp byte [win_focused], 2
    jne .frame2
    mov al, 1
.frame2:
    mov ah, 2                   ; Window ID 2 (Cyber Canvas)
    call gui_draw_window_frame

    ; Draw Canvas Toolbar (Swatches, Buttons, Help text)
    call gui_draw_palette_indicators

    ; [ Clear Canvas ] button (x: 310 .. 420, y: 426 .. 448)
    mov ecx, 310
    mov edx, 426
    mov esi, 110
    mov r8d, 22
    mov eax, 0x00334155
    call gfx_fill_rect
    mov ecx, 320
    mov edx, 433
    lea rsi, [str_btn_clear]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; [ Draw Cyber Art ] button (x: 430 .. 565, y: 426 .. 448)
    mov ecx, 430
    mov edx, 426
    mov esi, 135
    mov r8d, 22
    mov eax, GUI_CLR_CYAN_ACCENT
    call gfx_fill_rect
    mov ecx, 438
    mov edx, 433
    lea rsi, [str_btn_art]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; Canvas Toolbar hint text
    mov ecx, 580
    mov edx, 433
    lea rsi, [str_canvas_hint]
    mov eax, COLOR_TEXT_MUTED
    mov ebx, -1
    call gfx_print_string

    ; Clear and draw initial demo artwork on canvas
    call gui_clear_canvas
    call gui_draw_demo_art

    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_draw_palette_indicators: Renders the 8 swatches and active indicator
; ------------------------------------------------------------------------------
gui_draw_palette_indicators:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8

    xor ebx, ebx                ; i = 0 .. 7
.loop:
    mov ecx, ebx
    imul ecx, 30
    add ecx, 55                 ; X
    mov edx, 426                ; Y
    mov esi, 24                 ; W
    mov r8d, 22                 ; H
    mov eax, [gui_swatches + rbx * 4]
    call gfx_fill_rect

    ; Border around swatch
    mov ecx, ebx
    imul ecx, 30
    add ecx, 55
    mov edx, 426
    mov esi, 24
    mov r8d, 22
    mov eax, [gui_swatches + rbx * 4]
    cmp eax, [gui_active_color]
    jne .dim_border
    mov eax, COLOR_TEXT_WHITE   ; Selected swatch gets bright white border
    call gfx_draw_rect
    mov ecx, ebx
    imul ecx, 30
    add ecx, 56
    mov edx, 427
    mov esi, 22
    mov r8d, 20
    mov eax, COLOR_TEXT_WHITE
    call gfx_draw_rect
    jmp .next

.dim_border:
    mov eax, 0x00475569         ; Muted border
    call gfx_draw_rect

.next:
    inc ebx
    cmp ebx, 8
    jl .loop

    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_clear_canvas: Fills the drawing canvas with dark background
; ------------------------------------------------------------------------------
gui_clear_canvas:
    push rax
    push rcx
    push rdx
    push rsi
    push r8

    ; Canvas fill
    mov ecx, [win2_x]
    add ecx, 16
    mov edx, [win2_y]
    add edx, 65
    mov esi, [win2_w]
    sub esi, 28
    mov r8d, [win2_h]
    sub r8d, 80
    mov eax, GUI_CLR_CANVAS_BG
    call gfx_fill_rect

    ; Canvas inner border
    mov ecx, [win2_x]
    add ecx, 16
    mov edx, [win2_y]
    add edx, 65
    mov esi, [win2_w]
    sub esi, 28
    mov r8d, [win2_h]
    sub r8d, 80
    mov eax, 0x001F2937
    call gfx_draw_rect

    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_draw_demo_art: Renders futuristic cybernetic geometric vector art
; ------------------------------------------------------------------------------
gui_draw_demo_art:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10

    ; 1. Concentric Geometric Cyber Diamonds & Rings
    mov ebx, 10
.ring_loop:
    mov ecx, 512
    sub ecx, ebx
    mov edx, 587
    sub edx, ebx
    mov esi, ebx
    shl esi, 1                  ; Width = 2 * r
    mov r8d, ebx
    shl r8d, 1                  ; Height = 2 * r

    test ebx, 0x20
    jz .cyan_ring
    mov eax, 0x00EC4899          ; Magenta
    jmp .draw_box
.cyan_ring:
    mov eax, 0x0000F0FF          ; Cyan
.draw_box:
    call gfx_draw_rect

    add ebx, 14
    cmp ebx, 110
    jl .ring_loop

    ; 2. Crosshairs & Cyber Grid Lines
    mov ecx, 260
    mov edx, 587
    mov esi, 504
    mov r8d, 1
    mov eax, 0x000284C7
    call gfx_fill_rect

    mov ecx, 512
    mov edx, 475
    mov esi, 1
    mov r8d, 224
    mov eax, 0x000284C7
    call gfx_fill_rect

    ; 3. Cyber Branding Text
    mov ecx, 416
    mov edx, 583
    lea rsi, [str_canvas_banner]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, 0x000F172A
    call gfx_print_string

    ; 4. Corner Cyber Reticles
    ; Top-Left
    mov ecx, 70
    mov edx, 475
    mov esi, 20
    mov r8d, 2
    mov eax, COLOR_TEXT_CYAN
    call gfx_fill_rect
    mov ecx, 70
    mov edx, 475
    mov esi, 2
    mov r8d, 20
    mov eax, COLOR_TEXT_CYAN
    call gfx_fill_rect

    ; Top-Right
    mov ecx, 934
    mov edx, 475
    mov esi, 20
    mov r8d, 2
    mov eax, COLOR_TEXT_CYAN
    call gfx_fill_rect
    mov ecx, 952
    mov edx, 475
    mov esi, 2
    mov r8d, 20
    mov eax, COLOR_TEXT_CYAN
    call gfx_fill_rect

    ; Bottom-Left
    mov ecx, 70
    mov edx, 700
    mov esi, 20
    mov r8d, 2
    mov eax, COLOR_TEXT_CYAN
    call gfx_fill_rect
    mov ecx, 70
    mov edx, 682
    mov esi, 2
    mov r8d, 20
    mov eax, COLOR_TEXT_CYAN
    call gfx_fill_rect

    ; Bottom-Right
    mov ecx, 934
    mov edx, 700
    mov esi, 20
    mov r8d, 2
    mov eax, COLOR_TEXT_CYAN
    call gfx_fill_rect
    mov ecx, 952
    mov edx, 682
    mov esi, 2
    mov r8d, 20
    mov eax, COLOR_TEXT_CYAN
    call gfx_fill_rect

    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; Interactive Terminal Functions
; ==============================================================================

; ------------------------------------------------------------------------------
; strcpy: Copies null-terminated string from RSI to RDI. Preserves all registers.
; ------------------------------------------------------------------------------
strcpy:
    push rsi
    push rdi
    push rax
.loop:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .done
    inc rsi
    inc rdi
    jmp .loop
.done:
    pop rax
    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------------------------
; gui_term_init: Pre-populates initial terminal welcome & command lines
; ------------------------------------------------------------------------------
gui_term_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov dword [gui_term_line_count], 6
    mov dword [term_input_len], 0
    mov byte [term_input_buf], 0

    ; Line 0
    mov rdi, gui_term_lines
    lea rsi, [str_term_init0]
    call strcpy

    ; Line 1
    mov rdi, gui_term_lines + GUI_TERM_LINE_LEN
    lea rsi, [str_term_init1]
    call strcpy

    ; Line 2
    mov rdi, gui_term_lines + (GUI_TERM_LINE_LEN * 2)
    lea rsi, [str_term_init2]
    call strcpy

    ; Line 3
    mov rdi, gui_term_lines + (GUI_TERM_LINE_LEN * 3)
    lea rsi, [str_term_init3]
    call strcpy

    ; Line 4
    mov rdi, gui_term_lines + (GUI_TERM_LINE_LEN * 4)
    lea rsi, [str_term_init4]
    call strcpy

    ; Line 5
    mov rdi, gui_term_lines + (GUI_TERM_LINE_LEN * 5)
    lea rsi, [str_term_init5]
    call strcpy

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_term_scroll_up: Shifts all history lines up by 1 slot
; ------------------------------------------------------------------------------
gui_term_scroll_up:
    push rax
    push rcx
    push rsi
    push rdi

    mov rdi, gui_term_lines
    lea rsi, [gui_term_lines + GUI_TERM_LINE_LEN]
    mov ecx, ((GUI_TERM_MAX_LINES - 1) * GUI_TERM_LINE_LEN)
    rep movsb

    ; Clear bottom line
    mov rdi, gui_term_lines + ((GUI_TERM_MAX_LINES - 1) * GUI_TERM_LINE_LEN)
    xor eax, eax
    mov ecx, (GUI_TERM_LINE_LEN / 4)
    rep stosd

    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_term_add_line: Appends string in RSI to terminal history
; ------------------------------------------------------------------------------
gui_term_add_line:
    push rax
    push rbx
    push rcx
    push rdi

    mov eax, [gui_term_line_count]
    cmp eax, (GUI_TERM_MAX_LINES - 1)
    jl .can_append

    ; Scroll up
    call gui_term_scroll_up
    mov eax, (GUI_TERM_MAX_LINES - 2)
    mov [gui_term_line_count], eax

.can_append:
    imul eax, GUI_TERM_LINE_LEN
    lea rdi, [gui_term_lines + rax]
    call strcpy

    inc dword [gui_term_line_count]

    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_term_handle_char: Appends printable character in AL to term_input_buf
; ------------------------------------------------------------------------------
gui_term_handle_char:
    push rax
    push rbx
    push rcx
    push rdx

    mov ecx, [term_input_len]
    cmp ecx, 38                 ; Limit command line length
    jae .char_done

    mov [term_input_buf + rcx], al
    inc dword [term_input_len]
    mov byte [term_input_buf + rcx + 1], 0

    ; Redraw terminal
    call gfx_restore_cursor
    call gui_draw_term_window
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    call gfx_draw_cursor

.char_done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_term_handle_backspace: Deletes last character from term_input_buf
; ------------------------------------------------------------------------------
gui_term_handle_backspace:
    push rax
    push rcx
    push rdx

    mov ecx, [term_input_len]
    test ecx, ecx
    jz .bk_done

    dec dword [term_input_len]
    mov byte [term_input_buf + rcx - 1], 0

    ; Redraw terminal
    call gfx_restore_cursor
    call gui_draw_term_window
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    call gfx_draw_cursor

.bk_done:
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; gui_term_handle_enter: Executes command typed in terminal
; ------------------------------------------------------------------------------
gui_term_handle_enter:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; 1. Add "antigravity> <cmd>" line to history
    mov rdi, term_scratch_line
    lea rsi, [str_term_prompt]
    call strcpy
    mov rdi, term_scratch_line + 13
    lea rsi, [term_input_buf]
    call strcpy

    lea rsi, [term_scratch_line]
    call gui_term_add_line

    ; 2. Evaluate command
    lea rsi, [term_input_buf]

    ; Check "help"
    lea rdi, [CMD_HELP]
    call strcmp
    jz .cmd_help

    ; Check "ls" or "dir"
    lea rdi, [CMD_LS]
    call strcmp
    jz .cmd_ls
    lea rdi, [CMD_DIR]
    call strcmp
    jz .cmd_ls

    ; Check "clear"
    lea rdi, [CMD_CLEAR]
    call strcmp
    jz .cmd_clear

    ; Check "sysinfo" or "about"
    lea rdi, [str_cmd_sysinfo]
    call strcmp
    jz .cmd_sysinfo
    lea rdi, [CMD_ABOUT]
    call strcmp
    jz .cmd_sysinfo

    ; Check "ping" (starts with ping)
    lea rdi, [CMD_PING]
    mov rcx, 4
    call strncmp
    jz .cmd_ping

    ; Check "ticks"
    lea rdi, [CMD_TICKS]
    call strcmp
    jz .cmd_ticks

    ; Check "browser" or "web"
    lea rdi, [CMD_BROWSER]
    call strcmp
    jz .cmd_term_browser
    lea rdi, [CMD_WEB]
    call strcmp
    jz .cmd_term_browser

    ; Check "ws" or "workspace"
    lea rdi, [str_cmd_ws]
    mov rcx, 2
    call strncmp
    jz .cmd_ws
    lea rdi, [str_cmd_workspace]
    mov rcx, 9
    call strncmp
    jz .cmd_ws

    ; Check "exit" or "quit"
    lea rdi, [str_cmd_exit]
    call strcmp
    jz .cmd_exit
    lea rdi, [str_cmd_quit]
    call strcmp
    jz .cmd_exit

    ; Check empty command (just pressed Enter)
    cmp byte [rsi], 0
    je .clear_input

    ; Unknown command
    lea rsi, [str_term_unknown]
    call gui_term_add_line
    jmp .clear_input

.cmd_help:
    lea rsi, [str_term_h1]
    call gui_term_add_line
    lea rsi, [str_term_h2]
    call gui_term_add_line
    jmp .clear_input

.cmd_ls:
    lea rsi, [str_term_files]
    call gui_term_add_line
    jmp .clear_input

.cmd_clear:
    mov dword [gui_term_line_count], 0
    jmp .clear_input

.cmd_sysinfo:
    lea rsi, [str_term_sys1]
    call gui_term_add_line
    lea rsi, [str_term_sys2]
    call gui_term_add_line
    jmp .clear_input

.cmd_ping:
    lea rsi, [str_term_ping_rep]
    call gui_term_add_line
    jmp .clear_input

.cmd_ticks:
    lea rsi, [str_term_ticks]
    call gui_term_add_line
    jmp .clear_input

.cmd_ws:
    lea rsi, [term_input_buf + 2]
    cmp byte [term_input_buf + 1], 's'
    je .ws_skip_sp
    lea rsi, [term_input_buf + 9]
.ws_skip_sp:
    cmp byte [rsi], ' '
    jne .ws_chk_arg
    inc rsi
    jmp .ws_skip_sp

.ws_chk_arg:
    cmp byte [rsi], 0
    je .ws_show_status

    ; Check if "move"
    cmp byte [rsi], 'm'
    jne .ws_chk_num
    add rsi, 4                  ; Skip "move"
.ws_skip_sp2:
    cmp byte [rsi], ' '
    jne .ws_do_move
    inc rsi
    jmp .ws_skip_sp2

.ws_do_move:
    mov al, [rsi]
    sub al, '0'
    cmp al, 1
    jb .ws_show_status
    cmp al, 4
    ja .ws_show_status
    mov bl, al                  ; Target workspace (1..4)
    mov al, [win_focused]
    cmp al, 3
    jbe .ws_call_move
    mov al, 1                   ; Default to Terminal (win 1)
.ws_call_move:
    call gui_move_window_to_ws
    lea rsi, [str_term_ws_moved]
    call gui_term_add_line
    jmp .clear_input

.ws_chk_num:
    mov al, [rsi]
    sub al, '0'
    cmp al, 1
    jb .ws_show_status
    cmp al, 4
    ja .ws_show_status
    mov dword [term_input_len], 0
    mov byte [term_input_buf], 0
    lea rsi, [str_term_ws_switched]
    call gui_term_add_line
    call gui_switch_workspace
    jmp .done_exec

.ws_show_status:
    lea rsi, [str_term_ws_status]
    call gui_term_add_line
    jmp .clear_input

.cmd_term_browser:
    mov byte [win3_state], WIN_STATE_OPEN
    mov dword [win3_x], WIN3_DEF_X
    mov dword [win3_y], WIN3_DEF_Y
    mov dword [win3_w], WIN3_DEF_W
    mov dword [win3_h], WIN3_DEF_H
    mov byte [win_focused], 3
    mov al, [gui_active_ws]
    mov [win3_ws], al
    lea rsi, [str_term_browser_ok]
    call gui_term_add_line
    mov dword [term_input_len], 0
    mov byte [term_input_buf], 0
    call gui_flip_redraw_desktop
    jmp .done_exec

.cmd_exit:
    ; Close terminal window!
    mov byte [win1_state], WIN_STATE_CLOSED
    call gui_pick_next_focus
    call gui_flip_redraw_desktop
    jmp .done_exec

.clear_input:
    mov dword [term_input_len], 0
    mov byte [term_input_buf], 0

    ; Only redraw terminal window if open and on active workspace!
    cmp byte [win1_state], WIN_STATE_OPEN
    jne .done_exec
    mov al, [gui_active_ws]
    cmp al, [win1_ws]
    jne .done_exec

    ; Redraw terminal window with updated history
    call gfx_restore_cursor
    call gui_draw_term_window
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    call gfx_draw_cursor

.done_exec:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; GUI Text Strings & Buffers
; ------------------------------------------------------------------------------
term_scratch_line:  times 64 db 0

str_start_btn:      db "AGY OS 64", 0
str_menu_sys:       db "System", 0
str_menu_term:      db "Terminal", 0
str_menu_paint:     db "Cyber Canvas", 0
str_menu_browser:   db "Browser", 0
str_badge_ip:       db "IP: 10.0.2.15", 0
str_badge_ram:      db "RAM: 4 GB", 0
str_badge_exit:     db "Exit (Esc)", 0

str_ws_pill1:       db "1:TERM", 0
str_ws_pill2:       db "2:WEB", 0
str_ws_pill3:       db "3:DEV", 0
str_ws_pill4:       db "4:SYS", 0
str_app_term:       db "+Term", 0
str_app_web:        db "+Web", 0
str_app_dev:        db "+Dev", 0
str_app_sys:        db "+Sys", 0
str_i3_label:       db "i3 [WS]", 0
str_ws_digit_buf:
str_ws_digit:       db "1", 0
str_ws_badge_text:  db "WS "
str_ws_badge_digit: db "1", 0
str_cmd_ws:         db "ws", 0
str_cmd_workspace:  db "workspace", 0
str_term_ws_status: db "[i3] WS1:Term | WS2:Web | WS3:Dev | WS4:Sys", 0
str_term_ws_switched: db "[i3] Switched workspace", 0
str_term_ws_moved:    db "[i3] Moved window to workspace", 0

str_win0_title:     db "System Monitor - x86_64 Long Mode", 0
str_w0_sec1:        db "--- HARDWARE ARCHITECTURE ---", 0
str_w0_cpu:         db "CPU Arch:     x86_64 Long Mode (64-Bit)", 0
str_w0_mem:         db "Memory:       4096 MB Physical Identity Map", 0
str_w0_page:        db "Paging:       4-Level PML4 (2MB Huge Pages)", 0
str_w0_disp:        db "Display:      BGA 1024x768 32bpp TrueColor", 0
str_w0_sec2:        db "--- SUBSYSTEM & NETWORK ---", 0
str_w0_fs:          db "Storage:      AntigravityFS (AFS1) Primary ATA", 0
str_w0_nic:         db "NIC Adapter:  Realtek RTL8139 PCI BusMaster", 0
str_w0_ip:          db "IPv4 Address: 10.0.2.15 / 255.255.255.0", 0
str_w0_gw:          db "Gateway/DNS:  10.0.2.2 / 10.0.2.3", 0
str_w0_tcp:         db "TCP/IP Stack: Active (ARP/ICMP/UDP/TCP)", 0
str_w0_mouse:       db "Mouse Driver: PS/2 8042 Auxiliary (Active)", 0

str_win1_title:     db "Antigravity Terminal - x86_64 Console", 0
str_win1_title_act: db "Terminal - bash@antigravity [ACTIVE]", 0
str_term_prompt:    db "antigravity> ", 0
str_cmd_sysinfo:    db "sysinfo", 0
str_cmd_exit:       db "exit", 0
str_cmd_quit:       db "quit", 0

str_term_init0:     db "Antigravity OS v2.0 Terminal [x86_64 Console]", 0
str_term_init1:     db "Type 'help', 'ls', 'sysinfo', 'ping', or 'clear'", 0
str_term_init2:     db "antigravity> sysinfo", 0
str_term_init3:     db "[OK] 64-bit Kernel Active. 4096 MB RAM Identity Map.", 0
str_term_init4:     db "antigravity> ls", 0
str_term_init5:     db "welcome.txt (108 B)  readme.txt (250 B)", 0

str_term_unknown:   db "[ERROR] Command not found. Type 'help'", 0
str_term_browser_ok: db "[OK] Launched CyberSurf Web Browser (Window 3)", 0
str_term_h1:        db "Commands: ls, sysinfo, ping, browser, clear, exit", 0
str_term_h2:        db "Red/Yellow/Green dots: Close, Minimize, Maximize", 0
str_term_files:     db "Files: welcome.txt (108 B)  readme.txt (250 B)", 0
str_term_sys1:      db "[OK] AMD64 Long Mode | 4096 MB RAM | 4-Level Paging", 0
str_term_sys2:      db "[OK] RTL8139 PCI Fast Ethernet | 1024x768 TrueColor", 0
str_term_ping_rep:  db "64 bytes from 10.0.2.2: seq=1 time=1ms", 0
str_term_ticks:     db "[TIMER] PIT IRQ0 64-bit Hardware Timer Active", 0

str_win2_title:     db "Cyber Canvas & Interactive Vector Visualizer", 0
str_btn_clear:      db "Clear Canvas", 0
str_btn_art:        db "Draw Cyber Art", 0
str_canvas_hint:    db "Mouse/Space: Draw | Keys 1-8: Colors | C: Clear | D: Art", 0
str_canvas_banner:  db " [ ANTIGRAVITY OS 64-BIT GUI ] ", 0

str_footer_left:    db " i3: Alt/F1-F4: Switch WS | Shift+F1-F4: Move Win | Esc: CLI", 0
str_footer_right:   db "x86_64 Long Mode (4GB RAM)", 0
