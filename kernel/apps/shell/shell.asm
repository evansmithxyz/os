; ==============================================================================
; Antigravity OS - Command Shell (line editor, history, dispatch, completion)
; ------------------------------------------------------------------------------
; The shell is fed key events with shell_key (AX = key event, see
; drivers/keyboard.asm). It is used by BOTH the text console (kernel_loop) and
; the GUI terminal window (apps/terminal.asm); all output goes through the
; console layer, so it lands on whichever screen is active.
;
; Commands are defined in one table in apps/shell/commands.asm - see the
; COMMAND macro there. Dispatch, `help` and Tab completion all read that table.
; ==============================================================================

[bits 64]

SHELL_INPUT_MAX         equ 128
SHELL_HISTORY           equ 16      ; power of two
SHELL_WORD_MAX          equ 64

; Command table entry (built by the COMMAND macro)
CMD_NAME                equ 0       ; dq -> name
CMD_HANDLER             equ 8       ; dq -> handler (0 for section headings)
CMD_HELP                equ 16      ; dq -> help text ("" = alias, not listed)
CMD_FLAGS               equ 24      ; dq flags
CMD_ENTRY_SIZE          equ 32

CMDF_FILEARG            equ 0x01    ; Tab completes file names for this command
CMDF_HIDDEN             equ 0x02    ; not shown in help or completion
CMDF_HEADING            equ 0x04    ; section heading in help output only
CMDF_DESKTOP            equ 0x08    ; only works inside the desktop terminal

section .data
shell_input_len:        dq 0
shell_hist_count:       dd 0        ; entries stored (<= SHELL_HISTORY)
shell_hist_next:        dd 0        ; slot for the next entry
shell_hist_view:        dd 0        ; how far back Up has gone (0 = editing)

section .bss
alignb 16
shell_input:            resb SHELL_INPUT_MAX
shell_exec_line:        resb SHELL_INPUT_MAX
shell_history:          resb SHELL_HISTORY * SHELL_INPUT_MAX
shell_word:             resb SHELL_WORD_MAX
shell_arg:              resb SHELL_WORD_MAX

section .rodata
shell_prompt:           db "antigravity64> ", 0
shell_msg_unknown:      db "Unknown command: ", 0
shell_msg_unknown2:     db ". Type 'help' for the list of commands.", 0x0A, 0
shell_msg_ctrl_c:       db "^C", 0x0A, 0
shell_msg_desktop_only: db "This command only works in the desktop terminal (run 'gui' first).", 0x0A, 0
shell_two_spaces:       db "  ", 0

section .text
; ------------------------------------------------------------------------------
; shell_init: print the first prompt
; ------------------------------------------------------------------------------
shell_init:
    mov qword [shell_input_len], 0
    mov byte [shell_input], 0
    jmp shell_print_prompt

shell_print_prompt:
    push rbx
    push rsi
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [shell_prompt]
    call con_puts_color
    pop rsi
    pop rbx
    ret

; ------------------------------------------------------------------------------
; shell_key: AX = key event. Edits the input line; Enter runs it.
; ------------------------------------------------------------------------------
shell_key:
    push rax
    push rcx
    cmp al, 0x0D
    je .enter
    cmp al, 0x08
    je .backspace
    cmp al, 0x09
    je .tab
    cmp al, 3
    je .ctrl_c
    test al, al
    jz .special
    cmp al, 32
    jb .done
    cmp al, 126
    ja .done
    ; printable: append + echo
    mov rcx, [shell_input_len]
    cmp rcx, SHELL_INPUT_MAX - 1
    jae .done
    lea rcx, [shell_input]
    add rcx, [shell_input_len]
    mov [rcx], al
    mov byte [rcx + 1], 0
    inc qword [shell_input_len]
    call con_putc
    jmp .done

.backspace:
    cmp qword [shell_input_len], 0
    je .done
    dec qword [shell_input_len]
    lea rcx, [shell_input]
    add rcx, [shell_input_len]
    mov byte [rcx], 0
    mov al, 0x08
    call con_putc
    jmp .done

.tab:
    call shell_tab_complete
    jmp .done

.ctrl_c:
    push rsi
    lea rsi, [shell_msg_ctrl_c]
    call con_puts
    pop rsi
    mov qword [shell_input_len], 0
    mov byte [shell_input], 0
    mov dword [shell_hist_view], 0
    call shell_print_prompt
    jmp .done

.special:
    cmp ah, SC_UP
    je .hist_up
    cmp ah, SC_DOWN
    je .hist_down
    jmp .done
.hist_up:
    mov eax, [shell_hist_view]
    cmp eax, [shell_hist_count]
    jae .done
    inc eax
    mov [shell_hist_view], eax
    call shell_show_history
    jmp .done
.hist_down:
    mov eax, [shell_hist_view]
    test eax, eax
    jz .done
    dec eax
    mov [shell_hist_view], eax
    call shell_show_history
    jmp .done

.enter:
    call shell_submit
.done:
    pop rcx
    pop rax
    ret

; shell_show_history: replace the input line with history entry shell_hist_view
; (0 = empty line)
shell_show_history:
    push rax
    push rcx
    push rsi
    push rdi
    mov rcx, [shell_input_len]      ; erase what is on screen
    mov al, 0x08
.erase:
    test rcx, rcx
    jz .erased
    call con_putc
    dec rcx
    jmp .erase
.erased:
    mov byte [shell_input], 0
    mov eax, [shell_hist_view]
    test eax, eax
    jz .show
    mov ecx, [shell_hist_next]      ; slot = (next - view) mod SHELL_HISTORY
    sub ecx, eax
    and ecx, SHELL_HISTORY - 1
    imul ecx, SHELL_INPUT_MAX
    lea rsi, [shell_history]
    add rsi, rcx
    lea rdi, [shell_input]
    mov ecx, SHELL_INPUT_MAX
    call strlcpy
.show:
    lea rsi, [shell_input]
    call strlen
    mov [shell_input_len], rax
    call con_puts
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; shell_submit: run the current input line and start a new prompt
; ------------------------------------------------------------------------------
shell_submit:
    push rax
    push rcx
    push rsi
    push rdi
    call con_newline

    ; Copy the line out so commands may freely use shell_input
    lea rsi, [shell_input]
    lea rdi, [shell_exec_line]
    mov ecx, SHELL_INPUT_MAX
    call strlcpy

    ; Remember non-empty lines in the history
    lea rsi, [shell_input]
    call skip_spaces
    cmp byte [rsi], 0
    je .no_history
    mov eax, [shell_hist_next]
    imul eax, SHELL_INPUT_MAX
    lea rdi, [shell_history]
    add rdi, rax
    lea rsi, [shell_input]
    mov ecx, SHELL_INPUT_MAX
    call strlcpy
    mov eax, [shell_hist_next]
    inc eax
    and eax, SHELL_HISTORY - 1
    mov [shell_hist_next], eax
    cmp dword [shell_hist_count], SHELL_HISTORY
    jae .no_history
    inc dword [shell_hist_count]
.no_history:
    mov dword [shell_hist_view], 0
    mov qword [shell_input_len], 0
    mov byte [shell_input], 0

    lea rsi, [shell_exec_line]
    call shell_execute
    call shell_print_prompt
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; shell_execute: RSI = command line. Looks the first word up in the command
; table and calls its handler with RSI = the rest of the line (spaces skipped).
; Handlers may clobber any register except RSP; everything is restored here.
; ------------------------------------------------------------------------------
shell_execute:
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

    lea rdi, [shell_word]
    mov ecx, SHELL_WORD_MAX
    call next_word                  ; RSI -> arguments
    test rax, rax
    jz .done

    push rsi
    lea rsi, [shell_word]
    call shell_find_command         ; RBX = entry or 0
    pop rsi
    test rbx, rbx
    jz .unknown

    test qword [rbx + CMD_FLAGS], CMDF_DESKTOP
    jz .run
    cmp byte [bga_active], 0
    jne .run
    push rsi
    mov bl, COLOR_YELLOW
    lea rsi, [shell_msg_desktop_only]
    call con_puts_color
    pop rsi
    jmp .done
.run:
    call [rbx + CMD_HANDLER]
    jmp .done

.unknown:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [shell_msg_unknown]
    call con_puts_color
    lea rsi, [shell_word]
    call con_puts_color
    lea rsi, [shell_msg_unknown2]
    call con_puts_color
.done:
    mov byte [con_attr], COLOR_LIGHT_GRAY   ; commands must not leak colours
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

; ------------------------------------------------------------------------------
; shell_find_command: RSI = exact command name -> RBX = table entry or 0
; ------------------------------------------------------------------------------
shell_find_command:
    push rdi
    lea rbx, [shell_commands]
.loop:
    lea rdi, [shell_commands_end]
    cmp rbx, rdi
    jae .not_found
    test qword [rbx + CMD_FLAGS], CMDF_HEADING
    jnz .next
    mov rdi, [rbx + CMD_NAME]
    call strcmp
    je .found
.next:
    add rbx, CMD_ENTRY_SIZE
    jmp .loop
.not_found:
    xor ebx, ebx
.found:
    pop rdi
    ret

; ------------------------------------------------------------------------------
; shell_tab_complete: complete the command name, or a file name argument for
; commands flagged CMDF_FILEARG. One match completes; several are listed.
; ------------------------------------------------------------------------------
shell_tab_complete:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14

    lea rsi, [shell_input]
    call skip_spaces
    mov rdi, rsi                    ; find the end of the first word
.scan:
    mov al, [rdi]
    test al, al
    jz .complete_command
    cmp al, ' '
    je .argument
    inc rdi
    jmp .scan

.argument:
    ; Only complete if the first word is a file command
    push rsi
    xor ebx, ebx
    lea r12, [shell_word]
    mov rcx, rdi
    sub rcx, rsi
    cmp rcx, SHELL_WORD_MAX - 1
    jae .arg_too_long
    push rdi
    mov rdi, r12
    rep movsb
    mov byte [rdi], 0
    pop rdi
    lea rsi, [shell_word]
    call shell_find_command
.arg_too_long:
    pop rsi
    test rbx, rbx
    jz .done
    test qword [rbx + CMD_FLAGS], CMDF_FILEARG
    jz .done
    mov rsi, rdi
    call skip_spaces                ; RSI = argument prefix
    mov rdi, rsi
.arg_scan:                          ; only the first argument is completed
    cmp byte [rdi], 0
    je .arg_ok
    cmp byte [rdi], ' '
    je .done
    inc rdi
    jmp .arg_scan
.arg_ok:
    mov r13, rsi                    ; prefix
    call strlen
    mov r14, rax                    ; prefix length
    xor r12d, r12d                  ; match count
    xor edx, edx                    ; last match
    xor ecx, ecx
.file_loop:
    call fs_inode_ptr
    test byte [rax + INODE_FLAGS], FS_FLAG_ALLOC
    jz .file_next
    mov rsi, rax
    mov rdi, r13
    push rcx
    mov rcx, r14
    call strncmp
    pop rcx
    jne .file_next
    inc r12
    mov rdx, rax
.file_next:
    inc ecx
    cmp ecx, FS_MAX_INODES
    jb .file_loop
    test r12, r12
    jz .done
    cmp r12, 1
    jne .list_files
    lea rsi, [rdx + r14]
    call shell_append_completion
    jmp .done
.list_files:
    call con_newline
    xor ecx, ecx
.list_file_loop:
    call fs_inode_ptr
    test byte [rax + INODE_FLAGS], FS_FLAG_ALLOC
    jz .list_file_next
    mov rsi, rax
    mov rdi, r13
    push rcx
    mov rcx, r14
    call strncmp
    pop rcx
    jne .list_file_next
    mov bl, COLOR_LIGHT_GREEN
    call con_puts_color
    lea rsi, [shell_two_spaces]
    call con_puts
.list_file_next:
    inc ecx
    cmp ecx, FS_MAX_INODES
    jb .list_file_loop
    jmp .reprint

.complete_command:
    mov r13, rsi                    ; prefix
    call strlen
    mov r14, rax
    xor r12d, r12d
    xor edx, edx
    lea rbx, [shell_commands]
.cmd_loop:
    lea rax, [shell_commands_end]
    cmp rbx, rax
    jae .cmd_counted
    test qword [rbx + CMD_FLAGS], CMDF_HEADING | CMDF_HIDDEN
    jnz .cmd_next
    mov rsi, [rbx + CMD_NAME]
    mov rdi, r13
    mov rcx, r14
    call strncmp
    jne .cmd_next
    inc r12
    mov rdx, rsi
.cmd_next:
    add rbx, CMD_ENTRY_SIZE
    jmp .cmd_loop
.cmd_counted:
    test r12, r12
    jz .done
    cmp r12, 1
    jne .list_commands
    lea rsi, [rdx + r14]
    call shell_append_completion
    jmp .done
.list_commands:
    call con_newline
    lea rbx, [shell_commands]
.list_cmd_loop:
    lea rax, [shell_commands_end]
    cmp rbx, rax
    jae .reprint
    test qword [rbx + CMD_FLAGS], CMDF_HEADING | CMDF_HIDDEN
    jnz .list_cmd_next
    mov rsi, [rbx + CMD_NAME]
    mov rdi, r13
    mov rcx, r14
    call strncmp
    jne .list_cmd_next
    push rbx
    mov bl, COLOR_LIGHT_CYAN
    call con_puts_color
    pop rbx
    lea rsi, [shell_two_spaces]
    call con_puts
.list_cmd_next:
    add rbx, CMD_ENTRY_SIZE
    jmp .list_cmd_loop

.reprint:
    call con_newline
    call shell_print_prompt
    lea rsi, [shell_input]
    call con_puts
.done:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; shell_append_completion: RSI = text to add to the input line, then a space
shell_append_completion:
    push rax
    push rcx
    push rsi
.loop:
    lodsb
    test al, al
    jz .space
    call .append
    jmp .loop
.space:
    mov al, ' '
    call .append
    pop rsi
    pop rcx
    pop rax
    ret
.append:
    mov rcx, [shell_input_len]
    cmp rcx, SHELL_INPUT_MAX - 1
    jae .full
    push rdx
    lea rdx, [shell_input]
    mov [rdx + rcx], al
    mov byte [rdx + rcx + 1], 0
    pop rdx
    inc qword [shell_input_len]
    call con_putc
.full:
    ret
