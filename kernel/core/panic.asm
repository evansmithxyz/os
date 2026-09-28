; ==============================================================================
; Antigravity OS - Kernel Panic / Exception Reporter
; ------------------------------------------------------------------------------
; On any CPU exception (or a call to `panic`), leave the GUI if it is active,
; then print a full register dump to the VGA console AND the serial port.
; Serial output starts with "[PANIC]" so tests and tools can detect it.
;
; To find the faulting function, look up RIP in build/kernel.map:
;     python tools/build.py sym 0x12345
; ==============================================================================

[bits 64]
section .text

; ------------------------------------------------------------------------------
; panic_exception: RDI = exception frame (see EXC_* offsets in core/idt.asm)
; ------------------------------------------------------------------------------
panic_exception:
    cli
    mov r15, rdi                    ; R15 = frame (callee-owned from here on)

    cmp byte [bga_active], 0
    je .text_ready
    call vga_restore_text_mode      ; get the dump onto a visible screen
.text_ready:
    mov byte [con_attr], 0x4F       ; white on red
    call con_newline

    lea rsi, [panic_hdr]
    call con_puts
    mov rax, [r15 + EXC_VECTOR]
    cmp rax, 32
    jb .named
    mov rax, 32                     ; "unknown"
.named:
    lea rsi, [exc_names]
    mov rsi, [rsi + rax * 8]
    call con_puts
    lea rsi, [panic_vector]
    call con_puts
    mov rax, [r15 + EXC_VECTOR]
    call con_dec
    lea rsi, [panic_err]
    call con_puts
    mov rax, [r15 + EXC_ERROR]
    call con_hex64
    call con_newline

    mov byte [con_attr], 0x0F
    lea rsi, [panic_rip]
    call con_puts
    mov rax, [r15 + EXC_RIP]
    call con_hex64
    lea rsi, [panic_rsp]
    call con_puts
    mov rax, [r15 + EXC_RSP]
    call con_hex64
    lea rsi, [panic_rflags]
    call con_puts
    mov rax, [r15 + EXC_RFLAGS]
    call con_hex64
    call con_newline

    lea rsi, [panic_cr2]
    call con_puts
    mov rax, cr2
    call con_hex64
    lea rsi, [panic_cr3]
    call con_puts
    mov rax, cr3
    call con_hex64
    lea rsi, [panic_cs]
    call con_puts
    mov rax, [r15 + EXC_CS]
    call con_hex16
    call con_newline

    ; General purpose registers, two per line
    lea rbx, [panic_regs]
    xor ecx, ecx
.reg_loop:
    mov rsi, [rbx + rcx * 8]        ; label
    call con_puts
    lea rdx, [panic_reg_offsets]
    movzx eax, byte [rdx + rcx]
    mov rax, [r15 + rax]
    call con_hex64
    test ecx, 1
    jz .reg_same_line
    call con_newline
.reg_same_line:
    inc ecx
    cmp ecx, 16
    jb .reg_loop

    ; A few qwords from the interrupted stack
    lea rsi, [panic_stack]
    call con_puts
    mov rbx, [r15 + EXC_RSP]
    xor ecx, ecx
.stack_loop:
    mov rax, [rbx + rcx * 8]
    call con_hex64
    mov al, ' '
    call con_putc
    inc ecx
    cmp ecx, 4
    jb .stack_loop
    call con_newline

    lea rsi, [panic_hint]
    call con_puts
    jmp panic_halt

; ------------------------------------------------------------------------------
; panic: RSI = message. Software panic for "can't happen" situations.
; ------------------------------------------------------------------------------
panic:
    cli
    push rsi
    cmp byte [bga_active], 0
    je .text_ready
    call vga_restore_text_mode
.text_ready:
    mov byte [con_attr], 0x4F
    call con_newline
    lea rsi, [panic_sw]
    call con_puts
    pop rsi
    call con_puts
    call con_newline
    lea rsi, [panic_caller]
    call con_puts
    mov rax, [rsp]                  ; return address of the caller
    call con_hex64
    call con_newline
panic_halt:
    cli
.halt:
    hlt
    jmp .halt

section .rodata
panic_hdr:      db "[PANIC] CPU exception: ", 0
panic_vector:   db " (vector ", 0
panic_err:      db ", error code ", 0
panic_rip:      db "RIP=", 0
panic_rsp:      db "  RSP=", 0
panic_rflags:   db "  RFLAGS=", 0
panic_cr2:      db "CR2=", 0
panic_cr3:      db "  CR3=", 0
panic_cs:       db "  CS=", 0
panic_stack:    db "Stack: ", 0
panic_hint:     db "System halted. Find RIP with: python tools/build.py sym <RIP>", 0x0A, 0
panic_sw:       db "[PANIC] ", 0
panic_caller:   db "Called from ", 0

panic_r_rax:    db "RAX=", 0
panic_r_rbx:    db "  RBX=", 0
panic_r_rcx:    db "RCX=", 0
panic_r_rdx:    db "  RDX=", 0
panic_r_rsi:    db "RSI=", 0
panic_r_rdi:    db "  RDI=", 0
panic_r_rbp:    db "RBP=", 0
panic_r_r8:     db "  R8 =", 0
panic_r_r9:     db "R9 =", 0
panic_r_r10:    db "  R10=", 0
panic_r_r11:    db "R11=", 0
panic_r_r12:    db "  R12=", 0
panic_r_r13:    db "R13=", 0
panic_r_r14:    db "  R14=", 0
panic_r_r15:    db "R15=", 0
panic_r_vec:    db "  VEC=", 0

align 8
panic_regs:
    dq panic_r_rax, panic_r_rbx, panic_r_rcx, panic_r_rdx
    dq panic_r_rsi, panic_r_rdi, panic_r_rbp, panic_r_r8
    dq panic_r_r9,  panic_r_r10, panic_r_r11, panic_r_r12
    dq panic_r_r13, panic_r_r14, panic_r_r15, panic_r_vec
panic_reg_offsets:
    db EXC_RAX, EXC_RBX, EXC_RCX, EXC_RDX, EXC_RSI, EXC_RDI, EXC_RBP, EXC_R8
    db EXC_R9,  EXC_R10, EXC_R11, EXC_R12, EXC_R13, EXC_R14, EXC_R15, EXC_VECTOR

exc_n0:  db "Divide Error (#DE)", 0
exc_n1:  db "Debug (#DB)", 0
exc_n2:  db "NMI", 0
exc_n3:  db "Breakpoint (#BP)", 0
exc_n4:  db "Overflow (#OF)", 0
exc_n5:  db "Bound Range (#BR)", 0
exc_n6:  db "Invalid Opcode (#UD)", 0
exc_n7:  db "Device Not Available (#NM)", 0
exc_n8:  db "Double Fault (#DF)", 0
exc_n9:  db "Coprocessor Segment Overrun", 0
exc_n10: db "Invalid TSS (#TS)", 0
exc_n11: db "Segment Not Present (#NP)", 0
exc_n12: db "Stack Fault (#SS)", 0
exc_n13: db "General Protection Fault (#GP)", 0
exc_n14: db "Page Fault (#PF)", 0
exc_n15: db "Reserved", 0
exc_n16: db "x87 FP Error (#MF)", 0
exc_n17: db "Alignment Check (#AC)", 0
exc_n18: db "Machine Check (#MC)", 0
exc_n19: db "SIMD FP Error (#XM)", 0
exc_n20: db "Virtualization (#VE)", 0
exc_n21: db "Control Protection (#CP)", 0
exc_nres: db "Reserved", 0
exc_n29: db "VMM Communication (#VC)", 0
exc_n30: db "Security (#SX)", 0
exc_nunk: db "Unknown", 0

align 8
exc_names:
    dq exc_n0, exc_n1, exc_n2, exc_n3, exc_n4, exc_n5, exc_n6, exc_n7
    dq exc_n8, exc_n9, exc_n10, exc_n11, exc_n12, exc_n13, exc_n14, exc_n15
    dq exc_n16, exc_n17, exc_n18, exc_n19, exc_n20, exc_n21, exc_nres, exc_nres
    dq exc_nres, exc_nres, exc_nres, exc_nres, exc_nres, exc_n29, exc_n30, exc_nres
    dq exc_nunk
