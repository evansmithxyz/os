; ==============================================================================
; Antigravity OS - CyberSurf 64-Bit Web Browser Application
; Native Bare-Metal HTML Parser, Hyperlink Engine, and HTTP/AFS Web Navigator
; ==============================================================================

[bits 64]

; Browser Window Geometry Defaults
WIN3_DEF_X              equ 60
WIN3_DEF_Y              equ 52
WIN3_DEF_W              equ 904
WIN3_DEF_H              equ 670

BROWSER_URL_MAX         equ 96
BROWSER_PAGE_BUF_MAX    equ 4096
BROWSER_MAX_LINKS       equ 16

; Colors for Browser UI
BROWSER_CLR_TOOLBAR     equ 0x00131D2E   ; Deep Navy Toolbar
BROWSER_CLR_URL_BG      equ 0x000A0E17   ; Address Bar Background
BROWSER_CLR_URL_BORDER  equ 0x00334155   ; Unfocused Address Bar Border
BROWSER_CLR_URL_ACT     equ 0x0000F0FF   ; Focused Address Bar Border (Cyan)
BROWSER_CLR_BOOKMARK_BG equ 0x001E293B   ; Bookmark Pill Background
BROWSER_CLR_PAGE_BG     equ 0x00070A0F   ; Webpage Viewport Dark Canvas
BROWSER_CLR_STATUS_BG   equ 0x000B1120   ; Status Bar Background

; ------------------------------------------------------------------------------
; Window 3 State Variables
; ------------------------------------------------------------------------------
win3_state:             db WIN_STATE_CLOSED     ; Closed by default until opened
win3_x:                 dd WIN3_DEF_X
win3_y:                 dd WIN3_DEF_Y
win3_w:                 dd WIN3_DEF_W
win3_h:                 dd WIN3_DEF_H

browser_url_buf:        times BROWSER_URL_MAX db 0
browser_url_len:        dd 0
browser_prev_url:       times BROWSER_URL_MAX db 0
browser_url_focused:    db 0                    ; 1 = URL bar has keyboard focus
browser_page_title:     times 64 db 0
browser_status_text:    times 64 db 0

; Hyperlink Hit Table (up to 16 links on current page)
; Each entry: [x1: dd, y1: dd, x2: dd, y2: dd, target_url: 64 bytes] = 80 bytes
browser_link_count:     dd 0
browser_links           equ 0x00020000

; Page Document Content Buffer (4 KB in RAM)
browser_page_buf        equ 0x00021000
browser_page_len:       dd 0

; Parser Scratch Variables
browser_parse_ptr:      dq 0
browser_cur_x:          dd 0
browser_cur_y:          dd 0
browser_text_color:     dd 0x00E2E8F0
browser_vp_x:           dd 0
browser_vp_y:           dd 0
browser_vp_w:           dd 0
browser_vp_h:           dd 0
browser_in_link:        db 0
browser_link_x1:        dd 0
browser_link_y1:        dd 0
browser_temp_href:      times 64 db 0

; ------------------------------------------------------------------------------
; browser_init: Initializes default homepage and loads initial document
; ------------------------------------------------------------------------------
browser_init:
    push rax
    push rsi
    push rdi

    ; Default URL = "http://antigravity.os/"
    mov rdi, browser_url_buf
    lea rsi, [STR_URL_HOME]
    call strcpy

    mov eax, STR_URL_HOME_LEN
    mov [browser_url_len], eax

    mov rdi, browser_prev_url
    lea rsi, [STR_URL_HOME]
    call strcpy

    ; Load Home Portal Document
    call browser_load_home_portal

    pop rdi
    pop rsi
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_load_home_portal: Copies PAGE_HOME_HTML into browser_page_buf
; ------------------------------------------------------------------------------
browser_load_home_portal:
    push rax
    push rsi
    push rdi

    mov rdi, browser_page_buf
    lea rsi, [PAGE_HOME_HTML]
    call strcpy

    mov rdi, browser_page_title
    lea rsi, [STR_TITLE_HOME]
    call strcpy

    mov rdi, browser_status_text
    lea rsi, [STR_STATUS_200_HOME]
    call strcpy

    pop rdi
    pop rsi
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_load_demo_page: Copies PAGE_DEMO_HTML into browser_page_buf
; ------------------------------------------------------------------------------
browser_load_demo_page:
    push rax
    push rsi
    push rdi

    mov rdi, browser_page_buf
    lea rsi, [PAGE_DEMO_HTML]
    call strcpy

    mov rdi, browser_page_title
    lea rsi, [STR_TITLE_DEMO]
    call strcpy

    mov rdi, browser_status_text
    lea rsi, [STR_STATUS_200_DEMO]
    call strcpy

    pop rdi
    pop rsi
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_load_status_page: Copies PAGE_STATUS_HTML into browser_page_buf
; ------------------------------------------------------------------------------
browser_load_status_page:
    push rax
    push rsi
    push rdi

    mov rdi, browser_page_buf
    lea rsi, [PAGE_STATUS_HTML]
    call strcpy

    mov rdi, browser_page_title
    lea rsi, [STR_TITLE_STATUS]
    call strcpy

    mov rdi, browser_status_text
    lea rsi, [STR_STATUS_200_STATUS]
    call strcpy

    pop rdi
    pop rsi
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_navigate: Dispatches URL navigation based on browser_url_buf
; ------------------------------------------------------------------------------
browser_navigate:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; Update URL length
    lea rsi, [browser_url_buf]
    call strlen
    mov [browser_url_len], eax

    ; Save previous URL for Back button
    mov rdi, browser_prev_url
    lea rsi, [browser_url_buf]
    call strcpy

    ; 1. Check AFS file protocol: "afs://"
    lea rsi, [browser_url_buf]
    lea rdi, [STR_PROTO_AFS]
    mov rcx, 6
    call strncmp
    jz .load_afs_file

    ; 2. Check Home Portal: "http://antigravity.os/" or "about:home" or empty
    cmp byte [browser_url_buf], 0
    je .do_home
    lea rsi, [browser_url_buf]
    lea rdi, [STR_URL_HOME]
    call strcmp
    jz .do_home
    lea rsi, [browser_url_buf]
    lea rdi, [STR_URL_ABOUT]
    call strcmp
    jz .do_home

    ; 3. Check Demo Page: "http://antigravity.os/demo.html"
    lea rsi, [browser_url_buf]
    lea rdi, [STR_URL_DEMO]
    call strcmp
    jz .do_demo

    ; 4. Check Status Page: "http://antigravity.os/status"
    lea rsi, [browser_url_buf]
    lea rdi, [STR_URL_STATUS]
    call strcmp
    jz .do_status

    ; 5. Check Live HTTP to 10.0.2.2 Host Gateway: "http://10.0.2.2"
    lea rsi, [browser_url_buf]
    lea rdi, [STR_URL_HOST]
    mov rcx, 15
    call strncmp
    jz .do_http_host

    ; 6. Generic/Unknown URL -> Show 404 Not Found Page
    call browser_load_404_page
    jmp .done_nav

.do_home:
    call browser_load_home_portal
    jmp .done_nav

.do_demo:
    call browser_load_demo_page
    jmp .done_nav

.do_status:
    call browser_load_status_page
    jmp .done_nav

.load_afs_file:
    ; Extract filename after "afs://"
    lea rsi, [browser_url_buf + 6]
    call fs_find_file
    test rax, rax
    jz .afs_not_found

    ; Read file from starting LBA
    mov rbx, rax
    movzx rax, word [rbx + 20]  ; start LBA
    lea rdi, [fs_sector_buf]
    call ata_read_sector

    mov ecx, [rbx + 16]         ; file length
    cmp ecx, 2048
    jbe .afs_size_ok
    mov ecx, 2048
.afs_size_ok:
    ; Copy into browser_page_buf and null-terminate
    mov rdi, browser_page_buf
    lea rsi, [fs_sector_buf]
    rep movsb
    mov byte [rdi], 0

    mov rdi, browser_page_title
    lea rsi, [browser_url_buf]
    call strcpy

    mov rdi, browser_status_text
    lea rsi, [STR_STATUS_AFS_OK]
    call strcpy
    jmp .done_nav

.afs_not_found:
    mov rdi, browser_page_buf
    lea rsi, [PAGE_AFS_404_HTML]
    call strcpy

    mov rdi, browser_page_title
    lea rsi, [STR_TITLE_404]
    call strcpy

    mov rdi, browser_status_text
    lea rsi, [STR_STATUS_404]
    call strcpy
    jmp .done_nav

.do_http_host:
    ; Connect via TCP to 10.0.2.2:80
    mov dword [tcp_remote_ip], 0x0202000A ; 10.0.2.2
    mov word [tcp_remote_port], 80
    lea rsi, [tcp_remote_ip]
    xor rdi, rdi                ; Host header = IP
    mov dx, 80
    call tcp_http_client
    test eax, eax
    jnz .http_failed

    ; Copy response payload (skipping HTTP headers)
    mov rsi, tcp_rx_buf
    ; Scan for "\r\n\r\n"
.scan_hdr:
    cmp byte [rsi], 0
    je .copy_raw_http
    cmp byte [rsi], 0x0D
    jne .next_hdr_char
    cmp byte [rsi + 1], 0x0A
    jne .next_hdr_char
    cmp byte [rsi + 2], 0x0D
    jne .next_hdr_char
    cmp byte [rsi + 3], 0x0A
    jne .next_hdr_char
    add rsi, 4                  ; Found body!
    jmp .copy_raw_http
.next_hdr_char:
    inc rsi
    jmp .scan_hdr

.copy_raw_http:
    mov rdi, browser_page_buf
    call strcpy

    mov rdi, browser_page_title
    lea rsi, [STR_TITLE_HOST]
    call strcpy

    mov rdi, browser_status_text
    lea rsi, [STR_STATUS_HTTP_OK]
    call strcpy
    jmp .done_nav

.http_failed:
    mov rdi, browser_page_buf
    lea rsi, [PAGE_CONN_FAIL_HTML]
    call strcpy

    mov rdi, browser_page_title
    lea rsi, [STR_TITLE_FAIL]
    call strcpy

    mov rdi, browser_status_text
    lea rsi, [STR_STATUS_FAIL]
    call strcpy

.done_nav:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_load_404_page: Generic 404 HTML
; ------------------------------------------------------------------------------
browser_load_404_page:
    push rsi
    push rdi

    mov rdi, browser_page_buf
    lea rsi, [PAGE_404_HTML]
    call strcpy

    mov rdi, browser_page_title
    lea rsi, [STR_TITLE_404]
    call strcpy

    mov rdi, browser_status_text
    lea rsi, [STR_STATUS_404]
    call strcpy

    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------------------------
; browser_draw_window: Renders complete CyberSurf Web Browser window
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

    ; 1. Window Frame & Titlebar
    mov ecx, [win3_x]
    mov edx, [win3_y]
    mov esi, [win3_w]
    mov r8d, [win3_h]
    lea rdi, [browser_page_title]
    xor al, al
    cmp byte [win_focused], 3
    jne .frame3
    mov al, 1
.frame3:
    mov ah, 3                   ; Window ID 3 (CyberSurf Browser)
    call gui_draw_window_frame

    ; 2. Navigation Toolbar Panel (y: win3_y + 28, h: 26)
    mov ecx, [win3_x]
    add ecx, 2
    mov edx, [win3_y]
    add edx, 28
    mov esi, [win3_w]
    sub esi, 4
    mov r8d, 26
    mov eax, BROWSER_CLR_TOOLBAR
    call gfx_fill_rect

    ; Toolbar bottom divider
    mov ecx, [win3_x]
    add ecx, 2
    mov edx, [win3_y]
    add edx, 54
    mov esi, [win3_w]
    sub esi, 4
    mov r8d, 1
    mov eax, 0x001E293B
    call gfx_fill_rect

    ; Nav Button: [ < ] Back
    mov ecx, [win3_x]
    add ecx, 10
    mov edx, [win3_y]
    add edx, 32
    mov esi, 24
    mov r8d, 18
    mov eax, 0x001E293B
    call gfx_fill_rect
    mov ecx, [win3_x]
    add ecx, 18
    mov edx, [win3_y]
    add edx, 37
    lea rsi, [STR_BTN_BACK]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; Nav Button: [ > ] Forward
    mov ecx, [win3_x]
    add ecx, 38
    mov edx, [win3_y]
    add edx, 32
    mov esi, 24
    mov r8d, 18
    mov eax, 0x001E293B
    call gfx_fill_rect
    mov ecx, [win3_x]
    add ecx, 46
    mov edx, [win3_y]
    add edx, 37
    lea rsi, [STR_BTN_FWD]
    mov eax, COLOR_TEXT_MUTED
    mov ebx, -1
    call gfx_print_string

    ; Nav Button: [ R ] Reload
    mov ecx, [win3_x]
    add ecx, 66
    mov edx, [win3_y]
    add edx, 32
    mov esi, 24
    mov r8d, 18
    mov eax, 0x001E293B
    call gfx_fill_rect
    mov ecx, [win3_x]
    add ecx, 74
    mov edx, [win3_y]
    add edx, 37
    lea rsi, [STR_BTN_RELOAD]
    mov eax, COLOR_TEXT_CYAN
    mov ebx, -1
    call gfx_print_string

    ; Nav Button: [ Home ]
    mov ecx, [win3_x]
    add ecx, 94
    mov edx, [win3_y]
    add edx, 32
    mov esi, 44
    mov r8d, 18
    mov eax, 0x001E293B
    call gfx_fill_rect
    mov ecx, [win3_x]
    add ecx, 100
    mov edx, [win3_y]
    add edx, 37
    lea rsi, [STR_BTN_HOME]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; Address / URL Bar Input Box
    mov ecx, [win3_x]
    add ecx, 144
    mov edx, [win3_y]
    add edx, 32
    mov esi, [win3_w]
    sub esi, 204                 ; Leave room for [ Go ] button
    mov r8d, 18
    mov eax, BROWSER_CLR_URL_BG
    call gfx_fill_rect

    ; Address Bar Border
    mov ecx, [win3_x]
    add ecx, 144
    mov edx, [win3_y]
    add edx, 32
    mov esi, [win3_w]
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
    mov ecx, [win3_x]
    add ecx, 150
    mov edx, [win3_y]
    add edx, 37
    lea rsi, [STR_URL_ICON]
    mov eax, COLOR_TEXT_GREEN
    mov ebx, -1
    call gfx_print_string

    ; URL Text
    mov ecx, [win3_x]
    add ecx, 172
    mov edx, [win3_y]
    add edx, 37
    lea rsi, [browser_url_buf]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; URL Cursor (if URL bar focused)
    cmp byte [browser_url_focused], 1
    jne .skip_url_cursor
    mov ecx, [win3_x]
    add ecx, 172
    mov eax, [browser_url_len]
    shl eax, 3                  ; len * 8
    add ecx, eax
    mov edx, [win3_y]
    add edx, 36
    mov esi, 8
    mov r8d, 10
    mov eax, COLOR_TEXT_CYAN
    call gfx_fill_rect
.skip_url_cursor:

    ; [ Go ] Button
    mov ecx, [win3_x]
    add ecx, [win3_w]
    sub ecx, 54
    mov edx, [win3_y]
    add edx, 32
    mov esi, 44
    mov r8d, 18
    mov eax, GUI_CLR_CYAN_ACCENT
    call gfx_fill_rect
    mov ecx, [win3_x]
    add ecx, [win3_w]
    sub ecx, 42
    mov edx, [win3_y]
    add edx, 37
    lea rsi, [STR_BTN_GO]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; 3. Bookmarks Bar (y: win3_y + 55, h: 22)
    mov ecx, [win3_x]
    add ecx, 2
    mov edx, [win3_y]
    add edx, 55
    mov esi, [win3_w]
    sub esi, 4
    mov r8d, 22
    mov eax, 0x000F172A
    call gfx_fill_rect

    ; Bookmark 1: [ Portal ]
    mov ecx, [win3_x]
    add ecx, 10
    mov edx, [win3_y]
    add edx, 58
    mov esi, 64
    mov r8d, 16
    mov eax, BROWSER_CLR_BOOKMARK_BG
    call gfx_fill_rect
    mov ecx, [win3_x]
    add ecx, 16
    mov edx, [win3_y]
    add edx, 62
    lea rsi, [STR_BM_PORTAL]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; Bookmark 2: [ Demo HTML ]
    mov ecx, [win3_x]
    add ecx, 80
    mov edx, [win3_y]
    add edx, 58
    mov esi, 78
    mov r8d, 16
    mov eax, BROWSER_CLR_BOOKMARK_BG
    call gfx_fill_rect
    mov ecx, [win3_x]
    add ecx, 86
    mov edx, [win3_y]
    add edx, 62
    lea rsi, [STR_BM_DEMO]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; Bookmark 3: [ Telemetry ]
    mov ecx, [win3_x]
    add ecx, 164
    mov edx, [win3_y]
    add edx, 58
    mov esi, 80
    mov r8d, 16
    mov eax, BROWSER_CLR_BOOKMARK_BG
    call gfx_fill_rect
    mov ecx, [win3_x]
    add ecx, 170
    mov edx, [win3_y]
    add edx, 62
    lea rsi, [STR_BM_STATUS]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; Bookmark 4: [ AFS Docs ]
    mov ecx, [win3_x]
    add ecx, 250
    mov edx, [win3_y]
    add edx, 58
    mov esi, 75
    mov r8d, 16
    mov eax, BROWSER_CLR_BOOKMARK_BG
    call gfx_fill_rect
    mov ecx, [win3_x]
    add ecx, 256
    mov edx, [win3_y]
    add edx, 62
    lea rsi, [STR_BM_AFS]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; Bookmark 5: [ Host Web ]
    mov ecx, [win3_x]
    add ecx, 331
    mov edx, [win3_y]
    add edx, 58
    mov esi, 75
    mov r8d, 16
    mov eax, BROWSER_CLR_BOOKMARK_BG
    call gfx_fill_rect
    mov ecx, [win3_x]
    add ecx, 337
    mov edx, [win3_y]
    add edx, 62
    lea rsi, [STR_BM_HOST]
    mov eax, COLOR_TEXT_WHITE
    mov ebx, -1
    call gfx_print_string

    ; 4. Webpage Viewport Area
    mov ecx, [win3_x]
    add ecx, 4
    mov edx, [win3_y]
    add edx, 78
    mov esi, [win3_w]
    sub esi, 8
    mov r8d, [win3_h]
    sub r8d, 102
    mov eax, BROWSER_CLR_PAGE_BG
    call gfx_fill_rect

    ; Viewport Inner Border
    mov ecx, [win3_x]
    add ecx, 4
    mov edx, [win3_y]
    add edx, 78
    mov esi, [win3_w]
    sub esi, 8
    mov r8d, [win3_h]
    sub r8d, 102
    mov eax, 0x001E293B
    call gfx_draw_rect

    ; 5. Parse and Render HTML Page into Viewport
    call browser_render_html_page

    ; 6. Status Bar Panel (Bottom of browser window)
    mov ecx, [win3_x]
    add ecx, 2
    mov edx, [win3_y]
    add edx, [win3_h]
    sub edx, 22
    mov esi, [win3_w]
    sub esi, 4
    mov r8d, 20
    mov eax, BROWSER_CLR_STATUS_BG
    call gfx_fill_rect

    ; Status Bar Top Line
    mov ecx, [win3_x]
    add ecx, 2
    mov edx, [win3_y]
    add edx, [win3_h]
    sub edx, 22
    mov esi, [win3_w]
    sub esi, 4
    mov r8d, 1
    mov eax, 0x001E293B
    call gfx_fill_rect

    ; Status text
    mov ecx, [win3_x]
    add ecx, 12
    mov edx, [win3_y]
    add edx, [win3_h]
    sub edx, 16
    lea rsi, [browser_status_text]
    mov eax, COLOR_TEXT_GREEN
    mov ebx, -1
    call gfx_print_string

    ; Protocol badge on right
    mov ecx, [win3_x]
    add ecx, [win3_w]
    sub ecx, 130
    mov edx, [win3_y]
    add edx, [win3_h]
    sub edx, 16
    lea rsi, [STR_STATUS_BADGE]
    mov eax, COLOR_TEXT_MUTED
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
    mov eax, [win3_x]
    add eax, 6
    mov [browser_vp_x], eax

    mov eax, [win3_y]
    add eax, 80
    mov [browser_vp_y], eax

    mov eax, [win3_w]
    sub eax, 12
    mov [browser_vp_w], eax

    mov eax, [win3_h]
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

    mov r12, browser_page_buf

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

    ; Regular Printable ASCII Character (32 .. 126)
    cmp al, 32
    jb .parse_loop
    cmp al, 126
    ja .parse_loop

    ; Line wrap check: cur_x + 8 > right_margin
    mov ecx, [browser_cur_x]
    add ecx, 8
    mov edx, [browser_vp_x]
    add edx, [browser_vp_w]
    sub edx, 24
    cmp ecx, edx
    jbe .draw_char

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
    jae .render_complete

    ; Render single glyph (AL already holds ASCII character)
    mov ecx, [browser_cur_x]      ; ECX = X
    mov edx, [browser_cur_y]      ; EDX = Y
    mov esi, [browser_text_color] ; ESI = FG Color
    mov r8d, -1                   ; R8D = Transparent background
    call gfx_draw_char

    add dword [browser_cur_x], 8
    jmp .parse_loop

.handle_newline:
    mov ecx, [browser_vp_x]
    add ecx, 20
    mov [browser_cur_x], ecx
    add dword [browser_cur_y], 14
    jmp .parse_loop

.handle_tag:
    ; Read tag name until space or '>'
    lea rdi, [browser_temp_href]
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
    imul edx, 80
    mov rdi, browser_links + 16
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
    ; 0. Skip <head>...</head>
    cmp dword [browser_temp_href], 0x64616568 ; "head"
    jne .chk_h1
.skip_head:
    mov al, [r12]
    test al, al
    jz .render_complete
    inc r12
    cmp al, '<'
    jne .skip_head
    cmp byte [r12], '/'
    jne .skip_head
    cmp dword [r12 + 1], 0x64616568 ; "/head"
    jne .skip_head
.drain_head:
    mov al, [r12]
    test al, al
    jz .render_complete
    inc r12
    cmp al, '>'
    jne .drain_head
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
    cmp word [browser_temp_href], 0x696C ; "li"
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
    cmp word [browser_temp_href], 0x6C2F ; "/l" (matches "/li")
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
    ; Starting hyperlink
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

    imul edx, 80
    mov rdi, browser_links
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
; browser_handle_click: Handles mouse clicks inside Window 3
; Input: [mouse_x], [mouse_y]
; Output: RAX = 1 if handled, 0 if outside
; ------------------------------------------------------------------------------
browser_handle_click:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov ecx, [mouse_x]
    mov edx, [mouse_y]

    ; 1. Check Window 3 Buttons (Red, Yellow, Green)
    mov eax, [win3_x]
    mov ebx, [win3_y]
    call gui_check_win_buttons
    test eax, eax
    jz .chk_browser_body
    cmp eax, 1                  ; Red (Close)
    je .close_browser
    cmp eax, 2                  ; Yellow (Minimize)
    je .min_browser
    cmp eax, 3                  ; Green (Maximize / Restore)
    je .toggle_max_browser
    jmp .chk_browser_body

.close_browser:
    mov byte [win3_state], WIN_STATE_CLOSED
    mov dword [win3_x], WIN3_DEF_X
    mov dword [win3_y], WIN3_DEF_Y
    mov dword [win3_w], WIN3_DEF_W
    mov dword [win3_h], WIN3_DEF_H
    mov byte [win_focused], 1    ; Return focus to terminal
    mov rax, 1
    jmp .browser_click_done

.min_browser:
    mov byte [win3_state], WIN_STATE_MINIMIZED
    mov dword [win3_x], WIN3_DEF_X
    mov dword [win3_y], WIN3_DEF_Y
    mov dword [win3_w], WIN3_DEF_W
    mov dword [win3_h], WIN3_DEF_H
    mov byte [win_focused], 1
    mov rax, 1
    jmp .browser_click_done

.toggle_max_browser:
    cmp byte [win3_state], WIN_STATE_MAXIMIZED
    je .restore_browser
    mov byte [win3_state], WIN_STATE_MAXIMIZED
    mov dword [win3_x], WIN_MAX_X
    mov dword [win3_y], WIN_MAX_Y
    mov dword [win3_w], WIN_MAX_W
    mov dword [win3_h], WIN_MAX_H
    mov byte [win_focused], 3
    mov rax, 1
    jmp .browser_click_done

.restore_browser:
    mov byte [win3_state], WIN_STATE_OPEN
    mov dword [win3_x], WIN3_DEF_X
    mov dword [win3_y], WIN3_DEF_Y
    mov dword [win3_w], WIN3_DEF_W
    mov dword [win3_h], WIN3_DEF_H
    mov byte [win_focused], 3
    mov rax, 1
    jmp .browser_click_done

.chk_browser_body:
    ; 2. Check if click is inside Window 3 body
    mov eax, [win3_x]
    mov ebx, [win3_y]
    mov esi, [win3_w]
    mov edi, [win3_h]
    call gui_pt_in_rect
    jz .browser_click_miss
    mov byte [win_focused], 3

    ; 3. Check Nav Toolbar Buttons (y: win3_y + 30 .. win3_y + 52)
    mov eax, [win3_y]
    add eax, 30
    cmp edx, eax
    jb .chk_bookmarks
    add eax, 22
    cmp edx, eax
    ja .chk_bookmarks

    ; [ < ] Back Button (x: win3_x + 10 .. win3_x + 34)
    mov eax, [win3_x]
    add eax, 10
    cmp ecx, eax
    jb .chk_fwd
    add eax, 24
    cmp ecx, eax
    ja .chk_fwd
    ; Back clicked!
    mov rdi, browser_url_buf
    lea rsi, [browser_prev_url]
    call strcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_fwd:
    ; [ R ] Reload Button (x: win3_x + 66 .. win3_x + 90)
    mov eax, [win3_x]
    add eax, 66
    cmp ecx, eax
    jb .chk_home
    add eax, 24
    cmp ecx, eax
    ja .chk_home
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_home:
    ; [ Home ] Button (x: win3_x + 94 .. win3_x + 138)
    mov eax, [win3_x]
    add eax, 94
    cmp ecx, eax
    jb .chk_url_bar
    add eax, 44
    cmp ecx, eax
    ja .chk_url_bar
    mov rdi, browser_url_buf
    lea rsi, [STR_URL_HOME]
    call strcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_url_bar:
    ; Address / URL Bar (x: win3_x + 144 .. win3_x + win3_w - 60)
    mov eax, [win3_x]
    add eax, 144
    cmp ecx, eax
    jb .chk_go_btn
    mov eax, [win3_x]
    add eax, [win3_w]
    sub eax, 60
    cmp ecx, eax
    ja .chk_go_btn
    ; Focused URL bar!
    mov byte [browser_url_focused], 1
    mov rax, 1
    jmp .browser_click_done

.chk_go_btn:
    ; [ Go ] Button (x: win3_x + win3_w - 54 .. win3_x + win3_w - 10)
    mov eax, [win3_x]
    add eax, [win3_w]
    sub eax, 54
    cmp ecx, eax
    jb .chk_bookmarks
    mov eax, [win3_x]
    add eax, [win3_w]
    sub eax, 10
    cmp ecx, eax
    ja .chk_bookmarks
    mov byte [browser_url_focused], 0
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_bookmarks:
    ; Unfocus URL bar if clicked outside
    mov byte [browser_url_focused], 0

    ; 4. Check Bookmarks Bar (y: win3_y + 55 .. win3_y + 76)
    mov eax, [win3_y]
    add eax, 55
    cmp edx, eax
    jb .chk_hyperlinks
    add eax, 22
    cmp edx, eax
    ja .chk_hyperlinks

    ; Bookmark 1: [ Portal ] (x: win3_x + 10 .. win3_x + 74)
    mov eax, [win3_x]
    add eax, 10
    cmp ecx, eax
    jb .chk_bm_demo
    add eax, 64
    cmp ecx, eax
    ja .chk_bm_demo
    mov rdi, browser_url_buf
    lea rsi, [STR_URL_HOME]
    call strcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_bm_demo:
    ; Bookmark 2: [ Demo HTML ] (x: win3_x + 80 .. win3_x + 158)
    mov eax, [win3_x]
    add eax, 80
    cmp ecx, eax
    jb .chk_bm_status
    add eax, 78
    cmp ecx, eax
    ja .chk_bm_status
    mov rdi, browser_url_buf
    lea rsi, [STR_URL_DEMO]
    call strcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_bm_status:
    ; Bookmark 3: [ Telemetry ] (x: win3_x + 164 .. win3_x + 244)
    mov eax, [win3_x]
    add eax, 164
    cmp ecx, eax
    jb .chk_bm_afs
    add eax, 80
    cmp ecx, eax
    ja .chk_bm_afs
    mov rdi, browser_url_buf
    lea rsi, [STR_URL_STATUS]
    call strcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_bm_afs:
    ; Bookmark 4: [ AFS Docs ] (x: win3_x + 250 .. win3_x + 325)
    mov eax, [win3_x]
    add eax, 250
    cmp ecx, eax
    jb .chk_bm_host
    add eax, 75
    cmp ecx, eax
    ja .chk_bm_host
    mov rdi, browser_url_buf
    lea rsi, [STR_URL_AFS_README]
    call strcpy
    call browser_navigate
    mov rax, 1
    jmp .browser_click_done

.chk_bm_host:
    ; Bookmark 5: [ Host Web ] (x: win3_x + 331 .. win3_x + 406)
    mov eax, [win3_x]
    add eax, 331
    cmp ecx, eax
    jb .chk_hyperlinks
    add eax, 75
    cmp ecx, eax
    ja .chk_hyperlinks
    mov rdi, browser_url_buf
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
    imul esi, 80
    mov rdi, browser_links
    add rdi, rsi

    ; Test X bounds (links[i].x1 .. links[i].x2)
    cmp ecx, [rdi + 0]
    jb .next_link
    cmp ecx, [rdi + 8]
    ja .next_link

    ; Test Y bounds (links[i].y1 .. links[i].y2)
    cmp edx, [rdi + 4]
    jb .next_link
    cmp edx, [rdi + 12]
    ja .next_link

    ; Link matched! Copy target URL and navigate!
    mov rsi, rdi
    add rsi, 16                 ; Target URL string
    mov rdi, browser_url_buf
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
; browser_handle_char: Appends printable character in AL to browser_url_buf
; ------------------------------------------------------------------------------
browser_handle_char:
    push rax
    push rcx

    mov byte [browser_url_focused], 1
    mov ecx, [browser_url_len]
    cmp ecx, (BROWSER_URL_MAX - 2)
    jae .bchar_done

    mov [browser_url_buf + rcx], al
    inc dword [browser_url_len]
    mov byte [browser_url_buf + rcx + 1], 0

    ; Redraw browser window
    call gfx_restore_cursor
    call browser_draw_window
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    call gfx_draw_cursor

.bchar_done:
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_handle_backspace: Deletes character from browser_url_buf
; ------------------------------------------------------------------------------
browser_handle_backspace:
    push rax
    push rcx

    mov byte [browser_url_focused], 1
    mov ecx, [browser_url_len]
    test ecx, ecx
    jz .bbk_done

    dec dword [browser_url_len]
    mov byte [browser_url_buf + rcx - 1], 0

    ; Redraw browser window
    call gfx_restore_cursor
    call browser_draw_window
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    call gfx_draw_cursor

.bbk_done:
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_handle_enter: Navigates to the URL typed in the address bar
; ------------------------------------------------------------------------------
browser_handle_enter:
    push rax

    mov byte [browser_url_focused], 0
    call browser_navigate

    call gfx_restore_cursor
    call browser_draw_window
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    call gfx_draw_cursor

    pop rax
    ret

; ------------------------------------------------------------------------------
; Browser Strings & Built-in HTML Pages
; ------------------------------------------------------------------------------
STR_URL_HOME:           db "http://antigravity.os/", 0
STR_URL_HOME_LEN        equ ($ - STR_URL_HOME - 1)
STR_URL_ABOUT:          db "about:home", 0
STR_URL_DEMO:           db "http://antigravity.os/demo.html", 0
STR_URL_STATUS:         db "http://antigravity.os/status", 0
STR_URL_HOST:           db "http://10.0.2.2:80/", 0
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
STR_TITLE_HOST:         db "CyberSurf - Host Web (10.0.2.2)", 0
STR_TITLE_404:          db "CyberSurf - 404 Not Found", 0
STR_TITLE_FAIL:         db "CyberSurf - Connection Error", 0

STR_STATUS_200_HOME:    db "Done (HTTP 200 OK) | Antigravity Portal", 0
STR_STATUS_200_DEMO:    db "Done (HTTP 200 OK) | HTML Showcase Demo", 0
STR_STATUS_200_STATUS:  db "Done (HTTP 200 OK) | System Telemetry", 0
STR_STATUS_HTTP_OK:     db "Connected (HTTP 200 OK) | 10.0.2.2:80", 0
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
    db "<li><a href='http://10.0.2.2:80/'>Host Gateway (10.0.2.2)</a></li>", 0x0A
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

PAGE_STATUS_HTML:
    db "<html><head><title>System Telemetry</title></head>", 0x0A
    db "<body>", 0x0A
    db "<h1>Kernel and Network Telemetry</h1>", 0x0A
    db "<hr>", 0x0A
    db "<ul>", 0x0A
    db "<li><b>CPU:</b> x86_64 64-Bit Long Mode Active</li>", 0x0A
    db "<li><b>RAM:</b> 4096 MB Physical Identity Map</li>", 0x0A
    db "<li><b>Storage:</b> AntigravityFS (AFS1) Primary ATA</li>", 0x0A
    db "<li><b>Ethernet:</b> Realtek RTL8139 PCI BusMaster</li>", 0x0A
    db "<li><b>IP:</b> 10.0.2.15 / 255.255.255.0</li>", 0x0A
    db "<li><b>Gateway:</b> 10.0.2.2 / Port 80</li>", 0x0A
    db "<li><b>Mouse:</b> PS/2 8042 Auxiliary Active</li>", 0x0A
    db "</ul>", 0x0A
    db "<hr>", 0x0A
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
