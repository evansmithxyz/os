; ==============================================================================
; Antigravity OS - 64-bit Kernel
; ------------------------------------------------------------------------------
; Entered from boot/stage2.asm in 64-bit long mode at KERNEL_ADDR with:
;   RSP = KERNEL_STACK_TOP, RDI = BOOTINFO_ADDR, interrupts disabled,
;   0 - 4 GB identity mapped with 2 MB pages.
;
; The kernel is assembled as one flat binary (nasm -f bin) from this file; every
; other source file is %included below. Sections:
;   .text    code                         (in the image, at KERNEL_ADDR)
;   .rodata  strings, tables, fonts       (in the image, after .text)
;   .cmdtab  shell command table          (in the image, after .rodata)
;   .data    initialised mutable state    (in the image, after .rodata)
;   .bss     zero-initialised buffers     (NOT in the image, at KERNEL_BSS_ADDR,
;                                          zeroed by kernel_entry)
; Put every buffer that starts out as zeros in .bss with `resb` so it does not
; take up space in the kernel image. See docs/CONVENTIONS.md.
; ==============================================================================

%include "layout.inc"
%include "memmap.inc"

%if KERNEL_ADDR + KERNEL_MAX_SECTORS * SECTOR_SIZE > KERNEL_BSS_ADDR
    %error "the kernel slot (KERNEL_MAX_SECTORS) runs into KERNEL_BSS_ADDR"
%endif
%if KERNEL_BSS_ADDR + KERNEL_BSS_MAX > KERNEL_STACK_BOTTOM
    %error ".bss (KERNEL_BSS_MAX) runs into the kernel stack"
%endif

[map symbols build/kernel.map]

[org KERNEL_ADDR]
[bits 64]
default rel

section .text
section .rodata follows=.text align=16
section .cmdtab follows=.rodata align=16        ; shell command table (apps/shell/commands.asm)
section .data   follows=.cmdtab align=16
section .bss    nobits start=KERNEL_BSS_ADDR align=16

section .bss
bss_start:

section .text

; ------------------------------------------------------------------------------
; kernel_entry: first instruction of the kernel image
; ------------------------------------------------------------------------------
kernel_entry:
    cld
    ; Zero .bss (it is not part of the image, so it holds garbage until now)
    mov rdi, bss_start
    mov rcx, bss_end
    sub rcx, rdi
    xor eax, eax
    rep stosb

    call gdt_init
    call fpu_init
    call serial_init
    call vga_init
    mov byte [con_attr], COLOR_WHITE
    call con_clear
    call kernel_print_banner

    call memory_init                ; parse the E820 map from stage 2
    call idt_init                   ; exceptions + remapped PIC IRQs
    call timer_init                 ; PIT at TIMER_HZ
    sti
    call kernel_report_boot

    call fs_init
    call net_init
    call arp_init
    call bga_init

    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [msg_ready]
    call con_puts_color

    call shell_init

; ------------------------------------------------------------------------------
; kernel_loop: text-console main loop. Sleeps until the next interrupt (timer,
; keyboard) and then services the network and any pending key presses.
; ------------------------------------------------------------------------------
kernel_loop:
    call net_poll
.drain_keys:
    call key_get                    ; CF=0 when the queue is empty
    jnc .idle
    call shell_key
    jmp .drain_keys
.idle:
    hlt
    jmp kernel_loop

; ------------------------------------------------------------------------------
; fpu_init: enable the x87 FPU and SSE (the JavaScript engine computes with
; doubles). Interrupt handlers never touch them, so no state is saved.
; ------------------------------------------------------------------------------
fpu_init:
    push rax
    mov rax, cr0
    and rax, ~(1 << 2)              ; EM off: real FPU
    or rax, (1 << 1)                ; MP on
    and rax, ~(1 << 3)              ; TS off
    mov cr0, rax
    mov rax, cr4
    or rax, (1 << 9) | (1 << 10)    ; OSFXSR, OSXMMEXCPT: SSE instructions
    mov cr4, rax
    fninit
    pop rax
    ret

; ------------------------------------------------------------------------------
; kernel_print_banner: ASCII-art logo on the console
; ------------------------------------------------------------------------------
kernel_print_banner:
    push rbx
    push rsi
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [banner_logo]
    call con_puts_color
    mov bl, COLOR_YELLOW
    lea rsi, [banner_subtitle]
    call con_puts_color
    pop rsi
    pop rbx
    ret

; ------------------------------------------------------------------------------
; kernel_report_boot: one line each for memory, interrupts and kernel size
; ------------------------------------------------------------------------------
kernel_report_boot:
    push rax
    push rbx
    push rsi
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [msg_mem]
    call con_puts_color
    mov rax, [mem_total_bytes]
    shr rax, 20
    call con_dec
    lea rsi, [msg_boot_mem_mb]
    call con_puts_color
    movzx eax, word [abs BOOTINFO_ADDR + BI_E820_COUNT]
    call con_dec
    lea rsi, [msg_mem_regions]
    call con_puts_color

    lea rsi, [msg_kernel]
    call con_puts_color
    mov rax, kernel_image_end - KERNEL_ADDR
    shr rax, 10
    call con_dec
    lea rsi, [msg_kernel_kb]
    call con_puts_color
    mov rax, (KERNEL_MAX_SECTORS * SECTOR_SIZE) >> 10
    call con_dec
    lea rsi, [msg_kernel_slot]
    call con_puts_color

    lea rsi, [msg_irq]
    call con_puts_color
    pop rsi
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; Subsystems (order does not matter for correctness; grouped by layer)
; ------------------------------------------------------------------------------
%include "lib/string.asm"
%include "lib/format.asm"
%include "crypto/sha256.asm"
%include "crypto/sha512.asm"
%include "crypto/bignum.asm"
%include "crypto/rsa.asm"
%include "crypto/ecc.asm"
%include "crypto/chacha20poly1305.asm"
%include "crypto/x25519.asm"
%include "crypto/random.asm"
%include "core/gdt.asm"
%include "core/idt.asm"
%include "core/panic.asm"
%include "core/timer.asm"
%include "core/memory.asm"
%include "drivers/serial.asm"
%include "drivers/vga_text.asm"
%include "drivers/keyboard.asm"
%include "drivers/mouse.asm"
%include "drivers/pci.asm"
%include "drivers/ata.asm"
%include "drivers/rtl8139.asm"
%include "drivers/bga.asm"
%include "drivers/rtc.asm"
%include "console/console.asm"
%include "fs/afs.asm"
%include "net/eth.asm"
%include "net/ipv4.asm"
%include "net/udp.asm"
%include "net/tcp.asm"
%include "net/url.asm"
%include "net/tls.asm"
%include "net/inflate.asm"
%include "net/x509.asm"
%include "gfx/gfx.asm"
%include "gui/wm.asm"
%include "gui/desktop.asm"
%include "apps/terminal.asm"
%include "apps/sysmon.asm"
%include "apps/canvas.asm"
%include "apps/browser.asm"
%include "web/dom.asm"
%include "web/css.asm"
%include "web/layout.asm"
%include "js/js.inc"
%include "js/number.asm"
%include "js/heap.asm"
%include "js/gc.asm"
%include "js/object.asm"
%include "js/lexer.asm"
%include "js/parser.asm"
%include "js/compiler.asm"
%include "js/vm.asm"
%include "js/builtins.asm"
%include "js/stdlib.asm"
%include "js/async.asm"
%include "js/jsnet.asm"
%include "js/iter.asm"
%include "js/collections.asm"
%include "js/regexp.asm"
%include "js/regexp2.asm"
%include "js/date.asm"
%include "js/text.asm"
%include "js/typed.asm"
%include "js/proxy.asm"
%include "js/js.asm"
%include "js/jsdom.asm"
%include "apps/shell/shell.asm"
%include "apps/shell/commands.asm"

; ------------------------------------------------------------------------------
; Kernel strings
; ------------------------------------------------------------------------------
section .rodata
banner_logo:
    db "    ___          __  _                         _ __          ____  _____ ", 0x0A
    db "   /   |  ____  / /_(_)___ __________ __   __ (_) /___  __  / __ \/ ___/ ", 0x0A
    db "  / /| | / __ \/ __/ / __ `/ ___/ __ `/ | / // / __/ / / / / / / /\__ \  ", 0x0A
    db " / ___ |/ / / / /_/ / /_/ / /  / /_/ /| |/ // / /_/ /_/ / / /_/ /___/ /  ", 0x0A
    db "/_/  |_/_/ /_/\__/_/\__, /_/   \__,_/ |___//_/\__/\__, /  \____//____/   ", 0x0A
    db "                   /____/                        /____/                  ", 0x0A, 0
banner_subtitle:
    db "        ===[ 64-Bit Bare-Metal Long Mode Operating System ]===", 0x0A, 0x0A, 0

msg_mem:         db "[BOOT] Memory: ", 0
msg_boot_mem_mb: db " MB usable (", 0
msg_mem_regions: db " E820 regions)", 0x0A, 0
msg_kernel:      db "[BOOT] Kernel: ", 0
msg_kernel_kb:   db " KB of ", 0
msg_kernel_slot: db " KB slot", 0x0A, 0
msg_irq:         db "[BOOT] IDT loaded, PIC remapped, PIT at 1000 Hz", 0x0A, 0
msg_ready:       db "[KERNEL] System ready. Type 'help' to see available commands.", 0x0A, 0x0A, 0

; ------------------------------------------------------------------------------
; End markers (must stay at the very end of this file)
; ------------------------------------------------------------------------------
section .data
kernel_image_end:

section .bss
alignb 16
bss_end:                            ; tools/build.py checks bss_end - bss_start <= KERNEL_BSS_MAX
