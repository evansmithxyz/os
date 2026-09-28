; ==============================================================================
; Antigravity OS - JavaScript lexer
; ------------------------------------------------------------------------------
; jslex_init points it at the source; jslex_next reads one token into tok_*.
; Names and string literals become atoms (keywords carry their KW_* id in
; JH_AUX), numbers become doubles, punctuators become P_* ids. tok_nl says a
; line break came before the token (automatic semicolon insertion).
; ==============================================================================

[bits 64]

TK_EOF                  equ 0
TK_NAME                 equ 1           ; tok_val = atom
TK_NUM                  equ 2           ; tok_val = double bits
TK_STR                  equ 3           ; tok_val = atom
TK_PUNCT                equ 4           ; tok_val = P_*
TK_TEMPLATE             equ 5           ; tok_val = atom of a template piece, tok_tail
                                        ; = 1 if it ended with ` (else with ${)

P_LBRACE                equ 1
P_RBRACE                equ 2
P_LPAREN                equ 3
P_RPAREN                equ 4
P_LBRACK                equ 5
P_RBRACK                equ 6
P_SEMI                  equ 7
P_COMMA                 equ 8
P_DOT                   equ 9
P_ELLIPSIS              equ 10
P_QUESTION              equ 11
P_QDOT                  equ 12
P_COLON                 equ 13
P_ARROW                 equ 14
P_ASSIGN                equ 15
P_EQ                    equ 16
P_SEQ                   equ 17
P_NE                    equ 18
P_SNE                   equ 19
P_LT                    equ 20
P_LE                    equ 21
P_GT                    equ 22
P_GE                    equ 23
P_PLUS                  equ 24
P_MINUS                 equ 25
P_STAR                  equ 26
P_SLASH                 equ 27
P_PERCENT               equ 28
P_STARSTAR              equ 29
P_INC                   equ 30
P_DEC                   equ 31
P_SHL                   equ 32
P_SAR                   equ 33
P_SHR                   equ 34
P_AMP                   equ 35
P_PIPE                  equ 36
P_CARET                 equ 37
P_NOT                   equ 38
P_TILDE                 equ 39
P_AND                   equ 40
P_OR                    equ 41
P_NULLISH               equ 42
P_ADD_ASSIGN            equ 43          ; compound assignments: P_ADD_ASSIGN..P_NULLISH_ASSIGN
P_SUB_ASSIGN            equ 44
P_MUL_ASSIGN            equ 45
P_DIV_ASSIGN            equ 46
P_MOD_ASSIGN            equ 47
P_POW_ASSIGN            equ 48
P_SHL_ASSIGN            equ 49
P_SAR_ASSIGN            equ 50
P_SHR_ASSIGN            equ 51
P_AND_ASSIGN            equ 52
P_OR_ASSIGN             equ 53
P_XOR_ASSIGN            equ 54
P_LAND_ASSIGN           equ 55
P_LOR_ASSIGN            equ 56
P_NULLISH_ASSIGN        equ 57
P_BACKTICK              equ 58
P_HASH                  equ 59
P_AT                    equ 60

; Punctuators, longest first: db length, text, id
%macro PUNCT 2
    db %%e - %%s
    %%s: db %1
    %%e: db %2
%endmacro

section .rodata
jslex_puncts:
    PUNCT ">>>=", P_SHR_ASSIGN
    PUNCT "...", P_ELLIPSIS
    PUNCT "===", P_SEQ
    PUNCT "!==", P_SNE
    PUNCT "**=", P_POW_ASSIGN
    PUNCT "<<=", P_SHL_ASSIGN
    PUNCT ">>=", P_SAR_ASSIGN
    PUNCT ">>>", P_SHR
    PUNCT "&&=", P_LAND_ASSIGN
    PUNCT "||=", P_LOR_ASSIGN
    PUNCT "??=", P_NULLISH_ASSIGN
    PUNCT "=>", P_ARROW
    PUNCT "==", P_EQ
    PUNCT "!=", P_NE
    PUNCT "<=", P_LE
    PUNCT ">=", P_GE
    PUNCT "&&", P_AND
    PUNCT "||", P_OR
    PUNCT "??", P_NULLISH
    PUNCT "?.", P_QDOT
    PUNCT "++", P_INC
    PUNCT "--", P_DEC
    PUNCT "+=", P_ADD_ASSIGN
    PUNCT "-=", P_SUB_ASSIGN
    PUNCT "*=", P_MUL_ASSIGN
    PUNCT "/=", P_DIV_ASSIGN
    PUNCT "%=", P_MOD_ASSIGN
    PUNCT "&=", P_AND_ASSIGN
    PUNCT "|=", P_OR_ASSIGN
    PUNCT "^=", P_XOR_ASSIGN
    PUNCT "**", P_STARSTAR
    PUNCT "<<", P_SHL
    PUNCT ">>", P_SAR
    PUNCT "{", P_LBRACE
    PUNCT "}", P_RBRACE
    PUNCT "(", P_LPAREN
    PUNCT ")", P_RPAREN
    PUNCT "[", P_LBRACK
    PUNCT "]", P_RBRACK
    PUNCT ";", P_SEMI
    PUNCT ",", P_COMMA
    PUNCT ".", P_DOT
    PUNCT "?", P_QUESTION
    PUNCT ":", P_COLON
    PUNCT "=", P_ASSIGN
    PUNCT "<", P_LT
    PUNCT ">", P_GT
    PUNCT "+", P_PLUS
    PUNCT "-", P_MINUS
    PUNCT "*", P_STAR
    PUNCT "/", P_SLASH
    PUNCT "%", P_PERCENT
    PUNCT "&", P_AMP
    PUNCT "|", P_PIPE
    PUNCT "^", P_CARET
    PUNCT "!", P_NOT
    PUNCT "~", P_TILDE
    PUNCT "`", P_BACKTICK
    PUNCT "#", P_HASH
    PUNCT "@", P_AT
    db 0

jsmsg_bad_char:         db "Invalid or unexpected token", 0
jsmsg_unterminated_str: db "Invalid or unexpected token (unterminated string)", 0
jsmsg_unterminated_cmt: db "Unterminated comment", 0
jsmsg_bad_number:       db "Invalid number", 0
jsmsg_bigint:           db "BigInt literals are not supported yet", 0
jsmsg_unterminated_tpl: db "Unterminated template literal", 0

section .bss
alignb 8
jslex_state:                            ; everything jslex_peek saves and restores
jslex_src:              resq 1
jslex_pos:              resq 1
jslex_end:              resq 1
jslex_line:             resd 1
tok_type:               resd 1
tok_line:               resd 1
tok_kw:                 resd 1          ; KW_* of a TK_NAME keyword, else 0
tok_val:                resq 1
tok_start:              resq 1
tok_nl:                 resb 1
tok_tail:               resb 1          ; TK_TEMPLATE: the last piece
JSLEX_STATE_SIZE        equ $ - jslex_state
alignb 8
jslex_saved:            resb 64
peek_type:              resd 1
peek_line:              resd 1
peek_kw:                resd 1
peek_val:               resq 1
peek_nl:                resb 1
alignb 2
jslex_punct_first:      resw 128        ; first char -> 1 + offset of its first entry in jslex_puncts

section .text

; ------------------------------------------------------------------------------
; jslex_regex: the current token is the '/' (or '/=') that starts a regular
; expression literal -> RAX = its pattern, RDX = its flags (atoms); the lexer
; goes on after it (the parser knows when a '/' starts one)
; ------------------------------------------------------------------------------
jslex_regex:
    push rcx
    push rsi
    push rdi
    push r8
    mov rsi, [tok_start]
    inc rsi                         ; past the '/'
    mov rdi, rsi
    xor r8d, r8d                    ; 1 = inside [ ]
.char:
    cmp rsi, [jslex_end]
    jae .unterminated
    mov al, [rsi]
    cmp al, 10
    je .unterminated
    cmp al, 13
    je .unterminated
    inc rsi
    cmp al, '\'
    jne .not_escape
    cmp rsi, [jslex_end]
    jae .unterminated
    inc rsi
    jmp .char
.not_escape:
    test r8d, r8d
    jnz .in_class
    cmp al, '['
    jne .not_class
    mov r8d, 1
    jmp .char
.not_class:
    cmp al, '/'
    jne .char
    ; the pattern
    lea rcx, [rsi - 1]
    sub rcx, rdi
    push rsi
    mov rsi, rdi
    call jsstr_atom
    pop rsi
    mov r8, rax
    ; the flags: letters after it
    mov rdi, rsi
.flag:
    cmp rsi, [jslex_end]
    jae .flags
    mov al, [rsi]
    or al, 0x20
    sub al, 'a'
    cmp al, 25
    ja .flags
    inc rsi
    jmp .flag
.flags:
    mov rcx, rsi
    sub rcx, rdi
    mov [jslex_pos], rsi
    mov rsi, rdi
    call jsstr_atom
    mov rdx, rax
    mov rax, r8
    pop r8
    pop rdi
    pop rsi
    pop rcx
    ret
.in_class:
    cmp al, ']'
    jne .char
    xor r8d, r8d
    jmp .char
.unterminated:
    lea rsi, [jsmsg_rx_slash]
    jmp jslex_error

; ------------------------------------------------------------------------------
; jslex_init: RSI = source, RCX = length; reads the first token
; ------------------------------------------------------------------------------
jslex_init:
    cmp word [jslex_punct_first + '(' * 2], 0
    jne .ready
    ; (once: where the punctuators of each first character start)
    push rax
    push rbx
    push rdx
    lea rbx, [jslex_puncts]
.entry:
    movzx edx, byte [rbx]
    test edx, edx
    jz .indexed
    movzx eax, byte [rbx + 1]
    cmp word [jslex_punct_first + rax * 2], 0
    jne .next_entry
    push rbx
    lea rdx, [jslex_puncts - 1]
    sub rbx, rdx
    mov [jslex_punct_first + rax * 2], bx
    pop rbx
    movzx edx, byte [rbx]
.next_entry:
    lea rbx, [rbx + rdx + 2]
    jmp .entry
.indexed:
    pop rdx
    pop rbx
    pop rax
.ready:
    push rax
    mov [jslex_src], rsi
    mov [jslex_pos], rsi
    lea rax, [rsi + rcx]
    mov [jslex_end], rax
    mov dword [jslex_line], 1
    pop rax
    jmp jslex_next

; ------------------------------------------------------------------------------
; jslex_peek: the token after the current one -> peek_type, peek_val, peek_nl
; ------------------------------------------------------------------------------
jslex_peek:
    push rax
    push rcx
    push rsi
    push rdi
    ; save the lexer position and the current token
    lea rsi, [jslex_state]
    lea rdi, [jslex_saved]
    mov ecx, JSLEX_STATE_SIZE
    rep movsb
    call jslex_next
    mov eax, [tok_type]
    mov [peek_type], eax
    mov eax, [tok_line]
    mov [peek_line], eax
    mov eax, [tok_kw]
    mov [peek_kw], eax
    mov rax, [tok_val]
    mov [peek_val], rax
    mov al, [tok_nl]
    mov [peek_nl], al
    lea rsi, [jslex_saved]
    lea rdi, [jslex_state]
    mov ecx, JSLEX_STATE_SIZE
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jslex_next: read the next token into tok_type / tok_val / tok_line / tok_nl
; ------------------------------------------------------------------------------
jslex_next:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rsi, [jslex_pos]
    mov rdi, [jslex_end]
    mov byte [tok_nl], 0
    mov dword [tok_kw], 0
.skip:
    cmp rsi, rdi
    jae .eof
    movzx eax, byte [rsi]
    cmp al, 10
    je .newline
    cmp al, 13
    je .cr
    cmp al, ' '
    je .space
    cmp al, 9
    jb .not_space
    cmp al, 12
    jbe .space
    cmp al, '/'
    je .slash
    cmp al, '<'
    je .html_open
    cmp al, '-'
    je .html_close
    cmp al, 0x80
    jb .token
    ; U+00A0, U+FEFF, U+2028/2029 count as white space / line breaks
    push rcx
    mov rcx, rdi
    sub rcx, rsi
    call jsnum_space_len
    pop rcx
    test eax, eax
    jz .token_reload
    cmp eax, 3
    jne .skip_n
    cmp byte [rsi], 0xE2
    jne .skip_n
    mov byte [tok_nl], 1
    inc dword [jslex_line]
.skip_n:
    add rsi, rax
    jmp .skip
.token_reload:
    movzx eax, byte [rsi]
    jmp .token
.not_space:
    jmp .token
.newline:
    inc dword [jslex_line]
    mov byte [tok_nl], 1
.space:
    inc rsi
    jmp .skip
.cr:
    inc rsi
    cmp rsi, rdi
    jae .cr_line
    cmp byte [rsi], 10
    je .skip                        ; \r\n: counted at the \n
.cr_line:
    inc dword [jslex_line]
    mov byte [tok_nl], 1
    jmp .skip
.html_open:
    ; <!-- starts a line comment (old pages hide scripts in HTML comments)
    lea rdx, [rsi + 4]
    cmp rdx, rdi
    ja .token
    cmp dword [rsi], '<!--'
    jne .token
    jmp .line_comment
.html_close:
    ; --> at the start of a line is a line comment too
    lea rdx, [rsi + 3]
    cmp rdx, rdi
    ja .token
    cmp word [rsi + 1], '->'
    jne .token
    cmp byte [tok_nl], 0
    jne .line_comment
    cmp rsi, [jslex_src]
    je .line_comment
    jmp .token
.slash:
    lea rdx, [rsi + 1]
    cmp rdx, rdi
    jae .token
    cmp byte [rdx], '/'
    je .line_comment
    cmp byte [rdx], '*'
    jne .token
    ; block comment
    add rsi, 2
.block:
    cmp rsi, rdi
    jae .unterminated_comment
    mov al, [rsi]
    cmp al, 10
    jne .block_star
    inc dword [jslex_line]
    mov byte [tok_nl], 1
.block_star:
    cmp al, '*'
    jne .block_next
    lea rdx, [rsi + 1]
    cmp rdx, rdi
    jae .block_next
    cmp byte [rdx], '/'
    jne .block_next
    add rsi, 2
    jmp .skip
.block_next:
    inc rsi
    jmp .block
.line_comment:
    cmp rsi, rdi
    jae .eof
    cmp byte [rsi], 10
    je .skip
    cmp byte [rsi], 13
    je .skip
    inc rsi
    jmp .line_comment
.eof:
    mov [jslex_pos], rsi
    mov [tok_start], rsi
    mov eax, [jslex_line]
    mov [tok_line], eax
    mov dword [tok_type], TK_EOF
    mov qword [tok_val], 0
    jmp .out

.token:
    mov [tok_start], rsi
    mov edx, [jslex_line]
    mov [tok_line], edx
    call jslex_is_ident_start
    jc .name
    cmp al, '0'
    jb .not_digit
    cmp al, '9'
    jbe .number
.not_digit:
    cmp al, '.'
    jne .not_dot_number
    lea rdx, [rsi + 1]
    cmp rdx, rdi
    jae .punct
    movzx edx, byte [rdx]
    sub edx, '0'
    cmp edx, 9
    jbe .number
    jmp .punct
.not_dot_number:
    cmp al, '"'
    je .string
    cmp al, 0x27
    je .string
    jmp .punct

.name:
    mov rbx, rsi
.name_loop:
    inc rsi
    cmp rsi, rdi
    jae .name_end
    movzx eax, byte [rsi]
    call jslex_is_ident_start
    jc .name_loop
    cmp al, '0'
    jb .name_end
    cmp al, '9'
    jbe .name_loop
.name_end:
    mov rcx, rsi
    sub rcx, rbx
    push rsi
    mov rsi, rbx
    call jsstr_atom
    pop rsi
    mov [tok_val], rax
    movzx edx, word [rax + JH_AUX]
    mov [tok_kw], edx
    mov dword [tok_type], TK_NAME
    jmp .done

.number:
    mov rcx, rdi
    sub rcx, rsi
    cmp al, '0'
    jne .decimal
    cmp rcx, 2
    jb .decimal
    movzx eax, byte [rsi + 1]
    or al, 0x20
    mov ebx, 16
    cmp al, 'x'
    je .radix
    mov ebx, 8
    cmp al, 'o'
    je .radix
    mov ebx, 2
    cmp al, 'b'
    je .radix
    ; legacy octal 017 (all digits 0-7)
    movzx eax, byte [rsi + 1]
    sub eax, '0'
    cmp eax, 9
    ja .decimal
    lea rdx, [rsi + 1]
.octal_check:
    cmp rdx, rdi
    jae .octal
    movzx eax, byte [rdx]
    sub eax, '0'
    cmp eax, 9
    ja .octal_end
    cmp eax, 7
    ja .decimal
    inc rdx
    jmp .octal_check
.octal_end:
    movzx eax, byte [rdx]
    cmp al, '.'
    je .decimal
    or al, 0x20
    cmp al, 'e'
    je .decimal
.octal:
    inc rsi
    dec rcx
    mov ebx, 8
    call jsnum_parse_radix
    add rsi, rcx
    jmp .number_end
.radix:
    add rsi, 2
    sub rcx, 2
    call jsnum_parse_radix
    test rcx, rcx
    jz .bad_number
    add rsi, rcx
    jmp .number_end
.decimal:
    mov edx, 1                      ; allow 1_000
    call jsnum_scan
    test rcx, rcx
    jz .bad_number
    add rsi, rcx
.number_end:
    mov [tok_val], rax
    mov dword [tok_type], TK_NUM
    cmp rsi, rdi
    jae .done
    cmp byte [rsi], 'n'
    je .bigint
    jmp .done

.string:
    call jslex_string
    mov [tok_val], rax
    mov dword [tok_type], TK_STR
    jmp .done
.template:
    inc rsi
    call jslex_template
    cmp byte [tok_tail], 0
    jne .template_tail
    inc rsi                         ; past the '{' of ${
.template_tail:
    mov [tok_val], rax
    mov dword [tok_type], TK_TEMPLATE
    jmp .done

.punct:
    cmp al, '`'
    je .template
    cmp al, 128
    jae .bad_char
    movzx ebx, al
    movzx ebx, word [jslex_punct_first + rbx * 2]
    test ebx, ebx
    jz .bad_char
    lea rbx, [jslex_puncts + rbx - 1]
    mov rcx, rdi
    sub rcx, rsi                    ; bytes left
.try:
    movzx edx, byte [rbx]
    test edx, edx
    jz .bad_char
    cmp al, [rbx + 1]
    jne .try_next
    cmp rdx, rcx
    ja .try_next
    push rcx
    push rsi
    push rdi
    lea rdi, [rbx + 1]
    mov ecx, edx
    repe cmpsb
    pop rdi
    pop rsi
    pop rcx
    je .matched
.try_next:
    lea rbx, [rbx + rdx + 2]
    jmp .try
.matched:
    movzx eax, byte [rbx + rdx + 1]
    ; "?." followed by a digit is "?" then a number (a?.5:1)
    cmp eax, P_QDOT
    jne .punct_ok
    lea rcx, [rsi + 2]
    cmp rcx, rdi
    jae .punct_ok
    movzx ecx, byte [rcx]
    sub ecx, '0'
    cmp ecx, 9
    ja .punct_ok
    mov eax, P_QUESTION
    mov edx, 1
.punct_ok:
    add rsi, rdx
    mov [tok_val], rax
    mov dword [tok_type], TK_PUNCT
.done:
    mov [jslex_pos], rsi
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

.unterminated_comment:
    lea rsi, [jsmsg_unterminated_cmt]
    jmp jslex_error
.bad_char:
    lea rsi, [jsmsg_bad_char]
    jmp jslex_error
.bad_number:
    lea rsi, [jsmsg_bad_number]
    jmp jslex_error
.bigint:
    lea rsi, [jsmsg_bigint]
    jmp jslex_error

; ------------------------------------------------------------------------------
; jslex_template: RSI = start of a template piece (after ` or }), RDI = end of
; source -> RAX = atom of its text (escapes decoded), RSI past the ` or ${ that
; ends it, tok_tail = 1 for `
; ------------------------------------------------------------------------------
jslex_template:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    mov r9, rdi
    mov rbx, rsi
.find:
    cmp rbx, r9
    jae .unterminated
    mov al, [rbx]
    cmp al, '`'
    je .tail
    cmp al, 10
    jne .not_line
    inc dword [jslex_line]
.not_line:
    cmp al, '$'
    jne .not_dollar
    lea rax, [rbx + 1]
    cmp rax, r9
    jae .not_dollar
    cmp byte [rax], '{'
    je .head
.not_dollar:
    cmp al, '\'
    jne .next
    inc rbx
.next:
    inc rbx
    jmp .find
.tail:
    mov byte [tok_tail], 1
    jmp jslex_string.found          ; decode [RSI, RBX); RSI = RBX + 1
.head:
    mov byte [tok_tail], 0
    jmp jslex_string.found          ; (the caller skips the '{' as well)
.unterminated:
    lea rsi, [jsmsg_unterminated_tpl]
    jmp jslex_error

; jslex_template_resume: the current token is the '}' that ends a ${...}
; -> the next template piece becomes the current token
jslex_template_resume:
    push rax
    push rsi
    push rdi
    mov rsi, [jslex_pos]
    mov rdi, [jslex_end]
    mov [tok_start], rsi
    mov eax, [jslex_line]
    mov [tok_line], eax
    call jslex_template
    cmp byte [tok_tail], 0
    jne .tail
    inc rsi
.tail:
    mov [tok_val], rax
    mov dword [tok_type], TK_TEMPLATE
    mov dword [tok_kw], 0
    mov [jslex_pos], rsi
    pop rdi
    pop rsi
    pop rax
    ret

; jslex_is_ident_start: AL = byte -> CF=1 for a-z A-Z $ _ and bytes >= 0x80
jslex_is_ident_start:
    cmp al, '$'
    je .yes
    cmp al, '_'
    je .yes
    cmp al, 0x80
    jae .yes
    push rax
    or al, 0x20
    cmp al, 'a'
    jb .no_pop
    cmp al, 'z'
    ja .no_pop
    pop rax
.yes:
    stc
    ret
.no_pop:
    pop rax
    clc
    ret

; jslex_error: RSI = message -> SyntaxError at the current token's line
jslex_error:
    mov eax, [tok_line]
    mov [vm_line], eax
    mov edx, JE_SYNTAX
    xor edi, edi
    jmp js_throw

; ------------------------------------------------------------------------------
; jslex_string: RSI = opening quote, RDI = end of source
; -> RAX = atom of the decoded text, RSI = after the closing quote
; ------------------------------------------------------------------------------
jslex_string:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    movzx r8d, byte [rsi]           ; quote
    inc rsi
    mov r9, rdi                     ; end of source
    ; find the closing quote to size the buffer (decoded <= raw)
    mov rbx, rsi
.find:
    cmp rbx, r9
    jae .unterminated
    movzx eax, byte [rbx]
    cmp eax, r8d
    je .found
    cmp al, 10
    je .unterminated
    cmp al, '\'
    jne .find_next
    inc rbx
    cmp rbx, r9
    jae .unterminated
    cmp byte [rbx], 13              ; \ CR LF: a line continuation
    jne .find_next
    lea rax, [rbx + 1]
    cmp rax, r9
    jae .find_next
    cmp byte [rax], 10
    jne .find_next
    inc rbx
.find_next:
    inc rbx
    jmp .find
.found:
    mov rcx, rbx
    sub rcx, rsi
    call jsstr_alloc                ; scratch string, raw length
    mov r10, rax
    lea rdi, [rax + JSTR_DATA]
.decode:
    cmp rsi, rbx
    jae .end
    movzx eax, byte [rsi]
    inc rsi
    cmp al, '\'
    je .escape
    stosb
    jmp .decode
.escape:
    movzx eax, byte [rsi]
    inc rsi
    cmp al, 'n'
    je .lf
    cmp al, 't'
    je .tab
    cmp al, 'r'
    je .cret
    cmp al, 'b'
    je .bs
    cmp al, 'f'
    je .ff
    cmp al, 'v'
    je .vt
    cmp al, '0'
    je .nul
    cmp al, 'x'
    je .hex2
    cmp al, 'u'
    je .unicode
    cmp al, 13
    je .continuation_cr
    cmp al, 10
    je .continuation
    stosb                           ; \' \" \\ and anything else: itself
    jmp .decode
.lf:
    mov al, 10
    stosb
    jmp .decode
.tab:
    mov al, 9
    stosb
    jmp .decode
.cret:
    mov al, 13
    stosb
    jmp .decode
.bs:
    mov al, 8
    stosb
    jmp .decode
.ff:
    mov al, 12
    stosb
    jmp .decode
.vt:
    mov al, 11
    stosb
    jmp .decode
.nul:
    xor eax, eax
    stosb
    jmp .decode
.continuation_cr:
    cmp rsi, rbx
    jae .continuation
    cmp byte [rsi], 10
    jne .continuation
    inc rsi
.continuation:
    inc dword [jslex_line]
    jmp .decode
.hex2:
    mov ecx, 2
    call .hex_digits
    call jslex_put_utf8
    jmp .decode
.unicode:
    cmp rsi, rbx
    jae .end
    cmp byte [rsi], '{'
    je .unicode_braced
    mov ecx, 4
    call .hex_digits
    ; a high surrogate followed by \uDC00-\uDFFF is one code point
    mov edx, eax
    and edx, 0xFC00
    cmp edx, 0xD800
    jne .put
    lea rdx, [rsi + 6]
    cmp rdx, rbx
    ja .put
    cmp word [rsi], '\u'
    jne .put
    push rax
    add rsi, 2
    mov ecx, 4
    call .hex_digits
    mov edx, eax
    and edx, 0xFC00
    cmp edx, 0xDC00
    je .pair
    sub rsi, 6                      ; not a low surrogate: decode it separately
    pop rax
    jmp .put
.pair:
    pop rdx
    sub edx, 0xD800
    shl edx, 10
    sub eax, 0xDC00
    add eax, edx
    add eax, 0x10000
.put:
    call jslex_put_utf8
    jmp .decode
.unicode_braced:
    inc rsi
    xor eax, eax
.braced:
    cmp rsi, rbx
    jae .end
    movzx edx, byte [rsi]
    inc rsi
    cmp dl, '}'
    je .put
    push rax
    mov eax, edx
    call jsnum_digit_value
    mov edx, eax
    pop rax
    cmp edx, 16
    jae .braced
    shl eax, 4
    or eax, edx
    and eax, 0x1FFFFF
    jmp .braced
.end:
    lea rsi, [rbx + 1]              ; past the closing quote
    lea rcx, [r10 + JSTR_DATA]
    sub rdi, rcx
    mov ecx, edi                    ; decoded length
    push rsi
    lea rsi, [r10 + JSTR_DATA]
    call jsstr_atom
    pop rsi
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
.unterminated:
    lea rsi, [jsmsg_unterminated_str]
    jmp jslex_error

; .hex_digits: ECX hex digits at RSI (stops early at a non-digit) -> EAX
.hex_digits:
    push rdx
    xor edx, edx
.hd_loop:
    cmp rsi, rbx
    jae .hd_done
    movzx eax, byte [rsi]
    call jsnum_digit_value
    cmp eax, 16
    jae .hd_done
    shl edx, 4
    or edx, eax
    inc rsi
    dec ecx
    jnz .hd_loop
.hd_done:
    mov eax, edx
    pop rdx
    ret

; jslex_put_utf8: EAX = code point, RDI = destination -> RDI advanced
jslex_put_utf8:
    push rax
    push rdx
    cmp eax, 0x80
    jb .one
    cmp eax, 0x800
    jb .two
    cmp eax, 0x10000
    jb .three
    mov edx, eax
    shr edx, 18
    or dl, 0xF0
    mov [rdi], dl
    inc rdi
    mov edx, eax
    shr edx, 12
    and dl, 0x3F
    or dl, 0x80
    mov [rdi], dl
    inc rdi
    jmp .last2
.three:
    mov edx, eax
    shr edx, 12
    or dl, 0xE0
    mov [rdi], dl
    inc rdi
.last2:
    mov edx, eax
    shr edx, 6
    and dl, 0x3F
    or dl, 0x80
    mov [rdi], dl
    inc rdi
    jmp .last
.two:
    mov edx, eax
    shr edx, 6
    or dl, 0xC0
    mov [rdi], dl
    inc rdi
.last:
    and al, 0x3F
    or al, 0x80
.one:
    mov [rdi], al
    inc rdi
    pop rdx
    pop rax
    ret
