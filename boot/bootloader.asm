; ==============================================================================
; Antigravity OS - 64-bit Long Mode MBR Bootloader
; Loads the 64-bit Kernel, enables Identity Paging, and enters 64-bit Long Mode
; Fits strictly in 512 bytes with 0xAA55 signature
; ==============================================================================

[org 0x7c00]
[bits 16]

KERNEL_OFFSET  equ 0x8000       ; Physical memory address to load kernel
KERNEL_SECTORS equ 128          ; Number of sectors to load (64 KB)

start:
    ; Normalize segments & stack
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00

    mov [BOOT_DRIVE], dl        ; Save boot drive

    sti

    ; Print real mode boot message
    mov si, MSG_BOOTING
    call print_string_rm

    ; Load kernel sectors from disk
    mov bx, KERNEL_OFFSET
    mov dh, KERNEL_SECTORS
    mov dl, [BOOT_DRIVE]
    call disk_load

    ; Enable A20 address line
    call enable_a20

    ; Switch to 32-bit Protected Mode
    cli
    lgdt [gdt_descriptor]

    mov eax, cr0
    or al, 1                    ; Set PE (Protection Enable) bit
    mov cr0, eax

    ; Far jump to flush CPU pipeline into 32-bit code segment
    jmp CODE_SEG32:pm_entry

; Teletype print string routine in Real Mode
print_string_rm:
    mov ah, 0x0E
.loop:
    lodsb
    test al, al
    jz .done
    int 0x10
    jmp .loop
.done:
    ret

; ------------------------------------------------------------------------------
; Included Real Mode Modules
; ------------------------------------------------------------------------------
%include "disk.asm"
%include "a20.asm"
%include "gdt.asm"

; ------------------------------------------------------------------------------
; 32-Bit Protected Mode Trampoline -> Setup Paging & Enter 64-bit Long Mode
; ------------------------------------------------------------------------------
[bits 32]
pm_entry:
    mov ax, DATA_SEG32
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x7c00

    ; Check for Long Mode support via CPUID (Function 0x80000001, EDX bit 29)
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb .no_lm

    mov eax, 0x80000001
    cpuid
    test edx, (1 << 29)
    jz .no_lm

    ; Setup 4-level Identity Paging for full 4 GB physical memory:
    ; Clear 24 KB for PML4 (0x1000), PDPT (0x2000), PDTs (0x3000 - 0x7000)
    mov edi, 0x1000
    xor eax, eax
    mov ecx, 6144               ; 24,576 / 4 = 6144 dwords
    rep stosd

    ; PML4 at 0x1000: Entry 0 -> PDPT at 0x2000 (Present | Writable)
    mov dword [0x1000], 0x2003

    ; PDPT at 0x2000: Entries 0..3 -> Page Directories at 0x3000, 0x4000, 0x5000, 0x6000
    mov dword [0x2000], 0x3003
    mov dword [0x2008], 0x4003
    mov dword [0x2010], 0x5003
    mov dword [0x2018], 0x6003

    ; Identity-map all 4 GB using 2048 x 2 MB huge pages (Present | Writable | 2MB PageSize = 0x83)
    mov edi, 0x3000
    mov eax, 0x00000083
    mov ecx, 2048
.map_4gb:
    mov [edi], eax
    add eax, 0x00200000         ; +2 MB
    add edi, 8
    loop .map_4gb

    ; Point CR3 to PML4
    mov eax, 0x1000
    mov cr3, eax

    ; Enable Physical Address Extension (PAE) in CR4 (bit 5)
    mov eax, cr4
    or eax, (1 << 5)
    mov cr4, eax

    ; Enable Long Mode in EFER MSR (0xC0000080, bit 8 = LME)
    mov ecx, 0xC0000080
    rdmsr
    or eax, (1 << 8)
    wrmsr

    ; Enable Paging in CR0 (bit 31 = PG)
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax

    ; Far jump to 64-bit Long Mode code segment!
    jmp CODE_SEG64:long_mode_entry

.no_lm:
    hlt
    jmp .no_lm

; ------------------------------------------------------------------------------
; 64-Bit Long Mode Entry Point
; ------------------------------------------------------------------------------
[bits 64]
long_mode_entry:
    mov ax, DATA_SEG64
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    mov rsp, 0x00090000         ; 64-bit Stack Pointer
    mov rbp, rsp

    jmp KERNEL_OFFSET           ; Transfer control to 64-bit Kernel

; ------------------------------------------------------------------------------
; Real Mode Data Strings
; ------------------------------------------------------------------------------
[bits 16]
BOOT_DRIVE:  db 0
MSG_BOOTING: db "Booting Antigravity OS [x86_64]...", 0x0D, 0x0A, 0

; ------------------------------------------------------------------------------
; MBR Boot Signature Padding (Must be exactly 512 bytes)
; ------------------------------------------------------------------------------
times 510 - ($ - $$) db 0
dw 0xAA55
