; ==============================================================================
; Antigravity OS - 64-Bit Long Mode Kernel Entry & Main Event Loop
; Loaded at physical address 0x0000000000008000 by the 64-bit Bootloader
; ==============================================================================

[org 0x8000]
[bits 64]
default rel

kernel_entry:
    ; Initialize screen display
    mov byte [current_attr], 0x0F   ; White on black
    call vga_clear_screen

    ; Print OS Welcome Banner
    call kernel_print_banner

    ; Initialize 64-bit Interrupt Descriptor Table & Remap 8259 PIC
    mov bl, COLOR_LIGHT_BLUE
    mov rsi, MSG_INIT_IDT
    call vga_print_string_color

    call idt64_init

    mov bl, COLOR_LIGHT_GREEN
    mov rsi, MSG_IDT_OK
    call vga_print_string_color

    ; Enable Hardware Interrupts (IRQ 0 Timer and IRQ 1 Keyboard)
    sti

    ; Mount or format AntigravityFS (AFS) Storage Subsystem
    call fs_init

    ; Initialize PCI Bus and Realtek RTL8139 Network Subsystem
    call net_init
    call arp_init

    ; Initialize Bochs Graphics Adaptor (BGA) Subsystem
    call bga_init

    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [MSG_READY]
    call vga_print_string_color

    ; Display Initial 64-bit Shell Prompt
    call shell_print_prompt

; ------------------------------------------------------------------------------
; Main Kernel Event Loop: Low-power park via 'hlt' until hardware interrupt
; ------------------------------------------------------------------------------
kernel_loop:
    ; Poll network interface for background packets (ARP, ICMP ping replies, etc.)
    call net_poll

    hlt

    ; Check if Tab auto-completion was requested
    cmp byte [tab_requested], 1
    jne .check_enter
    mov byte [tab_requested], 0
    call shell_tab_complete
    jmp kernel_loop

.check_enter:
    ; Check if keyboard ISR reported a completed line (Enter was pressed)
    cmp byte [line_ready], 1
    jne kernel_loop

    ; Execute command in buffer
    call shell_execute_command

    ; Reset buffer state for next command
    call keyboard_clear_buffer

    ; Render prompt again
    call shell_print_prompt

    jmp kernel_loop

; ------------------------------------------------------------------------------
; kernel_print_banner: Renders stylized 64-bit OS startup logo
; ------------------------------------------------------------------------------
kernel_print_banner:
    push rax
    push rbx
    push rsi

    ; Print logo in Cyan
    mov bl, COLOR_LIGHT_CYAN
    mov rsi, BANNER_LINE1
    call vga_print_string_color
    mov rsi, BANNER_LINE2
    call vga_print_string_color
    mov rsi, BANNER_LINE3
    call vga_print_string_color
    mov rsi, BANNER_LINE4
    call vga_print_string_color
    mov rsi, BANNER_LINE5
    call vga_print_string_color
    mov rsi, BANNER_LINE6
    call vga_print_string_color

    ; Print subtitle in Yellow
    mov bl, COLOR_YELLOW
    mov rsi, BANNER_SUBTITLE
    call vga_print_string_color

    pop rsi
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; Included 64-Bit Kernel Subsystems
; ------------------------------------------------------------------------------
%include "vga.asm"
%include "idt.asm"
%include "isr.asm"
%include "keyboard.asm"
%include "ata.asm"
%include "fs.asm"
%include "pci.asm"
%include "net.asm"
%include "eth.asm"
%include "ipv4.asm"
%include "udp.asm"
%include "tcp.asm"
%include "bga.asm"
%include "mouse.asm"
%include "gfx.asm"
%include "gui.asm"
%include "browser.asm"
%include "shell.asm"

; ------------------------------------------------------------------------------
; Kernel Static Data Strings
; ------------------------------------------------------------------------------
BANNER_LINE1: db "    ___          __  _                         _ __          ____  _____ ", 0x0A, 0
BANNER_LINE2: db "   /   |  ____  / /_(_)___ __________ __   __ (_) /___  __  / __ \/ ___/ ", 0x0A, 0
BANNER_LINE3: db "  / /| | / __ \/ __/ / __ `/ ___/ __ `/ | / // / __/ / / / / / / /\__ \  ", 0x0A, 0
BANNER_LINE4: db " / ___ |/ / / / /_/ / /_/ / /  / /_/ /| |/ // / /_/ /_/ / / /_/ /___/ /  ", 0x0A, 0
BANNER_LINE5: db "/_/  |_/_/ /_/\__/_/\__, /_/   \__,_/ |___//_/\__/\__, /  \____//____/   ", 0x0A, 0
BANNER_LINE6: db "                   /____/                        /____/                  ", 0x0A, 0
BANNER_SUBTITLE: db "        ===[ 64-Bit Bare-Metal Long Mode Operating System ]===          ", 0x0A, 0x0A, 0

MSG_INIT_IDT: db "[KERNEL] Initializing 64-bit IDT and remapping 8259 PIC...", 0x0A, 0
MSG_IDT_OK:   db "[KERNEL] 64-bit Long Mode active. Hardware IRQs running (IRQ0, IRQ1).", 0x0A, 0
MSG_READY:    db "[KERNEL] System ready. Type 'help' to see available commands.", 0x0A, 0x0A, 0

; ------------------------------------------------------------------------------
; Pad kernel to exactly 128 sectors (65,536 bytes) to match bootloader load size
; ------------------------------------------------------------------------------
times (128 * 512) - ($ - $$) db 0
