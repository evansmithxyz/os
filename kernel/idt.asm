; ==============================================================================
; Antigravity OS - 64-bit Interrupt Descriptor Table (IDT) & 8259 PIC Remap
; Configures 16-byte 64-bit interrupt gates and hardware IRQs
; ==============================================================================

[bits 64]

; PIC I/O Ports
PIC1_COMMAND    equ 0x20
PIC1_DATA       equ 0x21
PIC2_COMMAND    equ 0xA0
PIC2_DATA       equ 0xA1
PIC_EOI         equ 0x20

; 64-bit IDT Gate Type
IDT_GATE_INTERRUPT  equ 0x8E    ; Present=1, DPL=00, GateType=1110 (64-bit Interrupt Gate)

align 16
idt64_start:
    times 256 * 16 db 0        ; 256 interrupt gates, 16 bytes each = 4096 bytes
idt64_end:

idt64_descriptor:
    dw idt64_end - idt64_start - 1  ; Limit (2 bytes)
    dq idt64_start                  ; Base Address (8 bytes for 64-bit LIDT)

; ------------------------------------------------------------------------------
; idt_set_gate: Installs a 64-bit interrupt handler into the IDT
; Input:
;   AL  = Interrupt vector (0 - 255)
;   RDX = 64-bit Handler address
;   CL  = Type / Attribute byte (0x8E)
; ------------------------------------------------------------------------------
idt_set_gate:
    push rax
    push rdi

    movzx rax, al
    shl rax, 4                  ; Multiply by 16 (16 bytes per gate)
    lea rdi, [idt64_start + rax]

    ; Bits 0..15 of handler offset
    mov [rdi], dx

    ; Code segment selector (0x18 = CODE_SEG64)
    mov word [rdi + 2], 0x18

    ; IST = 0 (Interrupt Stack Table unused)
    mov byte [rdi + 4], 0x00

    ; Type and attributes (0x8E)
    mov [rdi + 5], cl

    ; Bits 16..31 of handler offset
    mov rax, rdx
    shr rax, 16
    mov [rdi + 6], ax

    ; Bits 32..63 of handler offset
    mov rax, rdx
    shr rax, 32
    mov [rdi + 8], eax

    ; Reserved 32 bits (must be 0)
    mov dword [rdi + 12], 0x00000000

    pop rdi
    pop rax
    ret

; ------------------------------------------------------------------------------
; pic_remap: Remaps 8259 PIC so IRQs do not collide with CPU exceptions
; Master IRQ 0-7  -> INT 0x20 - 0x27
; Slave  IRQ 8-15 -> INT 0x28 - 0x2F
; ------------------------------------------------------------------------------
pic_remap:
    push rax

    ; ICW1: Start initialization sequence in cascade mode
    mov al, 0x11
    out PIC1_COMMAND, al
    call io_wait
    out PIC2_COMMAND, al
    call io_wait

    ; ICW2: Vector offsets
    mov al, 0x20                ; Master PIC vector offset 0x20 (32)
    out PIC1_DATA, al
    call io_wait
    mov al, 0x28                ; Slave PIC vector offset 0x28 (40)
    out PIC2_DATA, al
    call io_wait

    ; ICW3: Cascading configuration
    mov al, 0x04                ; Master PIC has slave at IRQ2
    out PIC1_DATA, al
    call io_wait
    mov al, 0x02                ; Slave PIC cascade identity (2)
    out PIC2_DATA, al
    call io_wait

    ; ICW4: Set 8086/88 mode
    mov al, 0x01
    out PIC1_DATA, al
    call io_wait
    out PIC2_DATA, al
    call io_wait

    ; Unmask IRQ 0 (Timer) and IRQ 1 (Keyboard): 11111100b = 0xFC
    mov al, 0xFC
    out PIC1_DATA, al
    mov al, 0xFF                ; Mask slave IRQs for now
    out PIC2_DATA, al

    pop rax
    ret

io_wait:
    out 0x80, al
    ret

; ------------------------------------------------------------------------------
; idt64_init: Initializes 64-bit IDT, remaps PIC, installs handlers, and loads IDTR
; ------------------------------------------------------------------------------
idt64_init:
    push rax
    push rbx
    push rcx
    push rdx

    ; Remap the 8259 PIC
    call pic_remap

    ; Populate all 256 gates with default exception handler
    xor rbx, rbx
.init_all_gates:
    mov al, bl
    mov rdx, isr_default_exception
    mov cl, IDT_GATE_INTERRUPT
    call idt_set_gate
    inc rbx
    cmp rbx, 256
    jl .init_all_gates

    ; Install specific CPU exception handlers
    mov al, 0                   ; Division by Zero (#0)
    mov rdx, isr_divide_by_zero
    mov cl, IDT_GATE_INTERRUPT
    call idt_set_gate

    mov al, 13                  ; General Protection Fault (#13)
    mov rdx, isr_general_protection
    mov cl, IDT_GATE_INTERRUPT
    call idt_set_gate

    ; Install IRQ 0 (Timer, vector 0x20)
    mov al, 0x20
    mov rdx, isr_timer
    mov cl, IDT_GATE_INTERRUPT
    call idt_set_gate

    ; Install IRQ 1 (Keyboard, vector 0x21)
    mov al, 0x21
    mov rdx, isr_keyboard
    mov cl, IDT_GATE_INTERRUPT
    call idt_set_gate

    ; Install IRQ 12 (Mouse, vector 0x2C)
    mov al, 0x2C
    mov rdx, isr_mouse
    mov cl, IDT_GATE_INTERRUPT
    call idt_set_gate

    ; Load 64-bit IDT Pointer register
    lidt [idt64_descriptor]

    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
