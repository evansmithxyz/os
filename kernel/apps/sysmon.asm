; ==============================================================================
; Antigravity OS - System Monitor window (live values, refreshed 4x a second)
; ------------------------------------------------------------------------------
; Two columns of cards: Hardware and Kernel on the left, Network and Storage
; on the right. While drawing, R12 = card x, R13 = y of the next row,
; R15 = card width.
; ==============================================================================

[bits 64]

SYSMON_PAD              equ 16      ; around and between the cards
SYSMON_LINE_H           equ 22
SYSMON_HEAD_H           equ 38      ; card heading, above the first row
SYSMON_CARD_BOTTOM      equ 10
SYSMON_LABEL_X          equ 18
SYSMON_VALUE_X          equ 110
SYSMON_METER_H          equ 6

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
sm_used:                db "Used", 0
sm_nic:                 db "NIC", 0
sm_ipv4:                db "IPv4", 0
sm_traffic:             db "Traffic", 0
sm_image:               db "Image", 0
sm_slot:                db "Slot", 0
sm_v_mb:                db " MB usable in ", 0
sm_v_regions:           db " E820 regions", 0
sm_v_paging:            db "4-level, 0-4 GB identity mapped, 2 MB pages", 0
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
sm_v_kb_bss:            db " KB, .bss ", 0
sm_v_kb:                db " KB", 0
sm_v_percent:           db "%", 0
sm_hint:                db "Refreshes live. F1-F4 switch workspaces; Esc returns to the text console.", 0

section .text
; sysmon_tick: redraw whenever visible (CF=1)
sysmon_tick:
    stc
    ret

sysmon_key:
    clc
    ret

; sysmon_card: RSI = heading, ECX = rows -> a card at (R12, R13), R15 wide,
; tall enough for that many rows; R13 = y of its first row
sysmon_card:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    imul r8d, ecx, SYSMON_LINE_H
    add r8d, SYSMON_HEAD_H + SYSMON_CARD_BOTTOM
    push rsi
    mov ecx, r12d
    mov edx, r13d
    mov esi, r15d
    mov r9d, 10
    mov eax, THEME_SURFACE
    call gfx_fill_round_rect
    mov eax, THEME_WIN_EDGE
    call gfx_stroke_round_rect
    pop rsi
    lea ecx, [r12d + SYSMON_LABEL_X]
    lea edx, [r13d + 12]
    mov eax, THEME_ACCENT
    call gfx_print_ui_bold
    add r13d, SYSMON_HEAD_H
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; sysmon_card_end: R13 = below the card just filled, plus the gap
sysmon_card_end:
    add r13d, SYSMON_CARD_BOTTOM + SYSMON_PAD
    ret

; sysmon_row: RSI = label, sysmon_buf = value. Draws at R13, advances R13.
sysmon_row:
    push rax
    push rcx
    push rdx
    push rsi
    lea ecx, [r12d + SYSMON_LABEL_X]
    mov edx, r13d
    mov eax, THEME_TEXT_MUTED
    call gfx_print_ui
    lea ecx, [r12d + SYSMON_VALUE_X]
    lea rsi, [sysmon_buf]
    mov eax, THEME_TEXT
    call gfx_print_ui
    add r13d, SYSMON_LINE_H
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; sysmon_meter: RSI = label, RAX = used, RDX = total -> a bar and the
; percentage used. Draws at R13, advances R13.
sysmon_meter:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r10, rdx
    mov rbx, rax
    lea ecx, [r12d + SYSMON_LABEL_X]
    mov edx, r13d
    mov eax, THEME_TEXT_MUTED
    call gfx_print_ui
    ; track: from the value column to 56 pixels before the card's edge
    lea ecx, [r12d + SYSMON_VALUE_X]
    lea edx, [r13d + 6]
    mov esi, r15d
    sub esi, SYSMON_VALUE_X + 56
    mov r8d, SYSMON_METER_H
    mov r9d, SYSMON_METER_H / 2
    mov eax, THEME_FIELD
    call gfx_fill_round_rect
    push rsi                        ; filled part: used * width / total
    mov rax, rbx
    movsxd rsi, esi
    mul rsi
    test r10, r10
    jz .empty
    div r10
    jmp .fill
.empty:
    xor eax, eax
.fill:
    pop rsi
    cmp eax, esi
    jbe .fill_ok
    mov eax, esi
.fill_ok:
    cmp eax, SYSMON_METER_H
    jae .fill_min
    mov eax, SYSMON_METER_H         ; never less than a dot
.fill_min:
    push rsi
    mov esi, eax
    mov eax, THEME_ACCENT
    call gfx_fill_round_rect
    pop rsi
    ; percentage
    lea rdi, [sysmon_buf]
    mov rax, rbx
    mov ecx, 100
    mul rcx
    xor edx, edx
    test r10, r10
    jz .pct
    div r10
.pct:
    call fmt_dec
    push rsi
    lea rsi, [sm_v_percent]
    call fmt_str
    pop rsi
    lea ecx, [r12d + SYSMON_VALUE_X + 10]
    add ecx, esi
    mov edx, r13d
    lea rsi, [sysmon_buf]
    mov eax, THEME_TEXT_SOFT
    call gfx_print_ui
    add r13d, SYSMON_LINE_H
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

; WIN_DRAW callback
sysmon_draw:
    push rcx
    push rdx
    push rsi
    push r8
    mov eax, THEME_WIN_BODY
    call gfx_fill_rect
    pop r8
    pop rsi
    pop rdx
    pop rcx
    mov r14d, edx                   ; R14 = client top
    lea r15d, [esi - 3 * SYSMON_PAD]
    shr r15d, 1                     ; card width
    lea r12d, [ecx + SYSMON_PAD]
    lea r13d, [edx + SYSMON_PAD]
    push rcx

    ; ---- left column: Hardware ------------------------------------------------
    lea rsi, [sm_h_hw]
    mov ecx, 7
    call sysmon_card

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
    call sysmon_card_end

    ; ---- left column: Kernel --------------------------------------------------
    lea rsi, [sm_h_kernel]
    mov ecx, 2
    call sysmon_card
    lea rdi, [sysmon_buf]           ; Image
    mov rax, kernel_image_end - KERNEL_ADDR + 1023
    shr rax, 10
    call fmt_dec
    lea rsi, [sm_v_kb_bss]
    call fmt_str
    mov eax, (bss_end - bss_start + 1023) >> 10
    call fmt_dec
    lea rsi, [sm_v_kb]
    call fmt_str
    lea rsi, [sm_image]
    call sysmon_row
    mov rax, kernel_image_end - KERNEL_ADDR     ; Slot
    mov edx, KERNEL_MAX_SECTORS * SECTOR_SIZE
    lea rsi, [sm_slot]
    call sysmon_meter
    call sysmon_card_end
    mov ebx, r13d                   ; EBX = bottom of the left column

    ; ---- right column: Network ------------------------------------------------
    add r12d, r15d
    add r12d, SYSMON_PAD
    lea r13d, [r14d + SYSMON_PAD]
    lea rsi, [sm_h_net]
    mov ecx, 1
    cmp byte [net_present], 1
    jne .net_card
    mov ecx, 3
.net_card:
    call sysmon_card
    lea rdi, [sysmon_buf]           ; NIC
    cmp byte [net_present], 1
    je .nic
    lea rsi, [sm_v_nonet]
    call fmt_str
    lea rsi, [sm_nic]
    call sysmon_row
    jmp .storage
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

.storage:
    call sysmon_card_end
    ; ---- right column: Storage ------------------------------------------------
    lea rsi, [sm_h_storage]
    mov ecx, 2
    call sysmon_card
    lea rdi, [sysmon_buf]           ; Disk
    lea rsi, [sm_v_afs]
    call fmt_str
    call fs_stats
    push rdx                        ; data sectors in use
    call fmt_dec
    lea rsi, [sm_v_files]
    call fmt_str
    mov eax, FS_TOTAL_SECTORS - FS_DATA_LBA
    sub rax, [rsp]
    shr rax, 1
    call fmt_dec
    lea rsi, [sm_v_kbfree]
    call fmt_str
    lea rsi, [sm_disk]
    call sysmon_row
    pop rax                         ; Used
    mov edx, FS_TOTAL_SECTORS - FS_DATA_LBA
    lea rsi, [sm_used]
    call sysmon_meter
    call sysmon_card_end

    ; hint under the taller column
    cmp r13d, ebx
    jge .hint
    mov r13d, ebx
.hint:
    pop rcx
    add ecx, SYSMON_PAD + 2
    mov edx, r13d
    lea rsi, [sm_hint]
    mov eax, THEME_TEXT_FAINT
    call gfx_print_ui
    ret
