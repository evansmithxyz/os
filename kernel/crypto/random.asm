; ==============================================================================
; Antigravity OS - random bytes for key generation
; ------------------------------------------------------------------------------
; A SHA-256 pool. Every block of output hashes the pool together with the time
; stamp counter, the PIT tick count and (when the CPU has it) RDRAND. QEMU's
; default CPU has no RDRAND, so under QEMU the unpredictability comes from the
; TSC, which follows the host clock. Good enough for TLS key shares here; not
; a certified generator.
; ==============================================================================

[bits 64]

RAND_IN_SIZE            equ 65      ; pool 32 | tsc 8 | ticks 8 | rdrand 8 | counter 8 | tag 1

section .data
rand_has_rdrand:        db 0xFF     ; 0xFF = not checked yet

section .bss
alignb 16
rand_pool:              resb 32
rand_counter:           resq 1
rand_in:                resb RAND_IN_SIZE
alignb 16
rand_block:             resb 32

section .text
; ------------------------------------------------------------------------------
; rand_bytes: RDI = output, RCX = number of bytes
; ------------------------------------------------------------------------------
rand_bytes:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rcx                     ; R8 = bytes still wanted

    cmp byte [rand_has_rdrand], 0xFF
    jne .have_cpuid
    push rcx
    mov eax, 1
    cpuid
    shr ecx, 30                     ; CPUID.1:ECX bit 30 = RDRAND
    and cl, 1
    mov [rand_has_rdrand], cl
    pop rcx
.have_cpuid:

.block:
    test r8, r8
    jz .done
    ; rand_in = pool | tsc | ticks | rdrand | counter | tag
    push rdi
    lea rdi, [rand_in]
    lea rsi, [rand_pool]
    mov ecx, 32
    rep movsb
    rdtsc
    shl rdx, 32
    or rax, rdx
    stosq
    mov rax, [timer_ticks]
    stosq
    xor eax, eax
    cmp byte [rand_has_rdrand], 1
    jne .no_rdrand
    mov ecx, 10                     ; RDRAND can fail transiently
.retry:
    rdrand rax
    jc .no_rdrand
    dec ecx
    jnz .retry
    xor eax, eax
.no_rdrand:
    stosq
    inc qword [rand_counter]
    mov rax, [rand_counter]
    stosq

    ; output block = SHA256(in | 0), new pool = SHA256(in | 1)
    mov byte [rdi], 0
    lea rsi, [rand_in]
    mov ecx, RAND_IN_SIZE
    lea rdi, [rand_block]
    call sha256
    mov byte [rand_in + RAND_IN_SIZE - 1], 1
    lea rdi, [rand_pool]
    call sha256
    pop rdi

    ; copy up to 32 bytes out
    lea rsi, [rand_block]
    mov ecx, 32
    cmp r8, rcx
    jae .copy
    mov rcx, r8
.copy:
    sub r8, rcx
    rep movsb
    jmp .block

.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
