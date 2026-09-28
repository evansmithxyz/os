; ==============================================================================
; Antigravity OS - 64-bit Realtek RTL8139 Fast Ethernet Controller Driver
; Hardware Packet Transmission and Reception via I/O Port Ring Buffers
; ==============================================================================

[bits 64]

; Physical Memory Buffers for RTL8139 DMA (within identity-mapped 0-8 MB)
RTL_RX_BUFFER_PHYS  equ 0x00030000      ; 8KB + 16 bytes RX Ring Buffer
RTL_TX_BUFFER_PHYS  equ 0x00034000      ; 1.5 KB TX Buffer

; RTL8139 Register Offsets (relative to net_io_base)
RTL_REG_MAC0        equ 0x00            ; IDR0-5 (MAC Address 6 bytes)
RTL_REG_TSD0        equ 0x10            ; Transmit Status of Descriptor 0
RTL_REG_TSAD0       equ 0x20            ; Transmit Start Address of Descriptor 0
RTL_REG_RBSTART     equ 0x30            ; Receive Buffer Start Address
RTL_REG_CR          equ 0x37            ; Command Register
RTL_REG_CAPR        equ 0x38            ; Current Address of Packet Read
RTL_REG_CBR         equ 0x3A            ; Current Buffer Address
RTL_REG_IMR         equ 0x3C            ; Interrupt Mask Register
RTL_REG_ISR         equ 0x3E            ; Interrupt Status Register
RTL_REG_RCR         equ 0x44            ; Receive Configuration Register
RTL_REG_CONFIG1     equ 0x52            ; Configuration Register 1

; Command Register Bits
RTL_CR_BUFE         equ 0x01            ; Buffer Empty
RTL_CR_TE           equ 0x04            ; Transmitter Enable
RTL_CR_RE           equ 0x08            ; Receiver Enable
RTL_CR_RST          equ 0x10            ; Software Reset

; Driver State Variables
net_present:        db 0
net_io_base:        dw 0
net_rx_offset:      dw 0
net_tx_cur:         db 0

; Hardware MAC Address
net_mac:            db 0x52, 0x54, 0x00, 0x12, 0x34, 0x56

; Statistics
net_packets_rx:     dq 0
net_packets_tx:     dq 0
net_bytes_rx:       dq 0
net_bytes_tx:       dq 0

; Packet Scratch Buffers
align 16
net_tx_buf:         times 1600 db 0
align 16
net_rx_buf:         times 1600 db 0

; Messages
MSG_NET_FOUND:      db "[NET] RTL8139 NIC detected at I/O port 0x", 0
MSG_NET_MAC:        db " [MAC: ", 0
MSG_NET_NOT_FOUND:  db "[NET] Notice: RTL8139 PCI NIC not detected.", 0x0A, 0

; ------------------------------------------------------------------------------
; net_init: Discovers, resets, and configures RTL8139 Network Card
; ------------------------------------------------------------------------------
net_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; Find RTL8139 on PCI Bus: Vendor 0x10EC, Device 0x8139
    mov si, 0x10EC
    mov di, 0x8139
    call pci_find_device
    jnz .not_found

    ; EAX = bus, EBX = slot, ECX = func
    ; Enable Bus Mastering & I/O Space in PCI Command Register
    call pci_enable_bus_master

    ; Get Base I/O Port from BAR0
    call pci_get_bar0_io
    mov [net_io_base], ax

    ; Power on the NIC (Wakeup via CONFIG1 = 0x00)
    mov dx, [net_io_base]
    add dx, RTL_REG_CONFIG1
    xor al, al
    out dx, al

    ; Software Reset: Set bit 4 (RST) in CR
    mov dx, [net_io_base]
    add dx, RTL_REG_CR
    mov al, RTL_CR_RST
    out dx, al

    ; Poll until reset bit clears
.wait_reset:
    in al, dx
    test al, RTL_CR_RST
    jnz .wait_reset

    ; Clear Receive Buffer Memory (8KB + 16 bytes)
    mov rdi, RTL_RX_BUFFER_PHYS
    mov ecx, 8192 + 16
    xor eax, eax
    rep stosb

    ; Configure Receive Buffer Address (RBSTART = RTL_RX_BUFFER_PHYS)
    mov dx, [net_io_base]
    add dx, RTL_REG_RBSTART
    mov eax, RTL_RX_BUFFER_PHYS
    out dx, eax

    ; Set CAPR to 0xFFF0 (-16 bytes read pointer offset)
    mov dx, [net_io_base]
    add dx, RTL_REG_CAPR
    mov ax, 0xFFF0
    out dx, ax
    mov word [net_rx_offset], 0

    ; Configure Interrupt Mask Register (IMR = 0x0005: ROK | TOK)
    mov dx, [net_io_base]
    add dx, RTL_REG_IMR
    mov ax, 0x0005
    out dx, ax

    ; Configure Receive Configuration Register (RCR):
    ; Accept: Broadcast (bit 3) + Multicast (bit 2) + Physical match (bit 1) + All physical (bit 0) = 0x0F
    ; Wrap bit 7 = 1 (wrap buffer at 8KB) -> 0x8F
    mov dx, [net_io_base]
    add dx, RTL_REG_RCR
    mov eax, 0x0000008F
    out dx, eax

    ; Enable Receiver and Transmitter in CR (RE | TE = 0x0C)
    mov dx, [net_io_base]
    add dx, RTL_REG_CR
    mov al, RTL_CR_RE | RTL_CR_TE
    out dx, al

    ; Read Hardware MAC Address from IDR0-5 (offsets 0x00 .. 0x05)
    mov dx, [net_io_base]
    xor ecx, ecx
.read_mac:
    in al, dx
    mov [net_mac + rcx], al
    inc dx
    inc ecx
    cmp ecx, 6
    jl .read_mac

    mov byte [net_present], 1

    ; Print hardware status
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [MSG_NET_FOUND]
    call vga_print_string_color

    movzx eax, word [net_io_base]
    call vga_print_hex16

    lea rsi, [MSG_NET_MAC]
    call vga_print_string_color

    ; Print MAC address: XX:XX:XX:XX:XX:XX
    xor ecx, ecx
.print_mac_loop:
    movzx eax, byte [net_mac + rcx]
    call vga_print_hex8
    cmp ecx, 5
    je .mac_done
    mov al, ':'
    call vga_print_char
    inc ecx
    jmp .print_mac_loop

.mac_done:
    mov al, ']'
    call vga_print_char
    mov al, 0x0A
    call vga_print_char
    jmp .done

.not_found:
    mov byte [net_present], 0
    mov bl, COLOR_DARK_GRAY
    lea rsi, [MSG_NET_NOT_FOUND]
    call vga_print_string_color

.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; net_send_packet: Transmits an Ethernet packet frame via RTL8139 DMA
; Input:  RSI = Pointer to packet data (Ethernet frame)
;         RCX = Packet length in bytes
; Output: RAX = 0 on success, 1 on failure
; ------------------------------------------------------------------------------
net_send_packet:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    cmp byte [net_present], 1
    jne .error

    cmp rcx, 1514
    jbe .len_ok
    mov rcx, 1514               ; Clamp to standard Ethernet MTU
.len_ok:
    cmp rcx, 60
    jae .no_pad
    ; Ethernet minimum frame length is 60 bytes (excluding FCS)
.no_pad:
    mov r8, rcx                 ; R8 = length

    ; Copy frame into physical TX DMA buffer (0x00034000)
    mov rdi, RTL_TX_BUFFER_PHYS
    push rcx
    rep movsb
    pop rcx

    ; Get current TX descriptor (0 .. 3)
    movzx ebx, byte [net_tx_cur]

    ; Write physical TX buffer address to TSAD[ebx]
    mov dx, [net_io_base]
    add dx, RTL_REG_TSAD0
    shl ebx, 2                  ; ebx * 4
    add dx, bx
    mov eax, RTL_TX_BUFFER_PHYS
    out dx, eax

    ; Write packet length to TSD[ebx] (Bits 12-0 = size, Bit 13 = 0, Bit 16 = 0)
    mov dx, [net_io_base]
    add dx, RTL_REG_TSD0
    add dx, bx
    mov eax, r8d
    and eax, 0x1FFF             ; Clamp to 8191
    out dx, eax

    ; Advance TX descriptor ring: (cur + 1) & 3
    movzx eax, byte [net_tx_cur]
    inc al
    and al, 3
    mov [net_tx_cur], al

    ; Update statistics
    inc qword [net_packets_tx]
    add [net_bytes_tx], r8

    ; Poll for transmit completion (TOK bit 15 in TSD) with timeout
    mov ecx, 100000
.poll_tx:
    in eax, dx
    test eax, 0x8000            ; TOK (Transmit OK)
    jnz .tx_ok
    test eax, 0x2000            ; TABT (Transmit Aborted)
    jnz .error
    dec ecx
    jnz .poll_tx

.tx_ok:
    xor rax, rax                ; Success
    jmp .done

.error:
    mov rax, 1

.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; net_poll: Polls the RTL8139 receiver ring buffer for arriving packets
; Called frequently in main kernel loop and network wait routines
; ------------------------------------------------------------------------------
net_poll:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    cmp byte [net_present], 1
    jne .poll_done

.poll_loop_packets:
    ; Check Command Register bit 0 (BUFE: Buffer Empty)
    mov dx, [net_io_base]
    add dx, RTL_REG_CR
    in al, dx
    test al, RTL_CR_BUFE
    jnz .poll_done              ; Buffer is empty, no packet waiting

    ; Read packet from RX ring buffer at RTL_RX_BUFFER_PHYS + net_rx_offset
    movzx rsi, word [net_rx_offset]
    add rsi, RTL_RX_BUFFER_PHYS

    ; Format of RTL8139 packet header:
    ; Offset 0 (2 bytes): Status flags (bit 0 = ROK)
    ; Offset 2 (2 bytes): Packet length (including 4-byte CRC)
    movzx eax, word [rsi]       ; Status
    test al, 0x01               ; ROK
    jz .reset_rx                ; If not OK, reset buffer

    movzx ecx, word [rsi + 2]   ; Length with CRC
    cmp ecx, 14
    jb .reset_rx
    cmp ecx, 1600
    ja .reset_rx

    ; Copy Ethernet frame (length - 4 CRC bytes) to net_rx_buf
    sub ecx, 4                  ; Strip 4-byte CRC
    mov r8, rcx                 ; R8 = Frame length

    add rsi, 4                  ; Skip 4-byte packet header
    lea rdi, [net_rx_buf]
    rep movsb

    ; Update statistics
    inc qword [net_packets_rx]
    add [net_bytes_rx], r8

    ; Advance net_rx_offset: (offset + len + 4 + 3) & ~3
    movzx eax, word [net_rx_offset]
    add eax, r8d
    add eax, 4 + 4 + 3          ; +4 header +4 CRC +3 for round up
    and eax, ~3
    and eax, 0x1FFF             ; Wrap around 8192 bytes (8KB ring)
    mov [net_rx_offset], ax

    ; Update CAPR (Current Address of Packet Read) = (offset - 16) & 0xFFFF
    sub ax, 16
    mov dx, [net_io_base]
    add dx, RTL_REG_CAPR
    out dx, ax

    ; Clear ROK in ISR (write 0x0001 to clear)
    mov dx, [net_io_base]
    add dx, RTL_REG_ISR
    mov ax, 0x0001
    out dx, ax

    ; Dispatch packet to Ethernet Protocol Layer
    lea rsi, [net_rx_buf]
    mov rcx, r8
    call eth_handle_packet

    ; Loop to drain any other pending packets
    jmp .poll_loop_packets

.reset_rx:
    ; Recovery from corrupted buffer state: reset CAPR to 0xFFF0 (-16)
    mov dx, [net_io_base]
    add dx, RTL_REG_CAPR
    mov ax, 0xFFF0
    out dx, ax
    mov word [net_rx_offset], 0

.poll_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
