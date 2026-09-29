; ==============================================================================
; Antigravity OS - Stage 2 Loader
; ------------------------------------------------------------------------------
; Loaded by stage 1 to STAGE2_ADDR, entered in 16-bit real mode with the boot
; drive in DL. Steps:
;   1. Init COM1 so boot progress is visible on the serial console
;   2. Enable A20, then load the kernel (s2_kernel_sectors, patched in by
;      tools/mkimage.py) to KERNEL_ADDR above 1 MB: each 32 KB chunk is read
;      into KERNEL_LOAD_BUF and copied up in unreal mode (copy_high)
;   3. Collect the BIOS E820 memory map into BOOTINFO
;   4. Enter 32-bit protected mode, build 4-level identity paging for 0-4 GB
;      with 2 MB pages, enable long mode and jump to the 64-bit kernel
; ==============================================================================

%include "layout.inc"
%include "memmap.inc"

[org STAGE2_ADDR]
[bits 16]

COM1                equ 0x3F8
KERNEL_CHUNK        equ 64                      ; sectors per BIOS read (32 KB)

    jmp short s2_start
    nop
s2_magic:           db "AGS2"                   ; checked by stage 1 and mkimage.py
s2_kernel_sectors:  dw 0                        ; patched by tools/mkimage.py

s2_start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov [s2_boot_drive], dl

    call serial_init
    mov si, msg_stage2
    call print

    ; ---------------------------------------------------------------------
    ; 1. A20 line (BIOS first, then the "fast A20" port). Needed before the
    ;    kernel load: the kernel lives above 1 MB.
    ; ---------------------------------------------------------------------
    mov ax, 0x2401
    int 0x15
    in al, 0x92
    test al, 2
    jnz .a20_done
    or al, 2
    and al, 0xFE
    out 0x92, al
.a20_done:

    ; ---------------------------------------------------------------------
    ; 2. Load kernel
    ; ---------------------------------------------------------------------
    mov cx, [s2_kernel_sectors]
    test cx, cx
    jz .no_kernel
    cmp cx, KERNEL_MAX_SECTORS
    ja .no_kernel

    mov eax, KERNEL_LBA                         ; next LBA to read
    mov dword [s2_load_dest], KERNEL_ADDR
.load_loop:
    test cx, cx
    jz .loaded
    mov dx, cx
    cmp dx, KERNEL_CHUNK
    jbe .chunk_ok
    mov dx, KERNEL_CHUNK
.chunk_ok:
    mov [dap_count], dx
    mov word [dap_offset], KERNEL_LOAD_BUF & 0xF
    mov word [dap_segment], KERNEL_LOAD_BUF >> 4
    mov [dap_lba], eax
    mov dword [dap_lba + 4], 0

    pushad
    mov si, dap
    mov ah, 0x42
    mov dl, [s2_boot_drive]
    int 0x13
    popad
    jc .disk_error

    call copy_high
    sub cx, dx
    movzx edx, dx
    add eax, edx
    push eax
    mov al, '.'
    call putc_both
    pop eax
    jmp .load_loop

.loaded:
    mov si, msg_crlf
    call print

    ; ---------------------------------------------------------------------
    ; 3. BIOS E820 memory map -> E820_MAP_ADDR, count -> BOOTINFO
    ; ---------------------------------------------------------------------
    mov di, E820_MAP_ADDR
    xor ebx, ebx
    xor bp, bp
.e820_loop:
    mov eax, 0xE820
    mov edx, 0x534D4150                         ; "SMAP"
    mov ecx, E820_ENTRY_SIZE
    mov dword [di + 20], 1                      ; ACPI 3.0: mark entry valid
    int 0x15
    jc .e820_done
    cmp eax, 0x534D4150
    jne .e820_done
    test ecx, ecx
    jz .e820_next
    inc bp
    add di, E820_ENTRY_SIZE
    cmp bp, E820_MAX
    jae .e820_done
.e820_next:
    test ebx, ebx
    jnz .e820_loop
.e820_done:

    mov dword [BOOTINFO_ADDR + BI_MAGIC], BOOTINFO_MAGIC
    mov al, [s2_boot_drive]
    mov [BOOTINFO_ADDR + BI_BOOT_DRIVE], al
    mov [BOOTINFO_ADDR + BI_E820_COUNT], bp
    mov ax, [s2_kernel_sectors]
    mov [BOOTINFO_ADDR + BI_KERNEL_SECTORS], ax

    mov si, msg_pmode
    call print

    ; ---------------------------------------------------------------------
    ; 4. Protected mode. Mask the PICs first: the kernel remaps them later.
    ; ---------------------------------------------------------------------
    cli
    mov al, 0xFF
    out 0xA1, al
    out 0x21, al

    lgdt [gdt_descriptor]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp CODE_SEG32:pm_entry

.no_kernel:
    mov si, msg_no_kernel
    jmp .fail
.disk_error:
    mov si, msg_disk
.fail:
    call print
.halt:
    cli
    hlt
    jmp .halt

; ------------------------------------------------------------------------------
; Real-mode helpers
; ------------------------------------------------------------------------------
serial_init:                                    ; COM1: 115200 baud, 8N1, FIFO on
    push ax
    push dx
    mov dx, COM1 + 1
    xor al, al
    out dx, al                                  ; IER = 0 (no interrupts)
    mov dx, COM1 + 3
    mov al, 0x80
    out dx, al                                  ; DLAB on
    mov dx, COM1 + 0
    mov al, 1
    out dx, al                                  ; divisor low  (115200)
    mov dx, COM1 + 1
    xor al, al
    out dx, al                                  ; divisor high
    mov dx, COM1 + 3
    mov al, 0x03
    out dx, al                                  ; 8N1, DLAB off
    mov dx, COM1 + 2
    mov al, 0xC7
    out dx, al                                  ; FIFO enable + clear
    mov dx, COM1 + 4
    mov al, 0x03
    out dx, al                                  ; DTR + RTS
    pop dx
    pop ax
    ret

putc_both:                                      ; AL -> screen (BIOS) and COM1
    pusha
    push ax
    mov ah, 0x0E
    xor bx, bx
    int 0x10
    pop ax
    mov bl, al
    mov dx, COM1 + 5
    mov cx, 0xFFFF                  ; don't hang if there is no UART
.wait:
    in al, dx
    test al, 0x20
    jnz .send
    loop .wait
.send:
    mov dx, COM1
    mov al, bl
    out dx, al
    popa
    ret

print:                                          ; DS:SI NUL-terminated string
    push ax
    push si
.loop:
    lodsb
    test al, al
    jz .done
    call putc_both
    jmp .loop
.done:
    pop si
    pop ax
    ret

; copy_high: copy DX sectors from KERNEL_LOAD_BUF to the 32-bit address in
; s2_load_dest and advance it. Real-mode segments stop at 64 KB, so DS and ES
; are loaded with the flat 4 GB descriptor in protected mode first ("unreal
; mode"): the cached limits survive the switch back, and a32 moves reach any
; address. Done per chunk because a BIOS call may reload the segments.
copy_high:
    pushad
    cli
    lgdt [gdt_descriptor]
    mov eax, cr0
    or al, 1
    mov cr0, eax
    jmp short .pm
.pm:
    mov bx, DATA_SEG32
    mov ds, bx
    mov es, bx
    and al, 0xFE
    mov cr0, eax
    jmp short .rm
.rm:
    xor bx, bx                                  ; real-mode bases again (0),
    mov ds, bx                                  ; the 4 GB limits stay
    mov es, bx
    movzx ecx, dx
    shl ecx, 7                                  ; sectors * 512 / 4 = dwords
    mov esi, KERNEL_LOAD_BUF
    mov edi, [s2_load_dest]
    cld
    a32 rep movsd
    mov [s2_load_dest], edi
    sti
    popad
    ret

; ------------------------------------------------------------------------------
; 32-bit protected mode: build page tables, enable long mode
; ------------------------------------------------------------------------------
[bits 32]
pm_entry:
    mov ax, DATA_SEG32
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, STAGE1_ADDR

    ; Long mode supported? (CPUID 0x80000001 EDX bit 29)
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb .no_long_mode
    mov eax, 0x80000001
    cpuid
    test edx, 1 << 29
    jz .no_long_mode

    ; Clear PML4 + PDPT + 4 PDs (6 pages)
    mov edi, PML4_ADDR
    xor eax, eax
    mov ecx, (6 * 4096) / 4
    rep stosd

    mov dword [PML4_ADDR], PDPT_ADDR | 0x03     ; present | writable
    mov dword [PDPT_ADDR + 0],  (PD_ADDR + 0x0000) | 0x03
    mov dword [PDPT_ADDR + 8],  (PD_ADDR + 0x1000) | 0x03
    mov dword [PDPT_ADDR + 16], (PD_ADDR + 0x2000) | 0x03
    mov dword [PDPT_ADDR + 24], (PD_ADDR + 0x3000) | 0x03

    ; 2048 x 2 MB pages = identity map of 0 - 4 GB
    mov edi, PD_ADDR
    mov eax, 0x83                               ; present | writable | 2 MB page
    mov ecx, 2048
.map:
    mov [edi], eax
    mov dword [edi + 4], 0
    add eax, 0x200000
    add edi, 8
    loop .map

    mov eax, PML4_ADDR
    mov cr3, eax
    mov eax, cr4
    or eax, 1 << 5                              ; PAE
    mov cr4, eax
    mov ecx, 0xC0000080                         ; EFER
    rdmsr
    or eax, 1 << 8                              ; LME
    wrmsr
    mov eax, cr0
    or eax, 1 << 31                             ; PG
    mov cr0, eax
    jmp CODE_SEG64:lm_entry

.no_long_mode:
    mov esi, msg_no_lm
    mov edi, 0xB8000
.nlm_loop:
    lodsb
    test al, al
    jz .nlm_halt
    mov ah, 0x4F
    stosw
    jmp .nlm_loop
.nlm_halt:
    cli
    hlt
    jmp .nlm_halt

; ------------------------------------------------------------------------------
; 64-bit long mode: hand off to the kernel
; ------------------------------------------------------------------------------
[bits 64]
lm_entry:
    mov ax, DATA_SEG64
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov rsp, KERNEL_STACK_TOP
    xor rbp, rbp
    mov rdi, BOOTINFO_ADDR                      ; first argument: boot info
    mov rax, KERNEL_ADDR
    jmp rax

; ------------------------------------------------------------------------------
; Data
; ------------------------------------------------------------------------------
align 8
gdt_start:
    dq 0                                        ; 0x00 null
    dq 0x00CF9A000000FFFF                       ; 0x08 32-bit code
    dq 0x00CF92000000FFFF                       ; 0x10 32-bit data
    dq 0x00209A0000000000                       ; 0x18 64-bit code (L=1)
    dq 0x0000920000000000                       ; 0x20 64-bit data
gdt_end:
gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE_SEG32          equ 0x08
DATA_SEG32          equ 0x10
CODE_SEG64          equ 0x18
DATA_SEG64          equ 0x20

align 4
dap:
    db 0x10, 0
dap_count:      dw 0
dap_offset:     dw 0
dap_segment:    dw 0
dap_lba:        dq 0

s2_boot_drive:  db 0
align 4
s2_load_dest:   dd 0                            ; where copy_high puts the next chunk
msg_stage2:    db "AGOS stage2: loading kernel", 0
msg_crlf:       db 13, 10, 0
msg_pmode:      db "AGOS stage2: entering long mode", 13, 10, 0
msg_no_kernel:  db 13, 10, "stage2: no kernel (run tools/mkimage.py)", 0
msg_disk:       db 13, 10, "stage2: disk read error", 0
msg_no_lm:      db "This CPU does not support x86_64 long mode", 0

%if ($ - $$) > STAGE2_SECTORS * SECTOR_SIZE
    %error "stage2 is larger than STAGE2_SECTORS"
%endif
%if (KERNEL_LOAD_BUF & 0xFFFF) + KERNEL_CHUNK * SECTOR_SIZE > 0x10000
    %error "KERNEL_LOAD_BUF + KERNEL_CHUNK crosses a 64 KB DMA boundary"
%endif
