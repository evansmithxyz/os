; ==============================================================================
; Shell commands: network (ifconfig, arp, ping, dns, curl, tcplisten)
; Handlers: RSI = arguments; may clobber any register except RSP.
; ==============================================================================

[bits 64]

section .rodata
msg_no_nic:         db "No RTL8139 network card was found (QEMU: -device rtl8139).", 0x0A, 0
msg_if_hdr:         db "eth0: Realtek RTL8139 Fast Ethernet (PCI, polled)", 0x0A, 0
msg_if_io:          db "  I/O port:    0x", 0
msg_if_mac:         db "  MAC:         ", 0
msg_if_ip:          db "  IPv4:        ", 0
msg_if_mask:        db "  Netmask:     ", 0
msg_if_gw:          db "  Gateway:     ", 0
msg_if_gw_mac:      db "  (MAC ", 0
msg_if_dns:         db "  DNS server:  ", 0
msg_if_rx:          db "  RX packets:  ", 0
msg_if_tx:          db "  TX packets:  ", 0
msg_if_bytes:       db "  bytes: ", 0
msg_close_paren:    db ")", 0x0A, 0
msg_arp_hdr:        db "IP ADDRESS        MAC ADDRESS         TYPE", 0x0A, 0
msg_arp_static:     db "  static (gateway)", 0x0A, 0
msg_arp_dynamic:    db "  dynamic", 0x0A, 0
msg_usage_ping:     db "Usage: ping <ip or domain>   e.g. ping 10.0.2.2", 0x0A, 0
msg_usage_dns:      db "Usage: dns <domain>   e.g. dns example.com", 0x0A, 0
msg_usage_curl:     db "Usage: curl [-k] <url> [port]   e.g. curl 10.0.2.2 or curl https://example.com/", 0x0A
                    db "       -k, --insecure: do not check the server's certificate", 0x0A, 0
msg_resolving:      db "Resolving ", 0
msg_dots:           db "... ", 0
msg_resolve_fail:   db "failed (unknown host or DNS timeout)", 0x0A, 0
msg_dns_query:      db "Querying DNS server ", 0
msg_dns_for:        db " for ", 0
msg_dns_name:       db "  Name:    ", 0
msg_dns_addr:       db "  Address: ", 0
msg_bad_port:       db "Invalid port number.", 0x0A, 0
msg_tls_unverified: db "[TLS] TLS 1.3, ChaCha20-Poly1305. WARNING: -k given, the certificate was NOT verified;", 0x0A
                    db "      anyone on the network path could be impersonating this server.", 0x0A, 0
msg_tls_verified:   db "[TLS] TLS 1.3, ChaCha20-Poly1305. Certificate verified for ", 0
msg_opt_k:          db "-k ", 0
msg_opt_insecure:   db "--insecure ", 0
msg_tls_failed:     db "[TLS] Handshake failed: ", 0

section .text
; cmd_require_nic: CF=1 (and a message) if there is no network card
cmd_require_nic:
    cmp byte [net_present], 1
    je .ok
    push rsi
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_no_nic]
    call con_puts_color
    pop rsi
    stc
    ret
.ok:
    clc
    ret

cmd_ifconfig:
    call cmd_require_nic
    jc .done
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [msg_if_hdr]
    call con_puts_color
    lea rsi, [msg_if_io]
    call con_puts
    mov ax, [net_io_base]
    call con_hex16
    call con_newline
    lea rsi, [msg_if_mac]
    call con_puts
    lea rsi, [net_mac]
    call con_mac
    call con_newline
    lea rsi, [msg_if_ip]
    call con_puts
    lea rsi, [net_ip]
    call con_ip
    call con_newline
    lea rsi, [msg_if_mask]
    call con_puts
    lea rsi, [net_netmask]
    call con_ip
    call con_newline
    lea rsi, [msg_if_gw]
    call con_puts
    lea rsi, [net_gateway]
    call con_ip
    lea rsi, [msg_if_gw_mac]
    call con_puts
    lea rsi, [gateway_mac]
    call con_mac
    lea rsi, [msg_close_paren]
    call con_puts
    lea rsi, [msg_if_dns]
    call con_puts
    lea rsi, [net_dns]
    call con_ip
    call con_newline
    lea rsi, [msg_if_rx]
    call con_puts
    mov rax, [net_packets_rx]
    call con_dec
    lea rsi, [msg_if_bytes]
    call con_puts
    mov rax, [net_bytes_rx]
    call con_dec
    call con_newline
    lea rsi, [msg_if_tx]
    call con_puts
    mov rax, [net_packets_tx]
    call con_dec
    lea rsi, [msg_if_bytes]
    call con_puts
    mov rax, [net_bytes_tx]
    call con_dec
    call con_newline
.done:
    ret

cmd_arp:
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [msg_arp_hdr]
    call con_puts_color
    lea rsi, [net_gateway]
    call cmd_print_ip_padded
    lea rsi, [gateway_mac]
    call con_mac
    lea rsi, [msg_arp_static]
    call con_puts
    xor r12d, r12d
.loop:
    lea rax, [arp_cache_valid]
    cmp byte [rax + r12], 1
    jne .next
    lea rsi, [arp_cache_ip]
    lea rsi, [rsi + r12 * 4]
    call cmd_print_ip_padded
    lea rsi, [arp_cache_mac]
    imul eax, r12d, 6
    add rsi, rax
    call con_mac
    lea rsi, [msg_arp_dynamic]
    call con_puts
.next:
    inc r12d
    cmp r12d, ARP_CACHE_MAX
    jb .loop
    ret

; cmd_print_ip_padded: RSI = IPv4 address, printed in an 18-column field
cmd_print_ip_padded:
    push rax
    push rcx
    push rdx
    call con_ip
    ; count the characters printed: digits of each octet + 3 dots
    mov ecx, 3
    xor edx, edx
.octet:
    movzx eax, byte [rsi + rdx]
    inc ecx
    cmp eax, 10
    jb .next
    inc ecx
    cmp eax, 100
    jb .next
    inc ecx
.next:
    inc edx
    cmp edx, 4
    jb .octet
    neg rcx
    add rcx, 18
    call con_spaces
    pop rdx
    pop rcx
    pop rax
    ret

; cmd_resolve_arg: RSI = host argument -> url_ip filled, CF=1 on failure.
; Prints "Resolving <name>... " for names that are not dotted IPs.
cmd_resolve_arg:
    lea rdi, [url_ip]
    push rsi
    call net_parse_ip
    mov dl, [rsi]                   ; must have consumed the whole argument
    pop rsi
    test rax, rax
    jnz .name
    test dl, dl
    jz .ok
.name:
    mov r15, rsi
    mov bl, COLOR_LIGHT_BLUE
    lea rsi, [msg_resolving]
    call con_puts_color
    mov rsi, r15
    call con_puts_color
    lea rsi, [msg_dots]
    call con_puts_color
    mov rsi, r15
    lea rdi, [url_ip]
    call net_resolve_host
    jc .fail
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [url_ip]
    mov [con_attr], bl
    call con_ip
    mov byte [con_attr], COLOR_LIGHT_GRAY
    call con_newline
.ok:
    clc
    ret
.fail:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_resolve_fail]
    call con_puts_color
    stc
    ret

cmd_ping:
    call cmd_require_nic
    jc .done
    call shell_arg_word
    test rax, rax
    jz .usage
    lea rsi, [shell_arg]
    call cmd_resolve_arg
    jc .done
    lea rsi, [url_ip]
    call icmp_ping
.done:
    ret
.usage:
    mov bl, COLOR_YELLOW
    lea rsi, [msg_usage_ping]
    jmp con_puts_color

cmd_dns:
    call cmd_require_nic
    jc .done
    call shell_arg_word
    test rax, rax
    jz .usage
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [msg_dns_query]
    call con_puts_color
    lea rsi, [net_dns]
    call con_ip
    lea rsi, [msg_dns_for]
    call con_puts_color
    lea rsi, [shell_arg]
    call con_puts_color
    call con_newline
    lea rsi, [shell_arg]
    lea rdi, [url_ip]
    call net_resolve_host
    jc .fail
    lea rsi, [msg_dns_name]
    call con_puts
    lea rsi, [shell_arg]
    call con_puts
    call con_newline
    lea rsi, [msg_dns_addr]
    call con_puts
    lea rsi, [url_ip]
    call con_ip
    jmp con_newline
.fail:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_resolve_fail]
    jmp con_puts_color
.done:
    ret
.usage:
    mov bl, COLOR_YELLOW
    lea rsi, [msg_usage_dns]
    jmp con_puts_color

cmd_curl:
    call cmd_require_nic
    jc .done
    ; -k / --insecure: do not check the server's certificate
    mov byte [tls_insecure], 0
    lea rdi, [msg_opt_k]
    call str_has_prefix
    je .insecure3
    lea rdi, [msg_opt_insecure]
    call str_has_prefix
    jne .no_option
    add rsi, 8
.insecure3:
    add rsi, 2
    mov byte [tls_insecure], 1
    call skip_spaces
.no_option:
    cmp byte [rsi], 0
    je .usage
    call url_parse                  ; RSI -> after the URL
    jc .usage
    call skip_spaces
    cmp byte [rsi], 0               ; optional "curl host port"
    je .resolve
    call parse_dec
    jc .bad_port
    test rax, rax
    jz .bad_port
    cmp rax, 65535
    ja .bad_port
    mov [url_port], ax
.resolve:
    lea rsi, [url_host]
    call cmd_resolve_arg
    jc .done
    mov byte [http_quiet], 0
    lea rsi, [url_ip]
    lea rdi, [url_host]
    movzx edx, word [url_port]
    lea r8, [url_path]
    cmp byte [url_https], 1
    je .https
    call tcp_http_client
.done:
    ret
.https:
    call tls_https_get
    test eax, eax
    jnz .tls_failed
    cmp byte [tls_verified], 1
    jne .unverified
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [msg_tls_verified]
    call con_puts_color
    lea rsi, [url_host]
    call con_puts_color
    mov al, 0x0A
    call con_putc
    jmp .body
.unverified:
    mov bl, COLOR_YELLOW
    lea rsi, [msg_tls_unverified]
    call con_puts_color
.body:
    mov bl, COLOR_LIGHT_CYAN
    lea rsi, [http_resp_buf]
    call con_puts_color
    call con_newline
    ret
.tls_failed:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_tls_failed]
    call con_puts_color
    mov rsi, [tls_error_msg]
    call con_puts_color
    call con_newline
    ret
.bad_port:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_bad_port]
    jmp con_puts_color
.usage:
    mov bl, COLOR_YELLOW
    lea rsi, [msg_usage_curl]
    jmp con_puts_color

cmd_tcplisten:
    call cmd_require_nic
    jc .done
    mov edx, 80
    cmp byte [rsi], 0
    je .start
    call parse_dec
    jc .bad_port
    test rax, rax
    jz .bad_port
    cmp rax, 65535
    ja .bad_port
    mov edx, eax
.start:
    call tcp_server_start
.done:
    ret
.bad_port:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_bad_port]
    jmp con_puts_color
