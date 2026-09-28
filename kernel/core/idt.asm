; ==============================================================================
; Antigravity OS - Interrupt Descriptor Table, CPU Exceptions & 8259 PIC
; ------------------------------------------------------------------------------
; Vectors 0x00-0x1F  CPU exceptions -> exc_common -> panic_exception (never returns)
; Vector  0x20       IRQ0  PIT timer        (core/timer.asm)
; Vector  0x21       IRQ1  PS/2 keyboard    (drivers/keyboard.asm)
; Vector  0x2C       IRQ12 PS/2 mouse       (masked; the GUI polls the mouse)
; Everything else    isr_ignore (spurious / unused)
; ==============================================================================

[bits 64]

PIC1_COMMAND            equ 0x20
PIC1_DATA               equ 0x21
PIC2_COMMAND            equ 0xA0
PIC2_DATA               equ 0xA1
PIC_EOI                 equ 0x20
IRQ_BASE                equ 0x20
IDT_GATE_INTERRUPT      equ 0x8E    ; present, DPL 0, 64-bit interrupt gate

; Stack frame built by exc_common (offsets from the frame pointer in RDI)
EXC_R15     equ 0
EXC_R14     equ 8
EXC_R13     equ 16
EXC_R12     equ 24
EXC_R11     equ 32
EXC_R10     equ 40
EXC_R9      equ 48
EXC_R8      equ 56
EXC_RBP     equ 64
EXC_RDI     equ 72
EXC_RSI     equ 80
EXC_RDX     equ 88
EXC_RCX     equ 96
EXC_RBX     equ 104
EXC_RAX     equ 112
EXC_VECTOR  equ 120
EXC_ERROR   equ 128
EXC_RIP     equ 136
EXC_CS      equ 144
EXC_RFLAGS  equ 152
EXC_RSP     equ 160
EXC_SS      equ 168

section .bss
alignb 16
idt_table:              resb 256 * 16

section .rodata
idt_descriptor:
    dw 256 * 16 - 1
    dq idt_table

section .text

; ------------------------------------------------------------------------------
; Exception entry stubs: normalise the stack to [vector, error code, iret frame]
; ------------------------------------------------------------------------------
%macro EXC_NOERR 1
exc_stub_%1:
    push qword 0
    push qword %1
    jmp exc_common
%endmacro

%macro EXC_ERR 1
exc_stub_%1:
    push qword %1
    jmp exc_common
%endmacro

EXC_NOERR 0
EXC_NOERR 1
EXC_NOERR 2
EXC_NOERR 3
EXC_NOERR 4
EXC_NOERR 5
EXC_NOERR 6
EXC_NOERR 7
EXC_ERR   8
EXC_NOERR 9
EXC_ERR   10
EXC_ERR   11
EXC_ERR   12
EXC_ERR   13
EXC_ERR   14
EXC_NOERR 15
EXC_NOERR 16
EXC_ERR   17
EXC_NOERR 18
EXC_NOERR 19
EXC_NOERR 20
EXC_ERR   21
EXC_NOERR 22
EXC_NOERR 23
EXC_NOERR 24
EXC_NOERR 25
EXC_NOERR 26
EXC_NOERR 27
EXC_NOERR 28
EXC_ERR   29
EXC_ERR   30
EXC_NOERR 31

exc_common:
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
    mov rdi, rsp
    call panic_exception            ; does not return

; ------------------------------------------------------------------------------
; isr_ignore: unused vectors (including spurious IRQ7 / IRQ15)
; ------------------------------------------------------------------------------
isr_ignore:
    iretq

; ------------------------------------------------------------------------------
; isr_mouse: IRQ12 is normally masked; if it fires, drain the byte and EOI.
; ------------------------------------------------------------------------------
isr_mouse:
    push rax
    in al, 0x64
    test al, 0x01
    jz .eoi
    in al, 0x60
.eoi:
    mov al, PIC_EOI
    out PIC2_COMMAND, al
    out PIC1_COMMAND, al
    pop rax
    iretq

; ------------------------------------------------------------------------------
; idt_set_gate: AL = vector, RDX = handler address
; ------------------------------------------------------------------------------
idt_set_gate:
    push rax
    push rdi
    movzx eax, al
    shl eax, 4
    lea rdi, [idt_table]
    add rdi, rax
    mov [rdi], dx                   ; offset 15:0
    mov word [rdi + 2], KERNEL_CS
    mov byte [rdi + 4], 0           ; IST
    mov byte [rdi + 5], IDT_GATE_INTERRUPT
    mov rax, rdx
    shr rax, 16
    mov [rdi + 6], ax               ; offset 31:16
    shr rax, 16
    mov [rdi + 8], eax              ; offset 63:32
    mov dword [rdi + 12], 0
    pop rdi
    pop rax
    ret

; ------------------------------------------------------------------------------
; pic_remap: IRQ0-7 -> 0x20-0x27, IRQ8-15 -> 0x28-0x2F. Unmask IRQ0 + IRQ1 only.
; ------------------------------------------------------------------------------
pic_remap:
    push rax
    mov al, 0x11                    ; ICW1: init, cascade, ICW4 needed
    out PIC1_COMMAND, al
    call io_wait
    out PIC2_COMMAND, al
    call io_wait
    mov al, IRQ_BASE                ; ICW2: vector offsets
    out PIC1_DATA, al
    call io_wait
    mov al, IRQ_BASE + 8
    out PIC2_DATA, al
    call io_wait
    mov al, 0x04                    ; ICW3: slave on IRQ2
    out PIC1_DATA, al
    call io_wait
    mov al, 0x02
    out PIC2_DATA, al
    call io_wait
    mov al, 0x01                    ; ICW4: 8086 mode
    out PIC1_DATA, al
    call io_wait
    out PIC2_DATA, al
    call io_wait
    mov al, 0xFC                    ; unmask IRQ0 (timer) and IRQ1 (keyboard)
    out PIC1_DATA, al
    mov al, 0xFF
    out PIC2_DATA, al
    pop rax
    ret

io_wait:
    out 0x80, al
    ret

; ------------------------------------------------------------------------------
; idt_init: fill the IDT, remap the PIC and load IDTR
; ------------------------------------------------------------------------------
idt_init:
    push rax
    push rbx
    push rdx
    push rsi

    call pic_remap

    xor ebx, ebx
.default_loop:
    mov al, bl
    lea rdx, [isr_ignore]
    call idt_set_gate
    inc ebx
    cmp ebx, 256
    jb .default_loop

    xor ebx, ebx
    lea rsi, [exc_stub_table]
.exc_loop:
    mov al, bl
    mov rdx, [rsi + rbx * 8]
    call idt_set_gate
    inc ebx
    cmp ebx, 32
    jb .exc_loop

    mov al, IRQ_BASE + 0
    lea rdx, [isr_timer]
    call idt_set_gate
    mov al, IRQ_BASE + 1
    lea rdx, [isr_keyboard]
    call idt_set_gate
    mov al, IRQ_BASE + 12
    lea rdx, [isr_mouse]
    call idt_set_gate

    lidt [idt_descriptor]

    pop rsi
    pop rdx
    pop rbx
    pop rax
    ret

section .rodata
align 8
exc_stub_table:
%assign i 0
%rep 32
    dq exc_stub_ %+ i
%assign i i + 1
%endrep
