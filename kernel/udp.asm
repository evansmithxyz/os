; ==============================================================================
; Antigravity OS - 64-bit User Datagram Protocol (UDP) & DNS Resolver Engine
; RFC 768 UDP Transport & RFC 1035 Domain Name System (DNS) Client
; ==============================================================================

[bits 64]

UDP_PORT_DNS        equ 53
UDP_SRC_PORT_DNS    equ 53530

; State Variables
dns_query_id:       dw 0x4242
dns_resolved_flag:  db 0
dns_resolved_ip:    times 4 db 0

; Buffers
align 16
udp_tx_buf:         times 1500 db 0
align 16
dns_query_buf:      times 512 db 0

; Strings & Messages
MSG_DNS_RESOLVING:  db "Resolving ", 0
MSG_DNS_VIA:        db " via DNS server ", 0
MSG_DNS_DOTS:       db "... ", 0
MSG_DNS_SUCCESS:    db "OK", 0x0A, "  Address: ", 0
MSG_DNS_TIMEOUT:    db "TIMEOUT", 0x0A, "[DNS] Error: Name resolution timed out.", 0x0A, 0
MSG_DNS_NOT_FOUND:  db "FAILED", 0x0A, "[DNS] Error: Host not found (NXDOMAIN).", 0x0A, 0

; ------------------------------------------------------------------------------
; udp_send_packet: Encapsulates UDP payload and transmits via IPv4
; Input:
;   RSI = Pointer to UDP payload
;   RCX = Payload length in bytes
;   RDI = Pointer to 4-byte Destination IPv4 address
;   DX  = Source Port (Host Order, 16-bit)
;   R8W = Destination Port (Host Order, 16-bit)
; Output:
;   RAX = 0 on success, 1 on error
; ------------------------------------------------------------------------------
udp_send_packet:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    mov r9, rsi                 ; R9 = Payload pointer
    mov r10, rcx                ; R10 = Payload length
    mov r11, rdi                ; R11 = Destination IP pointer

    ; Build 8-byte UDP Header at udp_tx_buf
    lea rax, [udp_tx_buf]

    ; 1. Source Port (Big Endian)
    mov byte [rax + 0], dh
    mov byte [rax + 1], dl

    ; 2. Destination Port (Big Endian)
    mov bx, r8w
    mov byte [rax + 2], bh
    mov byte [rax + 3], bl

    ; 3. Length = 8 + payload length (Big Endian)
    mov bx, r10w
    add bx, 8
    mov byte [rax + 4], bh
    mov byte [rax + 5], bl

    ; 4. Checksum = 0x0000 (Optional in IPv4 UDP)
    mov word [rax + 6], 0

    ; 5. Copy payload to udp_tx_buf + 8
    lea rdi, [udp_tx_buf + 8]
    mov rsi, r9
    mov rcx, r10
    rep movsb

    ; 6. Send via IPv4 Layer
    ; Total UDP packet length = 8 + payload length
    mov rcx, r10
    add rcx, 8
    lea rsi, [udp_tx_buf]
    mov rdi, r11                ; Destination IP
    mov dl, IPV4_PROTO_UDP      ; Protocol 17
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
; udp_handle_packet: Processes incoming UDP packet from IPv4 layer
; Input:
;   RSI = Pointer to UDP packet (header + payload)
;   RCX = Packet length
;   RDX = Pointer to 4-byte Source IPv4 address
; ------------------------------------------------------------------------------
udp_handle_packet:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; Minimum UDP header size is 8 bytes
    cmp rcx, 8
    jb .done

    ; Extract Source Port (Big Endian -> Host Order)
    movzx eax, byte [rsi + 0]
    shl eax, 8
    mov al, [rsi + 1]

    ; Extract Destination Port (Big Endian -> Host Order)
    movzx ebx, byte [rsi + 2]
    shl ebx, 8
    mov bl, [rsi + 3]

    ; Check if this is a DNS response destined for our query port (53530)
    ; or originating from DNS server port 53
    cmp ebx, UDP_SRC_PORT_DNS
    je .handle_dns
    cmp eax, UDP_PORT_DNS
    je .handle_dns

    jmp .done

.handle_dns:
    ; Advance RSI to DNS payload (skip 8-byte UDP header)
    add rsi, 8
    sub rcx, 8
    call dns_handle_response

.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; dns_encode_qname: Encodes ASCII domain (e.g. "google.com") into DNS QNAME format
; Input:
;   RSI = Pointer to null-terminated domain string
;   RDI = Destination buffer
; Output:
;   RDI = Advanced past terminating zero byte
;   RAX = Number of bytes written
; ------------------------------------------------------------------------------
dns_encode_qname:
    push rbx
    push rcx
    push rdx
    push rsi

    mov r8, rdi                 ; R8 = Start of output
    xor edx, edx                ; EDX = Bytes written

.new_label:
    mov r9, rdi                 ; R9 = Pointer to label length byte
    inc rdi                     ; Reserve byte for length
    inc edx
    xor ecx, ecx                ; ECX = Label character count

.char_loop:
    lodsb                       ; AL = [RSI++]
    test al, al
    jz .end_of_domain
    cmp al, '.'
    je .end_of_label

    stosb                       ; Store char into [RDI++]
    inc edx
    inc ecx
    jmp .char_loop

.end_of_label:
    ; Write label length into length slot
    mov [r9], cl
    jmp .new_label

.end_of_domain:
    ; Write last label length
    mov [r9], cl
    ; Write terminating zero byte
    xor al, al
    stosb
    inc edx

    mov eax, edx                ; RAX = Total bytes written
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; dns_resolve: Resolves a domain name to an IPv4 address via DNS over UDP
; Input:
;   RSI = Pointer to null-terminated domain name (e.g. "google.com")
;   RDI = Pointer to 4-byte buffer to store resolved IPv4 address
; Output:
;   RAX = 0 on Success, 1 on Timeout / Failure
;   [RDI] = 4-byte resolved IP address
; ------------------------------------------------------------------------------
dns_resolve:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14

    mov r12, rsi                ; R12 = Domain string
    mov r13, rdi                ; R13 = Output IP buffer

    ; Reset resolved state
    mov byte [dns_resolved_flag], 0
    mov dword [dns_resolved_ip], 0

    ; Increment query ID
    inc word [dns_query_id]

    ; 1. Build DNS Query Header in dns_query_buf (12 bytes)
    lea rax, [dns_query_buf]

    ; Transaction ID (Big Endian)
    mov bx, [dns_query_id]
    mov byte [rax + 0], bh
    mov byte [rax + 1], bl

    ; Flags = 0x0100 (Standard Query, Recursion Desired)
    mov byte [rax + 2], 0x01
    mov byte [rax + 3], 0x00

    ; QDCOUNT = 1 (1 Question)
    mov byte [rax + 4], 0x00
    mov byte [rax + 5], 0x01

    ; ANCOUNT = 0
    mov byte [rax + 6], 0x00
    mov byte [rax + 7], 0x00

    ; NSCOUNT = 0
    mov byte [rax + 8], 0x00
    mov byte [rax + 9], 0x00

    ; ARCOUNT = 0
    mov byte [rax + 10], 0x00
    mov byte [rax + 11], 0x00

    ; 2. Build Question Section: QNAME
    lea rdi, [dns_query_buf + 12]
    mov rsi, r12
    call dns_encode_qname       ; Encodes domain, returns RAX = length, RDI advanced

    ; Append QTYPE = 0x0001 (Type A: IPv4 Address)
    mov byte [rdi + 0], 0x00
    mov byte [rdi + 1], 0x01

    ; Append QCLASS = 0x0001 (Class IN: Internet)
    mov byte [rdi + 2], 0x00
    mov byte [rdi + 3], 0x01
    add rdi, 4

    ; Calculate total DNS query length: RDI - dns_query_buf
    lea rbx, [dns_query_buf]
    sub rdi, rbx
    mov rcx, rdi                ; RCX = Query length

    ; 3. Send DNS Query via UDP to net_dns (10.0.2.3) on port 53
    lea rsi, [dns_query_buf]
    lea rdi, [net_dns]
    mov dx, UDP_SRC_PORT_DNS    ; Source port 53530
    mov r8w, UDP_PORT_DNS       ; Destination port 53
    call udp_send_packet

    ; 4. Poll for response with timeout (~2.5 sec = 45 ticks)
    mov rax, [timer_ticks]
    add rax, 45
    mov r14, rax
.poll_loop:
    call net_poll

    cmp byte [dns_resolved_flag], 1
    je .success

    ; Tiny spin delay
    mov ecx, 2000
.spin:
    pause
    dec ecx
    jnz .spin

    mov rax, [timer_ticks]
    cmp rax, r14
    jb .poll_loop

    ; Timeout!
    mov rax, 1
    jmp .exit

.success:
    ; Copy resolved IP (4 bytes) to user buffer at [R13]
    mov eax, [dns_resolved_ip]
    mov [r13], eax
    xor rax, rax                ; Success = 0

.exit:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; dns_handle_response: Decodes incoming DNS response packet
; Input:
;   RSI = Pointer to DNS response payload
;   RCX = Length of DNS response
; ------------------------------------------------------------------------------
dns_handle_response:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10

    ; DNS header is at least 12 bytes
    cmp rcx, 12
    jb .drop

    ; Check Transaction ID
    mov al, [rsi + 0]
    mov ah, [rsi + 1]
    xchg al, ah
    cmp ax, [dns_query_id]
    jne .drop

    ; Check QR bit (Bit 15 must be 1 = Response)
    test byte [rsi + 2], 0x80
    jz .drop

    ; Check RCODE (Bits 3-0 of byte 3 must be 0 = No Error)
    mov al, [rsi + 3]
    and al, 0x0F
    jnz .drop                   ; Error (NXDOMAIN, ServFail, etc.)

    ; Extract Answer Count ANCOUNT (bytes 6-7, Big Endian)
    movzx r10d, byte [rsi + 6]
    shl r10d, 8
    mov r10b, [rsi + 7]
    test r10d, r10d
    jz .drop                    ; 0 answers

    ; Advance past 12-byte header
    add rsi, 12
    sub rcx, 12

    ; Skip Question Section: QNAME
.skip_qname:
    cmp rcx, 1
    jb .drop
    movzx eax, byte [rsi]
    test al, al
    jz .end_qname
    ; Check if compressed pointer (high 2 bits = 11)
    cmp al, 0xC0
    jae .skip_ptr

    ; Normal label: advance by (len + 1)
    inc eax
    cmp rcx, rax
    jb .drop
    add rsi, rax
    sub rcx, rax
    jmp .skip_qname

.skip_ptr:
    cmp rcx, 2
    jb .drop
    add rsi, 2
    sub rcx, 2
    jmp .skip_qtype

.end_qname:
    inc rsi
    dec rcx

.skip_qtype:
    ; Skip QTYPE (2 bytes) + QCLASS (2 bytes) = 4 bytes
    cmp rcx, 4
    jb .drop
    add rsi, 4
    sub rcx, 4

    ; Parse Answer Section (up to R10 answers)
.parse_answers:
    test r10d, r10d
    jz .drop

    ; Parse Name (compressed pointer or label sequence)
    cmp rcx, 2
    jb .drop
    mov al, [rsi]
    cmp al, 0xC0
    jae .ans_ptr

    ; Label sequence
.ans_label:
    movzx eax, byte [rsi]
    test al, al
    jz .ans_label_end
    inc eax
    cmp rcx, rax
    jb .drop
    add rsi, rax
    sub rcx, rax
    jmp .ans_label

.ans_label_end:
    inc rsi
    dec rcx
    jmp .check_rr

.ans_ptr:
    add rsi, 2
    sub rcx, 2

.check_rr:
    ; Standard Resource Record Header:
    ; TYPE (2 bytes) + CLASS (2 bytes) + TTL (4 bytes) + RDLENGTH (2 bytes) = 10 bytes
    cmp rcx, 10
    jb .drop

    ; Read TYPE (Big Endian)
    movzx eax, byte [rsi + 0]
    shl eax, 8
    mov al, [rsi + 1]

    ; Read RDLENGTH (Big Endian)
    movzx r9d, byte [rsi + 8]
    shl r9d, 8
    mov r9b, [rsi + 9]

    ; Advance past RR header (10 bytes)
    add rsi, 10
    sub rcx, 10

    ; Check if TYPE == 1 (Type A: IPv4) and RDLENGTH == 4
    cmp ax, 1
    jne .skip_rdata

    cmp r9d, 4
    jne .skip_rdata

    ; Found IPv4 Address! Copy 4 bytes into dns_resolved_ip
    cmp rcx, 4
    jb .drop
    mov eax, [rsi]
    mov [dns_resolved_ip], eax
    mov byte [dns_resolved_flag], 1
    jmp .drop                   ; Successfully captured!

.skip_rdata:
    ; Skip RDATA of length R9D
    cmp rcx, r9
    jb .drop
    add rsi, r9
    sub rcx, r9
    dec r10d
    jmp .parse_answers

.drop:
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
