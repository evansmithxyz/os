; ==============================================================================
; Antigravity OS - CSS: style sheets, selectors and the cascade
; ------------------------------------------------------------------------------
; css_parse turns style sheet text into rules at CSS_ADDR: each rule is one
; selector (up to CSS_MAX_COMPOUNDS compound selectors joined by descendant or
; child combinators) plus a range of declarations. Rules are kept in hash
; buckets by the rightmost compound's id, first class or tag, so an element
; only looks at rules that can match it.
;
; css_compute gives every element of the DOM its style (the S_* fields):
; inherited values from the parent, then matching rules in cascade order
; (browser defaults < author rules, by specificity and source order,
; !important last, style="" above normal author rules).
;
; Supported: type, .class, #id, *, :root, descendant and child combinators;
; @media (screen/all, min-width, max-width, prefers-color-scheme, ...),
; @supports and @layer contents. Rules that use anything else (attribute
; selectors, +, ~, most pseudo-classes, pseudo-elements) never match.
; Properties: display, visibility, color, background(-color), font-weight,
; font-style, text-decoration, text-align, white-space, list-style(-type),
; text-transform, margin(-left/-top/-bottom), padding(-left). Lengths are
; halved (the 8-pixel font is half the size a style sheet expects).
; var(), inherit and friends are ignored.
; ==============================================================================

[bits 64]

; computed style fields in each DOM node
S_DISPLAY               equ 88      ; db DISP_*
S_WS                    equ 89      ; db WS_*
S_ALIGN                 equ 90      ; db ALIGN_*
S_BOLD                  equ 91      ; db
S_UNDER                 equ 92      ; db
S_VIS                   equ 93      ; db 1 = hidden
S_LIST                  equ 94      ; db LIST_*
S_TRANSFORM             equ 95      ; db 0, 1 upper, 2 lower
S_COLOR                 equ 96      ; dd 0x00RRGGBB
S_BG                    equ 100     ; dd 0x00RRGGBB, or CSS_TRANSPARENT
S_ML                    equ 104     ; dw margin-left (pixels, signed)
S_MT                    equ 106     ; dw margin-top
S_MB                    equ 108     ; dw margin-bottom
S_PL                    equ 110     ; dw padding-left
S_ITALIC                equ 112     ; db
; not inherited, only used to spot content hidden by layout tricks
S_POS                   equ 113     ; db 1 = position absolute / fixed
S_TINY                  equ 114     ; db width or height of at most 1px, or clipped away
S_H0                    equ 115     ; db height: 0
S_OVH                   equ 116     ; db overflow: hidden / clip
S_OFF                   equ 117     ; db left or top far off screen

DISP_INLINE             equ 0
DISP_BLOCK              equ 1
DISP_NONE               equ 2
DISP_LIST_ITEM          equ 3
DISP_TABLE              equ 4
DISP_ROW                equ 5
DISP_CELL               equ 6

WS_NORMAL               equ 0
WS_PRE                  equ 1
WS_NOWRAP               equ 2

ALIGN_LEFT              equ 0
ALIGN_CENTER            equ 1
ALIGN_RIGHT             equ 2

LIST_DISC               equ 0
LIST_NONE               equ 1
LIST_DECIMAL            equ 2

CSS_TRANSPARENT         equ 0x80000000

; properties
P_DISPLAY               equ 1
P_VISIBILITY            equ 2
P_COLOR                 equ 3
P_BG                    equ 4
P_BOLD                  equ 5
P_ITALIC                equ 6
P_UNDER                 equ 7
P_ALIGN                 equ 8
P_WS                    equ 9
P_LIST                  equ 10
P_TRANSFORM             equ 11
P_ML                    equ 12
P_MT                    equ 13
P_MB                    equ 14
P_PL                    equ 15
P_POS                   equ 16
P_TINY                  equ 17
P_H0                    equ 18
P_OVH                   equ 19
P_OFF                   equ 20

; CSS region
CSS_TEXT                equ CSS_ADDR                ; copied style sheets
CSS_TEXT_SIZE           equ 0x000C0000
CSS_RULES               equ CSS_ADDR + 0x000C0000   ; rule records
CSS_RULE_SIZE           equ 168
CSS_MAX_RULES           equ 0x00100000 / CSS_RULE_SIZE
CSS_DECLS               equ CSS_ADDR + 0x001C0000   ; declarations
CSS_DECL_SIZE           equ 8
CSS_MAX_DECLS           equ 0x00040000 / CSS_DECL_SIZE

; rule record
R_NEXT                  equ 0       ; dd next rule in the bucket (index + 1)
R_SPEC                  equ 4       ; dd specificity (+ origin in bits 24+)
R_ORDER                 equ 8       ; dd source order
R_DECL                  equ 12      ; dd first declaration
R_NDECL                 equ 16      ; dw
R_NCOMP                 equ 18      ; db
R_COMP                  equ 24      ; compounds, rightmost first
CSS_MAX_COMPOUNDS       equ 3
; compound selector (48 bytes)
C_TAG                   equ 0       ; dd tag hash, 0 = any
C_ID                    equ 4       ; dd id hash, 0 = none
C_NCLS                  equ 8       ; db
C_COMB                  equ 9       ; db how the next compound (to the left) relates
C_FLAGS                 equ 10      ; db CF_*
C_NNOT                  equ 11      ; db
C_CLS                   equ 12      ; 7 x dd class hashes
C_MAX_CLASSES           equ 7
C_NOT                   equ 40      ; 2 x dd :not(.class) hashes
C_MAX_NOTS              equ 2
C_SIZE                  equ 48
COMB_DESCENDANT         equ 1
COMB_CHILD              equ 2
CF_ROOT                 equ 1
CF_FIRST                equ 2       ; :first-child
CF_LAST                 equ 4       ; :last-child

; declaration record
D_PROP                  equ 0       ; db P_*
D_IMPORTANT             equ 1       ; db
D_VALUE                 equ 4       ; dd

CSS_BUCKETS             equ 1024
CSS_ORIGIN_AUTHOR       equ 0x01000000
CSS_MAX_MATCHES         equ 128

section .data
align 4
css_text_used:          dd 0
css_rule_count:         dd 0
css_decl_count:         dd 0
css_order:              dd 0
css_origin:             dd 0        ; 0 for the browser's sheet, CSS_ORIGIN_AUTHOR
css_viewport:           dd 1760     ; viewport width in CSS pixels, for @media

section .bss
alignb 16
css_buckets:            resd CSS_BUCKETS
css_universal:          resd 1      ; rules with no id, class or tag (index + 1)
css_matches:            resd CSS_MAX_MATCHES
css_match_count:        resd 1
css_inline_decls:       resb CSS_DECL_SIZE * 64
css_inline_count:       resd 1
css_sel:                resb CSS_RULE_SIZE      ; selector being parsed
css_sel_spec:           resd 1
css_bad:                resb 1      ; the selector uses something unsupported
css_sel_only:           resb 1          ; css_add_selector only compiles (css_compile_selector)
css_sel_ok:             resb 1
alignb 8
css_sel_out:            resq 1
css_decl_first:         resd 1
css_decl_n:             resd 1
css_values:             resd 4      ; lengths of a margin/padding shorthand
css_value_count:        resd 1
css_important:          resb 1

section .text
; ==============================================================================
; Style sheet text
; ==============================================================================

; ------------------------------------------------------------------------------
; css_reset: forget every rule (a new page). The browser's own sheet is parsed
; again by the caller.
; ------------------------------------------------------------------------------
css_reset:
    push rax
    push rcx
    push rdi
    xor eax, eax
    mov [css_text_used], eax
    mov [css_rule_count], eax
    mov [css_decl_count], eax
    mov [css_order], eax
    mov [css_universal], eax
    lea rdi, [css_buckets]
    mov ecx, CSS_BUCKETS
    rep stosd
    pop rdi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; css_keep_text: RSI = text, RCX = length -> copied into the CSS text area
; (external sheets arrive in http_resp_buf, which the next fetch reuses).
; Output: RSI = the copy, RCX = its length (cut to what fits)
; ------------------------------------------------------------------------------
css_keep_text:
    push rax
    push rdi
    mov eax, CSS_TEXT_SIZE
    sub eax, [css_text_used]
    cmp rcx, rax
    jbe .fits
    mov ecx, eax
.fits:
    lea rdi, [abs CSS_TEXT]
    mov eax, [css_text_used]
    add rdi, rax
    add [css_text_used], ecx
    push rdi
    push rcx
    rep movsb
    pop rcx
    pop rsi
    pop rdi
    pop rax
    ret

; ------------------------------------------------------------------------------
; css_parse: RSI = style sheet text, RCX = length (must stay in memory: the
; rules do not copy it). css_origin says whose sheet it is.
; ------------------------------------------------------------------------------
css_parse:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    mov r12, rsi                    ; R12 = position
    lea r13, [rsi + rcx]            ; R13 = end
.block:
    call css_parse_block            ; returns early after a stray '}'
    cmp r12, r13
    jb .block
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; css_parse_block: rules from R12 until a '}' at this level (consumed) or R13
css_parse_block:
.next:
    call css_skip_ws
    cmp r12, r13
    jae .ret
    mov al, [r12]
    cmp al, '}'
    je .close
    cmp al, '@'
    je .at_rule
    cmp al, '<'                     ; "<!--" / "-->" in old <style> blocks
    je .html_comment
    cmp al, '-'
    jne .rule
    cmp word [r12 + 1], '->'
    je .html_comment
.rule:
    call css_rule_set
    jmp .next
.html_comment:
    inc r12
    jmp .next
.close:
    inc r12
.ret:
    ret
.at_rule:
    inc r12
    mov rsi, r12
    call css_ident                  ; RSI, ECX = name
    mov r12, rsi
    add r12, rcx
    ; the prelude, up to '{' or ';'
    mov rdi, r12
.prelude:
    cmp r12, r13
    jae .ret
    mov al, [r12]
    cmp al, ';'
    je .statement
    cmp al, '{'
    je .block
    inc r12
    jmp .prelude
.statement:
    inc r12                         ; @import, @charset, @namespace: ignored
    jmp .next
.block:
    ; RSI/ECX = at-rule name, RDI .. R12 = prelude
    mov rbx, rdi                    ; RBX = prelude
    lea rdi, [css_at_media]
    call css_ident_is
    je .media
    lea rdi, [css_at_supports]
    call css_ident_is
    je .nested
    lea rdi, [css_at_layer]
    call css_ident_is
    je .nested
    call css_skip_block             ; @font-face, @keyframes, @page, ...
    jmp .next
.media:
    mov rsi, rbx
    mov rcx, r12
    sub rcx, rbx
    call css_media_ok
    jnc .nested
    call css_skip_block
    jmp .next
.nested:
    inc r12                         ; past '{'
    call css_parse_block
    jmp .next

; ------------------------------------------------------------------------------
; css_rule_set: R12 = at a selector list -> its rules; R12 past its '}'
; ------------------------------------------------------------------------------
css_rule_set:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, r12                     ; R8 = start of the selector list
.to_brace:
    cmp r12, r13
    jae .done
    mov al, [r12]
    cmp al, '{'
    je .brace
    cmp al, '}'
    je .stray                       ; "}" without a block: skip it
    inc r12
    jmp .to_brace
.stray:
    inc r12
    jmp .done
.brace:
    mov rdi, r12                    ; RDI = end of the selector list
    inc r12
    ; the declarations first (every selector of the list shares them)
    mov eax, [css_decl_count]
    mov [css_decl_first], eax
    call css_declarations           ; up to and past '}'
    mov eax, [css_decl_count]
    sub eax, [css_decl_first]
    mov [css_decl_n], eax
    jz .done                        ; nothing we understand
    ; then each selector, split at top-level commas
    mov rsi, r8
.selector:
    cmp rsi, rdi
    jae .done
    mov rcx, rsi
    xor eax, eax                    ; parenthesis depth
.to_comma:
    cmp rcx, rdi
    jae .have_selector
    mov dl, [rcx]
    cmp dl, '('
    jne .not_open
    inc eax
.not_open:
    cmp dl, ')'
    jne .not_close
    dec eax
.not_close:
    cmp dl, ','
    jne .next_char
    test eax, eax
    jz .have_selector
.next_char:
    inc rcx
    jmp .to_comma
.have_selector:
    push rcx
    sub rcx, rsi
    call css_add_selector           ; RSI, RCX = one selector
    pop rsi
    inc rsi                         ; past the comma
    jmp .selector
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; css_declarations: R12 = after '{' -> declarations appended; R12 past '}'
; ------------------------------------------------------------------------------
css_declarations:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
.next:
    call css_skip_ws
    cmp r12, r13
    jae .done
    mov al, [r12]
    cmp al, '}'
    je .end
    cmp al, ';'
    je .skip_one
    ; property name
    mov rsi, r12
    call css_ident
    test ecx, ecx
    jz .skip_decl
    add r12, rcx
    push rsi
    push rcx
    call css_skip_ws
    pop rcx
    pop rsi
    cmp r12, r13
    jae .done
    cmp byte [r12], ':'
    jne .skip_decl
    inc r12
    call css_skip_ws
    ; value: up to ';' or '}' outside parentheses and quotes
    mov rdi, r12
    xor edx, edx
.value:
    cmp r12, r13
    jae .have_value
    mov al, [r12]
    cmp al, '{'
    je .nested                      ; "a:hover {": a nested rule, not a value
    cmp al, '('
    jne .v1
    inc edx
.v1:
    cmp al, ')'
    jne .v2
    dec edx
.v2:
    test edx, edx
    jnz .v_next
    cmp al, ';'
    je .have_value
    cmp al, '}'
    je .have_value
.v_next:
    inc r12
    jmp .value
.have_value:
    ; RSI/ECX = name, RDI .. R12 = value
    push r12
    mov rdx, r12
    sub rdx, rdi                    ; RDX = value length
    call css_declaration
    pop r12
    jmp .next
.skip_decl:
    ; to the next ';' or '}'
    cmp r12, r13
    jae .done
    mov al, [r12]
    cmp al, ';'
    je .skip_one
    cmp al, '}'
    je .end
    cmp al, '{'
    je .nested
    inc r12
    jmp .skip_decl
.nested:
    ; CSS nesting (".a { .b { ... } }"): the inner rule is skipped whole
    call css_skip_block
    jmp .next
.skip_one:
    inc r12
    jmp .next
.end:
    inc r12
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; css_declaration: RSI/ECX = property name, RDI/RDX = value -> declarations
; ------------------------------------------------------------------------------
css_declaration:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    ; trim trailing spaces and "!important"
    mov byte [css_important], 0
    call .trim
    cmp edx, 10
    jb .no_important
    lea r8, [rdi + rdx - 10]
    cmp byte [r8], '!'
    jne .no_important
    push rsi
    push rdi
    push rcx
    lea rsi, [r8 + 1]
    lea rdi, [css_kw_important]
    mov ecx, 9
    call css_ci_equal
    pop rcx
    pop rdi
    pop rsi
    jne .no_important
    mov byte [css_important], 1
    sub edx, 10
    call .trim
.no_important:
    test edx, edx
    jz .done
    ; values we do not follow
    push rsi
    push rcx
    mov rsi, rdi
    mov ecx, edx
    lea rdi, [css_kw_var]
    call css_contains_ci
    mov rdi, rsi
    pop rcx
    pop rsi
    je .done
    ; which property
    lea rbx, [css_props]
.find:
    movzx eax, byte [rbx]           ; name length
    test eax, eax
    jz .done
    cmp eax, ecx
    jne .next_prop
    push rdi
    push rcx
    lea rdi, [rbx + 1]
    call css_ci_equal
    pop rcx
    pop rdi
    je .found
.next_prop:
    lea rbx, [rbx + rax + 3]
    jmp .find
.found:
    movzx r8d, byte [rbx + rax + 1] ; R8 = handler kind
    movzx eax, byte [rbx + rax + 2] ; EAX = property id
    mov rsi, rdi                    ; RSI, EDX = value
    cmp r8d, K_KEYWORD
    je .keyword
    cmp r8d, K_COLOR
    je .color
    cmp r8d, K_LENGTH
    je .length
    cmp r8d, K_BACKGROUND
    je .background
    cmp r8d, K_BOX
    je .box
    cmp r8d, K_FONT
    je .font
    cmp r8d, K_SIZE
    je .size
    cmp r8d, K_CLIP
    je .clip
    cmp r8d, K_OPACITY
    je .opacity
    cmp r8d, K_OFFSET
    je .offset
    jmp .done
.size:
    ; width / height / max-height of at most 1px: "tiny" (and height 0)
    mov cl, [rsi]
    or cl, 0x20
    cmp cl, 'a'                     ; auto
    je .done
    call css_length
    jc .done
    test ecx, ecx
    jg .done
    push rax
    mov eax, P_TINY
    mov ecx, 1
    call css_emit
    pop rax
    cmp eax, P_H0                   ; heights also count as height: 0
    jne .done
    call css_emit
    jmp .done
.clip:
    ; clip: rect(...) / clip-path: inset(...) cut the box away
    push rdi
    push rcx
    mov ecx, edx
    lea rdi, [css_kw_rect]
    call css_contains_ci
    je .clipped
    lea rdi, [css_kw_inset]
    call css_contains_ci
.clipped:
    pop rcx
    pop rdi
    jne .done
    mov eax, P_TINY
    mov ecx, 1
    call css_emit
    jmp .done
.opacity:
    ; opacity: 0 is as good as visibility: hidden
    cmp byte [rsi], '0'
    jne .done
    cmp edx, 1
    je .transparent
    cmp byte [rsi + 1], '.'
    jne .done
    cmp edx, 3
    jb .transparent
    cmp byte [rsi + 2], '0'
    jne .done
.transparent:
    mov eax, P_VISIBILITY
    mov ecx, 1
    call css_emit
    jmp .done
.offset:
    ; left / top far off screen (the "move it out of view" trick)
    call css_length
    jc .done
    cmp ecx, -250
    jg .done
    mov eax, P_OFF
    mov ecx, 1
    call css_emit
    jmp .done
.keyword:
    call css_keyword                ; EAX = property -> ECX = value, CF
    jc .done
    call css_emit
    jmp .done
.color:
    call css_color
    jc .done
    call css_emit
    jmp .done
.length:
    call css_length
    jc .done
    call css_emit
    jmp .done
.background:
    ; the first thing in it that is a colour ("none" = transparent)
    call css_background
    jc .done
    mov eax, P_BG
    call css_emit
    jmp .done
.box:
    ; margin / padding shorthand: EAX = P_ML (margin) or P_PL (padding)
    call css_box
    jmp .done
.font:
    ; font shorthand: only "bold"
    push rdi
    push rcx
    mov ecx, edx
    lea rdi, [css_kw_bold]
    call css_contains_ci
    pop rcx
    pop rdi
    jne .done
    mov eax, P_BOLD
    mov ecx, 1
    call css_emit
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
; .trim: drop spaces at the end of RDI/EDX
.trim:
    test edx, edx
    jz .trim_ret
    cmp byte [rdi + rdx - 1], ' '
    ja .trim_ret
    dec edx
    jmp .trim
.trim_ret:
    ret

; css_emit: EAX = property, ECX = value -> a declaration (css_important)
css_emit:
    push rax
    push rbx
    mov ebx, [css_decl_count]
    cmp ebx, CSS_MAX_DECLS
    jae .full
    inc dword [css_decl_count]
    shl rbx, 3
    add rbx, CSS_DECLS
    mov [rbx + D_PROP], al
    mov al, [css_important]
    mov [rbx + D_IMPORTANT], al
    mov [rbx + D_VALUE], ecx
.full:
    pop rbx
    pop rax
    ret

; ==============================================================================
; Values
; ==============================================================================

; ------------------------------------------------------------------------------
; css_keyword: EAX = property, RSI/EDX = value -> ECX = its code; CF=1 if the
; value is not one we know for that property
; ------------------------------------------------------------------------------
css_keyword:
    push rax
    push rbx
    push rdi
    ; table: db property, db value code, db length, name
    lea rbx, [css_keywords]
.entry:
    movzx ecx, byte [rbx + 2]
    cmp byte [rbx], 0
    je .unknown
    cmp [rbx], al
    jne .next
    cmp ecx, edx
    jne .next
    lea rdi, [rbx + 3]
    push rcx
    call css_ci_equal
    pop rcx
    je .found
.next:
    lea rbx, [rbx + rcx + 3]
    jmp .entry
.found:
    movzx ecx, byte [rbx + 1]
    pop rdi
    pop rbx
    pop rax
    clc
    ret
.unknown:
    ; font-weight numbers: 600+ is bold
    cmp al, P_BOLD
    jne .fail
    cmp edx, 3
    jne .fail
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .fail
    cmp ecx, 6
    setae cl
    movzx ecx, cl
    pop rdi
    pop rbx
    pop rax
    clc
    ret
.fail:
    pop rdi
    pop rbx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; css_length: RSI/EDX = a length -> ECX = pixels for our half-size font
; (px / 2, em and rem x 8, 0, auto = 0); CF=1 for others (%, calc(), ...)
; ------------------------------------------------------------------------------
css_length:
    push rax
    push rbx
    push rdx
    push rsi
    push rdi
    ; "auto"
    cmp edx, 4
    jne .number
    push rcx
    lea rdi, [css_kw_auto]
    mov ecx, 4
    call css_ci_equal
    pop rcx
    je .zero
.number:
    ; [-]digits[.digits] in tenths
    lea rdi, [rsi + rdx]            ; RDI = end
    xor eax, eax                    ; value * 10
    xor ebx, ebx                    ; 1 = negative
    cmp rsi, rdi
    jae .fail
    cmp byte [rsi], '-'
    jne .digits
    inc ebx
    inc rsi
.digits:
    xor ecx, ecx                    ; digits seen
.int:
    cmp rsi, rdi
    jae .unit
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .fraction
    imul eax, eax, 10
    add eax, edx
    inc ecx
    inc rsi
    jmp .int
.fraction:
    imul eax, eax, 10               ; tenths
    cmp byte [rsi], '.'
    jne .unit_tenths
    inc rsi
    cmp rsi, rdi
    jae .unit_tenths
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .unit_tenths
    add eax, edx
    inc ecx
.skip_digits:
    inc rsi
    cmp rsi, rdi
    jae .unit_tenths
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    jbe .skip_digits
    jmp .unit_tenths
.unit:
    imul eax, eax, 10
.unit_tenths:
    test ecx, ecx
    jz .fail
    ; unit
    mov rdx, rdi
    sub rdx, rsi                    ; EDX = unit length
    jz .unitless
    cmp edx, 2
    jne .rem
    mov dx, [rsi]
    or dx, 0x2020
    cmp dx, 'px'
    je .px
    cmp dx, 'pt'
    je .px                          ; close enough
    cmp dx, 'em'
    je .em
    cmp dx, 'ex'
    je .px
    cmp dx, 'ch'
    je .em
    jmp .fail
.rem:
    cmp edx, 3
    jne .fail
    mov edx, [rsi]
    and edx, 0x00FFFFFF
    or edx, 0x00202020
    cmp edx, 'rem'
    je .em
    jmp .fail
.unitless:
    test eax, eax                   ; only 0 may leave out the unit
    jnz .fail
.zero:
    xor ecx, ecx
    jmp .ok
.px:
    ; px / 2, from tenths: / 20
    xor edx, edx
    mov ecx, 20
    div ecx
    mov ecx, eax
    jmp .sign
.em:
    ; 1em = 16px = 8 of ours: tenths * 8 / 10
    imul eax, eax, 8
    xor edx, edx
    mov ecx, 10
    div ecx
    mov ecx, eax
.sign:
    cmp ecx, 400
    jbe .signed
    mov ecx, 400
.signed:
    test ebx, ebx
    jz .ok
    neg ecx
.ok:
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    pop rax
    clc
    ret
.fail:
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; css_color: RSI/EDX = a colour -> ECX = 0x00RRGGBB (or CSS_TRANSPARENT);
; CF=1 if it is not one (hsl(), currentcolor, ...)
; ------------------------------------------------------------------------------
css_color:
    push rax
    push rbx
    push rdx
    push rsi
    push rdi
    push r8
    test edx, edx
    jz .fail
    cmp byte [rsi], '#'
    je .hex
    ; rgb( / rgba(
    cmp edx, 5
    jb .named
    mov eax, [rsi]
    or eax, 0x20202020
    cmp eax, 'rgb('
    je .rgb
    cmp eax, 'rgba'
    je .rgb
.named:
    lea rbx, [css_colors]
.color_entry:
    movzx ecx, byte [rbx]
    test ecx, ecx
    jz .fail
    cmp ecx, edx
    jne .color_next
    lea rdi, [rbx + 1]
    push rcx
    call css_ci_equal
    pop rcx
    je .color_found
.color_next:
    lea rbx, [rbx + rcx + 5]
    jmp .color_entry
.color_found:
    mov ecx, [rbx + rcx + 1]
    jmp .ok
.hex:
    inc rsi
    dec edx
    xor ecx, ecx                    ; value
    xor ebx, ebx                    ; digits
.hex_digit:
    cmp ebx, edx
    jae .hex_done
    movzx eax, byte [rsi + rbx]
    call css_hex_value
    jc .fail
    shl ecx, 4
    or ecx, eax
    inc ebx
    jmp .hex_digit
.hex_done:
    cmp edx, 6
    je .ok
    cmp edx, 8                      ; #rrggbbaa
    je .alpha8
    cmp edx, 3
    je .short
    cmp edx, 4                      ; #rgba
    jne .fail
    test ecx, 0xF
    jz .transparent
    shr ecx, 4
.short:
    ; #rgb -> #rrggbb
    mov eax, ecx
    and eax, 0xF
    imul eax, eax, 0x11
    mov ebx, ecx
    shr ebx, 4
    and ebx, 0xF
    imul ebx, ebx, 0x1100
    or eax, ebx
    mov ebx, ecx
    shr ebx, 8
    and ebx, 0xF
    imul ebx, ebx, 0x110000
    or eax, ebx
    mov ecx, eax
    jmp .ok
.alpha8:
    test ecx, 0xFF
    jz .transparent
    shr ecx, 8
    jmp .ok
.rgb:
    ; three numbers (0-255 or %), then maybe an alpha
    add rsi, 4
    sub edx, 4
    cmp byte [rsi], '('
    jne .rgb_numbers
    inc rsi
    dec edx
.rgb_numbers:
    lea rdi, [rsi + rdx]
    xor ecx, ecx
    mov ebx, 3
.component:
    call .skip_sep
    call .number                    ; EAX = 0-255
    jc .fail
    shl ecx, 8
    or ecx, eax
    dec ebx
    jnz .component
    ; alpha 0 = transparent
    call .skip_sep
    cmp rsi, rdi
    jae .ok
    cmp byte [rsi], '0'
    jne .ok
    cmp byte [rsi + 1], '.'
    je .ok
    cmp byte [rsi + 1], '%'
    je .transparent
    cmp byte [rsi + 1], ')'
    je .transparent
    cmp byte [rsi + 1], ' '
    ja .ok
.transparent:
    mov ecx, CSS_TRANSPARENT
.ok:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    pop rax
    clc
    ret
.fail:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    pop rax
    stc
    ret
; .skip_sep: past spaces, commas and '/' (RSI up to RDI)
.skip_sep:
    cmp rsi, rdi
    jae .sep_ret
    mov al, [rsi]
    cmp al, ' '
    jbe .sep_skip
    cmp al, ','
    je .sep_skip
    cmp al, '/'
    jne .sep_ret
.sep_skip:
    inc rsi
    jmp .skip_sep
.sep_ret:
    ret
; .number: RSI = a number or percentage -> EAX = 0-255; CF=1 if none
.number:
    push rdx
    xor eax, eax
    xor edx, edx                    ; digits
.num_digit:
    cmp rsi, rdi
    jae .num_end
    movzx r8d, byte [rsi]
    sub r8d, '0'
    cmp r8d, 9
    ja .num_end
    imul eax, eax, 10
    add eax, r8d
    inc edx
    inc rsi
    jmp .num_digit
.num_end:
    ; skip a fraction
    cmp rsi, rdi
    jae .num_check
    cmp byte [rsi], '.'
    jne .num_percent
.num_frac:
    inc rsi
    cmp rsi, rdi
    jae .num_check
    movzx r8d, byte [rsi]
    sub r8d, '0'
    cmp r8d, 9
    jbe .num_frac
.num_percent:
    cmp rsi, rdi
    jae .num_check
    cmp byte [rsi], '%'
    jne .num_check
    inc rsi
    imul eax, eax, 255
    push rcx
    push rdx
    xor edx, edx
    mov ecx, 100
    div ecx
    pop rdx
    pop rcx
.num_check:
    test edx, edx
    jz .num_fail
    cmp eax, 255
    jbe .num_ok
    mov eax, 255
.num_ok:
    pop rdx
    clc
    ret
.num_fail:
    pop rdx
    stc
    ret

; css_hex_value: AL = hex digit -> EAX = 0-15; CF=1 if not one
css_hex_value:
    movzx eax, al
    sub eax, '0'
    cmp eax, 9
    jbe .ok
    or eax, 0x20                    ; letters, lower case
    sub eax, 'a' - '0'
    cmp eax, 5
    ja .bad
    add eax, 10
.ok:
    clc
    ret
.bad:
    stc
    ret

; css_background: RSI/EDX = background value -> ECX = its colour; CF=1 if none
css_background:
    push rax
    push rdx
    push rsi
    push rdi
    lea rdi, [rsi + rdx]
    ; "none" alone means no background colour
    cmp edx, 4
    jne .token
    push rdi
    push rcx
    lea rdi, [css_kw_none]
    mov ecx, 4
    call css_ci_equal
    pop rcx
    pop rdi
    jne .token
    mov ecx, CSS_TRANSPARENT
    jmp .ok
.token:
    ; each space-separated token (a function counts as one)
.skip:
    cmp rsi, rdi
    jae .fail
    cmp byte [rsi], ' '
    ja .start
    inc rsi
    jmp .skip
.start:
    mov rax, rsi
    xor edx, edx                    ; parenthesis depth
.scan:
    cmp rsi, rdi
    jae .have
    mov cl, [rsi]
    cmp cl, '('
    jne .s1
    inc edx
.s1:
    cmp cl, ')'
    jne .s2
    dec edx
.s2:
    test edx, edx
    jnz .s3
    cmp cl, ' '
    jbe .have
.s3:
    inc rsi
    jmp .scan
.have:
    push rsi
    mov rdx, rsi
    sub rdx, rax
    mov rsi, rax
    call css_color
    pop rsi
    jnc .ok
    jmp .skip
.ok:
    pop rdi
    pop rsi
    pop rdx
    pop rax
    clc
    ret
.fail:
    pop rdi
    pop rsi
    pop rdx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; css_box: EAX = P_ML (margin) or P_PL (padding), RSI/EDX = 1-4 lengths
; -> margin-top/bottom/left or padding-left declarations
; ------------------------------------------------------------------------------
css_box:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov ebx, eax
    lea rdi, [rsi + rdx]
    mov dword [css_value_count], 0
.token:
    cmp rsi, rdi
    jae .have_all
    cmp byte [rsi], ' '
    ja .start
    inc rsi
    jmp .token
.start:
    mov rax, rsi
.scan:
    cmp rsi, rdi
    jae .end_token
    cmp byte [rsi], ' '
    jbe .end_token
    inc rsi
    jmp .scan
.end_token:
    mov ecx, [css_value_count]
    cmp ecx, 4
    jae .have_all
    push rsi
    mov rdx, rsi
    sub rdx, rax
    mov rsi, rax
    push rcx
    call css_length
    mov eax, ecx
    pop rcx
    pop rsi
    jc .done                        ; one we cannot read: ignore it all
    mov [css_values + rcx * 4], eax
    inc dword [css_value_count]
    jmp .token
.have_all:
    ; top = v0, right = v1|v0, bottom = v2|v0, left = v3|v1|v0
    mov ecx, [css_value_count]
    test ecx, ecx
    jz .done
    mov eax, [css_values]           ; top
    mov edx, eax                    ; bottom
    mov esi, eax                    ; left
    cmp ecx, 2
    jb .emit
    mov esi, [css_values + 4]
    cmp ecx, 3
    jb .emit
    mov edx, [css_values + 8]
    cmp ecx, 4
    jb .emit
    mov esi, [css_values + 12]
.emit:
    cmp ebx, P_PL
    je .padding
    mov ecx, eax
    mov eax, P_MT
    call css_emit
    mov ecx, edx
    mov eax, P_MB
    call css_emit
    mov ecx, esi
    mov eax, P_ML
    call css_emit
    jmp .done
.padding:
    mov ecx, esi
    mov eax, P_PL
    call css_emit
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; css_media_ok: RSI/RCX = @media prelude -> CF=0 if it applies to our screen
; ------------------------------------------------------------------------------
css_media_ok:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    lea rdi, [rsi + rcx]            ; RDI = end
.query:
    ; one query of a comma list: true unless something in it is false
    mov r8d, 1                      ; R8 = this query's result
    xor ebx, ebx                    ; 1 = "not"
.word:
    cmp rsi, rdi
    jae .query_end
    mov al, [rsi]
    cmp al, ','
    je .query_end
    cmp al, ' '
    jbe .skip
    cmp al, '('
    je .feature
    ; a word: not / only / and / a media type
    call css_ident                  ; ECX = its length
    test ecx, ecx
    jz .skip
    push rdi
    lea rdi, [css_kw_not]
    call css_ident_is
    jne .not_not
    mov ebx, 1
    jmp .word_done
.not_not:
    lea rdi, [css_kw_and]
    call css_ident_is
    je .word_done
    lea rdi, [css_kw_only]
    call css_ident_is
    je .word_done
    lea rdi, [css_kw_screen]
    call css_ident_is
    je .word_done
    lea rdi, [css_kw_all]
    call css_ident_is
    je .word_done
    xor r8d, r8d                    ; print, speech, anything else
.word_done:
    pop rdi
    add rsi, rcx
    jmp .word
.skip:
    inc rsi
    jmp .word
.feature:
    ; (name: value)
    inc rsi
    call css_media_feature          ; RSI -> past ')', EAX = 1/0
    and r8d, eax
    jmp .word
.query_end:
    xor r8d, ebx                    ; "not" flips it
    test r8d, r8d
    jnz .yes
    cmp rsi, rdi
    jae .no
    inc rsi                         ; past ','
    jmp .query
.yes:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret
.no:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret

; css_media_feature: RSI = after '(' (RDI = end) -> EAX = 1 if the feature
; holds for us, RSI past ')'
css_media_feature:
    push rbx
    push rcx
    push rdx
    push r9
.lead:
    cmp rsi, rdi
    jae .false
    cmp byte [rsi], ' '
    ja .name
    inc rsi
    jmp .lead
.name:
    call css_ident                  ; RSI, ECX
    mov r9, rsi
    lea rsi, [rsi + rcx]
.to_value:
    cmp rsi, rdi
    jae .false
    mov al, [rsi]
    cmp al, ')'
    je .no_value
    cmp al, ':'
    je .value
    inc rsi
    jmp .to_value
.no_value:
    ; (color), (hover), (grid)...: true
    inc rsi
    mov eax, 1
    jmp .ret
.value:
    inc rsi
.value_lead:
    cmp rsi, rdi
    jae .false
    cmp byte [rsi], ' '
    ja .value_start
    inc rsi
    jmp .value_lead
.value_start:
    mov rdx, rsi
.value_end:
    cmp rsi, rdi
    jae .have_value
    cmp byte [rsi], ')'
    je .have_value
    inc rsi
    jmp .value_end
.have_value:
    ; R9/ECX = name, RDX .. RSI = value
    push rsi
    mov rbx, rsi
    sub rbx, rdx                    ; value length
    xchg rsi, r9
    ; min-width / max-width
    push rdi
    lea rdi, [css_kw_min_width]
    call css_ident_is
    je .min_width
    lea rdi, [css_kw_max_width]
    call css_ident_is
    je .max_width
    lea rdi, [css_kw_color_scheme]
    call css_ident_is
    je .scheme
    lea rdi, [css_kw_reduced_motion]
    call css_ident_is
    je .false_value
    ; orientation, hover, pointer, any-hover...: true
    pop rdi
    mov eax, 1
    jmp .close
.min_width:
    call .value_px
    jc .false_value
    cmp [css_viewport], eax
    setge al
    jmp .bool
.max_width:
    call .value_px
    jc .false_value
    cmp [css_viewport], eax
    setle al
    jmp .bool
.scheme:
    ; light, not dark
    mov eax, [rdx]
    or eax, 0x20202020
    cmp eax, 'ligh'
    sete al
.bool:
    movzx eax, al
    pop rdi
    jmp .close
.false_value:
    pop rdi
    xor eax, eax
.close:
    pop rsi
    cmp rsi, rdi
    jae .ret
    inc rsi                         ; past ')'
    jmp .ret
.false:
    xor eax, eax
.ret:
    pop r9
    pop rdx
    pop rcx
    pop rbx
    ret
; .value_px: RDX/RBX = "Npx" or "Nem" -> EAX = CSS pixels; CF=1 otherwise
.value_px:
    push rcx
    push rsi
    push rdx
    mov rsi, rdx
    mov edx, ebx
    call css_length                 ; our pixels = CSS px / 2 (em: x 8)
    jc .vp_fail
    lea eax, [ecx * 2]
    pop rdx
    pop rsi
    pop rcx
    clc
    ret
.vp_fail:
    pop rdx
    pop rsi
    pop rcx
    stc
    ret

; ==============================================================================
; Selectors
; ==============================================================================

; ------------------------------------------------------------------------------
; css_add_selector: RSI/RCX = one selector -> a rule with the current
; declarations (css_decl_first, css_decl_n), unless it uses something we do
; not support
; ------------------------------------------------------------------------------
css_add_selector:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    ; parse left to right into css_sel with the compounds in written order,
    ; then store them reversed
    lea rdi, [css_sel]
    push rcx
    push rdi
    xor eax, eax
    mov ecx, CSS_RULE_SIZE / 8
    rep stosq
    pop rdi
    pop rcx
    mov byte [css_bad], 0
    mov dword [css_sel_spec], 0
    lea r9, [rsi + rcx]             ; R9 = end
    xor r8d, r8d                    ; R8 = compounds so far
    xor r10d, r10d                  ; R10 = combinator before the next compound
.lead:
    cmp rsi, r9
    jae .finish
    mov al, [rsi]
    cmp al, ' '
    jbe .space
    cmp al, '>'
    je .child
    cmp al, '+'
    je .bad
    cmp al, '~'
    je .bad
    ; a compound selector
    cmp r8d, CSS_MAX_COMPOUNDS
    jae .bad
    mov rax, r8
    imul rax, rax, C_SIZE
    lea rbx, [css_sel + R_COMP + rax]
    test r8d, r8d
    jz .first
    test r10d, r10d
    jnz .comb_set
    mov r10d, COMB_DESCENDANT
.comb_set:
    ; C_COMB of a compound: how the compound to its left relates to it
    mov [rbx + C_COMB], r10b
.first:
    xor r10d, r10d
    call css_compound               ; RSI -> after it
    cmp byte [css_bad], 0
    jne .bad
    inc r8d
    jmp .lead
.space:
    inc rsi
    jmp .lead
.child:
    mov r10d, COMB_CHILD
    inc rsi
    jmp .lead
.finish:
    test r8d, r8d
    jz .bad
    cmp byte [css_sel_only], 0
    je .new_rule
    mov rdi, [css_sel_out]          ; css_compile_selector: just the record
    jmp .fill
.new_rule:
    mov eax, [css_rule_count]
    cmp eax, CSS_MAX_RULES
    jae .bad
    inc dword [css_rule_count]
    mov edx, eax                    ; EDX = rule index
    imul rax, rax, CSS_RULE_SIZE
    lea rdi, [abs CSS_RULES]
    add rdi, rax                    ; RDI = rule
.fill:
    mov eax, [css_sel_spec]
    add eax, [css_origin]
    mov [rdi + R_SPEC], eax
    mov eax, [css_order]
    inc dword [css_order]
    mov [rdi + R_ORDER], eax
    mov eax, [css_decl_first]
    mov [rdi + R_DECL], eax
    mov eax, [css_decl_n]
    mov [rdi + R_NDECL], ax
    mov [rdi + R_NCOMP], r8b
    ; compounds reversed, rightmost first. C_COMB (how the left neighbour
    ; relates) stays with its compound; the leftmost one has none.
    xor ecx, ecx
.copy:
    mov rax, r8
    sub rax, rcx
    dec rax                         ; written index, from the right
    imul rax, rax, C_SIZE
    lea rsi, [css_sel + R_COMP + rax]
    mov rax, rcx
    imul rax, rax, C_SIZE
    lea rbx, [rdi + R_COMP + rax]
    push rcx
    push rdi
    mov rdi, rbx
    mov ecx, C_SIZE
    rep movsb
    pop rdi
    pop rcx
    inc ecx
    cmp ecx, r8d
    jb .copy
    cmp byte [css_sel_only], 0
    je .file
    mov byte [css_sel_ok], 1
    jmp .done
.file:
    ; into its bucket: id, else first class, else tag, else universal
    mov eax, [rdi + R_COMP + C_ID]
    test eax, eax
    jnz .bucket
    cmp byte [rdi + R_COMP + C_NCLS], 0
    je .by_tag
    mov eax, [rdi + R_COMP + C_CLS]
    jmp .bucket
.by_tag:
    mov eax, [rdi + R_COMP + C_TAG]
    test eax, eax
    jnz .bucket
    mov eax, [css_universal]
    mov [rdi + R_NEXT], eax
    lea eax, [edx + 1]
    mov [css_universal], eax
    jmp .done
.bucket:
    and eax, CSS_BUCKETS - 1
    lea rbx, [css_buckets]
    mov ecx, [rbx + rax * 4]
    mov [rdi + R_NEXT], ecx
    lea ecx, [edx + 1]
    mov [rbx + rax * 4], ecx
    jmp .done
.bad:
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
; css_compound: RSI = at a compound selector (R9 = end), RBX = its record
; -> filled in, RSI after it; css_bad set for what we do not support
; ------------------------------------------------------------------------------
css_compound:
    push rax
    push rcx
    push rdx
.part:
    cmp rsi, r9
    jae .done
    mov al, [rsi]
    cmp al, ' '
    jbe .done
    cmp al, '>'
    je .done
    cmp al, '+'
    je .done
    cmp al, '~'
    je .done
    cmp al, '*'
    je .star
    cmp al, '#'
    je .id
    cmp al, '.'
    je .class
    cmp al, ':'
    je .pseudo
    cmp al, '['
    je .bad
    ; a type selector
    call css_ident
    test ecx, ecx
    jz .bad
    call dom_hash
    mov [rbx + C_TAG], eax
    add rsi, rcx
    inc dword [css_sel_spec]
    jmp .part
.star:
    inc rsi
    jmp .part
.id:
    inc rsi
    call css_ident
    test ecx, ecx
    jz .bad
    call css_hash_exact
    mov [rbx + C_ID], eax
    add rsi, rcx
    add dword [css_sel_spec], 0x10000
    jmp .part
.class:
    inc rsi
    call css_ident
    test ecx, ecx
    jz .bad
    movzx eax, byte [rbx + C_NCLS]
    cmp eax, C_MAX_CLASSES
    jae .bad
    push rax
    call css_hash_exact
    mov edx, eax
    pop rax
    mov [rbx + C_CLS + rax * 4], edx
    inc byte [rbx + C_NCLS]
    add rsi, rcx
    add dword [css_sel_spec], 0x100
    jmp .part
.pseudo:
    ; :root and :link are understood; ::x and the rest are not
    inc rsi
    cmp rsi, r9
    jae .bad
    cmp byte [rsi], ':'
    je .bad
    call css_ident
    push rdi
    lea rdi, [css_kw_root]
    call css_ident_is
    pop rdi
    jne .not_root
    or byte [rbx + C_FLAGS], CF_ROOT
    add rsi, rcx
    add dword [css_sel_spec], 0x100
    jmp .part
.not_root:
    push rdi
    lea rdi, [css_kw_link]
    call css_ident_is
    je .simple_pseudo
    lea rdi, [css_kw_first_child]
    call css_ident_is
    je .first
    lea rdi, [css_kw_last_child]
    call css_ident_is
    je .last
    lea rdi, [css_kw_only_child]
    call css_ident_is
    je .only
    lea rdi, [css_kw_not]
    call css_ident_is
    pop rdi
    jne .bad
    add rsi, rcx
    cmp byte [rsi], '('
    jne .bad
    inc rsi
    ; :not(:state) is always true here: nothing is hovered, focused or
    ; checked. :not(.class) is checked. Anything else is not supported.
    cmp byte [rsi], ':'
    je .not_state
    cmp byte [rsi], '.'
    jne .bad
    inc rsi
    call css_ident
    test ecx, ecx
    jz .bad
    cmp byte [rsi + rcx], ')'
    jne .bad
    movzx eax, byte [rbx + C_NNOT]
    cmp eax, C_MAX_NOTS
    jae .bad
    push rax
    call css_hash_exact
    mov edx, eax
    pop rax
    mov [rbx + C_NOT + rax * 4], edx
    inc byte [rbx + C_NNOT]
    lea rsi, [rsi + rcx + 1]
    add dword [css_sel_spec], 0x100
    jmp .part
.not_state:
    ; skip to the matching ')'
    xor eax, eax
.not_skip:
    cmp rsi, r9
    jae .bad
    mov dl, [rsi]
    inc rsi
    cmp dl, '('
    jne .not_close
    inc eax
.not_close:
    cmp dl, ')'
    jne .not_skip
    dec eax
    jns .not_skip
    jmp .part
.first:
    or byte [rbx + C_FLAGS], CF_FIRST
    jmp .simple_pseudo
.last:
    or byte [rbx + C_FLAGS], CF_LAST
    jmp .simple_pseudo
.only:
    or byte [rbx + C_FLAGS], CF_FIRST | CF_LAST
.simple_pseudo:
    pop rdi
    add rsi, rcx
    add dword [css_sel_spec], 0x100
    jmp .part
.bad:
    mov byte [css_bad], 1
.done:
    pop rdx
    pop rcx
    pop rax
    ret

; css_hash_exact: class and id names match case-sensitively in HTML, but
; dom_hash folds case. Using the same function on both sides keeps them equal.
css_hash_exact:
    jmp dom_hash

; ==============================================================================
; The cascade
; ==============================================================================

; ------------------------------------------------------------------------------
; css_compute: style every element of the DOM (in document order, which is
; node order, so parents are done before their children)
; ------------------------------------------------------------------------------
css_compute:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    ; the document: initial values
    xor eax, eax
    call dom_node
    mov byte [rbx + S_DISPLAY], DISP_BLOCK
    mov dword [rbx + S_COLOR], 0x000000
    mov dword [rbx + S_BG], CSS_TRANSPARENT
    ; a walk through the tree, parents before children (scripts can move
    ; nodes, so index order is not enough; detached nodes are skipped)
    mov r12d, [rbx + N_FIRST]
.node:
    test r12d, r12d
    jz .done
    mov eax, r12d
    call dom_node
    mov r13, rbx                    ; R13 = this node
    ; inherit from the parent
    mov eax, [r13 + N_PARENT]
    call dom_node                   ; RBX = parent
    mov al, [rbx + S_WS]
    mov [r13 + S_WS], al
    mov al, [rbx + S_ALIGN]
    mov [r13 + S_ALIGN], al
    mov al, [rbx + S_BOLD]
    mov [r13 + S_BOLD], al
    mov al, [rbx + S_UNDER]
    mov [r13 + S_UNDER], al
    mov al, [rbx + S_VIS]
    mov [r13 + S_VIS], al
    mov al, [rbx + S_LIST]
    mov [r13 + S_LIST], al
    mov al, [rbx + S_TRANSFORM]
    mov [r13 + S_TRANSFORM], al
    mov al, [rbx + S_ITALIC]
    mov [r13 + S_ITALIC], al
    mov eax, [rbx + S_COLOR]
    mov [r13 + S_COLOR], eax
    ; not inherited
    mov byte [r13 + S_DISPLAY], DISP_INLINE
    mov dword [r13 + S_BG], CSS_TRANSPARENT
    mov dword [r13 + S_ML], 0
    mov dword [r13 + S_MB], 0
    mov dword [r13 + S_POS], 0      ; S_POS, S_TINY, S_H0, S_OVH
    mov byte [r13 + S_OFF], 0
    ; a display:none parent hides everything inside
    cmp byte [rbx + S_DISPLAY], DISP_NONE
    je .none
    ; a closed <details> shows only its <summary> (text directly in it too)
    cmp byte [rbx + N_TAG], TAGID_DETAILS
    jne .element
    cmp byte [r13 + N_TAG], TAGID_SUMMARY
    je .element
    mov eax, [r13 + N_PARENT]
    lea rdi, [css_kw_open]
    call dom_attr
    jc .none
.element:
    cmp byte [r13 + N_TYPE], NODE_ELEMENT
    je .match
    jmp .next
.none:
    mov byte [r13 + S_DISPLAY], DISP_NONE
    jmp .next
.match:
    call css_presentational         ; bgcolor=, <font color=>, align=
    mov rbx, r13
    call css_match_element          ; css_matches, sorted
    call css_apply_matches          ; normal declarations
    call css_inline_style           ; style=""
    mov byte [css_apply_important], 1
    call css_apply_matches          ; !important
    call css_apply_inline
    mov byte [css_apply_important], 0
    ; hidden by layout tricks: absolutely positioned and tiny, clipped or off
    ; screen ("visually hidden" text for screen readers), or height 0 with
    ; the overflow cut off (closed menus)
    cmp byte [r13 + S_POS], 0
    je .collapsed
    cmp byte [r13 + S_TINY], 0
    jne .gone
    cmp byte [r13 + S_OFF], 0
    jne .gone
.collapsed:
    cmp byte [r13 + S_H0], 0
    je .attribute
    cmp byte [r13 + S_OVH], 0
    je .attribute
.gone:
    mov byte [r13 + S_DISPLAY], DISP_NONE
    jmp .next
.attribute:
    ; the hidden attribute
    mov eax, r12d
    lea rdi, [css_kw_hidden]
    call dom_attr
    jc .next
    mov byte [r13 + S_DISPLAY], DISP_NONE
.next:
    ; the next node in document order
    mov eax, [r13 + N_FIRST]
    test eax, eax
    jnz .go
.up:
    mov eax, [r13 + N_NEXT]
    test eax, eax
    jnz .go
    mov eax, [r13 + N_PARENT]
    test eax, eax
    jz .done
    call dom_node
    mov r13, rbx
    jmp .up
.go:
    mov r12d, eax
    jmp .node
.done:
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
; css_presentational: R12 = element index, R13 = its record. Old HTML styling
; attributes, below every style sheet rule: bgcolor="", color="" (on <font>),
; align="" (left / center / right)
; ------------------------------------------------------------------------------
css_presentational:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    ; the element may have no attributes at all
    cmp dword [r13 + N_ATTRS_LEN], 3
    jb .done
    mov eax, r12d
    lea rdi, [css_attr_bgcolor]
    call dom_attr
    jc .color
    mov edx, ecx
    call css_color
    jc .color
    mov [r13 + S_BG], ecx
.color:
    mov eax, r12d
    lea rdi, [css_attr_color]
    call dom_attr
    jc .align
    mov edx, ecx
    call css_color
    jc .align
    mov [r13 + S_COLOR], ecx
.align:
    mov eax, r12d
    lea rdi, [css_attr_align]
    call dom_attr
    jc .done
    mov edx, ecx
    mov eax, P_ALIGN
    call css_keyword
    jc .done
    mov [r13 + S_ALIGN], cl
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; css_match_element: RBX = element -> css_matches (rule indexes) in cascade
; order
; ------------------------------------------------------------------------------
css_match_element:
    push rax
    push rcx
    push rdx
    push rsi
    mov dword [css_match_count], 0
    mov eax, [css_universal]
    call .chain
    mov eax, [rbx + N_TAGH]
    call .bucket
    mov eax, [rbx + N_IDH]
    test eax, eax
    jz .classes
    call .bucket
.classes:
    xor ecx, ecx
.class:
    cmp cl, [rbx + N_NCLS]
    jae .sort
    mov eax, [rbx + N_CLSH + rcx * 4]
    call .bucket
    inc ecx
    jmp .class
.sort:
    call css_sort_matches
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
; .bucket: EAX = hash -> test the rules in its bucket
.bucket:
    and eax, CSS_BUCKETS - 1
    push rsi
    lea rsi, [css_buckets]
    mov eax, [rsi + rax * 4]
    pop rsi
; .chain: EAX = first rule + 1 -> test each rule of the chain
.chain:
    test eax, eax
    jz .chain_done
    dec eax
    push rax
    call css_rule_matches           ; EAX = rule, RBX = element -> CF=0 match
    pop rax
    jc .chain_next
    call css_add_match
.chain_next:
    push rbx
    imul rbx, rax, CSS_RULE_SIZE
    add rbx, CSS_RULES
    mov eax, [rbx + R_NEXT]
    pop rbx
    jmp .chain
.chain_done:
    ret

; css_add_match: EAX = rule -> css_matches (once)
css_add_match:
    push rcx
    push rdx
    push rsi
    lea rsi, [css_matches]
    mov ecx, [css_match_count]
    xor edx, edx
.dup:
    cmp edx, ecx
    jae .add
    cmp [rsi + rdx * 4], eax
    je .done
    inc edx
    jmp .dup
.add:
    cmp ecx, CSS_MAX_MATCHES
    jae .done
    mov [rsi + rcx * 4], eax
    inc dword [css_match_count]
.done:
    pop rsi
    pop rdx
    pop rcx
    ret

; css_sort_matches: css_matches by (specificity, order), insertion sort
css_sort_matches:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    lea rsi, [css_matches]
    mov ecx, 1
.outer:
    cmp ecx, [css_match_count]
    jae .done
    mov eax, [rsi + rcx * 4]        ; the one to insert
    call .key
    mov r8, rdx                     ; its key
    mov edi, ecx
.inner:
    test edi, edi
    jz .place
    mov r9d, [rsi + rdi * 4 - 4]
    push rax
    mov eax, r9d
    call .key
    pop rax
    cmp rdx, r8
    jbe .place
    mov [rsi + rdi * 4], r9d
    dec edi
    jmp .inner
.place:
    mov [rsi + rdi * 4], eax
    inc ecx
    jmp .outer
.done:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
; .key: EAX = rule -> RDX = specificity << 32 | order
.key:
    push rbx
    imul rbx, rax, CSS_RULE_SIZE
    add rbx, CSS_RULES
    mov edx, [rbx + R_SPEC]
    shl rdx, 32
    mov ebx, [rbx + R_ORDER]
    or rdx, rbx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; css_compile_selector: RSI/RCX = one selector, RDI = a CSS_RULE_SIZE record
; -> the compiled selector in it (querySelector); CF=1 if it uses something
; not supported
; ------------------------------------------------------------------------------
css_compile_selector:
    mov [css_sel_out], rdi
    mov byte [css_sel_only], 1
    mov byte [css_sel_ok], 0
    call css_add_selector
    mov byte [css_sel_only], 0
    cmp byte [css_sel_ok], 1
    jne .bad
    clc
    ret
.bad:
    stc
    ret

; ------------------------------------------------------------------------------
; css_rule_matches: EAX = rule, RBX = element -> CF=0 if the selector matches
; css_selector_matches: RSI = rule record, RBX = element -> the same
; ------------------------------------------------------------------------------
css_rule_matches:
    push rsi
    imul rsi, rax, CSS_RULE_SIZE
    add rsi, CSS_RULES              ; RSI = rule
    call css_selector_matches
    pop rsi
    ret

css_selector_matches:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    movzx r8d, byte [rsi + R_NCOMP]
    lea rdi, [rsi + R_COMP]         ; RDI = compound 0 (rightmost)
    mov rdx, rbx                    ; RDX = element being matched
    call css_compound_matches
    jc .no
    ; to the left
.left:
    dec r8d
    jz .yes
    movzx ecx, byte [rdi + C_COMB]
    add rdi, C_SIZE
    cmp ecx, COMB_CHILD
    je .parent
    ; descendant: the nearest ancestor that matches
.ancestor:
    mov eax, [rdx + N_PARENT]
    test eax, eax
    jz .no
    push rbx
    call dom_node
    mov rdx, rbx
    pop rbx
    call css_compound_matches
    jc .ancestor
    jmp .left
.parent:
    mov eax, [rdx + N_PARENT]
    test eax, eax
    jz .no
    push rbx
    call dom_node
    mov rdx, rbx
    pop rbx
    call css_compound_matches
    jc .no
    jmp .left
.yes:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.no:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; css_compound_matches: RDI = compound, RDX = element -> CF=0 if it matches
css_compound_matches:
    push rax
    push rcx
    push rsi
    mov eax, [rdi + C_TAG]
    test eax, eax
    jz .id
    cmp eax, [rdx + N_TAGH]
    jne .no
.id:
    mov eax, [rdi + C_ID]
    test eax, eax
    jz .classes
    cmp eax, [rdx + N_IDH]
    jne .no
.classes:
    xor ecx, ecx
.class:
    cmp cl, [rdi + C_NCLS]
    jae .flags
    mov eax, [rdi + C_CLS + rcx * 4]
    ; one of the element's classes
    xor esi, esi
.elem_class:
    cmp sil, [rdx + N_NCLS]
    jae .no
    cmp eax, [rdx + N_CLSH + rsi * 4]
    je .class_ok
    inc esi
    jmp .elem_class
.class_ok:
    inc ecx
    jmp .class
.flags:
    ; :not(.class): none of the element's classes
    xor ecx, ecx
.not_class:
    cmp cl, [rdi + C_NNOT]
    jae .root
    mov eax, [rdi + C_NOT + rcx * 4]
    xor esi, esi
.not_elem:
    cmp sil, [rdx + N_NCLS]
    jae .not_ok
    cmp eax, [rdx + N_CLSH + rsi * 4]
    je .no
    inc esi
    jmp .not_elem
.not_ok:
    inc ecx
    jmp .not_class
.root:
    test byte [rdi + C_FLAGS], CF_ROOT
    jz .first
    ; :root is the element whose parent is the document
    cmp dword [rdx + N_PARENT], 0
    jne .no
.first:
    test byte [rdi + C_FLAGS], CF_FIRST
    jz .last
    ; no element before it among its parent's children
    push rbx
    mov eax, [rdx + N_PARENT]
    call dom_node
    mov eax, [rbx + N_FIRST]
.first_scan:
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    je .first_found
    mov eax, [rbx + N_NEXT]
    test eax, eax
    jnz .first_scan
.first_found:
    cmp rbx, rdx
    pop rbx
    jne .no
.last:
    test byte [rdi + C_FLAGS], CF_LAST
    jz .yes
    ; no element after it
    push rbx
    mov eax, [rdx + N_NEXT]
.last_scan:
    test eax, eax
    jz .last_ok
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    je .last_fail
    mov eax, [rbx + N_NEXT]
    jmp .last_scan
.last_fail:
    pop rbx
    jmp .no
.last_ok:
    pop rbx
.yes:
    pop rsi
    pop rcx
    pop rax
    clc
    ret
.no:
    pop rsi
    pop rcx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; css_apply_matches: the declarations of css_matches onto R13 (normal ones, or
; only !important ones when css_apply_important is set)
; ------------------------------------------------------------------------------
css_apply_matches:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    xor ecx, ecx
.rule:
    cmp ecx, [css_match_count]
    jae .done
    lea rax, [css_matches]
    mov eax, [rax + rcx * 4]
    imul rbx, rax, CSS_RULE_SIZE
    add rbx, CSS_RULES
    mov eax, [rbx + R_DECL]
    movzx edx, word [rbx + R_NDECL]
    shl rax, 3
    lea rsi, [abs CSS_DECLS]
    add rsi, rax
.decl:
    test edx, edx
    jz .next_rule
    call css_apply_decl
    add rsi, CSS_DECL_SIZE
    dec edx
    jmp .decl
.next_rule:
    inc ecx
    jmp .rule
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; css_inline_style: R13's style="" -> css_inline_decls, applied (normal ones)
css_inline_style:
    push rax
    push rcx
    push rsi
    push r12
    push r13
    mov dword [css_inline_count], 0
    mov rsi, [r13 + N_STYLE]
    test rsi, rsi
    jz .done
    mov ecx, [r13 + N_STYLE_LEN]
    ; parse into the normal declaration area, then move them aside
    mov eax, [css_decl_count]
    push rax
    mov r12, rsi
    lea r13, [rsi + rcx]
    call css_declarations
    pop rax                         ; first new declaration
    mov ecx, [css_decl_count]
    mov [css_decl_count], eax       ; give the space back
    sub ecx, eax
    cmp ecx, 64
    jbe .count_ok
    mov ecx, 64
.count_ok:
    mov [css_inline_count], ecx
    shl rax, 3
    lea rsi, [abs CSS_DECLS]
    add rsi, rax
    push rdi
    lea rdi, [css_inline_decls]
    shl ecx, 3
    rep movsb
    pop rdi
.done:
    pop r13
    pop r12
    pop rsi
    pop rcx
    pop rax
    ; fall through: apply them
css_apply_inline:
    push rdx
    push rsi
    lea rsi, [css_inline_decls]
    mov edx, [css_inline_count]
.decl:
    test edx, edx
    jz .done
    call css_apply_decl
    add rsi, CSS_DECL_SIZE
    dec edx
    jmp .decl
.done:
    pop rsi
    pop rdx
    ret

; css_apply_decl: RSI = declaration -> R13's style (if its importance is the
; one being applied)
css_apply_decl:
    push rax
    push rcx
    mov al, [rsi + D_IMPORTANT]
    cmp al, [css_apply_important]
    jne .done
    mov ecx, [rsi + D_VALUE]
    movzx eax, byte [rsi + D_PROP]
    cmp eax, P_DISPLAY
    je .display
    cmp eax, P_VISIBILITY
    je .vis
    cmp eax, P_COLOR
    je .color
    cmp eax, P_BG
    je .bg
    cmp eax, P_BOLD
    je .bold
    cmp eax, P_ITALIC
    je .italic
    cmp eax, P_UNDER
    je .under
    cmp eax, P_ALIGN
    je .align
    cmp eax, P_WS
    je .ws
    cmp eax, P_LIST
    je .list
    cmp eax, P_TRANSFORM
    je .transform
    cmp eax, P_ML
    je .ml
    cmp eax, P_MT
    je .mt
    cmp eax, P_MB
    je .mb
    cmp eax, P_PL
    je .pl
    cmp eax, P_POS
    jb .done
    cmp eax, P_OFF
    ja .done
    ; P_POS .. P_OFF -> S_POS .. S_OFF
    mov [r13 + rax + S_POS - P_POS], cl
    jmp .done
.display:
    mov [r13 + S_DISPLAY], cl
    jmp .done
.vis:
    mov [r13 + S_VIS], cl
    jmp .done
.color:
    cmp ecx, CSS_TRANSPARENT
    je .done
    mov [r13 + S_COLOR], ecx
    jmp .done
.bg:
    mov [r13 + S_BG], ecx
    jmp .done
.bold:
    mov [r13 + S_BOLD], cl
    jmp .done
.italic:
    mov [r13 + S_ITALIC], cl
    jmp .done
.under:
    mov [r13 + S_UNDER], cl
    jmp .done
.align:
    mov [r13 + S_ALIGN], cl
    jmp .done
.ws:
    mov [r13 + S_WS], cl
    jmp .done
.list:
    mov [r13 + S_LIST], cl
    jmp .done
.transform:
    mov [r13 + S_TRANSFORM], cl
    jmp .done
.ml:
    mov [r13 + S_ML], cx
    jmp .done
.mt:
    mov [r13 + S_MT], cx
    jmp .done
.mb:
    mov [r13 + S_MB], cx
    jmp .done
.pl:
    mov [r13 + S_PL], cx
.done:
    pop rcx
    pop rax
    ret

; ==============================================================================
; Text helpers
; ==============================================================================

; css_skip_ws: R12 past spaces and /* comments */ (up to R13)
css_skip_ws:
.loop:
    cmp r12, r13
    jae .ret
    cmp byte [r12], ' '
    jbe .space
    cmp word [r12], '/*'
    jne .ret
    add r12, 2
.comment:
    cmp r12, r13
    jae .ret
    cmp word [r12], '*/'
    je .comment_end
    inc r12
    jmp .comment
.comment_end:
    add r12, 2
    jmp .loop
.space:
    inc r12
    jmp .loop
.ret:
    ret

; css_skip_block: R12 = at or before '{' -> past its matching '}'
css_skip_block:
    push rax
    push rcx
    xor ecx, ecx
.loop:
    cmp r12, r13
    jae .done
    mov al, [r12]
    inc r12
    cmp al, '{'
    jne .not_open
    inc ecx
    jmp .loop
.not_open:
    cmp al, '}'
    jne .loop
    dec ecx
    jg .loop
.done:
    pop rcx
    pop rax
    ret

; css_ident: RSI = text -> ECX = length of the identifier there (letters,
; digits, '-', '_', escapes, non-ASCII)
css_ident:
    push rax
    xor ecx, ecx
.char:
    mov al, [rsi + rcx]
    cmp al, '-'
    je .ok
    cmp al, '_'
    je .ok
    cmp al, '\'
    je .escape
    cmp al, 0x80
    jae .ok
    cmp al, '0'
    jb .done
    cmp al, '9'
    jbe .ok
    or al, 0x20
    cmp al, 'a'
    jb .done
    cmp al, 'z'
    ja .done
.ok:
    inc ecx
    jmp .char
.escape:
    add ecx, 2
    jmp .char
.done:
    pop rax
    ret

; css_ident_is: RSI/ECX = identifier, RDI = keyword (NUL-terminated, lower
; case) -> ZF=1 if equal (ignoring case)
css_ident_is:
    push rax
    push rcx
    push rsi
    push rdi
.char:
    mov al, [rdi]
    test al, al
    jz .end
    test ecx, ecx
    jz .no
    mov ah, [rsi]
    or ah, 0x20
    cmp ah, al
    jne .no
    inc rsi
    inc rdi
    dec ecx
    jmp .char
.end:
    test ecx, ecx                   ; ZF=1 if both ended
    jmp .ret
.no:
    or al, 1                        ; ZF=0 (AL is a letter, not 0)
    test rsp, rsp
.ret:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; css_ci_equal: RSI, RDI = two strings, ECX = length -> ZF=1 if equal (case
; folded)
css_ci_equal:
    push rax
    push rcx
    push rsi
    push rdi
.char:
    test ecx, ecx
    jz .ret                         ; ZF=1
    mov al, [rsi]
    mov ah, [rdi]
    or ax, 0x2020
    cmp al, ah
    jne .ret
    inc rsi
    inc rdi
    dec ecx
    jmp .char
.ret:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; css_contains_ci: RSI/ECX = text, RDI = word (NUL-terminated, lower case)
; -> ZF=1 if the text contains it
css_contains_ci:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push rdi
    mov rdi, [rsp]
    call strlen_rdi                 ; EAX = word length
    pop rdi
    mov edx, eax
.try:
    cmp ecx, edx
    jb .no
    push rcx
    mov ecx, edx
    call css_ci_equal
    pop rcx
    je .yes
    inc rsi
    dec ecx
    jmp .try
.no:
    test rsp, rsp                   ; ZF=0
.yes:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; strlen_rdi: RDI = string -> EAX = length
strlen_rdi:
    push rsi
    mov rsi, rdi
    call strlen
    pop rsi
    ret

section .data
css_apply_important:    db 0

section .rodata
css_at_media:           db "media", 0
css_at_supports:        db "supports", 0
css_at_layer:           db "layer", 0
css_kw_important:       db "important"
css_kw_var:             db "var(", 0
css_kw_bold:            db "bold", 0
css_kw_auto:            db "auto"
css_kw_none:            db "none"
css_kw_not:             db "not", 0
css_kw_and:             db "and", 0
css_kw_only:            db "only", 0
css_kw_screen:          db "screen", 0
css_kw_all:             db "all", 0
css_kw_min_width:       db "min-width", 0
css_kw_max_width:       db "max-width", 0
css_kw_color_scheme:    db "prefers-color-scheme", 0
css_kw_reduced_motion:  db "prefers-reduced-motion", 0
css_kw_root:            db "root", 0
css_kw_link:            db "link", 0
css_kw_first_child:     db "first-child", 0
css_kw_last_child:      db "last-child", 0
css_kw_only_child:      db "only-child", 0
css_kw_rect:            db "rect(", 0
css_kw_inset:           db "inset(", 0
css_kw_hidden:          db "hidden", 0
css_kw_open:            db "open", 0
css_attr_bgcolor:       db "bgcolor", 0
css_attr_color:         db "color", 0
css_attr_align:         db "align", 0

; property table: db name length, name, db handler kind, db property
K_KEYWORD               equ 1
K_COLOR                 equ 2
K_LENGTH                equ 3
K_BACKGROUND            equ 4
K_BOX                   equ 5
K_FONT                  equ 6
K_SIZE                  equ 7
K_CLIP                  equ 8
K_OPACITY               equ 9
K_OFFSET                equ 10
%macro CPROP 3
    db %%e - %%s
%%s:
    db %1
%%e:
    db %2, %3
%endmacro
css_props:
    CPROP "display", K_KEYWORD, P_DISPLAY
    CPROP "visibility", K_KEYWORD, P_VISIBILITY
    CPROP "color", K_COLOR, P_COLOR
    CPROP "background-color", K_COLOR, P_BG
    CPROP "background", K_BACKGROUND, P_BG
    CPROP "font-weight", K_KEYWORD, P_BOLD
    CPROP "font-style", K_KEYWORD, P_ITALIC
    CPROP "font", K_FONT, P_BOLD
    CPROP "text-decoration", K_KEYWORD, P_UNDER
    CPROP "text-decoration-line", K_KEYWORD, P_UNDER
    CPROP "text-align", K_KEYWORD, P_ALIGN
    CPROP "white-space", K_KEYWORD, P_WS
    CPROP "list-style", K_KEYWORD, P_LIST
    CPROP "list-style-type", K_KEYWORD, P_LIST
    CPROP "text-transform", K_KEYWORD, P_TRANSFORM
    CPROP "margin", K_BOX, P_ML
    CPROP "margin-left", K_LENGTH, P_ML
    CPROP "margin-top", K_LENGTH, P_MT
    CPROP "margin-bottom", K_LENGTH, P_MB
    CPROP "margin-inline-start", K_LENGTH, P_ML
    CPROP "padding", K_BOX, P_PL
    CPROP "padding-left", K_LENGTH, P_PL
    CPROP "padding-inline-start", K_LENGTH, P_PL
    CPROP "position", K_KEYWORD, P_POS
    CPROP "width", K_SIZE, P_TINY
    CPROP "height", K_SIZE, P_H0
    CPROP "max-height", K_SIZE, P_H0
    CPROP "clip", K_CLIP, P_TINY
    CPROP "clip-path", K_CLIP, P_TINY
    CPROP "overflow", K_KEYWORD, P_OVH
    CPROP "overflow-y", K_KEYWORD, P_OVH
    CPROP "opacity", K_OPACITY, P_VISIBILITY
    CPROP "left", K_OFFSET, P_OFF
    CPROP "top", K_OFFSET, P_OFF
    CPROP "inset-inline-start", K_OFFSET, P_OFF
    db 0

; keyword values: db property, db value, db length, name
%macro CKW 3
    db %1, %2, %%e - %%s
%%s:
    db %3
%%e:
%endmacro
css_keywords:
    CKW P_DISPLAY, DISP_NONE, "none"
    CKW P_DISPLAY, DISP_BLOCK, "block"
    CKW P_DISPLAY, DISP_INLINE, "inline"
    CKW P_DISPLAY, DISP_INLINE, "inline-block"
    CKW P_DISPLAY, DISP_INLINE, "inline-flex"
    CKW P_DISPLAY, DISP_INLINE, "inline-table"
    CKW P_DISPLAY, DISP_INLINE, "contents"
    CKW P_DISPLAY, DISP_LIST_ITEM, "list-item"
    CKW P_DISPLAY, DISP_BLOCK, "flex"
    CKW P_DISPLAY, DISP_BLOCK, "grid"
    CKW P_DISPLAY, DISP_BLOCK, "flow-root"
    CKW P_DISPLAY, DISP_TABLE, "table"
    CKW P_DISPLAY, DISP_ROW, "table-row"
    CKW P_DISPLAY, DISP_CELL, "table-cell"
    CKW P_DISPLAY, DISP_BLOCK, "table-row-group"
    CKW P_DISPLAY, DISP_BLOCK, "table-header-group"
    CKW P_DISPLAY, DISP_BLOCK, "table-footer-group"
    CKW P_DISPLAY, DISP_BLOCK, "table-caption"
    CKW P_VISIBILITY, 0, "visible"
    CKW P_VISIBILITY, 1, "hidden"
    CKW P_VISIBILITY, 1, "collapse"
    CKW P_BOLD, 1, "bold"
    CKW P_BOLD, 1, "bolder"
    CKW P_BOLD, 0, "normal"
    CKW P_BOLD, 0, "lighter"
    CKW P_ITALIC, 1, "italic"
    CKW P_ITALIC, 1, "oblique"
    CKW P_ITALIC, 0, "normal"
    CKW P_UNDER, 1, "underline"
    CKW P_UNDER, 0, "none"
    CKW P_UNDER, 0, "line-through"
    CKW P_UNDER, 0, "overline"
    CKW P_ALIGN, ALIGN_LEFT, "left"
    CKW P_ALIGN, ALIGN_LEFT, "start"
    CKW P_ALIGN, ALIGN_LEFT, "justify"
    CKW P_ALIGN, ALIGN_CENTER, "center"
    CKW P_ALIGN, ALIGN_CENTER, "-webkit-center"
    CKW P_ALIGN, ALIGN_RIGHT, "right"
    CKW P_ALIGN, ALIGN_RIGHT, "end"
    CKW P_WS, WS_NORMAL, "normal"
    CKW P_WS, WS_PRE, "pre"
    CKW P_WS, WS_PRE, "pre-wrap"
    CKW P_WS, WS_PRE, "pre-line"
    CKW P_WS, WS_PRE, "break-spaces"
    CKW P_WS, WS_NOWRAP, "nowrap"
    CKW P_LIST, LIST_NONE, "none"
    CKW P_LIST, LIST_DISC, "disc"
    CKW P_LIST, LIST_DISC, "circle"
    CKW P_LIST, LIST_DISC, "square"
    CKW P_LIST, LIST_DECIMAL, "decimal"
    CKW P_TRANSFORM, 0, "none"
    CKW P_TRANSFORM, 1, "uppercase"
    CKW P_TRANSFORM, 2, "lowercase"
    CKW P_TRANSFORM, 0, "capitalize"
    CKW P_POS, 1, "absolute"
    CKW P_POS, 1, "fixed"
    CKW P_POS, 0, "static"
    CKW P_POS, 0, "relative"
    CKW P_POS, 0, "sticky"
    CKW P_OVH, 1, "hidden"
    CKW P_OVH, 1, "clip"
    CKW P_OVH, 0, "visible"
    CKW P_OVH, 0, "auto"
    CKW P_OVH, 0, "scroll"
    db 0

; named colours: db length, name, dd 0x00RRGGBB
%macro CCOL 2
    db %%e - %%s
%%s:
    db %1
%%e:
    dd %2
%endmacro
css_colors:
    CCOL "black", 0x000000
    CCOL "white", 0xFFFFFF
    CCOL "red", 0xFF0000
    CCOL "green", 0x008000
    CCOL "blue", 0x0000FF
    CCOL "yellow", 0xFFFF00
    CCOL "orange", 0xFFA500
    CCOL "purple", 0x800080
    CCOL "gray", 0x808080
    CCOL "grey", 0x808080
    CCOL "silver", 0xC0C0C0
    CCOL "maroon", 0x800000
    CCOL "olive", 0x808000
    CCOL "lime", 0x00FF00
    CCOL "aqua", 0x00FFFF
    CCOL "cyan", 0x00FFFF
    CCOL "teal", 0x008080
    CCOL "navy", 0x000080
    CCOL "fuchsia", 0xFF00FF
    CCOL "magenta", 0xFF00FF
    CCOL "darkgray", 0xA9A9A9
    CCOL "darkgrey", 0xA9A9A9
    CCOL "lightgray", 0xD3D3D3
    CCOL "lightgrey", 0xD3D3D3
    CCOL "darkblue", 0x00008B
    CCOL "darkred", 0x8B0000
    CCOL "darkgreen", 0x006400
    CCOL "brown", 0xA52A2A
    CCOL "pink", 0xFFC0CB
    CCOL "gold", 0xFFD700
    CCOL "whitesmoke", 0xF5F5F5
    CCOL "gainsboro", 0xDCDCDC
    CCOL "dimgray", 0x696969
    CCOL "dimgrey", 0x696969
    CCOL "steelblue", 0x4682B4
    CCOL "transparent", CSS_TRANSPARENT
    db 0
section .text
