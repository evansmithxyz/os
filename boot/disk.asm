; ==============================================================================
; Antigravity OS - Real Mode Disk Loading Routine
; Reads DH sectors from drive DL into ES:BX
; Uses INT 13h Extensions (AH=42h) with fallback to INT 13h (AH=02h)
; ==============================================================================

[bits 16]

disk_load:
    push dx
    push si

    ; Prepare LBA disk address packet
    mov byte [disk_packet_count], dh
    mov word [disk_packet_buf_off], bx

    mov si, disk_packet
    mov ah, 0x42                ; Extended Read Sectors from Drive
    int 0x13
    jnc .done

    ; Fallback to standard CHS read if LBA extensions fail
    mov ah, 0x02                ; BIOS read sector function
    mov al, dh                  ; Number of sectors to read
    mov ch, 0x00                ; Cylinder 0
    mov dh, 0x00                ; Head 0
    mov cl, 0x02                ; Sector 2 (Sector 1 is MBR)
    int 0x13
    jc disk_error               ; Carry flag set on error

.done:
    pop si
    pop dx
    ret

disk_error:
    mov si, MSG_DISK_ERR
    call print_string_rm
    cli
    hlt
    jmp $

MSG_DISK_ERR: db "Disk error!", 0x0D, 0x0A, 0

align 4
disk_packet:
    db 0x10                     ; Packet size (16 bytes)
    db 0                        ; Reserved
disk_packet_count:
    db 128                      ; Number of blocks (low byte)
    db 0                        ; Number of blocks (high byte)
disk_packet_buf_off:
    dw 0x8000                   ; Target offset
    dw 0x0000                   ; Target segment
    dq 1                        ; Starting LBA (Sector 1)
