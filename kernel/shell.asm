; ==============================================================================
; Antigravity OS - 64-bit Interactive Shell & Command Interpreter
; Integrated with AntigravityFS (AFS) Persistent Storage Subsystem
; ==============================================================================

[bits 64]

PROMPT_STR:         db "antigravity64> ", 0

; Command Identifiers
CMD_HELP:           db "help", 0
CMD_CLEAR:          db "clear", 0
CMD_CPU:            db "cpu", 0
CMD_MEM:            db "mem", 0
CMD_REGS:           db "regs", 0
CMD_TICKS:          db "ticks", 0
CMD_ECHO:           db "echo", 0
CMD_LS:             db "ls", 0
CMD_DIR:            db "dir", 0
CMD_CAT:            db "cat", 0
CMD_TOUCH:          db "touch", 0
CMD_WRITE:          db "write", 0
CMD_RM:             db "rm", 0
CMD_DF:             db "df", 0
CMD_REBOOT:         db "reboot", 0
CMD_HALT:           db "halt", 0
CMD_ABOUT:          db "about", 0
CMD_IFCONFIG:       db "ifconfig", 0
CMD_NET:            db "net", 0
CMD_PING:           db "ping", 0
CMD_ARP:            db "arp", 0
CMD_DNS:            db "dns", 0
CMD_NSLOOKUP:       db "nslookup", 0
CMD_CURL:           db "curl", 0
CMD_HTTP:           db "http", 0
CMD_TCPLISTEN:      db "tcplisten", 0
CMD_GUI:            db "gui", 0
CMD_DESKTOP:        db "desktop", 0
CMD_BROWSER:        db "browser", 0
CMD_WEB:            db "web", 0

STR_TWO_SPACES:     db "  ", 0

; Tab completion command pointers (sorted alphabetically)
tab_cmd_ptrs:
    dq CMD_ABOUT
    dq CMD_ARP
    dq CMD_BROWSER
    dq CMD_CAT
    dq CMD_CLEAR
    dq CMD_CPU
    dq CMD_CURL
    dq CMD_DESKTOP
    dq CMD_DF
    dq CMD_DIR
    dq CMD_DNS
    dq CMD_ECHO
    dq CMD_GUI
    dq CMD_HALT
    dq CMD_HELP
    dq CMD_HTTP
    dq CMD_IFCONFIG
    dq CMD_LS
    dq CMD_MEM
    dq CMD_NET
    dq CMD_NSLOOKUP
    dq CMD_PING
    dq CMD_REBOOT
    dq CMD_REGS
    dq CMD_RM
    dq CMD_TCPLISTEN
    dq CMD_TICKS
    dq CMD_TOUCH
    dq CMD_WRITE
    dq 0                        ; End of table marker

; Help messages
MSG_HELP_BANNER:    db "=== Antigravity OS [64-bit] Available Commands ===", 0x0A, 0
MSG_H_HELP:         db "  help               - Display this reference manual", 0x0A, 0
MSG_H_LS:           db "  ls / dir           - List files on the AntigravityFS volume", 0x0A, 0
MSG_H_CAT:          db "  cat <file>         - Display file contents from disk", 0x0A, 0
MSG_H_TOUCH:        db "  touch <file>       - Create a new empty file", 0x0A, 0
MSG_H_WRITE:        db "  write <file> <txt> - Write persistent text into file", 0x0A, 0
MSG_H_RM:           db "  rm <file>          - Delete a file from disk", 0x0A, 0
MSG_H_DF:           db "  df                 - Display filesystem storage statistics", 0x0A, 0
MSG_H_IFCONFIG:     db "  ifconfig / net     - Display RTL8139 NIC, IP & packet stats", 0x0A, 0
MSG_H_PING:         db "  ping <ip/domain>   - Send ICMP Echo Requests with latency timing", 0x0A, 0
MSG_H_ARP:          db "  arp                - Display Address Resolution Protocol cache", 0x0A, 0
MSG_H_DNS:          db "  dns <domain>       - Query DNS server 10.0.2.3 over UDP port 53", 0x0A, 0
MSG_H_CURL:         db "  curl <target> [p]  - HTTP client: fetch web page via TCP port 80", 0x0A, 0
MSG_H_TCPLISTEN:    db "  tcplisten [port]   - Run bare-metal HTTP web server on port 80", 0x0A, 0
MSG_H_GUI:          db "  gui / desktop      - Launch 1024x768 32bpp TrueColor graphical desktop", 0x0A, 0
MSG_H_BROWSER:      db "  browser / web      - Launch CyberSurf 64-bit HTML Web Browser", 0x0A, 0
MSG_H_REGS:         db "  regs               - Dump 64-bit CPU Registers (RAX-R15)", 0x0A, 0
MSG_H_MEM:          db "  mem                - Inspect 64-bit paging root (CR3) and stack", 0x0A, 0
MSG_H_CPU:          db "  cpu                - Query CPUID vendor string and family", 0x0A, 0
MSG_H_TICKS:        db "  ticks              - Show 64-bit PIT timer interrupt counter", 0x0A, 0
MSG_H_ECHO:         db "  echo <text>        - Print given text to screen", 0x0A, 0
MSG_H_CLEAR:        db "  clear              - Clear console screen and redraw banner", 0x0A, 0
MSG_H_ABOUT:        db "  about              - 64-bit Long Mode specifications", 0x0A, 0
MSG_H_REBOOT:       db "  reboot             - Reset system via 8042 keyboard controller", 0x0A, 0
MSG_H_HALT:         db "  halt               - Safely park CPU instruction execution", 0x0A, 0

MSG_UNKNOWN_CMD:    db "[ERROR] Unknown command. Type 'help' for commands.", 0x0A, 0
MSG_HALT_WARN:      db "64-bit CPU halted. Safe to power off or close emulator.", 0x0A, 0

MSG_ABOUT_TEXT:     db "Antigravity OS v2.0 [x86_64 Long Mode]", 0x0A
                    db "Architecture: AMD64 / Intel 64 Long Mode (64-bit Flat)", 0x0A
                    db "Storage Subsystem: Primary ATA Bus PIO Driver (Ports 0x1F0-0x1F7)", 0x0A
                    db "Filesystem: AntigravityFS (AFS) with 32-entry Inode Table", 0x0A
                    db "Paging: 4-Level Paging Active (PML4 -> PDPT -> PDT)", 0x0A
                    db "Interrupts: Dual 8259 PIC Remapped + 16-Byte IDT Gates", 0x0A, 0

; Filesystem Messages & Headers
MSG_LS_HEADER:      db "FILENAME          SIZE (BYTES)    LBA SECTOR", 0x0A
                    db "----------------  --------------  ----------", 0x0A, 0
MSG_NO_FILES:       db "(no files found on filesystem)", 0x0A, 0
STR_SPACES:         db "            ", 0
MSG_FILE_NOT_FOUND: db "[FS] Error: File not found!", 0x0A, 0
MSG_EMPTY_FILE:     db "(empty file)", 0x0A, 0
MSG_CAT_USAGE:      db "Usage: cat <filename>", 0x0A, 0
MSG_TOUCH_USAGE:    db "Usage: touch <filename>", 0x0A, 0
MSG_TOUCH_OK:       db "[FS] File created successfully.", 0x0A, 0
MSG_TOUCH_ERR:      db "[FS] Failed to create file (table or disk full).", 0x0A, 0
MSG_WRITE_USAGE:    db "Usage: write <filename> <text...>", 0x0A, 0
MSG_WRITE_OK:       db "[FS] File written and committed to disk.", 0x0A, 0
MSG_WRITE_ERR:      db "[FS] Failed to write file data.", 0x0A, 0
MSG_RM_USAGE:       db "Usage: rm <filename>", 0x0A, 0
MSG_RM_OK:          db "[FS] File removed from disk.", 0x0A, 0

MSG_DF_TITLE:       db "--- AntigravityFS Volume Statistics ---", 0x0A, 0
MSG_DF_INODES:      db "Allocated Inodes:   ", 0
MSG_DF_MAX_INODES:  db " / 32 files", 0x0A, 0
MSG_DF_SECTORS:     db "Volume Capacity:    ", 0
MSG_DF_KB:          db " sectors (64 KB)", 0x0A, 0

MSG_MEM_HEADER:     db "--- 64-Bit Memory Architecture ---", 0x0A, 0
MSG_MEM_CR3:        db "CR3 (PML4 Page Table Root):  ", 0
MSG_MEM_KERNEL:     db "Kernel Entry Point:          0x0000000000008000", 0x0A, 0
MSG_MEM_VGA:        db "VGA Framebuffer Address:     0x00000000000B8000", 0x0A, 0
MSG_MEM_STACK:      db "Current Stack Pointer (RSP): ", 0
MSG_TICKS_TEXT:     db "PIT IRQ0 Timer Ticks (64-bit): ", 0

cpu_vendor:         times 16 db 0
MSG_CPU_VENDOR:     db "CPU Vendor ID:              ", 0
MSG_CPU_SIGNATURE:  db "CPU Signature (Hex):        ", 0
MSG_CPU_LM:         db "x86_64 Long Mode Feature:   SUPPORTED & ACTIVE", 0x0A, 0

MSG_REGS_HEADER:    db "--- 64-bit General Purpose Registers ---", 0x0A, 0
STR_RAX:            db "RAX: ", 0
STR_RBX:            db "  RBX: ", 0
STR_RCX:            db "RCX: ", 0
STR_RDX:            db "  RDX: ", 0
STR_RSI:            db "RSI: ", 0
STR_RDI:            db "  RDI: ", 0
STR_RSP:            db "RSP: ", 0
STR_RBP:            db "  RBP: ", 0
STR_R8:             db "R8:  ", 0
STR_R9:             db "  R9:  ", 0
STR_R10:            db "R10: ", 0
STR_R11:            db "  R11: ", 0
STR_R12:            db "R12: ", 0
STR_R13:            db "  R13: ", 0
STR_R14:            db "R14: ", 0
STR_R15:            db "  R15: ", 0

fs_temp_name:       times 20 db 0
net_cmd_target:     times 64 db 0
net_target_ip:      times 4 db 0

; ------------------------------------------------------------------------------
; shell_print_prompt: Renders the 64-bit command line prompt
; ------------------------------------------------------------------------------
shell_print_prompt:
    push rax
    push rbx
    push rsi
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [PROMPT_STR]
    call vga_print_string_color
    pop rsi
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; shell_execute_command: Evaluates user input and executes matched utility
; ------------------------------------------------------------------------------
shell_execute_command:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r12
    push r13
    push r14

    lea rsi, [input_buffer]
    call skip_spaces

    cmp byte [rsi], 0
    je .done

    ; Match "help"
    lea rdi, [CMD_HELP]
    call match_command
    jz .do_help

    ; Match "clear"
    lea rdi, [CMD_CLEAR]
    call match_command
    jz .do_clear

    ; Match "ls" or "dir"
    lea rdi, [CMD_LS]
    call match_command
    jz .do_ls
    lea rdi, [CMD_DIR]
    call match_command
    jz .do_ls

    ; Match "df"
    lea rdi, [CMD_DF]
    call match_command
    jz .do_df

    ; Match "cpu"
    lea rdi, [CMD_CPU]
    call match_command
    jz .do_cpu

    ; Match "regs"
    lea rdi, [CMD_REGS]
    call match_command
    jz .do_regs

    ; Match "mem"
    lea rdi, [CMD_MEM]
    call match_command
    jz .do_mem

    ; Match "ticks"
    lea rdi, [CMD_TICKS]
    call match_command
    jz .do_ticks

    ; Match "about"
    lea rdi, [CMD_ABOUT]
    call match_command
    jz .do_about

    ; Match "reboot"
    lea rdi, [CMD_REBOOT]
    call match_command
    jz .do_reboot

    ; Match "halt"
    lea rdi, [CMD_HALT]
    call match_command
    jz .do_halt

    ; Match "ifconfig" or "net"
    lea rdi, [CMD_IFCONFIG]
    call match_command
    jz .do_ifconfig
    lea rdi, [CMD_NET]
    call match_command
    jz .do_ifconfig

    ; Match "arp"
    lea rdi, [CMD_ARP]
    call match_command
    jz .do_arp

    ; Match "gui" or "desktop"
    lea rdi, [CMD_GUI]
    call match_command
    jz .do_gui
    lea rdi, [CMD_DESKTOP]
    call match_command
    jz .do_gui

    ; Match "browser" or "web"
    lea rdi, [CMD_BROWSER]
    call match_command
    jz .do_browser
    lea rdi, [CMD_WEB]
    call match_command
    jz .do_browser

    ; Match "tcplisten"
    lea rdi, [CMD_TCPLISTEN]
    mov rcx, 9
    call strncmp
    jz .check_tcplisten_space

    ; Prefix: "ping "
    lea rdi, [CMD_PING]
    mov rcx, 4
    call strncmp
    jz .check_ping_space

    ; Prefix: "dns "
    lea rdi, [CMD_DNS]
    mov rcx, 3
    call strncmp
    jz .check_dns_space

    ; Prefix: "nslookup "
    lea rdi, [CMD_NSLOOKUP]
    mov rcx, 8
    call strncmp
    jz .check_nslookup_space

    ; Prefix: "curl "
    lea rdi, [CMD_CURL]
    mov rcx, 4
    call strncmp
    jz .check_curl_space

    ; Prefix: "http "
    lea rdi, [CMD_HTTP]
    mov rcx, 4
    call strncmp
    jz .check_http_space

    ; Prefix: "cat "
    lea rdi, [CMD_CAT]
    mov rcx, 3
    call strncmp
    jz .check_cat_space

    ; Prefix: "touch "
    lea rdi, [CMD_TOUCH]
    mov rcx, 5
    call strncmp
    jz .check_touch_space

    ; Prefix: "write "
    lea rdi, [CMD_WRITE]
    mov rcx, 5
    call strncmp
    jz .check_write_space

    ; Prefix: "rm "
    lea rdi, [CMD_RM]
    mov rcx, 2
    call strncmp
    jz .check_rm_space

    ; Prefix: "echo "
    lea rdi, [CMD_ECHO]
    mov rcx, 4
    call strncmp
    jz .do_echo

    ; Unknown command
    mov bl, COLOR_LIGHT_RED
    lea rsi, [MSG_UNKNOWN_CMD]
    call vga_print_string_color
    jmp .done

.check_ping_space:
    cmp byte [rsi + 4], ' '
    je .do_ping
    cmp byte [rsi + 4], 0
    je .ping_usage
    jmp .unknown_cmd

.check_dns_space:
    cmp byte [rsi + 3], ' '
    je .do_dns
    cmp byte [rsi + 3], 0
    je .dns_usage
    jmp .unknown_cmd

.check_nslookup_space:
    cmp byte [rsi + 8], ' '
    je .do_nslookup
    cmp byte [rsi + 8], 0
    je .dns_usage
    jmp .unknown_cmd

.check_curl_space:
    cmp byte [rsi + 4], ' '
    je .do_curl
    cmp byte [rsi + 4], 0
    je .curl_usage
    jmp .unknown_cmd

.check_http_space:
    cmp byte [rsi + 4], ' '
    je .do_http
    cmp byte [rsi + 4], 0
    je .curl_usage
    jmp .unknown_cmd

.check_tcplisten_space:
    cmp byte [rsi + 9], ' '
    je .do_tcplisten_arg
    cmp byte [rsi + 9], 0
    je .do_tcplisten_default
    jmp .unknown_cmd

.check_cat_space:
    cmp byte [rsi + 3], ' '
    je .do_cat
    cmp byte [rsi + 3], 0
    je .cat_usage
    jmp .unknown_cmd

.check_touch_space:
    cmp byte [rsi + 5], ' '
    je .do_touch
    cmp byte [rsi + 5], 0
    je .touch_usage
    jmp .unknown_cmd

.check_write_space:
    cmp byte [rsi + 5], ' '
    je .do_write
    cmp byte [rsi + 5], 0
    je .write_usage
    jmp .unknown_cmd

.check_rm_space:
    cmp byte [rsi + 2], ' '
    je .do_rm
    cmp byte [rsi + 2], 0
    je .rm_usage
    jmp .unknown_cmd

.unknown_cmd:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [MSG_UNKNOWN_CMD]
    call vga_print_string_color
    jmp .done

.do_help:
    mov bl, COLOR_YELLOW
    lea rsi, [MSG_HELP_BANNER]
    call vga_print_string_color

    mov bl, COLOR_LIGHT_GRAY
    lea rsi, [MSG_H_HELP]
    call vga_print_string_color
    lea rsi, [MSG_H_LS]
    call vga_print_string_color
    lea rsi, [MSG_H_CAT]
    call vga_print_string_color
    lea rsi, [MSG_H_TOUCH]
    call vga_print_string_color
    lea rsi, [MSG_H_WRITE]
    call vga_print_string_color
    lea rsi, [MSG_H_RM]
    call vga_print_string_color
    lea rsi, [MSG_H_DF]
    call vga_print_string_color
    lea rsi, [MSG_H_IFCONFIG]
    call vga_print_string_color
    lea rsi, [MSG_H_PING]
    call vga_print_string_color
    lea rsi, [MSG_H_ARP]
    call vga_print_string_color
    lea rsi, [MSG_H_DNS]
    call vga_print_string_color
    lea rsi, [MSG_H_CURL]
    call vga_print_string_color
    lea rsi, [MSG_H_TCPLISTEN]
    call vga_print_string_color
    lea rsi, [MSG_H_GUI]
    call vga_print_string_color
    lea rsi, [MSG_H_BROWSER]
    call vga_print_string_color
    lea rsi, [MSG_H_REGS]
    call vga_print_string_color
    lea rsi, [MSG_H_MEM]
    call vga_print_string_color
    lea rsi, [MSG_H_CPU]
    call vga_print_string_color
    lea rsi, [MSG_H_TICKS]
    call vga_print_string_color
    lea rsi, [MSG_H_ECHO]
    call vga_print_string_color
    lea rsi, [MSG_H_CLEAR]
    call vga_print_string_color
    lea rsi, [MSG_H_ABOUT]
    call vga_print_string_color
    lea rsi, [MSG_H_REBOOT]
    call vga_print_string_color
    lea rsi, [MSG_H_HALT]
    call vga_print_string_color
    jmp .done

.do_browser:
    mov byte [win_focused], 3
    call gui_run
    call vga_clear_screen
    call kernel_print_banner
    jmp .done

.do_gui:
    call gui_run
    call vga_clear_screen
    call kernel_print_banner
    jmp .done

.do_clear:
    call vga_clear_screen
    call kernel_print_banner
    jmp .done

.do_ls:
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [MSG_LS_HEADER]
    call vga_print_string_color

    xor r14, r14                ; R14 = inode index (0 .. 31)
    xor r12, r12                ; R12 = file counter

.ls_loop:
    mov rax, r14
    shl rax, 5
    lea r13, [fs_inode_table + rax]
    test byte [r13 + 24], FS_FLAG_ALLOC
    jz .ls_next

    inc r12

    ; Print filename in White
    mov bl, COLOR_WHITE
    mov rsi, r13
    call vga_print_string_color

    ; Pad to column 18
    mov rsi, r13
    call strlen
    mov rcx, 18
    sub rcx, rax
    cmp rcx, 1
    jl .ls_print_size
.ls_pad:
    mov al, ' '
    call vga_print_char
    loop .ls_pad

.ls_print_size:
    ; Print size in bytes
    mov eax, [r13 + 16]
    call vga_print_dec

    ; Space padding
    lea rsi, [STR_SPACES]
    call vga_print_string

    ; Print start LBA sector
    movzx rax, word [r13 + 20]
    call vga_print_dec

    mov al, 0x0A
    call vga_print_char

.ls_next:
    inc r14
    cmp r14, FS_MAX_INODES
    jl .ls_loop

    test r12, r12
    jnz .done

    mov bl, COLOR_DARK_GRAY
    lea rsi, [MSG_NO_FILES]
    call vga_print_string_color
    jmp .done

.do_cat:
    add rsi, 4                  ; Skip "cat "
    call skip_spaces
    cmp byte [rsi], 0
    je .cat_usage

    ; Copy filename argument to fs_temp_name
    lea rdi, [fs_temp_name]
    mov rcx, 15
.copy_cat_name:
    lodsb
    cmp al, ' '
    je .cat_name_end
    cmp al, 0
    je .cat_name_nul
    stosb
    loop .copy_cat_name
.cat_name_end:
.cat_name_nul:
    xor al, al
    stosb

    lea rsi, [fs_temp_name]
    call fs_find_file
    test rax, rax
    jz .cat_not_found

    ; Read file content from start LBA
    mov rbx, rax
    movzx rax, word [rbx + 20]  ; start LBA
    lea rdi, [fs_sector_buf]
    call ata_read_sector

    mov ecx, [rbx + 16]         ; size
    test ecx, ecx
    jz .cat_empty

    ; Print characters up to size bytes
    lea rsi, [fs_sector_buf]
.cat_loop:
    lodsb
    call vga_print_char
    dec ecx
    jnz .cat_loop

    mov al, 0x0A
    call vga_print_char
    jmp .done

.cat_empty:
    mov bl, COLOR_DARK_GRAY
    lea rsi, [MSG_EMPTY_FILE]
    call vga_print_string_color
    jmp .done

.cat_not_found:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [MSG_FILE_NOT_FOUND]
    call vga_print_string_color
    jmp .done

.cat_usage:
    mov bl, COLOR_YELLOW
    lea rsi, [MSG_CAT_USAGE]
    call vga_print_string_color
    jmp .done

.do_touch:
    add rsi, 6                  ; Skip "touch "
    call skip_spaces
    cmp byte [rsi], 0
    je .touch_usage

    ; Copy filename argument to fs_temp_name
    lea rdi, [fs_temp_name]
    mov rcx, 15
.copy_t_name:
    lodsb
    cmp al, ' '
    je .t_name_end
    cmp al, 0
    je .t_name_nul
    stosb
    loop .copy_t_name
.t_name_end:
.t_name_nul:
    xor al, al
    stosb

    lea rsi, [fs_temp_name]
    call fs_create_file
    test rax, rax
    jz .touch_err

    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [MSG_TOUCH_OK]
    call vga_print_string_color
    jmp .done

.touch_err:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [MSG_TOUCH_ERR]
    call vga_print_string_color
    jmp .done

.touch_usage:
    mov bl, COLOR_YELLOW
    lea rsi, [MSG_TOUCH_USAGE]
    call vga_print_string_color
    jmp .done

.do_write:
    add rsi, 6                  ; Skip "write "
    call skip_spaces
    cmp byte [rsi], 0
    je .write_usage

    ; Copy filename to fs_temp_name
    lea rdi, [fs_temp_name]
    mov rcx, 15
.copy_w_name:
    lodsb
    cmp al, ' '
    je .w_name_end
    cmp al, 0
    je .write_usage
    stosb
    loop .copy_w_name
.w_name_end:
    xor al, al
    stosb

    call skip_spaces
    mov rdx, rsi                ; RDX = text content
    call strlen
    mov rcx, rax                ; RCX = text length

    lea rsi, [fs_temp_name]
    call fs_write_content
    test rax, rax
    jnz .write_err

    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [MSG_WRITE_OK]
    call vga_print_string_color
    jmp .done

.write_err:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [MSG_WRITE_ERR]
    call vga_print_string_color
    jmp .done

.write_usage:
    mov bl, COLOR_YELLOW
    lea rsi, [MSG_WRITE_USAGE]
    call vga_print_string_color
    jmp .done

.do_rm:
    add rsi, 3                  ; Skip "rm "
    call skip_spaces
    cmp byte [rsi], 0
    je .rm_usage

    ; Copy filename argument to fs_temp_name
    lea rdi, [fs_temp_name]
    mov rcx, 15
.copy_rm_name:
    lodsb
    cmp al, ' '
    je .rm_name_end
    cmp al, 0
    je .rm_name_nul
    stosb
    loop .copy_rm_name
.rm_name_end:
.rm_name_nul:
    xor al, al
    stosb

    lea rsi, [fs_temp_name]
    call fs_delete_file
    test rax, rax
    jnz .rm_err

    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [MSG_RM_OK]
    call vga_print_string_color
    jmp .done

.rm_err:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [MSG_FILE_NOT_FOUND]
    call vga_print_string_color
    jmp .done

.rm_usage:
    mov bl, COLOR_YELLOW
    lea rsi, [MSG_RM_USAGE]
    call vga_print_string_color
    jmp .done

.do_df:
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [MSG_DF_TITLE]
    call vga_print_string_color

    ; Count active inodes
    xor ebx, ebx
    xor ecx, ecx
.df_loop:
    mov rax, rbx
    shl rax, 5
    lea rax, [fs_inode_table + rax]
    test byte [rax + 24], FS_FLAG_ALLOC
    jz .df_next
    inc ecx
.df_next:
    inc ebx
    cmp ebx, FS_MAX_INODES
    jl .df_loop

    lea rsi, [MSG_DF_INODES]
    call vga_print_string
    mov eax, ecx
    call vga_print_dec
    lea rsi, [MSG_DF_MAX_INODES]
    call vga_print_string

    lea rsi, [MSG_DF_SECTORS]
    call vga_print_string
    mov eax, FS_TOTAL_SECTORS
    call vga_print_dec
    lea rsi, [MSG_DF_KB]
    call vga_print_string
    jmp .done

.do_cpu:
    xor eax, eax
    cpuid
    mov [cpu_vendor], ebx
    mov [cpu_vendor + 4], edx
    mov [cpu_vendor + 8], ecx
    mov byte [cpu_vendor + 12], 0

    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [MSG_CPU_VENDOR]
    call vga_print_string_color

    lea rsi, [cpu_vendor]
    call vga_print_string
    mov al, 0x0A
    call vga_print_char

    mov eax, 1
    cpuid
    lea rsi, [MSG_CPU_SIGNATURE]
    call vga_print_string_color
    call vga_print_hex32
    mov al, 0x0A
    call vga_print_char

    lea rsi, [MSG_CPU_LM]
    call vga_print_string_color
    jmp .done

.do_regs:
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [MSG_REGS_HEADER]
    call vga_print_string_color

    lea rsi, [STR_RAX]
    call vga_print_string
    mov rax, 0x1111222233334444
    call vga_print_hex64
    lea rsi, [STR_RBX]
    call vga_print_string
    mov rax, rbx
    call vga_print_hex64
    mov al, 0x0A
    call vga_print_char

    lea rsi, [STR_RCX]
    call vga_print_string
    mov rax, rcx
    call vga_print_hex64
    lea rsi, [STR_RDX]
    call vga_print_string
    mov rax, rdx
    call vga_print_hex64
    mov al, 0x0A
    call vga_print_char

    lea rsi, [STR_RSI]
    call vga_print_string
    mov rax, rsi
    call vga_print_hex64
    lea rsi, [STR_RDI]
    call vga_print_string
    mov rax, rdi
    call vga_print_hex64
    mov al, 0x0A
    call vga_print_char

    lea rsi, [STR_RSP]
    call vga_print_string
    mov rax, rsp
    call vga_print_hex64
    lea rsi, [STR_RBP]
    call vga_print_string
    mov rax, rbp
    call vga_print_hex64
    mov al, 0x0A
    call vga_print_char

    lea rsi, [STR_R8]
    call vga_print_string
    mov rax, r8
    call vga_print_hex64
    lea rsi, [STR_R9]
    call vga_print_string
    mov rax, r9
    call vga_print_hex64
    mov al, 0x0A
    call vga_print_char

    lea rsi, [STR_R10]
    call vga_print_string
    mov rax, r10
    call vga_print_hex64
    lea rsi, [STR_R11]
    call vga_print_string
    mov rax, r11
    call vga_print_hex64
    mov al, 0x0A
    call vga_print_char

    lea rsi, [STR_R12]
    call vga_print_string
    mov rax, r12
    call vga_print_hex64
    lea rsi, [STR_R13]
    call vga_print_string
    mov rax, r13
    call vga_print_hex64
    mov al, 0x0A
    call vga_print_char

    lea rsi, [STR_R14]
    call vga_print_string
    mov rax, r14
    call vga_print_hex64
    lea rsi, [STR_R15]
    call vga_print_string
    mov rax, r15
    call vga_print_hex64
    mov al, 0x0A
    call vga_print_char
    jmp .done

.do_mem:
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [MSG_MEM_HEADER]
    call vga_print_string_color

    lea rsi, [MSG_MEM_CR3]
    call vga_print_string
    mov rax, cr3
    call vga_print_hex64
    mov al, 0x0A
    call vga_print_char

    lea rsi, [MSG_MEM_KERNEL]
    call vga_print_string

    lea rsi, [MSG_MEM_VGA]
    call vga_print_string

    lea rsi, [MSG_MEM_STACK]
    call vga_print_string
    mov rax, rsp
    call vga_print_hex64
    mov al, 0x0A
    call vga_print_char
    jmp .done

.do_ticks:
    mov bl, COLOR_YELLOW
    lea rsi, [MSG_TICKS_TEXT]
    call vga_print_string_color
    mov rax, [timer_ticks]
    call vga_print_dec
    mov al, 0x0A
    call vga_print_char
    jmp .done

.do_about:
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [MSG_ABOUT_TEXT]
    call vga_print_string_color
    jmp .done

.do_echo:
    add rsi, 4
    call skip_spaces
    call vga_print_string
    mov al, 0x0A
    call vga_print_char
    jmp .done

.do_reboot:
    mov bl, COLOR_LIGHT_MAGENTA
    lea rsi, [.reboot_msg]
    call vga_print_string_color
    cli
.reboot_wait:
    in al, 0x64
    test al, 2
    jnz .reboot_wait
    mov al, 0xFE
    out 0x64, al
    hlt
.reboot_msg: db "Rebooting x86_64 system...", 0x0A, 0

.do_halt:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [MSG_HALT_WARN]
    call vga_print_string_color
    cli
    hlt
    jmp $

; ------------------------------------------------------------------------------
; Network Command Implementations
; ------------------------------------------------------------------------------

.do_ifconfig:
    cmp byte [net_present], 1
    je .ifconfig_show
    mov bl, COLOR_LIGHT_RED
    lea rsi, [.msg_no_nic]
    call vga_print_string_color
    jmp .done
.msg_no_nic: db "[NET] RTL8139 PCI NIC not detected or offline.", 0x0A, 0

.ifconfig_show:
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [.msg_hdr]
    call vga_print_string_color

    ; Status
    lea rsi, [.msg_status]
    call vga_print_string

    ; I/O Port
    lea rsi, [.msg_io]
    call vga_print_string
    mov ax, [net_io_base]
    call vga_print_hex16
    mov al, 0x0A
    call vga_print_char

    ; MAC Address: XX:XX:XX:XX:XX:XX
    lea rsi, [.msg_mac]
    call vga_print_string
    xor ecx, ecx
.mac_print:
    mov al, [net_mac + rcx]
    call vga_print_hex8
    cmp ecx, 5
    je .mac_done
    mov al, ':'
    call vga_print_char
    inc ecx
    jmp .mac_print
.mac_done:
    mov al, 0x0A
    call vga_print_char

    ; IPv4 Address
    lea rsi, [.msg_ip]
    call vga_print_string
    lea rsi, [net_ip]
    call vga_print_ip
    mov al, 0x0A
    call vga_print_char

    ; Netmask
    lea rsi, [.msg_mask]
    call vga_print_string
    lea rsi, [net_netmask]
    call vga_print_ip
    mov al, 0x0A
    call vga_print_char

    ; Gateway IP & MAC
    lea rsi, [.msg_gw]
    call vga_print_string
    lea rsi, [net_gateway]
    call vga_print_ip
    lea rsi, [.msg_gw_mac]
    call vga_print_string
    xor ecx, ecx
.gw_mac_loop:
    mov al, [gateway_mac + rcx]
    call vga_print_hex8
    cmp ecx, 5
    je .gw_mac_done
    mov al, ':'
    call vga_print_char
    inc ecx
    jmp .gw_mac_loop
.gw_mac_done:
    lea rsi, [.msg_close_paren]
    call vga_print_string

    ; DNS Server
    lea rsi, [.msg_dns]
    call vga_print_string
    lea rsi, [net_dns]
    call vga_print_ip
    mov al, 0x0A
    call vga_print_char

    ; Statistics: RX/TX Packets & Bytes
    lea rsi, [.msg_rx]
    call vga_print_string
    mov rax, [net_packets_rx]
    call vga_print_dec
    lea rsi, [.msg_bytes]
    call vga_print_string
    mov rax, [net_bytes_rx]
    call vga_print_dec
    lea rsi, [.msg_close_paren]
    call vga_print_string

    lea rsi, [.msg_tx]
    call vga_print_string
    mov rax, [net_packets_tx]
    call vga_print_dec
    lea rsi, [.msg_bytes]
    call vga_print_string
    mov rax, [net_bytes_tx]
    call vga_print_dec
    lea rsi, [.msg_close_paren]
    call vga_print_string

    jmp .done

.msg_hdr:         db "--- eth0: Realtek RTL8139 Fast Ethernet PCI ---", 0x0A, 0
.msg_status:      db "  Link Status:  UP, 100 Mbps Full Duplex, Bus Master", 0x0A, 0
.msg_io:          db "  I/O Port:     0x", 0
.msg_mac:         db "  MAC Address:  ", 0
.msg_ip:          db "  IPv4 Address: ", 0
.msg_mask:        db "  Subnet Mask:  ", 0
.msg_gw:          db "  Default GW:   ", 0
.msg_gw_mac:      db " (MAC: ", 0
.msg_dns:         db "  DNS Server:   ", 0
.msg_rx:          db "  RX Packets:   ", 0
.msg_tx:          db "  TX Packets:   ", 0
.msg_bytes:       db " (Bytes: ", 0
.msg_close_paren: db ")", 0x0A, 0

.do_arp:
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [.arp_hdr]
    call vga_print_string_color

    ; Print Default Gateway Static Entry
    lea rsi, [net_gateway]
    call vga_print_ip
    lea rsi, [.spc1]
    call vga_print_string
    xor ecx, ecx
.gw_arp_mac:
    mov al, [gateway_mac + rcx]
    call vga_print_hex8
    cmp ecx, 5
    je .gw_arp_done
    mov al, ':'
    call vga_print_char
    inc ecx
    jmp .gw_arp_mac
.gw_arp_done:
    lea rsi, [.arp_static]
    call vga_print_string

    ; Iterate through ARP cache (0..7)
    xor r14d, r14d
.arp_loop:
    cmp byte [arp_cache_valid + r14], 1
    jne .arp_next

    ; Print Cached IP
    lea rsi, [arp_cache_ip]
    mov eax, r14d
    shl eax, 2
    add rsi, rax
    call vga_print_ip

    lea rsi, [.spc1]
    call vga_print_string

    ; Print Cached MAC
    lea rsi, [arp_cache_mac]
    mov eax, r14d
    imul eax, 6
    add rsi, rax
    xor ecx, ecx
.cache_mac_print:
    mov al, [rsi + rcx]
    call vga_print_hex8
    cmp ecx, 5
    je .cache_mac_done
    mov al, ':'
    call vga_print_char
    inc ecx
    jmp .cache_mac_print
.cache_mac_done:
    lea rsi, [.arp_dynamic]
    call vga_print_string

.arp_next:
    inc r14d
    cmp r14d, ARP_CACHE_MAX
    jl .arp_loop

    jmp .done

.arp_hdr:     db "--- Address Resolution Protocol (ARP) Cache ---", 0x0A
              db "IP ADDRESS       MAC ADDRESS        TYPE", 0x0A, 0
.arp_static:  db "  STATIC (GATEWAY)", 0x0A, 0
.arp_dynamic: db "  DYNAMIC", 0x0A, 0
.spc1:        db "       ", 0

.do_ping:
    add rsi, 4                  ; Skip "ping"
    call skip_spaces
    cmp byte [rsi], 0
    je .ping_usage

    ; Extract target string into net_cmd_target
    lea rdi, [net_cmd_target]
    mov rcx, 63
.copy_ping_tgt:
    lodsb
    cmp al, ' '
    je .ping_tgt_end
    cmp al, 0
    je .ping_tgt_nul
    stosb
    loop .copy_ping_tgt
.ping_tgt_end:
.ping_tgt_nul:
    xor al, al
    stosb

    ; Try parsing as dotted IPv4
    lea rsi, [net_cmd_target]
    lea rdi, [net_target_ip]
    call net_parse_ip
    test rax, rax
    jz .ping_ip_ready

    ; Resolve domain name via DNS!
    mov bl, COLOR_LIGHT_BLUE
    lea rsi, [.msg_ping_res]
    call vga_print_string_color
    lea rsi, [net_cmd_target]
    call vga_print_string
    lea rsi, [.msg_dots]
    call vga_print_string_color

    lea rsi, [net_cmd_target]
    lea rdi, [net_target_ip]
    call dns_resolve
    test rax, rax
    jz .ping_ip_ready

    mov bl, COLOR_LIGHT_RED
    lea rsi, [.msg_ping_fail]
    call vga_print_string_color
    jmp .done

.ping_ip_ready:
    lea rsi, [net_target_ip]
    call icmp_ping
    jmp .done

.ping_usage:
    mov bl, COLOR_YELLOW
    lea rsi, [.msg_ping_use]
    call vga_print_string_color
    jmp .done

.msg_ping_use:  db "Usage: ping <ip or domain>  (e.g. ping 10.0.2.2 or ping google.com)", 0x0A, 0
.msg_ping_res:  db "Resolving ", 0
.msg_dots:      db "... ", 0
.msg_ping_fail: db "FAILED", 0x0A, "[PING] Error: Host could not be resolved.", 0x0A, 0

.do_nslookup:
    add rsi, 8                  ; Skip "nslookup"
    jmp .dns_common

.do_dns:
    add rsi, 3                  ; Skip "dns"
.dns_common:
    call skip_spaces
    cmp byte [rsi], 0
    je .dns_usage

    ; Extract domain argument
    lea rdi, [net_cmd_target]
    mov rcx, 63
.copy_dns_dom:
    lodsb
    cmp al, ' '
    je .dns_dom_end
    cmp al, 0
    je .dns_dom_nul
    stosb
    loop .copy_dns_dom
.dns_dom_end:
.dns_dom_nul:
    xor al, al
    stosb

    ; Query message
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [.msg_dns_query]
    call vga_print_string_color
    lea rsi, [net_cmd_target]
    call vga_print_string
    mov al, 0x0A
    call vga_print_char

    ; Resolve via UDP port 53
    lea rsi, [net_cmd_target]
    lea rdi, [net_target_ip]
    call dns_resolve
    test rax, rax
    jnz .dns_failed

    ; Success
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [.msg_dns_ans]
    call vga_print_string_color

    mov bl, COLOR_WHITE
    lea rsi, [.msg_dns_name]
    call vga_print_string_color
    lea rsi, [net_cmd_target]
    call vga_print_string
    mov al, 0x0A
    call vga_print_char

    lea rsi, [.msg_dns_addr]
    call vga_print_string_color
    lea rsi, [net_target_ip]
    call vga_print_ip
    mov al, 0x0A
    call vga_print_char
    jmp .done

.dns_failed:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [.msg_dns_err]
    call vga_print_string_color
    jmp .done

.dns_usage:
    mov bl, COLOR_YELLOW
    lea rsi, [.msg_dns_use]
    call vga_print_string_color
    jmp .done

.msg_dns_use:   db "Usage: dns <domain>  (e.g. dns google.com)", 0x0A, 0
.msg_dns_query: db "Querying DNS server 10.0.2.3 for ", 0
.msg_dns_ans:   db "Non-authoritative answer:", 0x0A, 0
.msg_dns_name:  db "  Name:    ", 0
.msg_dns_addr:  db "  Address: ", 0
.msg_dns_err:   db "[DNS] Error: Name resolution failed or query timed out.", 0x0A, 0

.do_http:
.do_curl:
    add rsi, 4                  ; Skip "curl" or "http"
    call skip_spaces
    cmp byte [rsi], 0
    je .curl_usage

    ; Extract target host
    lea rdi, [net_cmd_target]
    mov rcx, 63
.copy_curl_tgt:
    lodsb
    cmp al, ' '
    je .curl_tgt_end
    cmp al, 0
    je .curl_tgt_nul
    stosb
    loop .copy_curl_tgt
.curl_tgt_end:
.curl_tgt_nul:
    xor al, al
    stosb

    ; Check if optional port argument exists
    call skip_spaces
    cmp byte [rsi], 0
    je .curl_default_port
    call parse_dec
    mov dx, ax
    jmp .curl_resolve

.curl_default_port:
    mov dx, 80                  ; Standard HTTP port

.curl_resolve:
    push rdx                    ; Save port number

    ; Parse as IPv4 or resolve domain
    lea rsi, [net_cmd_target]
    lea rdi, [net_target_ip]
    call net_parse_ip
    test rax, rax
    jz .curl_ready

    ; Resolve domain
    mov bl, COLOR_LIGHT_BLUE
    lea rsi, [.msg_res]
    call vga_print_string_color
    lea rsi, [net_cmd_target]
    call vga_print_string
    lea rsi, [.msg_curl_dots]
    call vga_print_string_color

    lea rsi, [net_cmd_target]
    lea rdi, [net_target_ip]
    call dns_resolve
    test rax, rax
    jz .curl_resolved_ok

    pop rdx
    mov bl, COLOR_LIGHT_RED
    lea rsi, [.msg_dns_err]
    call vga_print_string_color
    jmp .done

.curl_resolved_ok:
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [.msg_ok]
    call vga_print_string_color
    lea rsi, [net_target_ip]
    call vga_print_ip
    mov al, 0x0A
    call vga_print_char

.curl_ready:
    pop rdx                     ; Restore port number
    lea rsi, [net_target_ip]
    lea rdi, [net_cmd_target]
    call tcp_http_client
    jmp .done

.curl_usage:
    mov bl, COLOR_YELLOW
    lea rsi, [.msg_curl_use]
    call vga_print_string_color
    jmp .done

.msg_curl_use:  db "Usage: curl <target> [port]  (e.g. curl 10.0.2.2 or curl 10.0.2.2 80)", 0x0A, 0
.msg_res:       db "Resolving ", 0
.msg_curl_dots: db "... ", 0
.msg_ok:        db "OK -> ", 0

.do_tcplisten_arg:
    add rsi, 9                  ; Skip "tcplisten"
    call skip_spaces
    cmp byte [rsi], 0
    je .do_tcplisten_default
    call parse_dec
    mov dx, ax
    call tcp_server_start
    jmp .done

.do_tcplisten_default:
    mov dx, 80                  ; Default HTTP port 80
    call tcp_server_start
    jmp .done

.done:
    pop r14
    pop r13
    pop r12
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
; parse_dec: Parses unsigned decimal ASCII integer from RSI
; Input:  RSI = string pointer
; Output: EAX = integer value, RSI advanced
; ------------------------------------------------------------------------------
parse_dec:
    push rbx
    push rdx
    xor eax, eax
.loop:
    movzx edx, byte [rsi]
    cmp dl, '0'
    jb .dec_done
    cmp dl, '9'
    ja .dec_done
    sub dl, '0'
    imul eax, 10
    add eax, edx
    inc rsi
    jmp .loop
.dec_done:
    pop rdx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; Helper: Skip leading spaces in RSI
; ------------------------------------------------------------------------------
skip_spaces:
.loop:
    cmp byte [rsi], ' '
    jne .done
    inc rsi
    jmp .loop
.done:
    ret

; ------------------------------------------------------------------------------
; Helper: Compute string length at RSI
; Returns: RAX = length
; ------------------------------------------------------------------------------
strlen:
    push rsi
    xor rax, rax
.loop:
    cmp byte [rsi + rax], 0
    je .done
    inc rax
    jmp .loop
.done:
    pop rsi
    ret

; ------------------------------------------------------------------------------
; String Comparison: RSI vs RDI, ZF=1 if equal
; Preserves RAX, RBX, RCX, RDX, RSI, RDI
; ------------------------------------------------------------------------------
strcmp:
    push rsi
    push rdi
    push rdx
.loop:
    mov dl, [rsi]
    cmp dl, [rdi]
    jne .diff
    test dl, dl
    jz .equal
    inc rsi
    inc rdi
    jmp .loop
.diff:
    pop rdx
    pop rdi
    pop rsi
    ret
.equal:
    pop rdx
    pop rdi
    pop rsi
    cmp eax, eax                ; Guarantees ZF=1, modifies no registers
    ret

; ------------------------------------------------------------------------------
; Substring Comparison: RSI vs RDI for RCX bytes, ZF=1 if matched
; Preserves RAX, RBX, RCX, RDX, RSI, RDI
; ------------------------------------------------------------------------------
strncmp:
    push rsi
    push rdi
    push rcx
    push rdx
.loop:
    test rcx, rcx
    jz .equal
    mov dl, [rsi]
    cmp dl, [rdi]
    jne .diff
    test dl, dl
    jz .equal
    inc rsi
    inc rdi
    dec rcx
    jmp .loop
.diff:
    pop rdx
    pop rcx
    pop rdi
    pop rsi
    ret
.equal:
    pop rdx
    pop rcx
    pop rdi
    pop rsi
    cmp eax, eax                ; Guarantees ZF=1, modifies no registers
    ret

; ------------------------------------------------------------------------------
; match_command: Compares command keyword at RDI with user input at RSI
; Returns: ZF=1 if matched and [RSI + len] is ' ' or 0
; Preserves RAX, RBX, RCX, RDX, RSI, RDI
; ------------------------------------------------------------------------------
match_command:
    push rsi
    push rdi
    push rdx
.loop:
    mov dl, [rdi]
    test dl, dl
    jz .cmd_end
    cmp dl, [rsi]
    jne .diff
    inc rsi
    inc rdi
    jmp .loop

.cmd_end:
    mov dl, [rsi]
    cmp dl, ' '
    je .matched
    cmp dl, 0
    je .matched
    jmp .diff

.matched:
    pop rdx
    pop rdi
    pop rsi
    cmp eax, eax                ; ZF=1
    ret

.diff:
    pop rdx
    pop rdi
    pop rsi
    test esp, esp               ; ZF=0 (ESP is non-zero)
    ret

; ------------------------------------------------------------------------------
; append_suffix_and_space: Appends suffix string at RSI to input_buffer and screen,
;                          followed by a space (unless already ending in a space).
; Input: RSI = null-terminated suffix string to append
; Preserves all general purpose registers
; ------------------------------------------------------------------------------
append_suffix_and_space:
    push rax
    push rcx
    push rsi

.loop:
    lodsb
    test al, al
    jz .check_space

    mov rcx, [input_len]
    cmp rcx, INPUT_BUFFER_MAX - 2
    jae .done

    mov [input_buffer + rcx], al
    inc qword [input_len]
    mov byte [input_buffer + rcx + 1], 0
    call vga_print_char
    jmp .loop

.check_space:
    mov rcx, [input_len]
    test rcx, rcx
    jz .do_space
    cmp byte [input_buffer + rcx - 1], ' '
    je .done

.do_space:
    cmp rcx, INPUT_BUFFER_MAX - 2
    jae .done
    mov byte [input_buffer + rcx], ' '
    inc qword [input_len]
    mov byte [input_buffer + rcx + 1], 0
    mov al, ' '
    call vga_print_char

.done:
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; shell_tab_complete: Bash-style Tab auto-completion engine
; Completes command names and on-disk AntigravityFS filenames
; ------------------------------------------------------------------------------
shell_tab_complete:
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

    ; Find start of first word in input_buffer
    lea rsi, [input_buffer]
.tab_skip_leading:
    cmp byte [rsi], ' '
    jne .tab_check_first_word
    inc rsi
    jmp .tab_skip_leading

.tab_check_first_word:
    ; Scan to see if there is a space separating command and argument
    mov rdi, rsi
.tab_find_spc:
    cmp byte [rdi], 0
    je .tab_cmd_mode            ; No space -> User is typing a command!
    cmp byte [rdi], ' '
    je .tab_found_spc           ; Space found -> Check if file command!
    inc rdi
    jmp .tab_find_spc

.tab_found_spc:
    ; First word is at RSI with length RCX = RDI - RSI
    mov rcx, rdi
    sub rcx, rsi

    ; Check if first word is a filesystem command that takes a filename
    ; "cat" (3)
    cmp rcx, 3
    jne .chk_touch
    cmp byte [rsi], 'c'
    jne .chk_touch
    cmp byte [rsi+1], 'a'
    jne .chk_touch
    cmp byte [rsi+2], 't'
    je .tab_file_mode

.chk_touch:
    ; "touch" (5)
    cmp rcx, 5
    jne .chk_write
    cmp byte [rsi], 't'
    jne .chk_write
    cmp byte [rsi+1], 'o'
    jne .chk_write
    cmp byte [rsi+2], 'u'
    jne .chk_write
    cmp byte [rsi+3], 'c'
    jne .chk_write
    cmp byte [rsi+4], 'h'
    je .tab_file_mode

.chk_write:
    ; "write" (5)
    cmp rcx, 5
    jne .chk_rm
    cmp byte [rsi], 'w'
    jne .chk_rm
    cmp byte [rsi+1], 'r'
    jne .chk_rm
    cmp byte [rsi+2], 'i'
    jne .chk_rm
    cmp byte [rsi+3], 't'
    jne .chk_rm
    cmp byte [rsi+4], 'e'
    je .tab_file_mode

.chk_rm:
    ; "rm" (2)
    cmp rcx, 2
    jne .chk_ls
    cmp byte [rsi], 'r'
    jne .chk_ls
    cmp byte [rsi+1], 'm'
    je .tab_file_mode

.chk_ls:
    ; "ls" (2)
    cmp rcx, 2
    jne .chk_dir
    cmp byte [rsi], 'l'
    jne .chk_dir
    cmp byte [rsi+1], 's'
    je .tab_file_mode

.chk_dir:
    ; "dir" (3)
    cmp rcx, 3
    jne .tab_not_file_cmd
    cmp byte [rsi], 'd'
    jne .tab_not_file_cmd
    cmp byte [rsi+1], 'i'
    jne .tab_not_file_cmd
    cmp byte [rsi+2], 'r'
    je .tab_file_mode

.tab_not_file_cmd:
    ; Command does not take filenames, do nothing
    jmp .tab_done

.tab_file_mode:
    ; RDI is currently pointing at ' ' after command.
    ; Skip spaces to find start of filename argument.
.tab_skip_arg_spc:
    cmp byte [rdi], ' '
    jne .tab_arg_start
    inc rdi
    jmp .tab_skip_arg_spc

.tab_arg_start:
    ; RDI points to filename argument prefix (or 0 if user just typed "cat ")
    ; Check if there is another space AFTER this argument word (e.g. for write text...)
    mov rbx, rdi
.tab_chk_trailing_spc:
    cmp byte [rbx], 0
    je .tab_valid_file_arg
    cmp byte [rbx], ' '
    je .tab_trailing_spc_found
    inc rbx
    jmp .tab_chk_trailing_spc

.tab_trailing_spc_found:
    ; Argument already finished with space, do not complete further
    jmp .tab_done

.tab_valid_file_arg:
    ; RDI points to filename prefix to match in fs_inode_table
    mov rsi, rdi
    call strlen
    mov r14, rax                ; R14 = L_arg (length of filename prefix)
    mov r15, rdi                ; R15 = pointer to typed filename prefix

    ; Scan fs_inode_table
    xor r12, r12                ; R12 = match count
    xor r13, r13                ; R13 = pointer to last matched inode filename
    xor r10, r10                ; R10 = inode index (0..31)

.tab_file_scan:
    mov rax, r10
    shl rax, 5
    lea rax, [fs_inode_table + rax]
    test byte [rax + 24], FS_FLAG_ALLOC
    jz .tab_file_next

    ; Check if filename in [rax] matches prefix at R15 (length R14)
    mov rcx, r14
    test rcx, rcx
    jz .tab_file_matched        ; If prefix is empty (L=0), all files match!

    mov r8, r15
    mov r9, rax
.tab_file_cmp:
    mov dl, [r8]
    cmp dl, [r9]
    jne .tab_file_next
    inc r8
    inc r9
    dec rcx
    jnz .tab_file_cmp

.tab_file_matched:
    inc r12
    mov r13, rax

.tab_file_next:
    inc r10
    cmp r10, FS_MAX_INODES
    jl .tab_file_scan

    ; Evaluate file matches
    test r12, r12
    jz .tab_done                ; 0 matches -> do nothing

    cmp r12, 1
    jne .tab_file_multiple

    ; EXACTLY 1 MATCH: Auto-complete suffix + space!
    lea rsi, [r13 + r14]        ; Start of suffix (after typed prefix)
    call append_suffix_and_space
    jmp .tab_done

.tab_file_multiple:
    ; Multiple file matches: print list and restore prompt
    mov al, 0x0A
    call vga_print_char

    ; Loop through matching files and print names
    xor r10, r10
.tab_file_print_loop:
    mov rax, r10
    shl rax, 5
    lea rax, [fs_inode_table + rax]
    test byte [rax + 24], FS_FLAG_ALLOC
    jz .tab_file_p_next

    mov rcx, r14
    test rcx, rcx
    jz .tab_file_p_do

    mov r8, r15
    mov r9, rax
.tab_file_p_cmp:
    mov dl, [r8]
    cmp dl, [r9]
    jne .tab_file_p_next
    inc r8
    inc r9
    dec rcx
    jnz .tab_file_p_cmp

.tab_file_p_do:
    mov bl, COLOR_LIGHT_GREEN
    mov rsi, rax
    call vga_print_string_color
    lea rsi, [STR_TWO_SPACES]
    call vga_print_string

.tab_file_p_next:
    inc r10
    cmp r10, FS_MAX_INODES
    jl .tab_file_print_loop

    ; End list of files with newline
    mov al, 0x0A
    call vga_print_char

    ; Re-render prompt and current line
    call shell_print_prompt
    lea rsi, [input_buffer]
    call vga_print_string
    jmp .tab_done

; ------------------------------------------------------------------------------
; Command Completion Branch
; ------------------------------------------------------------------------------
.tab_cmd_mode:
    ; RSI points to start of command prefix
    mov rdi, rsi
    call strlen
    mov r14, rax                ; R14 = L_cmd (prefix length)
    mov r15, rsi                ; R15 = pointer to typed command prefix

    ; Scan tab_cmd_ptrs table
    xor r12, r12                ; R12 = match count
    xor r13, r13                ; R13 = pointer to last matched command string
    xor r10, r10                ; R10 = table index (0, 1, 2...)

.tab_cmd_scan:
    mov rax, [tab_cmd_ptrs + r10 * 8]
    test rax, rax
    jz .tab_cmd_scan_done

    ; Compare prefix at R15 of length R14 against command at RAX
    mov rcx, r14
    test rcx, rcx
    jz .tab_cmd_matched

    mov r8, r15
    mov r9, rax
.tab_cmd_cmp:
    mov dl, [r8]
    cmp dl, [r9]
    jne .tab_cmd_next
    inc r8
    inc r9
    dec rcx
    jnz .tab_cmd_cmp

.tab_cmd_matched:
    inc r12
    mov r13, rax

.tab_cmd_next:
    inc r10
    jmp .tab_cmd_scan

.tab_cmd_scan_done:
    test r12, r12
    jz .tab_done

    cmp r12, 1
    jne .tab_cmd_multiple

    ; EXACTLY 1 MATCH: Complete suffix + space!
    lea rsi, [r13 + r14]
    call append_suffix_and_space
    jmp .tab_done

.tab_cmd_multiple:
    ; Multiple command matches: print list and restore prompt
    mov al, 0x0A
    call vga_print_char

    xor r10, r10
.tab_cmd_print_loop:
    mov rax, [tab_cmd_ptrs + r10 * 8]
    test rax, rax
    jz .tab_cmd_print_done

    mov rcx, r14
    test rcx, rcx
    jz .tab_cmd_p_do

    mov r8, r15
    mov r9, rax
.tab_cmd_p_cmp:
    mov dl, [r8]
    cmp dl, [r9]
    jne .tab_cmd_p_next
    inc r8
    inc r9
    dec rcx
    jnz .tab_cmd_p_cmp

.tab_cmd_p_do:
    mov bl, COLOR_LIGHT_CYAN
    mov rsi, rax
    call vga_print_string_color
    lea rsi, [STR_TWO_SPACES]
    call vga_print_string

.tab_cmd_p_next:
    inc r10
    jmp .tab_cmd_print_loop

.tab_cmd_print_done:
    mov al, 0x0A
    call vga_print_char

    ; Re-render prompt and current line
    call shell_print_prompt
    lea rsi, [input_buffer]
    call vga_print_string

.tab_done:
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
