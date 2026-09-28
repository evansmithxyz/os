; ==============================================================================
; Shell commands: system (help, clear, echo, sysinfo, about, cpu, mem, regs,
; uptime, reboot, halt, crash)
; Handlers: RSI = arguments; may clobber any register except RSP.
; ==============================================================================

[bits 64]

%define OS_VERSION_STR "2.1"

section .bss
cpu_brand_buf:          resb 64

section .rodata
msg_about:
    db "Antigravity OS ", OS_VERSION_STR, " - a 64-bit operating system in pure x86_64 assembly", 0x0A
    db "  Boot:     MBR -> stage 2 loader -> long mode, 4-level paging (0-4 GB, 2 MB pages)", 0x0A
    db "  Kernel:   flat NASM binary, IDT + PIC + 1 kHz PIT, serial console on COM1", 0x0A
    db "  Storage:  ATA PIO driver + AntigravityFS (AFS1)", 0x0A
    db "  Network:  RTL8139 driver, Ethernet/ARP/IPv4/ICMP/UDP/DNS/TCP/HTTP", 0x0A
    db "  Desktop:  BGA 1024x768x32, window manager with 4 workspaces", 0x0A, 0
msg_si_title:       db "Antigravity OS ", OS_VERSION_STR, " (x86_64 long mode)", 0x0A, 0
msg_si_cpu:         db "  CPU:      ", 0
msg_si_mem:         db "  Memory:   ", 0
msg_si_mb:          db " MB usable", 0x0A, 0
msg_si_uptime:      db "  Uptime:   ", 0
msg_si_disk:        db "  Disk:     ", 0
msg_si_files:       db " files, ", 0
msg_si_kbfree:      db " KB free", 0x0A, 0
msg_si_net:         db "  Network:  ", 0
msg_si_nonet:       db "no network card", 0x0A, 0
msg_si_rtl:         db " (RTL8139)", 0x0A, 0
msg_si_display:     db "  Display:  ", 0
msg_si_bga_yes:     db "BGA 1024x768x32 available (type 'gui')", 0x0A, 0
msg_si_bga_no:      db "text mode only (no BGA adapter)", 0x0A, 0
msg_si_bga_running: db "BGA 1024x768x32 (desktop running)", 0x0A, 0
msg_cpu_vendor:     db "Vendor:     ", 0
msg_cpu_brand:      db "Brand:      ", 0
msg_cpu_sig:        db "Signature:  ", 0
msg_cpu_lm:         db "Long mode:  active", 0x0A, 0
msg_mem_e820:       db "BIOS E820 memory map:", 0x0A, 0
msg_mem_dash:       db " - ", 0
msg_mem_usable:     db "  usable", 0x0A, 0
msg_mem_reserved:   db "  reserved", 0x0A, 0
msg_mem_acpi:       db "  ACPI", 0x0A, 0
msg_mem_other:      db "  other", 0x0A, 0
msg_mem_total:      db "Usable total:  ", 0
msg_mem_mb:         db " MB", 0x0A, 0
msg_mem_kernel:     db "Kernel image:  ", 0
msg_mem_bss:        db "Kernel .bss:   ", 0
msg_mem_stack:      db "Stack top:     ", 0
msg_mem_rsp:        db "   RSP now: ", 0
msg_mem_cr3:        db "Page tables:   CR3 = ", 0
msg_mem_used:       db "  (", 0
msg_mem_of:         db " KB of ", 0
msg_mem_kb:         db " KB)", 0x0A, 0
msg_regs_hdr:       db "Control registers (read inside the 'regs' command):", 0x0A, 0
msg_regs_cr0:       db "  CR0    = ", 0
msg_regs_cr2:       db "  CR2    = ", 0
msg_regs_cr3:       db "  CR3    = ", 0
msg_regs_cr4:       db "  CR4    = ", 0
msg_regs_efer:      db "  EFER   = ", 0
msg_regs_rflags:    db "  RFLAGS = ", 0
msg_regs_rsp:       db "  RSP    = ", 0
msg_uptime_up:      db "Up ", 0
msg_uptime_ticks:   db "  (", 0
msg_uptime_hz:      db " ticks at 1000 Hz)", 0x0A, 0
msg_h:              db "h ", 0
msg_m:              db "m ", 0
msg_s:              db "s", 0
msg_reboot:         db "Rebooting...", 0x0A, 0
msg_halt:           db "CPU halted. It is now safe to close the emulator.", 0x0A, 0
msg_crash:          db "Triggering a CPU exception on purpose (crash ud|gp|pf|de)...", 0x0A, 0
arg_ud:             db "ud", 0
arg_gp:             db "gp", 0
arg_pf:             db "pf", 0
arg_de:             db "de", 0

section .text
cmd_help:
    lea rbx, [shell_commands]
    xor r12d, r12d                  ; 0 until the first heading was printed
.loop:
    lea rax, [shell_commands_end]
    cmp rbx, rax
    jae .done
    mov rax, [rbx + CMD_FLAGS]
    test rax, CMDF_HEADING
    jnz .heading
    test rax, CMDF_HIDDEN
    jnz .next
    mov rsi, [rbx + CMD_HELP]
    cmp byte [rsi], 0
    je .next                        ; alias
    push rbx
    mov bl, COLOR_LIGHT_GRAY
    call con_spaces_2
    call con_puts_color
    call con_newline
    pop rbx
    jmp .next
.heading:
    test r12d, r12d
    jz .first
    call con_newline
.first:
    mov r12d, 1
    push rbx
    mov rsi, [rbx + CMD_NAME]
    mov bl, COLOR_YELLOW
    call con_puts_color
    pop rbx
    call con_newline
.next:
    add rbx, CMD_ENTRY_SIZE
    jmp .loop
.done:
    ret

con_spaces_2:
    push rcx
    mov ecx, 2
    call con_spaces
    pop rcx
    ret

cmd_clear:
    call con_clear
    cmp byte [bga_active], 0
    jne .done
    call kernel_print_banner
.done:
    ret

cmd_echo:
    call con_puts
    jmp con_newline

cmd_about:
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [msg_about]
    jmp con_puts_color

; cpu_get_brand: fills cpu_brand_buf with the brand string (or the vendor ID)
; -> RSI = pointer to the first non-space character
cpu_get_brand:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    lea rdi, [cpu_brand_buf]
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .vendor
    mov eax, 0x80000002
.brand_loop:
    push rax
    cpuid
    mov [rdi], eax
    mov [rdi + 4], ebx
    mov [rdi + 8], ecx
    mov [rdi + 12], edx
    add rdi, 16
    pop rax
    inc eax
    cmp eax, 0x80000004
    jbe .brand_loop
    mov byte [rdi], 0
    jmp .trim
.vendor:
    xor eax, eax
    cpuid
    mov [rdi], ebx
    mov [rdi + 4], edx
    mov [rdi + 8], ecx
    mov byte [rdi + 12], 0
.trim:
    lea rsi, [cpu_brand_buf]
    call skip_spaces
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

cmd_sysinfo:
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [msg_si_title]
    call con_puts_color
    lea rsi, [msg_si_cpu]
    call con_puts
    call cpu_get_brand
    call con_puts
    call con_newline
    lea rsi, [msg_si_mem]
    call con_puts
    call memory_total_mb
    call con_dec
    lea rsi, [msg_si_mb]
    call con_puts
    lea rsi, [msg_si_uptime]
    call con_puts
    call cmd_print_uptime
    call con_newline
    lea rsi, [msg_si_disk]
    call con_puts
    call fs_stats
    mov r12, rdx
    call con_dec
    lea rsi, [msg_si_files]
    call con_puts
    mov eax, FS_TOTAL_SECTORS - FS_DATA_LBA
    sub rax, r12
    shr rax, 1
    call con_dec
    lea rsi, [msg_si_kbfree]
    call con_puts
    lea rsi, [msg_si_net]
    call con_puts
    cmp byte [net_present], 1
    jne .no_net
    lea rsi, [net_ip]
    call con_ip
    lea rsi, [msg_si_rtl]
    call con_puts
    jmp .display
.no_net:
    lea rsi, [msg_si_nonet]
    call con_puts
.display:
    lea rsi, [msg_si_display]
    call con_puts
    lea rsi, [msg_si_bga_running]
    cmp byte [bga_active], 0
    jne .print_display
    lea rsi, [msg_si_bga_yes]
    cmp byte [bga_available], 1
    je .print_display
    lea rsi, [msg_si_bga_no]
.print_display:
    jmp con_puts

; cmd_print_uptime: "Hh MMm SSs"
cmd_print_uptime:
    call timer_uptime_seconds
    xor edx, edx
    mov ecx, 3600
    div rcx                         ; RAX = hours, RDX = rest
    call con_dec
    lea rsi, [msg_h]
    call con_puts
    mov rax, rdx
    xor edx, edx
    mov ecx, 60
    div rcx
    call con_dec
    lea rsi, [msg_m]
    call con_puts
    mov rax, rdx
    call con_dec
    lea rsi, [msg_s]
    jmp con_puts

cmd_uptime:
    lea rsi, [msg_uptime_up]
    call con_puts
    call cmd_print_uptime
    lea rsi, [msg_uptime_ticks]
    call con_puts
    mov rax, [timer_ticks]
    call con_dec
    lea rsi, [msg_uptime_hz]
    jmp con_puts

cmd_cpu:
    mov bl, COLOR_LIGHT_GREEN
    mov [con_attr], bl
    lea rsi, [msg_cpu_vendor]
    call con_puts
    lea rdi, [cpu_brand_buf]
    xor eax, eax
    cpuid
    mov [rdi], ebx
    mov [rdi + 4], edx
    mov [rdi + 8], ecx
    mov byte [rdi + 12], 0
    mov rsi, rdi
    call con_puts
    call con_newline
    lea rsi, [msg_cpu_brand]
    call con_puts
    call cpu_get_brand
    call con_puts
    call con_newline
    lea rsi, [msg_cpu_sig]
    call con_puts
    mov eax, 1
    cpuid
    call con_hex32
    call con_newline
    lea rsi, [msg_cpu_lm]
    jmp con_puts

cmd_mem:
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [msg_mem_e820]
    call con_puts_color
    movzx r12d, word [abs BOOTINFO_ADDR + BI_E820_COUNT]
    mov r13, E820_MAP_ADDR
.e820:
    test r12d, r12d
    jz .e820_done
    call con_spaces_2
    mov rax, [r13]
    call con_hex64
    lea rsi, [msg_mem_dash]
    call con_puts
    mov rax, [r13]
    add rax, [r13 + 8]
    dec rax
    call con_hex64
    mov eax, [r13 + 16]
    lea rsi, [msg_mem_usable]
    cmp eax, 1
    je .type
    lea rsi, [msg_mem_reserved]
    cmp eax, 2
    je .type
    lea rsi, [msg_mem_acpi]
    cmp eax, 3
    je .type
    lea rsi, [msg_mem_other]
.type:
    call con_puts
    add r13, E820_ENTRY_SIZE
    dec r12d
    jmp .e820
.e820_done:
    lea rsi, [msg_mem_total]
    call con_puts
    call memory_total_mb
    call con_dec
    lea rsi, [msg_mem_mb]
    call con_puts

    lea rsi, [msg_mem_kernel]
    call con_puts
    mov rax, KERNEL_ADDR
    call con_hex64
    lea rsi, [msg_mem_dash]
    call con_puts
    mov rax, kernel_image_end - 1
    call con_hex64
    lea rsi, [msg_mem_used]
    call con_puts
    mov rax, kernel_image_end - KERNEL_ADDR + 1023
    shr rax, 10
    call con_dec
    lea rsi, [msg_mem_of]
    call con_puts
    mov eax, (KERNEL_MAX_SECTORS * SECTOR_SIZE) >> 10
    call con_dec
    lea rsi, [msg_mem_kb]
    call con_puts

    lea rsi, [msg_mem_bss]
    call con_puts
    mov rax, bss_start
    call con_hex64
    lea rsi, [msg_mem_dash]
    call con_puts
    mov rax, bss_end - 1
    call con_hex64
    lea rsi, [msg_mem_used]
    call con_puts
    mov rax, (bss_end - bss_start + 1023) >> 10
    call con_dec
    lea rsi, [msg_mem_of]
    call con_puts
    mov eax, KERNEL_BSS_MAX >> 10
    call con_dec
    lea rsi, [msg_mem_kb]
    call con_puts

    lea rsi, [msg_mem_stack]
    call con_puts
    mov rax, KERNEL_STACK_TOP
    call con_hex64
    lea rsi, [msg_mem_rsp]
    call con_puts
    mov rax, rsp
    call con_hex64
    call con_newline
    lea rsi, [msg_mem_cr3]
    call con_puts
    mov rax, cr3
    call con_hex64
    jmp con_newline

cmd_regs:
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [msg_regs_hdr]
    call con_puts_color
    lea rsi, [msg_regs_cr0]
    call con_puts
    mov rax, cr0
    call con_hex64
    call con_newline
    lea rsi, [msg_regs_cr2]
    call con_puts
    mov rax, cr2
    call con_hex64
    call con_newline
    lea rsi, [msg_regs_cr3]
    call con_puts
    mov rax, cr3
    call con_hex64
    call con_newline
    lea rsi, [msg_regs_cr4]
    call con_puts
    mov rax, cr4
    call con_hex64
    call con_newline
    lea rsi, [msg_regs_efer]
    call con_puts
    mov ecx, 0xC0000080
    rdmsr
    shl rdx, 32
    or rax, rdx
    call con_hex64
    call con_newline
    lea rsi, [msg_regs_rflags]
    call con_puts
    pushfq
    pop rax
    call con_hex64
    call con_newline
    lea rsi, [msg_regs_rsp]
    call con_puts
    mov rax, rsp
    call con_hex64
    jmp con_newline

cmd_reboot:
    mov bl, COLOR_LIGHT_MAGENTA
    lea rsi, [msg_reboot]
    call con_puts_color
    cli
    mov ecx, 100000
.wait:
    in al, 0x64
    test al, 2
    jz .pulse
    dec ecx
    jnz .wait
.pulse:
    mov al, 0xFE                    ; 8042: pulse the CPU reset line
    out 0x64, al
    mov ecx, 1000000
.spin:
    dec ecx
    jnz .spin
    lidt [.null_idt]                ; fallback: triple fault
    int3
.null_idt:
    dw 0
    dq 0

cmd_halt:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_halt]
    call con_puts_color
    jmp panic_halt

cmd_crash:
    mov r12, rsi
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_crash]
    call con_puts_color
    mov rsi, r12
    lea rdi, [arg_gp]
    call str_has_prefix
    je .gp
    lea rdi, [arg_pf]
    call str_has_prefix
    je .pf
    lea rdi, [arg_de]
    call str_has_prefix
    je .de
    ud2                             ; default: invalid opcode
.gp:
    mov rax, 0x8000000000000000     ; non-canonical address -> #GP
    mov rax, [rax]
.pf:
    mov rax, 0x0000008000000000     ; 512 GB: not mapped -> #PF
    mov rax, [rax]
.de:
    xor ecx, ecx
    div rcx
    ret
