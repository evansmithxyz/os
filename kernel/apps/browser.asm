; ==============================================================================
; Antigravity OS - CyberSurf Web Browser window
; ------------------------------------------------------------------------------
; The window: toolbar, address bar, bookmarks, status bar, navigation for
;   http://antigravity.os/...   built-in pages (home, demo, live telemetry)
;   afs://<file>                files on the AntigravityFS disk
;   http(s)://host[:port]/path  real HTTP/1.0 over the kernel's TCP stack, TLS
;                               1.3 for https (host names are resolved with DNS)
; and scrolling (arrows, PgUp/PgDn, Home/End, mouse wheel). The page layout is
; in browser_html.asm. Drawing uses the window frame position
; (br_wx/br_wy/br_ww/br_wh), which the WIN_DRAW callback derives from the
; client rectangle.
; ==============================================================================

[bits 64]

BROWSER_URL_MAX         equ 1024
BROWSER_PAGE_BUF_MAX    equ BROWSER_PAGE_SIZE - 1
browser_page_buf        equ BROWSER_PAGE_ADDR   ; use as [abs browser_page_buf]
BROWSER_LOG_MAX         equ 80      ; visible text reported by "[klog] browser text:"
BROWSER_MAX_REDIRECTS   equ 5
BROWSER_URL_X           equ 182     ; address text, from the window's left edge
BROWSER_WHEEL_STEP      equ 3 * 14  ; pixels per wheel notch / arrow key
BROWSER_MAX_SHEETS      equ 8       ; external style sheets per page

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
browser_log_text:       db 0        ; 1 = next render logs the page's first text
browser_page_tls:       db 0        ; 1 = page came over TLS with a verified certificate
browser_page_builtin:   db 1        ; 1 = the browser's own page: dark style sheet
browser_sheets:         db 0        ; style sheets fetched for this page
dom_ready:              db 0        ; dom_init has run
browser_redirects:      db 0        ; redirects followed for the current navigation
browser_js_navs:        db 0        ; navigations a script started, in a row
align 4
browser_log_len:        dd 0
browser_log_y:          dd 0        ; y of the last logged glyph
browser_url_len:        dd 0
browser_link_count:     dd 0
browser_vp_x:           dd 0
browser_vp_y:           dd 0
browser_vp_w:           dd 0
browser_vp_h:           dd 0
br_wx:                  dd 0        ; window frame geometry for the current draw
br_wy:                  dd 0
br_ww:                  dd 0
br_wh:                  dd 0

section .bss
alignb 16
browser_url_buf:        resb BROWSER_URL_MAX
browser_prev_url:       resb BROWSER_URL_MAX
browser_page_title:     resb 64
browser_status_text:    resb 96
browser_scratch:        resb 160
browser_redirect_buf:   resb 2048   ; [0] built URL, [1024] Location value
browser_link_buf:       resb 1024   ; a link being resolved
alignb 8
browser_resolved:       resq 1      ; browser_resolve_link's result
browser_log_buf:        resb BROWSER_LOG_MAX + 2

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

; browser_mouse: WIN_MOUSE callback - presses click, the wheel scrolls
browser_mouse:
    cmp al, WM_MOUSE_WHEEL
    je .wheel
    cmp al, WM_MOUSE_PRESS
    jne .ret
    call browser_handle_click
.ret:
    ret
.wheel:
    imul ecx, ecx, BROWSER_WHEEL_STEP
    jmp browser_scroll_by

; browser_key: WIN_KEY callback - typing edits the address bar
browser_key:
    test al, al
    jz .scroll_key
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
.scroll_key:
    ; Up/Down: a few lines, PgUp/PgDn: a viewport, Home/End: the ends
    mov ecx, -BROWSER_WHEEL_STEP
    cmp ah, SC_UP
    je .scroll
    mov ecx, BROWSER_WHEEL_STEP
    cmp ah, SC_DOWN
    je .scroll
    mov ecx, [browser_vp_h]
    sub ecx, 40
    cmp ah, SC_PGDN
    je .scroll
    neg ecx
    cmp ah, SC_PGUP
    je .scroll
    mov ecx, -0x1000000
    cmp ah, SC_HOME
    je .scroll
    mov ecx, 0x1000000
    cmp ah, SC_END
    jne .unused
.scroll:
    call browser_scroll_by
    jmp .used
.unused:
    clc
    ret

; ------------------------------------------------------------------------------
; browser_follow_link: RSI = href, ECX = its length (as written in the page)
; -> navigate there. "#fragment", javascript: and mailto: links do nothing.
; ------------------------------------------------------------------------------
browser_follow_link:
    call browser_resolve_link
    jc .ret
    push rcx
    push rsi
    push rdi
    mov rsi, [browser_resolved]
    lea rdi, [browser_url_buf]
    mov ecx, BROWSER_URL_MAX
    call strlcpy
    pop rdi
    pop rsi
    pop rcx
    call browser_navigate
.ret:
    ret

; ------------------------------------------------------------------------------
; browser_resolve_link: RSI = href, ECX = its length -> browser_resolved = the
; absolute URL, resolved against browser_page_url (absolute, //host, /path,
; ?query or relative, with ./ and ../). CF=1 for "#fragment", javascript:,
; mailto: and URLs too long to use.
; ------------------------------------------------------------------------------
browser_resolve_link:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    ; a clean copy: no whitespace, &amp; decoded
    lea rdi, [browser_link_buf]
    xor edx, edx
.copy:
    test ecx, ecx
    jz .copied
    mov al, [rsi]
    inc rsi
    dec ecx
    cmp al, ' '
    jbe .copy
    cmp al, '&'
    jne .store
    cmp ecx, 4
    jb .store
    cmp dword [rsi], 'amp;'
    jne .store
    add rsi, 4
    sub ecx, 4
.store:
    cmp edx, 1000
    jae .copy
    mov [rdi + rdx], al
    inc edx
    jmp .copy
.copied:
    mov byte [rdi + rdx], 0
    lea rsi, [browser_link_buf]
    mov al, [rsi]
    test al, al
    jz .done
    cmp al, '#'
    je .done
    lea rdi, [STR_LINK_JS]
    call str_has_prefix
    je .done
    lea rdi, [STR_LINK_MAILTO]
    call str_has_prefix
    je .done
    lea rdi, [url_http_prefix]
    call str_has_prefix
    je .absolute
    lea rdi, [url_https_prefix]
    call str_has_prefix
    je .absolute
    lea rdi, [STR_PROTO_AFS]
    call str_has_prefix
    je .absolute

    ; relative to the page: RBX = base URL, RDI = output
    lea rbx, [browser_page_url]
    lea rdi, [browser_redirect_buf]
    mov byte [rdi], 0
    push rsi
    mov rsi, rbx
    push rdi
    lea rdi, [STR_PROTO_AFS]
    call str_has_prefix
    pop rdi
    pop rsi
    jne .web
    ; afs:// pages link to other files on the disk
    push rsi
    lea rsi, [STR_PROTO_AFS]
    call fmt_str
    pop rsi
.afs_slash:
    cmp byte [rsi], '/'
    jne .afs_name
    inc rsi
    jmp .afs_slash
.afs_name:
    call fmt_str
    jmp .built
.web:
    ; R8 = end of "scheme://", R9 = end of the origin (host and port)
    xor r8d, r8d
.find_scheme:
    mov al, [rbx + r8]
    test al, al
    jz .done
    inc r8
    cmp al, ':'
    jne .find_scheme
    cmp word [rbx + r8], '//'
    jne .done
    lea r9, [r8 + 2]
.find_origin_end:
    mov al, [rbx + r9]
    test al, al
    jz .have_origin
    cmp al, '/'
    je .have_origin
    cmp al, '?'
    je .have_origin
    cmp al, '#'
    je .have_origin
    inc r9
    jmp .find_origin_end
.have_origin:
    cmp word [rsi], '//'
    jne .not_scheme_relative
    mov ecx, r8d                    ; "https:" + "//host/path"
    call .base
    jmp .append
.not_scheme_relative:
    cmp byte [rsi], '/'
    jne .not_root
    mov ecx, r9d                    ; origin + "/path"
    call .base
    jmp .append
.not_root:
    ; ECX = end of the base path (before '?' or '#')
    mov ecx, r9d
.find_path_end:
    mov al, [rbx + rcx]
    test al, al
    jz .have_path_end
    cmp al, '?'
    je .have_path_end
    cmp al, '#'
    je .have_path_end
    inc ecx
    jmp .find_path_end
.have_path_end:
    cmp byte [rsi], '?'
    je .query                       ; same path, new query
    ; the base's directory: up to and including its last '/'
.dir:
    cmp ecx, r9d
    jbe .no_dir
    cmp byte [rbx + rcx - 1], '/'
    je .query
    dec ecx
    jmp .dir
.no_dir:
    mov ecx, r9d
    call .base
    mov al, '/'
    call fmt_char
    jmp .append
.query:
    call .base
.append:
    call fmt_str
    ; tidy "./" and "../" in the path
    lea rsi, [browser_redirect_buf]
    add rsi, r9
    call browser_dot_segments
.built:
    lea rsi, [browser_redirect_buf]
.absolute:
    call strlen
    cmp eax, BROWSER_URL_MAX - 1
    jae .done
    mov [browser_resolved], rsi
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret
.done:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret
; .base: append the first ECX bytes of the base URL (RBX) at RDI
.base:
    push rcx
    push rsi
    mov rsi, rbx
    rep movsb
    mov byte [rdi], 0
    pop rsi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; browser_dot_segments: RSI = the path part of a URL (in place). Removes "/./"
; and folds "/x/../" away, as a browser does before sending the request.
; ------------------------------------------------------------------------------
browser_dot_segments:
    push rax
    push rcx
    push rsi
    push rdi
    mov rcx, rsi                    ; RCX = start of the path
.scan:
    mov al, [rsi]
    test al, al
    jz .done
    cmp al, '?'
    je .done
    cmp al, '#'
    je .done
    cmp al, '/'
    jne .next
    cmp byte [rsi + 1], '.'
    jne .next
    mov al, [rsi + 2]
    cmp al, '/'
    je .dot                         ; "/./"
    test al, al
    je .dot_end                     ; trailing "/."
    cmp al, '.'
    jne .next
    mov al, [rsi + 3]
    cmp al, '/'
    je .dotdot                      ; "/../"
    test al, al
    jne .next
    ; trailing "/..": becomes "/"
    mov byte [rsi + 3], '/'
    mov byte [rsi + 4], 0
    jmp .dotdot
.dot_end:
    mov byte [rsi + 1], 0
    jmp .done
.dot:
    lea rdi, [rsi + 1]              ; "/./x" -> "/x"
    push rsi
    lea rsi, [rsi + 3]
    call .move_down
    pop rsi
    jmp .scan
.dotdot:
    ; back to the '/' before this one (not past the start)
    mov rdi, rsi
.back:
    cmp rdi, rcx
    jbe .at_start
    dec rdi
    cmp byte [rdi], '/'
    jne .back
.at_start:
    push rsi
    lea rsi, [rsi + 3]              ; from the '/' after ".."
    call .move_down
    pop rsi
    mov rsi, rdi
    jmp .scan
.next:
    inc rsi
    jmp .scan
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret
; .move_down: copy the string at RSI (with its NUL) to RDI
.move_down:
    push rax
    push rsi
    push rdi
.md_byte:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .md_byte
    pop rdi
    pop rsi
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_scroll_by: ECX = pixels (negative = up). Going down stops at the end
; of the page (browser_render_html_page clamps once it has seen the end).
; ------------------------------------------------------------------------------
browser_scroll_by:
    push rax
    mov eax, [browser_scroll]
    test ecx, ecx
    js .apply
    cmp byte [browser_more], 0      ; already showing the end
    je .done
.apply:
    add eax, ecx
    jns .set
    xor eax, eax
.set:
    cmp eax, [browser_scroll]
    je .done
    mov [browser_scroll], eax
    mov byte [gui_dirty], 1
    mov byte [browser_log_text], 1  ; tests: log what is now at the top
    mov dword [browser_log_len], 0
    mov byte [browser_log_buf], 0
    push rsi
    lea rsi, [klog_browser_scroll]
    call klog_dec
    pop rsi
.done:
    pop rax
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
    lea rdi, [abs browser_page_buf]
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
    mov byte [browser_page_builtin], 1  ; until a fetched page replaces it
    mov byte [browser_page_plain], 0
    mov byte [browser_page_latin1], 0
    mov dword [browser_scroll], 0
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
    lea rdi, [abs browser_page_buf]
    mov ecx, BROWSER_PAGE_BUF_MAX
    call fs_read_file
    lea rdi, [abs browser_page_buf]
    mov byte [rdi + rax], 0
    ; a file is plain text unless its name ends in .htm or .html
    mov byte [browser_page_plain], 1
    lea rsi, [browser_url_buf]
    call strlen
    cmp eax, 5
    jb .afs_title
    mov edx, [rsi + rax - 4]
    or edx, 0x20202020
    cmp edx, '.htm'
    je .afs_html
    cmp eax, 6
    jb .afs_title
    mov edx, [rsi + rax - 5]
    or edx, 0x20202000              ; keep the '.'
    cmp edx, '.htm'
    jne .afs_title
    mov dl, [rsi + rax - 1]
    or dl, 0x20
    cmp dl, 'l'
    jne .afs_title
.afs_html:
    mov byte [browser_page_plain], 0
.afs_title:
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
    call browser_prepare_page       ; DOM, style sheets, styles
    call jsd_page_load              ; its scripts
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
    call browser_js_navigation      ; a script set location.href
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; browser_js_navigation: a script asked for another page (location.href):
; load it (at most a few in a row, so pages cannot bounce forever)
browser_js_navigation:
    cmp byte [jsd_nav_pending], 0
    je .ret
    mov byte [jsd_nav_pending], 0
    cmp byte [browser_js_navs], 4
    jae .ret
    inc byte [browser_js_navs]
    call browser_navigate
    dec byte [browser_js_navs]
.ret:
    ret

; ------------------------------------------------------------------------------
; browser_prepare_page: browser_page_buf -> DOM (dom.asm), style sheets and
; styles (css.asm). The layout is redone at the next paint. Style sheets, in
; document order: the browser's defaults (web/ua.css), the dark look of its
; own pages (web/builtin.css), then the page's <style> blocks and
; <link rel=stylesheet> files, fetched over HTTP(S).
; ------------------------------------------------------------------------------
browser_prepare_page:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    cmp byte [dom_ready], 0
    jne .ready
    call dom_init
    mov byte [dom_ready], 1
.ready:
    call dom_build
    call css_reset
    ; @media sees our viewport in CSS pixels (twice ours)
    mov eax, [browser_vp_w]
    test eax, eax
    jnz .have_width
    mov eax, 880
.have_width:
    shl eax, 1
    mov [css_viewport], eax
    mov dword [css_origin], 0
    lea rsi, [css_ua_sheet]
    mov ecx, css_ua_sheet_len
    call css_parse
    mov dword [css_origin], CSS_ORIGIN_AUTHOR
    cmp byte [browser_page_builtin], 0
    je .page_sheets
    lea rsi, [css_builtin_sheet]
    mov ecx, css_builtin_sheet_len
    call css_parse
.page_sheets:
    mov byte [browser_sheets], 0
    mov r12d, 1
.node:
    cmp r12d, [dom_count]
    jae .styled
    mov eax, r12d
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    jne .next
    cmp byte [rbx + N_TAG], TAGID_STYLE
    je .style
    cmp byte [rbx + N_TAG], TAGID_LINK
    jne .next
    ; <link rel="stylesheet" href="..." [media="..."]>
    mov eax, r12d
    lea rdi, [STR_ATTR_REL]
    call dom_attr
    jc .next
    lea rdi, [STR_REL_STYLESHEET]
    call css_contains_ci
    jne .next
    call .media_ok
    jc .next
    mov eax, r12d
    lea rdi, [STR_ATTR_HREF]
    call dom_attr
    jc .next
    call browser_fetch_stylesheet
    jmp .next
.style:
    call .media_ok
    jc .next
    mov eax, [rbx + N_FIRST]
    test eax, eax
    jz .next
    call dom_node
    mov rsi, [rbx + N_NAME]
    mov ecx, [rbx + N_NAME_LEN]
    call css_parse
.next:
    inc r12d
    jmp .node
.styled:
    mov eax, [css_rule_count]
    lea rsi, [klog_browser_rules]   ; "[klog] browser: css rules N"
    call klog_dec
    call css_compute
    mov dword [lay_width], -1       ; lay out at the next paint
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
; .media_ok: element R12's media="" (if any) -> CF=1 if not for the screen
.media_ok:
    push rax
    push rcx
    push rsi
    push rdi
    mov eax, r12d
    lea rdi, [STR_ATTR_MEDIA]
    call dom_attr
    jc .media_yes
    call css_media_ok
    jmp .media_out
.media_yes:
    clc
.media_out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_fetch_stylesheet: RSI = href, ECX = its length -> fetched (quietly)
; and parsed as an author style sheet. At most BROWSER_MAX_SHEETS per page.
; ------------------------------------------------------------------------------
browser_fetch_stylesheet:
    push rax
    push rcx
    push rsi
    cmp byte [browser_sheets], BROWSER_MAX_SHEETS
    jae .done
    inc byte [browser_sheets]
    call browser_fetch_quiet
    jc .done
    call css_keep_text              ; the next fetch reuses http_resp_buf
    call css_parse
    mov eax, ecx
    lea rsi, [klog_browser_sheet]
    call klog_dec
.done:
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_fetch_quiet: RSI = href, ECX = its length (resolved against the page)
; -> RSI = the body of a 200 response (in http_resp_buf, valid until the next
; fetch), RCX = its length; CF=1 if it could not be fetched
; ------------------------------------------------------------------------------
browser_fetch_quiet:
    push rax
    push rdx
    push rdi
    push r8
    call browser_resolve_link
    jc .fail
    mov rsi, [browser_resolved]
    call url_parse
    jc .fail
    cmp byte [net_present], 1
    jne .fail
    lea rsi, [url_host]
    lea rdi, [url_ip]
    call net_resolve_host
    jc .fail
    mov byte [http_quiet], 1
    lea rsi, [url_ip]
    lea rdi, [url_host]
    movzx edx, word [url_port]
    lea r8, [url_path]
    cmp byte [url_https], 1
    je .https
    call tcp_http_client
    jmp .fetched
.https:
    mov byte [tls_insecure], 0
    call tls_https_get
.fetched:
    mov byte [http_quiet], 0
    test eax, eax
    jnz .fail
    ; only a 200 response counts
    lea rsi, [abs http_resp_buf]
    cmp byte [rsi + 9], '2'
    jne .fail
    ; the body, after the blank line
.find_body:
    mov al, [rsi]
    test al, al
    jz .fail
    cmp dword [rsi], 0x0A0D0A0D
    je .body
    inc rsi
    jmp .find_body
.body:
    add rsi, 4
    call strlen
    mov rcx, rax
    pop r8
    pop rdi
    pop rdx
    pop rax
    clc
    ret
.fail:
    pop r8
    pop rdi
    pop rdx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; browser_fetch_http: GET browser_url_buf (http:// or https://) into the page
; buffer, following up to BROWSER_MAX_REDIRECTS redirects. An https:// page is
; only shown if its certificate verifies; it sets browser_page_tls, which the
; address bar and the badge show.
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
    mov byte [tls_insecure], 0      ; the browser always checks certificates
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
    mov byte [browser_page_builtin], 0
    call browser_content_type

    ; Body = everything after the blank line that ends the headers
    lea rsi, [abs http_resp_buf]
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
    lea rsi, [abs http_resp_buf]
.copy:
    lea rdi, [abs browser_page_buf]
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
    call browser_title_from_page    ; "CyberSurf - <title>" if the page has one
    lea rdi, [browser_scratch]
    lea rsi, [abs http_resp_buf]
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
; browser_content_type: from the response's Content-Type header set
; browser_page_plain (text/plain) and browser_page_latin1 (ISO-8859-x or
; Windows-125x charset)
; ------------------------------------------------------------------------------
browser_content_type:
    push rax
    push rcx
    push rsi
    push rdi
    lea rdi, [STR_HDR_CONTENT_TYPE]
    call browser_header
    jc .done
    ; RSI = the value, lower-cased in browser_scratch
    lea rdi, [STR_CT_PLAIN]
    call browser_contains
    jne .charset
    mov byte [browser_page_plain], 1
.charset:
    lea rdi, [STR_CT_LATIN1]
    call browser_contains
    je .latin1
    lea rdi, [STR_CT_CP1252]
    call browser_contains
    jne .done
.latin1:
    mov byte [browser_page_latin1], 1
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_header: RDI = header name with ':' (lower case) -> RSI = its value in
; browser_scratch, lower-cased; CF=1 if the response has no such header
; ------------------------------------------------------------------------------
browser_header:
    push rax
    push rcx
    push rdx
    push rdi
    lea rsi, [abs http_resp_buf]
.line:
    mov al, [rsi]
    test al, al
    jz .none
    inc rsi
    cmp al, 0x0A
    jne .line
    cmp byte [rsi], 0x0D            ; blank line: end of the headers
    je .none
    cmp byte [rsi], 0x0A
    je .none
    xor ecx, ecx
.name:
    mov al, [rdi + rcx]
    test al, al
    jz .found
    mov dl, [rsi + rcx]
    or dl, 0x20
    cmp dl, al
    jne .line
    inc ecx
    jmp .name
.found:
    add rsi, rcx
.space:
    cmp byte [rsi], ' '
    jne .value
    inc rsi
    jmp .space
.value:
    lea rdi, [browser_scratch]
    xor ecx, ecx
.value_char:
    mov al, [rsi + rcx]
    cmp al, 0x0D
    je .value_end
    cmp al, 0x0A
    je .value_end
    test al, al
    jz .value_end
    cmp ecx, 150
    jae .value_end
    cmp al, 'A'
    jb .lower
    cmp al, 'Z'
    ja .lower
    or al, 0x20
.lower:
    mov [rdi + rcx], al
    inc ecx
    jmp .value_char
.value_end:
    mov byte [rdi + rcx], 0
    mov rsi, rdi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.none:
    pop rdi
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; browser_contains: ZF=1 if the string at RSI contains the string at RDI
browser_contains:
    push rsi
.try:
    cmp byte [rsi], 0
    je .no
    call str_has_prefix
    je .yes
    inc rsi
    jmp .try
.no:
    pop rsi
    test rsp, rsp                   ; ZF=0
    ret
.yes:
    pop rsi
    ret

; ------------------------------------------------------------------------------
; browser_title_from_page: if browser_page_buf has a <title>, make the window
; title "CyberSurf - <title>" (spaces collapsed, cut to fit)
; ------------------------------------------------------------------------------
browser_title_from_page:
    push rax
    push rcx
    push rsi
    push rdi
    lea rsi, [abs browser_page_buf]
.find:
    mov al, [rsi]
    test al, al
    jz .done
    inc rsi
    cmp al, '<'
    jne .find
    mov eax, [rsi]
    or eax, 0x20202020
    cmp eax, 'titl'
    jne .find
    mov al, [rsi + 4]
    or al, 0x20
    cmp al, 'e'
    jne .find
    mov al, [rsi + 5]
    cmp al, '>'
    je .open
    cmp al, ' '
    jne .find
.open:
    mov al, [rsi]
    test al, al
    jz .done
    inc rsi
    cmp al, '>'
    jne .open
    ; the text, up to '<'
    lea rdi, [browser_page_title]
    push rsi
    lea rsi, [STR_TITLE_PREFIX]
    call fmt_str
    pop rsi
    lea rcx, [browser_page_title + 63]
    mov ah, 1                       ; 1 = at a space (drop leading ones)
.char:
    mov al, [rsi]
    test al, al
    jz .end
    cmp al, '<'
    je .end
    inc rsi
    cmp al, ' '
    ja .visible
    test ah, ah
    jnz .char
    mov ah, 1
    mov al, ' '
    jmp .put
.visible:
    cmp al, 0x7E
    ja .char                        ; the font has no glyphs past '~'
    xor ah, ah
.put:
    cmp rdi, rcx
    jae .end
    mov [rdi], al
    inc rdi
    jmp .char
.end:
    cmp byte [rdi - 1], ' '
    jne .terminate
    dec rdi
.terminate:
    mov byte [rdi], 0
.done:
    pop rdi
    pop rsi
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

    lea rsi, [abs http_resp_buf]
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
    ; the value, up to the end of the line, into browser_redirect_buf + 1024
    lea rdi, [browser_redirect_buf + 1024]
    xor ecx, ecx
.value_char:
    mov al, [rsi + rcx]
    cmp al, ' '
    jbe .value_end                  ; CR, LF, NUL or space
    cmp ecx, 900                    ; (the URL built from it must stay below +1024)
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
    lea rdi, [abs browser_page_buf]
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
    lea rsi, [STR_URL_ICON_TLS]     ; encrypted, certificate verified
    mov eax, THEME_GREEN_LIGHT
.url_icon:
    mov ebx, -1
    call gfx_print_string

    ; URL Text: the end of it when it is longer than the box
    mov eax, [br_ww]
    sub eax, BROWSER_URL_X + 68
    shr eax, 3                      ; characters that fit (one left for the cursor)
    mov ecx, [browser_url_len]
    xor r9d, r9d                    ; R9 = characters hidden on the left
    sub ecx, eax
    jle .url_fits
    mov r9d, ecx
.url_fits:
    mov ecx, [br_wx]
    add ecx, BROWSER_URL_X
    mov edx, [br_wy]
    add edx, 37
    lea rsi, [browser_url_buf]
    add rsi, r9
    mov eax, THEME_TEXT
    mov ebx, -1
    call gfx_print_string

    ; URL Cursor (if URL bar focused)
    cmp byte [browser_url_focused], 1
    jne .skip_url_cursor
    mov ecx, [br_wx]
    add ecx, BROWSER_URL_X
    mov eax, [browser_url_len]
    sub eax, r9d
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
    lea rsi, [STR_BADGE_VERIFIED]
    mov eax, THEME_GREEN_LIGHT
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

; (the HTML renderer is in browser_html.asm)
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
    ; 5. The page: first its scripts' click handlers, then links
    call browser_page_click
    jc .body_handled                ; a handler cancelled it (or navigated)
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

    ; Link matched: resolve its href against this page and go there
    mov rsi, [rdi + LINK_HREF]
    mov ecx, [rdi + LINK_HREF_LEN]
    call browser_follow_link
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
; browser_page_click: ECX, EDX = the pointer -> the page's click event on the
; element under it (if it is in the viewport). CF=1 if the default action
; is cancelled or a script navigated.
; ------------------------------------------------------------------------------
browser_page_click:
    push rax
    push rbx
    mov eax, [browser_vp_x]
    cmp ecx, eax
    jl .outside
    add eax, [browser_vp_w]
    cmp ecx, eax
    jge .outside
    mov eax, [browser_vp_y]
    cmp edx, eax
    jl .outside
    add eax, [browser_vp_h]
    cmp edx, eax
    jge .outside
    call layout_node_at
    jnc .target
    ; page background: <body>
    push rdx
    xor eax, eax
    mov edx, TAGID_BODY
    call jsd_find_tag
    pop rdx
    jc .outside
.target:
    push rcx
    push rdx
    sub ecx, [browser_vp_x]
    sub edx, [browser_vp_y]
    call jsd_page_click
    pop rdx
    pop rcx
    jc .cancel
    cmp byte [jsd_nav_pending], 0
    je .outside
    call browser_js_navigation
.cancel:
    pop rbx
    pop rax
    stc
    ret
.outside:
    pop rbx
    pop rax
    clc
    ret

; ------------------------------------------------------------------------------
; Browser Strings & Built-in HTML Pages
; ------------------------------------------------------------------------------
section .rodata
browser_label:          db "Browser", 0
klog_browser:           db "browser: ", 0
klog_browser_status:    db "browser status: ", 0
klog_browser_text:      db "browser text: ", 0
klog_browser_scroll:    db "browser scroll: ", 0
klog_browser_sheet:     db "browser: style sheet bytes ", 0
klog_browser_rules:     db "browser: css rules ", 0
STR_ATTR_REL:           db "rel", 0
STR_ATTR_HREF:          db "href", 0
STR_ATTR_MEDIA:         db "media", 0
STR_REL_STYLESHEET:     db "stylesheet", 0
css_ua_sheet:           incbin "web/ua.css"
css_ua_sheet_len        equ $ - css_ua_sheet
css_builtin_sheet:      incbin "web/builtin.css"
css_builtin_sheet_len   equ $ - css_builtin_sheet
STR_LINK_JS:            db "javascript:", 0
STR_LINK_MAILTO:        db "mailto:", 0
STR_HDR_CONTENT_TYPE:   db "content-type:", 0
STR_CT_PLAIN:           db "text/plain", 0
STR_CT_LATIN1:          db "iso-8859", 0
STR_CT_CP1252:          db "windows-125", 0
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
    db "<p>The TLS 1.3 connection was not made. The reason is in the status bar.</p>", 0x0A
    db "<p>CyberSurf only shows HTTPS pages from servers whose certificate chains to a trusted root, "
    db "is currently valid and names this host. Add your own CA to the disk file localca.der to trust it.</p>", 0x0A
    db "<p>It speaks TLS 1.3 with ChaCha20-Poly1305 and X25519 only.</p>", 0x0A
    db "<hr>", 0x0A
    db "<p><a href='http://antigravity.os/'>Return to Home Portal</a></p>", 0x0A
    db "</body></html>", 0

STR_TITLE_TLS_FAIL:     db "CyberSurf - Secure Connection Failed", 0
STR_STATUS_TLS_FAIL:    db "Error: TLS ", 0
STR_BADGE_VERIFIED:     db "TLS 1.3 VERIFIED", 0
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
