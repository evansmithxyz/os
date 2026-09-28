; ==============================================================================
; Antigravity OS - CyberSurf Web Browser window
; ------------------------------------------------------------------------------
; A tiny HTML renderer (h1-h3, p, b, br, hr, ul/li, code, a href) with
; navigation for:
;   http://antigravity.os/...   built-in pages (home, demo, live telemetry)
;   afs://<file>                files on the AntigravityFS disk
;   http://host[:port]/path     real HTTP/1.0 over the kernel's TCP stack
;                               (host names are resolved with DNS)
; Drawing uses the window frame position (br_wx/br_wy/br_ww/br_wh), which the
; WIN_DRAW callback derives from the client rectangle.
; ==============================================================================

[bits 64]

BROWSER_URL_MAX         equ 96
BROWSER_PAGE_BUF_MAX    equ 131072
BROWSER_MAX_LINKS       equ 16
BROWSER_LINK_SIZE       equ 80      ; x1, y1, x2, y2 (dd) + 64-byte target URL
BROWSER_LOG_MAX         equ 80      ; visible text reported by "[klog] browser text:"
BROWSER_MAX_REDIRECTS   equ 5

; Colors for Browser UI
BROWSER_CLR_TOOLBAR     equ 0x00131D2E   ; Deep Navy Toolbar
BROWSER_CLR_URL_BG      equ 0x000A0E17   ; Address Bar Background
BROWSER_CLR_URL_BORDER  equ 0x00334155   ; Unfocused Address Bar Border
BROWSER_CLR_URL_ACT     equ 0x0000F0FF   ; Focused Address Bar Border (Cyan)
BROWSER_CLR_BOOKMARK_BG equ 0x001E293B   ; Bookmark Pill Background
BROWSER_CLR_PAGE_BG     equ 0x00070A0F   ; Webpage Viewport Dark Canvas
BROWSER_CLR_STATUS_BG   equ 0x000B1120   ; Status Bar Background

section .data
browser_ready:          db 0
browser_pending_nav:    db 0        ; navigate to browser_url_buf when opened
browser_url_focused:    db 0        ; 1 = URL bar has keyboard focus
browser_in_link:        db 0
browser_href_set:       db 0        ; current <a> tag had an href
browser_log_text:       db 0        ; 1 = next render logs the page's first text
browser_page_tls:       db 0        ; 1 = page came over TLS; certificate NOT verified
browser_redirects:      db 0        ; redirects followed for the current navigation
align 4
browser_log_len:        dd 0
browser_log_y:          dd 0        ; y of the last logged glyph
browser_url_len:        dd 0
browser_link_count:     dd 0
browser_page_len:       dd 0
browser_cur_x:          dd 0
browser_cur_y:          dd 0
browser_text_color:     dd 0x00E2E8F0
browser_vp_x:           dd 0
browser_vp_y:           dd 0
browser_vp_w:           dd 0
browser_vp_h:           dd 0
browser_link_x1:        dd 0
browser_link_y1:        dd 0
br_wx:                  dd 0        ; window frame geometry for the current draw
br_wy:                  dd 0
br_ww:                  dd 0
br_wh:                  dd 0
align 8
browser_parse_ptr:      dq 0

section .bss
alignb 16
browser_url_buf:        resb BROWSER_URL_MAX
browser_prev_url:       resb BROWSER_URL_MAX
browser_page_title:     resb 64
browser_status_text:    resb 96
browser_temp_href:      resb 64
browser_scratch:        resb 160
browser_redirect_buf:   resb 384    ; [0] built URL, [256] Location value
browser_log_buf:        resb BROWSER_LOG_MAX + 2
browser_links:          resb BROWSER_MAX_LINKS * BROWSER_LINK_SIZE
browser_page_buf:       resb BROWSER_PAGE_BUF_MAX + 1

section .text
; ==============================================================================
; Window callbacks
; ==============================================================================

; browser_draw: WIN_DRAW callback (ECX,EDX = client x,y  ESI,R8D = client w,h)
browser_draw:
    lea eax, [ecx - WIN_BORDER]
    mov [br_wx], eax
    lea eax, [edx - TITLE_H]
    mov [br_wy], eax
    lea eax, [esi + WIN_BORDER * 2]
    mov [br_ww], eax
    lea eax, [r8d + TITLE_H + WIN_BORDER]
    mov [br_wh], eax
    jmp browser_draw_window

; browser_mouse: WIN_MOUSE callback - only presses matter
browser_mouse:
    cmp al, WM_MOUSE_PRESS
    jne .ret
    call browser_handle_click
.ret:
    ret

; browser_key: WIN_KEY callback - typing edits the address bar
browser_key:
    test al, al
    jz .unused
    cmp al, 0x0D
    je .enter
    cmp al, 0x08
    je .backspace
    cmp al, 32
    jb .unused
    cmp al, 126
    ja .unused
    mov byte [browser_url_focused], 1
    mov ecx, [browser_url_len]
    cmp ecx, BROWSER_URL_MAX - 2
    jae .used
    lea rdi, [browser_url_buf]
    mov [rdi + rcx], al
    mov byte [rdi + rcx + 1], 0
    inc dword [browser_url_len]
    jmp .used
.backspace:
    mov byte [browser_url_focused], 1
    mov ecx, [browser_url_len]
    test ecx, ecx
    jz .used
    dec ecx
    mov [browser_url_len], ecx
    lea rdi, [browser_url_buf]
    mov byte [rdi + rcx], 0
    jmp .used
.enter:
    mov byte [browser_url_focused], 0
    call browser_navigate
.used:
    stc
    ret
.unused:
    clc
    ret

; browser_open: WIN_OPEN callback (window opened from the closed state)
browser_open:
    cmp byte [browser_pending_nav], 0
    je .ret
    call browser_navigate
.ret:
    ret

; ==============================================================================
; Navigation
; ==============================================================================

; ------------------------------------------------------------------------------
; browser_init: load the home page the first time the desktop starts, or the
; URL given to `browser <url>`
; ------------------------------------------------------------------------------
browser_init:
    cmp byte [browser_pending_nav], 0
    jne browser_navigate
    cmp byte [browser_ready], 0
    jne .ret
    mov byte [browser_ready], 1
    push rcx
    push rsi
    push rdi
    lea rdi, [browser_url_buf]
    lea rsi, [STR_URL_HOME]
    mov ecx, BROWSER_URL_MAX
    call strlcpy
    lea rdi, [browser_prev_url]
    call strlcpy
    pop rdi
    pop rsi
    pop rcx
    call browser_navigate
.ret:
    ret

; browser_set_url: RSI = URL (first word is used). Navigates now if the
; desktop is running, otherwise when the browser is next shown.
browser_set_url:
    push rax
    push rcx
    push rsi
    push rdi
    lea rdi, [browser_url_buf]
    mov ecx, BROWSER_URL_MAX
    call next_word
    mov byte [browser_pending_nav], 1
    mov byte [browser_ready], 1
    cmp byte [gui_running], 0
    je .done
    call browser_navigate
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; browser_set_page: RSI = HTML (copied), RDI = title, RDX = status text
browser_set_page:
    push rcx
    push rsi
    push rdi
    push rdx
    push rdi
    lea rdi, [browser_page_buf]
    mov ecx, BROWSER_PAGE_BUF_MAX + 1
    call strlcpy
    pop rsi
    lea rdi, [browser_page_title]
    mov ecx, 64
    call strlcpy
    mov rsi, rdx
    lea rdi, [browser_status_text]
    mov ecx, 96
    call strlcpy
    pop rdx
    pop rdi
    pop rsi
    pop rcx
    ret

; browser_show_status: RSI = status text; repaint now so it is visible while
; the network is busy
browser_show_status:
    push rcx
    push rdi
    lea rdi, [browser_status_text]
    mov ecx, 96
    call strlcpy
    pop rdi
    pop rcx
    cmp byte [gui_running], 0
    je .ret
    call gui_redraw
.ret:
    ret

; ------------------------------------------------------------------------------
; browser_navigate: load the page named in browser_url_buf
; ------------------------------------------------------------------------------
browser_navigate:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    mov byte [browser_pending_nav], 0
    mov byte [browser_page_tls], 0
    mov dword [browser_link_count], 0
    lea rsi, [browser_url_buf]
    call strlen
    mov [browser_url_len], eax

    ; remember the page we are leaving for the Back button
    lea rsi, [browser_page_url]
    lea rdi, [browser_prev_url]
    mov ecx, BROWSER_URL_MAX
    call strlcpy
    lea rsi, [browser_url_buf]
    lea rdi, [browser_page_url]
    call strlcpy

    lea rsi, [browser_url_buf]
    cmp byte [rsi], 0
    je .home
    lea rdi, [STR_PROTO_AFS]
    call str_has_prefix
    je .afs
    lea rdi, [STR_URL_HOME]
    call strcmp
    je .home
    lea rdi, [STR_URL_HOME_NOSLASH]
    call strcmp
    je .home
    lea rdi, [STR_URL_ABOUT]
    call strcmp
    je .home
    lea rdi, [STR_URL_DEMO]
    call strcmp
    je .demo
    lea rdi, [STR_URL_STATUS]
    call strcmp
    je .status
    call browser_fetch_http
    jmp .done

.home:
    lea rsi, [PAGE_HOME_HTML]
    lea rdi, [STR_TITLE_HOME]
    lea rdx, [STR_STATUS_200_HOME]
    call browser_set_page
    jmp .done
.demo:
    lea rsi, [PAGE_DEMO_HTML]
    lea rdi, [STR_TITLE_DEMO]
    lea rdx, [STR_STATUS_200_DEMO]
    call browser_set_page
    jmp .done
.status:
    call browser_build_status_page
    jmp .done

.afs:
    add rsi, 6                      ; skip "afs://"
    call fs_find_file
    test rax, rax
    jz .afs_missing
    lea rdi, [browser_page_buf]
    mov ecx, BROWSER_PAGE_BUF_MAX
    call fs_read_file
    lea rdi, [browser_page_buf]
    mov byte [rdi + rax], 0
    lea rsi, [browser_url_buf]
    lea rdi, [browser_page_title]
    mov ecx, 64
    call strlcpy
    lea rsi, [STR_STATUS_AFS_OK]
    lea rdi, [browser_status_text]
    mov ecx, 96
    call strlcpy
    jmp .done
.afs_missing:
    lea rsi, [PAGE_AFS_404_HTML]
    lea rdi, [STR_TITLE_404]
    lea rdx, [STR_STATUS_404]
    call browser_set_page
.done:
    mov byte [gui_dirty], 1
    mov byte [browser_log_text], 1  ; the next render reports the visible text
    mov dword [browser_log_len], 0
    mov byte [browser_log_buf], 0
    lea rsi, [klog_browser]         ; "[klog] browser: <title>" for tests
    lea rdi, [browser_page_title]
    call klog2
    lea rsi, [klog_browser_status]  ; "[klog] browser status: <status bar>"
    lea rdi, [browser_status_text]
    call klog2
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_fetch_http: GET browser_url_buf (http:// or https://) into the page
; buffer, following up to BROWSER_MAX_REDIRECTS redirects. An https:// page
; sets browser_page_tls: its certificate was NOT verified, which the address
; bar, the status bar and the badge all show.
; ------------------------------------------------------------------------------
browser_fetch_http:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    mov byte [browser_redirects], 0
.fetch:
    lea rsi, [browser_url_buf]
    call url_parse
    jc .bad_url
    cmp byte [net_present], 1
    jne .fail

    lea rsi, [STR_STATUS_RESOLVING]
    call browser_show_status
    lea rsi, [url_host]
    lea rdi, [url_ip]
    call net_resolve_host
    jc .dns_fail

    lea rsi, [STR_STATUS_CONNECTING]
    call browser_show_status
    mov byte [http_quiet], 1
    lea rsi, [url_ip]
    lea rdi, [url_host]
    movzx edx, word [url_port]
    lea r8, [url_path]
    cmp byte [url_https], 1
    je .https
    call tcp_http_client
    mov byte [http_quiet], 0
    test rax, rax
    jnz .fail
    jmp .fetched
.https:
    call tls_https_get
    mov byte [http_quiet], 0
    test rax, rax
    jnz .tls_fail
.fetched:
    cmp dword [http_resp_len], 0
    je .fail

    ; 3xx with a Location header: fetch the new URL instead
    cmp byte [browser_redirects], BROWSER_MAX_REDIRECTS
    jae .show
    call browser_redirect_target
    jc .show
    inc byte [browser_redirects]
    lea rsi, [klog_browser_redirect]
    lea rdi, [browser_url_buf]
    call klog2
    lea rsi, [browser_url_buf]
    lea rdi, [browser_page_url]
    mov ecx, BROWSER_URL_MAX
    call strlcpy
    call strlen
    mov [browser_url_len], eax
    jmp .fetch

.show:
    mov al, [url_https]
    mov [browser_page_tls], al

    ; Body = everything after the blank line that ends the headers
    lea rsi, [http_resp_buf]
.find_body:
    mov al, [rsi]
    test al, al
    jz .no_headers
    cmp dword [rsi], 0x0A0D0A0D     ; "\r\n\r\n"
    je .body4
    cmp word [rsi], 0x0A0A          ; "\n\n" (lenient)
    je .body2
    inc rsi
    jmp .find_body
.body4:
    add rsi, 2
.body2:
    add rsi, 2
    jmp .copy
.no_headers:
    lea rsi, [http_resp_buf]
.copy:
    lea rdi, [browser_page_buf]
    mov ecx, BROWSER_PAGE_BUF_MAX + 1
    call strlcpy

    ; Title "CyberSurf - host", status = [TLS warning] HTTP status line + host.
    ; Built in a scratch buffer, then copied with a bound (host names can be
    ; 63 chars).
    lea rdi, [browser_scratch]
    lea rsi, [STR_TITLE_PREFIX]
    call fmt_str
    lea rsi, [url_host]
    call fmt_str
    lea rsi, [browser_scratch]
    lea rdi, [browser_page_title]
    mov ecx, 64
    call strlcpy
    lea rdi, [browser_scratch]
    mov byte [rdi], 0
    cmp byte [browser_page_tls], 0
    je .status_start
    lea rsi, [STR_STATUS_UNVERIFIED]
    call fmt_str
.status_start:
    lea rsi, [http_resp_buf]
    xor ecx, ecx
.status_line:
    mov al, [rsi + rcx]
    cmp al, 0x0D
    je .status_end
    cmp al, 0x0A
    je .status_end
    test al, al
    jz .status_end
    mov [rdi + rcx], al
    inc ecx
    cmp ecx, 40
    jb .status_line
.status_end:
    add rdi, rcx
    mov byte [rdi], 0
    lea rsi, [STR_STATUS_SEP]
    call fmt_str
    lea rsi, [url_host]
    call fmt_str
    lea rsi, [browser_scratch]
    lea rdi, [browser_status_text]
    mov ecx, 96
    call strlcpy
    jmp .done

.bad_url:
    lea rsi, [PAGE_404_HTML]
    lea rdi, [STR_TITLE_404]
    lea rdx, [STR_STATUS_BAD_URL]
    call browser_set_page
    jmp .done
.dns_fail:
    lea rsi, [PAGE_CONN_FAIL_HTML]
    lea rdi, [STR_TITLE_FAIL]
    lea rdx, [STR_STATUS_DNS_FAIL]
    call browser_set_page
    jmp .done
.tls_fail:
    ; status = "Error: TLS <reason>"
    lea rdi, [browser_scratch]
    lea rsi, [STR_STATUS_TLS_FAIL]
    call fmt_str
    mov rsi, [tls_error_msg]
    call fmt_str
    lea rsi, [PAGE_TLS_FAIL_HTML]
    lea rdi, [STR_TITLE_TLS_FAIL]
    lea rdx, [browser_scratch]
    call browser_set_page
    jmp .done
.fail:
    mov byte [http_quiet], 0
    lea rsi, [PAGE_CONN_FAIL_HTML]
    lea rdi, [STR_TITLE_FAIL]
    lea rdx, [STR_STATUS_FAIL]
    call browser_set_page
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_redirect_target: if http_resp_buf is a 3xx response with a Location
; header, put the absolute target URL in browser_url_buf. A target starting
; with '/' is relative to the request (url_https, url_host, url_port).
; Output: CF=1 if there is nothing to follow (or the URL would not fit)
; ------------------------------------------------------------------------------
browser_redirect_target:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi

    lea rsi, [http_resp_buf]
    cmp dword [rsi], 'HTTP'
    jne .no
    cmp byte [rsi + 9], '3'         ; "HTTP/1.x 3xx"
    jne .no
.line:
    ; to the start of the next header line
    mov al, [rsi]
    test al, al
    jz .no
    inc rsi
    cmp al, 0x0A
    jne .line
    cmp byte [rsi], 0x0D            ; blank line: end of the headers
    je .no
    cmp byte [rsi], 0x0A
    je .no
    ; "location:" in any case
    lea rdi, [STR_HDR_LOCATION]
    xor ecx, ecx
.name:
    mov al, [rdi + rcx]
    test al, al
    jz .found
    mov dl, [rsi + rcx]
    cmp dl, 'A'
    jb .cmp_char
    cmp dl, 'Z'
    ja .cmp_char
    add dl, 32
.cmp_char:
    cmp dl, al
    jne .line
    inc ecx
    jmp .name
.found:
    add rsi, rcx
.skip_space:
    cmp byte [rsi], ' '
    jne .value
    inc rsi
    jmp .skip_space
.value:
    ; the value, up to the end of the line, into browser_redirect_buf + 256
    lea rdi, [browser_redirect_buf + 256]
    xor ecx, ecx
.value_char:
    mov al, [rsi + rcx]
    cmp al, ' '
    jbe .value_end                  ; CR, LF, NUL or space
    cmp ecx, 126
    jae .no                         ; too long for us
    mov [rdi + rcx], al
    inc ecx
    jmp .value_char
.value_end:
    mov byte [rdi + rcx], 0
    mov rsi, rdi
    lea rdi, [url_http_prefix]
    call str_has_prefix
    je .absolute
    lea rdi, [url_https_prefix]
    call str_has_prefix
    je .absolute
    cmp byte [rsi], '/'
    jne .no
    cmp byte [rsi + 1], '/'         ; "//host/path" is not supported
    je .no
    ; scheme://host[:port]path
    lea rdi, [browser_redirect_buf]
    push rsi
    lea rsi, [url_http_prefix]
    mov edx, 80
    cmp byte [url_https], 0
    je .scheme
    lea rsi, [url_https_prefix]
    mov edx, 443
.scheme:
    call fmt_str
    lea rsi, [url_host]
    call fmt_str
    movzx eax, word [url_port]
    cmp eax, edx
    je .default_port
    push rax
    mov al, ':'
    call fmt_char
    pop rax
    call fmt_dec
.default_port:
    pop rsi
    call fmt_str
    lea rsi, [browser_redirect_buf]
.absolute:
    call strlen
    cmp eax, BROWSER_URL_MAX - 1
    jae .no
    lea rdi, [browser_url_buf]
    mov ecx, BROWSER_URL_MAX
    call strlcpy
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.no:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; browser_build_status_page: live telemetry as HTML
; ------------------------------------------------------------------------------
browser_build_status_page:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    lea rdi, [browser_page_buf]
    lea rsi, [TELEM_HEAD]
    call fmt_str
    lea rsi, [TELEM_CPU]
    call fmt_str
    call cpu_get_brand
    call fmt_str
    lea rsi, [TELEM_RAM]
    call fmt_str
    call memory_total_mb
    call fmt_dec
    lea rsi, [TELEM_MB]
    call fmt_str
    lea rsi, [TELEM_UPTIME]
    call fmt_str
    call fmt_uptime
    lea rsi, [TELEM_DISK]
    call fmt_str
    call fs_stats
    call fmt_dec
    lea rsi, [TELEM_FILES]
    call fmt_str
    lea rsi, [TELEM_IP]
    call fmt_str
    lea rsi, [net_ip]
    call fmt_ip
    lea rsi, [TELEM_SLASH]
    call fmt_str
    lea rsi, [net_netmask]
    call fmt_ip
    lea rsi, [TELEM_GW]
    call fmt_str
    lea rsi, [net_gateway]
    call fmt_ip
    lea rsi, [TELEM_DNS]
    call fmt_str
    lea rsi, [net_dns]
    call fmt_ip
    lea rsi, [TELEM_PACKETS]
    call fmt_str
    mov rax, [net_packets_rx]
    call fmt_dec
    lea rsi, [TELEM_TX]
    call fmt_str
    mov rax, [net_packets_tx]
    call fmt_dec
    lea rsi, [TELEM_TAIL]
    call fmt_str
    lea rsi, [STR_TITLE_STATUS]
    lea rdi, [browser_page_title]
    mov ecx, 64
    call strlcpy
    lea rsi, [STR_STATUS_200_STATUS]
    lea rdi, [browser_status_text]
    mov ecx, 96
    call strlcpy
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

section .bss
browser_page_url:       resb BROWSER_URL_MAX    ; URL of the page on screen

section .text

; ------------------------------------------------------------------------------
; browser_draw_window: toolbar, address bar, bookmarks, page and status bar
; (inside the frame described by br_wx/br_wy/br_ww/br_wh)
; ------------------------------------------------------------------------------
browser_draw_window:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10


    ; 2. Navigation Toolbar Panel (y: br_wy + 28, h: 26)
    mov ecx, [br_wx]
    add ecx, 2
    mov edx, [br_wy]
    add edx, 28
    mov esi, [br_ww]
    sub esi, 4
    mov r8d, 26
    mov eax, BROWSER_CLR_TOOLBAR
    call gfx_fill_rect

    ; Toolbar bottom divider
    mov ecx, [br_wx]
    add ecx, 2
    mov edx, [br_wy]
    add edx, 54
    mov esi, [br_ww]
    sub esi, 4
    mov r8d, 1
    mov eax, 0x001E293B
    call gfx_fill_rect

    ; Nav Button: [ < ] Back
    mov ecx, [br_wx]
    add ecx, 10
    mov edx, [br_wy]
    add edx, 32
    mov esi, 24
    mov r8d, 18
    mov eax, 0x001E293B
    call gfx_fill_rect
    mov ecx, [br_wx]
    add ecx, 18
    mov edx, [br_wy]
    add edx, 37
    lea rsi, [STR_BTN_BACK]
    mov eax, THEME_TEXT
    mov ebx, -1
    call gfx_print_string

    ; Nav Button: [ > ] Forward
    mov ecx, [br_wx]
    add ecx, 38
    mov edx, [br_wy]
    add edx, 32
    mov esi, 24
    mov r8d, 18
    mov eax, 0x001E293B
    call gfx_fill_rect
    mov ecx, [br_wx]
    add ecx, 46
    mov edx, [br_wy]
    add edx, 37
    lea rsi, [STR_BTN_FWD]
    mov eax, THEME_TEXT_MUTED
    mov ebx, -1
    call gfx_print_string

    ; Nav Button: [ R ] Reload
    mov ecx, [br_wx]
    add ecx, 66
    mov edx, [br_wy]
    add edx, 32
    mov esi, 24
    mov r8d, 18
    mov eax, 0x001E293B
    call gfx_fill_rect
    mov ecx, [br_wx]
    add ecx, 74
    mov edx, [br_wy]
    add edx, 37
    lea rsi, [STR_BTN_RELOAD]
    mov eax, THEME_CYAN
    mov ebx, -1
    call gfx_print_string

    ; Nav Button: [ Home ]
    mov ecx, [br_wx]
    add ecx, 94
    mov edx, [br_wy]
    add edx, 32
    mov esi, 44
    mov r8d, 18
    mov eax, 0x001E293B
    call gfx_fill_rect
    mov ecx, [br_wx]
    add ecx, 100
    mov edx, [br_wy]
    add edx, 37
    lea rsi, [STR_BTN_HOME]
    mov eax, THEME_TEXT
    mov ebx, -1
    call gfx_print_string

    ; Address / URL Bar Input Box
    mov ecx, [br_wx]
    add ecx, 144
    mov edx, [br_wy]
    add edx, 32
    mov esi, [br_ww]
    sub esi, 204                 ; Leave room for [ Go ] button
    mov r8d, 18
    mov eax, BROWSER_CLR_URL_BG
    call gfx_fill_rect

    ; Address Bar Border
    mov ecx, [br_wx]
    add ecx, 144
    mov edx, [br_wy]
    add edx, 32
    mov esi, [br_ww]
    sub esi, 204
    mov r8d, 18
    cmp byte [browser_url_focused], 1
    je .url_act_border
    mov eax, BROWSER_CLR_URL_BORDER
    jmp .draw_url_bdr
.url_act_border:
    mov eax, BROWSER_CLR_URL_ACT
.draw_url_bdr:
    call gfx_draw_rect

    ; URL Lock Icon / Prefix
    mov ecx, [br_wx]
    add ecx, 150
    mov edx, [br_wy]
    add edx, 37
    lea rsi, [STR_URL_ICON]
    mov eax, THEME_GREEN
    cmp byte [browser_page_tls], 0
    je .url_icon
    lea rsi, [STR_URL_ICON_TLS]     ; encrypted, but the server is not verified
    mov eax, THEME_YELLOW
.url_icon:
    mov ebx, -1
    call gfx_print_string

    ; URL Text
    mov ecx, [br_wx]
    add ecx, 172
    mov edx, [br_wy]
    add edx, 37
    lea rsi, [browser_url_buf]
    mov eax, THEME_TEXT
    mov ebx, -1
    call gfx_print_string

    ; URL Cursor (if URL bar focused)
    cmp byte [browser_url_focused], 1
    jne .skip_url_cursor
    mov ecx, [br_wx]
    add ecx, 172
    mov eax, [browser_url_len]
    shl eax, 3                  ; len * 8
    add ecx, eax
    mov edx, [br_wy]
    add edx, 36
    mov esi, 8
    mov r8d, 10
    mov eax, THEME_CYAN
    call gfx_fill_rect
.skip_url_cursor:

    ; [ Go ] Button
    mov ecx, [br_wx]
    add ecx, [br_ww]
    sub ecx, 54
    mov edx, [br_wy]
    add edx, 32
    mov esi, 44
    mov r8d, 18
    mov eax, THEME_ACCENT
    call gfx_fill_rect
    mov ecx, [br_wx]
    add ecx, [br_ww]
    sub ecx, 42
    mov edx, [br_wy]
    add edx, 37
    lea rsi, [STR_BTN_GO]
    mov eax, THEME_TEXT
    mov ebx, -1
    call gfx_print_string

    ; 3. Bookmarks Bar (y: br_wy + 55, h: 22)
    mov ecx, [br_wx]
    add ecx, 2
    mov edx, [br_wy]
    add edx, 55
    mov esi, [br_ww]
    sub esi, 4
    mov r8d, 22
    mov eax, 0x000F172A
    call gfx_fill_rect

    ; Bookmark 1: [ Portal ]
    mov ecx, [br_wx]
    add ecx, 10
    mov edx, [br_wy]
    add edx, 58
    mov esi, 64
    mov r8d, 16
    mov eax, BROWSER_CLR_BOOKMARK_BG
    call gfx_fill_rect
    mov ecx, [br_wx]
    add ecx, 16
    mov edx, [br_wy]
    add edx, 62
    lea rsi, [STR_BM_PORTAL]
    mov eax, THEME_TEXT
    mov ebx, -1
    call gfx_print_string

    ; Bookmark 2: [ Demo HTML ]
    mov ecx, [br_wx]
    add ecx, 80
    mov edx, [br_wy]
    add edx, 58
    mov esi, 78
    mov r8d, 16
    mov eax, BROWSER_CLR_BOOKMARK_BG
    call gfx_fill_rect
    mov ecx, [br_wx]
    add ecx, 86
    mov edx, [br_wy]
    add edx, 62
    lea rsi, [STR_BM_DEMO]
    mov eax, THEME_TEXT
    mov ebx, -1
    call gfx_print_string

    ; Bookmark 3: [ Telemetry ]
    mov ecx, [br_wx]
    add ecx, 164
    mov edx, [br_wy]
    add edx, 58
    mov esi, 80
    mov r8d, 16
    mov eax, BROWSER_CLR_BOOKMARK_BG
    call gfx_fill_rect
    mov ecx, [br_wx]
    add ecx, 170
    mov edx, [br_wy]
    add edx, 62
    lea rsi, [STR_BM_STATUS]
    mov eax, THEME_TEXT
    mov ebx, -1
    call gfx_print_string

    ; Bookmark 4: [ AFS Docs ]
    mov ecx, [br_wx]
    add ecx, 250
    mov edx, [br_wy]
    add edx, 58
    mov esi, 75
    mov r8d, 16
    mov eax, BROWSER_CLR_BOOKMARK_BG
    call gfx_fill_rect
    mov ecx, [br_wx]
    add ecx, 256
    mov edx, [br_wy]
    add edx, 62
    lea rsi, [STR_BM_AFS]
    mov eax, THEME_TEXT
    mov ebx, -1
    call gfx_print_string

    ; Bookmark 5: [ Host Web ]
    mov ecx, [br_wx]
    add ecx, 331
    mov edx, [br_wy]
    add edx, 58
    mov esi, 75
    mov r8d, 16
    mov eax, BROWSER_CLR_BOOKMARK_BG
    call gfx_fill_rect
    mov ecx, [br_wx]
    add ecx, 337
    mov edx, [br_wy]
    add edx, 62
    lea rsi, [STR_BM_HOST]
    mov eax, THEME_TEXT
    mov ebx, -1
    call gfx_print_string

    ; 4. Webpage Viewport Area
    mov ecx, [br_wx]
    add ecx, 4
    mov edx, [br_wy]
    add edx, 78
    mov esi, [br_ww]
    sub esi, 8
    mov r8d, [br_wh]
    sub r8d, 102
    mov eax, BROWSER_CLR_PAGE_BG
    call gfx_fill_rect

    ; Viewport Inner Border
    mov ecx, [br_wx]
    add ecx, 4
    mov edx, [br_wy]
    add edx, 78
    mov esi, [br_ww]
    sub esi, 8
    mov r8d, [br_wh]
    sub r8d, 102
    mov eax, 0x001E293B
    call gfx_draw_rect

    ; 5. Parse and Render HTML Page into Viewport
    call browser_render_html_page

    ; 6. Status Bar Panel (Bottom of browser window)
    mov ecx, [br_wx]
    add ecx, 2
    mov edx, [br_wy]
    add edx, [br_wh]
    sub edx, 22
    mov esi, [br_ww]
    sub esi, 4
    mov r8d, 20
    mov eax, BROWSER_CLR_STATUS_BG
    call gfx_fill_rect

    ; Status Bar Top Line
    mov ecx, [br_wx]
    add ecx, 2
    mov edx, [br_wy]
    add edx, [br_wh]
    sub edx, 22
    mov esi, [br_ww]
    sub esi, 4
    mov r8d, 1
    mov eax, 0x001E293B
    call gfx_fill_rect

    ; Status text
    mov ecx, [br_wx]
    add ecx, 12
    mov edx, [br_wy]
    add edx, [br_wh]
    sub edx, 16
    lea rsi, [browser_status_text]
    mov eax, THEME_GREEN
    cmp byte [browser_page_tls], 0
    je .status_color
    mov eax, THEME_YELLOW
.status_color:
    mov ebx, -1
    call gfx_print_string

    ; Protocol badge on right
    mov ecx, [br_wx]
    add ecx, [br_ww]
    sub ecx, 130
    mov edx, [br_wy]
    add edx, [br_wh]
    sub edx, 16
    lea rsi, [STR_STATUS_BADGE]
    mov eax, THEME_TEXT_MUTED
    cmp byte [browser_page_tls], 0
    je .badge
    lea rsi, [STR_BADGE_UNVERIFIED]
    mov eax, THEME_RED
.badge:
    mov ebx, -1
    call gfx_print_string

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
; browser_render_html_page: Tokenizes and renders HTML from browser_page_buf
; ------------------------------------------------------------------------------
browser_render_html_page:
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
    push r13

    ; Viewport boundaries
    mov eax, [br_wx]
    add eax, 6
    mov [browser_vp_x], eax

    mov eax, [br_wy]
    add eax, 80
    mov [browser_vp_y], eax

    mov eax, [br_ww]
    sub eax, 12
    mov [browser_vp_w], eax

    mov eax, [br_wh]
    sub eax, 104
    mov [browser_vp_h], eax

    ; Initial parser state
    mov eax, [browser_vp_x]
    add eax, 20
    mov [browser_cur_x], eax

    mov eax, [browser_vp_y]
    add eax, 16
    mov [browser_cur_y], eax

    mov dword [browser_text_color], 0x00CBD5E1 ; Light slate grey
    mov dword [browser_link_count], 0
    mov byte [browser_in_link], 0

    lea r12, [browser_page_buf]

.parse_loop:
    mov al, [r12]
    test al, al
    jz .render_complete
    inc r12

    ; Check for Tag open '<'
    cmp al, '<'
    je .handle_tag

    ; Check for Newline '\n'
    cmp al, 0x0A
    je .handle_newline

    ; Check for Carriage Return '\r'
    cmp al, 0x0D
    je .parse_loop

    cmp al, '&'
    je .entity

    ; Regular Printable ASCII Character (32 .. 126)
    cmp al, 32
    jb .parse_loop
    cmp al, 126
    ja .parse_loop

.printable:
    ; Line wrap check: cur_x + 8 > right_margin
    mov ecx, [browser_cur_x]
    add ecx, 8
    mov edx, [browser_vp_x]
    add edx, [browser_vp_w]
    sub edx, 24
    cmp ecx, edx
    jle .draw_char

    ; Wrap line!
    mov ecx, [browser_vp_x]
    add ecx, 20
    mov [browser_cur_x], ecx
    add dword [browser_cur_y], 14

.draw_char:
    ; Vertical bound check: cur_y + 10 > bottom_margin
    mov edx, [browser_cur_y]
    add edx, 10
    mov ebx, [browser_vp_y]
    add ebx, [browser_vp_h]
    sub ebx, 10
    cmp edx, ebx
    jge .render_complete

    ; Render single glyph (AL already holds ASCII character)
    call browser_log_char
    mov ecx, [browser_cur_x]      ; ECX = X
    mov edx, [browser_cur_y]      ; EDX = Y
    mov esi, [browser_text_color] ; ESI = FG Color
    mov r8d, -1                   ; R8D = Transparent background
    call gfx_draw_char

    add dword [browser_cur_x], 8
    jmp .parse_loop

.entity:
    ; "&name;" from browser_entities becomes its character; anything else
    ; is drawn as a plain '&'
    lea rsi, [browser_entities]
.ent_next:
    movzx ecx, byte [rsi]           ; length of the name, including ';'
    test ecx, ecx
    jz .ent_unknown
    inc rsi
    xor edx, edx
.ent_cmp:
    mov bl, [r12 + rdx]
    cmp bl, [rsi + rdx]
    jne .ent_skip
    inc edx
    cmp edx, ecx
    jb .ent_cmp
    mov al, [rsi + rcx]             ; the character it stands for
    add r12, rcx
    jmp .printable
.ent_skip:
    lea rsi, [rsi + rcx + 1]
    jmp .ent_next
.ent_unknown:
    mov al, '&'
    jmp .printable

.handle_newline:
    mov ecx, [browser_vp_x]
    add ecx, 20
    mov [browser_cur_x], ecx
    add dword [browser_cur_y], 14
    jmp .parse_loop

.handle_tag:
    ; <!-- comment --> is skipped whole (it may contain '>' and text)
    cmp byte [r12], '!'
    jne .tag_name
    cmp word [r12 + 1], '--'
    jne .tag_name
.skip_comment:
    mov al, [r12]
    test al, al
    jz .render_complete
    inc r12
    cmp al, '-'
    jne .skip_comment
    cmp word [r12], '->'
    jne .skip_comment
    add r12, 2
    jmp .parse_loop

.tag_name:
    ; Read tag name until space or '>' (cleared first: "a < b" must not
    ; re-run the previous tag)
    mov byte [browser_href_set], 0
    lea rdi, [browser_temp_href]
    mov qword [rdi], 0
    mov qword [rdi + 8], 0
    xor ecx, ecx
.read_tag_name:
    mov al, [r12]
    test al, al
    jz .render_complete
    inc r12
    cmp al, '>'
    je .eval_tag
    cmp al, ' '
    je .skip_tag_attrs
    ; Convert to lowercase
    cmp al, 'A'
    jb .store_tag_char
    cmp al, 'Z'
    ja .store_tag_char
    add al, 32
.store_tag_char:
    cmp ecx, 15
    jae .read_tag_name
    mov [rdi + rcx], al
    inc ecx
    mov byte [rdi + rcx], 0
    jmp .read_tag_name

.skip_tag_attrs:
    ; If tag is 'a', scan for href="..."
    cmp byte [browser_temp_href], 'a'
    jne .drain_tag
    ; Extract href target
.scan_href:
    mov al, [r12]
    test al, al
    jz .render_complete
    inc r12
    cmp al, '>'
    je .eval_tag
    cmp al, 'h'
    jne .scan_href
    cmp byte [r12], 'r'
    jne .scan_href
    cmp byte [r12 + 1], 'e'
    jne .scan_href
    cmp byte [r12 + 2], 'f'
    jne .scan_href
    add r12, 3
    ; Find quote
.find_q:
    mov al, [r12]
    test al, al
    jz .render_complete
    inc r12
    cmp al, '>'
    je .eval_tag
    cmp al, '"'
    je .copy_href
    cmp al, "'"
    je .copy_href
    jmp .find_q

.copy_href:
    ; Copy URL into link table slot if room
    mov edx, [browser_link_count]
    cmp edx, BROWSER_MAX_LINKS
    jae .drain_tag
    imul edx, BROWSER_LINK_SIZE
    lea rdi, [browser_links + 16]
    add rdi, rdx
    xor ecx, ecx
.href_loop:
    mov al, [r12]
    test al, al
    jz .eval_tag
    inc r12
    cmp al, '"'
    je .href_done
    cmp al, "'"
    je .href_done
    cmp ecx, 62
    jae .href_loop
    mov [rdi + rcx], al
    inc ecx
    mov byte [rdi + rcx], 0
    jmp .href_loop
.href_done:
    mov byte [browser_href_set], 1
    jmp .drain_tag

.drain_tag:
    mov al, [r12]
    test al, al
    jz .render_complete
    inc r12
    cmp al, '>'
    jne .drain_tag

.eval_tag:
    ; Check tag in browser_temp_href
    ; 0. <script>, <style> and <title> hold no visible text: skip to the end tag
    lea rsi, [browser_temp_href]
    lea rdi, [STR_TAG_SCRIPT]
    call strcmp
    je .skip_raw
    lea rdi, [STR_TAG_STYLE]
    call strcmp
    je .skip_raw
    lea rdi, [STR_TAG_TITLE]
    call strcmp
    jne .chk_head
.skip_raw:
    ; RDI = tag name: find "</name" in any case, then its '>'
    mov al, [r12]
    test al, al
    jz .render_complete
    inc r12
    cmp al, '<'
    jne .skip_raw
    cmp byte [r12], '/'
    jne .skip_raw
    xor ecx, ecx
.raw_cmp:
    mov al, [rdi + rcx]
    test al, al
    jz .drain_end_tag
    mov dl, [r12 + rcx + 1]
    or dl, 0x20                     ; lower case
    cmp dl, al
    jne .skip_raw
    inc ecx
    jmp .raw_cmp

.chk_head:
    ; Skip <head>...</head>. When "</head>" is not in the buffer, parse the
    ; head normally instead of rendering nothing.
    cmp dword [browser_temp_href], 0x64616568 ; "head" (exactly: not "header")
    jne .chk_div
    cmp byte [browser_temp_href + 4], 0
    jne .chk_div
    mov r13, r12                    ; just after <head>
.skip_head:
    mov al, [r12]
    test al, al
    jz .no_head_end
    inc r12
    cmp al, '<'
    jne .skip_head
    cmp byte [r12], '/'
    jne .skip_head
    cmp dword [r12 + 1], 0x64616568 ; "/head"
    jne .skip_head
    cmp byte [r12 + 5], '>'
    jne .skip_head
.drain_end_tag:
    mov al, [r12]
    test al, al
    jz .render_complete
    inc r12
    cmp al, '>'
    jne .drain_end_tag
    jmp .parse_loop
.no_head_end:
    mov r12, r13
    jmp .parse_loop

.chk_div:
    ; <div> and </div> start a new line unless already at the start of one
    lea rsi, [browser_temp_href]
    lea rdi, [STR_TAG_DIV]
    call strcmp
    je .block_break
    lea rdi, [STR_TAG_DIV_END]
    call strcmp
    jne .chk_h1
.block_break:
    mov eax, [browser_vp_x]
    add eax, 20
    cmp [browser_cur_x], eax
    jle .parse_loop
    mov [browser_cur_x], eax
    add dword [browser_cur_y], 14
    jmp .parse_loop

.chk_h1:
    ; 1. "h1"
    cmp word [browser_temp_href], 0x3168 ; "h1"
    jne .chk_h1_end
    mov eax, [browser_vp_x]
    add eax, 20
    mov [browser_cur_x], eax
    add dword [browser_cur_y], 8
    mov dword [browser_text_color], 0x0000F0FF ; Cyan
    jmp .parse_loop

.chk_h1_end:
    cmp byte [browser_temp_href], '/'
    jne .chk_h2
    cmp word [browser_temp_href + 1], 0x3168 ; "/h1"
    jne .chk_h2_end
    ; Draw cyan underline across heading
    mov ecx, [browser_vp_x]
    add ecx, 20
    mov edx, [browser_cur_y]
    add edx, 11
    mov esi, [browser_cur_x]
    sub esi, ecx
    mov r8d, 1
    mov eax, 0x0000F0FF
    call gfx_fill_rect

    mov eax, [browser_vp_x]
    add eax, 20
    mov [browser_cur_x], eax
    add dword [browser_cur_y], 18
    mov dword [browser_text_color], 0x00CBD5E1
    jmp .parse_loop

.chk_h2:
    cmp word [browser_temp_href], 0x3268 ; "h2"
    jne .chk_h2_end
    mov eax, [browser_vp_x]
    add eax, 20
    mov [browser_cur_x], eax
    add dword [browser_cur_y], 6
    mov dword [browser_text_color], 0x00F59E0B ; Amber
    jmp .parse_loop

.chk_h2_end:
    cmp byte [browser_temp_href], '/'
    jne .chk_h3
    cmp word [browser_temp_href + 1], 0x3268 ; "/h2"
    jne .chk_h3_end
    mov eax, [browser_vp_x]
    add eax, 20
    mov [browser_cur_x], eax
    add dword [browser_cur_y], 16
    mov dword [browser_text_color], 0x00CBD5E1
    jmp .parse_loop

.chk_h3:
    cmp word [browser_temp_href], 0x3368 ; "h3"
    jne .chk_h3_end
    mov eax, [browser_vp_x]
    add eax, 20
    mov [browser_cur_x], eax
    add dword [browser_cur_y], 4
    mov dword [browser_text_color], 0x0034D399 ; Emerald
    jmp .parse_loop

.chk_h3_end:
    cmp byte [browser_temp_href], '/'
    jne .chk_p
    cmp word [browser_temp_href + 1], 0x3368 ; "/h3"
    jne .chk_p
    mov eax, [browser_vp_x]
    add eax, 20
    mov [browser_cur_x], eax
    add dword [browser_cur_y], 14
    mov dword [browser_text_color], 0x00CBD5E1
    jmp .parse_loop

.chk_p:
    cmp word [browser_temp_href], 0x0070 ; "p"
    jne .chk_p_end
    mov eax, [browser_vp_x]
    add eax, 20
    mov [browser_cur_x], eax
    add dword [browser_cur_y], 4
    mov dword [browser_text_color], 0x00E2E8F0
    jmp .parse_loop

.chk_p_end:
    cmp word [browser_temp_href], 0x702F ; "/p"
    jne .chk_hr
    mov eax, [browser_vp_x]
    add eax, 20
    mov [browser_cur_x], eax
    add dword [browser_cur_y], 16
    mov dword [browser_text_color], 0x00CBD5E1
    jmp .parse_loop

.chk_hr:
    cmp word [browser_temp_href], 0x7268 ; "hr"
    jne .chk_br
    add dword [browser_cur_y], 8
    mov ecx, [browser_vp_x]
    add ecx, 20
    mov edx, [browser_cur_y]
    mov esi, [browser_vp_w]
    sub esi, 40
    mov r8d, 1
    mov eax, 0x001E293B
    call gfx_fill_rect

    mov eax, [browser_vp_x]
    add eax, 20
    mov [browser_cur_x], eax
    add dword [browser_cur_y], 10
    jmp .parse_loop

.chk_br:
    cmp word [browser_temp_href], 0x7262 ; "br"
    jne .chk_li
    mov eax, [browser_vp_x]
    add eax, 20
    mov [browser_cur_x], eax
    add dword [browser_cur_y], 14
    jmp .parse_loop

.chk_li:
    cmp word [browser_temp_href], 0x696C ; "li" (exactly: not "link")
    jne .chk_li_end
    cmp byte [browser_temp_href + 2], 0
    jne .chk_li_end
    mov eax, [browser_vp_x]
    add eax, 28
    mov [browser_cur_x], eax

    ; Draw cyan bullet dot
    mov ecx, [browser_cur_x]
    mov edx, [browser_cur_y]
    add edx, 3
    mov esi, 4
    mov r8d, 4
    mov eax, 0x0038BDF8
    call gfx_fill_rect
    add dword [browser_cur_x], 10
    mov dword [browser_text_color], 0x00E2E8F0
    jmp .parse_loop

.chk_li_end:
    cmp dword [browser_temp_href], 0x00696C2F ; "/li" (exactly: not "/label")
    jne .chk_b
    mov eax, [browser_vp_x]
    add eax, 20
    mov [browser_cur_x], eax
    add dword [browser_cur_y], 14
    mov dword [browser_text_color], 0x00CBD5E1
    jmp .parse_loop

.chk_b:
    cmp word [browser_temp_href], 0x0062 ; "b"
    jne .chk_b_end
    mov dword [browser_text_color], 0x00FFFFFF ; Bright white
    jmp .parse_loop

.chk_b_end:
    cmp word [browser_temp_href], 0x622F ; "/b"
    jne .chk_code
    mov dword [browser_text_color], 0x00CBD5E1
    jmp .parse_loop

.chk_code:
    cmp dword [browser_temp_href], 0x65646F63 ; "code"
    jne .chk_code_end
    mov eax, [browser_vp_x]
    add eax, 28
    mov [browser_cur_x], eax
    mov dword [browser_text_color], 0x0010B981 ; Emerald green code
    jmp .parse_loop

.chk_code_end:
    cmp byte [browser_temp_href], '/'
    jne .chk_a
    cmp dword [browser_temp_href + 1], 0x65646F63 ; "/code"
    jne .chk_a
    mov eax, [browser_vp_x]
    add eax, 20
    mov [browser_cur_x], eax
    add dword [browser_cur_y], 14
    mov dword [browser_text_color], 0x00CBD5E1
    jmp .parse_loop

.chk_a:
    cmp word [browser_temp_href], 0x0061 ; "a"
    jne .chk_a_end
    ; Starting hyperlink. An <a> without href must not inherit the URL a
    ; previous page left in this link slot.
    cmp byte [browser_href_set], 0
    jne .have_href
    mov edx, [browser_link_count]
    cmp edx, BROWSER_MAX_LINKS
    jae .have_href
    imul edx, BROWSER_LINK_SIZE
    lea rdi, [browser_links + 16]
    mov byte [rdi + rdx], 0
.have_href:
    mov byte [browser_in_link], 1
    mov eax, [browser_cur_x]
    mov [browser_link_x1], eax
    mov eax, [browser_cur_y]
    mov [browser_link_y1], eax
    mov dword [browser_text_color], 0x0038BDF8 ; Sky blue
    jmp .parse_loop

.chk_a_end:
    cmp word [browser_temp_href], 0x612F ; "/a"
    jne .parse_loop
    ; Completed hyperlink
    cmp byte [browser_in_link], 1
    jne .parse_loop
    mov byte [browser_in_link], 0

    ; Draw underline under link
    mov ecx, [browser_link_x1]
    mov edx, [browser_cur_y]
    add edx, 9
    mov esi, [browser_cur_x]
    sub esi, ecx
    mov r8d, 1
    mov eax, 0x0038BDF8
    call gfx_fill_rect

    ; Save link bounding box to browser_links table
    mov edx, [browser_link_count]
    cmp edx, BROWSER_MAX_LINKS
    jae .reset_link_color

    imul edx, BROWSER_LINK_SIZE
    lea rdi, [browser_links]
    add rdi, rdx
    mov eax, [browser_link_x1]
    mov [rdi + 0], eax
    mov eax, [browser_link_y1]
    mov [rdi + 4], eax
    mov eax, [browser_cur_x]
    mov [rdi + 8], eax
    mov eax, [browser_cur_y]
    add eax, 10
    mov [rdi + 12], eax

    inc dword [browser_link_count]

.reset_link_color:
    mov dword [browser_text_color], 0x00CBD5E1
    jmp .parse_loop

.render_complete:
    cmp byte [browser_log_text], 0
    je .restore
    mov byte [browser_log_text], 0
    lea rsi, [klog_browser_text]    ; "[klog] browser text: <first visible text>"
    lea rdi, [browser_log_buf]
    call klog2
.restore:
    pop r13
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
; browser_log_char: AL = glyph about to be drawn at browser_cur_y. While
; browser_log_text is set, collects the page's first visible text for the
; "[klog] browser text:" line: runs of spaces and line changes become one space.
; ------------------------------------------------------------------------------
browser_log_char:
    cmp byte [browser_log_text], 0
    je .ret
    push rcx
    push rdx
    push rdi
    lea rdi, [browser_log_buf]
    mov ecx, [browser_log_len]
    cmp ecx, BROWSER_LOG_MAX
    jae .done
    test ecx, ecx
    jz .check_space
    cmp byte [rdi + rcx - 1], ' '
    je .check_space
    mov edx, [browser_cur_y]
    cmp edx, [browser_log_y]
    je .check_space
    mov byte [rdi + rcx], ' '       ; new line
    inc ecx
    cmp al, ' '
    je .terminate                   ; that space stands in for this one
    jmp .store
.check_space:
    cmp al, ' '                     ; no leading or repeated spaces
    jne .store
    test ecx, ecx
    jz .done
    cmp byte [rdi + rcx - 1], ' '
    je .done
.store:
    mov [rdi + rcx], al
    inc ecx
.terminate:
    mov byte [rdi + rcx], 0
    mov [browser_log_len], ecx
    mov edx, [browser_cur_y]
    mov [browser_log_y], edx
.done:
    pop rdi
    pop rdx
    pop rcx
.ret:
    ret

; ------------------------------------------------------------------------------
; browser_handle_click: a click inside the browser window at [mouse_x],[mouse_y]
; ------------------------------------------------------------------------------
browser_handle_click:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov ecx, [mouse_x]
    mov edx, [mouse_y]

    ; 3. Check Nav Toolbar Buttons (y: br_wy + 30 .. br_wy + 52)
    mov eax, [br_wy]
    add eax, 30
    cmp edx, eax
    jl .chk_bookmarks
    add eax, 22
    cmp edx, eax
    jg .chk_bookmarks

    ; [ < ] Back Button (x: br_wx + 10 .. br_wx + 34)
    mov eax, [br_wx]
    add eax, 10
    cmp ecx, eax
    jl .chk_fwd
    add eax, 24
    cmp ecx, eax
    jg .chk_fwd
    ; Back clicked!
    lea rdi, [browser_url_buf]
    lea rsi, [browser_prev_url]
    mov ecx, BROWSER_URL_MAX
    call strlcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_fwd:
    ; [ R ] Reload Button (x: br_wx + 66 .. br_wx + 90)
    mov eax, [br_wx]
    add eax, 66
    cmp ecx, eax
    jl .chk_home
    add eax, 24
    cmp ecx, eax
    jg .chk_home
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_home:
    ; [ Home ] Button (x: br_wx + 94 .. br_wx + 138)
    mov eax, [br_wx]
    add eax, 94
    cmp ecx, eax
    jl .chk_url_bar
    add eax, 44
    cmp ecx, eax
    jg .chk_url_bar
    lea rdi, [browser_url_buf]
    lea rsi, [STR_URL_HOME]
    call strcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_url_bar:
    ; Address / URL Bar (x: br_wx + 144 .. br_wx + br_ww - 60)
    mov eax, [br_wx]
    add eax, 144
    cmp ecx, eax
    jl .chk_go_btn
    mov eax, [br_wx]
    add eax, [br_ww]
    sub eax, 60
    cmp ecx, eax
    jg .chk_go_btn
    ; Focused URL bar!
    mov byte [browser_url_focused], 1
    mov rax, 1
    jmp .browser_click_done

.chk_go_btn:
    ; [ Go ] Button (x: br_wx + br_ww - 54 .. br_wx + br_ww - 10)
    mov eax, [br_wx]
    add eax, [br_ww]
    sub eax, 54
    cmp ecx, eax
    jl .chk_bookmarks
    mov eax, [br_wx]
    add eax, [br_ww]
    sub eax, 10
    cmp ecx, eax
    jg .chk_bookmarks
    mov byte [browser_url_focused], 0
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_bookmarks:
    ; Unfocus URL bar if clicked outside
    mov byte [browser_url_focused], 0

    ; 4. Check Bookmarks Bar (y: br_wy + 55 .. br_wy + 76)
    mov eax, [br_wy]
    add eax, 55
    cmp edx, eax
    jl .chk_hyperlinks
    add eax, 22
    cmp edx, eax
    jg .chk_hyperlinks

    ; Bookmark 1: [ Portal ] (x: br_wx + 10 .. br_wx + 74)
    mov eax, [br_wx]
    add eax, 10
    cmp ecx, eax
    jl .chk_bm_demo
    add eax, 64
    cmp ecx, eax
    jg .chk_bm_demo
    lea rdi, [browser_url_buf]
    lea rsi, [STR_URL_HOME]
    call strcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_bm_demo:
    ; Bookmark 2: [ Demo HTML ] (x: br_wx + 80 .. br_wx + 158)
    mov eax, [br_wx]
    add eax, 80
    cmp ecx, eax
    jl .chk_bm_status
    add eax, 78
    cmp ecx, eax
    jg .chk_bm_status
    lea rdi, [browser_url_buf]
    lea rsi, [STR_URL_DEMO]
    call strcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_bm_status:
    ; Bookmark 3: [ Telemetry ] (x: br_wx + 164 .. br_wx + 244)
    mov eax, [br_wx]
    add eax, 164
    cmp ecx, eax
    jl .chk_bm_afs
    add eax, 80
    cmp ecx, eax
    jg .chk_bm_afs
    lea rdi, [browser_url_buf]
    lea rsi, [STR_URL_STATUS]
    call strcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_bm_afs:
    ; Bookmark 4: [ AFS Docs ] (x: br_wx + 250 .. br_wx + 325)
    mov eax, [br_wx]
    add eax, 250
    cmp ecx, eax
    jl .chk_bm_host
    add eax, 75
    cmp ecx, eax
    jg .chk_bm_host
    lea rdi, [browser_url_buf]
    lea rsi, [STR_URL_AFS_README]
    call strcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_bm_host:
    ; Bookmark 5: [ Host Web ] (x: br_wx + 331 .. br_wx + 406)
    mov eax, [br_wx]
    add eax, 331
    cmp ecx, eax
    jl .chk_hyperlinks
    add eax, 75
    cmp ecx, eax
    jg .chk_hyperlinks
    lea rdi, [browser_url_buf]
    lea rsi, [STR_URL_HOST]
    call strcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_hyperlinks:
    ; 5. Check Click on Page Hyperlinks in Viewport
    mov ebx, [browser_link_count]
    test ebx, ebx
    jz .body_handled

    xor eax, eax                ; i = 0 .. link_count - 1
.link_loop:
    cmp eax, ebx
    jge .body_handled

    mov esi, eax
    imul esi, BROWSER_LINK_SIZE
    lea rdi, [browser_links]
    add rdi, rsi

    ; Test X bounds (links[i].x1 .. links[i].x2)
    cmp ecx, [rdi + 0]
    jl .next_link
    cmp ecx, [rdi + 8]
    jg .next_link

    ; Test Y bounds (links[i].y1 .. links[i].y2)
    cmp edx, [rdi + 4]
    jl .next_link
    cmp edx, [rdi + 12]
    jg .next_link

    ; Link matched! Copy target URL and navigate!
    mov rsi, rdi
    add rsi, 16                 ; Target URL string
    lea rdi, [browser_url_buf]
    call strcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.next_link:
    inc eax
    jmp .link_loop

.body_handled:
    mov rax, 1
    jmp .browser_click_done

.browser_click_miss:
    xor rax, rax

.browser_click_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; Browser Strings & Built-in HTML Pages
; ------------------------------------------------------------------------------
section .rodata
browser_label:          db "Browser", 0
klog_browser:           db "browser: ", 0
klog_browser_status:    db "browser status: ", 0
klog_browser_text:      db "browser text: ", 0
STR_TAG_SCRIPT:         db "script", 0
STR_TAG_STYLE:          db "style", 0
STR_TAG_TITLE:          db "title", 0
STR_TAG_DIV:            db "div", 0
STR_TAG_DIV_END:        db "/div", 0

; HTML entities the renderer decodes: length of the name (with ';'), the
; name, the character it stands for. A zero length ends the table.
browser_entities:
    db 4, "amp;", '&'
    db 3, "lt;", '<'
    db 3, "gt;", '>'
    db 5, "quot;", '"'
    db 5, "apos;", "'"
    db 4, "#39;", "'"
    db 5, "nbsp;", ' '
    db 0
STR_URL_HOME:           db "http://antigravity.os/", 0
STR_URL_HOME_LEN        equ ($ - STR_URL_HOME - 1)
STR_URL_HOME_NOSLASH:   db "http://antigravity.os", 0
STR_URL_ABOUT:          db "about:home", 0
STR_URL_DEMO:           db "http://antigravity.os/demo.html", 0
STR_URL_STATUS:         db "http://antigravity.os/status", 0
STR_URL_HOST:           db "http://10.0.2.2/", 0
STR_URL_AFS_README:     db "afs://readme.txt", 0
STR_PROTO_AFS:          db "afs://", 0

STR_BTN_BACK:           db "<", 0
STR_BTN_FWD:            db ">", 0
STR_BTN_RELOAD:         db "R", 0
STR_BTN_HOME:           db "Home", 0
STR_BTN_GO:             db "Go", 0
STR_URL_ICON:           db "URL", 0

STR_BM_PORTAL:          db "Portal", 0
STR_BM_DEMO:            db "Demo HTML", 0
STR_BM_STATUS:          db "Telemetry", 0
STR_BM_AFS:             db "AFS Docs", 0
STR_BM_HOST:            db "Host Web", 0

STR_TITLE_HOME:         db "CyberSurf - Antigravity Portal", 0
STR_TITLE_DEMO:         db "CyberSurf - HTML Showcase Demo", 0
STR_TITLE_STATUS:       db "CyberSurf - Kernel Telemetry", 0
STR_TITLE_404:          db "CyberSurf - 404 Not Found", 0
STR_TITLE_FAIL:         db "CyberSurf - Connection Error", 0

STR_STATUS_200_HOME:    db "Done (HTTP 200 OK) | Antigravity Portal", 0
STR_STATUS_200_DEMO:    db "Done (HTTP 200 OK) | HTML Showcase Demo", 0
STR_STATUS_200_STATUS:  db "Done (HTTP 200 OK) | System Telemetry", 0
STR_STATUS_AFS_OK:      db "Done (AFS Volume Read) | Local Disk File", 0
STR_STATUS_404:         db "Error 404: Document Not Found", 0
STR_STATUS_FAIL:        db "Error: Remote Host Unreachable (Timeout)", 0
STR_STATUS_BADGE:       db "HTTP/1.1 | AFS", 0

; ------------------------------------------------------------------------------
; Built-in HTML Documents
; ------------------------------------------------------------------------------
PAGE_HOME_HTML:
    db "<html><head><title>CyberSurf Home Portal</title></head>", 0x0A
    db "<body>", 0x0A
    db "<h1>CyberSurf Web Explorer</h1>", 0x0A
    db "<p>Antigravity OS 64-bit World Wide Web Browser.</p>", 0x0A
    db "<hr>", 0x0A
    db "<h2>Quick Navigation Bookmarks</h2>", 0x0A
    db "<ul>", 0x0A
    db "<li><a href='http://antigravity.os/demo.html'>Showcase Demo</a></li>", 0x0A
    db "<li><a href='http://antigravity.os/status'>Kernel Telemetry</a></li>", 0x0A
    db "<li><a href='afs://welcome.txt'>AFS: welcome.txt</a></li>", 0x0A
    db "<li><a href='afs://readme.txt'>AFS: readme.txt</a></li>", 0x0A
    db "<li><a href='http://10.0.2.2/'>Host machine web server (10.0.2.2)</a></li>", 0x0A
    db "<li><a href='http://example.com/'>example.com (real internet via DNS + TCP)</a></li>", 0x0A
    db "</ul>", 0x0A
    db "<hr>", 0x0A
    db "<p><b>Engine:</b> Native x86_64 HTML Parser | BGA 1024x768 | RTL8139 TCP/IP</p>", 0x0A
    db "</body></html>", 0

PAGE_DEMO_HTML:
    db "<html><head><title>HTML Showcase</title></head>", 0x0A
    db "<body>", 0x0A
    db "<h1>Interactive HTML Showcase</h1>", 0x0A
    db "<p>CyberSurf renders HTML directly on bare metal.</p>", 0x0A
    db "<hr>", 0x0A
    db "<h2>Supported Features</h2>", 0x0A
    db "<ul>", 0x0A
    db "<li><b>Headings:</b> H1, H2, and H3 with color hierarchy</li>", 0x0A
    db "<li><b>Links:</b> Clickable navigation targets</li>", 0x0A
    db "<li><b>Lists:</b> Unordered bullet points</li>", 0x0A
    db "<li><b>Code Blocks:</b> Monospace syntax containers</li>", 0x0A
    db "<li><b>Dividers:</b> Horizontal accent rules (HR)</li>", 0x0A
    db "</ul>", 0x0A
    db "<hr>", 0x0A
    db "<code>mov eax, 0x0000F0FF ; Cyan TrueColor</code>", 0x0A
    db "<br>", 0x0A
    db "<p><a href='http://antigravity.os/'>Back to Home Portal</a></p>", 0x0A
    db "</body></html>", 0

PAGE_404_HTML:
    db "<html><head><title>404 Not Found</title></head>", 0x0A
    db "<body>", 0x0A
    db "<h1>404 - Webpage Not Found</h1>", 0x0A
    db "<p>The requested URL could not be resolved.</p>", 0x0A
    db "<hr>", 0x0A
    db "<p><a href='http://antigravity.os/'>Return to Home Portal</a></p>", 0x0A
    db "</body></html>", 0

PAGE_AFS_404_HTML:
    db "<html><head><title>AFS Not Found</title></head>", 0x0A
    db "<body>", 0x0A
    db "<h1>AFS File Not Found</h1>", 0x0A
    db "<p>File was not found in AntigravityFS volume.</p>", 0x0A
    db "<hr>", 0x0A
    db "<p><a href='http://antigravity.os/'>Return to Home Portal</a></p>", 0x0A
    db "</body></html>", 0

PAGE_CONN_FAIL_HTML:
    db "<html><head><title>Connection Failed</title></head>", 0x0A
    db "<body>", 0x0A
    db "<h1>Remote Host Unreachable</h1>", 0x0A
    db "<p>TCP connection timed out or was refused.</p>", 0x0A
    db "<hr>", 0x0A
    db "<p><a href='http://antigravity.os/'>Return to Home Portal</a></p>", 0x0A
    db "</body></html>", 0

PAGE_TLS_FAIL_HTML:
    db "<html><head><title>Secure Connection Failed</title></head>", 0x0A
    db "<body>", 0x0A
    db "<h1>Secure Connection Failed</h1>", 0x0A
    db "<p>The TLS 1.3 handshake did not complete. The reason is in the status bar.</p>", 0x0A
    db "<p>CyberSurf speaks TLS 1.3 with ChaCha20-Poly1305 and X25519 only.</p>", 0x0A
    db "<hr>", 0x0A
    db "<p><a href='http://antigravity.os/'>Return to Home Portal</a></p>", 0x0A
    db "</body></html>", 0

STR_TITLE_TLS_FAIL:     db "CyberSurf - Secure Connection Failed", 0
STR_STATUS_TLS_FAIL:    db "Error: TLS ", 0
STR_STATUS_UNVERIFIED:  db "CERT NOT VERIFIED | ", 0
STR_BADGE_UNVERIFIED:   db "UNVERIFIED TLS", 0
STR_URL_ICON_TLS:       db "TLS", 0
STR_HDR_LOCATION:       db "location:", 0
klog_browser_redirect:  db "browser: redirect -> ", 0
STR_TITLE_PREFIX:       db "CyberSurf - ", 0
STR_STATUS_SEP:         db " | ", 0
STR_STATUS_RESOLVING:   db "Resolving host name...", 0
STR_STATUS_CONNECTING:  db "Connecting...", 0
STR_STATUS_BAD_URL:     db "Error: not a valid URL", 0
STR_STATUS_DNS_FAIL:    db "Error: DNS lookup failed", 0

TELEM_HEAD:     db "<html><body><h1>Kernel and Network Telemetry</h1><p>Generated live by the kernel.</p><hr><ul>", 0x0A, 0
TELEM_CPU:      db "<li><b>CPU:</b> ", 0
TELEM_RAM:      db "</li>", 0x0A, "<li><b>RAM:</b> ", 0
TELEM_MB:       db " MB usable", 0
TELEM_UPTIME:   db "</li>", 0x0A, "<li><b>Uptime:</b> ", 0
TELEM_DISK:     db "</li>", 0x0A, "<li><b>Disk:</b> AntigravityFS, ", 0
TELEM_FILES:    db " files", 0
TELEM_IP:       db "</li>", 0x0A, "<li><b>IP:</b> ", 0
TELEM_SLASH:    db " / ", 0
TELEM_GW:       db "</li>", 0x0A, "<li><b>Gateway:</b> ", 0
TELEM_DNS:      db "  <b>DNS:</b> ", 0
TELEM_PACKETS:  db "</li>", 0x0A, "<li><b>Packets:</b> RX ", 0
TELEM_TX:       db " / TX ", 0
TELEM_TAIL:     db "</li>", 0x0A, "</ul><hr><p><a href='http://antigravity.os/'>Back to Home Portal</a></p></body></html>", 0
