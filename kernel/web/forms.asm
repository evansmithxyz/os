; ==============================================================================
; Antigravity OS - form controls: values, focus, typing, submission
; ------------------------------------------------------------------------------
; layout.asm draws <input>, <textarea>, <select> and <button> as boxes. What
; the user changes lives here, one entry per control, not in the page's
; value="" / checked attributes (a real browser's "dirty" value and
; checkedness); element.value in the page's scripts reads and writes it
; (jsdom.asm).
;
;   form_click   a press on the page: focus a text field, tick a check box or
;                radio button, show the next <select> option, press a button
;   form_key     typing into the focused field; Enter submits its form, Tab
;                moves to the next field, Esc leaves it
;   form_submit  the form's fields as name=value&... after its action URL
;                (GET), or as the body the browser POSTs there
; ==============================================================================

[bits 64]

FORM_MAX_FIELDS         equ 64
FORM_VALUE_MAX          equ 1000
FORM_QUERY_MAX          equ 16384

; field entry
FE_NODE                 equ 0       ; dd the control
FE_LEN                  equ 4       ; dd value length
FE_FLAGS                equ 8       ; dd FEF_*
FE_SEL                  equ 12      ; dd <select>: index of the chosen option
FE_VALUE                equ 16      ; the value (bytes, not HTML)
FORM_ENTRY_SIZE         equ 1024
FEF_CHECK_SET           equ 1       ; FEF_CHECKED replaces the checked attribute
FEF_CHECKED             equ 2
FEF_SEL_SET             equ 4       ; FE_SEL replaces the selected attribute

; control kinds (form_kind)
FK_NONE                 equ 0
FK_TEXT                 equ 1       ; text, search, email, url, number, ...
FK_PASSWORD             equ 2
FK_TEXTAREA             equ 3
FK_CHECKBOX             equ 4
FK_RADIO                equ 5
FK_SUBMIT               equ 6       ; <input type=submit|image>, <button>
FK_BUTTON               equ 7       ; type=button|reset, <button type=button>
FK_HIDDEN               equ 8
FK_SELECT               equ 9
FK_FILE                 equ 10

section .data
align 4
form_count:             dd 0        ; entries in use
form_focus:             dd 0        ; the focused text field, 0 = none

section .bss
alignb 16
form_fields:            resb FORM_MAX_FIELDS * FORM_ENTRY_SIZE
form_url:               resb BROWSER_URL_MAX
form_query:             resb FORM_QUERY_MAX     ; name=value&... (a POST's body)
form_query_len:         resd 1
form_first:             resb 1      ; building the query: no '&' yet
form_post:              resb 1      ; form_build_url: the form is method=post
form_post_pending:      resb 1      ; the next navigation POSTs form_query

section .rodata
form_str_type:          db "type", 0
form_str_value:         db "value", 0
form_str_name:          db "name", 0
form_str_checked:       db "checked", 0
form_str_selected:      db "selected", 0
form_str_disabled:      db "disabled", 0
form_str_action:        db "action", 0
form_str_method:        db "method", 0
form_str_input:         db "input", 0
form_str_change:        db "change", 0
form_str_submit_event:  db "submit", 0
form_str_on:            db "on", 0
form_str_button:        db "button", 0
form_str_reset:         db "reset", 0
form_type_urlencoded:   db "application/x-www-form-urlencoded", 0
form_method_post:       db "POST", 0
klog_form_submit:       db "browser: form -> ", 0
klog_form_body:         db "browser: form body ", 0
klog_form_focus:        db "browser: field focused ", 0
klog_form_post:         db "browser: form POST -> ", 0
; input types, then their kinds
form_types:
    db "hidden", 0, FK_HIDDEN
    db "checkbox", 0, FK_CHECKBOX
    db "radio", 0, FK_RADIO
    db "submit", 0, FK_SUBMIT
    db "image", 0, FK_SUBMIT
    db "button", 0, FK_BUTTON
    db "reset", 0, FK_BUTTON
    db "password", 0, FK_PASSWORD
    db "file", 0, FK_FILE
    db 0

section .text
; ------------------------------------------------------------------------------
; form_reset: a new page -> no changed controls, nothing focused
; ------------------------------------------------------------------------------
form_reset:
    mov dword [form_count], 0
    mov dword [form_focus], 0
    ret

; ------------------------------------------------------------------------------
; form_kind: EAX = node -> ECX = FK_* (FK_NONE if it is not a form control)
; ------------------------------------------------------------------------------
form_kind:
    push rax
    push rbx
    push rsi
    push rdi
    xor ecx, ecx
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    jne .out
    movzx ebx, byte [rbx + N_TAG]
    mov ecx, FK_TEXTAREA
    cmp ebx, TAGID_TEXTAREA
    je .out
    mov ecx, FK_SELECT
    cmp ebx, TAGID_SELECT
    je .out
    cmp ebx, TAGID_BUTTON
    je .button
    xor ecx, ecx
    cmp ebx, TAGID_INPUT
    jne .out
    ; <input type=...>
    lea rdi, [form_str_type]
    call dom_attr
    mov ebx, ecx
    mov ecx, FK_TEXT
    jc .out
    lea rdi, [form_types]
.type:
    cmp byte [rdi], 0
    je .out                         ; anything else is a text field
    call form_attr_is
    je .type_found
.skip:
    inc rdi
    cmp byte [rdi - 1], 0
    jne .skip
    inc rdi                         ; its kind
    jmp .type
.type_found:
    call strlen_rdi
    movzx ecx, byte [rdi + rax + 1]
    jmp .out
.button:
    ; <button type=button|reset> does nothing by itself; others submit
    lea rdi, [form_str_type]
    call dom_attr
    mov ebx, ecx
    mov ecx, FK_SUBMIT
    jc .out
    lea rdi, [form_str_button]
    call form_attr_is
    je .plain_button
    lea rdi, [form_str_reset]
    call form_attr_is
    jne .out
.plain_button:
    mov ecx, FK_BUTTON
.out:
    pop rdi
    pop rsi
    pop rbx
    pop rax
    ret

; form_attr_is: RSI/EBX = attribute value, RDI = lower-case name (NUL-ended)
; -> ZF=1 if they are the same, ignoring case
form_attr_is:
    push rax
    push rcx
    push rsi
    push rdi
    mov ecx, ebx
.cmp:
    test ecx, ecx
    jz .end
    mov al, [rsi]
    cmp al, 'A'
    jb .have
    cmp al, 'Z'
    ja .have
    or al, 0x20
.have:
    cmp al, [rdi]
    jne .out
    inc rsi
    inc rdi
    dec ecx
    jmp .cmp
.end:
    cmp byte [rdi], 0
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; form_is_text: ECX = kind -> ZF=1 for the kinds you type into
form_is_text:
    cmp ecx, FK_TEXT
    je .ret
    cmp ecx, FK_PASSWORD
    je .ret
    cmp ecx, FK_TEXTAREA
.ret:
    ret

; ------------------------------------------------------------------------------
; form_find: EAX = node -> RBX = its entry; CF=1 if it has none
; ------------------------------------------------------------------------------
form_find:
    push rcx
    lea rbx, [form_fields]
    mov ecx, [form_count]
.entry:
    test ecx, ecx
    jz .none
    cmp [rbx + FE_NODE], eax
    je .found
    add rbx, FORM_ENTRY_SIZE
    dec ecx
    jmp .entry
.found:
    pop rcx
    clc
    ret
.none:
    pop rcx
    stc
    ret

; ------------------------------------------------------------------------------
; form_entry: EAX = node -> RBX = its entry, made (with the value the page
; gave it) if it has none yet; CF=1 if the table is full
; ------------------------------------------------------------------------------
form_entry:
    call form_find
    jnc .ret
    push rcx
    push rsi
    push rdi
    cmp dword [form_count], FORM_MAX_FIELDS
    jae .full
    call form_value                 ; RSI/ECX (before the entry exists)
    push rcx
    mov ecx, [form_count]
    inc dword [form_count]
    imul ebx, ecx, FORM_ENTRY_SIZE
    pop rcx
    lea rdi, [form_fields]
    add rbx, rdi
    mov [rbx + FE_NODE], eax
    mov dword [rbx + FE_FLAGS], 0
    mov dword [rbx + FE_SEL], 0
    call form_store
    pop rdi
    pop rsi
    pop rcx
    clc
.ret:
    ret
.full:
    pop rdi
    pop rsi
    pop rcx
    stc
    ret

; form_store: RBX = entry, RSI/ECX = value -> kept (cut at FORM_VALUE_MAX)
form_store:
    push rcx
    push rsi
    push rdi
    cmp ecx, FORM_VALUE_MAX
    jbe .len
    mov ecx, FORM_VALUE_MAX
.len:
    mov [rbx + FE_LEN], ecx
    lea rdi, [rbx + FE_VALUE]
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; form_value: EAX = control -> RSI/ECX = its value: what was typed or set by
; a script, else value="" (a <textarea>: its text), entities decoded. May use
; the page builder (jsd_bld), so use it before building anything else.
; ------------------------------------------------------------------------------
form_value:
    push rbx
    push rdi
    call form_find
    jc .from_page
    lea rsi, [rbx + FE_VALUE]
    mov ecx, [rbx + FE_LEN]
    jmp .out
.from_page:
    call dom_node
    cmp byte [rbx + N_TAG], TAGID_TEXTAREA
    jne .attr
    ; a textarea's text (its one text child; a first newline is not part of it)
    call jsd_bld_reset
    mov ebx, [rbx + N_FIRST]
    test ebx, ebx
    jz .built
    push rax
    mov eax, ebx
    call dom_node
    pop rax
    mov rsi, [rbx + N_NAME]
    mov ecx, [rbx + N_NAME_LEN]
    test ecx, ecx
    jz .built
    cmp byte [rsi], 13
    jne .lf
    inc rsi
    dec ecx
    jz .built
.lf:
    cmp byte [rsi], 10
    jne .decode
    inc rsi
    dec ecx
.decode:
    call jsd_decode
    jmp .built
.attr:
    lea rdi, [form_str_value]
    call form_attr_decoded
    jmp .out
.built:
    mov rsi, JSD_BLD
    mov ecx, [jsd_bld_len]
.out:
    pop rdi
    pop rbx
    ret

; ------------------------------------------------------------------------------
; form_attr_decoded: EAX = element, RDI = attribute name -> RSI/ECX = its
; value with entities decoded (in the page builder); empty if it has none
; ------------------------------------------------------------------------------
form_attr_decoded:
    call jsd_bld_reset
    call dom_attr
    jc .built
    call jsd_decode
.built:
    mov rsi, JSD_BLD
    mov ecx, [jsd_bld_len]
    ret

; ------------------------------------------------------------------------------
; form_set_value: EAX = control, RSI/ECX = new value -> kept for it (a script
; set element.value). CF=1 if the table is full.
; ------------------------------------------------------------------------------
form_set_value:
    push rbx
    call form_entry
    jc .ret
    call form_store
    clc
.ret:
    pop rbx
    ret

; ------------------------------------------------------------------------------
; form_checked: EAX = check box or radio button -> CF=1 if it is ticked
; ------------------------------------------------------------------------------
form_checked:
    push rbx
    push rcx
    push rsi
    push rdi
    call form_find
    jc .attr
    test dword [rbx + FE_FLAGS], FEF_CHECK_SET
    jz .attr
    test dword [rbx + FE_FLAGS], FEF_CHECKED
    jz .no
    jmp .yes
.attr:
    lea rdi, [form_str_checked]
    call dom_attr
    jc .no
.yes:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    stc
    ret
.no:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    clc
    ret

; form_set_checked: EAX = control, DL = 1 ticked / 0 not
form_set_checked:
    push rbx
    call form_entry
    jc .ret
    and dword [rbx + FE_FLAGS], ~FEF_CHECKED
    or dword [rbx + FE_FLAGS], FEF_CHECK_SET
    test dl, dl
    jz .ret
    or dword [rbx + FE_FLAGS], FEF_CHECKED
.ret:
    pop rbx
    ret

; ------------------------------------------------------------------------------
; form_option: EAX = <select> -> EDX = its chosen <option> (0 if it has none),
; ECX = how many options it has
; ------------------------------------------------------------------------------
form_option:
    push rax
    push rbx
    push rsi
    push rdi
    push r8
    push r9
    mov r8d, eax                    ; R8 = the select
    mov r9d, -1                     ; R9 = the chosen index, -1 = by attribute
    call form_find
    jc .count
    test dword [rbx + FE_FLAGS], FEF_SEL_SET
    jz .count
    mov r9d, [rbx + FE_SEL]
.count:
    xor ecx, ecx                    ; options so far
    xor esi, esi                    ; ESI = the first option
    xor edi, edi                    ; EDI = the chosen one
    mov eax, r8d
.walk:
    mov edx, r8d
    call jsd_next
    test eax, eax
    jz .done
    call dom_node
    cmp byte [rbx + N_TAG], TAGID_OPTION
    jne .walk
    test esi, esi
    jnz .not_first
    mov esi, eax
.not_first:
    cmp r9d, -1
    je .by_attr
    cmp ecx, r9d
    jne .next_option
    mov edi, eax
    jmp .next_option
.by_attr:
    test edi, edi
    jnz .next_option                ; the first one marked selected wins
    push rcx
    push rsi
    push rdi
    lea rdi, [form_str_selected]
    call dom_attr
    pop rdi
    pop rsi
    pop rcx
    jc .next_option
    mov edi, eax
.next_option:
    inc ecx
    jmp .walk
.done:
    mov edx, edi
    test edx, edx
    jnz .out
    mov edx, esi
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbx
    pop rax
    ret

; form_option_index: EAX = <select>, EDX = one of its options -> ECX = its index
form_option_index:
    push rax
    push rbx
    push rdx
    push r8
    mov r8d, edx
    mov edx, eax
    xor ecx, ecx
.walk:
    call jsd_next
    test eax, eax
    jz .out
    cmp eax, r8d
    je .out
    push rbx
    call dom_node
    cmp byte [rbx + N_TAG], TAGID_OPTION
    pop rbx
    jne .walk
    inc ecx
    jmp .walk
.out:
    pop r8
    pop rdx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; form_option_text: EAX = <option> -> RSI/ECX = its label: label="", else its
; text with entities decoded and white space trimmed (in the page builder)
; ------------------------------------------------------------------------------
form_option_text:
    push rax
    push rbx
    push rdx
    push rdi
    call jsd_bld_reset
    mov edx, eax                    ; EDX = the option
.walk:
    call jsd_next
    test eax, eax
    jz .built
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_TEXT
    jne .walk
    test byte [rbx + N_FLAGS], NF_COMMENT
    jnz .walk
    mov rsi, [rbx + N_NAME]
    mov ecx, [rbx + N_NAME_LEN]
    call jsd_decode
    jmp .walk
.built:
    ; trim and collapse white space in place
    mov rsi, JSD_BLD
    mov ecx, [jsd_bld_len]
    xor edx, edx                    ; EDX = length out
    mov rdi, rsi
    mov bl, 1                       ; after a space (or at the start)
.trim:
    test ecx, ecx
    jz .trimmed
    lodsb
    dec ecx
    cmp al, ' '
    ja .keep
    test bl, bl
    jnz .trim
    mov bl, 1
    mov al, ' '
    stosb
    inc edx
    jmp .trim
.keep:
    xor bl, bl
    stosb
    inc edx
    jmp .trim
.trimmed:
    test edx, edx
    jz .set
    cmp byte [rdi - 1], ' '
    jne .set
    dec edx
.set:
    mov [jsd_bld_len], edx
    mov rsi, JSD_BLD
    mov ecx, edx
    pop rdi
    pop rdx
    pop rbx
    pop rax
    ret

; form_option_value: EAX = <option> -> RSI/ECX = value="", else its text
form_option_value:
    push rdi
    lea rdi, [form_str_value]
    call dom_attr
    jc .text
    call form_attr_decoded
    pop rdi
    ret
.text:
    call form_option_text
    pop rdi
    ret

; ------------------------------------------------------------------------------
; form_control_at: EAX = node (from layout_node_at) -> EAX = the form
; control it is part of, ECX = its kind; CF=1 if it is not in one
; ------------------------------------------------------------------------------
form_control_at:
    push rbx
    push rdx
    mov edx, 8                      ; a button's label may be a few levels down
.up:
    test eax, eax
    jz .none
    call form_kind
    test ecx, ecx
    jnz .found
    call dom_node
    mov eax, [rbx + N_PARENT]
    dec edx
    jnz .up
.none:
    pop rdx
    pop rbx
    stc
    ret
.found:
    pop rdx
    pop rbx
    clc
    ret

; form_of: EAX = control -> EAX = the <form> around it; CF=1 if none
form_of:
    push rbx
.up:
    call dom_node
    mov eax, [rbx + N_PARENT]
    test eax, eax
    jz .none
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    jne .up
    cmp dword [rbx + N_NAME_LEN], 4
    jne .up
    push rcx
    mov rcx, [rbx + N_NAME]
    mov ecx, [rcx]
    or ecx, 0x20202020
    cmp ecx, 'form'
    pop rcx
    jne .up
    pop rbx
    clc
    ret
.none:
    pop rbx
    stc
    ret

; form_disabled: EAX = control -> CF=1 if it has disabled=""
form_disabled:
    push rcx
    push rsi
    push rdi
    lea rdi, [form_str_disabled]
    call dom_attr
    cmc
    pop rdi
    pop rsi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; form_take_post: (browser_navigate) a form asked for a POST -> the request
; carries form_query as its body (http_req_*), until browser_fetch_http
; has its answer
; ------------------------------------------------------------------------------
form_take_post:
    cmp byte [form_post_pending], 0
    je .ret
    mov byte [form_post_pending], 0
    push rax
    lea rax, [form_method_post]
    mov [http_req_method], rax
    lea rax, [form_query]
    mov [http_req_body], rax
    mov eax, [form_query_len]
    mov [http_req_body_len], eax
    lea rax, [form_type_urlencoded]
    mov [http_req_type], rax
    pop rax
.ret:
    ret

; form_event: EAX = control, RSI = event type -> the page's handlers ran; a
; navigation they asked for happens
form_event:
    call jsd_page_event
    cmp byte [jsd_nav_pending], 0
    je .ret
    call browser_js_navigation
.ret:
    ret

; form_changed: the page must be laid out again (a value, the focus)
form_changed:
    mov dword [lay_width], -1
    mov byte [gui_dirty], 1
    ret

; ------------------------------------------------------------------------------
; form_focus_on: EAX = text field (0 = none) -> it has the keyboard
; ------------------------------------------------------------------------------
form_focus_on:
    cmp eax, [form_focus]
    je .ret
    mov [form_focus], eax
    call form_changed
    test eax, eax
    jz .ret
    push rsi
    lea rsi, [klog_form_focus]      ; "[klog] browser: field focused N"
    call klog_dec
    pop rsi
.ret:
    ret

; ------------------------------------------------------------------------------
; form_click: ECX, EDX = the pointer (screen) -> what a press on a control
; does; CF=1 if it was on one (links under it are not followed)
; ------------------------------------------------------------------------------
form_click:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    mov eax, [browser_vp_x]
    cmp ecx, eax
    jl .miss
    add eax, [browser_vp_w]
    cmp ecx, eax
    jge .miss
    mov eax, [browser_vp_y]
    cmp edx, eax
    jl .miss
    add eax, [browser_vp_h]
    cmp edx, eax
    jge .miss
    call layout_node_at
    jc .miss
    call form_control_at
    jc .miss
    call form_disabled
    jc .hit                         ; a disabled control swallows the press
    call form_is_text
    je .text
    cmp ecx, FK_CHECKBOX
    je .checkbox
    cmp ecx, FK_RADIO
    je .radio
    cmp ecx, FK_SELECT
    je .select
    cmp ecx, FK_SUBMIT
    jne .other
    ; a submit button: its form, sent with this button's name=value
    mov edx, eax
    call form_of
    jc .unfocus
    call form_submit
    jmp .unfocus
.text:
    call form_focus_on
    jmp .hit
.checkbox:
    call form_checked
    setnc dl
    call form_set_checked
    jmp .toggled
.radio:
    call form_radio_pick
.toggled:
    call form_changed
    push rsi
    lea rsi, [form_str_change]
    call form_event
    pop rsi
    jmp .unfocus
.select:
    ; no drop-down list: each press shows the next option
    push rax
    call form_option
    mov r8d, ecx                    ; R8 = how many
    call form_option_index
    inc ecx
    cmp ecx, r8d
    jb .index
    xor ecx, ecx
.index:
    call form_entry
    jc .select_done
    mov [rbx + FE_SEL], ecx
    or dword [rbx + FE_FLAGS], FEF_SEL_SET
.select_done:
    pop rax
    jmp .toggled
.other:
.unfocus:
    xor eax, eax
    call form_focus_on
.hit:
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret
.miss:
    xor eax, eax
    call form_focus_on
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret

; form_radio_pick: EAX = radio button -> ticked, and the others with its
; name in its form (or the page, outside a form) not
form_radio_pick:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r8d, eax                    ; R8 = the one picked
    mov edx, 1
    call form_set_checked
    call form_of
    jnc .scope
    xor eax, eax                    ; the whole document
.scope:
    mov r9d, eax                    ; R9 = where to look
    ; its name (raw attribute text: the same page wrote both)
    mov eax, r8d
    lea rdi, [form_str_name]
    call dom_attr
    jc .done
    mov r10, rsi
    mov ebx, ecx                    ; R10/EBX = the name
    mov eax, r9d
.walk:
    mov edx, r9d
    call jsd_next
    test eax, eax
    jz .done
    cmp eax, r8d
    je .walk
    call form_kind
    cmp ecx, FK_RADIO
    jne .walk
    lea rdi, [form_str_name]
    push rbx
    call dom_attr
    pop rbx
    jc .walk
    cmp ecx, ebx
    jne .walk
    push rcx
    mov rdi, r10
    repe cmpsb
    pop rcx
    jne .walk
    xor edx, edx
    call form_set_checked
    jmp .walk
.done:
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
; form_key: AL = character (0 for other keys), AH = scancode -> typed into
; the focused field; CF=1 if it took the key
; ------------------------------------------------------------------------------
form_key:
    push rax
    push rbx
    push rcx
    push rdx
    mov edx, [form_focus]
    test edx, edx
    jz .not_used
    test al, al
    jz .not_used                    ; arrows and pages still scroll
    cmp al, 0x1B
    je .escape
    cmp al, 0x09
    je .tab
    xchg eax, edx                   ; EAX = field, DL = character
    call form_entry
    jc .used
    cmp dl, 0x08
    je .backspace
    cmp dl, 0x0D
    je .enter
    cmp dl, 32
    jb .used
    cmp dl, 126
    ja .used
.insert:
    mov ecx, [rbx + FE_LEN]
    cmp ecx, FORM_VALUE_MAX
    jae .used
    mov [rbx + FE_VALUE + rcx], dl
    inc dword [rbx + FE_LEN]
    jmp .edited
.backspace:
    mov ecx, [rbx + FE_LEN]
.back_byte:
    test ecx, ecx
    jz .used
    dec ecx
    mov dl, [rbx + FE_VALUE + rcx]
    and dl, 0xC0
    cmp dl, 0x80                    ; a UTF-8 continuation byte: keep going
    je .back_byte
    mov [rbx + FE_LEN], ecx
    jmp .edited
.enter:
    call form_kind
    cmp ecx, FK_TEXTAREA
    jne .submit
    mov dl, 10
    jmp .insert
.submit:
    push rax
    call form_of
    mov edx, 0                      ; the form's default button
    jc .enter_done
    call form_submit
.enter_done:
    pop rax
    jmp .used
.edited:
    call form_changed
    push rsi
    lea rsi, [form_str_input]
    call form_event
    pop rsi
    jmp .used
.escape:
    xor eax, eax
    call form_focus_on
    jmp .used
.tab:
    call form_next_field
    jmp .used
.used:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret
.not_used:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret

; form_next_field: the focus moves to the next text field in the page (none
; after the last)
form_next_field:
    push rax
    push rcx
    push rdx
    mov eax, [form_focus]
.walk:
    xor edx, edx
    call jsd_next
    test eax, eax
    jz .set
    call form_kind
    call form_is_text
    jne .walk
    push rbx
    call dom_node
    cmp byte [rbx + S_DISPLAY], DISP_NONE
    pop rbx
    je .walk
    call form_disabled
    jc .walk
.set:
    call form_focus_on
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; form_submit: EAX = <form>, EDX = the button that sent it (0: the first
; submit button, as when Enter is pressed in a field) -> the page's submit
; event, then the browser goes to form_build_url's URL
; ------------------------------------------------------------------------------
form_submit:
    push rax
    push rcx
    push rsi
    push rdi
    lea rsi, [form_str_submit_event]
    call jsd_page_event
    jc .done                        ; preventDefault()
    cmp byte [jsd_nav_pending], 0
    je .ours
    call browser_js_navigation      ; the script went somewhere itself
    jmp .done
.ours:
    call form_build_url
    mov al, [form_post]
    mov [form_post_pending], al     ; browser_navigate sends the body
    lea rsi, [form_url]
    lea rdi, [browser_url_buf]
    mov ecx, BROWSER_URL_MAX
    call strlcpy
    xor eax, eax
    call form_focus_on
    call browser_navigate
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; form_build_url: EAX = <form>, EDX = the button that sent it (0: its first
; submit button) -> form_query = the form's fields: name=value&... of every
; named, enabled control (check boxes and radio buttons only when ticked,
; only the button that sent it); form_url = its action URL (the page if it
; has none) with them as the query, or for method="post" (form_post = 1)
; without them: they are the body
; ------------------------------------------------------------------------------
form_build_url:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8d, eax                    ; R8 = the form
    mov r9d, edx                    ; R9 = the submitter
    mov byte [form_post], 0
    lea rdi, [form_str_method]
    call dom_attr
    jc .get
    mov ebx, ecx
    lea rdi, [form_str_post]
    call form_attr_is
    jne .get
    mov byte [form_post], 1
.get:
    ; the default button, if none sent it
    test r9d, r9d
    jnz .action
    mov eax, r8d
.find_button:
    mov edx, r8d
    call jsd_next
    test eax, eax
    jz .action
    call form_kind
    cmp ecx, FK_SUBMIT
    jne .find_button
    mov r9d, eax
.action:
    ; action="" resolved against the page; none, "" or "#..." is the page
    mov eax, r8d
    lea rdi, [form_str_action]
    call dom_attr
    jc .page_url
    call browser_resolve_link
    jc .page_url
    mov rsi, [browser_resolved]
    jmp .have_url
.page_url:
    lea rsi, [browser_page_url]
.have_url:
    lea rdi, [form_url]
    mov ecx, BROWSER_URL_MAX
    call strlcpy
    ; drop its query and fragment
    xor ecx, ecx
.cut:
    mov al, [rdi + rcx]
    test al, al
    jz .cut_here
    cmp al, '?'
    je .cut_here
    cmp al, '#'
    je .cut_here
    inc ecx
    jmp .cut
.cut_here:
    mov byte [rdi + rcx], 0
    mov dword [form_query_len], 0
    mov byte [form_first], 1
    ; every named control in the form, in order
    mov eax, r8d
.field:
    mov edx, r8d
    call jsd_next
    test eax, eax
    jz .built
    call form_kind
    test ecx, ecx
    jz .field
    call form_disabled
    jc .field
    cmp ecx, FK_BUTTON
    je .field
    cmp ecx, FK_FILE
    je .field
    cmp ecx, FK_SUBMIT
    jne .not_submit
    cmp eax, r9d
    jne .field                      ; only the button that sent it
.not_submit:
    cmp ecx, FK_CHECKBOX
    je .check
    cmp ecx, FK_RADIO
    jne .named
.check:
    call form_checked
    jnc .field
.named:
    call form_add_field
    jmp .field
.built:
    cmp byte [form_post], 0
    jne .post
    ; GET: "?" and the fields after the URL (none: no '?')
    cmp dword [form_query_len], 0
    je .log
    lea rdi, [form_url]
    mov rsi, rdi
    call strlen
    mov ecx, eax
    mov byte [rdi + rcx], '?'
    inc ecx
    lea rsi, [form_query]
    mov edx, [form_query_len]
.append:
    test edx, edx
    jz .appended
    cmp ecx, BROWSER_URL_MAX - 1
    jae .appended
    mov al, [rsi]
    mov [rdi + rcx], al
    inc rsi
    inc ecx
    dec edx
    jmp .append
.appended:
    mov byte [rdi + rcx], 0
.log:
    lea rsi, [klog_form_submit]     ; "[klog] browser: form -> URL"
    lea rdi, [form_url]
    call klog2
    jmp .out
.post:
    ; "[klog] browser: form POST -> URL <body>"
    lea rdi, [form_query]
    mov ecx, [form_query_len]
    mov byte [rdi + rcx], 0
    lea rsi, [klog_form_post]
    lea rdi, [form_url]
    call klog2
    lea rsi, [klog_form_body]
    lea rdi, [form_query]
    call klog2
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; form_add_field: EAX = control, ECX = its kind -> "&name=value" added to
; form_query (nothing if it has no name)
form_add_field:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov ebx, ecx                    ; EBX = kind
    lea rdi, [form_str_name]
    call form_attr_decoded
    test ecx, ecx
    jz .done
    cmp byte [form_first], 0
    jne .first
    push rax
    mov al, '&'
    call form_url_byte
    pop rax
.first:
    mov byte [form_first], 0
    call form_url_encode            ; the name
    push rax
    mov al, '='
    call form_url_byte
    pop rax
    ; the value
    cmp ebx, FK_SELECT
    je .select
    cmp ebx, FK_CHECKBOX
    je .check
    cmp ebx, FK_RADIO
    je .check
    cmp ebx, FK_SUBMIT
    je .attr_value
    call form_value
    jmp .encode
.check:
    lea rdi, [form_str_value]
    push rsi
    push rcx
    call dom_attr
    pop rcx
    pop rsi
    jnc .attr_value
    lea rsi, [form_str_on]
    mov ecx, 2
    jmp .encode
.attr_value:
    lea rdi, [form_str_value]
    call form_attr_decoded
    jmp .encode
.select:
    call form_option
    test edx, edx
    jz .done
    mov eax, edx
    call form_option_value
.encode:
    call form_url_encode
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; form_url_byte: AL -> appended to form_query (if it fits)
form_url_byte:
    push rcx
    push rdi
    mov ecx, [form_query_len]
    cmp ecx, FORM_QUERY_MAX - 1
    jae .full
    lea rdi, [form_query]
    mov [rdi + rcx], al
    inc dword [form_query_len]
.full:
    pop rdi
    pop rcx
    ret

; form_url_encode: RSI/ECX = text -> appended to form_query as
; application/x-www-form-urlencoded (space = '+', newline = %0D%0A)
form_url_encode:
    push rax
    push rbx
    push rcx
    push rsi
.byte:
    test ecx, ecx
    jz .done
    lodsb
    dec ecx
    cmp al, ' '
    je .plus
    cmp al, 10
    je .newline
    cmp al, '0'
    jb .check_mark
    cmp al, '9'
    jbe .plain
    cmp al, 'A'
    jb .percent
    cmp al, 'Z'
    jbe .plain
    cmp al, 'a'
    jb .underscore
    cmp al, 'z'
    jbe .plain
    jmp .percent
.underscore:
    cmp al, '_'
    je .plain
    jmp .percent
.check_mark:
    cmp al, '*'
    je .plain
    cmp al, '-'
    je .plain
    cmp al, '.'
    je .plain
    cmp al, 13
    je .byte                        ; (CR LF comes from the LF)
.percent:
    mov bl, al
    mov al, '%'
    call form_url_byte
    mov al, bl
    shr al, 4
    call .hex
    mov al, bl
    and al, 15
    call .hex
    jmp .byte
.plain:
    call form_url_byte
    jmp .byte
.plus:
    mov al, '+'
    call form_url_byte
    jmp .byte
.newline:
    mov al, '%'
    call form_url_byte
    mov al, '0'
    call form_url_byte
    mov al, 'D'
    call form_url_byte
    mov al, '%'
    call form_url_byte
    mov al, '0'
    call form_url_byte
    mov al, 'A'
    call form_url_byte
    jmp .byte
.done:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret
.hex:
    add al, '0'
    cmp al, '9'
    jbe .hex_out
    add al, 'A' - '0' - 10
.hex_out:
    jmp form_url_byte

section .rodata
form_str_post:          db "post", 0
section .text
