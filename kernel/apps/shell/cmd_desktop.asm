; ==============================================================================
; Shell commands: desktop (gui, browser, ws, exit)
; Handlers: RSI = arguments; may clobber any register except RSP.
; ==============================================================================

[bits 64]

section .rodata
msg_gui_running:    db "The desktop is already running.", 0x0A, 0
msg_gui_no_bga:     db "No BGA display adapter found (QEMU: -vga std). The desktop needs one.", 0x0A, 0
msg_gui_no_ram:     db "The desktop needs at least 32 MB of RAM (QEMU: -m 256M).", 0x0A, 0
msg_ws_current:     db "Workspace ", 0
msg_ws_windows:     db " is active. Windows:", 0x0A, 0
msg_ws_on:          db " on workspace ", 0
msg_ws_closed:      db " (closed)", 0
msg_ws_min:         db " (minimized)", 0
msg_ws_usage:       db "Usage: ws [1-4]  or  ws move [1-4]", 0x0A, 0
arg_move:           db "move", 0

section .text
; cmd_gui_check: CF=1 (with a message) if the desktop cannot start
cmd_gui_check:
    cmp byte [bga_active], 0
    jne .running
    cmp byte [bga_available], 1
    jne .no_bga
    cmp qword [mem_total_bytes], GUI_MIN_RAM
    jb .no_ram
    clc
    ret
.running:
    lea rsi, [msg_gui_running]
    jmp .fail
.no_bga:
    lea rsi, [msg_gui_no_bga]
    jmp .fail
.no_ram:
    lea rsi, [msg_gui_no_ram]
.fail:
    mov bl, COLOR_YELLOW
    call con_puts_color
    stc
    ret

; cmd_gui_session: run the desktop, opening window AL first (WIN_NONE = none),
; then restore the text console
cmd_gui_session:
    mov [gui_launch_window], al
    call gui_run
    call con_clear
    jmp kernel_print_banner

cmd_gui:
    call cmd_gui_check
    jc .done
    mov al, WIN_NONE
    call cmd_gui_session
.done:
    ret

cmd_browser:
    cmp byte [rsi], 0
    je .no_url
    call browser_set_url            ; navigated when the window opens
.no_url:
    cmp byte [bga_active], 0
    je .start_desktop
    mov al, WIN_BROWSER
    jmp wm_open
.start_desktop:
    call cmd_gui_check
    jc .done
    mov al, WIN_BROWSER
    call cmd_gui_session
.done:
    ret

cmd_exit:
    mov al, WIN_TERM
    jmp wm_close

cmd_ws:
    cmp byte [rsi], 0
    je .status
    lea rdi, [arg_move]
    call str_has_prefix
    jne .switch
    add rsi, 4
    call skip_spaces
    call parse_dec
    jc .usage
    cmp rax, 1
    jb .usage
    cmp rax, WM_WORKSPACES
    ja .usage
    mov bl, WIN_TERM
    jmp wm_move_to_workspace
.switch:
    call parse_dec
    jc .usage
    cmp rax, 1
    jb .usage
    cmp rax, WM_WORKSPACES
    ja .usage
    jmp wm_switch_workspace

.status:
    lea rsi, [msg_ws_current]
    call con_puts
    movzx eax, byte [wm_active_ws]
    call con_dec
    lea rsi, [msg_ws_windows]
    call con_puts
    xor r12d, r12d
.win_loop:
    mov eax, r12d
    call wm_window_ptr              ; RBX = window
    call con_spaces_2
    mov rsi, [rbx + WIN_LABEL]
    call con_puts
    lea rsi, [msg_ws_on]
    call con_puts
    movzx eax, byte [rbx + WIN_WS]
    call con_dec
    cmp byte [rbx + WIN_STATE], WIN_STATE_CLOSED
    jne .not_closed
    lea rsi, [msg_ws_closed]
    call con_puts
.not_closed:
    cmp byte [rbx + WIN_STATE], WIN_STATE_MINIMIZED
    jne .not_min
    lea rsi, [msg_ws_min]
    call con_puts
.not_min:
    call con_newline
    inc r12d
    cmp r12d, WIN_COUNT
    jb .win_loop
    ret
.usage:
    mov bl, COLOR_YELLOW
    lea rsi, [msg_ws_usage]
    jmp con_puts_color
