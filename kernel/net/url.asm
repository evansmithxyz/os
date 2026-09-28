; ==============================================================================
; Antigravity OS - URL parsing and host name resolution
; ------------------------------------------------------------------------------
; url_parse understands   [http://|https://]host[:port][/path]
; and fills url_https / url_host / url_port / url_path. Used by `curl` and the
; browser.
; ==============================================================================

[bits 64]

URL_HOST_MAX            equ 64
URL_PATH_MAX            equ 256

section .data
url_port:               dw 80
url_https:              db 0        ; 1 = https:// (TLS, default port 443)

section .bss
url_host:               resb URL_HOST_MAX
url_path:               resb URL_PATH_MAX
url_ip:                 resb 4

section .rodata
url_http_prefix:        db "http://", 0
url_https_prefix:       db "https://", 0

section .text
; ------------------------------------------------------------------------------
; url_parse: RSI = URL (ends at a space or NUL). Advances RSI past the URL.
; Output: CF=1 if there is no host name or the port is invalid.
; ------------------------------------------------------------------------------
url_parse:
    push rax
    push rcx
    push rdi

    mov word [url_port], 80
    mov byte [url_https], 0
    mov byte [url_host], 0
    mov word [url_path], '/'        ; "/" + NUL

    lea rdi, [url_http_prefix]
    call str_has_prefix
    jne .try_https
    add rsi, 7
    jmp .host
.try_https:
    lea rdi, [url_https_prefix]
    call str_has_prefix
    jne .host
    add rsi, 8
    mov byte [url_https], 1
    mov word [url_port], 443

.host:
    lea rdi, [url_host]
    xor ecx, ecx
.host_loop:
    mov al, [rsi]
    test al, al
    jz .host_end
    cmp al, ' '
    je .host_end
    cmp al, ':'
    je .host_end
    cmp al, '/'
    je .host_end
    inc rsi
    cmp ecx, URL_HOST_MAX - 1
    jae .host_loop
    mov [rdi + rcx], al
    inc ecx
    jmp .host_loop
.host_end:
    mov byte [rdi + rcx], 0
    test ecx, ecx
    jz .error

    cmp byte [rsi], ':'
    jne .path
    inc rsi
    call parse_dec
    jc .error
    test rax, rax
    jz .error
    cmp rax, 65535
    ja .error
    mov [url_port], ax

.path:
    cmp byte [rsi], '/'
    jne .ok
    lea rdi, [url_path]
    xor ecx, ecx
.path_loop:
    mov al, [rsi]
    test al, al
    jz .path_end
    cmp al, ' '
    je .path_end
    inc rsi
    cmp ecx, URL_PATH_MAX - 1
    jae .path_loop
    mov [rdi + rcx], al
    inc ecx
    jmp .path_loop
.path_end:
    mov byte [rdi + rcx], 0
.ok:
    pop rdi
    pop rcx
    pop rax
    clc
    ret
.error:
    pop rdi
    pop rcx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; net_resolve_host: RSI = host name or dotted IPv4, RDI = 4-byte output
; Output: CF=1 if it is not an IP address and DNS lookup failed.
; ------------------------------------------------------------------------------
net_resolve_host:
    push rax
    push rsi
    call net_parse_ip               ; RAX = 0 if RSI was a dotted IPv4 address
    test rax, rax
    jnz .dns
    cmp byte [rsi], 0               ; must have consumed the whole string
    je .ok
.dns:
    mov rsi, [rsp]
    call dns_resolve
    test rax, rax
    jnz .fail
.ok:
    pop rsi
    pop rax
    clc
    ret
.fail:
    pop rsi
    pop rax
    stc
    ret
