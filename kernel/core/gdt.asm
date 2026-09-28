; ==============================================================================
; Antigravity OS - Kernel GDT
; ------------------------------------------------------------------------------
; Stage 2's GDT lives in loader memory; the kernel installs its own copy so it
; does not depend on memory it does not own. Selector values match stage 2.
; ==============================================================================

[bits 64]

KERNEL_CS               equ 0x18
KERNEL_DS               equ 0x20

section .rodata
align 16
gdt64:
    dq 0                            ; 0x00 null
    dq 0x00CF9A000000FFFF           ; 0x08 32-bit code (unused, kept for layout)
    dq 0x00CF92000000FFFF           ; 0x10 32-bit data (unused)
    dq 0x00209A0000000000           ; 0x18 64-bit code
    dq 0x0000920000000000           ; 0x20 64-bit data
gdt64_end:

gdt64_descriptor:
    dw gdt64_end - gdt64 - 1
    dq gdt64

section .text
; ------------------------------------------------------------------------------
; gdt_init: load the kernel GDT and reload every segment register
; ------------------------------------------------------------------------------
gdt_init:
    push rax
    lgdt [gdt64_descriptor]
    mov ax, KERNEL_DS
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    ; Reload CS with a far return
    lea rax, [.reload]
    push qword KERNEL_CS
    push rax
    retfq
.reload:
    pop rax
    ret
