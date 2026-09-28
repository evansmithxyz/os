; ==============================================================================
; Antigravity OS - 64-bit Interrupt Service Routines (ISRs)
; Handles 64-bit hardware IRQs and CPU exception vectors using iretq
; ==============================================================================

[bits 64]

timer_ticks:        dq 0
MSG_DEFAULT_EXC:    db 0x0A, "[CPU EXCEPTION] Unhandled exception occurred in 64-bit mode! System halted.", 0x0A, 0
MSG_DIV_ZERO:       db 0x0A, "[CPU EXCEPTION #0] 64-bit Division By Zero!", 0x0A, 0
MSG_GPF:            db 0x0A, "[CPU EXCEPTION #13] 64-bit General Protection Fault!", 0x0A, 0

; ------------------------------------------------------------------------------
; Default CPU Exception Handler
; ------------------------------------------------------------------------------
isr_default_exception:
    mov bl, 0x4F                ; White on Red
    mov rsi, MSG_DEFAULT_EXC
    call vga_print_string_color
    cli
    hlt
    jmp $

; ------------------------------------------------------------------------------
; Division by Zero (#0)
; ------------------------------------------------------------------------------
isr_divide_by_zero:
    mov bl, 0x4F
    mov rsi, MSG_DIV_ZERO
    call vga_print_string_color
    cli
    hlt
    jmp $

; ------------------------------------------------------------------------------
; General Protection Fault (#13)
; ------------------------------------------------------------------------------
isr_general_protection:
    mov bl, 0x4F
    mov rsi, MSG_GPF
    call vga_print_string_color
    cli
    hlt
    jmp $

; ------------------------------------------------------------------------------
; IRQ 0 - System Timer (8253 PIT)
; ------------------------------------------------------------------------------
isr_timer:
    push rax
    inc qword [timer_ticks]

    ; Send End Of Interrupt (EOI) to Master PIC
    mov al, 0x20
    out 0x20, al

    pop rax
    iretq

; ------------------------------------------------------------------------------
; IRQ 1 - PS/2 Keyboard Controller
; ------------------------------------------------------------------------------
isr_keyboard:
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

    ; Read raw scancode from port 0x60 if data is available
    in al, 0x64
    test al, 0x01
    jz .eoi
    in al, 0x60
    call keyboard_process_scancode

.eoi:
    ; Send EOI to Master PIC
    mov al, 0x20
    out 0x20, al

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    iretq

; ------------------------------------------------------------------------------
; IRQ 12 - PS/2 Mouse Controller (Vector 0x2C)
; ------------------------------------------------------------------------------
isr_mouse:
    push rax
    ; In case an interrupt fires, read port 0x60 if output full, then EOI
    in al, 0x64
    test al, 0x01
    jz .eoi
    in al, 0x60
.eoi:
    mov al, 0x20
    out 0xA0, al                ; EOI to Slave PIC
    out 0x20, al                ; EOI to Master PIC
    pop rax
    iretq

