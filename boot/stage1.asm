; ==============================================================================
; Antigravity OS - Stage 1 (MBR boot sector, 512 bytes)
; ------------------------------------------------------------------------------
; The BIOS loads this sector to 0x7C00 and jumps here in 16-bit real mode with
; the boot drive in DL. Its only job is to load stage 2 (STAGE2_SECTORS sectors
; starting at STAGE2_LBA) to STAGE2_ADDR and jump to it with DL preserved.
; ==============================================================================

%include "layout.inc"
%include "memmap.inc"

[org STAGE1_ADDR]
[bits 16]

    jmp short start
    nop
    ; BIOS Parameter Block placeholder. Some BIOSes (USB "floppy" emulation)
    ; write a BPB over bytes 3-61 of the boot sector, so no code may live here.
    times 0x3E - ($ - $$) db 0

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, STAGE1_ADDR
    sti
    cld
    jmp 0x0000:.flush_cs            ; normalise CS:IP (some BIOSes use 07C0:0000)
.flush_cs:
    mov [boot_drive], dl

    mov si, msg_boot
    call print

    ; Require INT 13h extensions (LBA addressing)
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [boot_drive]
    int 0x13
    jc .no_ext
    cmp bx, 0xAA55
    jne .no_ext
    test cx, 1                      ; "device access using the packet structure"
    jz .no_ext

    ; Read stage 2
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jc .disk_error

    ; Sanity check the stage 2 signature ("AGS2" at offset 3)
    cmp dword [STAGE2_ADDR + 3], 0x32534741
    jne .bad_stage2

    mov dl, [boot_drive]
    jmp 0x0000:STAGE2_ADDR

.no_ext:
    mov si, msg_no_ext
    jmp .fail
.disk_error:
    mov si, msg_disk
    jmp .fail
.bad_stage2:
    mov si, msg_stage2
.fail:
    call print
.halt:
    cli
    hlt
    jmp .halt

; print: BIOS teletype output of the NUL-terminated string at DS:SI
print:
    pusha
    mov ah, 0x0E
    xor bx, bx
.loop:
    lodsb
    test al, al
    jz .done
    int 0x10
    jmp .loop
.done:
    popa
    ret

boot_drive:     db 0
msg_boot:       db "AGOS stage1", 13, 10, 0
msg_no_ext:     db "No INT13 LBA extensions", 0
msg_disk:       db "Disk read error (stage2)", 0
msg_stage2:     db "Bad stage2 signature", 0

align 4
dap:                                ; INT 13h AH=42h disk address packet
    db 0x10, 0
    dw STAGE2_SECTORS
    dw STAGE2_ADDR, 0x0000          ; offset, segment
    dq STAGE2_LBA

; Partition table: one active entry covering everything after the MBR.
; Real BIOSes often refuse to boot a USB disk without one; QEMU ignores it.
times 0x1BE - ($ - $$) db 0
    db 0x80                         ; active
    db 0x00, 0x02, 0x00             ; CHS start (cylinder 0, head 0, sector 2)
    db 0xDA                         ; type: non-filesystem data
    db 0xFE, 0xFF, 0xFF             ; CHS end: use LBA
    dd 1                            ; first LBA
    dd DISK_SECTORS - 1             ; sector count
    times 3 * 16 db 0               ; entries 2-4 unused
dw 0xAA55
