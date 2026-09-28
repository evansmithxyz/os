; ==============================================================================
; Antigravity OS - 64-Bit ATA PIO Hard Disk Controller Driver
; Reads and writes 512-byte raw sectors via Primary ATA Bus (Ports 0x1F0-0x1F7)
; ==============================================================================

[bits 64]
section .text

; Primary ATA Bus I/O Ports
ATA_DATA        equ 0x1F0
ATA_ERROR       equ 0x1F1
ATA_SECT_CNT    equ 0x1F2
ATA_LBA_LOW     equ 0x1F3
ATA_LBA_MID     equ 0x1F4
ATA_LBA_HIGH    equ 0x1F5
ATA_DRIVE_HEAD  equ 0x1F6
ATA_STATUS_CMD  equ 0x1F7

; ATA Commands
ATA_CMD_READ    equ 0x20
ATA_CMD_WRITE   equ 0x30
ATA_CMD_FLUSH   equ 0xE7

; ATA Status Bits
ATA_STATUS_BSY  equ 0x80        ; Drive is preparing/busy
ATA_STATUS_DRQ  equ 0x08        ; Data Request ready
ATA_STATUS_ERR  equ 0x01        ; Error occurred
ATA_STATUS_DF   equ 0x20        ; Device Fault

; ------------------------------------------------------------------------------
; ata_wait_bsy: Polls until BSY flag (bit 7) is cleared
; ------------------------------------------------------------------------------
ata_wait_bsy:
    push rdx
    mov dx, ATA_STATUS_CMD
.loop:
    in al, dx
    test al, ATA_STATUS_BSY
    jnz .loop
    pop rdx
    ret

; ------------------------------------------------------------------------------
; ata_wait_ready: Waits 400ns, then polls until BSY=0 and DRQ=1
; Returns: RAX = 0 (Success), RAX = 1 (Error)
; ------------------------------------------------------------------------------
ata_wait_ready:
    push rdx

    ; Read status 4 times for standard 400ns ATA bus recovery
    mov dx, ATA_STATUS_CMD
    in al, dx
    in al, dx
    in al, dx
    in al, dx

.poll:
    in al, dx
    test al, ATA_STATUS_BSY
    jnz .poll                   ; Wait if still busy

    test al, ATA_STATUS_ERR
    jnz .fail
    test al, ATA_STATUS_DF
    jnz .fail

    test al, ATA_STATUS_DRQ
    jz .poll                    ; Wait until data request ready

    xor rax, rax                ; Success
    pop rdx
    ret

.fail:
    mov rax, 1                  ; Error
    pop rdx
    ret

; ------------------------------------------------------------------------------
; ata_read_sector: Reads one 512-byte sector from disk into RAM
; Input:
;   RAX = 28-bit LBA sector address
;   RDI = Destination buffer in memory (512 bytes)
; Returns:
;   RAX = 0 on success, 1 on failure
; ------------------------------------------------------------------------------
ata_read_sector:
    push rbx
    push rcx
    push rdx
    push rdi

    mov rbx, rax                ; RBX = LBA sector

    call ata_wait_bsy

    ; Send 0xE0 | LBA[27:24] to Drive/Head port
    mov rax, rbx
    shr rax, 24
    and al, 0x0F
    or al, 0xE0                 ; Master drive, LBA28 mode
    mov dx, ATA_DRIVE_HEAD
    out dx, al

    ; Sector count = 1
    mov dx, ATA_SECT_CNT
    mov al, 1
    out dx, al

    ; LBA bits 0-7
    mov rax, rbx
    mov dx, ATA_LBA_LOW
    out dx, al

    ; LBA bits 8-15
    shr rax, 8
    mov dx, ATA_LBA_MID
    out dx, al

    ; LBA bits 16-23
    shr rax, 8
    mov dx, ATA_LBA_HIGH
    out dx, al

    ; Send Read command (0x20)
    mov dx, ATA_STATUS_CMD
    mov al, ATA_CMD_READ
    out dx, al

    ; Wait until data is ready in buffer
    call ata_wait_ready
    test rax, rax
    jnz .error

    ; Read 256 16-bit words (512 bytes) from Data port
    mov dx, ATA_DATA
    mov rcx, 256
.read_loop:
    in ax, dx
    mov [rdi], ax
    add rdi, 2
    loop .read_loop

    xor rax, rax                ; Success
    jmp .done

.error:
    mov rax, 1

.done:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; ata_write_sector: Writes one 512-byte sector from RAM to disk
; Input:
;   RAX = 28-bit LBA sector address
;   RSI = Source buffer in memory (512 bytes)
; Returns:
;   RAX = 0 on success, 1 on failure
; ------------------------------------------------------------------------------
ata_write_sector:
    push rbx
    push rcx
    push rdx
    push rsi

    mov rbx, rax                ; RBX = LBA sector

    call ata_wait_bsy

    ; Send 0xE0 | LBA[27:24] to Drive/Head port
    mov rax, rbx
    shr rax, 24
    and al, 0x0F
    or al, 0xE0
    mov dx, ATA_DRIVE_HEAD
    out dx, al

    ; Sector count = 1
    mov dx, ATA_SECT_CNT
    mov al, 1
    out dx, al

    ; LBA bits 0-7
    mov rax, rbx
    mov dx, ATA_LBA_LOW
    out dx, al

    ; LBA bits 8-15
    shr rax, 8
    mov dx, ATA_LBA_MID
    out dx, al

    ; LBA bits 16-23
    shr rax, 8
    mov dx, ATA_LBA_HIGH
    out dx, al

    ; Send Write command (0x30)
    mov dx, ATA_STATUS_CMD
    mov al, ATA_CMD_WRITE
    out dx, al

    ; Wait until drive is ready to receive data
    call ata_wait_ready
    test rax, rax
    jnz .error

    ; Write 256 16-bit words (512 bytes) to Data port
    mov dx, ATA_DATA
    mov rcx, 256
.write_loop:
    mov ax, [rsi]
    out dx, ax
    add rsi, 2
    loop .write_loop

    ; Flush hardware write cache to commit data to physical disk
    call ata_wait_bsy
    mov dx, ATA_STATUS_CMD
    mov al, ATA_CMD_FLUSH
    out dx, al
    call ata_wait_bsy

    xor rax, rax                ; Success
    jmp .done

.error:
    mov rax, 1

.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
