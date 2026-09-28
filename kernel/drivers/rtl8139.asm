; ==============================================================================
; Antigravity OS - Realtek RTL8139 Fast Ethernet Driver (polled, no IRQ)
; ------------------------------------------------------------------------------
; RX: 8 KB ring at NIC_RX_RING_ADDR in WRAP mode (packets that straddle the end
;     continue past it, so the ring has 1.5 KB of slack after 8 KB + 16).
; TX: 4 descriptors, each with its own 2 KB buffer at NIC_TX_BUF_ADDR + n*2048.
; net_poll drains the RX ring and hands frames to eth_handle_packet.
; ==============================================================================

[bits 64]

RTL_VENDOR_ID       equ 0x10EC
RTL_DEVICE_ID       equ 0x8139
RTL_RX_RING_SIZE    equ 8192
RTL_TX_BUF_SIZE     equ 2048

; Register offsets from net_io_base
RTL_REG_MAC0        equ 0x00
RTL_REG_TSD0        equ 0x10
RTL_REG_TSAD0       equ 0x20
RTL_REG_RBSTART     equ 0x30
RTL_REG_CR          equ 0x37
RTL_REG_CAPR        equ 0x38
RTL_REG_IMR         equ 0x3C
RTL_REG_ISR         equ 0x3E
RTL_REG_RCR         equ 0x44
RTL_REG_CONFIG1     equ 0x52

RTL_CR_BUFE         equ 0x01
RTL_CR_TE           equ 0x04
RTL_CR_RE           equ 0x08
RTL_CR_RST          equ 0x10

ETH_MAX_FRAME       equ 1514
ETH_MIN_FRAME       equ 60

section .data
net_present:        db 0
net_tx_cur:         db 0
net_io_base:        dw 0
net_rx_offset:      dw 0
net_mac:            db 0x52, 0x54, 0x00, 0x12, 0x34, 0x56
align 8
net_packets_rx:     dq 0
net_packets_tx:     dq 0
net_bytes_rx:       dq 0
net_bytes_tx:       dq 0

section .bss
alignb 16
net_rx_buf:         resb 1600       ; one received frame, CRC stripped

section .text
; ------------------------------------------------------------------------------
; net_init: find the card on PCI, reset it and start RX/TX
; ------------------------------------------------------------------------------
net_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov si, RTL_VENDOR_ID
    mov di, RTL_DEVICE_ID
    call pci_find_device
    jnz .not_found

    call pci_enable_bus_master
    call pci_get_bar0_io
    mov [net_io_base], ax

    mov dx, [net_io_base]           ; power on
    add dx, RTL_REG_CONFIG1
    xor al, al
    out dx, al

    mov dx, [net_io_base]           ; software reset
    add dx, RTL_REG_CR
    mov al, RTL_CR_RST
    out dx, al
    mov ecx, 1000000
.wait_reset:
    in al, dx
    test al, RTL_CR_RST
    jz .reset_done
    dec ecx
    jnz .wait_reset
.reset_done:

    mov rdi, NIC_RX_RING_ADDR       ; clear the ring
    mov ecx, RTL_RX_RING_SIZE + 16 + 1500
    xor eax, eax
    rep stosb

    mov dx, [net_io_base]
    add dx, RTL_REG_RBSTART
    mov eax, NIC_RX_RING_ADDR
    out dx, eax

    mov dx, [net_io_base]
    add dx, RTL_REG_CAPR
    mov ax, 0xFFF0
    out dx, ax
    mov word [net_rx_offset], 0

    mov dx, [net_io_base]
    add dx, RTL_REG_IMR
    mov ax, 0x0005                  ; ROK | TOK (status only; IRQ line unused)
    out dx, ax

    mov dx, [net_io_base]           ; accept broadcast/multicast/match/all, WRAP
    add dx, RTL_REG_RCR
    mov eax, 0x0000008F
    out dx, eax

    mov dx, [net_io_base]
    add dx, RTL_REG_CR
    mov al, RTL_CR_RE | RTL_CR_TE
    out dx, al

    mov dx, [net_io_base]           ; MAC address from IDR0-5
    xor ecx, ecx
.read_mac:
    in al, dx
    mov [net_mac + rcx], al
    inc dx
    inc ecx
    cmp ecx, 6
    jb .read_mac

    mov byte [net_present], 1

    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [msg_net_found]
    call con_puts_color
    mov ax, [net_io_base]
    call con_hex16
    lea rsi, [msg_net_mac]
    call con_puts_color
    lea rsi, [net_mac]
    call con_mac
    mov al, ']'
    call con_putc
    call con_newline
    jmp .done

.not_found:
    mov byte [net_present], 0
    mov bl, COLOR_DARK_GRAY
    lea rsi, [msg_net_missing]
    call con_puts_color
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; net_send_packet: RSI = Ethernet frame, RCX = length -> RAX = 0 ok / 1 error
; ------------------------------------------------------------------------------
net_send_packet:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    cmp byte [net_present], 1
    jne .error

    cmp rcx, ETH_MAX_FRAME
    jbe .len_ok
    mov ecx, ETH_MAX_FRAME
.len_ok:
    mov r8, rcx

    ; Buffer for this descriptor
    movzx ebx, byte [net_tx_cur]
    mov edi, ebx
    shl edi, 11                     ; * RTL_TX_BUF_SIZE
    add rdi, NIC_TX_BUF_ADDR
    push rdi
    rep movsb
    ; Pad short frames to the Ethernet minimum with zeros
    mov rcx, ETH_MIN_FRAME
    sub rcx, r8
    jle .no_pad
    xor eax, eax
    rep stosb
    mov r8d, ETH_MIN_FRAME
.no_pad:
    pop rdi

    shl ebx, 2                      ; descriptor register offset
    mov dx, [net_io_base]
    add dx, RTL_REG_TSAD0
    add dx, bx
    mov eax, edi
    out dx, eax

    mov dx, [net_io_base]
    add dx, RTL_REG_TSD0
    add dx, bx
    mov eax, r8d
    and eax, 0x1FFF
    out dx, eax                     ; writing the size starts the transmit

    movzx eax, byte [net_tx_cur]
    inc al
    and al, 3
    mov [net_tx_cur], al

    inc qword [net_packets_tx]
    add [net_bytes_tx], r8

    mov ecx, 100000
.poll_tx:
    in eax, dx
    test eax, 0x8000                ; TOK
    jnz .ok
    test eax, 0x2000                ; TABT
    jnz .error
    dec ecx
    jnz .poll_tx
.ok:
    xor eax, eax
    jmp .done
.error:
    mov eax, 1
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; net_poll: process every frame waiting in the RX ring
; ------------------------------------------------------------------------------
net_poll:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    cmp byte [net_present], 1
    jne .done

.next_packet:
    mov dx, [net_io_base]
    add dx, RTL_REG_CR
    in al, dx
    test al, RTL_CR_BUFE
    jnz .done

    movzx esi, word [net_rx_offset]
    add rsi, NIC_RX_RING_ADDR
    movzx eax, word [rsi]           ; RX status
    test al, 0x01                   ; ROK
    jz .reset_rx
    movzx ecx, word [rsi + 2]       ; length including CRC
    cmp ecx, 14 + 4
    jb .reset_rx
    cmp ecx, 1600
    ja .reset_rx

    sub ecx, 4                      ; strip CRC
    mov r8, rcx
    add rsi, 4                      ; skip the RX header
    lea rdi, [net_rx_buf]
    rep movsb

    inc qword [net_packets_rx]
    add [net_bytes_rx], r8

    movzx eax, word [net_rx_offset] ; offset += header + frame + CRC, dword aligned
    add eax, r8d
    add eax, 4 + 4 + 3
    and eax, ~3
    and eax, RTL_RX_RING_SIZE - 1
    mov [net_rx_offset], ax

    sub ax, 16                      ; CAPR lags the read pointer by 16
    mov dx, [net_io_base]
    add dx, RTL_REG_CAPR
    out dx, ax

    mov dx, [net_io_base]
    add dx, RTL_REG_ISR
    mov ax, 0x0001                  ; ack ROK
    out dx, ax

    lea rsi, [net_rx_buf]
    mov rcx, r8
    call eth_handle_packet
    jmp .next_packet

.reset_rx:
    call rtl_reset_rx
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; rtl_reset_rx: the RX ring looks corrupt - restart the receiver so the card's
; write pointer and our read pointer agree again (both back at offset 0)
; ------------------------------------------------------------------------------
rtl_reset_rx:
    push rax
    push rdx
    mov dx, [net_io_base]
    add dx, RTL_REG_CR
    mov al, RTL_CR_TE               ; receiver off
    out dx, al
    mov dx, [net_io_base]
    add dx, RTL_REG_RBSTART
    mov eax, NIC_RX_RING_ADDR
    out dx, eax
    mov dx, [net_io_base]
    add dx, RTL_REG_RCR
    mov eax, 0x0000008F
    out dx, eax
    mov dx, [net_io_base]
    add dx, RTL_REG_CR
    mov al, RTL_CR_RE | RTL_CR_TE   ; receiver on: resets the write pointer
    out dx, al
    mov dx, [net_io_base]
    add dx, RTL_REG_CAPR
    mov ax, 0xFFF0
    out dx, ax
    mov word [net_rx_offset], 0
    pop rdx
    pop rax
    ret

; ------------------------------------------------------------------------------
; net_wait_step: one iteration of a "wait for the network" loop. Services the
; NIC, keeps the GUI responsive and pauses briefly. Use it in every polling
; loop instead of hand-rolled spin delays.
; ------------------------------------------------------------------------------
net_wait_step:
    push rcx
    call net_poll
    call con_idle
    mov ecx, 2000
.spin:
    pause
    dec ecx
    jnz .spin
    pop rcx
    ret

section .rodata
msg_net_found:      db "[NET] RTL8139 NIC at I/O port 0x", 0
msg_net_mac:        db " [MAC ", 0
msg_net_missing:    db "[NET] Notice: RTL8139 PCI NIC not detected.", 0x0A, 0
