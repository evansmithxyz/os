; ==============================================================================
; Antigravity OS - page layout and painting
; ------------------------------------------------------------------------------
; layout_page walks the styled DOM (css.asm) and produces a display list at
; LAYOUT_ADDR: text runs and rectangles in document coordinates (x from the
; content's left edge, y from the top of the page). It is done once per page
; and again when the window width changes; scrolling only repaints.
;
;   - block boxes stack vertically; adjacent vertical margins collapse
;   - inline content forms line boxes, wrapped at word boundaries and shifted
;     for text-align: center / right
;   - whitespace collapses unless white-space is pre; entities, UTF-8 and
;     Latin-1 become the nearest ASCII the 8x16 font has
;   - list items get a bullet or a number; table rows are one line with the
;     cells spaced apart (block boxes inside a cell flow inline)
;   - background colours of blocks become rectangles behind their content
;   - text inside <a href> becomes link runs; clicking uses layout_links
;   - <input>, <textarea>, <select> and <button> become boxes (lay_field,
;     lay_button) with the value forms.asm keeps; inline elements get their
;     left and right margin and padding as space
;
; browser_render_html_page paints the display list into the viewport.
; ==============================================================================

[bits 64]

LAY_LINE_H              equ 18
LAY_PAD_X               equ 20      ; page content inset from the viewport
LAY_PAD_Y               equ 14
LAY_WORD_MAX            equ 120
LAY_MAX_ITEMS           equ (LAYOUT_SIZE - LAY_TEXT_SIZE) / LAY_ITEM_SIZE
LAY_TEXT                equ LAYOUT_ADDR + LAYOUT_SIZE - LAY_TEXT_SIZE
LAY_TEXT_SIZE           equ 0x00100000
LAY_MAX_LINKS           equ 4096
LAY_LIST_DEPTH          equ 16

; display list item
I_KIND                  equ 0       ; db IK_*
I_FLAGS                 equ 1       ; db IF_*
I_LEN                   equ 2       ; dw characters
I_Y                     equ 4       ; dd document y
I_X                     equ 8       ; dd x from the content's left edge
I_COLOR                 equ 12      ; dd
I_TEXT                  equ 16      ; dd text offset (rectangle: width)
I_LINK                  equ 20      ; dd link + 1, 0 = none (rectangle: height)
I_NODE                  equ 24      ; dd DOM node
LAY_ITEM_SIZE           equ 32
IK_TEXT                 equ 1
IK_RECT                 equ 2
IF_BOLD                 equ 1
IF_UNDER                equ 2
IF_HIDDEN               equ 4

section .data
align 4
lay_count:              dd 0        ; display list items
lay_text_used:          dd 0
lay_height:             dd 0        ; page height after layout
lay_width:              dd -1       ; content width it was laid out for
lay_page_bg:            dd 0xFFFFFF
lay_link_count:         dd 0

section .bss
alignb 16
layout_links:           resb LAY_MAX_LINKS * 16     ; dq href, dd length, dd -
lay_word:               resb LAY_WORD_MAX
lay_list_counter:       resd LAY_LIST_DEPTH
alignb 4
lay_x:                  resd 1      ; pen, from the content's left edge
lay_y:                  resd 1      ; top of the current line
lay_left:               resd 1      ; the current block's content box
lay_right:              resd 1
lay_margin:             resd 1      ; collapsed margin waiting above the next line
lay_line_first:         resd 1      ; first item of the current line
lay_word_len:           resd 1
lay_link:               resd 1      ; link + 1 for text being laid out
lay_color:              resd 1      ; style of the text being laid out
lay_list_depth:         resd 1
lay_text_node:          resd 1      ; node of the text being laid out
lay_flags:              resb 1
lay_space:              resb 1
lay_ws:                 resb 1
lay_align:              resb 1
lay_transform:          resb 1
lay_cell:               resb 1      ; inside a table cell
alignb 4
lay_field_x:            resd 1      ; the form field being laid out: its box
lay_field_y:            resd 1
lay_field_w:            resd 1
lay_field_cols:         resd 1      ; characters per line
lay_field_color:        resd 1      ; of its text
lay_caret_y:            resd 1      ; top of its last line drawn
lay_latin1:             resb 1

section .text
; ------------------------------------------------------------------------------
; layout_page: EAX = content width in pixels -> the display list
; ------------------------------------------------------------------------------
layout_page:
    push rax
    push rbx
    push rcx
    mov [lay_width], eax
    xor ecx, ecx
    mov [lay_count], ecx
    mov [lay_text_used], ecx
    mov [lay_link_count], ecx
    mov [lay_x], ecx
    mov [lay_y], ecx
    mov [lay_left], ecx
    mov [lay_margin], ecx
    mov [lay_line_first], ecx
    mov [lay_word_len], ecx
    mov [lay_link], ecx
    mov [lay_list_depth], ecx
    mov [lay_space], cl
    mov [lay_cell], cl
    mov [lay_align], cl
    mov [lay_right], eax
    mov al, [browser_page_latin1]
    mov [lay_latin1], al
    call lay_page_background
    xor eax, eax                    ; the document
    call lay_node_children
    call lay_end_line
    mov eax, [lay_y]
    add eax, [lay_margin]
    mov [lay_height], eax
    pop rcx
    pop rbx
    pop rax
    ret

; lay_page_background: <body>'s background, else <html>'s, else white
lay_page_background:
    push rax
    push rbx
    push rcx
    mov dword [lay_page_bg], 0xFFFFFF
    mov ecx, 1
.find:
    cmp ecx, [dom_count]
    jae .done
    mov eax, ecx
    call dom_node
    cmp byte [rbx + N_TAG], TAGID_HTML
    je .candidate
    cmp byte [rbx + N_TAG], TAGID_BODY
    jne .next
.candidate:
    mov eax, [rbx + S_BG]
    cmp eax, CSS_TRANSPARENT
    je .next
    mov [lay_page_bg], eax          ; body comes after html, so it wins
.next:
    inc ecx
    cmp ecx, 64                     ; they are near the start
    jb .find
.done:
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; lay_node_children: EAX = node -> lay out each child
; ------------------------------------------------------------------------------
lay_node_children:
    push rax
    push rbx
    call dom_node
    mov eax, [rbx + N_FIRST]
.child:
    test eax, eax
    jz .done
    call lay_node
    call dom_node
    mov eax, [rbx + N_NEXT]
    jmp .child
.done:
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; lay_node: EAX = node -> laid out (with its subtree)
; ------------------------------------------------------------------------------
lay_node:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov r12d, eax                   ; R12 = node
    call dom_node
    mov r13, rbx                    ; R13 = its record
    cmp byte [r13 + N_TYPE], NODE_TEXT
    jne .not_text
    test byte [r13 + N_FLAGS], NF_COMMENT
    jnz .done                       ; (comments are not drawn)
    jmp .text
.not_text:
    movzx eax, byte [r13 + S_DISPLAY]
    cmp eax, DISP_NONE
    je .done

    ; save what this element may change
    push qword [lay_link]
    push qword [lay_left]           ; (lay_left and lay_right)
    movzx ecx, byte [lay_align]
    push rcx

    ; links
    cmp byte [r13 + N_TAG], TAGID_A
    jne .not_link
    call lay_new_link
.not_link:
    ; replaced / special inline elements
    movzx ecx, byte [r13 + N_TAG]
    cmp ecx, TAGID_BR
    je .br
    cmp ecx, TAGID_IMG
    je .img
    cmp ecx, TAGID_INPUT
    je .input
    cmp ecx, TAGID_TEXTAREA
    je .input
    cmp ecx, TAGID_SELECT
    je .input
    cmp ecx, TAGID_HR
    je .hr

    cmp eax, DISP_INLINE
    je .inline
    cmp eax, DISP_CELL
    je .cell
    cmp eax, DISP_TABLE
    je .table
    cmp eax, DISP_ROW
    je .row
    cmp byte [lay_cell], 0
    jne .inline_block               ; blocks inside a table cell flow inline

.block:
    call lay_block
    jmp .restore

    ; --- table: a block, and a fresh start for any cells around it ------------------
.table:
    movzx ecx, byte [lay_cell]
    push rcx
    mov byte [lay_cell], 0
    call lay_block
    pop rcx
    mov [lay_cell], cl
    jmp .restore

    ; --- table row: its own line, cells side by side ------------------------------
.row:
    call lay_end_line
    mov eax, [lay_left]
    mov ecx, [lay_right]
    sub ecx, eax
    call lay_bg_begin               ; R14 = its background, if any
    mov eax, r12d
    call lay_node_children
    call lay_end_line
    call lay_bg_end
    jmp .restore

    ; --- table cell -----------------------------------------------------------------
.cell:
    call lay_cell_gap
    mov eax, [lay_x]
    sub eax, 4
    xor ecx, ecx                    ; width: known at the end
    call lay_bg_begin
    inc byte [lay_cell]
    mov eax, r12d
    call lay_node_children
    dec byte [lay_cell]
    call lay_flush_word
    call lay_bg_end
    jmp .restore

    ; --- a block inside a cell: a word break, nothing more --------------------------
.inline_block:
    call lay_flush_word
    mov byte [lay_space], 1
    mov eax, r12d
    call lay_node_children
    call lay_flush_word
    mov byte [lay_space], 1
    jmp .restore

    ; --- inline ---------------------------------------------------------------------
.inline:
    cmp byte [r13 + N_TAG], TAGID_BUTTON
    je .button
    ; margin and padding at each end
    movsx eax, word [r13 + S_ML]
    movsx ecx, word [r13 + S_PL]
    call lay_inline_space
    mov eax, r12d
    call lay_node_children
    movsx eax, byte [r13 + S_MR]
    movsx ecx, byte [r13 + S_PR]
    call lay_inline_space
    jmp .restore
.button:
    call lay_button
    jmp .restore

.br:
    call lay_flush_word
    call lay_break
    jmp .restore
.hr:
    call lay_end_line
    mov eax, 4
    call lay_collapse_margin
    call lay_use_margin
    call lay_new_item
    jc .hr_done
    mov byte [rbx + I_KIND], IK_RECT
    mov eax, [lay_y]
    add eax, LAY_LINE_H / 2
    mov [rbx + I_Y], eax
    mov eax, [lay_left]
    mov [rbx + I_X], eax
    mov eax, [lay_right]
    sub eax, [lay_left]
    mov [rbx + I_TEXT], eax
    mov dword [rbx + I_LINK], 1
    mov eax, [r13 + S_COLOR]
    mov [rbx + I_COLOR], eax
.hr_done:
    add dword [lay_y], LAY_LINE_H
    mov eax, 4
    call lay_collapse_margin
    jmp .restore
.img:
    ; [alt]
    mov eax, r12d
    lea rdi, [lay_attr_alt]
    call dom_attr
    jc .restore
    test ecx, ecx
    jz .restore
    call lay_style_from
    mov al, '['
    call lay_add_char
    call lay_add_attr_text
    mov al, ']'
    call lay_add_char
    call lay_flush_word
    mov byte [lay_space], 1
    jmp .restore
.input:
    call lay_field
    jmp .restore

.restore:
    call lay_flush_word             ; the last word still has this element's style
    pop rcx
    mov [lay_align], cl
    pop qword [lay_left]
    pop qword [lay_link]
    ; an empty line starts at the (restored) left edge
    mov eax, [lay_line_first]
    cmp eax, [lay_count]
    jne .done
    mov eax, [lay_left]
    mov [lay_x], eax
    jmp .done

    ; --- text ---------------------------------------------------------------------
.text:
    ; hidden itself (closed <details>) or by an ancestor?
    cmp byte [r13 + S_DISPLAY], DISP_NONE
    je .done
    mov eax, [r13 + N_PARENT]
    call dom_node
    cmp byte [rbx + S_DISPLAY], DISP_NONE
    je .done
    mov rbx, r13
    call lay_style_from
    call lay_text                   ; RBX = text node
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; lay_block: R12 = node, R13 = its record (display block, list-item or table)
; -> laid out as a block box: margins, indent, background, list marker
; ------------------------------------------------------------------------------
lay_block:
    push rax
    push rbx
    push rcx
    push rdx
    push r14
    call lay_end_line
    movsx eax, word [r13 + S_MT]
    call lay_collapse_margin
    mov al, [r13 + S_ALIGN]
    mov [lay_align], al
    ; background: reserve its rectangle now so it is painted under the content
    mov r14d, -1                    ; R14 = background item
    cmp dword [r13 + S_BG], CSS_TRANSPARENT
    je .no_bg
    call lay_use_margin
    call lay_new_item
    jc .no_bg
    mov r14d, eax
    mov byte [rbx + I_KIND], IK_RECT
    mov eax, [lay_y]
    mov [rbx + I_Y], eax
    mov eax, [lay_left]
    mov [rbx + I_X], eax
    mov eax, [lay_right]
    sub eax, [lay_left]
    mov [rbx + I_TEXT], eax
    mov eax, [r13 + S_BG]
    mov [rbx + I_COLOR], eax
    mov [rbx + I_NODE], r12d
    mov eax, [lay_count]            ; the rectangle is not content of a line
    mov [lay_line_first], eax
.no_bg:
    ; indent: margin-left + padding-left
    movsx eax, word [r13 + S_ML]
    movsx ecx, word [r13 + S_PL]
    add eax, ecx
    add eax, [lay_left]
    mov ecx, [lay_right]
    sub ecx, 64                     ; always keep some room for text
    cmp eax, ecx
    jle .indent_ok
    mov eax, ecx
.indent_ok:
    test eax, eax
    jns .indent_set
    xor eax, eax
.indent_set:
    mov [lay_left], eax
    mov [lay_x], eax
    ; lists count their items; items get a marker
    movzx ecx, byte [r13 + N_TAG]
    cmp ecx, TAGID_UL
    je .list
    cmp ecx, TAGID_OL
    jne .not_list
.list:
    mov ecx, [lay_list_depth]
    cmp ecx, LAY_LIST_DEPTH
    jae .not_list
    lea rdx, [lay_list_counter]
    mov dword [rdx + rcx * 4], 0
    inc dword [lay_list_depth]
.not_list:
    cmp byte [r13 + S_DISPLAY], DISP_LIST_ITEM
    jne .children
    call lay_marker
.children:
    mov eax, r12d
    call lay_node_children
    call lay_end_line
    movzx ecx, byte [r13 + N_TAG]
    cmp ecx, TAGID_UL
    je .unlist
    cmp ecx, TAGID_OL
    jne .no_unlist
.unlist:
    cmp dword [lay_list_depth], 0
    je .no_unlist
    dec dword [lay_list_depth]
.no_unlist:
    ; the background's height
    cmp r14d, -1
    je .bg_done
    mov eax, r14d
    call lay_item
    mov eax, [lay_y]
    sub eax, [rbx + I_Y]
    mov [rbx + I_LINK], eax
.bg_done:
    movsx eax, word [r13 + S_MB]
    call lay_collapse_margin
    pop r14
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; lay_style_from: R13 = node -> the style used for text laid out now
; ------------------------------------------------------------------------------
lay_style_from:
    push rax
    call lay_flush_word             ; the word so far keeps its own style
    mov eax, [r13 + S_COLOR]
    mov [lay_color], eax
    xor eax, eax
    cmp byte [r13 + S_BOLD], 0
    je .under
    or al, IF_BOLD
.under:
    cmp byte [r13 + S_UNDER], 0
    je .hidden
    or al, IF_UNDER
.hidden:
    cmp byte [r13 + S_VIS], 0
    je .set
    or al, IF_HIDDEN
.set:
    mov [lay_flags], al
    mov al, [r13 + S_WS]
    mov [lay_ws], al
    mov al, [r13 + S_TRANSFORM]
    mov [lay_transform], al
    mov [lay_text_node], r12d
    pop rax
    ret

; lay_new_link: R12/R13 = <a> -> lay_link = a new link for its href (if any)
lay_new_link:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    mov eax, r12d
    lea rdi, [lay_attr_href]
    call dom_attr
    jc .done
    mov eax, [lay_link_count]
    cmp eax, LAY_MAX_LINKS
    jae .done
    inc dword [lay_link_count]
    mov rbx, rax
    shl rbx, 4
    lea rdi, [layout_links]
    mov [rdi + rbx], rsi
    mov [rdi + rbx + 8], ecx
    inc eax
    mov [lay_link], eax
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; lay_field: R12/R13 = <input>, <textarea> or <select> -> a box on the line
; with its value (forms.asm keeps what the user typed), a check box, or a
; button
; ------------------------------------------------------------------------------
LAY_FIELD_BORDER        equ 0x767676
LAY_FIELD_FOCUS         equ 0x1A73E8
LAY_FIELD_HINT          equ 0x757575    ; placeholder text
LAY_BUTTON_FACE         equ 0xEFEFEF

lay_field:
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
    call lay_style_from
    mov eax, r12d
    call form_kind
    cmp ecx, FK_HIDDEN
    je .done
    cmp ecx, FK_CHECKBOX
    je .check
    cmp ecx, FK_RADIO
    je .check
    cmp ecx, FK_SELECT
    je .select
    cmp ecx, FK_TEXTAREA
    je .textarea
    cmp ecx, FK_TEXT
    je .text_field
    cmp ecx, FK_PASSWORD
    je .text_field
    ; --- a button: its label in a grey box ---------------------------------------
    mov r10d, ecx                   ; R10 = kind
    lea rdi, [lay_attr_value]
    call form_attr_decoded
    test ecx, ecx
    jnz .label
    lea rsi, [lay_str_submit]
    cmp r10d, FK_SUBMIT
    je .default_label
    lea rsi, [lay_str_reset]
    push rsi
    push rcx
    lea rdi, [lay_attr_type]
    call dom_attr
    mov ebx, ecx
    pop rcx
    lea rdi, [form_str_reset]
    call form_attr_is
    pop rsi
    je .default_label
    lea rsi, [lay_str_file]
    cmp r10d, FK_FILE
    je .default_label
    xor ecx, ecx
    jmp .label
.default_label:
    call strlen
    mov ecx, eax
.label:
    cmp ecx, 40
    jbe .label_len
    mov ecx, 40
.label_len:
    mov r11d, ecx                   ; R11 = label length
    push rsi
    lea ecx, [r11d * 8 + 16]
    call lay_place                  ; EAX = x
    pop rsi
    mov edx, [lay_y]
    test byte [lay_flags], IF_HIDDEN
    jnz .done
    mov r8d, [r13 + S_BG]
    cmp r8d, CSS_TRANSPARENT
    jne .face
    mov r8d, LAY_BUTTON_FACE
.face:
    push rsi
    mov esi, LAY_LINE_H
    mov edi, LAY_FIELD_BORDER
    mov r9d, 1
    call lay_box
    pop rsi
    add eax, 8
    inc edx
    mov ecx, r11d
    mov edi, [r13 + S_COLOR]
    xor r8d, r8d
    call lay_put_text
    jmp .spaced

    ; --- check box / radio button ------------------------------------------------
.check:
    mov ecx, 14
    call lay_place
    mov edx, [lay_y]
    test byte [lay_flags], IF_HIDDEN
    jnz .done
    inc eax
    add edx, 3
    mov ecx, 12
    mov esi, 12
    mov edi, LAY_FIELD_BORDER
    mov r8d, 0xFFFFFF
    mov r9d, 1
    call lay_box
    push rax
    mov eax, r12d
    call form_checked
    pop rax
    jnc .spaced
    add eax, 3
    add edx, 3
    mov ecx, 6
    mov esi, 6
    mov edi, LAY_FIELD_FOCUS
    call lay_rect
    jmp .spaced

    ; --- <select>: the chosen option, as wide as the widest -----------------------
.select:
    xor r11d, r11d                  ; R11 = widest label
    mov eax, r12d
.option:
    mov edx, r12d
    call jsd_next
    test eax, eax
    jz .widest
    call dom_node
    cmp byte [rbx + N_TAG], TAGID_OPTION
    jne .option
    call form_option_text
    cmp ecx, r11d
    jbe .option
    mov r11d, ecx
    jmp .option
.widest:
    cmp r11d, 40
    jbe .select_width
    mov r11d, 40
.select_width:
    lea ecx, [r11d * 8 + 24]
    mov r10d, ecx                   ; R10 = width
    call lay_place
    mov r9d, eax                    ; R9 = x
    test byte [lay_flags], IF_HIDDEN
    jnz .done
    mov eax, r12d
    call form_option
    xor ecx, ecx
    test edx, edx
    jz .select_box
    mov eax, edx
    call form_option_text
.select_box:
    cmp ecx, r11d
    jbe .select_text
    mov ecx, r11d
.select_text:
    push rcx
    push rsi
    mov eax, r9d
    mov edx, [lay_y]
    mov ecx, r10d
    mov esi, LAY_LINE_H
    mov edi, LAY_FIELD_BORDER
    mov r8d, [r13 + S_BG]
    cmp r8d, CSS_TRANSPARENT
    jne .select_fill
    mov r8d, 0xFFFFFF
.select_fill:
    push r9
    mov r9d, 1
    call lay_box
    pop r9
    pop rsi
    pop rcx
    lea eax, [r9d + 4]
    inc edx
    mov edi, [r13 + S_COLOR]
    xor r8d, r8d
    call lay_put_text
    ; the arrow
    lea eax, [r9d + r10d - 12]
    lea rsi, [lay_str_arrow]
    mov ecx, 1
    mov edi, LAY_FIELD_BORDER
    call lay_put_text
    jmp .spaced

    ; --- a text field: size="" characters wide ----------------------------------
.text_field:
    mov r10d, ecx                   ; R10 = kind
    lea rdi, [lay_attr_size]
    mov ebx, 20
    call lay_attr_number
    mov ecx, ebx
    mov r11d, 1                     ; R11 = rows
    jmp .field_box
.textarea:
    mov r10d, ecx
    lea rdi, [lay_attr_rows]
    mov ebx, 2
    call lay_attr_number
    cmp ebx, 20
    jbe .rows
    mov ebx, 20
.rows:
    mov r11d, ebx
    lea rdi, [lay_attr_cols]
    mov ebx, 20
    call lay_attr_number
    mov ecx, ebx
.field_box:
    ; ECX = columns: at least 2, and the box must fit on a line
    mov eax, [lay_right]
    sub eax, [lay_left]
    sub eax, 8
    sar eax, 3
    cmp ecx, eax
    jle .cols_fit
    mov ecx, eax
.cols_fit:
    cmp ecx, 2
    jge .cols_ok
    mov ecx, 2
.cols_ok:
    mov [lay_field_cols], ecx
    lea ecx, [ecx * 8 + 8]
    mov [lay_field_w], ecx
    call lay_place
    mov [lay_field_x], eax
    mov edx, [lay_y]
    mov [lay_field_y], edx
    ; taller than a line: the rest of the line goes along its bottom
    lea eax, [r11d - 1]
    imul eax, eax, LAY_LINE_H
    add [lay_y], eax
    test byte [lay_flags], IF_HIDDEN
    jnz .done
    ; the box: blue and thicker while it has the keyboard
    mov eax, [lay_field_x]
    mov ecx, [lay_field_w]
    imul esi, r11d, LAY_LINE_H
    mov edi, LAY_FIELD_BORDER
    mov r9d, 1
    cmp r12d, [form_focus]
    jne .unfocused
    mov edi, LAY_FIELD_FOCUS
    mov r9d, 2
.unfocused:
    mov r8d, [r13 + S_BG]
    cmp r8d, CSS_TRANSPARENT
    jne .fill
    mov r8d, 0xFFFFFF
.fill:
    call lay_box
    ; its value, else the placeholder (in grey, when it is not focused)
    mov eax, r12d
    call form_value
    mov edi, [r13 + S_COLOR]
    test ecx, ecx
    jnz .have_text
    cmp r12d, [form_focus]
    je .have_text
    lea rdi, [lay_attr_placeholder]
    call form_attr_decoded
    mov edi, LAY_FIELD_HINT
.have_text:
    mov [lay_field_color], edi
    xor r8d, r8d
    cmp r10d, FK_PASSWORD
    jne .lines
    mov r8d, 1
.lines:
    call lay_field_lines
.spaced:
    mov byte [lay_space], 1
.done:
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
; lay_field_lines: RSI/ECX = a field's text, R11D = its rows, R8D = 1 for
; '*'s, lay_field_* = its box -> the text in lines of lay_field_cols (at a
; newline or when full): the first rows, or while it has the keyboard the
; last ones and the caret after the text
; ------------------------------------------------------------------------------
lay_field_lines:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r10
    ; one row: the start, or the end while typing (with room for the caret)
    cmp r11d, 1
    jne .count
    mov eax, [lay_field_cols]
    cmp r12d, [form_focus]
    jne .one_row
    dec eax
    cmp ecx, eax
    jbe .one_row
    sub ecx, eax
    add rsi, rcx
    mov ecx, eax
.one_row:
    cmp ecx, eax
    jbe .one_row_len
    mov ecx, eax
.one_row_len:
    mov eax, [lay_field_x]
    add eax, 4
    mov edx, [lay_field_y]
    inc edx
    mov edi, [lay_field_color]
    call lay_put_text
    shl ecx, 3
    add eax, ecx
    jmp .caret
.count:
    ; pass 1: how many lines; pass 2: draw the ones that show
    mov r9d, -1                     ; R9 = first line drawn (-1: none, counting)
    call .split
    xor r9d, r9d
    cmp r12d, [form_focus]
    jne .draw
    mov r9d, r10d
    sub r9d, r11d
    jge .draw
    xor r9d, r9d
.draw:
    call .split
    ; EAX = x after the last line drawn, EDX = its y
.caret:
    cmp r12d, [form_focus]
    jne .ret
    mov edx, [lay_field_y]
    cmp r11d, 1
    je .caret_y
    mov edx, [lay_caret_y]
.caret_y:
    add edx, 2
    mov ecx, [lay_field_x]
    add ecx, [lay_field_w]
    sub ecx, 4
    cmp eax, ecx
    jle .caret_x
    mov eax, ecx
.caret_x:
    mov ecx, 1
    push rsi
    mov esi, FONT_H - 2
    mov edi, [r13 + S_COLOR]
    call lay_rect
    pop rsi
.ret:
    pop r10
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; .split: RSI/ECX = text -> R10D = its lines; lines R9 .. R9 + R11 - 1 drawn
; (R9 = -1: none), EAX = x after the last one drawn
.split:
    push rcx
    push rsi
    xor r10d, r10d                  ; R10 = line number
    mov rbx, rsi                    ; RBX = start of the line
    xor edx, edx                    ; EDX = its length so far
    mov eax, [lay_field_x]
    add eax, 4
.byte:
    test ecx, ecx
    jz .last
    cmp byte [rsi], 10
    je .newline
    cmp edx, [lay_field_cols]
    jb .take
    call .line                      ; full: wrap
    mov rbx, rsi
    xor edx, edx
.take:
    inc rsi
    dec ecx
    inc edx
    jmp .byte
.newline:
    call .line
    inc rsi
    dec ecx
    mov rbx, rsi
    xor edx, edx
    jmp .byte
.last:
    call .line
    pop rsi
    pop rcx
    ret
; .line: RBX/EDX = a line, R10 = its number -> drawn if it shows; next number
.line:
    cmp r9d, -1
    je .line_done
    cmp r10d, r9d
    jl .line_done
    push rcx
    mov ecx, r10d
    sub ecx, r9d
    cmp ecx, r11d
    pop rcx
    jge .line_done
    push rcx
    push rdx
    push rsi
    push rdi
    mov ecx, edx
    mov rsi, rbx
    mov edx, r10d
    sub edx, r9d
    imul edx, edx, LAY_LINE_H
    add edx, [lay_field_y]
    mov [lay_caret_y], edx
    inc edx
    mov eax, [lay_field_x]
    add eax, 4
    mov edi, [lay_field_color]
    call lay_put_text
    shl ecx, 3
    add eax, ecx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
.line_done:
    inc r10d
    ret

; ------------------------------------------------------------------------------
; lay_place: ECX = width -> EAX = x of a box that wide on the current line
; (after a pending space; on a new line if it does not fit and may wrap);
; the pen moves past it
; ------------------------------------------------------------------------------
lay_place:
    push rdx
    call lay_flush_word
    mov eax, [lay_x]
    cmp byte [lay_space], 0
    je .no_space
    cmp eax, [lay_left]
    jle .no_space
    add eax, 8
.no_space:
    lea edx, [eax + ecx]
    cmp edx, [lay_right]
    jle .fits
    cmp byte [lay_ws], WS_NORMAL
    jne .fits
    mov edx, [lay_x]
    cmp edx, [lay_left]
    jle .fits                       ; nothing on the line: it overflows
    call lay_end_line
    mov eax, [lay_x]
.fits:
    mov byte [lay_space], 0
    call lay_use_margin
    lea edx, [eax + ecx]
    mov [lay_x], edx
    pop rdx
    ret

; lay_attr_number: EAX = element, RDI = attribute name, EBX = default ->
; EBX = its value if it is a number from 1 to 200
lay_attr_number:
    push rax
    push rcx
    push rdx
    push rsi
    call dom_attr
    jc .ret
    xor eax, eax
.digit:
    test ecx, ecx
    jz .end
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .end
    imul eax, eax, 10
    add eax, edx
    cmp eax, 1000
    ja .ret
    inc rsi
    dec ecx
    jmp .digit
.end:
    test eax, eax
    jz .ret
    cmp eax, 200
    ja .ret
    mov ebx, eax
.ret:
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; lay_rect: EAX, EDX = x, y  ECX, ESI = width, height  EDI = colour -> a
; rectangle item (of node R12, so pressing it finds the control)
lay_rect:
    push rbx
    push rax
    call lay_new_item
    pop rax
    jc .ret
    mov byte [rbx + I_KIND], IK_RECT
    mov [rbx + I_X], eax
    mov [rbx + I_Y], edx
    mov [rbx + I_TEXT], ecx
    mov [rbx + I_LINK], esi
    mov [rbx + I_COLOR], edi
    mov [rbx + I_NODE], r12d
.ret:
    pop rbx
    ret

; lay_box: EAX, EDX, ECX, ESI = x, y, width, height  EDI = border colour,
; R8D = fill colour, R9D = border width -> two rectangles
lay_box:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    call lay_rect
    add eax, r9d
    add edx, r9d
    sub ecx, r9d
    sub ecx, r9d
    sub esi, r9d
    sub esi, r9d
    mov edi, r8d
    call lay_rect
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; lay_put_text: EAX, EDX = x, y  RSI/ECX = text  EDI = colour  R8D = 1 to
; show '*'s -> a text item of node R12 (a UTF-8 character is one '?')
; ------------------------------------------------------------------------------
lay_put_text:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r10
    test ecx, ecx
    jz .ret
    push rax
    call lay_new_item
    pop rax
    jc .ret
    mov byte [rbx + I_KIND], IK_TEXT
    mov [rbx + I_X], eax
    mov [rbx + I_Y], edx
    mov [rbx + I_COLOR], edi
    mov r9d, [lay_text_used]
    mov [rbx + I_TEXT], r9d
    mov [rbx + I_NODE], r12d
    lea rdi, [abs LAY_TEXT]
    add rdi, r9
    xor edx, edx                    ; EDX = characters
.char:
    test ecx, ecx
    jz .end
    lodsb
    dec ecx
    cmp al, 0x80
    jb .ascii
    cmp al, 0xC0
    jb .char                        ; the rest of a UTF-8 character
    mov al, '?'
.ascii:
    cmp al, ' '
    jae .shown
    mov al, ' '
.shown:
    cmp al, 0x7E
    jbe .star
    mov al, '?'
.star:
    test r8d, r8d
    jz .put
    mov al, '*'
.put:
    lea r10d, [r9d + edx]
    cmp r10d, LAY_TEXT_SIZE
    jae .end
    mov [rdi + rdx], al
    inc edx
    jmp .char
.end:
    mov [rbx + I_LEN], dx
    add [lay_text_used], edx
.ret:
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
; lay_button: R12/R13 = <button> -> its content in a box of its background
; (the browser's style sheet makes it grey); no box if nothing in it shows
; or it runs over a line
; ------------------------------------------------------------------------------
lay_button:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    call lay_style_from
    mov r9d, CSS_TRANSPARENT
    test byte [lay_flags], IF_HIDDEN
    jnz .no_face
    mov r9d, [r13 + S_BG]           ; R9 = its face
.no_face:
    xor ecx, ecx
    call lay_place                  ; EAX = its left
    mov r8d, eax                    ; R8 = x
    mov edx, [lay_y]
    mov r10d, [lay_count]           ; R10 = its first item
    cmp r9d, CSS_TRANSPARENT
    je .content
    xor ecx, ecx                    ; (sizes come at the end)
    xor esi, esi
    mov edi, LAY_FIELD_BORDER
    push r9
    mov r9d, 1
    push r8
    mov r8d, [rsp + 8]
    call lay_box
    pop r8
    pop r9
    add dword [lay_x], 6
.content:
    mov eax, r12d
    call lay_node_children
    call lay_flush_word
    cmp r9d, CSS_TRANSPARENT
    je .done
    add dword [lay_x], 6
    ; the box, if its content is on this line and something showed
    mov eax, r10d
    call lay_item
    mov eax, [lay_count]
    sub eax, r10d
    cmp eax, 2
    jbe .empty
    cmp edx, [lay_y]
    jne .done                       ; it wrapped: no box
    mov ecx, [lay_x]
    sub ecx, r8d
    mov [rbx + I_TEXT], ecx
    mov dword [rbx + I_LINK], LAY_LINE_H
    sub ecx, 2
    mov [rbx + LAY_ITEM_SIZE + I_TEXT], ecx
    mov dword [rbx + LAY_ITEM_SIZE + I_LINK], LAY_LINE_H - 2
    jmp .done
.empty:
    mov [lay_x], r8d                ; an icon we cannot draw: no room either
.done:
    mov byte [lay_space], 1
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

; lay_inline_space: EAX + ECX = margin and padding at one end of an inline
; element -> the pen moves on (0 .. 64 pixels, within the line)
lay_inline_space:
    push rax
    call lay_flush_word
    add eax, ecx
    jle .ret
    cmp eax, 64
    jbe .add
    mov eax, 64
.add:
    add eax, [lay_x]
    cmp eax, [lay_right]
    jle .set
    mov eax, [lay_right]
.set:
    cmp eax, [lay_x]
    jle .ret
    mov [lay_x], eax
.ret:
    pop rax
    ret

; lay_add_attr_text: RSI/ECX = attribute text -> characters (entities kept raw)
lay_add_attr_text:
    push rax
    push rcx
    push rsi
.char:
    test ecx, ecx
    jz .done
    mov al, [rsi]
    cmp al, ' '
    jae .put
    mov al, ' '
.put:
    cmp al, 0x7E
    ja .next
    call lay_add_char
.next:
    inc rsi
    dec ecx
    jmp .char
.done:
    pop rsi
    pop rcx
    pop rax
    ret

; lay_marker: a list item's bullet or number at the start of its first line
lay_marker:
    push rax
    push rbx
    push rcx
    push rdx
    call lay_use_margin
    ; count it
    mov ecx, [lay_list_depth]
    xor edx, edx
    test ecx, ecx
    jz .counted
    lea rbx, [lay_list_counter]
    inc dword [rbx + rcx * 4 - 4]
    mov edx, [rbx + rcx * 4 - 4]    ; EDX = its number
.counted:
    cmp byte [r13 + S_LIST], LIST_NONE
    je .done
    cmp byte [r13 + S_LIST], LIST_DECIMAL
    je .number
    call lay_new_item
    jc .done
    mov byte [rbx + I_KIND], IK_RECT
    mov eax, [lay_y]
    add eax, 7
    mov [rbx + I_Y], eax
    mov eax, [lay_left]
    sub eax, 10
    mov [rbx + I_X], eax
    mov dword [rbx + I_TEXT], 4
    mov dword [rbx + I_LINK], 4
    mov eax, [r13 + S_COLOR]
    mov [rbx + I_COLOR], eax
    jmp .done
.number:
    ; "N." right-aligned before the text
    call lay_new_item
    jc .done
    mov byte [rbx + I_KIND], IK_TEXT
    mov eax, [lay_y]
    mov [rbx + I_Y], eax
    mov eax, [r13 + S_COLOR]
    mov [rbx + I_COLOR], eax
    mov eax, [lay_text_used]
    mov [rbx + I_TEXT], eax
    push rdi
    lea rdi, [abs LAY_TEXT]
    add rdi, rax
    mov eax, edx
    call fmt_dec
    mov al, '.'
    call fmt_char
    mov rax, rdi
    lea rdi, [abs LAY_TEXT]
    sub rax, rdi
    pop rdi
    mov ecx, eax
    sub ecx, [lay_text_used]
    mov [lay_text_used], eax
    mov [rbx + I_LEN], cx
    shl ecx, 3
    mov eax, [lay_left]
    sub eax, ecx
    sub eax, 4
    mov [rbx + I_X], eax
.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; lay_bg_begin: R13 = row or cell, EAX = its left x, ECX = its width (0 = up to
; the pen at lay_bg_end) -> R14 = its background rectangle (-1 = none). The
; rectangle comes before the content in the display list, so it is behind it.
; ------------------------------------------------------------------------------
lay_bg_begin:
    push rax
    push rbx
    mov r14d, -1
    cmp dword [r13 + S_BG], CSS_TRANSPARENT
    je .ret
    call lay_use_margin
    push rax
    call lay_new_item
    mov r14d, eax
    pop rax
    jc .none
    mov byte [rbx + I_KIND], IK_RECT
    mov [rbx + I_X], eax
    mov [rbx + I_TEXT], ecx
    mov eax, [lay_y]
    mov [rbx + I_Y], eax
    mov eax, [r13 + S_BG]
    mov [rbx + I_COLOR], eax
    mov [rbx + I_NODE], r12d
    jmp .ret
.none:
    mov r14d, -1
.ret:
    pop rbx
    pop rax
    ret

; lay_bg_end: R14 = background from lay_bg_begin -> its width and height
lay_bg_end:
    push rax
    push rbx
    cmp r14d, -1
    je .ret
    mov eax, r14d
    call lay_item
    ; height: down to the current line (at least one line)
    mov eax, [lay_y]
    sub eax, [rbx + I_Y]
    mov ecx, [lay_line_first]
    cmp ecx, [lay_count]
    je .height
    add eax, LAY_LINE_H             ; the line in progress counts too
.height:
    cmp eax, LAY_LINE_H
    jge .set_height
    mov eax, LAY_LINE_H
.set_height:
    mov [rbx + I_LINK], eax
    cmp dword [rbx + I_TEXT], 0
    jne .ret
    ; a cell: up to the pen, or the whole line if it wrapped
    mov eax, [lay_x]
    add eax, 4
    mov ecx, [lay_y]
    cmp ecx, [rbx + I_Y]
    je .width
    mov eax, [lay_right]
.width:
    sub eax, [rbx + I_X]
    mov [rbx + I_TEXT], eax
.ret:
    pop rbx
    pop rax
    ret

; lay_cell_gap: space between table cells on a row
lay_cell_gap:
    push rax
    call lay_flush_word
    mov eax, [lay_x]
    cmp eax, [lay_left]
    jle .ret
    add dword [lay_x], 8
    mov byte [lay_space], 1
.ret:
    pop rax
    ret

; ==============================================================================
; Lines and words
; ==============================================================================

; lay_collapse_margin: EAX = a margin -> the pending margin is the larger one
lay_collapse_margin:
    cmp byte [lay_cell], 0
    jne .ret
    cmp eax, [lay_margin]
    jle .ret
    mov [lay_margin], eax
.ret:
    ret

; lay_use_margin: before the first thing on a line, move down by the margin
lay_use_margin:
    push rax
    mov eax, [lay_line_first]
    cmp eax, [lay_count]
    jne .ret                        ; the line already has something
    mov eax, [lay_margin]
    test eax, eax
    jz .ret
    cmp dword [lay_y], 0
    je .top                         ; no margin above the very first line
    add [lay_y], eax
.top:
    mov dword [lay_margin], 0
.ret:
    pop rax
    ret

; lay_end_line: finish the current line (text-align), start the next one
lay_end_line:
    push rax
    push rbx
    push rcx
    push rdx
    call lay_flush_word
    mov ecx, [lay_line_first]
    cmp ecx, [lay_count]
    je .empty
    ; shift the line for center / right alignment
    movzx eax, byte [lay_align]
    test eax, eax
    jz .aligned
    mov edx, [lay_right]
    sub edx, [lay_x]                ; free space
    jle .aligned
    cmp eax, ALIGN_CENTER
    jne .shift
    shr edx, 1
.shift:
    mov eax, ecx
    call lay_item
    add [rbx + I_X], edx
    inc ecx
    cmp ecx, [lay_count]
    jb .shift
.aligned:
    add dword [lay_y], LAY_LINE_H
.empty:
    mov eax, [lay_left]
    mov [lay_x], eax
    mov eax, [lay_count]
    mov [lay_line_first], eax
    mov byte [lay_space], 0
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; lay_break: <br>: end the line, or leave an empty one
lay_break:
    push rax
    mov eax, [lay_line_first]
    cmp eax, [lay_count]
    jne .end
    call lay_use_margin
    add dword [lay_y], LAY_LINE_H
    pop rax
    ret
.end:
    call lay_end_line
    pop rax
    ret

; lay_add_char: AL = character for the current word (text-transform applied)
lay_add_char:
    push rax
    push rcx
    push rdi
    cmp byte [lay_transform], 1
    jne .lower
    cmp al, 'a'
    jb .add
    cmp al, 'z'
    ja .add
    sub al, 32
    jmp .add
.lower:
    cmp byte [lay_transform], 2
    jne .add
    cmp al, 'A'
    jb .add
    cmp al, 'Z'
    ja .add
    add al, 32
.add:
    mov ecx, [lay_word_len]
    cmp ecx, LAY_WORD_MAX
    jb .store
    call lay_flush_word
    xor ecx, ecx
.store:
    lea rdi, [lay_word]
    mov [rdi + rcx], al
    inc ecx
    mov [lay_word_len], ecx
    pop rdi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; lay_flush_word: place the collected word on the line: after the pending
; space if it fits, else on a new line (unless white-space is nowrap / pre)
; ------------------------------------------------------------------------------
lay_flush_word:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov ecx, [lay_word_len]
    test ecx, ecx
    jz .ret
    mov dword [lay_word_len], 0
    mov edx, ecx
    shl edx, 3                      ; EDX = width
    cmp byte [lay_ws], WS_NORMAL
    jne .no_wrap
    mov eax, [lay_x]
    cmp byte [lay_space], 0
    je .no_space
    cmp eax, [lay_left]
    jle .no_space
    lea eax, [eax + edx + 8]
    cmp eax, [lay_right]
    jle .space
    call lay_end_line
    jmp .place
.no_space:
    mov eax, [lay_x]
    add eax, edx
    cmp eax, [lay_right]
    jle .place
    mov eax, [lay_x]
    cmp eax, [lay_left]
    jle .place                      ; too wide for any line: it overflows
    call lay_end_line
    jmp .place
.no_wrap:
    cmp byte [lay_space], 0
    je .place
    mov eax, [lay_x]
    cmp eax, [lay_left]
    jle .place
.space:
    ; the space joins the previous run if it has the same style
    mov byte [lay_space], 0
    call lay_use_margin
    mov al, ' '
    call lay_append_run
.place:
    mov byte [lay_space], 0
    call lay_use_margin
    lea rsi, [lay_word]
.char:
    mov al, [rsi]
    call lay_append_run
    inc rsi
    dec ecx
    jnz .char
.ret:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; lay_append_run: AL = character at the pen -> the last run (if it continues
; there with the same style) or a new run; pen moves on
lay_append_run:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    mov ecx, [lay_text_used]
    cmp ecx, LAY_TEXT_SIZE
    jae .advance
    ; can the last item take it?
    mov edi, [lay_count]
    cmp edi, [lay_line_first]
    je .new
    push rax
    lea eax, [edi - 1]
    call lay_item
    pop rax
    cmp byte [rbx + I_KIND], IK_TEXT
    jne .new
    push rax
    movzx eax, word [rbx + I_LEN]
    add eax, [rbx + I_TEXT]
    cmp eax, ecx                    ; its text ends where ours starts
    pop rax
    jne .new
    push rax
    movzx eax, word [rbx + I_LEN]
    shl eax, 3
    add eax, [rbx + I_X]
    cmp eax, [lay_x]                ; and it ends at the pen
    pop rax
    jne .new
    mov dl, [lay_flags]
    cmp dl, [rbx + I_FLAGS]
    jne .new
    mov edx, [lay_color]
    cmp edx, [rbx + I_COLOR]
    jne .new
    mov edx, [lay_link]
    cmp edx, [rbx + I_LINK]
    jne .new
    inc word [rbx + I_LEN]
    jmp .store
.new:
    push rax
    call lay_new_item
    pop rax
    jc .advance
    mov byte [rbx + I_KIND], IK_TEXT
    mov dl, [lay_flags]
    mov [rbx + I_FLAGS], dl
    mov word [rbx + I_LEN], 1
    mov edx, [lay_y]
    mov [rbx + I_Y], edx
    mov edx, [lay_x]
    mov [rbx + I_X], edx
    mov edx, [lay_color]
    mov [rbx + I_COLOR], edx
    mov [rbx + I_TEXT], ecx
    mov edx, [lay_link]
    mov [rbx + I_LINK], edx
    mov edx, [lay_text_node]
    mov [rbx + I_NODE], edx
.store:
    lea rdi, [abs LAY_TEXT]
    mov [rdi + rcx], al
    inc dword [lay_text_used]
.advance:
    add dword [lay_x], 8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; lay_new_item: -> EAX = a new display list item, RBX = it (zeroed); CF=1 full
lay_new_item:
    push rcx
    push rdi
    mov eax, [lay_count]
    cmp eax, LAY_MAX_ITEMS
    jae .full
    inc dword [lay_count]
    call lay_item
    push rax
    mov rdi, rbx
    xor eax, eax
    mov ecx, LAY_ITEM_SIZE / 8
    rep stosq
    pop rax
    pop rdi
    pop rcx
    clc
    ret
.full:
    pop rdi
    pop rcx
    stc
    ret

; lay_item: EAX = item -> RBX = its record
lay_item:
    push rax
    shl rax, 5                      ; * LAY_ITEM_SIZE
    lea rbx, [abs LAYOUT_ADDR]
    add rbx, rax
    pop rax
    ret

; ==============================================================================
; Text
; ==============================================================================

; ------------------------------------------------------------------------------
; lay_text: RBX = text node -> words (whitespace collapsed unless pre)
; ------------------------------------------------------------------------------
lay_text:
    push rax
    push rcx
    push r12
    push r14
    mov r12, [rbx + N_NAME]         ; R12 = position
    mov ecx, [rbx + N_NAME_LEN]
    lea r14, [r12 + rcx]            ; R14 = end
.loop:
    cmp r12, r14
    jae .done
    mov al, [r12]
    inc r12
    cmp al, '&'
    je .entity
    cmp al, 0x0A
    je .line_feed
    cmp al, ' '
    jbe .white
    cmp al, 0x80
    jae .high
    call lay_add_char
    jmp .loop
.white:
    cmp al, 0x0D
    je .loop
    cmp byte [lay_ws], WS_PRE
    jne .collapse
    cmp al, 0x09
    jne .pre_space
    mov al, ' '
    call lay_add_char
    call lay_add_char
    call lay_add_char
.pre_space:
    mov al, ' '
    call lay_add_char
    jmp .loop
.collapse:
    call lay_flush_word
    mov byte [lay_space], 1
    jmp .loop
.line_feed:
    cmp byte [lay_ws], WS_PRE
    jne .collapse
    call lay_flush_word
    call lay_break
    jmp .loop
.entity:
    call lay_entity
    jmp .loop
.high:
    call lay_high_byte
    jmp .loop
.done:
    pop r14
    pop r12
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; lay_emit_cp: EAX = Unicode code point -> the closest ASCII into the word
; ------------------------------------------------------------------------------
lay_emit_cp:
    push rax
    push rsi
    cmp eax, 0x7F
    jae .table
    cmp eax, ' '
    jae .ascii
    cmp eax, 0x09
    je .space
    cmp eax, 0x0A
    jne .ret
.space:
    mov eax, ' '
.ascii:
    call lay_add_char
    jmp .ret
.table:
    cmp eax, 0xC0
    jb .ranges
    cmp eax, 0xFF
    ja .ranges
    lea rsi, [lay_latin1_letters]
    mov al, [rsi + rax - 0xC0]
    call lay_add_char
    jmp .ret
.ranges:
    lea rsi, [lay_cp_map]
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
    call lay_add_char
    inc rsi
    jmp .put
.unknown:
    cmp eax, 0x10000                ; emoji and other astral symbols: nothing
    jae .ret
    mov al, '?'
    call lay_add_char
.ret:
    pop rsi
    pop rax
    ret

; lay_high_byte: AL = byte >= 0x80 (R12 after it, R14 = end) -> a character
lay_high_byte:
    push rax
    push rcx
    push rdx
    movzx eax, al
    cmp byte [lay_latin1], 0
    je .utf8
    cmp eax, 0xA0
    jae .emit
    lea rdx, [lay_cp1252]
    movzx eax, word [rdx + rax * 2 - 0x100]
    jmp .emit
.utf8:
    cmp eax, 0xC0
    jb .done
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
    cmp r12, r14
    jae .bad
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
    call lay_emit_cp
    jmp .done
.bad:
    mov eax, '?'
    call lay_add_char
.done:
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; lay_entity: R12 = just after '&' -> "&name;", "&#123;", "&#x1F;" (also
; "&copy" without ';' before a non-letter) as characters; else a literal '&'
; ------------------------------------------------------------------------------
lay_entity:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rbx, r12
    cmp byte [r12], '#'
    jne .named
    inc r12
    xor eax, eax
    xor ecx, ecx
    mov edx, 10
    mov dil, [r12]
    or dil, 0x20
    cmp dil, 'x'
    jne .number
    mov edx, 16
    inc r12
.number:
    cmp r12, r14
    jae .literal
    movzx edi, byte [r12]
    cmp edi, ';'
    je .number_end
    or edi, 0x20
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
    call lay_emit_cp
    jmp .out
.named:
    lea rsi, [lay_entities]
.entry:
    movzx ecx, byte [rsi]
    test ecx, ecx
    jz .literal
    lea rdi, [rsi + 1]
    push rcx
    push rsi
    dec ecx
    mov rsi, r12
    xchg rsi, rdi
    repe cmpsb
    pop rsi
    pop rcx
    jne .next_entry
    mov al, [r12 + rcx - 1]
    cmp al, ';'
    je .match
    dec ecx
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
    movzx eax, byte [rsi]
    movzx eax, word [rsi + rax + 1]
    call lay_emit_cp
    jmp .out
.literal:
    mov r12, rbx
    mov eax, '&'
    call lay_add_char
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; Painting
; ==============================================================================

; ------------------------------------------------------------------------------
; browser_render_html_page: draw the display list in the viewport (window
; geometry in br_wx/br_wy/br_ww/br_wh), laying the page out again first if
; the width changed
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

    ; viewport: between the bookmarks and the status bar, inside the border
    mov eax, [br_wx]
    add eax, WIN_BORDER
    mov [browser_vp_x], eax
    mov eax, [br_wy]
    add eax, BR_VIEW_Y
    mov [browser_vp_y], eax
    mov eax, [br_ww]
    sub eax, 2 * WIN_BORDER
    mov [browser_vp_w], eax
    mov eax, [br_wh]
    sub eax, BR_VIEW_Y + BR_STATUS_H + WIN_BORDER
    mov [browser_vp_h], eax
    ; content: LAY_PAD_X in from each side
    mov eax, [browser_vp_w]
    sub eax, 2 * LAY_PAD_X + 8      ; (and room for the right edge)
    cmp eax, [lay_width]
    je .laid_out
    call layout_page
.laid_out:
    ; page background
    mov ecx, [browser_vp_x]
    mov edx, [browser_vp_y]
    mov esi, [browser_vp_w]
    mov r8d, [browser_vp_h]
    mov eax, [lay_page_bg]
    call gfx_fill_rect

    mov r10d, [browser_vp_x]
    add r10d, LAY_PAD_X             ; R10 = content left (screen)
    mov r11d, [browser_vp_y]
    add r11d, LAY_PAD_Y
    sub r11d, [browser_scroll]      ; R11 = screen y of page y 0
    mov dword [browser_link_count], 0
    ; rectangles, then text on top
    mov r12d, IK_RECT
    call .pass
    mov r12d, IK_TEXT
    call .pass

    ; scrolling stops at the end of the page
    mov eax, [lay_height]
    add eax, LAY_LINE_H
    mov ecx, [browser_vp_h]
    sub ecx, 12
    sub eax, ecx
    jns .max
    xor eax, eax
.max:
    mov ecx, [browser_scroll]
    add ecx, [browser_vp_h]
    sub ecx, 12
    cmp ecx, [lay_height]
    setl byte [browser_more]
    cmp [browser_scroll], eax
    jle .log
    mov [browser_scroll], eax
    mov byte [gui_dirty], 1         ; draw again at the clamped position
    jmp .restore                    ; (that frame is the one to log)
.log:
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

; .pass: draw every visible item of kind R12
.pass:
    xor r13d, r13d
.item:
    cmp r13d, [lay_count]
    jae .pass_done
    mov eax, r13d
    call lay_item
    cmp [rbx + I_KIND], r12b
    jne .next_item
    mov edx, [rbx + I_Y]
    add edx, r11d                   ; screen y
    mov ecx, [rbx + I_X]
    add ecx, r10d                   ; screen x
    cmp r12d, IK_RECT
    je .rect
    mov eax, [browser_vp_y]
    add eax, 2
    cmp edx, eax
    jl .next_item
    mov eax, [browser_vp_y]
    add eax, [browser_vp_h]
    sub eax, FONT_H + 1
    cmp edx, eax
    jg .next_item
    call paint_text
    jmp .next_item
.rect:
    ; clipped to the viewport (a background can start above it)
    mov esi, [rbx + I_TEXT]         ; width
    mov r8d, [rbx + I_LINK]         ; height
    mov eax, [browser_vp_y]
    sub eax, edx                    ; rows above the viewport
    jle .rect_bottom
    sub r8d, eax
    add edx, eax
.rect_bottom:
    mov eax, [browser_vp_y]
    add eax, [browser_vp_h]
    sub eax, edx                    ; rows left in the viewport
    cmp r8d, eax
    jle .rect_h
    mov r8d, eax
.rect_h:
    test r8d, r8d
    jle .next_item
    mov eax, [browser_vp_x]
    add eax, [browser_vp_w]
    sub eax, 2
    sub eax, ecx                    ; columns left in the viewport
    cmp esi, eax
    jle .rect_w
    mov esi, eax
.rect_w:
    test esi, esi
    jle .next_item
    mov eax, [rbx + I_COLOR]
    call gfx_fill_rect
.next_item:
    inc r13d
    jmp .item
.pass_done:
    ret

; ------------------------------------------------------------------------------
; paint_text: RBX = text item, ECX,EDX = its screen position -> its glyphs
; (bold twice, one pixel apart), underline, link box and the test log
; ------------------------------------------------------------------------------
paint_text:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    test byte [rbx + I_FLAGS], IF_HIDDEN
    jnz .done
    movzx r9d, word [rbx + I_LEN]
    mov edi, [rbx + I_TEXT]
    lea rax, [abs LAY_TEXT]
    add rdi, rax                    ; RDI = text
    ; the right edge of the viewport
    mov eax, [browser_vp_x]
    add eax, [browser_vp_w]
    sub eax, 10
    mov [paint_right], eax
    ; for the test log
    mov eax, [rbx + I_Y]
    mov [lay_log_y], eax
    push rcx
.glyph:
    test r9d, r9d
    jz .glyphs_done
    lea eax, [ecx + 8]
    cmp eax, [paint_right]
    jg .glyphs_done
    mov al, [rdi]
    call browser_log_char
    mov esi, [rbx + I_COLOR]
    mov r8d, -1
    call gfx_draw_char
    test byte [rbx + I_FLAGS], IF_BOLD
    jz .next_glyph
    inc ecx
    call gfx_draw_char
    dec ecx
.next_glyph:
    add ecx, 8
    inc rdi
    dec r9d
    jmp .glyph
.glyphs_done:
    mov r9d, ecx                    ; R9 = right end
    pop rcx                         ; ECX = left
    ; underline (links are underlined by their style)
    test byte [rbx + I_FLAGS], IF_UNDER
    jz .link
    push rdx
    add edx, 13                     ; just under the baseline
    mov esi, r9d
    sub esi, ecx
    mov r8d, 1
    mov eax, [rbx + I_COLOR]
    call gfx_fill_rect
    pop rdx
.link:
    mov eax, [rbx + I_LINK]
    test eax, eax
    jz .done
    mov esi, [browser_link_count]
    cmp esi, BROWSER_MAX_LINKS
    jae .done
    inc dword [browser_link_count]
    shl esi, 5
    lea rdi, [browser_links]
    add rdi, rsi
    mov [rdi + LINK_X1], ecx
    mov [rdi + LINK_Y1], edx
    mov [rdi + LINK_X2], r9d
    lea esi, [edx + LAY_LINE_H - 2]
    mov [rdi + LINK_Y2], esi
    dec eax
    shl eax, 4
    lea rsi, [layout_links]
    mov r8, [rsi + rax]
    mov [rdi + LINK_HREF], r8
    mov r8d, [rsi + rax + 8]
    mov [rdi + LINK_HREF_LEN], r8d
.done:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

section .bss
paint_right:            resd 1

section .rodata
lay_attr_href:          db "href", 0
lay_attr_alt:           db "alt", 0
lay_attr_type:          db "type", 0
lay_attr_value:         db "value", 0
lay_attr_placeholder:   db "placeholder", 0
lay_attr_size:          db "size", 0
lay_attr_rows:          db "rows", 0
lay_attr_cols:          db "cols", 0
lay_str_submit:         db "Submit", 0
lay_str_reset:          db "Reset", 0
lay_str_file:           db "Choose file", 0
lay_str_arrow:          db "v", 0
section .text

; ------------------------------------------------------------------------------
; layout_node_at: ECX, EDX = screen point in the viewport -> EAX = the DOM node
; drawn there: a text run's node, else the innermost background box. CF=1 if
; there is only page background.
; ------------------------------------------------------------------------------
layout_node_at:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    sub ecx, [browser_vp_x]
    sub ecx, LAY_PAD_X              ; document x
    sub edx, [browser_vp_y]
    sub edx, LAY_PAD_Y
    add edx, [browser_scroll]       ; document y
    ; text, last drawn first
    mov eax, [lay_count]
.text:
    test eax, eax
    jz .rects
    dec eax
    call lay_item
    cmp byte [rbx + I_KIND], IK_TEXT
    jne .text
    mov esi, [rbx + I_Y]
    cmp edx, esi
    jl .text
    add esi, LAY_LINE_H
    cmp edx, esi
    jge .text
    mov esi, [rbx + I_X]
    cmp ecx, esi
    jl .text
    movzx edi, word [rbx + I_LEN]
    shl edi, 3
    add esi, edi
    cmp ecx, esi
    jge .text
    mov eax, [rbx + I_NODE]
    jmp .found
.rects:
    mov eax, [lay_count]
.rect:
    test eax, eax
    jz .none
    dec eax
    call lay_item
    cmp byte [rbx + I_KIND], IK_RECT
    jne .rect
    cmp dword [rbx + I_NODE], 0
    je .rect
    mov esi, [rbx + I_Y]
    cmp edx, esi
    jl .rect
    add esi, [rbx + I_LINK]         ; height
    cmp edx, esi
    jge .rect
    mov esi, [rbx + I_X]
    cmp ecx, esi
    jl .rect
    add esi, [rbx + I_TEXT]         ; width
    cmp ecx, esi
    jge .rect
    mov eax, [rbx + I_NODE]
.found:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    clc
    ret
.none:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    stc
    ret

; ==============================================================================
; Shared with browser.asm: scrolling, link boxes, the test log
; ==============================================================================

; link box of a visible link (painted this frame)
LINK_X1                 equ 0       ; dd screen box
LINK_Y1                 equ 4
LINK_X2                 equ 8
LINK_Y2                 equ 12
LINK_HREF               equ 16      ; dq into browser_page_buf
LINK_HREF_LEN           equ 24      ; dd
BROWSER_LINK_SIZE       equ 32
BROWSER_MAX_LINKS       equ 256

section .data
align 4
browser_scroll:         dd 0        ; pixels scrolled down
browser_more:           db 0        ; 1 = the page continues below the viewport
browser_page_plain:     db 0        ; 1 = plain text: keep line breaks and spaces
browser_page_latin1:    db 0        ; 1 = bytes 0x80-0xFF are Latin-1, not UTF-8

section .bss
alignb 16
browser_links:          resb BROWSER_MAX_LINKS * BROWSER_LINK_SIZE
lay_log_y:              resd 1

section .text
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
    mov edx, [lay_log_y]
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
    mov edx, [lay_log_y]
    mov [browser_log_y], edx
.done:
    pop rdi
    pop rdx
    pop rcx
.ret:
    ret

section .rodata
; named entities: db length (with ';'), name, dw code point
%macro LENT 2
    db %%end - %%start
%%start:
    db %1, ';'
%%end:
    dw %2
%endmacro
lay_entities:
    LENT "amp", '&'
    LENT "lt", '<'
    LENT "gt", '>'
    LENT "quot", '"'
    LENT "apos", "'"
    LENT "nbsp", 0xA0
    LENT "copy", 0xA9
    LENT "reg", 0xAE
    LENT "trade", 0x2122
    LENT "raquo", 0xBB
    LENT "laquo", 0xAB
    LENT "hellip", 0x2026
    LENT "mdash", 0x2014
    LENT "ndash", 0x2013
    LENT "lsquo", 0x2018
    LENT "rsquo", 0x2019
    LENT "sbquo", 0x201A
    LENT "ldquo", 0x201C
    LENT "rdquo", 0x201D
    LENT "bdquo", 0x201E
    LENT "middot", 0xB7
    LENT "bull", 0x2022
    LENT "times", 0xD7
    LENT "divide", 0xF7
    LENT "deg", 0xB0
    LENT "plusmn", 0xB1
    LENT "para", 0xB6
    LENT "sect", 0xA7
    LENT "euro", 0x20AC
    LENT "pound", 0xA3
    LENT "yen", 0xA5
    LENT "cent", 0xA2
    LENT "larr", 0x2190
    LENT "rarr", 0x2192
    LENT "uarr", 0x2191
    LENT "darr", 0x2193
    LENT "harr", 0x2194
    LENT "ensp", 0x2002
    LENT "emsp", 0x2003
    LENT "thinsp", 0x2009
    LENT "zwj", 0x200D
    LENT "zwnj", 0x200C
    LENT "shy", 0xAD
    LENT "minus", 0x2212
    LENT "prime", 0x2032
    LENT "eacute", 0xE9
    LENT "egrave", 0xE8
    LENT "aacute", 0xE1
    LENT "agrave", 0xE0
    LENT "iacute", 0xED
    LENT "oacute", 0xF3
    LENT "uacute", 0xFA
    LENT "ccedil", 0xE7
    LENT "ntilde", 0xF1
    LENT "auml", 0xE4
    LENT "ouml", 0xF6
    LENT "uuml", 0xFC
    LENT "szlig", 0xDF
    db 0

; U+00C0 - U+00FF as plain letters
lay_latin1_letters:
    db "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYTs"
    db "aaaaaaaceeeeiiiidnooooo/ouuuuyty"

; Windows-1252 0x80-0x9F as code points
lay_cp1252:
    dw 0x20AC, '?', 0x201A, 'f', 0x201E, 0x2026, '+', '+', '^', '%', 'S', 0x2039, 'O', '?', 'Z', '?'
    dw '?', 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, '~', 0x2122, 's', 0x203A, 'o', '?', 'z', 'Y'

; other code points: dd first, last, then up to 4 replacement bytes (0 = none)
%macro LCPS 3
    dd %1, %2
%%s:
    db %3
%%e:
    times 4 - (%%e - %%s) db 0
%endmacro
lay_cp_map:
    LCPS 0x7F, 0x9F, ""                 ; controls
    LCPS 0xA0, 0xA0, " "
    LCPS 0xA1, 0xA1, "!"
    LCPS 0xA2, 0xA2, "c"
    LCPS 0xA3, 0xA3, "L"
    LCPS 0xA4, 0xA4, "$"
    LCPS 0xA5, 0xA5, "Y"
    LCPS 0xA6, 0xA6, "|"
    LCPS 0xA7, 0xA7, "S"
    LCPS 0xA8, 0xA8, '"'
    LCPS 0xA9, 0xA9, "(c)"
    LCPS 0xAA, 0xAA, "a"
    LCPS 0xAB, 0xAB, "<<"
    LCPS 0xAC, 0xAC, "-"
    LCPS 0xAD, 0xAD, ""                 ; soft hyphen
    LCPS 0xAE, 0xAE, "(R)"
    LCPS 0xAF, 0xAF, "-"
    LCPS 0xB0, 0xB0, "o"
    LCPS 0xB1, 0xB1, "+-"
    LCPS 0xB2, 0xB2, "2"
    LCPS 0xB3, 0xB3, "3"
    LCPS 0xB4, 0xB4, "'"
    LCPS 0xB5, 0xB5, "u"
    LCPS 0xB6, 0xB6, "P"
    LCPS 0xB7, 0xB7, "."
    LCPS 0xB8, 0xB8, ","
    LCPS 0xB9, 0xB9, "1"
    LCPS 0xBA, 0xBA, "o"
    LCPS 0xBB, 0xBB, ">>"
    LCPS 0xBC, 0xBC, "1/4"
    LCPS 0xBD, 0xBD, "1/2"
    LCPS 0xBE, 0xBE, "3/4"
    LCPS 0xBF, 0xBF, "?"
    LCPS 0x2000, 0x200A, " "            ; spaces
    LCPS 0x200B, 0x200F, ""             ; zero-width
    LCPS 0x2010, 0x2015, "-"            ; dashes
    LCPS 0x2018, 0x201B, "'"
    LCPS 0x201C, 0x201F, '"'
    LCPS 0x2020, 0x2021, "+"
    LCPS 0x2022, 0x2023, "*"
    LCPS 0x2026, 0x2026, "..."
    LCPS 0x2028, 0x202F, " "
    LCPS 0x2032, 0x2033, "'"
    LCPS 0x2039, 0x2039, "<"
    LCPS 0x203A, 0x203A, ">"
    LCPS 0x20AC, 0x20AC, "EUR"
    LCPS 0x2122, 0x2122, "TM"
    LCPS 0x2190, 0x2190, "<-"
    LCPS 0x2191, 0x2191, "^"
    LCPS 0x2192, 0x2192, "->"
    LCPS 0x2193, 0x2193, "v"
    LCPS 0x2194, 0x2194, "<->"
    LCPS 0x2212, 0x2212, "-"
    LCPS 0x2215, 0x2215, "/"
    LCPS 0x2260, 0x2260, "!="
    LCPS 0x2264, 0x2264, "<="
    LCPS 0x2265, 0x2265, ">="
    LCPS 0x25B2, 0x25B2, "^"
    LCPS 0x25BC, 0x25BC, "v"
    LCPS 0x25CF, 0x25CF, "*"
    LCPS 0x2713, 0x2714, "v"
    LCPS 0x2715, 0x2717, "x"
    LCPS 0xFE00, 0xFE0F, ""             ; variation selectors
    LCPS 0xFEFF, 0xFEFF, ""             ; byte order mark
    dd 0xFFFFFFFF
section .text
