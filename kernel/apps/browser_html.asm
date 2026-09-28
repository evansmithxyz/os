; ==============================================================================
; Antigravity OS - CyberSurf HTML layout
; ------------------------------------------------------------------------------
; Lays out browser_page_buf into the browser viewport on every redraw:
;   - whitespace collapses to single spaces (except inside <pre> and for
;     plain-text pages); text wraps at word boundaries
;   - block elements (p, div, h1-h6, li, tr, section, ...) start new lines;
;     table cells are spaced apart; lists are indented
;   - entities (named, &#123; and &#x1F;) and UTF-8 or Latin-1 text become the
;     closest ASCII the 8x8 font can show
;   - <script>, <style>, <title>, <svg>, <select>, ... are not shown;
;     <img alt> shows as [alt]
;   - links remember one clickable box per line they cover, and point back into
;     the page buffer for their href (resolved on click)
; The page scrolls by browser_scroll pixels. Laying out stops at the bottom of
; the viewport; browser_more says whether the page goes on.
; ==============================================================================

[bits 64]

HTML_LINE_H             equ 14
HTML_WORD_MAX           equ 120
HTML_MARGIN             equ 20      ; left margin inside the viewport
HTML_LIST_INDENT        equ 16

HTML_CLR_TEXT           equ 0x00CBD5E1
HTML_CLR_BOLD           equ 0x00FFFFFF
HTML_CLR_LINK           equ 0x0038BDF8
HTML_CLR_CODE           equ 0x0010B981
HTML_CLR_H1             equ 0x0000F0FF
HTML_CLR_H2             equ 0x00F59E0B
HTML_CLR_H3             equ 0x0034D399
HTML_CLR_RULE           equ 0x001E293B

; link table entry
LINK_X1                 equ 0       ; dd screen box
LINK_Y1                 equ 4
LINK_X2                 equ 8
LINK_Y2                 equ 12
LINK_HREF               equ 16      ; dq into browser_page_buf
LINK_HREF_LEN           equ 24      ; dd
BROWSER_LINK_SIZE       equ 32
BROWSER_MAX_LINKS       equ 128

; tag actions
TAG_BLOCK               equ 1
TAG_P                   equ 2
TAG_H1                  equ 3
TAG_H2                  equ 4
TAG_H3                  equ 5
TAG_BR                  equ 6
TAG_HR                  equ 7
TAG_LI                  equ 8
TAG_LIST                equ 9
TAG_CELL                equ 10
TAG_BOLD                equ 11
TAG_CODE                equ 12
TAG_PRE                 equ 13
TAG_A                   equ 14
TAG_IMG                 equ 15
TAG_SKIP                equ 16
TAG_ROW                 equ 17

section .data
align 4
browser_scroll:         dd 0        ; pixels scrolled down
browser_more:           db 0        ; 1 = the page continues below the viewport
browser_page_plain:     db 0        ; 1 = plain text: keep line breaks and spaces
browser_page_latin1:    db 0        ; 1 = bytes 0x80-0xFF are Latin-1, not UTF-8

section .bss
alignb 16
browser_links:          resb BROWSER_MAX_LINKS * BROWSER_LINK_SIZE
html_word:              resb HTML_WORD_MAX
html_tag:               resb 16
html_attr_name:         resb 16
alignb 8
html_href:              resq 1
html_link_href:         resq 1
html_alt:               resq 1
html_href_len:          resd 1
html_link_href_len:     resd 1
html_alt_len:           resd 1
html_x:                 resd 1      ; pen position (screen x)
html_y:                 resd 1      ; top of the current line (document y)
html_left:              resd 1      ; line start (screen x), with list indent
html_right:             resd 1      ; wrap limit (screen x)
html_top:               resd 1      ; screen y of document y 0
html_clip_top:          resd 1      ; visible screen rows
html_clip_bottom:       resd 1
html_word_len:          resd 1
html_link_line:         resd 1      ; document y of the current link box
html_link_entry:        resd 1
html_space:             resb 1      ; a space is pending before the next word
html_pre:               resb 1
html_bold:              resb 1
html_code:              resb 1
html_heading:           resb 1
html_link:              resb 1
html_stop:              resb 1
html_closing:           resb 1
html_cell:              resb 1      ; inside a table cell: blocks flow inline
html_last_link:         resb 1      ; the last word drawn was part of a link

section .text
; ------------------------------------------------------------------------------
; browser_render_html_page: lay out and draw browser_page_buf in the viewport
; (window geometry in br_wx/br_wy/br_ww/br_wh)
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

    ; viewport: x+6, y+80, w-12, h-104 of the window frame
    mov eax, [br_wx]
    add eax, 6
    mov [browser_vp_x], eax
    add eax, HTML_MARGIN
    mov [html_left], eax
    mov [html_x], eax
    mov eax, [br_wy]
    add eax, 80
    mov [browser_vp_y], eax
    lea ecx, [eax + 4]
    mov [html_clip_top], ecx
    add eax, 12
    sub eax, [browser_scroll]
    mov [html_top], eax
    mov eax, [br_ww]
    sub eax, 12
    mov [browser_vp_w], eax
    add eax, [browser_vp_x]
    sub eax, 24
    mov [html_right], eax
    mov eax, [br_wh]
    sub eax, 104
    mov [browser_vp_h], eax
    add eax, [browser_vp_y]
    sub eax, 6
    mov [html_clip_bottom], eax

    xor eax, eax
    mov [html_y], eax
    mov [html_word_len], eax
    mov [browser_link_count], eax
    mov [html_space], al
    mov [html_bold], al
    mov [html_code], al
    mov [html_heading], al
    mov [html_link], al
    mov [html_stop], al
    mov [html_cell], al
    mov [html_last_link], al
    mov dword [html_link_line], -1
    mov al, [browser_page_plain]
    mov [html_pre], al

    lea r12, [abs browser_page_buf]
.loop:
    cmp byte [html_stop], 0
    jne .stopped
    mov al, [r12]
    test al, al
    jz .end_of_page
    inc r12
    cmp al, '<'
    je .tag
    cmp al, '&'
    je .entity
    cmp al, 0x0A
    je .line_feed
    cmp al, ' '
    jbe .white
    cmp al, 0x80
    jae .high
    call html_add_char
    jmp .loop
.white:
    cmp al, 0x0D
    je .loop
    cmp byte [html_pre], 0
    je .collapse
    cmp al, 0x09
    jne .pre_space
    mov al, ' '                     ; a tab is four spaces in <pre>
    call html_add_char
    call html_add_char
    call html_add_char
.pre_space:
    mov al, ' '
    call html_add_char
    jmp .loop
.collapse:
    call html_flush_word
    mov byte [html_space], 1
    jmp .loop
.line_feed:
    cmp byte [html_pre], 0
    je .collapse
    call html_flush_word
    call html_newline
    jmp .loop
.entity:
    call html_entity
    jmp .loop
.high:
    call html_high_byte
    jmp .loop
.tag:
    call html_tag_open
    jmp .loop

.end_of_page:
    call html_flush_word
    mov byte [browser_more], 0
    ; the whole page is laid out: do not scroll past its end
    mov eax, [html_y]
    add eax, HTML_LINE_H * 2        ; page height plus a little room
    mov ecx, [html_clip_bottom]
    sub ecx, [html_clip_top]        ; viewport height
    sub eax, ecx
    jns .have_max
    xor eax, eax
.have_max:
    cmp [browser_scroll], eax
    jle .done
    mov [browser_scroll], eax
    mov byte [gui_dirty], 1         ; draw again at the clamped position,
    jmp .restore                    ; which is the frame to log
.stopped:
    mov byte [browser_more], 1
.done:
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

; ==============================================================================
; Lines and words
; ==============================================================================

; html_newline: pen to the start of the next line; stop once below the viewport
html_newline:
    push rax
    mov eax, [html_left]
    mov [html_x], eax
    add dword [html_y], HTML_LINE_H
    mov byte [html_space], 0
    mov eax, [html_y]
    add eax, [html_top]
    cmp eax, [html_clip_bottom]
    jl .ret
    mov byte [html_stop], 1
.ret:
    pop rax
    ret

; html_block: end the current line (if anything is on it). Inside a table
; cell it only separates words: cells of a row stay on one line.
html_block:
    push rax
    call html_flush_word
    cmp byte [html_cell], 0
    je .line
    mov byte [html_space], 1
    pop rax
    ret
.line:
    mov eax, [html_x]
    cmp eax, [html_left]
    jle .ret
    call html_newline
.ret:
    mov byte [html_space], 0
    pop rax
    ret

; html_gap: ECX = pixels of extra space below the line (none at the very top
; or inside a table cell)
html_gap:
    cmp dword [html_y], 0
    je .ret
    cmp byte [html_cell], 0
    jne .ret
    add [html_y], ecx
.ret:
    ret

; html_add_char: AL = character for the current word
html_add_char:
    push rcx
    push rdi
    mov ecx, [html_word_len]
    cmp ecx, HTML_WORD_MAX
    jb .add
    call html_flush_word
    xor ecx, ecx
.add:
    lea rdi, [html_word]
    mov [rdi + rcx], al
    inc ecx
    mov [html_word_len], ecx
    pop rdi
    pop rcx
    ret

; html_color: -> ESI = colour for text at this point
html_color:
    mov esi, HTML_CLR_LINK
    cmp byte [html_link], 0
    jne .ret
    mov esi, HTML_CLR_H1
    cmp byte [html_heading], 1
    je .ret
    mov esi, HTML_CLR_H2
    cmp byte [html_heading], 2
    je .ret
    mov esi, HTML_CLR_H3
    cmp byte [html_heading], 3
    je .ret
    mov esi, HTML_CLR_CODE
    cmp byte [html_code], 0
    jne .ret
    mov esi, HTML_CLR_BOLD
    cmp byte [html_bold], 0
    jne .ret
    mov esi, HTML_CLR_TEXT
.ret:
    ret

; ------------------------------------------------------------------------------
; html_flush_word: place the collected word: after the pending space if it
; fits, otherwise on the next line (a word wider than a line is broken)
; ------------------------------------------------------------------------------
html_flush_word:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r9d, [html_word_len]
    test r9d, r9d
    jz .ret
    mov edx, r9d
    shl edx, 3                      ; EDX = word width
    mov eax, [html_x]
    cmp byte [html_space], 0
    je .no_space
    cmp eax, [html_left]
    jle .no_space                   ; no space at the start of a line
    lea ebx, [eax + edx + 8]
    cmp ebx, [html_right]
    jg .wrap
    ; the space: logged, and underlined only between two words of one link
    mov bl, [html_link]
    and bl, [html_last_link]
    xchg bl, [html_link]
    mov al, ' '
    call html_glyph
    mov [html_link], bl
    add dword [html_x], 8
    jmp .draw
.no_space:
    lea ebx, [eax + edx]
    cmp ebx, [html_right]
    jle .draw
    cmp eax, [html_left]
    jle .draw                       ; alone on its line: break it where it must
.wrap:
    call html_newline
.draw:
    mov byte [html_space], 0
    xor r8d, r8d                    ; character index
.char:
    cmp r8d, r9d
    jae .drawn
    mov eax, [html_x]
    add eax, 8
    cmp eax, [html_right]
    jle .fits
    mov eax, [html_x]
    cmp eax, [html_left]
    jle .fits
    call html_newline
.fits:
    lea rdi, [html_word]
    mov al, [rdi + r8]
    call html_glyph
    add dword [html_x], 8
    inc r8d
    jmp .char
.drawn:
    mov dword [html_word_len], 0
    mov al, [html_link]
    mov [html_last_link], al
.ret:
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
; html_glyph: AL = character at the pen, if its line is inside the viewport.
; Inside a link it is underlined and added to the line's link box.
; ------------------------------------------------------------------------------
html_glyph:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov edx, [html_y]
    add edx, [html_top]             ; EDX = screen y
    cmp edx, [html_clip_top]
    jl .ret
    lea ecx, [edx + 10]
    cmp ecx, [html_clip_bottom]
    jg .ret
    call browser_log_char
    mov ecx, [html_x]
    call html_color
    mov r8d, -1
    call gfx_draw_char
    cmp byte [html_link], 0
    je .ret
    ; underline
    push rdx
    add edx, 9
    mov esi, 8
    mov r8d, 1
    mov eax, HTML_CLR_LINK
    call gfx_fill_rect
    pop rdx
    ; one box per link per line
    mov eax, [html_y]
    cmp eax, [html_link_line]
    je .extend
    mov eax, [browser_link_count]
    cmp eax, BROWSER_MAX_LINKS
    jae .ret
    mov [html_link_entry], eax
    inc dword [browser_link_count]
    mov ebx, [html_y]
    mov [html_link_line], ebx
    imul eax, BROWSER_LINK_SIZE
    lea rdi, [browser_links]
    add rdi, rax
    mov [rdi + LINK_X1], ecx
    mov [rdi + LINK_Y1], edx
    lea eax, [edx + 11]
    mov [rdi + LINK_Y2], eax
    mov rax, [html_link_href]
    mov [rdi + LINK_HREF], rax
    mov eax, [html_link_href_len]
    mov [rdi + LINK_HREF_LEN], eax
    jmp .set_x2
.extend:
    mov eax, [html_link_entry]
    imul eax, BROWSER_LINK_SIZE
    lea rdi, [browser_links]
    add rdi, rax
.set_x2:
    lea eax, [ecx + 8]
    mov [rdi + LINK_X2], eax
.ret:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; browser_log_char: AL = glyph being drawn. While browser_log_text is set,
; collects the first visible text for the "[klog] browser text:" line: runs of
; spaces and line changes become one space.
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
    mov edx, [html_y]
    cmp edx, [browser_log_y]
    je .check_space
    mov byte [rdi + rcx], ' '       ; new line
    inc ecx
    cmp al, ' '
    je .terminate
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
    mov edx, [html_y]
    mov [browser_log_y], edx
.done:
    pop rdi
    pop rdx
    pop rcx
.ret:
    ret

; ==============================================================================
; Characters
; ==============================================================================

; ------------------------------------------------------------------------------
; html_emit_cp: EAX = Unicode code point -> the closest ASCII into the word
; ------------------------------------------------------------------------------
html_emit_cp:
    push rax
    push rsi
    cmp eax, 0x7F
    jae .table
    cmp eax, ' '
    jae .ascii
    cmp eax, 0x09                   ; tab / newline from a numeric entity
    je .space
    cmp eax, 0x0A
    jne .ret
.space:
    mov eax, ' '
.ascii:
    call html_add_char
    jmp .ret
.table:
    ; Latin-1 letters by table
    cmp eax, 0xC0
    jb .ranges
    cmp eax, 0xFF
    ja .ranges
    lea rsi, [html_latin1_letters]
    mov al, [rsi + rax - 0xC0]
    call html_add_char
    jmp .ret
.ranges:
    ; html_cp_map: dd first, last, db replacement (4 bytes, NUL-padded)
    lea rsi, [html_cp_map]
.range:
    cmp dword [rsi], 0xFFFFFFFF
    je .unknown
    cmp eax, [rsi]
    jb .next
    cmp eax, [rsi + 4]
    jbe .found
.next:
    add rsi, 12
    jmp .range
.found:
    add rsi, 8
.put:
    mov al, [rsi]
    test al, al
    jz .ret
    call html_add_char
    inc rsi
    jmp .put
.unknown:
    cmp eax, 0x10000                ; emoji and other astral symbols: nothing
    jae .ret
    mov al, '?'
    call html_add_char
.ret:
    pop rsi
    pop rax
    ret

; ------------------------------------------------------------------------------
; html_high_byte: AL = byte >= 0x80 (R12 after it) -> UTF-8 sequence, or a
; Latin-1 / Windows-1252 character on pages that say so
; ------------------------------------------------------------------------------
html_high_byte:
    push rax
    push rcx
    push rdx
    movzx eax, al
    cmp byte [browser_page_latin1], 0
    je .utf8
    cmp eax, 0xA0
    jae .emit
    lea rdx, [html_cp1252]          ; 0x80-0x9F
    movzx eax, word [rdx + rax * 2 - 0x100]
    jmp .emit
.utf8:
    cmp eax, 0xC0
    jb .done                        ; stray continuation byte
    mov ecx, 1
    and eax, 0x1F
    cmp byte [r12 - 1], 0xE0
    jb .continue
    mov ecx, 2
    movzx eax, byte [r12 - 1]
    and eax, 0x0F
    cmp byte [r12 - 1], 0xF0
    jb .continue
    mov ecx, 3
    movzx eax, byte [r12 - 1]
    and eax, 0x07
    cmp byte [r12 - 1], 0xF8
    jae .done
.continue:
    movzx edx, byte [r12]
    mov dh, dl
    and dh, 0xC0
    cmp dh, 0x80
    jne .bad
    and edx, 0x3F
    shl eax, 6
    or eax, edx
    inc r12
    dec ecx
    jnz .continue
.emit:
    call html_emit_cp
    jmp .done
.bad:
    mov eax, '?'
    call html_add_char
.done:
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; html_entity: R12 = just after '&'. "&name;", "&#123;" or "&#x1F;" become
; their character; anything else is a literal '&'.
; ------------------------------------------------------------------------------
html_entity:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rbx, r12                    ; RBX = where to go back to
    cmp byte [r12], '#'
    jne .named
    inc r12
    xor eax, eax
    xor ecx, ecx                    ; digits seen
    mov edx, 10
    mov dil, [r12]
    or dil, 0x20
    cmp dil, 'x'
    jne .number
    mov edx, 16
    inc r12
.number:
    movzx edi, byte [r12]
    cmp edi, ';'
    je .number_end
    or edi, 0x20                    ; lower case for a-f
    sub edi, '0'
    cmp edi, 9
    jbe .digit
    cmp edx, 16
    jne .literal
    sub edi, 'a' - '0'
    cmp edi, 5
    ja .literal
    add edi, 10
.digit:
    cmp ecx, 7
    jae .literal
    imul eax, edx
    add eax, edi
    inc ecx
    inc r12
    jmp .number
.number_end:
    test ecx, ecx
    jz .literal
    inc r12
    call html_emit_cp
    jmp .out
.named:
    ; look the name up; old pages leave out the ';' ("&copy 2026"), which is
    ; accepted when no letter or digit follows the name
    lea rsi, [html_entities]
.entry:
    movzx ecx, byte [rsi]           ; name length with ';'
    test ecx, ecx
    jz .literal
    lea rdi, [rsi + 1]
    push rcx
    push rsi
    dec ecx                         ; the name without ';'
    mov rsi, r12
    xchg rsi, rdi
    repe cmpsb
    pop rsi
    pop rcx
    jne .next_entry
    mov al, [r12 + rcx - 1]         ; what follows the name
    cmp al, ';'
    je .match
    dec ecx                         ; no ';' to skip
    or al, 0x20
    cmp al, 'a'
    jb .digit_after
    cmp al, 'z'
    jbe .restore_len
.digit_after:
    cmp al, '0' | 0x20
    jb .match
    cmp al, '9' | 0x20
    ja .match
.restore_len:
    inc ecx
.next_entry:
    lea rsi, [rsi + rcx + 3]
    jmp .entry
.match:
    add r12, rcx
    movzx eax, byte [rsi]           ; the table's own length, for the code point
    movzx eax, word [rsi + rax + 1]
    call html_emit_cp
    jmp .out
.literal:
    mov r12, rbx
    mov eax, '&'
    call html_add_char
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; Tags
; ==============================================================================

; ------------------------------------------------------------------------------
; html_tag_open: R12 = just after '<'. Reads the tag and its attributes and
; applies it. "<" that does not start a tag is shown as text.
; ------------------------------------------------------------------------------
html_tag_open:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    ; <!-- comment -->, <!DOCTYPE>, <?xml?>
    cmp byte [r12], '!'
    jne .not_bang
    cmp word [r12 + 1], '--'
    jne .skip_to_gt
.comment:
    mov al, [r12]
    test al, al
    jz .done
    inc r12
    cmp al, '-'
    jne .comment
    cmp word [r12], '->'
    jne .comment
    add r12, 2
    jmp .done
.not_bang:
    cmp byte [r12], '?'
    je .skip_to_gt

    mov byte [html_closing], 0
    cmp byte [r12], '/'
    jne .name
    mov byte [html_closing], 1
    inc r12
.name:
    lea rdi, [html_tag]
    xor ecx, ecx
.name_char:
    mov al, [r12]
    cmp al, '0'
    jb .name_end
    cmp al, '9'
    ja .letter
    test ecx, ecx                   ; a name starts with a letter ("a <3 b" is text)
    jz .name_end
    jmp .name_store
.letter:
    or al, 0x20
    cmp al, 'a'
    jb .name_end
    cmp al, 'z'
    ja .name_end
.name_store:
    inc r12
    cmp ecx, 15
    jae .name_char
    mov [rdi + rcx], al
    inc ecx
    jmp .name_char
.name_end:
    mov byte [rdi + rcx], 0
    test ecx, ecx
    jnz .attributes
    ; not a tag: show the '<' (and the '/')
    mov al, '<'
    call html_add_char
    cmp byte [html_closing], 0
    je .done
    mov al, '/'
    call html_add_char
    jmp .done
.attributes:
    call html_attributes
    call html_tag_apply
    jmp .done
.skip_to_gt:
    mov al, [r12]
    test al, al
    jz .done
    inc r12
    cmp al, '>'
    jne .skip_to_gt
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; html_attributes: R12 = after the tag name -> past the closing '>'.
; html_href / html_alt = those attributes' values (0 if absent).
; Quoted values may contain '>'.
; ------------------------------------------------------------------------------
html_attributes:
    push rax
    push rcx
    push rdx
    push rdi
    xor eax, eax
    mov [html_href], rax
    mov [html_alt], rax
    mov [html_href_len], eax
    mov [html_alt_len], eax
.next:
    mov al, [r12]
    test al, al
    jz .done
    cmp al, '>'
    je .end_tag
    cmp al, ' '
    jbe .skip
    cmp al, '/'
    je .skip
    ; attribute name
    lea rdi, [html_attr_name]
    xor ecx, ecx
.attr_char:
    mov al, [r12]
    cmp al, '='
    je .attr_end
    cmp al, '>'
    je .attr_end
    cmp al, ' '
    jbe .attr_end
    test al, al
    jz .attr_end
    inc r12
    cmp ecx, 15
    jae .attr_char
    or al, 0x20
    mov [rdi + rcx], al
    inc ecx
    jmp .attr_char
.attr_end:
    mov byte [rdi + rcx], 0
.space1:
    cmp byte [r12], ' '
    ja .equals
    cmp byte [r12], 0
    je .done
    inc r12
    jmp .space1
.equals:
    cmp byte [r12], '='
    jne .next                       ; attribute without a value
    inc r12
.space2:
    cmp byte [r12], ' '
    ja .value
    cmp byte [r12], 0
    je .done
    inc r12
    jmp .space2
.value:
    mov al, [r12]
    cmp al, '"'
    je .quoted
    cmp al, "'"
    je .quoted
    mov rdx, r12                    ; unquoted: up to a space or '>'
.unquoted:
    mov al, [r12]
    cmp al, '>'
    je .have_value
    cmp al, ' '
    jbe .have_value
    inc r12
    jmp .unquoted
.quoted:
    inc r12
    mov rdx, r12
.in_quote:
    movzx ecx, byte [r12]
    test cl, cl
    jz .have_value
    cmp cl, al
    je .close_quote
    inc r12
    jmp .in_quote
.close_quote:
    mov rcx, r12
    inc r12
    jmp .store
.have_value:
    mov rcx, r12
.store:
    sub rcx, rdx                    ; RDX = value, ECX = its length
    cmp dword [html_attr_name], 'href'
    jne .not_href
    cmp byte [html_attr_name + 4], 0
    jne .next
    mov [html_href], rdx
    mov [html_href_len], ecx
    jmp .next
.not_href:
    cmp dword [html_attr_name], 'alt'
    jne .next
    mov [html_alt], rdx
    mov [html_alt_len], ecx
    jmp .next
.skip:
    inc r12
    jmp .next
.end_tag:
    inc r12
.done:
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; html_tag_apply: html_tag (lower case), html_closing -> layout changes
; ------------------------------------------------------------------------------
html_tag_apply:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    ; find the tag: db length, name, action
    lea rsi, [html_tags]
.find:
    movzx ecx, byte [rsi]
    test ecx, ecx
    jz .done                        ; unknown tags change nothing
    lea rdi, [rsi + 1]
    push rsi
    push rcx
    lea rsi, [html_tag]
    repe cmpsb
    pop rcx
    pop rsi
    jne .next
    cmp byte [html_tag + rcx], 0    ; the whole name, not a prefix
    je .found
.next:
    lea rsi, [rsi + rcx + 2]
    jmp .find
.found:
    movzx eax, byte [rsi + rcx + 1]
    mov bl, [html_closing]

    cmp eax, TAG_SKIP
    je .skip
    ; everything else ends the word collected so far (it may change colour)
    call html_flush_word
    cmp eax, TAG_BLOCK
    je .block
    cmp eax, TAG_ROW
    je .row
    cmp eax, TAG_P
    je .paragraph
    cmp eax, TAG_H1
    jb .not_heading
    cmp eax, TAG_H3
    jbe .heading
.not_heading:
    cmp eax, TAG_BR
    je .br
    cmp eax, TAG_HR
    je .hr
    cmp eax, TAG_LI
    je .li
    cmp eax, TAG_LIST
    je .list
    cmp eax, TAG_CELL
    je .cell
    cmp eax, TAG_BOLD
    je .bold
    cmp eax, TAG_CODE
    je .code
    cmp eax, TAG_PRE
    je .pre
    cmp eax, TAG_A
    je .anchor
    cmp eax, TAG_IMG
    je .img
    jmp .done

.block:
    call html_block
    jmp .done
.row:
    mov byte [html_cell], 0         ; a row (or table) starts outside any cell
    call html_block
    jmp .done
.paragraph:
    call html_block
    mov ecx, 6
    call html_gap
    jmp .done
.heading:
    call html_block
    test bl, bl
    jnz .heading_end
    mov ecx, 8
    call html_gap
    sub eax, TAG_H1 - 1
    mov [html_heading], al           ; 1, 2 or 3
    jmp .done
.heading_end:
    mov byte [html_heading], 0
    mov ecx, 6
    call html_gap
    jmp .done
.br:
    test bl, bl
    jnz .done
    call html_newline
    jmp .done
.hr:
    call html_block
    mov ecx, 4
    call html_gap
    mov edx, [html_y]
    add edx, [html_top]
    add edx, 6
    cmp edx, [html_clip_top]
    jl .hr_done
    cmp edx, [html_clip_bottom]
    jg .hr_done
    mov ecx, [browser_vp_x]
    add ecx, HTML_MARGIN
    mov esi, [browser_vp_w]
    sub esi, HTML_MARGIN * 2
    mov r8d, 1
    mov eax, HTML_CLR_RULE
    call gfx_fill_rect
.hr_done:
    call html_newline
    jmp .done
.li:
    call html_block
    test bl, bl
    jnz .done
    ; bullet left of the text
    mov edx, [html_y]
    add edx, [html_top]
    cmp edx, [html_clip_top]
    jl .done
    lea eax, [edx + 10]
    cmp eax, [html_clip_bottom]
    jg .done
    add edx, 3
    mov ecx, [html_left]
    sub ecx, 10
    mov esi, 4
    mov r8d, 4
    mov eax, HTML_CLR_LINK
    call gfx_fill_rect
    jmp .done
.list:
    call html_block
    mov eax, HTML_LIST_INDENT
    test bl, bl
    jz .indent
    neg eax
.indent:
    add eax, [html_left]
    mov ecx, [browser_vp_x]
    add ecx, HTML_MARGIN
    cmp eax, ecx                    ; never left of the margin
    jge .indent_ok
    mov eax, ecx
.indent_ok:
    mov ecx, [html_right]
    sub ecx, 160
    cmp eax, ecx                    ; nor so deep there is no room left
    jle .indent_set
    mov eax, ecx
.indent_set:
    mov [html_left], eax
    mov [html_x], eax
    jmp .done
.cell:
    test bl, bl
    jnz .cell_end
    inc byte [html_cell]
    mov eax, [html_x]
    cmp eax, [html_left]
    jle .done
    add dword [html_x], 8           ; gap between table cells: 8 + a space
    mov byte [html_space], 1
    jmp .done
.cell_end:
    cmp byte [html_cell], 0
    je .done
    dec byte [html_cell]
    jmp .done
.bold:
    lea rdi, [html_bold]
    jmp .count
.code:
    lea rdi, [html_code]
.count:
    test bl, bl
    jnz .count_down
    inc byte [rdi]
    jmp .done
.count_down:
    cmp byte [rdi], 0
    je .done
    dec byte [rdi]
    jmp .done
.pre:
    call html_block
    lea rdi, [html_code]
    test bl, bl
    jnz .pre_end
    inc byte [html_pre]
    inc byte [rdi]
    jmp .done
.pre_end:
    cmp byte [html_pre], 0
    je .done
    dec byte [html_pre]
    dec byte [rdi]
    jmp .done
.anchor:
    mov byte [html_link], 0
    mov dword [html_link_line], -1
    test bl, bl
    jnz .done
    mov rax, [html_href]
    test rax, rax
    jz .done
    mov [html_link_href], rax
    mov eax, [html_href_len]
    mov [html_link_href_len], eax
    mov byte [html_link], 1
    jmp .done
.img:
    mov ecx, [html_alt_len]
    test ecx, ecx
    jz .done
    cmp ecx, 60
    jbe .alt
    mov ecx, 60
.alt:
    mov rsi, [html_alt]
    mov al, '['
    call html_add_char
.alt_char:
    mov al, [rsi]
    cmp al, ' '
    jae .alt_put
    mov al, ' '
.alt_put:
    call html_add_char
    inc rsi
    dec ecx
    jnz .alt_char
    mov al, ']'
    call html_add_char
    mov byte [html_space], 1
    jmp .done
.skip:
    test bl, bl
    jnz .done
    call html_skip_element
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; html_skip_element: R12 = after <name ...> -> after its </name> (html_tag)
html_skip_element:
    push rax
    push rcx
    push rdx
    push rdi
    lea rdi, [html_tag]
.scan:
    mov al, [r12]
    test al, al
    jz .done
    inc r12
    cmp al, '<'
    jne .scan
    cmp byte [r12], '/'
    jne .scan
    xor ecx, ecx
.compare:
    mov al, [rdi + rcx]
    test al, al
    jz .matched
    mov dl, [r12 + rcx + 1]
    or dl, 0x20
    cmp dl, al
    jne .scan
    inc ecx
    jmp .compare
.matched:
    mov al, [r12]
    test al, al
    jz .done
    inc r12
    cmp al, '>'
    jne .matched
.done:
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; ==============================================================================
; Tables
; ==============================================================================
section .rodata
; tags: db name length, name, action
%macro HTAG 2
    db %%end - %%start
%%start:
    db %1
%%end:
    db %2
%endmacro
html_tags:
    HTAG "a", TAG_A
    HTAG "p", TAG_P
    HTAG "br", TAG_BR
    HTAG "div", TAG_BLOCK
    HTAG "li", TAG_LI
    HTAG "td", TAG_CELL
    HTAG "th", TAG_CELL
    HTAG "tr", TAG_ROW
    HTAG "span", 0
    HTAG "b", TAG_BOLD
    HTAG "strong", TAG_BOLD
    HTAG "h1", TAG_H1
    HTAG "h2", TAG_H2
    HTAG "h3", TAG_H3
    HTAG "h4", TAG_H3
    HTAG "h5", TAG_H3
    HTAG "h6", TAG_H3
    HTAG "ul", TAG_LIST
    HTAG "ol", TAG_LIST
    HTAG "dl", TAG_LIST
    HTAG "blockquote", TAG_LIST
    HTAG "dt", TAG_BLOCK
    HTAG "dd", TAG_BLOCK
    HTAG "table", TAG_ROW
    HTAG "caption", TAG_BLOCK
    HTAG "section", TAG_BLOCK
    HTAG "article", TAG_BLOCK
    HTAG "header", TAG_BLOCK
    HTAG "footer", TAG_BLOCK
    HTAG "nav", TAG_BLOCK
    HTAG "main", TAG_BLOCK
    HTAG "aside", TAG_BLOCK
    HTAG "form", TAG_BLOCK
    HTAG "fieldset", TAG_BLOCK
    HTAG "figure", TAG_BLOCK
    HTAG "figcaption", TAG_BLOCK
    HTAG "center", TAG_BLOCK
    HTAG "address", TAG_BLOCK
    HTAG "details", TAG_BLOCK
    HTAG "summary", TAG_BLOCK
    HTAG "hr", TAG_HR
    HTAG "code", TAG_CODE
    HTAG "tt", TAG_CODE
    HTAG "kbd", TAG_CODE
    HTAG "samp", TAG_CODE
    HTAG "pre", TAG_PRE
    HTAG "img", TAG_IMG
    HTAG "script", TAG_SKIP
    HTAG "style", TAG_SKIP
    HTAG "title", TAG_SKIP
    HTAG "svg", TAG_SKIP
    HTAG "template", TAG_SKIP
    HTAG "select", TAG_SKIP
    HTAG "textarea", TAG_SKIP
    HTAG "iframe", TAG_SKIP
    HTAG "object", TAG_SKIP
    HTAG "math", TAG_SKIP
    db 0

; named entities: db length (with ';'), name, dw code point
%macro HENT 2
    db %%end - %%start
%%start:
    db %1, ';'
%%end:
    dw %2
%endmacro
html_entities:
    HENT "amp", '&'
    HENT "lt", '<'
    HENT "gt", '>'
    HENT "quot", '"'
    HENT "apos", "'"
    HENT "nbsp", 0xA0
    HENT "copy", 0xA9
    HENT "reg", 0xAE
    HENT "trade", 0x2122
    HENT "raquo", 0xBB
    HENT "laquo", 0xAB
    HENT "hellip", 0x2026
    HENT "mdash", 0x2014
    HENT "ndash", 0x2013
    HENT "lsquo", 0x2018
    HENT "rsquo", 0x2019
    HENT "sbquo", 0x201A
    HENT "ldquo", 0x201C
    HENT "rdquo", 0x201D
    HENT "bdquo", 0x201E
    HENT "middot", 0xB7
    HENT "bull", 0x2022
    HENT "times", 0xD7
    HENT "divide", 0xF7
    HENT "deg", 0xB0
    HENT "plusmn", 0xB1
    HENT "para", 0xB6
    HENT "sect", 0xA7
    HENT "euro", 0x20AC
    HENT "pound", 0xA3
    HENT "yen", 0xA5
    HENT "cent", 0xA2
    HENT "larr", 0x2190
    HENT "rarr", 0x2192
    HENT "uarr", 0x2191
    HENT "darr", 0x2193
    HENT "harr", 0x2194
    HENT "ensp", 0x2002
    HENT "emsp", 0x2003
    HENT "thinsp", 0x2009
    HENT "zwj", 0x200D
    HENT "zwnj", 0x200C
    HENT "shy", 0xAD
    HENT "minus", 0x2212
    HENT "prime", 0x2032
    HENT "eacute", 0xE9
    HENT "egrave", 0xE8
    HENT "aacute", 0xE1
    HENT "agrave", 0xE0
    HENT "iacute", 0xED
    HENT "oacute", 0xF3
    HENT "uacute", 0xFA
    HENT "ccedil", 0xE7
    HENT "ntilde", 0xF1
    HENT "auml", 0xE4
    HENT "ouml", 0xF6
    HENT "uuml", 0xFC
    HENT "szlig", 0xDF
    db 0

; U+00C0 - U+00FF as plain letters
html_latin1_letters:
    db "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYTs"
    db "aaaaaaaceeeeiiiidnooooo/ouuuuyty"

; Windows-1252 0x80-0x9F as code points
html_cp1252:
    dw 0x20AC, '?', 0x201A, 'f', 0x201E, 0x2026, '+', '+', '^', '%', 'S', 0x2039, 'O', '?', 'Z', '?'
    dw '?', 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, '~', 0x2122, 's', 0x203A, 'o', '?', 'z', 'Y'

; other code points: dd first, last, then up to 4 replacement bytes (0 = none)
%macro HCPS 3
    dd %1, %2
%%s:
    db %3
%%e:
    times 4 - (%%e - %%s) db 0
%endmacro
html_cp_map:
    HCPS 0x7F, 0x9F, ""                 ; controls
    HCPS 0xA0, 0xA0, " "
    HCPS 0xA1, 0xA1, "!"
    HCPS 0xA2, 0xA2, "c"
    HCPS 0xA3, 0xA3, "L"
    HCPS 0xA4, 0xA4, "$"
    HCPS 0xA5, 0xA5, "Y"
    HCPS 0xA6, 0xA6, "|"
    HCPS 0xA7, 0xA7, "S"
    HCPS 0xA8, 0xA8, '"'
    HCPS 0xA9, 0xA9, "(c)"
    HCPS 0xAA, 0xAA, "a"
    HCPS 0xAB, 0xAB, "<<"
    HCPS 0xAC, 0xAC, "-"
    HCPS 0xAD, 0xAD, ""                 ; soft hyphen
    HCPS 0xAE, 0xAE, "(R)"
    HCPS 0xAF, 0xAF, "-"
    HCPS 0xB0, 0xB0, "o"
    HCPS 0xB1, 0xB1, "+-"
    HCPS 0xB2, 0xB2, "2"
    HCPS 0xB3, 0xB3, "3"
    HCPS 0xB4, 0xB4, "'"
    HCPS 0xB5, 0xB5, "u"
    HCPS 0xB6, 0xB6, "P"
    HCPS 0xB7, 0xB7, "."
    HCPS 0xB8, 0xB8, ","
    HCPS 0xB9, 0xB9, "1"
    HCPS 0xBA, 0xBA, "o"
    HCPS 0xBB, 0xBB, ">>"
    HCPS 0xBC, 0xBC, "1/4"
    HCPS 0xBD, 0xBD, "1/2"
    HCPS 0xBE, 0xBE, "3/4"
    HCPS 0xBF, 0xBF, "?"
    HCPS 0x2000, 0x200A, " "            ; spaces
    HCPS 0x200B, 0x200F, ""             ; zero-width
    HCPS 0x2010, 0x2015, "-"            ; dashes
    HCPS 0x2018, 0x201B, "'"
    HCPS 0x201C, 0x201F, '"'
    HCPS 0x2020, 0x2021, "+"
    HCPS 0x2022, 0x2023, "*"
    HCPS 0x2026, 0x2026, "..."
    HCPS 0x2028, 0x202F, " "
    HCPS 0x2032, 0x2033, "'"
    HCPS 0x2039, 0x2039, "<"
    HCPS 0x203A, 0x203A, ">"
    HCPS 0x20AC, 0x20AC, "EUR"
    HCPS 0x2122, 0x2122, "TM"
    HCPS 0x2190, 0x2190, "<-"
    HCPS 0x2191, 0x2191, "^"
    HCPS 0x2192, 0x2192, "->"
    HCPS 0x2193, 0x2193, "v"
    HCPS 0x2194, 0x2194, "<->"
    HCPS 0x2212, 0x2212, "-"
    HCPS 0x2215, 0x2215, "/"
    HCPS 0x2260, 0x2260, "!="
    HCPS 0x2264, 0x2264, "<="
    HCPS 0x2265, 0x2265, ">="
    HCPS 0x25B2, 0x25B2, "^"
    HCPS 0x25BC, 0x25BC, "v"
    HCPS 0x25CF, 0x25CF, "*"
    HCPS 0x2713, 0x2714, "v"
    HCPS 0x2715, 0x2717, "x"
    HCPS 0xFE00, 0xFE0F, ""             ; variation selectors
    HCPS 0xFEFF, 0xFEFF, ""             ; byte order mark
    dd 0xFFFFFFFF
section .text
