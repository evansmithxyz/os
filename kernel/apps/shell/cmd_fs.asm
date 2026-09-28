; ==============================================================================
; Shell commands: files (ls, cat, touch, write, rm, df)
; Handlers: RSI = arguments; may clobber any register except RSP.
; ==============================================================================

[bits 64]

CAT_MAX_BYTES           equ 16384

section .bss
alignb 16
cmd_file_buf:           resb CAT_MAX_BYTES + 1

section .rodata
msg_ls_header:      db "NAME              SIZE     SECTORS  LBA", 0x0A, 0
msg_ls_empty:       db "(no files)", 0x0A, 0
msg_file_missing:   db "File not found: ", 0
msg_usage_cat:      db "Usage: cat <file>", 0x0A, 0
msg_usage_touch:    db "Usage: touch <file>   (names are 1-15 characters)", 0x0A, 0
msg_usage_write:    db "Usage: write <file> <text>", 0x0A, 0
msg_usage_rm:       db "Usage: rm <file>", 0x0A, 0
msg_touch_ok:       db "Created ", 0
msg_touch_fail:     db "Could not create the file (bad name, or disk/inode table full).", 0x0A, 0
msg_write_ok:       db "Wrote ", 0
msg_write_ok2:      db " bytes to ", 0
msg_write_fail:     db "Write failed.", 0x0A, 0
msg_rm_ok:          db "Removed ", 0
msg_cat_empty:      db "(empty file)", 0x0A, 0
msg_cat_io:         db "Disk read error.", 0x0A, 0
msg_cat_trunc:      db 0x0A, "[output truncated]", 0x0A, 0
msg_df_files:       db "Files:        ", 0
msg_df_of:          db " of ", 0
msg_df_inodes:      db " inodes used", 0x0A, 0
msg_df_data:        db "Data sectors: ", 0
msg_df_used:        db " used, ", 0
msg_df_free:        db " free (", 0
msg_df_kb:          db " KB free)", 0x0A, 0
msg_df_volume:      db "Volume:       LBA ", 0
msg_df_to:          db " - ", 0

section .text
; ------------------------------------------------------------------------------
; shell_arg_word: copy the next argument word into shell_arg -> RAX = length
; ------------------------------------------------------------------------------
shell_arg_word:
    push rcx
    push rdi
    lea rdi, [shell_arg]
    mov ecx, SHELL_WORD_MAX
    call next_word
    pop rdi
    pop rcx
    ret

; print "File not found: <shell_arg>"
cmd_say_missing:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_file_missing]
    call con_puts_color
    lea rsi, [shell_arg]
    call con_puts_color
    jmp con_newline

cmd_ls:
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [msg_ls_header]
    call con_puts_color
    xor ecx, ecx
    xor r12d, r12d
.loop:
    call fs_inode_ptr
    test byte [rax + INODE_FLAGS], FS_FLAG_ALLOC
    jz .next
    inc r12d
    mov r13, rax
    mov bl, COLOR_WHITE
    mov byte [con_attr], bl
    mov rsi, r13
    push rcx
    mov ecx, 18
    call con_puts_pad
    mov byte [con_attr], COLOR_LIGHT_GRAY
    mov eax, [r13 + INODE_SIZE]
    call cmd_print_dec_pad9
    movzx eax, word [r13 + INODE_SECTORS]
    call cmd_print_dec_pad9
    movzx eax, word [r13 + INODE_LBA]
    call con_dec
    call con_newline
    pop rcx
.next:
    inc ecx
    cmp ecx, FS_MAX_INODES
    jb .loop
    test r12d, r12d
    jnz .done
    mov bl, COLOR_DARK_GRAY
    lea rsi, [msg_ls_empty]
    call con_puts_color
.done:
    ret

; cmd_print_dec_pad9: RAX printed in decimal, left-aligned in 9 columns
cmd_print_dec_pad9:
    push rcx
    push rdx
    push rax
    mov ecx, 1                      ; digit count
    mov rdx, rax
.count:
    cmp rdx, 10
    jb .counted
    push rax
    mov rax, rdx
    xor edx, edx
    push rcx
    mov ecx, 10
    div rcx
    pop rcx
    mov rdx, rax
    pop rax
    inc ecx
    jmp .count
.counted:
    call con_dec
    neg rcx
    add rcx, 9
    call con_spaces
    pop rax
    pop rdx
    pop rcx
    ret

cmd_cat:
    call shell_arg_word
    test rax, rax
    jz .usage
    lea rsi, [shell_arg]
    call fs_find_file
    test rax, rax
    jz cmd_say_missing
    mov r12, rax
    mov ecx, [r12 + INODE_SIZE]
    test ecx, ecx
    jz .empty
    lea rdi, [cmd_file_buf]
    mov ecx, CAT_MAX_BYTES
    call fs_read_file
    test rax, rax
    jz .io
    mov rcx, rax
    lea rsi, [cmd_file_buf]
    mov r13, rsi
    add r13, rcx                    ; end
.print:
    cmp rsi, r13
    jae .printed
    lodsb
    cmp al, 0x0A
    je .out
    cmp al, 0x09
    jne .not_tab
    mov al, ' '
.not_tab:
    cmp al, 32
    jb .print                       ; drop other control characters
    cmp al, 126
    ja .print
.out:
    call con_putc
    jmp .print
.printed:
    cmp byte [rsi - 1], 0x0A
    je .check_trunc
    call con_newline
.check_trunc:
    mov eax, [r12 + INODE_SIZE]
    cmp eax, CAT_MAX_BYTES
    jbe .done
    mov bl, COLOR_DARK_GRAY
    lea rsi, [msg_cat_trunc]
    call con_puts_color
.done:
    ret
.empty:
    mov bl, COLOR_DARK_GRAY
    lea rsi, [msg_cat_empty]
    jmp con_puts_color
.io:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_cat_io]
    jmp con_puts_color
.usage:
    mov bl, COLOR_YELLOW
    lea rsi, [msg_usage_cat]
    jmp con_puts_color

cmd_touch:
    call shell_arg_word
    test rax, rax
    jz .usage
    lea rsi, [shell_arg]
    call fs_create_file
    test rax, rax
    jz .fail
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [msg_touch_ok]
    call con_puts_color
    lea rsi, [shell_arg]
    call con_puts_color
    jmp con_newline
.fail:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_touch_fail]
    jmp con_puts_color
.usage:
    mov bl, COLOR_YELLOW
    lea rsi, [msg_usage_touch]
    jmp con_puts_color

cmd_write:
    call shell_arg_word
    test rax, rax
    jz .usage
    cmp byte [rsi], 0
    je .usage
    mov rdx, rsi                    ; text = rest of the line
    call strlen
    mov rcx, rax
    mov r12, rax
    lea rsi, [shell_arg]
    call fs_write_content
    test rax, rax
    jnz .fail
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [msg_write_ok]
    call con_puts_color
    mov rax, r12
    call con_dec
    lea rsi, [msg_write_ok2]
    call con_puts_color
    lea rsi, [shell_arg]
    call con_puts_color
    jmp con_newline
.fail:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_write_fail]
    jmp con_puts_color
.usage:
    mov bl, COLOR_YELLOW
    lea rsi, [msg_usage_write]
    jmp con_puts_color

cmd_rm:
    call shell_arg_word
    test rax, rax
    jz .usage
    lea rsi, [shell_arg]
    call fs_delete_file
    test rax, rax
    jnz cmd_say_missing
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [msg_rm_ok]
    call con_puts_color
    lea rsi, [shell_arg]
    call con_puts_color
    jmp con_newline
.usage:
    mov bl, COLOR_YELLOW
    lea rsi, [msg_usage_rm]
    jmp con_puts_color

cmd_df:
    call fs_stats                   ; RAX = files, RDX = sectors used
    mov r12, rax
    mov r13, rdx
    mov bl, COLOR_LIGHT_CYAN
    mov [con_attr], bl
    lea rsi, [msg_df_files]
    call con_puts
    mov rax, r12
    call con_dec
    lea rsi, [msg_df_of]
    call con_puts
    mov eax, FS_MAX_INODES
    call con_dec
    lea rsi, [msg_df_inodes]
    call con_puts

    lea rsi, [msg_df_data]
    call con_puts
    mov rax, r13
    call con_dec
    lea rsi, [msg_df_used]
    call con_puts
    mov eax, FS_TOTAL_SECTORS - FS_DATA_LBA
    sub rax, r13
    mov r14, rax
    call con_dec
    lea rsi, [msg_df_free]
    call con_puts
    mov rax, r14
    shr rax, 1                      ; sectors -> KB
    call con_dec
    lea rsi, [msg_df_kb]
    call con_puts

    lea rsi, [msg_df_volume]
    call con_puts
    mov eax, FS_SUPERBLOCK_LBA
    call con_dec
    lea rsi, [msg_df_to]
    call con_puts
    mov eax, FS_TOTAL_SECTORS - 1
    call con_dec
    jmp con_newline
