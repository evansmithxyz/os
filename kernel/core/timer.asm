; ==============================================================================
; Antigravity OS - PIT Timer (IRQ0)
; ------------------------------------------------------------------------------
; Channel 0 is programmed to TIMER_HZ, so one tick is one millisecond.
; Use TICKS(ms) when converting a timeout so code stays correct if TIMER_HZ
; ever changes.
; ==============================================================================

[bits 64]

TIMER_HZ                equ 1000
PIT_BASE_HZ             equ 1193182
PIT_DIVISOR             equ (PIT_BASE_HZ + TIMER_HZ / 2) / TIMER_HZ

%define TICKS(ms) (((ms) * TIMER_HZ) / 1000)

section .data
timer_ticks:            dq 0

section .text
; ------------------------------------------------------------------------------
; timer_init: PIT channel 0, mode 2 (rate generator), TIMER_HZ
; ------------------------------------------------------------------------------
timer_init:
    push rax
    mov al, 0x34                    ; channel 0, lobyte/hibyte, mode 2, binary
    out 0x43, al
    mov al, PIT_DIVISOR & 0xFF
    out 0x40, al
    mov al, PIT_DIVISOR >> 8
    out 0x40, al
    pop rax
    ret

; ------------------------------------------------------------------------------
; isr_timer: IRQ0 handler
; ------------------------------------------------------------------------------
isr_timer:
    push rax
    inc qword [timer_ticks]
    mov al, PIC_EOI
    out PIC1_COMMAND, al
    pop rax
    iretq

; ------------------------------------------------------------------------------
; sleep_ms: RAX = milliseconds. Sleeps with HLT (interrupts must be enabled).
; ------------------------------------------------------------------------------
sleep_ms:
    push rax
    add rax, [timer_ticks]
.wait:
    cmp [timer_ticks], rax
    jae .done
    hlt
    jmp .wait
.done:
    pop rax
    ret

; ------------------------------------------------------------------------------
; timer_uptime_seconds: RAX = seconds since boot
; ------------------------------------------------------------------------------
timer_uptime_seconds:
    push rdx
    push rcx
    mov rax, [timer_ticks]
    xor edx, edx
    mov ecx, TIMER_HZ
    div rcx
    pop rcx
    pop rdx
    ret
