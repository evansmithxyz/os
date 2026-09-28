; ==============================================================================
; Antigravity OS - 64-bit IPv4 & ICMP (Ping) Network Protocol Engine
; Internet Checksum Calculation, Packet Encapsulation, and Echo Handling
; ==============================================================================

[bits 64]

IPV4_PROTO_ICMP     equ 1
IPV4_PROTO_TCP      equ 6
IPV4_PROTO_UDP      equ 17

ICMP_ECHO_REPLY     equ 0
ICMP_ECHO_REQUEST   equ 8

; State Variables
ipv4_packet_id:     dw 0x1000
resolved_dst_mac:   times 6 db 0

; Ping State
ping_reply_rx:      db 0
ping_reply_seq:     dw 0
ping_reply_ttl:     db 0
ping_start_tick:    dq 0
ping_target_ip:     times 4 db 0

; Buffers
align 16
ipv4_tx_buf:        times 1600 db 0
align 16
icmp_tx_buf:        times 128 db 0

; Messages
MSG_PING_HEADER:    db "PING ", 0
MSG_PING_BYTES:     db " (56 data bytes):", 0x0A, 0
MSG_PING_REPLY:     db "64 bytes from ", 0
MSG_PING_SEQ:       db ": icmp_seq=", 0
MSG_PING_TTL:       db " ttl=", 0
MSG_PING_TIME:      db " time=", 0
MSG_PING_MS:        db " ms", 0x0A, 0
MSG_PING_TIMEOUT:   db "Request timed out.", 0x0A, 0

; ------------------------------------------------------------------------------
; net_checksum: Computes standard 16-bit 1's complement Internet Checksum
; Input:  RSI = Pointer to buffer, RCX = Length in bytes
; Output: AX  = 16-bit checksum
; ------------------------------------------------------------------------------
net_checksum:
    push rbx
    push rcx
    push rsi

    xor eax, eax                ; EAX = 32-bit accumulator
    shr rcx, 1                  ; Convert bytes to 16-bit word count
    jz .check_odd

.word_loop:
    movzx ebx, word [rsi]
    add eax, ebx
    add rsi, 2
    dec rcx
    jnz .word_loop

.check_odd:
    pop rsi
    push rsi
    pop rcx
    push rcx
    test cl, 1
    jz .fold

    ; Add final odd byte (padded with zero in low or high byte)
    sub rsp, 8
    pop rsi
    push rsi
    push rsi
    ; Odd byte at end
    movzx ebx, byte [rsi + rcx - 1]
    add eax, ebx

.fold:
    ; Fold 32-bit sum into 16 bits
    mov edx, eax
    shr edx, 16
    and eax, 0xFFFF
    add eax, edx

    mov edx, eax
    shr edx, 16
    add eax, edx

    not ax                      ; 1's complement

    pop rsi
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; ipv4_send_packet: Encapsulates transport payload into IPv4 packet & transmits
; Input:
;   RSI = Pointer to transport layer payload (ICMP, TCP, UDP)
;   RCX = Payload length in bytes
;   RDI = Pointer to 4-byte Destination IPv4 address
;   DL  = Protocol number (1=ICMP, 6=TCP, 17=UDP)
; ------------------------------------------------------------------------------
ipv4_send_packet:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    mov r8, rcx                 ; R8 = Payload length
    mov r9, rsi                 ; R9 = Payload pointer
    mov r10b, dl                ; R10B = Protocol
    mov r11, rdi                ; R11 = Destination IP pointer

    ; 1. Build 20-byte IPv4 Header at ipv4_tx_buf
    lea rax, [ipv4_tx_buf]

    ; Version (4) + IHL (5) = 0x45
    mov byte [rax + 0], 0x45
    ; Type of Service = 0x00
    mov byte [rax + 1], 0x00

    ; Total Length (20 + payload_len) in Big Endian
    mov ebx, r8d
    add ebx, 20
    mov byte [rax + 2], bh
    mov byte [rax + 3], bl

    ; Packet Identification
    mov bx, [ipv4_packet_id]
    inc word [ipv4_packet_id]
    mov byte [rax + 4], bh
    mov byte [rax + 5], bl

    ; Flags & Fragment Offset = 0x4000 (Don't Fragment)
    mov byte [rax + 6], 0x40
    mov byte [rax + 7], 0x00

    ; Time to Live (TTL) = 64
    mov byte [rax + 8], 64

    ; Protocol
    mov byte [rax + 9], r10b

    ; Checksum = 0x0000 initially
    mov word [rax + 10], 0

    ; Source IP (4 bytes from net_ip)
    mov ebx, [net_ip]
    mov [rax + 12], ebx

    ; Destination IP (4 bytes from [R11])
    mov ebx, [r11]
    mov [rax + 16], ebx

    ; Compute IPv4 Header Checksum
    lea rsi, [ipv4_tx_buf]
    mov rcx, 20
    call net_checksum
    mov [ipv4_tx_buf + 10], ax  ; Write computed checksum into header

    ; 2. Copy payload to ipv4_tx_buf + 20
    lea rdi, [ipv4_tx_buf + 20]
    mov rsi, r9
    mov rcx, r8
    rep movsb

    ; 3. Resolve Destination MAC via ARP
    mov rsi, r11
    lea rdi, [resolved_dst_mac]
    call arp_resolve

    ; 4. Send Ethernet Frame (Length = 20 + payload_len, EtherType = 0x0800)
    lea rsi, [ipv4_tx_buf]
    mov rcx, r8
    add rcx, 20
    lea rdi, [resolved_dst_mac]
    mov dx, ETHERTYPE_IPV4
    call eth_send_frame

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; ipv4_handle_packet: Decodes incoming IPv4 packet from Ethernet layer
; Input:
;   RSI = Pointer to IPv4 packet
;   RCX = Packet length
; ------------------------------------------------------------------------------
ipv4_handle_packet:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    cmp rcx, 20
    jb .drop

    ; Check Version == 4 (high nibble of byte 0)
    mov al, [rsi]
    shr al, 4
    cmp al, 4
    jne .drop

    ; Calculate IHL (low nibble * 4)
    movzx ebx, byte [rsi]
    and ebx, 0x0F
    shl ebx, 2                  ; EBX = header length in bytes
    cmp ebx, 20
    jb .drop

    ; Extract Total Length (Big Endian)
    movzx eax, byte [rsi + 2]
    shl eax, 8
    mov al, [rsi + 3]
    cmp rcx, rax
    jb .drop                    ; Truncated packet

    ; Payload Length = Total Length - IHL
    sub eax, ebx
    mov r8d, eax                ; R8D = Payload length

    ; Extract Protocol (byte 9)
    movzx edx, byte [rsi + 9]

    ; Extract Source IP (RSI + 12) and Dest IP (RSI + 16)
    lea rdi, [rsi + 12]         ; RDI = Pointer to Source IP

    ; Save TTL (byte 8)
    mov al, [rsi + 8]
    mov [ping_reply_ttl], al

    ; Advance RSI to payload (RSI + IHL)
    add rsi, rbx
    mov rcx, r8                 ; RCX = Payload length

    ; Dispatch based on Protocol
    cmp dl, IPV4_PROTO_ICMP
    je .handle_icmp

    cmp dl, IPV4_PROTO_UDP
    je .handle_udp

    cmp dl, IPV4_PROTO_TCP
    je .handle_tcp

    jmp .drop

.handle_icmp:
    mov rdx, rdi                ; RDX = Source IP pointer
    call icmp_handle_packet
    jmp .drop

.handle_udp:
    mov rdx, rdi                ; RDX = Source IP pointer
    call udp_handle_packet
    jmp .drop

.handle_tcp:
    mov rdx, rdi                ; RDX = Source IP pointer
    call tcp_handle_packet

.drop:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; icmp_handle_packet: Processes incoming ICMP packets (Echo Request / Echo Reply)
; Input:
;   RSI = Pointer to ICMP header & payload
;   RCX = ICMP length
;   RDX = Pointer to 4-byte Source IPv4 address
; ------------------------------------------------------------------------------
icmp_handle_packet:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    cmp rcx, 8
    jb .done

    mov al, [rsi + 0]           ; Type
    mov bl, [rsi + 1]           ; Code

    ; Check for ICMP Echo Request (Type 8, Code 0)
    cmp al, ICMP_ECHO_REQUEST
    je .reply_echo

    ; Check for ICMP Echo Reply (Type 0, Code 0)
    cmp al, ICMP_ECHO_REPLY
    je .record_reply

    jmp .done

.reply_echo:
    ; Build Echo Reply: exactly copy packet, change Type to 0, recompute checksum
    lea rdi, [icmp_tx_buf]
    push rcx
    push rsi
    rep movsb
    pop rsi
    pop rcx

    ; Type = 0 (Echo Reply)
    mov byte [icmp_tx_buf + 0], ICMP_ECHO_REPLY
    ; Zero out checksum before calculation
    mov word [icmp_tx_buf + 2], 0

    ; Calculate new ICMP Checksum
    push rsi
    push rcx
    push rdx
    lea rsi, [icmp_tx_buf]
    call net_checksum
    mov [icmp_tx_buf + 2], ax
    pop rdx
    pop rcx
    pop rsi

    ; Send back via IPv4
    lea rsi, [icmp_tx_buf]
    mov rdi, rdx                ; Dst IP = original Source IP
    mov dl, IPV4_PROTO_ICMP
    call ipv4_send_packet
    jmp .done

.record_reply:
    ; Extract sequence number (offset 6, Big Endian)
    movzx eax, byte [rsi + 6]
    shl eax, 8
    mov al, [rsi + 7]
    mov [ping_reply_seq], ax
    mov byte [ping_reply_rx], 1

.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_print_ip: Formats and prints a 4-byte IPv4 address (e.g. 10.0.2.15)
; Input: RSI = Pointer to 4-byte IP address
; ------------------------------------------------------------------------------
vga_print_ip:
    push rax
    push rcx
    push rsi

    xor ecx, ecx
.loop:
    movzx eax, byte [rsi + rcx]
    call vga_print_dec
    cmp ecx, 3
    je .done
    mov al, '.'
    call vga_print_char
    inc ecx
    jmp .loop

.done:
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; icmp_ping: Sends ICMP Echo Request to target IP and displays RTT response
; Input: RSI = Pointer to 4-byte Target IPv4 address
; ------------------------------------------------------------------------------
icmp_ping:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov eax, [rsi]
    mov [ping_target_ip], eax

    ; Print Header: "PING 10.0.2.2 (56 data bytes):"
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [MSG_PING_HEADER]
    call vga_print_string_color

    lea rsi, [ping_target_ip]
    call vga_print_ip

    lea rsi, [MSG_PING_BYTES]
    call vga_print_string_color

    ; Send 4 ping probes
    mov r12d, 1                 ; Sequence number (1 .. 4)

.ping_probe:
    mov byte [ping_reply_rx], 0

    ; Build ICMP Echo Request (Type 8, Code 0, ID 0x1234, Seq r12w, 32 bytes payload)
    lea rdi, [icmp_tx_buf]
    mov byte [rdi + 0], ICMP_ECHO_REQUEST
    mov byte [rdi + 1], 0       ; Code 0
    mov word [rdi + 2], 0       ; Checksum = 0
    mov word [rdi + 4], 0x3412  ; Identifier
    ; Sequence in Big Endian
    mov byte [rdi + 6], 0
    mov byte [rdi + 7], r12b

    ; 32-byte test payload
    mov eax, 0x41424344         ; "ABCD"
    mov [rdi + 8], eax
    mov [rdi + 12], eax
    mov [rdi + 16], eax
    mov [rdi + 20], eax
    mov [rdi + 24], eax
    mov [rdi + 28], eax
    mov [rdi + 32], eax
    mov [rdi + 36], eax

    ; Compute Checksum over 40 bytes (8 header + 32 payload)
    lea rsi, [icmp_tx_buf]
    mov rcx, 40
    call net_checksum
    mov [icmp_tx_buf + 2], ax

    ; Record start ticks
    mov rax, [timer_ticks]
    mov [ping_start_tick], rax

    ; Send packet via IPv4
    lea rsi, [icmp_tx_buf]
    mov rcx, 40
    lea rdi, [ping_target_ip]
    mov dl, IPV4_PROTO_ICMP
    call ipv4_send_packet

    ; Poll for reply (up to ~1000 ms timeout)
    mov rax, [timer_ticks]
    add rax, 20                 ; 20 ticks (~1 sec)
    mov r13, rax
.wait_reply:
    call net_poll
    cmp byte [ping_reply_rx], 1
    je .got_reply

    ; Micro-delay
    mov ecx, 2000
.spin:
    pause
    dec ecx
    jnz .spin

    cmp [timer_ticks], r13
    jb .wait_reply

    ; Timeout!
    mov bl, COLOR_LIGHT_RED
    lea rsi, [MSG_PING_TIMEOUT]
    call vga_print_string_color
    jmp .next_probe

.got_reply:
    ; Print: "64 bytes from 10.0.2.2: icmp_seq=1 ttl=64 time=X ms"
    lea rsi, [MSG_PING_REPLY]
    call vga_print_string

    lea rsi, [ping_target_ip]
    call vga_print_ip

    lea rsi, [MSG_PING_SEQ]
    call vga_print_string
    movzx eax, word [ping_reply_seq]
    call vga_print_dec

    lea rsi, [MSG_PING_TTL]
    call vga_print_string
    movzx eax, byte [ping_reply_ttl]
    call vga_print_dec

    lea rsi, [MSG_PING_TIME]
    call vga_print_string

    ; Compute elapsed time (approx ms based on timer ticks)
    mov rax, [timer_ticks]
    sub rax, [ping_start_tick]
    ; If < 1, display 1 ms
    cmp eax, 1
    jae .show_ms
    mov eax, 1
.show_ms:
    call vga_print_dec

    lea rsi, [MSG_PING_MS]
    call vga_print_string

.next_probe:
    inc r12d
    cmp r12d, 4
    jbe .ping_probe

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; net_parse_ip: Parses dotted-decimal IPv4 string (e.g. "10.0.2.15") into 4 bytes
; Input:
;   RSI = Pointer to null-terminated or space-terminated ASCII string
;   RDI = Pointer to 4-byte buffer to receive IP address
; Output:
;   RAX = 0 on Success, 1 on Error (invalid format or octet > 255)
;   RSI = Advanced past parsed IP string
; ------------------------------------------------------------------------------
net_parse_ip:
    push rbx
    push rcx
    push rdx
    push r8

    mov r8, rdi                 ; R8 = output destination
    xor ecx, ecx                ; ECX = octet counter (0 .. 3)

.octet_loop:
    xor edx, edx                ; EDX = octet accumulator
    xor ebx, ebx                ; EBX = digit count for this octet

.digit_loop:
    mov al, [rsi]
    cmp al, '0'
    jb .digit_done
    cmp al, '9'
    ja .digit_done

    ; Digit found
    sub al, '0'
    movzx eax, al
    imul edx, 10
    add edx, eax
    cmp edx, 255
    ja .error                   ; Octet overflow (> 255)

    inc rsi
    inc ebx
    jmp .digit_loop

.digit_done:
    ; Must have parsed at least 1 digit
    test ebx, ebx
    jz .error

    ; Save octet byte
    mov [r8 + rcx], dl
    inc ecx
    cmp ecx, 4
    je .done_check

    ; Expect '.' delimiter
    cmp byte [rsi], '.'
    jne .error
    inc rsi                     ; Skip '.'
    jmp .octet_loop

.done_check:
    xor rax, rax                ; Success
    jmp .exit

.error:
    mov rax, 1

.exit:
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

