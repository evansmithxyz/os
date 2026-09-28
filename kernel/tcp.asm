; ==============================================================================
; Antigravity OS - 64-bit Transmission Control Protocol (TCP) Engine
; RFC 793 Transmission Control Protocol, HTTP Client & Bare-Metal Web Server
; ==============================================================================

[bits 64]

; TCP Header Flags
TCP_FLAG_FIN        equ 0x01
TCP_FLAG_SYN        equ 0x02
TCP_FLAG_RST        equ 0x04
TCP_FLAG_PSH        equ 0x08
TCP_FLAG_ACK        equ 0x10
TCP_FLAG_URG        equ 0x20

; TCP Connection States
TCP_STATE_CLOSED        equ 0
TCP_STATE_LISTEN        equ 1
TCP_STATE_SYN_SENT      equ 2
TCP_STATE_SYN_RCVD      equ 3
TCP_STATE_ESTABLISHED   equ 4
TCP_STATE_FIN_WAIT_1    equ 5
TCP_STATE_FIN_WAIT_2    equ 6
TCP_STATE_CLOSE_WAIT    equ 7
TCP_STATE_LAST_ACK      equ 8
TCP_STATE_TIME_WAIT     equ 9

; State Variables
tcp_active_state:       db TCP_STATE_CLOSED
tcp_is_server:          db 0
tcp_local_port:         dw 0
tcp_remote_port:        dw 0
tcp_remote_ip:          dd 0

; Sequence and Acknowledgment Numbers (Host Order)
tcp_my_seq:             dd 0
tcp_my_ack:             dd 0

; Flags for Event Notification
tcp_data_rx_flag:       db 0
tcp_data_rx_len:        dw 0
tcp_fin_received:       db 0
tcp_reset_received:     db 0
tcp_connection_closed:  db 0

; Buffers
align 16
; Buffer layout: [0..11] Pseudo-header, [12..31] TCP header, [32..] Payload
tcp_tx_packet:          times 2048 db 0
tcp_rx_buf              equ 0x00022000          ; 4096 bytes TCP RX buffer in RAM
align 16
http_req_buf:           times 512 db 0

; Server HTTP Response Content
HTTP_SERVER_RESP:
    db "HTTP/1.0 200 OK", 0x0D, 0x0A
    db "Server: AntigravityOS-x86_64", 0x0D, 0x0A
    db "Content-Type: text/html; charset=utf-8", 0x0D, 0x0A
    db "Connection: close", 0x0D, 0x0A, 0x0D, 0x0A
    db "<!DOCTYPE html>", 0x0A
    db "<html><head><title>Antigravity OS Web Server</title>", 0x0A
    db "<style>", 0x0A
    db "body { background: #0a0e17; color: #00ffcc; font-family: monospace; padding: 40px; }", 0x0A
    db "h1 { color: #38bdf8; text-shadow: 0 0 10px rgba(56,189,248,0.5); }", 0x0A
    db ".card { background: #131d2e; border: 1px solid #1e293b; border-radius: 8px; padding: 20px; margin: 20px 0; }", 0x0A
    db ".badge { background: #0284c7; color: #fff; padding: 3px 8px; border-radius: 4px; font-weight: bold; }", 0x0A
    db "li { margin: 8px 0; }", 0x0A
    db "</style></head><body>", 0x0A
    db "<h1>=== Antigravity OS ===</h1>", 0x0A
    db "<p><span class='badge'>AMD64 / x86_64</span> Bare-Metal Long Mode Operating System</p>", 0x0A
    db "<div class='card'>", 0x0A
    db "<h3>Network Subsystem Status</h3>", 0x0A
    db "<ul>", 0x0A
    db "<li><b>NIC:</b> Realtek RTL8139 Fast Ethernet PCI (BAR0 0xC000)</li>", 0x0A
    db "<li><b>IP Address:</b> 10.0.2.15 (QEMU SLIRP)</li>", 0x0A
    db "<li><b>Gateway:</b> 10.0.2.2</li>", 0x0A
    db "<li><b>Stack:</b> Pure x86_64 NASM (Ethernet, ARP, IPv4, ICMP, UDP, TCP, HTTP)</li>", 0x0A
    db "</ul>", 0x0A
    db "</div>", 0x0A
    db "<p><i>Served directly from pure x86_64 assembly running on bare metal!</i></p>", 0x0A
    db "</body></html>", 0x0A, 0
HTTP_SERVER_RESP_LEN equ ($ - HTTP_SERVER_RESP - 1)

; Messages
MSG_TCP_CONNECTING: db "Connecting to ", 0
MSG_TCP_PORT_STR:   db " on port ", 0
MSG_TCP_CONNECTED:  db " [CONNECTED]", 0x0A, 0
MSG_TCP_TIMEOUT:    db "[ERROR] Connection timed out.", 0x0A, 0
MSG_TCP_SENDING:    db "Sending HTTP GET request...", 0x0A, 0
MSG_TCP_CLOSED:     db 0x0A, "[TCP] Connection closed by remote host.", 0x0A, 0
MSG_TCP_SERVER_ON:  db "=== Antigravity OS Bare-Metal HTTP Web Server ===", 0x0A
                    db "[TCP] Listening on port 80 (accessible from host at http://localhost:8888)", 0x0A
                    db "[TCP] Press 'q' or Esc to stop server.", 0x0A, 0x0A, 0
MSG_TCP_INCOMING:   db "[TCP] Incoming connection from ", 0
MSG_TCP_SERVED:     db "[HTTP] Webpage served successfully. Ready for next request.", 0x0A, 0
MSG_TCP_STOPPED:    db 0x0A, "[TCP] Web server stopped.", 0x0A, 0

; ------------------------------------------------------------------------------
; tcp_send_segment: Builds TCP segment with pseudo-header checksum & transmits
; Input:
;   RSI = Pointer to payload data (or 0 if no payload)
;   RCX = Payload length in bytes
;   AL  = TCP Flags (e.g. TCP_FLAG_SYN, TCP_FLAG_ACK, TCP_FLAG_PSH, TCP_FLAG_FIN)
; ------------------------------------------------------------------------------
tcp_send_segment:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    mov r10, rcx                ; R10 = Payload length
    mov r11, rsi                ; R11 = Payload pointer
    mov r8b, al                 ; R8B = Flags

    ; 1. Build 12-byte IPv4 Pseudo-Header at tcp_tx_packet + 0
    lea rax, [tcp_tx_packet]

    ; Source IP (4 bytes from net_ip)
    mov ebx, [net_ip]
    mov [rax + 0], ebx

    ; Destination IP (4 bytes from tcp_remote_ip)
    mov ebx, [tcp_remote_ip]
    mov [rax + 4], ebx

    ; Reserved (0x00)
    mov byte [rax + 8], 0

    ; Protocol (6 = TCP)
    mov byte [rax + 9], IPV4_PROTO_TCP

    ; TCP Length = 20 + payload_length (Big Endian)
    mov bx, r10w
    add bx, 20
    mov byte [rax + 10], bh
    mov byte [rax + 11], bl

    ; 2. Build 20-byte TCP Header at tcp_tx_packet + 12
    ; Source Port (Big Endian)
    mov bx, [tcp_local_port]
    mov byte [rax + 12], bh
    mov byte [rax + 13], bl

    ; Destination Port (Big Endian)
    mov bx, [tcp_remote_port]
    mov byte [rax + 14], bh
    mov byte [rax + 15], bl

    ; Sequence Number (Host Order -> Big Endian)
    mov ebx, [tcp_my_seq]
    bswap ebx
    mov [rax + 16], ebx

    ; Acknowledgment Number (Host Order -> Big Endian)
    mov ebx, [tcp_my_ack]
    bswap ebx
    mov [rax + 20], ebx

    ; Data Offset (5 = 20 bytes -> 0x50) + Reserved (0)
    mov byte [rax + 24], 0x50

    ; TCP Flags
    mov byte [rax + 25], r8b

    ; Window Size = 16384 (0x4000 in Big Endian)
    mov byte [rax + 26], 0x40
    mov byte [rax + 27], 0x00

    ; Checksum = 0 initially
    mov word [rax + 28], 0

    ; Urgent Pointer = 0
    mov word [rax + 30], 0

    ; 3. Copy Payload to tcp_tx_packet + 32 (if length > 0)
    test r10, r10
    jz .no_payload
    test r11, r11
    jz .no_payload

    lea rdi, [tcp_tx_packet + 32]
    mov rsi, r11
    mov rcx, r10
    rep movsb

.no_payload:
    ; Calculate total length for checksum = 12 (pseudo) + 20 (tcp) + payload_len
    mov rcx, r10
    add rcx, 32

    ; Pad odd byte with zero for clean checksum calculation
    test rcx, 1
    jz .do_csum
    lea rdi, [tcp_tx_packet]
    mov byte [rdi + rcx], 0
    inc rcx

.do_csum:
    ; Calculate checksum over pseudo-header + TCP header + payload
    lea rsi, [tcp_tx_packet]
    call net_checksum

    ; If computed checksum is 0x0000, RFC specifies sending 0xFFFF
    test ax, ax
    jnz .store_csum
    mov ax, 0xFFFF

.store_csum:
    ; Write checksum into TCP Header (offset 12 + 16 = 28)
    mov [tcp_tx_packet + 28], ax

    ; 4. Transmit TCP Segment via IPv4 Layer
    ; Payload for IPv4 = TCP Header (20 bytes) + TCP Payload (r10 bytes)
    lea rsi, [tcp_tx_packet + 12]
    mov rcx, r10
    add rcx, 20
    lea rdi, [tcp_remote_ip]
    mov dl, IPV4_PROTO_TCP
    call ipv4_send_packet

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; tcp_handle_packet: Dispatches incoming TCP packet from IPv4 layer
; Input:
;   RSI = Pointer to TCP packet (Header + Payload)
;   RCX = Packet length
;   RDX = Pointer to 4-byte Source IPv4 address
; ------------------------------------------------------------------------------
tcp_handle_packet:
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
    push r12
    push r15

    mov r15, rdx                ; R15 = Source IP pointer

    ; TCP header is at least 20 bytes
    cmp rcx, 20
    jb .drop

    ; Extract Source Port (Big Endian -> Host Order)
    movzx eax, byte [rsi + 0]
    shl eax, 8
    mov al, [rsi + 1]
    mov r11w, ax                ; R11W = Source Port

    ; Extract Destination Port (Big Endian -> Host Order)
    movzx eax, byte [rsi + 2]
    shl eax, 8
    mov al, [rsi + 3]
    mov r12w, ax                ; R12W = Dest Port

    ; Extract Sequence Number (Big Endian -> Host Order)
    mov eax, [rsi + 4]
    bswap eax
    mov r9d, eax                ; R9D = Remote Seq

    ; Extract Acknowledgment Number (Big Endian -> Host Order)
    mov eax, [rsi + 8]
    bswap eax
    mov r10d, eax               ; R10D = Remote Ack

    ; Extract Data Offset (Header size)
    movzx ebx, byte [rsi + 12]
    shr ebx, 4
    shl ebx, 2                  ; EBX = TCP Header length in bytes
    cmp ebx, 20
    jb .drop

    ; Extract TCP Flags
    movzx r8d, byte [rsi + 13]  ; R8D = Flags

    ; Calculate Payload Length: Total length (RCX) - Header length (EBX)
    mov eax, ecx
    sub eax, ebx
    mov edx, eax                ; EDX = Payload length

    ; Check RST Flag
    test r8b, TCP_FLAG_RST
    jz .check_state
    mov byte [tcp_reset_received], 1
    mov byte [tcp_active_state], TCP_STATE_CLOSED
    jmp .drop

.check_state:
    ; --------------------------------------------------------------------------
    ; State 1: TCP_STATE_LISTEN (Server Mode)
    ; --------------------------------------------------------------------------
    cmp byte [tcp_active_state], TCP_STATE_LISTEN
    jne .state_syn_rcvd

    ; Must be destined for our listening port
    cmp r12w, [tcp_local_port]
    jne .drop

    ; Must be a SYN packet
    test r8b, TCP_FLAG_SYN
    jz .drop

    ; Record remote host info
    mov eax, [r15]
    mov [tcp_remote_ip], eax
    mov [tcp_remote_port], r11w

    ; Ack incoming SYN
    inc r9d                     ; Ack = Remote Seq + 1
    mov [tcp_my_ack], r9d

    ; Generate initial Sequence Number
    mov eax, 0x20000000
    add eax, [timer_ticks]
    mov [tcp_my_seq], eax

    ; Send SYN | ACK
    mov al, TCP_FLAG_SYN | TCP_FLAG_ACK
    xor rcx, rcx
    call tcp_send_segment

    ; Advance our Seq for SYN
    inc dword [tcp_my_seq]

    ; Move to SYN_RCVD
    mov byte [tcp_active_state], TCP_STATE_SYN_RCVD
    jmp .drop

.state_syn_rcvd:
    ; --------------------------------------------------------------------------
    ; State 2: TCP_STATE_SYN_RCVD (Server Handshake Completion)
    ; --------------------------------------------------------------------------
    cmp byte [tcp_active_state], TCP_STATE_SYN_RCVD
    jne .state_syn_sent

    ; Expect ACK matching our local port and remote port
    cmp r12w, [tcp_local_port]
    jne .drop
    cmp r11w, [tcp_remote_port]
    jne .drop

    test r8b, TCP_FLAG_ACK
    jz .drop

    ; Handshake Complete!
    mov byte [tcp_active_state], TCP_STATE_ESTABLISHED
    jmp .drop

.state_syn_sent:
    ; --------------------------------------------------------------------------
    ; State 3: TCP_STATE_SYN_SENT (Client Mode Handshake)
    ; --------------------------------------------------------------------------
    cmp byte [tcp_active_state], TCP_STATE_SYN_SENT
    jne .state_established

    ; Expect SYN | ACK
    test r8b, TCP_FLAG_SYN
    jz .drop
    test r8b, TCP_FLAG_ACK
    jz .drop

    ; Ack remote SYN
    inc r9d                     ; Ack = Remote Seq + 1
    mov [tcp_my_ack], r9d

    ; Advance our Seq for our original SYN
    inc dword [tcp_my_seq]

    ; Send ACK to complete 3-way handshake
    mov al, TCP_FLAG_ACK
    xor rcx, rcx
    call tcp_send_segment

    mov byte [tcp_active_state], TCP_STATE_ESTABLISHED
    jmp .drop

.state_established:
    ; --------------------------------------------------------------------------
    ; State 4: TCP_STATE_ESTABLISHED (Data Transfer)
    ; --------------------------------------------------------------------------
    cmp byte [tcp_active_state], TCP_STATE_ESTABLISHED
    jne .state_fin_wait

    ; Verify port match
    cmp r12w, [tcp_local_port]
    jne .drop
    cmp r11w, [tcp_remote_port]
    jne .drop

    ; 1. Handle incoming data payload
    test edx, edx
    jz .check_fin

    ; Copy incoming payload to tcp_rx_buf
    mov rdi, tcp_rx_buf
    push rsi
    add rsi, rbx                ; RSI = payload start (RSI + Header length)
    mov ecx, edx
    cmp ecx, 4000
    jbe .len_fit
    mov ecx, 4000
.len_fit:
    rep movsb
    mov byte [rdi], 0           ; Null-terminate string
    pop rsi

    mov [tcp_data_rx_len], dx
    mov byte [tcp_data_rx_flag], 1

    ; Advance ACK number by received payload length
    add [tcp_my_ack], edx

    ; Send ACK for received data
    mov al, TCP_FLAG_ACK
    xor rcx, rcx
    call tcp_send_segment

.check_fin:
    ; 2. Handle remote FIN flag
    test r8b, TCP_FLAG_FIN
    jz .drop

    ; Remote wishes to close
    inc dword [tcp_my_ack]
    mov byte [tcp_fin_received], 1

    ; Send FIN | ACK
    mov al, TCP_FLAG_FIN | TCP_FLAG_ACK
    xor rcx, rcx
    call tcp_send_segment

    inc dword [tcp_my_seq]
    mov byte [tcp_active_state], TCP_STATE_LAST_ACK
    jmp .drop

.state_fin_wait:
    ; --------------------------------------------------------------------------
    ; State 5 & 6: FIN_WAIT_1 / LAST_ACK (Closing)
    ; --------------------------------------------------------------------------
    cmp byte [tcp_active_state], TCP_STATE_LAST_ACK
    je .handle_last_ack
    cmp byte [tcp_active_state], TCP_STATE_FIN_WAIT_1
    jne .drop

    test r8b, TCP_FLAG_ACK
    jz .drop
    mov byte [tcp_active_state], TCP_STATE_CLOSED
    mov byte [tcp_connection_closed], 1
    jmp .drop

.handle_last_ack:
    test r8b, TCP_FLAG_ACK
    jz .drop
    mov byte [tcp_active_state], TCP_STATE_CLOSED
    mov byte [tcp_connection_closed], 1

.drop:
    pop r15
    pop r12
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
; tcp_http_client: Connects to target IP on port 80 and issues HTTP GET request
; Input:
;   RSI = Target IP (4 bytes)
;   RDI = Optional domain string for Host header (or target IP if null)
;   DX  = Destination Port (e.g. 80)
; Output:
;   RAX = 0 on Success, 1 on Error
; ------------------------------------------------------------------------------
tcp_http_client:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15

    mov r15, rdi                ; R15 = Hostname string pointer
    mov eax, [rsi]
    mov [tcp_remote_ip], eax
    mov [tcp_remote_port], dx

    ; Ephemeral local port: 49152 + (ticks & 0x0FFF)
    mov ax, [timer_ticks]
    and ax, 0x0FFF
    add ax, 49152
    mov [tcp_local_port], ax

    ; Initial Sequence Number
    mov eax, 0x10000000
    add eax, [timer_ticks]
    mov [tcp_my_seq], eax
    mov dword [tcp_my_ack], 0

    ; Reset flags
    mov byte [tcp_is_server], 0
    mov byte [tcp_data_rx_flag], 0
    mov byte [tcp_fin_received], 0
    mov byte [tcp_connection_closed], 0
    mov byte [tcp_active_state], TCP_STATE_SYN_SENT

    ; Print connecting banner
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [MSG_TCP_CONNECTING]
    call vga_print_string_color

    lea rsi, [tcp_remote_ip]
    call vga_print_ip

    lea rsi, [MSG_TCP_PORT_STR]
    call vga_print_string_color
    movzx eax, word [tcp_remote_port]
    call vga_print_dec

    ; Send SYN
    mov al, TCP_FLAG_SYN
    xor rcx, rcx
    call tcp_send_segment

    ; Wait for ESTABLISHED state with timeout (~3 seconds = 55 ticks)
    mov rax, [timer_ticks]
    add rax, 55
    mov r14, rax
.wait_connect:
    call net_poll
    cmp byte [tcp_active_state], TCP_STATE_ESTABLISHED
    je .connected

    mov ecx, 2000
.spin1:
    pause
    dec ecx
    jnz .spin1

    mov rax, [timer_ticks]
    cmp rax, r14
    jb .wait_connect

    ; Timeout!
    mov bl, COLOR_LIGHT_RED
    lea rsi, [MSG_TCP_TIMEOUT]
    call vga_print_string_color
    mov byte [tcp_active_state], TCP_STATE_CLOSED
    mov rax, 1
    jmp .exit_client

.connected:
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [MSG_TCP_CONNECTED]
    call vga_print_string_color

    ; Build HTTP GET Request at http_req_buf:
    ; "GET / HTTP/1.0\r\nHost: <domain or IP>\r\nUser-Agent: AntigravityOS/1.0 (x86_64)\r\nConnection: close\r\n\r\n"
    lea rdi, [http_req_buf]

    ; 1. Copy "GET / HTTP/1.0\r\nHost: "
    lea rsi, [.STR_GET_PREFIX]
.copy_prefix:
    lodsb
    test al, al
    jz .prefix_done
    stosb
    jmp .copy_prefix
.prefix_done:

    ; 2. Copy Hostname from R15 (if valid string) or IP
    test r15, r15
    jz .use_ip_host
    cmp byte [r15], 0
    je .use_ip_host

    mov rsi, r15
.copy_host:
    lodsb
    test al, al
    jz .host_done
    stosb
    jmp .copy_host

.use_ip_host:
    movzx eax, byte [tcp_remote_ip + 0]
    call .append_dec
    mov al, '.'
    stosb
    movzx eax, byte [tcp_remote_ip + 1]
    call .append_dec
    mov al, '.'
    stosb
    movzx eax, byte [tcp_remote_ip + 2]
    call .append_dec
    mov al, '.'
    stosb
    movzx eax, byte [tcp_remote_ip + 3]
    call .append_dec

.host_done:
    ; 3. Copy "\r\nUser-Agent: AntigravityOS/1.0 (x86_64)\r\nConnection: close\r\n\r\n"
    lea rsi, [.STR_GET_SUFFIX]
.copy_suffix:
    lodsb
    test al, al
    jz .suffix_done
    stosb
    jmp .copy_suffix
.suffix_done:

    ; Calculate request length
    lea rbx, [http_req_buf]
    sub rdi, rbx
    mov rcx, rdi                ; RCX = Request length

    ; Send HTTP Request with PSH | ACK
    lea rsi, [http_req_buf]
    mov al, TCP_FLAG_PSH | TCP_FLAG_ACK
    call tcp_send_segment

    ; Advance our Seq by sent bytes
    add [tcp_my_seq], ecx

    ; Loop receiving HTTP response chunks (~5 seconds = 90 ticks)
    mov rax, [timer_ticks]
    add rax, 90
    mov r14, rax
.rx_loop:
    call net_poll

    ; Did we receive data?
    cmp byte [tcp_data_rx_flag], 1
    jne .check_term

    ; Print received HTTP payload in Light Cyan
    mov bl, COLOR_LIGHT_CYAN
    mov rsi, tcp_rx_buf
    call vga_print_string_color
    mov byte [tcp_data_rx_flag], 0

.check_term:
    cmp byte [tcp_fin_received], 1
    je .done_transfer
    cmp byte [tcp_connection_closed], 1
    je .done_transfer
    cmp byte [tcp_active_state], TCP_STATE_CLOSED
    je .done_transfer

    mov ecx, 2000
.spin2:
    pause
    dec ecx
    jnz .spin2

    mov rax, [timer_ticks]
    cmp rax, r14
    jb .rx_loop

.done_transfer:
    mov bl, COLOR_LIGHT_GRAY
    lea rsi, [MSG_TCP_CLOSED]
    call vga_print_string_color
    xor rax, rax

.exit_client:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

.append_dec:
    push rbx
    push rcx
    push rdx
    mov ebx, 10
    xor ecx, ecx
.dec_div:
    xor edx, edx
    div ebx
    push rdx
    inc ecx
    test eax, eax
    jnz .dec_div
.dec_store:
    pop rax
    add al, '0'
    stosb
    dec ecx
    jnz .dec_store
    pop rdx
    pop rcx
    pop rbx
    ret

.STR_GET_PREFIX:
    db "GET / HTTP/1.0", 0x0D, 0x0A, "Host: ", 0
.STR_GET_SUFFIX:
    db 0x0D, 0x0A
    db "User-Agent: AntigravityOS/1.0 (x86_64)", 0x0D, 0x0A
    db "Connection: close", 0x0D, 0x0A, 0x0D, 0x0A, 0

; ------------------------------------------------------------------------------
; tcp_server_start: Runs interactive bare-metal HTTP web server on port 80
; Input:
;   DX = Listening port (e.g. 80)
; ------------------------------------------------------------------------------
tcp_server_start:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov [tcp_local_port], dx
    mov byte [tcp_is_server], 1
    mov byte [tcp_active_state], TCP_STATE_LISTEN

    ; Print Server Welcome Banner
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [MSG_TCP_SERVER_ON]
    call vga_print_string_color

.server_loop:
    ; Non-blocking check for keyboard input ('q' or Esc to stop)
    cmp qword [input_len], 0
    jz .service_net

    mov al, [input_buffer]
    cmp al, 'q'
    je .stop_server
    cmp al, 'Q'
    je .stop_server
    cmp al, 27                  ; Esc
    je .stop_server

    ; Clear input buffer for other keystrokes
    call keyboard_clear_buffer

.service_net:
    ; Service Network Packets
    call net_poll

    ; If connection is ESTABLISHED and incoming request arrived:
    cmp byte [tcp_active_state], TCP_STATE_ESTABLISHED
    jne .check_closed

    cmp byte [tcp_data_rx_flag], 1
    jne .check_closed

    ; Request received!
    mov byte [tcp_data_rx_flag], 0

    ; Print incoming request info
    mov bl, COLOR_YELLOW
    lea rsi, [MSG_TCP_INCOMING]
    call vga_print_string_color
    lea rsi, [tcp_remote_ip]
    call vga_print_ip
    mov al, ':'
    call vga_print_char
    movzx eax, word [tcp_remote_port]
    call vga_print_dec
    mov al, 0x0A
    call vga_print_char

    ; Send HTTP HTML Response
    lea rsi, [HTTP_SERVER_RESP]
    mov rcx, HTTP_SERVER_RESP_LEN
    mov al, TCP_FLAG_PSH | TCP_FLAG_ACK
    call tcp_send_segment
    add [tcp_my_seq], ecx

    ; Send FIN | ACK to close connection cleanly
    mov al, TCP_FLAG_FIN | TCP_FLAG_ACK
    xor rcx, rcx
    call tcp_send_segment
    inc dword [tcp_my_seq]

    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [MSG_TCP_SERVED]
    call vga_print_string_color

    ; Transition to FIN_WAIT_1
    mov byte [tcp_active_state], TCP_STATE_FIN_WAIT_1

.check_closed:
    ; Once connection is closed, reset back to LISTEN for next client!
    cmp byte [tcp_active_state], TCP_STATE_CLOSED
    jne .idle_pause

    mov byte [tcp_active_state], TCP_STATE_LISTEN
    mov byte [tcp_fin_received], 0
    mov byte [tcp_data_rx_flag], 0

.idle_pause:
    mov ecx, 2000
.spin:
    pause
    dec ecx
    jnz .spin
    jmp .server_loop

.stop_server:
    mov byte [tcp_active_state], TCP_STATE_CLOSED
    mov bl, COLOR_YELLOW
    lea rsi, [MSG_TCP_STOPPED]
    call vga_print_string_color

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
