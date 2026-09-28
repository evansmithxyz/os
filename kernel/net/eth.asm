; ==============================================================================
; Antigravity OS - 64-bit Ethernet II & Address Resolution Protocol (ARP) Engine
; Handles L2 Frame Encapsulation, Hardware Addressing, and Dynamic ARP Discovery
; ==============================================================================

[bits 64]

ETHERTYPE_IPV4      equ 0x0800
ETHERTYPE_ARP       equ 0x0806

ARP_OP_REQUEST      equ 1
ARP_OP_REPLY        equ 2

section .data
; Network Interface Configuration (QEMU SLIRP Defaults)
net_ip:             db 10, 0, 2, 15
net_gateway:        db 10, 0, 2, 2
net_netmask:        db 255, 255, 255, 0
net_dns:            db 10, 0, 2, 3

; Default Gateway MAC (Pre-seeded for QEMU SLIRP router: 52:54:00:12:34:02)
gateway_mac:        db 0x52, 0x54, 0x00, 0x12, 0x34, 0x02
broadcast_mac:      db 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF

; ARP Cache: 8 entries (4 bytes IP, 6 bytes MAC, 1 byte valid flag = 11 bytes each)
ARP_CACHE_MAX       equ 8

section .bss
arp_cache_ip:       resb ARP_CACHE_MAX * 4
arp_cache_mac:      resb ARP_CACHE_MAX * 6
arp_cache_valid:    resb ARP_CACHE_MAX
alignb 16
eth_tx_frame:       resb 1600
alignb 16
arp_pkt_buf:        resb 64

section .text

; ------------------------------------------------------------------------------
; eth_send_frame: Encapsulates L3 payload into Ethernet II frame and transmits
; Input:
;   RSI = Pointer to payload data
;   RCX = Payload length in bytes
;   RDI = Pointer to 6-byte Destination MAC Address
;   DX  = 16-bit EtherType (e.g. 0x0800 or 0x0806)
; ------------------------------------------------------------------------------
eth_send_frame:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    mov r8, rcx                 ; R8 = payload length
    mov r9, rsi                 ; R9 = payload source

    ; 1. Destination MAC (6 bytes)
    lea rax, [eth_tx_frame]
    push rdi
    push rsi
    mov rsi, rdi
    mov rdi, rax
    mov rcx, 6
    rep movsb
    pop rsi
    pop rdi

    ; 2. Source MAC (6 bytes) from net_mac
    lea rdi, [eth_tx_frame + 6]
    lea rsi, [net_mac]
    mov rcx, 6
    rep movsb

    ; 3. EtherType (2 bytes in big-endian network order)
    mov byte [eth_tx_frame + 12], dh
    mov byte [eth_tx_frame + 13], dl

    ; 4. Copy payload data starting at eth_tx_frame + 14
    lea rdi, [eth_tx_frame + 14]
    mov rsi, r9
    mov rcx, r8
    rep movsb

    ; Total frame length = payload length + 14
    add r8, 14

    ; Minimum Ethernet frame size is 60 bytes (pad with zeros if needed)
    cmp r8, 60
    jae .send_now
    mov rcx, 60
    sub rcx, r8
    lea rdi, [eth_tx_frame]
    add rdi, r8
    xor eax, eax
    rep stosb
    mov r8, 60

.send_now:
    lea rsi, [eth_tx_frame]
    mov rcx, r8
    call net_send_packet

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
; eth_handle_packet: Decodes incoming Ethernet II frame from driver
; Input:
;   RSI = Pointer to received Ethernet frame
;   RCX = Total frame length in bytes
; ------------------------------------------------------------------------------
eth_handle_packet:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    cmp rcx, 14
    jb .drop                    ; Drop malformed/short frame

    ; Extract 16-bit EtherType from offset 12 (Big Endian)
    movzx edx, byte [rsi + 12]
    shl edx, 8
    mov dl, [rsi + 13]

    ; Check EtherType
    cmp dx, ETHERTYPE_ARP
    je .handle_arp

    cmp dx, ETHERTYPE_IPV4
    je .handle_ipv4

    jmp .drop

.handle_arp:
    add rsi, 14                 ; Advance past Ethernet header
    sub rcx, 14
    call arp_handle_packet
    jmp .drop

.handle_ipv4:
    add rsi, 14                 ; Advance past Ethernet header
    sub rcx, 14
    call ipv4_handle_packet

.drop:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; arp_handle_packet: Processes incoming ARP Requests and Replies
; Input:
;   RSI = Pointer to ARP packet data
;   RCX = Packet length
; ------------------------------------------------------------------------------
arp_handle_packet:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    cmp rcx, 28
    jb .arp_done                ; Drop packet if smaller than standard 28-byte ARP

    ; Validate HW type == 1 (Ethernet)
    cmp byte [rsi + 0], 0
    jne .arp_done
    cmp byte [rsi + 1], 1
    jne .arp_done

    ; Validate Protocol == 0x0800 (IPv4)
    cmp byte [rsi + 2], 0x08
    jne .arp_done
    cmp byte [rsi + 3], 0x00
    jne .arp_done

    ; Validate HW size == 6, Proto size == 4
    cmp byte [rsi + 4], 6
    jne .arp_done
    cmp byte [rsi + 5], 4
    jne .arp_done

    ; Extract Opcode (offset 6): 1 = Request, 2 = Reply
    movzx eax, byte [rsi + 7]   ; Low byte of big-endian opcode

    ; Save Sender IP and MAC in ARP Cache
    lea rdi, [rsi + 14]         ; Sender IP (4 bytes)
    lea rbx, [rsi + 8]          ; Sender MAC (6 bytes)
    call arp_cache_insert

    cmp al, ARP_OP_REQUEST
    je .process_request
    jmp .arp_done

.process_request:
    ; Check if Target IP (offset 24) matches our net_ip
    mov eax, [rsi + 24]
    cmp eax, [net_ip]
    jne .arp_done               ; Not asking for our IP!

    ; Build ARP Reply (28 bytes)
    lea rdi, [arp_pkt_buf]

    ; HW Type = 0x0001
    mov word [rdi + 0], 0x0100  ; Big endian: 0x00, 0x01
    ; Protocol = 0x0800
    mov word [rdi + 2], 0x0008  ; Big endian: 0x08, 0x00
    ; HW size = 6, Proto size = 4
    mov byte [rdi + 4], 6
    mov byte [rdi + 5], 4
    ; Opcode = 2 (Reply)
    mov word [rdi + 6], 0x0200  ; Big endian: 0x00, 0x02

    ; Sender MAC = our net_mac (6 bytes)
    push rdi
    push rsi
    lea rdi, [arp_pkt_buf + 8]
    lea rsi, [net_mac]
    mov rcx, 6
    rep movsb
    pop rsi
    pop rdi

    ; Sender IP = our net_ip (4 bytes)
    mov eax, [net_ip]
    mov [rdi + 14], eax

    ; Target MAC = requester's MAC (6 bytes from RSI + 8)
    push rdi
    push rsi
    lea rdi, [arp_pkt_buf + 18]
    lea rsi, [rsi + 8]
    mov rcx, 6
    rep movsb
    pop rsi
    pop rdi

    ; Target IP = requester's IP (4 bytes from RSI + 14)
    mov eax, [rsi + 14]
    mov [rdi + 24], eax

    ; Transmit ARP Reply frame
    lea rsi, [arp_pkt_buf]
    mov rcx, 28
    lea rdi, [arp_pkt_buf + 18] ; Dst MAC = requester's MAC
    mov dx, ETHERTYPE_ARP
    call eth_send_frame

.arp_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; arp_send_request: Broadcasts ARP Request query for a given IPv4 address
; Input: RSI = Pointer to 4-byte Target IPv4 address
; ------------------------------------------------------------------------------
arp_send_request:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov r8, rsi                 ; R8 = target IP

    lea rdi, [arp_pkt_buf]
    ; HW Type = 1, Protocol = 0x0800
    mov word [rdi + 0], 0x0100
    mov word [rdi + 2], 0x0008
    mov byte [rdi + 4], 6
    mov byte [rdi + 5], 4
    ; Opcode = 1 (Request)
    mov word [rdi + 6], 0x0100

    ; Sender MAC = net_mac
    push rdi
    lea rdi, [arp_pkt_buf + 8]
    lea rsi, [net_mac]
    mov rcx, 6
    rep movsb
    pop rdi

    ; Sender IP = net_ip
    mov eax, [net_ip]
    mov [rdi + 14], eax

    ; Target MAC = 00:00:00:00:00:00
    mov dword [rdi + 18], 0
    mov word [rdi + 22], 0

    ; Target IP = target IP
    mov eax, [r8]
    mov [rdi + 24], eax

    ; Broadcast ARP frame
    lea rsi, [arp_pkt_buf]
    mov rcx, 28
    lea rdi, [broadcast_mac]
    mov dx, ETHERTYPE_ARP
    call eth_send_frame

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; arp_cache_insert: Stores IP -> MAC mapping in ARP Cache
; Input: RDI = Pointer to 4-byte IP, RBX = Pointer to 6-byte MAC
; ------------------------------------------------------------------------------
arp_cache_insert:
    push rax
    push rcx
    push rsi
    push rdi

    mov eax, [rdi]              ; New IP

    ; Check if IP already exists in cache
    xor ecx, ecx
.check_exist:
    cmp byte [arp_cache_valid + rcx], 1
    jne .next_chk
    cmp [arp_cache_ip + rcx * 4], eax
    je .update_entry
.next_chk:
    inc ecx
    cmp ecx, ARP_CACHE_MAX
    jl .check_exist

    ; Find first invalid or slot 0
    xor ecx, ecx
.find_slot:
    cmp byte [arp_cache_valid + rcx], 0
    je .found_slot
    inc ecx
    cmp ecx, ARP_CACHE_MAX
    jl .find_slot
    xor ecx, ecx                ; Overwrite slot 0 if full

.found_slot:
.update_entry:
    ; ECX holds target slot index
    mov [arp_cache_ip + rcx * 4], eax
    mov byte [arp_cache_valid + rcx], 1

    ; Copy 6-byte MAC
    push rdi
    push rcx
    lea rdi, [arp_cache_mac]
    imul ecx, 6
    add rdi, rcx
    mov rsi, rbx
    mov rcx, 6
    rep movsb
    pop rcx
    pop rdi

    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; ------------------------------------------------------------------------------
; arp_init: Pre-seeds the ARP cache with Gateway (10.0.2.2) and DNS (10.0.2.3)
; ------------------------------------------------------------------------------
arp_init:
    push rax
    push rbx
    push rcx
    push rdi

    ; Slot 0: Gateway (10.0.2.2) -> 52:54:00:12:34:02
    mov eax, [net_gateway]
    mov [arp_cache_ip + 0], eax
    mov byte [arp_cache_valid + 0], 1
    lea rdi, [arp_cache_mac + 0]
    lea rbx, [gateway_mac]
    mov rcx, 6
.seed_gw:
    mov al, [rbx]
    mov [rdi], al
    inc rbx
    inc rdi
    dec rcx
    jnz .seed_gw

    ; Slot 1: DNS Server (10.0.2.3) -> 52:54:00:12:34:02
    mov eax, [net_dns]
    mov [arp_cache_ip + 4], eax
    mov byte [arp_cache_valid + 1], 1
    lea rdi, [arp_cache_mac + 6]
    lea rbx, [gateway_mac]
    mov rcx, 6
.seed_dns:
    mov al, [rbx]
    mov [rdi], al
    inc rbx
    inc rdi
    dec rcx
    jnz .seed_dns

    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; arp_resolve: Resolves IPv4 address to Destination MAC address
; Input:  RSI = Pointer to 4-byte Target IPv4 address
;         RDI = Pointer to 6-byte buffer to store resolved MAC
; Output: RAX = 0 (Success), RAX = 1 (Failed/Timeout)
; ------------------------------------------------------------------------------
arp_resolve:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12

    mov eax, [rsi]              ; Target IP

    ; Fast path: If target is Gateway or DNS, route directly via Gateway MAC!
    cmp eax, [net_gateway]
    je .use_gw_mac
    cmp eax, [net_dns]
    je .use_gw_mac

    ; If target is on a different subnet, route via Gateway MAC!
    mov edx, eax
    xor edx, [net_ip]
    and edx, [net_netmask]
    jnz .use_gw_mac

    ; Search local ARP cache
    xor ecx, ecx
.cache_search:
    cmp byte [arp_cache_valid + rcx], 1
    jne .cache_next
    cmp [arp_cache_ip + rcx * 4], eax
    je .cache_hit
.cache_next:
    inc ecx
    cmp ecx, ARP_CACHE_MAX
    jl .cache_search

    ; Not in cache -> send ARP Request and poll with timer ticks (~500ms)
    call arp_send_request

    mov rax, [timer_ticks]
    add rax, TICKS(500)
    mov r12, rax
.poll_loop:
    call net_poll

    ; Re-check cache
    xor ecx, ecx
.recheck:
    cmp byte [arp_cache_valid + rcx], 1
    jne .recheck_next
    cmp [arp_cache_ip + rcx * 4], eax
    je .cache_hit
.recheck_next:
    inc ecx
    cmp ecx, ARP_CACHE_MAX
    jl .recheck

    call net_wait_step

    mov rax, [timer_ticks]
    cmp rax, r12
    jb .poll_loop

.use_gw_mac:
    ; Fallback / Route via Gateway MAC
    lea rsi, [gateway_mac]
    mov rcx, 6
    rep movsb
    xor rax, rax
    jmp .done

.cache_hit:
    ; Found in slot ECX: copy MAC to RDI
    lea rsi, [arp_cache_mac]
    imul ecx, 6
    add rsi, rcx
    mov rcx, 6
    rep movsb
    xor rax, rax

.done:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
