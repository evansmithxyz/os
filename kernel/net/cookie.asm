; ==============================================================================
; Antigravity OS - the browser's cookie jar
; ------------------------------------------------------------------------------
; Cookies live in memory until the machine is turned off (expiry dates only
; matter to delete one). The browser's requests (http_quiet) carry them:
;
;   cookie_request   http_build_request: the request's host, path and whether
;                    it goes over TLS
;   cookie_header    "\r\nCookie: a=1; b=2" for that request
;   cookie_response  after the response: its Set-Cookie headers stored
;   cookie_page_*    document.cookie: the page's cookies as a string, and a
;                    script setting one
;
; Matching follows RFC 6265: a cookie with Domain= goes to that domain and its
; subdomains, one without only to the host that set it; Path= is a prefix of
; the request path at a '/'; Secure ones only go over TLS; HttpOnly ones are
; not shown to scripts. A cookie is replaced by one with the same name,
; domain and path, and deleted by Max-Age<=0 or an Expires in the past.
; ==============================================================================

[bits 64]

COOKIE_MAX              equ 64
COOKIE_SIZE             equ 1024
COOKIE_HEADER_MAX       equ 4096    ; bytes of one Cookie: header
COOKIE_STR_MAX          equ 255     ; host and path of a request

; jar entry
CK_FLAGS                equ 0       ; db CKF_*
CK_DLEN                 equ 1       ; db domain length
CK_PLEN                 equ 2       ; db path length
CK_NLEN                 equ 4       ; dw name length
CK_VLEN                 equ 6       ; dw value length
CK_DOMAIN               equ 8       ; lower case, no leading dot
CK_DOMAIN_MAX           equ 127
CK_PATH                 equ 136
CK_PATH_MAX             equ 127
CK_NAME                 equ 264
CK_NAME_MAX             equ 127
CK_VALUE                equ 392
CK_VALUE_MAX            equ COOKIE_SIZE - CK_VALUE
CKF_USED                equ 1
CKF_HOST_ONLY           equ 2
CKF_SECURE              equ 4
CKF_HTTP_ONLY           equ 8

section .data
align 4
cookie_next:            dd 0        ; the entry a full jar gives up next

section .bss
alignb 16
cookie_jar:             resb COOKIE_MAX * COOKIE_SIZE
cookie_req_host:        resb COOKIE_STR_MAX + 1     ; the request cookies are for
cookie_req_path:        resb COOKIE_STR_MAX + 1
cookie_page_buf:        resb COOKIE_HEADER_MAX      ; document.cookie
cookie_new:             resb COOKIE_SIZE            ; the cookie being parsed
alignb 4
cookie_req_hlen:        resd 1
cookie_req_plen:        resd 1
cookie_expired:         resb 1      ; the one being parsed deletes itself
cookie_req_secure:      resb 1
cookie_script:          resb 1      ; document.cookie: HttpOnly is not allowed

section .rodata
cookie_hdr_name:        db 13, 10, "Cookie: ", 0
cookie_set_name:        db "set-cookie:", 0
cookie_attr_domain:     db "domain", 0
cookie_attr_path:       db "path", 0
cookie_attr_max_age:    db "max-age", 0
cookie_attr_expires:    db "expires", 0
cookie_attr_secure:     db "secure", 0
cookie_attr_httponly:   db "httponly", 0
cookie_months:          db "janfebmaraprmayjunjulaugsepoctnovdec"
klog_cookie_set:        db "cookie: set ", 0
klog_cookie_del:        db "cookie: deleted ", 0

section .text
; ------------------------------------------------------------------------------
; cookie_request: RSI/ECX = request host, RDI = its path (NUL-terminated, may
; have a query), AL = 1 over TLS -> the request the jar works for now
; ------------------------------------------------------------------------------
cookie_request:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov [cookie_req_secure], al
    ; the host, lower case, without a :port
    push rdi
    lea rdi, [cookie_req_host]
    xor eax, eax
.host:
    test ecx, ecx
    jz .host_done
    cmp eax, COOKIE_STR_MAX
    jae .host_done
    mov dl, [rsi]
    cmp dl, ':'
    je .host_done
    cmp dl, 'A'
    jb .host_put
    cmp dl, 'Z'
    ja .host_put
    or dl, 0x20
.host_put:
    mov [rdi + rax], dl
    inc eax
    inc rsi
    dec ecx
    jmp .host
.host_done:
    mov byte [rdi + rax], 0
    mov [cookie_req_hlen], eax
    pop rsi                         ; the path
    ; the path, up to its query or fragment ("/" if it has none)
    lea rdi, [cookie_req_path]
    xor eax, eax
    test rsi, rsi
    jz .path_done
.path:
    cmp eax, COOKIE_STR_MAX
    jae .path_done
    mov dl, [rsi + rax]
    test dl, dl
    jz .path_done
    cmp dl, '?'
    je .path_done
    cmp dl, '#'
    je .path_done
    mov [rdi + rax], dl
    inc eax
    jmp .path
.path_done:
    test eax, eax
    jz .root
    cmp byte [rdi], '/'
    je .path_end
.root:
    mov byte [rdi], '/'
    mov eax, 1
.path_end:
    mov byte [rdi + rax], 0
    mov [cookie_req_plen], eax
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; cookie_page: browser_page_url -> the request the jar works for (what
; document.cookie reads and writes)
; ------------------------------------------------------------------------------
cookie_page:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    lea rsi, [browser_page_url]
    xor eax, eax                    ; AL = https
    cmp dword [rsi], 'http'
    jne .no_scheme
    cmp byte [rsi + 4], 's'
    jne .http
    mov al, 1
    inc rsi
.http:
    add rsi, 4
    cmp word [rsi], ':/'
    jne .no_scheme
    add rsi, 3                      ; "://"
.no_scheme:
    xor ecx, ecx
.host_end:
    mov dl, [rsi + rcx]
    test dl, dl
    jz .have_host
    cmp dl, '/'
    je .have_host
    cmp dl, '?'
    je .have_host
    cmp dl, '#'
    je .have_host
    inc ecx
    jmp .host_end
.have_host:
    lea rdi, [rsi + rcx]            ; the path
    call cookie_request
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; cookie_header: RDI = end of the request headers so far, RDX = how far they
; may go -> "\r\nCookie: ..." with the cookies for the request, if any; RDI
; after it
; ------------------------------------------------------------------------------
cookie_header:
    push rax
    push rsi
    push r8
    mov r8, rdi                     ; (nothing added: back to here)
    lea rsi, [cookie_hdr_name]
    call cookie_put_cstr
    mov rax, rdi
    push rdx
    mov byte [cookie_script], 0
    call cookie_list
    pop rdx
    cmp rdi, rax
    jne .ret
    mov rdi, r8                     ; no cookies: no header
.ret:
    pop r8
    pop rsi
    pop rax
    ret

; cookie_put_cstr: RSI = text -> copied to RDI (up to RDX)
cookie_put_cstr:
    push rax
    push rsi
.byte:
    lodsb
    test al, al
    jz .done
    cmp rdi, rdx
    jae .done
    stosb
    jmp .byte
.done:
    pop rsi
    pop rax
    ret

; ------------------------------------------------------------------------------
; cookie_list: RDI = where, RDX = limit -> "a=1; b=2" for the request (not
; the HttpOnly ones if cookie_script); RDI after it
; ------------------------------------------------------------------------------
cookie_list:
    push rax
    push rbx
    push rcx
    push rsi
    push r9
    lea rbx, [cookie_jar]
    xor r9d, r9d                    ; R9 = cookies so far
    mov ecx, COOKIE_MAX
.entry:
    test byte [rbx + CK_FLAGS], CKF_USED
    jz .next
    call cookie_matches
    jnc .next
    cmp byte [cookie_script], 0
    je .room
    test byte [rbx + CK_FLAGS], CKF_HTTP_ONLY
    jnz .next
.room:
    ; "; " name "=" value must fit
    movzx eax, word [rbx + CK_NLEN]
    movzx esi, word [rbx + CK_VLEN]
    lea rax, [rax + rsi + 4]
    add rax, rdi
    cmp rax, rdx
    jae .next
    test r9d, r9d
    jz .first
    mov word [rdi], '; '
    add rdi, 2
.first:
    inc r9d
    push rcx
    lea rsi, [rbx + CK_NAME]
    movzx ecx, word [rbx + CK_NLEN]
    rep movsb
    mov byte [rdi], '='
    inc rdi
    lea rsi, [rbx + CK_VALUE]
    movzx ecx, word [rbx + CK_VLEN]
    rep movsb
    pop rcx
.next:
    add rbx, COOKIE_SIZE
    dec ecx
    jnz .entry
    pop r9
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; cookie_matches: RBX = jar entry -> CF=1 if it goes with the request
; (cookie_req_*): domain, path and Secure
; ------------------------------------------------------------------------------
cookie_matches:
    push rax
    push rcx
    push rsi
    push rdi
    test byte [rbx + CK_FLAGS], CKF_SECURE
    jz .domain
    cmp byte [cookie_req_secure], 0
    je .no
.domain:
    movzx ecx, byte [rbx + CK_DLEN]
    mov eax, [cookie_req_hlen]
    lea rsi, [rbx + CK_DOMAIN]
    lea rdi, [cookie_req_host]
    cmp eax, ecx
    je .same_host
    jb .no
    test byte [rbx + CK_FLAGS], CKF_HOST_ONLY
    jnz .no
    ; a subdomain: the host ends with "." domain
    sub eax, ecx
    cmp byte [rdi + rax - 1], '.'
    jne .no
    add rdi, rax
.same_host:
    repe cmpsb
    jne .no
    ; the path: the cookie's is a prefix of the request's, ending at a '/'
    movzx ecx, byte [rbx + CK_PLEN]
    mov eax, [cookie_req_plen]
    cmp eax, ecx
    jb .no
    lea rsi, [rbx + CK_PATH]
    lea rdi, [cookie_req_path]
    push rcx
    repe cmpsb
    pop rcx
    jne .no
    cmp eax, ecx
    je .yes
    cmp byte [rbx + CK_PATH + rcx - 1], '/'
    je .yes
    lea rdi, [cookie_req_path]
    cmp byte [rdi + rcx], '/'
    jne .no
.yes:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    stc
    ret
.no:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    clc
    ret

; ------------------------------------------------------------------------------
; cookie_response: http_resp_buf holds a response to the request -> each of
; its Set-Cookie headers stored
; ------------------------------------------------------------------------------
cookie_response:
    push rax
    push rcx
    push rsi
    push rdi
    lea rsi, [abs http_resp_buf]
.line:
    ; the next header line (the status line is skipped the same way)
    mov al, [rsi]
    test al, al
    jz .done
    inc rsi
    cmp al, 10
    jne .line
    cmp byte [rsi], 13
    je .done                        ; the blank line: the body is next
    cmp byte [rsi], 10
    je .done
    lea rdi, [cookie_set_name]
    call cookie_prefix_ci
    jne .line
    add rsi, 11
    ; its value, up to the end of the line
    xor ecx, ecx
.value_end:
    mov al, [rsi + rcx]
    test al, al
    jz .have_value
    cmp al, 13
    je .have_value
    cmp al, 10
    je .have_value
    inc ecx
    jmp .value_end
.have_value:
    mov byte [cookie_script], 0
    call cookie_set
    add rsi, rcx
    jmp .line
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; cookie_prefix_ci: RSI = text, RDI = lower-case prefix -> ZF=1 if the text
; starts with it, ignoring case
cookie_prefix_ci:
    push rax
    push rsi
    push rdi
.byte:
    mov al, [rdi]
    test al, al
    jz .done                        ; (ZF=1)
    mov ah, [rsi]
    cmp ah, 'A'
    jb .cmp
    cmp ah, 'Z'
    ja .cmp
    or ah, 0x20
.cmp:
    cmp ah, al
    jne .done
    inc rsi
    inc rdi
    jmp .byte
.done:
    pop rdi
    pop rsi
    pop rax
    ret

; ------------------------------------------------------------------------------
; cookie_set: RSI/ECX = a Set-Cookie value ("name=value; Path=/; ...") for
; the request (cookie_req_*); cookie_script = 1 if a script set it -> stored,
; replacing or deleting the one with its name, domain and path
; ------------------------------------------------------------------------------
cookie_set:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    lea r8, [rsi + rcx]             ; R8 = end
    lea rbx, [cookie_new]
    mov byte [rbx + CK_FLAGS], CKF_USED | CKF_HOST_ONLY
    mov byte [cookie_expired], 0
    ; name=value (no '=': a value with an empty name)
    call cookie_skip_spaces
    mov r9, rsi                     ; R9 = start
    mov rdi, rsi
.name_end:
    cmp rdi, r8
    jae .no_equals
    cmp byte [rdi], ';'
    je .no_equals
    cmp byte [rdi], '='
    je .have_name
    inc rdi
    jmp .name_end
.no_equals:
    xor ecx, ecx
    mov rdi, r9                     ; all of it is the value
    jmp .store_name
.have_name:
    mov rcx, rdi
    sub rcx, rsi
.store_name:
    call cookie_trim
    cmp ecx, CK_NAME_MAX
    ja .reject
    mov [rbx + CK_NLEN], cx
    push rdi
    lea rdi, [rbx + CK_NAME]
    rep movsb
    pop rdi
    ; the value, up to ';'
    mov rsi, rdi
    cmp rsi, r8
    jae .value_start
    cmp byte [rsi], '='
    jne .value_start
    inc rsi
.value_start:
    mov rdi, rsi
.value_end:
    cmp rdi, r8
    jae .have_value
    cmp byte [rdi], ';'
    je .have_value
    inc rdi
    jmp .value_end
.have_value:
    mov rcx, rdi
    sub rcx, rsi
    call cookie_trim
    cmp ecx, CK_VALUE_MAX
    ja .reject
    mov [rbx + CK_VLEN], cx
    push rdi
    lea rdi, [rbx + CK_VALUE]
    rep movsb
    pop rdi
    mov rsi, rdi
    movzx eax, word [rbx + CK_NLEN]
    or ax, [rbx + CK_VLEN]
    jz .reject                      ; nothing at all
    ; defaults: the request's host, its path up to the last '/'
    call cookie_default_domain
    call cookie_default_path
    ; attributes
.attr:
    cmp rsi, r8
    jae .attrs_done
    inc rsi                         ; the ';'
    call cookie_skip_spaces
    lea rdi, [cookie_attr_domain]
    call cookie_attr_is
    je .domain
    lea rdi, [cookie_attr_path]
    call cookie_attr_is
    je .path
    lea rdi, [cookie_attr_max_age]
    call cookie_attr_is
    je .max_age
    lea rdi, [cookie_attr_expires]
    call cookie_attr_is
    je .expires
    lea rdi, [cookie_attr_secure]
    call cookie_attr_is
    je .secure
    lea rdi, [cookie_attr_httponly]
    call cookie_attr_is
    je .http_only
    call cookie_attr_value          ; something else: skipped
    jmp .attr
.secure:
    call cookie_attr_value
    or byte [rbx + CK_FLAGS], CKF_SECURE
    jmp .attr
.http_only:
    call cookie_attr_value
    cmp byte [cookie_script], 0
    jne .reject
    or byte [rbx + CK_FLAGS], CKF_HTTP_ONLY
    jmp .attr
.max_age:
    call cookie_attr_value          ; RDI/ECX
    test ecx, ecx
    jz .attr
    cmp byte [rdi], '-'
    je .gone
    cmp byte [rdi], '0'
    jne .attr
    ; "0", "00": gone
.zeros:
    cmp byte [rdi], '0'
    jne .attr
    inc rdi
    dec ecx
    jnz .zeros
.gone:
    mov byte [cookie_expired], 1
    jmp .attr
.expires:
    call cookie_attr_value
    call cookie_date_past
    jnc .attr
    mov byte [cookie_expired], 1
    jmp .attr
.path:
    call cookie_attr_value
    test ecx, ecx
    jz .attr
    cmp byte [rdi], '/'
    jne .attr                       ; not a path: the default stays
    cmp ecx, CK_PATH_MAX
    ja .reject
    mov [rbx + CK_PLEN], cl
    push rsi
    mov rsi, rdi
    lea rdi, [rbx + CK_PATH]
    rep movsb
    pop rsi
    jmp .attr
.domain:
    call cookie_attr_value
    ; a leading dot means nothing
    test ecx, ecx
    jz .attr
    cmp byte [rdi], '.'
    jne .domain_len
    inc rdi
    dec ecx
    jz .attr
.domain_len:
    cmp ecx, CK_DOMAIN_MAX
    ja .reject
    ; it must be the request's host or a domain it is in
    mov eax, [cookie_req_hlen]
    cmp eax, ecx
    jb .reject
    push rsi
    push rdi
    lea rsi, [cookie_req_host]
    sub eax, ecx
    jz .domain_cmp
    cmp byte [rsi + rax - 1], '.'
    jne .domain_bad
.domain_cmp:
    add rsi, rax
    push rcx
.domain_byte:
    mov al, [rdi]
    cmp al, 'A'
    jb .domain_lower
    cmp al, 'Z'
    ja .domain_lower
    or al, 0x20
.domain_lower:
    cmp al, [rsi]
    jne .domain_mismatch
    inc rdi
    inc rsi
    dec ecx
    jnz .domain_byte
    pop rcx
    pop rdi
    pop rsi
    ; store it (lower case: the host's own letters)
    mov [rbx + CK_DLEN], cl
    push rsi
    push rdi
    lea rsi, [cookie_req_host]
    add esi, [cookie_req_hlen]      ; (the tail of the host)
    sub rsi, rcx
    lea rdi, [rbx + CK_DOMAIN]
    rep movsb
    pop rdi
    pop rsi
    and byte [rbx + CK_FLAGS], ~CKF_HOST_ONLY
    jmp .attr
.domain_mismatch:
    pop rcx
.domain_bad:
    pop rdi
    pop rsi
    jmp .reject
.attrs_done:
    call cookie_store
.reject:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; cookie_skip_spaces: RSI up to R8 -> past spaces and tabs
cookie_skip_spaces:
    cmp rsi, r8
    jae .ret
    cmp byte [rsi], ' '
    je .skip
    cmp byte [rsi], 9
    jne .ret
.skip:
    inc rsi
    jmp cookie_skip_spaces
.ret:
    ret

; cookie_trim: RSI/ECX -> without spaces at either end
cookie_trim:
.front:
    test ecx, ecx
    jz .ret
    cmp byte [rsi], ' '
    jne .back
    inc rsi
    dec ecx
    jmp .front
.back:
    cmp byte [rsi + rcx - 1], ' '
    jne .ret
    dec ecx
    jnz .back
.ret:
    ret

; cookie_attr_is: RSI = an attribute (up to R8), RDI = lower-case name ->
; ZF=1 if it is that one (followed by '=', ';', a space or the end)
cookie_attr_is:
    push rax
    push rcx
    push rsi
    push rdi
.byte:
    mov al, [rdi]
    test al, al
    jz .name_end
    cmp rsi, r8
    jae .no
    mov ah, [rsi]
    cmp ah, 'A'
    jb .cmp
    cmp ah, 'Z'
    ja .cmp
    or ah, 0x20
.cmp:
    cmp ah, al
    jne .no
    inc rsi
    inc rdi
    jmp .byte
.name_end:
    cmp rsi, r8
    jae .yes
    mov al, [rsi]
    cmp al, '='
    je .yes
    cmp al, ';'
    je .yes
    cmp al, ' '
    je .yes
.no:
    or al, 1                        ; (ZF=0)
    test al, al
    jmp .out
.yes:
    xor eax, eax                    ; (ZF=1)
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; cookie_attr_value: RSI = an attribute (up to R8) -> RDI/ECX = its value
; (trimmed, empty if it has none), RSI at the ';' after it or the end
cookie_attr_value:
    xor ecx, ecx
    mov rdi, rsi
.name:
    cmp rsi, r8
    jae .none
    cmp byte [rsi], ';'
    je .none
    cmp byte [rsi], '='
    je .value
    inc rsi
    jmp .name
.none:
    mov rdi, rsi
    ret
.value:
    inc rsi
    push rsi
.end:
    cmp rsi, r8
    jae .have
    cmp byte [rsi], ';'
    je .have
    inc rsi
    jmp .end
.have:
    mov rcx, rsi
    pop rdi
    sub rcx, rdi
    push rsi
    mov rsi, rdi
    call cookie_trim
    mov rdi, rsi
    pop rsi
    ret

; cookie_default_domain: RBX = new cookie -> the request's host (host-only)
cookie_default_domain:
    push rcx
    push rsi
    push rdi
    mov ecx, [cookie_req_hlen]
    cmp ecx, CK_DOMAIN_MAX
    jbe .len
    mov ecx, CK_DOMAIN_MAX
.len:
    mov [rbx + CK_DLEN], cl
    lea rsi, [cookie_req_host]
    lea rdi, [rbx + CK_DOMAIN]
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    ret

; cookie_default_path: RBX = new cookie -> the request's path up to (not
; including) its last '/', or "/"
cookie_default_path:
    push rax
    push rcx
    push rsi
    push rdi
    lea rsi, [cookie_req_path]
    mov ecx, [cookie_req_plen]
.last_slash:
    test ecx, ecx
    jz .root
    dec ecx
    cmp byte [rsi + rcx], '/'
    jne .last_slash
    test ecx, ecx
    jz .root
    cmp ecx, CK_PATH_MAX
    ja .root
    mov [rbx + CK_PLEN], cl
    lea rdi, [rbx + CK_PATH]
    rep movsb
    jmp .out
.root:
    mov byte [rbx + CK_PLEN], 1
    mov byte [rbx + CK_PATH], '/'
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; cookie_date_past: RDI/ECX = an HTTP date ("Thu, 01 Jan 1970 00:00:00 GMT")
; -> CF=1 if its day is before today (by the CMOS clock)
; ------------------------------------------------------------------------------
cookie_date_past:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r10
    push r11
    ; day: the first number; year: a number over 31; month: its name
    xor r9d, r9d                    ; R9 = day
    xor r10d, r10d                  ; R10 = month (1-12)
    xor r11d, r11d                  ; R11 = year
    lea rsi, [rdi + rcx]            ; RSI = end
.token:
    cmp rdi, rsi
    jae .parsed
    movzx eax, byte [rdi]
    sub eax, '0'
    cmp eax, 9
    jbe .number
    ; three letters: a month?
    lea rax, [rdi + 3]
    cmp rax, rsi
    ja .skip
    mov eax, [rdi]
    and eax, 0x00FFFFFF
    or eax, 0x00202020
    lea rbx, [cookie_months]
    xor edx, edx
.month:
    mov ecx, [rbx]
    and ecx, 0x00FFFFFF
    cmp eax, ecx
    je .month_found
    add rbx, 3
    inc edx
    cmp edx, 12
    jb .month
    jmp .skip
.month_found:
    lea r10d, [edx + 1]
    add rdi, 3
    jmp .token
.number:
    xor eax, eax
    xor ecx, ecx                    ; digits
.digits:
    cmp rdi, rsi
    jae .have_number
    movzx edx, byte [rdi]
    sub edx, '0'
    cmp edx, 9
    ja .have_number
    imul eax, eax, 10
    add eax, edx
    inc rdi
    inc ecx
    jmp .digits
.have_number:
    cmp rdi, rsi
    jae .whole
    cmp byte [rdi], ':'
    jne .whole
.time:                              ; hh:mm:ss is not needed
    cmp rdi, rsi
    jae .token
    cmp byte [rdi], ' '
    je .token
    inc rdi
    jmp .time
.whole:
    cmp ecx, 3
    jae .year
    test r9d, r9d
    jnz .two_digit_year
    mov r9d, eax
    jmp .token
.two_digit_year:
    add eax, 1900
    cmp eax, 1970
    jae .year
    add eax, 100
.year:
    mov r11d, eax
    jmp .token
.skip:
    inc rdi
    jmp .token
.parsed:
    test r11d, r11d
    jz .no                          ; not a date we can read: keep it
    call rtc_read
    movzx eax, word [rtc_year]
    cmp r11d, eax
    jb .yes
    ja .no
    movzx eax, byte [rtc_month]
    cmp r10d, eax
    jb .yes
    ja .no
    movzx eax, byte [rtc_day]
    cmp r9d, eax
    jb .yes
.no:
    clc
    jmp .out
.yes:
    stc
.out:
    pop r11
    pop r10
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; cookie_store: cookie_new -> in the jar (instead of one with its name, domain
; and path), or that one deleted if cookie_expired
; ------------------------------------------------------------------------------
cookie_store:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    lea rsi, [cookie_new]
    ; the same cookie already there?
    lea rbx, [cookie_jar]
    mov ecx, COOKIE_MAX
.find:
    test byte [rbx + CK_FLAGS], CKF_USED
    jz .find_next
    mov ax, [rbx + CK_NLEN]
    cmp ax, [rsi + CK_NLEN]
    jne .find_next
    mov al, [rbx + CK_DLEN]
    cmp al, [rsi + CK_DLEN]
    jne .find_next
    mov al, [rbx + CK_PLEN]
    cmp al, [rsi + CK_PLEN]
    jne .find_next
    push rcx
    push rsi
    lea rdi, [rbx + CK_NAME]
    add rsi, CK_NAME
    movzx ecx, word [rbx + CK_NLEN]
    repe cmpsb
    jne .differs
    lea rdi, [rbx + CK_DOMAIN]
    mov rsi, [rsp]
    add rsi, CK_DOMAIN
    movzx ecx, byte [rbx + CK_DLEN]
    repe cmpsb
    jne .differs
    lea rdi, [rbx + CK_PATH]
    mov rsi, [rsp]
    add rsi, CK_PATH
    movzx ecx, byte [rbx + CK_PLEN]
    repe cmpsb
.differs:
    pop rsi
    pop rcx
    je .found
.find_next:
    add rbx, COOKIE_SIZE
    dec ecx
    jnz .find
    ; a new one: a free entry, else the next one round the jar
    cmp byte [cookie_expired], 0
    jne .done
    lea rbx, [cookie_jar]
    mov ecx, COOKIE_MAX
.free:
    test byte [rbx + CK_FLAGS], CKF_USED
    jz .put
    add rbx, COOKIE_SIZE
    dec ecx
    jnz .free
    mov eax, [cookie_next]
    inc dword [cookie_next]
    and dword [cookie_next], COOKIE_MAX - 1
    imul eax, eax, COOKIE_SIZE
    lea rbx, [cookie_jar]
    add rbx, rax
    jmp .put
.found:
    cmp byte [cookie_expired], 0
    je .put
    mov byte [rbx + CK_FLAGS], 0
    lea rsi, [klog_cookie_del]
    jmp .log
.put:
    mov rdi, rbx
    mov ecx, COOKIE_SIZE / 8
    rep movsq
    lea rsi, [klog_cookie_set]
.log:
    ; "[klog] cookie: set name" / "deleted name"
    push rsi
    lea rsi, [rbx + CK_NAME]
    lea rdi, [cookie_page_buf]
    movzx ecx, word [rbx + CK_NLEN]
    rep movsb
    mov byte [rdi], 0
    pop rsi
    lea rdi, [cookie_page_buf]
    call klog2
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; cookie_page_get: -> RSI/ECX = document.cookie ("a=1; b=2", no HttpOnly ones)
; ------------------------------------------------------------------------------
cookie_page_get:
    push rdx
    push rdi
    call cookie_page
    lea rdi, [cookie_page_buf]
    lea rdx, [rdi + COOKIE_HEADER_MAX - 1]
    mov byte [cookie_script], 1
    call cookie_list
    mov byte [cookie_script], 0
    lea rsi, [cookie_page_buf]
    mov rcx, rdi
    sub rcx, rsi
    pop rdi
    pop rdx
    ret

; cookie_page_set: RSI/ECX = what a script assigned to document.cookie -> stored
cookie_page_set:
    call cookie_page
    mov byte [cookie_script], 1
    call cookie_set
    mov byte [cookie_script], 0
    ret
