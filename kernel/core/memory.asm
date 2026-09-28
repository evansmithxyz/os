; ==============================================================================
; Antigravity OS - Physical Memory Detection
; ------------------------------------------------------------------------------
; Stage 2 stores the BIOS E820 map at E820_MAP_ADDR (count in BOOTINFO).
; memory_init sums the usable (type 1) regions into mem_total_bytes.
; ==============================================================================

[bits 64]

E820_TYPE_USABLE        equ 1

section .data
mem_total_bytes:        dq 0        ; usable RAM in bytes
mem_highest_usable:     dq 0        ; end address of the highest usable region

section .text
memory_init:
    push rax
    push rbx
    push rcx
    push rsi

    xor ebx, ebx                    ; total
    cmp dword [abs BOOTINFO_ADDR + BI_MAGIC], BOOTINFO_MAGIC
    jne .done
    movzx ecx, word [abs BOOTINFO_ADDR + BI_E820_COUNT]
    mov rsi, E820_MAP_ADDR
.loop:
    test ecx, ecx
    jz .done
    cmp dword [rsi + 16], E820_TYPE_USABLE
    jne .next
    mov rax, [rsi + 8]              ; length
    add rbx, rax
    add rax, [rsi]                  ; end = base + length
    cmp rax, [mem_highest_usable]
    jbe .next
    mov [mem_highest_usable], rax
.next:
    add rsi, E820_ENTRY_SIZE
    dec ecx
    jmp .loop
.done:
    mov [mem_total_bytes], rbx
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; memory_total_mb: RAX = usable RAM in MB
; ------------------------------------------------------------------------------
memory_total_mb:
    mov rax, [mem_total_bytes]
    shr rax, 20
    ret
