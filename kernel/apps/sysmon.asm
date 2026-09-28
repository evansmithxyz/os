; ==============================================================================
; Antigravity OS - System Monitor window (live values, refreshed 4x a second)
; ==============================================================================

[bits 64]

SYSMON_LINE_H           equ 16
SYSMON_VALUE_X          equ 120

section .bss
sysmon_buf:             resb 160

section .rodata
sysmon_title:           db "System Monitor", 0
sysmon_label:           db "System Monitor", 0
sm_h_hw:                db "HARDWARE", 0
sm_h_storage:           db "STORAGE", 0
sm_h_net:               db "NETWORK", 0
sm_h_kernel:            db "KERNEL", 0
sm_cpu:                 db "CPU", 0
sm_mem:                 db "Memory", 0
sm_paging:              db "Paging", 0
sm_display:             db "Display", 0
sm_timer:               db "Timer", 0
sm_uptime:              db "Uptime", 0
sm_mouse:               db "Mouse", 0
sm_disk:                db "Disk", 0
sm_nic:                 db "NIC", 0
sm_ipv4:                db "IPv4", 0
sm_traffic:             db "Traffic", 0
sm_image:               db "Image", 0
sm_v_mb:                db " MB usable in ", 0
sm_v_regions:           db " E820 regions", 0
sm_v_paging:            db "4-level, 0-4 GB identity mapped with 2 MB pages", 0
sm_v_display:           db "BGA 1024x768x32, framebuffer at 0x", 0
sm_v_timer:             db "PIT at 1000 Hz, ", 0
sm_v_ticks:             db " ticks", 0
sm_v_comma:             db ", ", 0
sm_v_buttons:           db "  buttons ", 0
sm_v_afs:               db "AntigravityFS, ", 0
sm_v_files:             db " files, ", 0
sm_v_kbfree:            db " KB free", 0
sm_v_rtl:               db "RTL8139, I/O 0x", 0
sm_v_mac:               db ", MAC ", 0
sm_v_nonet:             db "not present", 0
sm_v_slash:             db " / ", 0
sm_v_gw:                db ", gateway ", 0
sm_v_rx:                db "RX ", 0
sm_v_tx:                db " packets, TX ", 0
sm_v_packets:           db " packets", 0
sm_v_kb_of:             db " KB of 512 KB slot, .bss ", 0
sm_v_kb:                db " KB", 0
sm_hint:                db "Refreshes live. F1-F4 switch workspaces; Esc returns to the text console.", 0

section .text
; sysmon_tick: redraw whenever visible (CF=1)
sysmon_tick:
    stc
    ret

sysmon_key:
    clc
    ret

; sysmon_heading: RSI = text at (R12, R13); advances R13
sysmon_heading:
    push rax
    push rbx
    push rcx
    push rdx
    add r13d, 4
    mov ecx, r12d
    mov edx, r13d
    mov eax, THEME_CYAN
    mov ebx, -1
    call gfx_print_string
    add r13d, SYSMON_LINE_H
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; sysmon_row: RSI = label, sysmon_buf = value. Draws at R13, advances R13.
sysmon_row:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    lea ecx, [r12d + 12]
    mov edx, r13d
    mov eax, THEME_TEXT_MUTED
    mov ebx, -1
    call gfx_print_string
    lea ecx, [r12d + SYSMON_VALUE_X]
    lea rsi, [sysmon_buf]
    mov eax, THEME_TEXT
    call gfx_print_string
    add r13d, SYSMON_LINE_H
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; WIN_DRAW callback
sysmon_draw:
    mov r12d, ecx
    add r12d, 12
    mov r13d, edx
    add r13d, 6
    mov eax, THEME_WIN_BODY
    call gfx_fill_rect

    lea rsi, [sm_h_hw]
    call sysmon_heading

    call cpu_get_brand              ; CPU
    lea rdi, [sysmon_buf]
    call fmt_str
    lea rsi, [sm_cpu]
    call sysmon_row

    lea rdi, [sysmon_buf]           ; Memory
    call memory_total_mb
    call fmt_dec
    lea rsi, [sm_v_mb]
    call fmt_str
    movzx eax, word [abs BOOTINFO_ADDR + BI_E820_COUNT]
    call fmt_dec
    lea rsi, [sm_v_regions]
    call fmt_str
    lea rsi, [sm_mem]
    call sysmon_row

    lea rdi, [sysmon_buf]           ; Paging
    lea rsi, [sm_v_paging]
    call fmt_str
    lea rsi, [sm_paging]
    call sysmon_row

    lea rdi, [sysmon_buf]           ; Display
    lea rsi, [sm_v_display]
    call fmt_str
    mov rax, [bga_lfb]
    shr rax, 24
    call fmt_hex8
    mov rax, [bga_lfb]
    shr rax, 16
    call fmt_hex8
    mov rax, [bga_lfb]
    shr rax, 8
    call fmt_hex8
    mov rax, [bga_lfb]
    call fmt_hex8
    lea rsi, [sm_display]
    call sysmon_row

    lea rdi, [sysmon_buf]           ; Timer
    lea rsi, [sm_v_timer]
    call fmt_str
    mov rax, [timer_ticks]
    call fmt_dec
    lea rsi, [sm_v_ticks]
    call fmt_str
    lea rsi, [sm_timer]
    call sysmon_row

    lea rdi, [sysmon_buf]           ; Uptime
    call fmt_uptime
    lea rsi, [sm_uptime]
    call sysmon_row

    lea rdi, [sysmon_buf]           ; Mouse
    mov eax, [mouse_x]
    call fmt_dec
    lea rsi, [sm_v_comma]
    call fmt_str
    mov eax, [mouse_y]
    call fmt_dec
    lea rsi, [sm_v_buttons]
    call fmt_str
    movzx eax, byte [mouse_buttons]
    call fmt_dec
    lea rsi, [sm_mouse]
    call sysmon_row

    lea rsi, [sm_h_storage]
    call sysmon_heading
    lea rdi, [sysmon_buf]           ; Disk
    lea rsi, [sm_v_afs]
    call fmt_str
    call fs_stats
    mov r14, rdx
    call fmt_dec
    lea rsi, [sm_v_files]
    call fmt_str
    mov eax, FS_TOTAL_SECTORS - FS_DATA_LBA
    sub rax, r14
    shr rax, 1
    call fmt_dec
    lea rsi, [sm_v_kbfree]
    call fmt_str
    lea rsi, [sm_disk]
    call sysmon_row

    lea rsi, [sm_h_net]
    call sysmon_heading
    lea rdi, [sysmon_buf]           ; NIC
    cmp byte [net_present], 1
    je .nic
    lea rsi, [sm_v_nonet]
    call fmt_str
    lea rsi, [sm_nic]
    call sysmon_row
    jmp .kernel
.nic:
    lea rsi, [sm_v_rtl]
    call fmt_str
    mov ax, [net_io_base]
    push rax
    shr ax, 8
    call fmt_hex8
    pop rax
    call fmt_hex8
    lea rsi, [sm_v_mac]
    call fmt_str
    lea rsi, [net_mac]
    call fmt_mac
    lea rsi, [sm_nic]
    call sysmon_row

    lea rdi, [sysmon_buf]           ; IPv4
    lea rsi, [net_ip]
    call fmt_ip
    lea rsi, [sm_v_slash]
    call fmt_str
    lea rsi, [net_netmask]
    call fmt_ip
    lea rsi, [sm_v_gw]
    call fmt_str
    lea rsi, [net_gateway]
    call fmt_ip
    lea rsi, [sm_ipv4]
    call sysmon_row

    lea rdi, [sysmon_buf]           ; Traffic
    lea rsi, [sm_v_rx]
    call fmt_str
    mov rax, [net_packets_rx]
    call fmt_dec
    lea rsi, [sm_v_tx]
    call fmt_str
    mov rax, [net_packets_tx]
    call fmt_dec
    lea rsi, [sm_v_packets]
    call fmt_str
    lea rsi, [sm_traffic]
    call sysmon_row

.kernel:
    lea rsi, [sm_h_kernel]
    call sysmon_heading
    lea rdi, [sysmon_buf]           ; Image
    mov rax, kernel_image_end - KERNEL_ADDR + 1023
    shr rax, 10
    call fmt_dec
    lea rsi, [sm_v_kb_of]
    call fmt_str
    mov eax, (bss_end - bss_start + 1023) >> 10
    call fmt_dec
    lea rsi, [sm_v_kb]
    call fmt_str
    lea rsi, [sm_image]
    call sysmon_row

    add r13d, 8
    mov ecx, r12d
    mov edx, r13d
    lea rsi, [sm_hint]
    mov eax, THEME_TEXT_MUTED
    mov ebx, -1
    call gfx_print_string
    ret
