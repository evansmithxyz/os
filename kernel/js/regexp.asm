; ==============================================================================
; Antigravity OS - JavaScript regular expressions: compiler and matcher
; ------------------------------------------------------------------------------
; jsre_compile turns a pattern and flags into a small program (the RX_*
; instructions below; jumps are relative, so a piece of program can be copied
; to repeat it). jsre_match runs a program on a string with backtracking:
; alternatives and undo records for captures go on an explicit stack in
; JS_RX_ADDR, so a pattern cannot overflow the kernel stack. Strings are
; UTF-8: `.`, classes and escapes above 0x7F match whole code points; /i folds
; ASCII letters. Lookahead and lookbehind are atomic, as in the standard.
; The RegExp object and the string methods that use it are in regexp2.asm.
; ==============================================================================

[bits 64]

; --- the program --------------------------------------------------------------
RX_CHAR                 equ 1           ; byte: that byte
RX_CHARI                equ 2           ; byte (lower case): that byte, any case
RX_ANY                  equ 3           ; a code point that is not a line break
RX_ANYNL                equ 4           ; any code point (/s)
RX_CLASS                equ 5           ; u16 size, then the class (RXC_*)
RX_BOL                  equ 6           ; start of input
RX_EOL                  equ 7           ; end of input
RX_BOLM                 equ 8           ; start of a line (/m)
RX_EOLM                 equ 9           ; end of a line (/m)
RX_WORDB                equ 10          ; \b
RX_NWORDB               equ 11          ; \B
RX_SPLIT                equ 12          ; rel32 first, rel32 second (from the end)
RX_JMP                  equ 13          ; rel32
RX_SAVE                 equ 14          ; u8 capture slot (2 per group)
RX_BACKREF              equ 15          ; u8 group
RX_BACKREFI             equ 16          ; u8 group, any case
RX_LOOK                 equ 17          ; u8 LK_*, rel32 length of the sub-program
RX_MARK                 equ 18          ; u16 register: the position, for...
RX_CHECK                equ 19          ; u16 register: ...failing a loop pass that matched nothing
RX_MATCH                equ 20
RX_ENDAT                equ 21          ; lookbehind: only where it has to end

LK_AHEAD                equ 1
LK_NOT_AHEAD            equ 2
LK_BEHIND               equ 3
LK_NOT_BEHIND           equ 4

; a class after RX_CLASS u16: flags (bit 0 negated), 16 bytes of bits for
; ASCII, u16 range count, then u32 low, u32 high pairs (code points >= 0x80)
RXC_BITS                equ 1
RXC_NRANGES             equ 17
RXC_RANGES              equ 19

; flags (JRE_FLAGS)
RXF_GLOBAL              equ 1
RXF_ICASE               equ 2
RXF_MULTILINE           equ 4
RXF_DOTALL              equ 8
RXF_UNICODE             equ 16
RXF_STICKY              equ 32
RXF_INDICES             equ 64

JSRE_MAX_PROG           equ 0x10000     ; program bytes
JSRE_MAX_GROUPS         equ 126
JSRE_MAX_CLASS          equ 2048        ; one class's bytes

; memory at JS_RX_ADDR: the matcher's captures, loop registers and stack,
; the compiler's buffers
RX_CAPS                 equ 0           ; qword per slot: byte offset or -1
RX_REGS                 equ 0x1000      ; qword per loop register
RX_PROG                 equ 0x10000     ; the compiler's program buffer
RX_ATOM                 equ 0x20000     ; ... and a quantified atom, kept to be copied
RX_STACK                equ 0x30000     ; 24-byte records: kind, a, b
jsre_buf                equ JS_RX_ADDR + RX_PROG
jsre_atom               equ JS_RX_ADDR + RX_ATOM
RXB_ALT                 equ 0           ; a: pc, b: position
RXB_CAP                 equ 1           ; a: slot, b: old value
RXB_REG                 equ 2           ; a: register, b: old value

section .bss
alignb 8
jsre_src:               resq 1          ; the pattern being compiled
jsre_pos:               resq 1
jsre_end:               resq 1
jsre_len:               resq 1          ; program bytes so far
jsre_flags:             resd 1
jsre_group_count:            resd 1          ; capturing groups so far
jsre_total:             resd 1          ; capturing groups in all
jsre_regs:              resd 1          ; loop registers so far
jsre_depth:             resd 1
jsre_names:             resq 1          ; raw array: group names (index = group)
jsre_error:             resq 1          ; the source value, for messages
jsre_class:             resb JSRE_MAX_CLASS
; matching
jsre_in:                resq 1          ; the input's first byte
jsre_in_end:            resq 1
jsre_behind:            resq 1          ; RX_ENDAT's position
jsre_steps:             resd 1
jsre_icase:             resb 1
jsre_multi:             resb 1

section .rodata
jsmsg_rx:               db "Invalid regular expression: /%/: ", 0
jsmsg_rx_paren:         db "Unterminated group", 0
jsmsg_rx_unmatched:     db "Unmatched ')'", 0
jsmsg_rx_class:         db "Unterminated character class", 0
jsmsg_rx_nothing:       db "Nothing to repeat", 0
jsmsg_rx_range:         db "Range out of order in character class", 0
jsmsg_rx_big:           db "Regular expression too large", 0
jsmsg_rx_group:         db "Invalid group", 0
jsmsg_rx_name:          db "Invalid capture group name", 0
jsmsg_rx_escape:        db "Invalid escape", 0
jsmsg_rx_flags:         db "Invalid flags supplied to RegExp constructor '%'", 0
jsmsg_rx_slash:         db "Invalid regular expression: missing /", 0
jsmsg_rx_stack:         db "Maximum call stack size exceeded", 0
jsre_flag_chars:        db "gimsuyd", 0

section .text

; ==============================================================================
; The compiler
; ==============================================================================

; ------------------------------------------------------------------------------
; jsre_compile: RAX = pattern (heap string), RDX = flags (heap string) ->
; RAX = the program (raw heap block), ECX = capturing groups, EDX = flags
; (RXF_*), R8 = group names (raw array: string or undefined per group; 0 if
; none). A bad pattern or flag throws a SyntaxError.
; ------------------------------------------------------------------------------
jsre_compile:
    push rbx
    push rsi
    push rdi
    mov rbx, rax
    mov rcx, rax
    BOX rcx, rsi, JS_STR_BITS
    mov [jsre_error], rcx
    ; the flags
    mov eax, edx
    call jsre_parse_flags
    mov [jsre_flags], eax
    ; the pattern
    lea rsi, [rbx + JSTR_DATA]
    mov [jsre_src], rsi
    mov ecx, [rbx + JSTR_LEN]
    add rcx, rsi
    mov [jsre_end], rcx
    call jsre_count_groups
    mov [jsre_pos], rsi
    mov qword [jsre_len], 0
    mov dword [jsre_group_count], 0
    mov dword [jsre_regs], 0
    mov dword [jsre_depth], 0
    ; the whole match is group 0
    mov al, RX_SAVE
    call jsre_emit
    xor eax, eax
    call jsre_emit
    call jsre_disjunction
    mov rsi, [jsre_pos]
    cmp rsi, [jsre_end]
    jb .unmatched                   ; a ')' too many
    mov al, RX_SAVE
    call jsre_emit
    mov al, 1
    call jsre_emit
    mov al, RX_MATCH
    call jsre_emit
    ; the program onto the heap
    mov rcx, [jsre_len]
    call js_alloc
    or byte [rax - 8 + GCH_FLAGS], GCF_LEAF
    mov rdi, rax
    lea rsi, [abs jsre_buf]
    mov rcx, [jsre_len]
    rep movsb
    mov ecx, [jsre_total]
    mov edx, [jsre_flags]
    mov r8, [jsre_names]
    pop rdi
    pop rsi
    pop rbx
    ret
.unmatched:
    lea rdi, [jsmsg_rx_unmatched]
    jmp jsre_error_throw

; jsre_parse_flags: EAX = flags string (raw) -> EAX = RXF_* (SyntaxError for
; an unknown or repeated flag)
jsre_parse_flags:
    push rbx
    push rcx
    push rdx
    push rsi
    mov rbx, rax
    xor edx, edx
    mov ecx, [rbx + JSTR_LEN]
    lea rsi, [rbx + JSTR_DATA]
.flag:
    test ecx, ecx
    jz .done
    lodsb
    dec ecx
    push rsi
    push rcx
    lea rsi, [jsre_flag_chars]
    xor ecx, ecx
.find:
    cmp byte [rsi + rcx], 0
    je .bad_pop
    cmp [rsi + rcx], al
    je .found
    inc ecx
    jmp .find
.found:
    mov eax, 1
    shl eax, cl
    ; g i m s u y d -> RXF_GLOBAL, ICASE, MULTILINE, DOTALL, UNICODE, STICKY, INDICES
    pop rcx
    pop rsi
    test edx, eax
    jnz .bad
    or edx, eax
    jmp .flag
.done:
    mov eax, edx
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.bad_pop:
    pop rcx
    pop rsi
.bad:
    mov rdi, rbx
    lea rsi, [jsmsg_rx_flags]
    mov edx, JE_SYNTAX
    jmp js_throw

; jsre_error_throw: RDI = what is wrong -> SyntaxError "Invalid regular
; expression: /source/: what"
jsre_error_throw:
    push rdi
    lea rsi, [jsmsg_rx]
    call jsstr_from_cstr
    mov rdx, rax
    pop rsi
    push rdx
    call jsstr_from_cstr
    mov rdx, rax
    pop rax
    call jsstr_concat               ; the message, with its %
    mov rsi, rax
    add rsi, JSTR_DATA
    mov edi, [jsre_error]
    mov edx, JE_SYNTAX
    jmp js_throw

; jsre_count_groups: the capturing groups of the pattern (so \2 knows) and
; their names -> jsre_total, jsre_names
jsre_count_groups:
    push rax
    push rcx
    push rdx
    push rsi
    mov qword [jsre_names], 0
    xor edx, edx
    mov rsi, [jsre_src]
    xor ecx, ecx                    ; 1 = inside [ ]
.char:
    cmp rsi, [jsre_end]
    jae .done
    lodsb
    cmp al, '\'
    je .escape
    test ecx, ecx
    jnz .in_class
    cmp al, '['
    je .open_class
    cmp al, '('
    jne .char
    cmp rsi, [jsre_end]
    jae .group
    cmp byte [rsi], '?'
    jne .group
    ; (?<name> is a group; (?: (?= (?! (?<= (?<! are not
    lea rax, [rsi + 2]
    cmp rax, [jsre_end]
    ja .char
    cmp byte [rsi + 1], '<'
    jne .char
    cmp byte [rsi + 2], '='
    je .char
    cmp byte [rsi + 2], '!'
    je .char
    inc edx
    push rsi
    add rsi, 2
    call jsre_note_name             ; ESI -> name, for group EDX
    pop rsi
    jmp .char
.group:
    inc edx
    jmp .char
.open_class:
    mov ecx, 1
    jmp .char
.in_class:
    cmp al, ']'
    jne .char
    xor ecx, ecx
    jmp .char
.escape:
    cmp rsi, [jsre_end]
    jae .done
    inc rsi
    jmp .char
.done:
    mov [jsre_total], edx
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsre_note_name: RSI = a group name (up to '>'), EDX = its group -> kept in
; jsre_names
jsre_note_name:
    push rax
    push rbx
    push rcx
    push rsi
    mov rbx, rsi
.end:
    cmp rsi, [jsre_end]
    jae .out
    cmp byte [rsi], '>'
    je .name
    inc rsi
    jmp .end
.name:
    mov rcx, rsi
    sub rcx, rbx
    jz .out
    mov rsi, rbx
    call jsstr_atom
    call jsb_box_string
    mov rcx, rax
    mov rax, [jsre_names]
    test rax, rax
    jnz .have
    push rcx
    xor ecx, ecx
    call jsarr_new
    mov [jsre_names], rax
    pop rcx
.have:
    push rdx
    call jsarr_set                  ; names[group] = name
    pop rdx
.out:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; jsre_emit: AL -> one program byte
jsre_emit:
    push rcx
    mov rcx, [jsre_len]
    cmp rcx, JSRE_MAX_PROG
    jae jsre_too_big
    mov [jsre_buf + rcx], al
    inc qword [jsre_len]
    pop rcx
    ret
; jsre_emit16 / jsre_emit32: AX / EAX
jsre_emit16:
    call jsre_emit
    shr eax, 8
    jmp jsre_emit
jsre_emit32:
    push rax
    call jsre_emit16
    pop rax
    shr eax, 16
    jmp jsre_emit16

jsre_too_big:
    lea rdi, [jsmsg_rx_big]
    jmp jsre_error_throw

; jsre_insert: RAX = program offset, ECX = bytes -> that many bytes of room
; made there (what follows moves up; the new bytes are to be filled in)
jsre_insert:
    push rcx
    push rsi
    push rdi
    mov rdi, [jsre_len]
    add rdi, rcx
    cmp rdi, JSRE_MAX_PROG
    jae jsre_too_big
    ; move [RAX, len) up by RCX, from the end
    mov rsi, [jsre_len]
    mov [jsre_len], rdi
    lea rdi, [jsre_buf + rdi - 1]
    push rcx
    mov rcx, rsi
    sub rcx, rax
    lea rsi, [jsre_buf + rsi - 1]
    std
    rep movsb
    cld
    pop rcx
    pop rdi
    pop rsi
    pop rcx
    ret

; jsre_put32: RAX = program offset, EDX = value -> written there
jsre_put32:
    mov [jsre_buf + rax], edx
    ret

; jsre_peek: -> AL = the next pattern byte (0 at the end), ZF=1 at the end
jsre_peek:
    push rsi
    mov rsi, [jsre_pos]
    cmp rsi, [jsre_end]
    jae .end
    mov al, [rsi]
    pop rsi
    cmp al, 0
    je .zero
    ret
.zero:
    or al, 1                        ; (a NUL byte in the pattern: not the end)
    mov al, 0
    ret
.end:
    xor eax, eax
    pop rsi
    ret

; jsre_at_end: -> CF=1 if the pattern is all read
jsre_at_end:
    push rax
    mov rax, [jsre_pos]
    cmp rax, [jsre_end]
    pop rax
    jae .yes
    clc
    ret
.yes:
    stc
    ret

; ------------------------------------------------------------------------------
; jsre_disjunction: alternative ('|' alternative)* -> program; stops at ')'
; or the end
; ------------------------------------------------------------------------------
jsre_disjunction:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    inc dword [jsre_depth]
    cmp dword [jsre_depth], 200
    ja jsre_too_big
    mov rbx, [jsre_len]             ; where this alternative starts
    xor r8d, r8d                    ; jumps to patch: a list on the kernel stack
    mov r9, rsp
.alternative:
    call jsre_alternative
    call jsre_at_end
    jc .end
    mov rsi, [jsre_pos]
    cmp byte [rsi], '|'
    jne .end
    inc qword [jsre_pos]
    ; the alternative before: SPLIT in front (this one / the next), JMP after
    mov rax, rbx
    mov ecx, 9
    call jsre_insert
    mov byte [jsre_buf + rax], RX_SPLIT
    xor edx, edx
    lea rax, [rax + 1]
    call jsre_put32                 ; first: straight on
    mov al, RX_JMP
    call jsre_emit
    mov rax, [jsre_len]
    push rax                        ; the JMP's rel32, patched at the end
    inc r8d
    xor eax, eax
    call jsre_emit32
    ; the SPLIT's second: the next alternative
    mov rdx, [jsre_len]
    lea rax, [rbx + 9]
    sub rdx, rax
    lea rax, [rbx + 5]
    call jsre_put32
    mov rbx, [jsre_len]
    jmp .alternative
.end:
    ; the JMPs go to here
.patch:
    test r8d, r8d
    jz .done
    pop rax
    mov rdx, [jsre_len]
    sub rdx, rax
    sub rdx, 4
    call jsre_put32
    dec r8d
    jmp .patch
.done:
    dec dword [jsre_depth]
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsre_alternative: terms until '|', ')' or the end
jsre_alternative:
    push rax
.term:
    call jsre_at_end
    jc .done
    mov rax, [jsre_pos]
    mov al, [rax]
    cmp al, '|'
    je .done
    cmp al, ')'
    je .done
    call jsre_term
    jmp .term
.done:
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsre_term: an assertion, or an atom with an optional quantifier
; ------------------------------------------------------------------------------
jsre_term:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov rbx, [jsre_len]             ; the atom's program starts here
    mov rsi, [jsre_pos]
    movzx eax, byte [rsi]
    inc rsi
    mov [jsre_pos], rsi
    cmp al, '^'
    je .bol
    cmp al, '$'
    je .eol
    cmp al, '('
    je .group
    cmp al, '.'
    je .dot
    cmp al, '['
    je .class
    cmp al, '\'
    je .escape
    cmp al, '*'
    je .nothing
    cmp al, '+'
    je .nothing
    cmp al, '?'
    je .nothing
    cmp al, '{'
    jne .literal
    ; a { that does not start a quantifier is a character
    dec qword [jsre_pos]
    call jsre_quantifier_ahead
    jc .nothing
    inc qword [jsre_pos]
.literal:
    ; the whole UTF-8 sequence is one character
    dec rsi
    mov [jsre_pos], rsi
    call jsre_literal_char
    jmp .quantifier
.bol:
    mov al, RX_BOL
    test dword [jsre_flags], RXF_MULTILINE
    jz .assertion
    mov al, RX_BOLM
    jmp .assertion
.eol:
    mov al, RX_EOL
    test dword [jsre_flags], RXF_MULTILINE
    jz .assertion
    mov al, RX_EOLM
.assertion:
    call jsre_emit
    jmp .done
.dot:
    mov al, RX_ANY
    test dword [jsre_flags], RXF_DOTALL
    jz .dot_op
    mov al, RX_ANYNL
.dot_op:
    call jsre_emit
    jmp .quantifier
.class:
    call jsre_class_atom
    jmp .quantifier
.escape:
    call jsre_escape_atom           ; CF=1: an assertion (\b, \B), no quantifier
    jc .done
    jmp .quantifier
.group:
    call jsre_group                 ; CF=1: a lookaround (not quantified here)
    jc .done
.quantifier:
    call jsre_quantifier
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.nothing:
    lea rdi, [jsmsg_rx_nothing]
    jmp jsre_error_throw

; jsre_literal_char: the character at jsre_pos (a UTF-8 sequence) -> CHAR(s)
jsre_literal_char:
    push rax
    push rcx
    push rsi
    mov rsi, [jsre_pos]
    movzx eax, byte [rsi]
    mov ecx, 1
    cmp al, 0xC0
    jb .emit
    inc ecx
    cmp al, 0xE0
    jb .emit
    inc ecx
    cmp al, 0xF0
    jb .emit
    inc ecx
.emit:
    cmp rsi, [jsre_end]
    jae .done
    lodsb
    call jsre_emit_char
    dec ecx
    jnz .emit
.done:
    mov [jsre_pos], rsi
    pop rsi
    pop rcx
    pop rax
    ret

; jsre_emit_char: AL = a byte to match (CHARI for letters under /i)
jsre_emit_char:
    push rax
    test dword [jsre_flags], RXF_ICASE
    jz .plain
    mov ah, al
    or ah, 0x20
    sub ah, 'a'
    cmp ah, 25
    ja .plain
    or al, 0x20
    push rax
    mov al, RX_CHARI
    call jsre_emit
    pop rax
    call jsre_emit
    pop rax
    ret
.plain:
    push rax
    mov al, RX_CHAR
    call jsre_emit
    pop rax
    call jsre_emit
    pop rax
    ret

; jsre_emit_codepoint: EAX = a code point -> CHAR(s) for its UTF-8 bytes
jsre_emit_codepoint:
    push rax
    push rcx
    push rsi
    push rdi
    sub rsp, 8
    mov rdi, rsp
    call jslex_put_utf8
    mov rcx, rdi
    mov rsi, rsp
    sub rcx, rsi
.byte:
    lodsb
    call jsre_emit_char
    dec ecx
    jnz .byte
    add rsp, 8
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsre_group: after '(' -> a capturing, non-capturing or named group (CF=0),
; or a lookaround (CF=1)
; ------------------------------------------------------------------------------
jsre_group:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov rsi, [jsre_pos]
    cmp rsi, [jsre_end]
    jae .unterminated
    cmp byte [rsi], '?'
    jne .capture
    inc rsi
    cmp rsi, [jsre_end]
    jae .bad
    mov al, [rsi]
    inc rsi
    mov [jsre_pos], rsi
    cmp al, ':'
    je .plain
    cmp al, '='
    je .ahead
    cmp al, '!'
    je .not_ahead
    cmp al, '<'
    jne .bad
    cmp rsi, [jsre_end]
    jae .bad
    mov al, [rsi]
    cmp al, '='
    je .behind
    cmp al, '!'
    je .not_behind
    ; (?<name>...: the name was noted by jsre_count_groups
.name:
    cmp rsi, [jsre_end]
    jae .bad
    lodsb
    cmp al, '>'
    jne .name
    mov [jsre_pos], rsi
    jmp .numbered
.capture:
    mov [jsre_pos], rsi
.numbered:
    inc dword [jsre_group_count]
    mov ebx, [jsre_group_count]
    cmp ebx, JSRE_MAX_GROUPS
    ja jsre_too_big
    mov al, RX_SAVE
    call jsre_emit
    lea eax, [rbx + rbx]
    call jsre_emit
    call jsre_disjunction
    call .close
    mov al, RX_SAVE
    call jsre_emit
    lea eax, [rbx + rbx + 1]
    call jsre_emit
    clc
    jmp .out
.plain:
    call jsre_disjunction
    call .close
    clc
    jmp .out
.ahead:
    mov bl, LK_AHEAD
    jmp .look
.not_ahead:
    mov bl, LK_NOT_AHEAD
    jmp .look
.behind:
    mov bl, LK_BEHIND
    jmp .look_behind
.not_behind:
    mov bl, LK_NOT_BEHIND
.look_behind:
    inc qword [jsre_pos]            ; (the = or !)
.look:
    ; LOOK kind len, the sub-program, (ENDAT) MATCH
    mov al, RX_LOOK
    call jsre_emit
    mov al, bl
    call jsre_emit
    mov rdx, [jsre_len]             ; the length goes here
    xor eax, eax
    call jsre_emit32
    call jsre_disjunction
    call .close
    cmp bl, LK_BEHIND
    jb .match
    mov al, RX_ENDAT
    call jsre_emit
.match:
    mov al, RX_MATCH
    call jsre_emit
    mov rax, rdx
    mov rdx, [jsre_len]
    sub rdx, rax
    sub rdx, 4
    call jsre_put32
    stc
.out:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
; .close: the ')'
.close:
    mov rsi, [jsre_pos]
    cmp rsi, [jsre_end]
    jae .unterminated
    cmp byte [rsi], ')'
    jne .unterminated
    inc qword [jsre_pos]
    ret
.unterminated:
    lea rdi, [jsmsg_rx_paren]
    jmp jsre_error_throw
.bad:
    lea rdi, [jsmsg_rx_group]
    jmp jsre_error_throw

; ------------------------------------------------------------------------------
; jsre_quantifier_ahead: at '{' -> CF=1 if it is a quantifier ({n}, {n,},
; {n,m})
; ------------------------------------------------------------------------------
jsre_quantifier_ahead:
    push rax
    push rcx
    push rsi
    mov rsi, [jsre_pos]
    inc rsi
    xor ecx, ecx                    ; digits
.digits:
    cmp rsi, [jsre_end]
    jae .no
    mov al, [rsi]
    sub al, '0'
    cmp al, 9
    ja .after
    inc ecx
    inc rsi
    jmp .digits
.after:
    test ecx, ecx
    jz .no
    cmp byte [rsi], '}'
    je .yes
    cmp byte [rsi], ','
    jne .no
    inc rsi
.more:
    cmp rsi, [jsre_end]
    jae .no
    mov al, [rsi]
    cmp al, '}'
    je .yes
    sub al, '0'
    cmp al, 9
    ja .no
    inc rsi
    jmp .more
.yes:
    pop rsi
    pop rcx
    pop rax
    stc
    ret
.no:
    pop rsi
    pop rcx
    pop rax
    clc
    ret

; jsre_number: RSI = digits -> EAX = their value (capped), RSI past them
jsre_number:
    push rdx
    xor eax, eax
.digit:
    cmp rsi, [jsre_end]
    jae .done
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .done
    imul eax, eax, 10
    add eax, edx
    cmp eax, 100000
    jbe .next
    mov eax, 100000
.next:
    inc rsi
    jmp .digit
.done:
    pop rdx
    ret

; ------------------------------------------------------------------------------
; jsre_quantifier: RBX = where the atom's program starts -> * + ? {n,m}
; (and a lazy ?) applied to it
; ------------------------------------------------------------------------------
jsre_quantifier:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    call jsre_at_end
    jc .none
    mov rsi, [jsre_pos]
    mov al, [rsi]
    xor r8d, r8d                    ; min
    mov r9d, -1                     ; max (-1: no limit)
    cmp al, '*'
    je .one_char
    mov r8d, 1
    cmp al, '+'
    je .one_char
    xor r8d, r8d
    mov r9d, 1
    cmp al, '?'
    je .one_char
    cmp al, '{'
    jne .none
    call jsre_quantifier_ahead
    jnc .none
    inc rsi
    call jsre_number
    mov r8d, eax
    mov r9d, eax
    cmp byte [rsi], ','
    jne .brace_end
    inc rsi
    mov r9d, -1
    cmp byte [rsi], '}'
    je .brace_end
    call jsre_number
    mov r9d, eax
    cmp r9d, r8d
    jb .order
.brace_end:
    inc rsi                         ; '}'
    jmp .lazy
.one_char:
    inc rsi
.lazy:
    xor r10d, r10d                  ; 1 = lazy
    cmp rsi, [jsre_end]
    jae .apply
    cmp byte [rsi], '?'
    jne .apply
    inc rsi
    mov r10d, 1
.apply:
    mov [jsre_pos], rsi
    ; the atom: [RBX, len); taken out, then written back as needed
    mov rcx, [jsre_len]
    sub rcx, rbx                    ; its size
    ; min copies
    mov edx, r8d
    call jsre_repeat                ; RBX = start, RCX = size, EDX = copies more, R8D = min...
.none:
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
.order:
    lea rdi, [jsmsg_rx_range]
    jmp jsre_error_throw

; ------------------------------------------------------------------------------
; jsre_repeat: RBX = the atom's start, RCX = its size (it is the program's
; end), R8D = min, R9D = max (-1 = none), R10D = 1 if lazy -> the atom
; repeated: min copies, then optional ones, or a loop
; ------------------------------------------------------------------------------
jsre_repeat:
    push rax
    push rdx
    push rsi
    push rdi
    push r11
    ; keep a copy of the atom
    lea rsi, [jsre_buf + rbx]
    lea rdi, [abs jsre_atom]
    push rcx
    rep movsb
    pop rcx
    mov [jsre_len], rbx             ; the atom is taken out
    ; min copies
    mov r11d, r8d
.min:
    test r11d, r11d
    jz .optional
    call .copy
    dec r11d
    jmp .min
.optional:
    cmp r9d, -1
    je .star
    mov r11d, r9d
    sub r11d, r8d                   ; optional copies
.opt:
    test r11d, r11d
    jz .done
    ; SPLIT(atom, past it) atom
    mov al, RX_SPLIT
    call jsre_emit
    xor eax, eax
    mov edx, ecx                    ; to skip the atom
    test r10d, r10d
    jz .greedy_opt
    xchg eax, edx
.greedy_opt:
    call jsre_emit32
    mov eax, edx
    call jsre_emit32
    call .copy
    dec r11d
    jmp .opt
.star:
    ; L: SPLIT(body, exit) MARK r atom CHECK r JMP L
    mov r11d, [jsre_regs]
    inc dword [jsre_regs]
    cmp r11d, 0xFFFF
    ja jsre_too_big
    mov al, RX_SPLIT
    call jsre_emit
    lea edx, [ecx + 3 + 3 + 5]      ; past MARK, the atom, CHECK, JMP
    xor eax, eax
    test r10d, r10d
    jz .greedy_star
    xchg eax, edx
.greedy_star:
    call jsre_emit32
    mov eax, edx
    call jsre_emit32
    mov al, RX_MARK
    call jsre_emit
    mov eax, r11d
    call jsre_emit16
    call .copy
    mov al, RX_CHECK
    call jsre_emit
    mov eax, r11d
    call jsre_emit16
    mov al, RX_JMP
    call jsre_emit
    lea eax, [ecx + 3 + 3 + 5 + 9]
    neg eax                         ; back to the SPLIT
    call jsre_emit32
.done:
    pop r11
    pop rdi
    pop rsi
    pop rdx
    pop rax
    ret
; .copy: the kept atom (RCX bytes) appended
.copy:
    push rcx
    push rsi
    push rdi
    mov rdi, [jsre_len]
    lea rax, [rdi + rcx]
    cmp rax, JSRE_MAX_PROG
    jae jsre_too_big
    mov [jsre_len], rax
    lea rdi, [jsre_buf + rdi]
    lea rsi, [abs jsre_atom]
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; Classes: [...] and \d \w \s. A class is built in jsre_class (flags, 16
; bytes of ASCII bits, range count, ranges), then emitted as RX_CLASS.
; ------------------------------------------------------------------------------

; jsre_class_begin: an empty class in jsre_class; RDI = where ranges go
jsre_class_begin:
    push rax
    push rcx
    lea rdi, [jsre_class]
    mov ecx, RXC_RANGES
    xor eax, eax
    rep stosb
    pop rcx
    pop rax
    ret

; jsre_class_add: EAX = low, EDX = high code point -> in the class (RDI =
; where the next range goes); letters in both cases under /i
jsre_class_add:
    push rax
    push rcx
    push rdx
.ascii:
    cmp eax, 0x80
    jae .ranges
    cmp eax, edx
    ja .out
    bts [jsre_class + RXC_BITS], eax
    test dword [jsre_flags], RXF_ICASE
    jz .next
    mov ecx, eax
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 25
    ja .next
    mov ecx, eax
    xor ecx, 0x20                   ; the other case
    bts [jsre_class + RXC_BITS], ecx
.next:
    inc eax
    jmp .ascii
.ranges:
    cmp eax, edx
    ja .out
    lea rcx, [jsre_class + JSRE_MAX_CLASS - 8]
    cmp rdi, rcx
    jae jsre_too_big
    mov [rdi], eax
    mov [rdi + 4], edx
    add rdi, 8
    inc word [jsre_class + RXC_NRANGES]
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; jsre_class_emit: RDI = past the class -> RX_CLASS with it
jsre_class_emit:
    push rax
    push rcx
    push rsi
    mov al, RX_CLASS
    call jsre_emit
    mov rcx, rdi
    lea rsi, [jsre_class]
    sub rcx, rsi
    mov eax, ecx
    call jsre_emit16
.byte:
    lodsb
    call jsre_emit
    dec ecx
    jnz .byte
    pop rsi
    pop rcx
    pop rax
    ret

; jsre_class_shorthand: AL = d, D, w, W, s or S -> added to the class being
; built (the capital letters: everything else)
jsre_class_shorthand:
    push rax
    push rbx
    push rdx
    push rsi
    mov bl, al
    or al, 0x20
    lea rsi, [jsre_digit_ranges]
    cmp al, 'd'
    je .ranges
    lea rsi, [jsre_word_ranges]
    cmp al, 'w'
    je .ranges
    lea rsi, [jsre_space_ranges]
    cmp bl, 's'
    je .ranges
    lea rsi, [jsre_not_space_ranges]
    jmp .add
.ranges:
    cmp bl, 'a'
    jae .add                        ; \d \w \s
    ; \D \W: their ASCII complement and all of the rest
    lea rsi, [jsre_not_digit_ranges]
    cmp al, 'd'
    je .add
    lea rsi, [jsre_not_word_ranges]
.add:
    mov eax, [rsi]
    cmp eax, -1
    je .done
    mov edx, [rsi + 4]
    call jsre_class_add
    add rsi, 8
    jmp .add
.done:
    pop rsi
    pop rdx
    pop rbx
    pop rax
    ret

; jsre_class_atom: after '[' -> RX_CLASS
jsre_class_atom:
    push rax
    push rbx
    push rdx
    push rsi
    push rdi
    call jsre_class_begin
    mov rsi, [jsre_pos]
    cmp rsi, [jsre_end]
    jae .unterminated
    cmp byte [rsi], '^'
    jne .items
    inc rsi
    or byte [jsre_class], 1         ; negated
.items:
    cmp rsi, [jsre_end]
    jae .unterminated
    cmp byte [rsi], ']'
    je .end
    call .member                    ; EAX = code point (or -1: a shorthand, added)
    cmp eax, -1
    je .items
    mov edx, eax
    ; a range a-b?
    lea rax, [rsi + 1]
    cmp rax, [jsre_end]
    jae .single
    cmp byte [rsi], '-'
    jne .single
    cmp byte [rsi + 1], ']'
    je .single
    inc rsi
    push rdx
    call .member
    pop rbx
    cmp eax, -1
    je .dash                        ; a-\d: a, '-', then the shorthand
    cmp eax, ebx
    jb .order
    mov edx, eax
    mov eax, ebx
    call jsre_class_add
    jmp .items
.dash:
    mov eax, ebx
    mov edx, ebx
    call jsre_class_add
    mov eax, '-'
    mov edx, eax
.single:
    mov eax, edx
    call jsre_class_add
    jmp .items
.end:
    inc rsi
    mov [jsre_pos], rsi
    call jsre_class_emit
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    pop rax
    ret
.unterminated:
    lea rdi, [jsmsg_rx_class]
    jmp jsre_error_throw
.order:
    lea rdi, [jsmsg_rx_range]
    jmp jsre_error_throw
; .member: RSI = a class member -> EAX = its code point, or -1 if it was a
; shorthand (already added); RSI past it
.member:
    movzx eax, byte [rsi]
    cmp al, '\'
    je .member_escape
    cmp al, 0x80
    jb .one_byte
    call jsre_decode_utf8           ; RSI -> EAX, RSI past it
    ret
.one_byte:
    inc rsi
    ret
.member_escape:
    inc rsi
    cmp rsi, [jsre_end]
    jae .unterminated
    movzx eax, byte [rsi]
    mov bl, al
    or bl, 0x20
    cmp bl, 'd'
    je .shorthand
    cmp bl, 'w'
    je .shorthand
    cmp bl, 's'
    je .shorthand
    cmp al, 'b'
    jne .other_escape
    inc rsi
    mov eax, 8                      ; [\b] is a backspace
    ret
.shorthand:
    inc rsi
    call jsre_class_shorthand
    mov eax, -1
    ret
.other_escape:
    mov [jsre_pos], rsi
    call jsre_char_escape           ; -> EAX, jsre_pos past it
    mov rsi, [jsre_pos]
    ret

; jsre_decode_utf8: RSI = a UTF-8 sequence -> EAX = its code point, RSI past it
jsre_decode_utf8:
    push rcx
    push rdx
    movzx eax, byte [rsi]
    inc rsi
    mov ecx, 0
    cmp al, 0xC0
    jb .done
    mov edx, eax
    and eax, 0x1F
    mov ecx, 1
    cmp dl, 0xE0
    jb .more
    and eax, 0x0F
    mov ecx, 2
    cmp dl, 0xF0
    jb .more
    and eax, 0x07
    mov ecx, 3
.more:
    test ecx, ecx
    jz .done
    cmp rsi, [jsre_end]
    jae .done
    shl eax, 6
    movzx edx, byte [rsi]
    and edx, 0x3F
    or eax, edx
    inc rsi
    dec ecx
    jmp .more
.done:
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------------------------
; jsre_char_escape: jsre_pos after '\' at a character escape -> EAX = its
; code point: \n \r \t \v \f \0 \xHH \uHHHH \u{H...} \cX, or the character
; itself
; ------------------------------------------------------------------------------
jsre_char_escape:
    push rcx
    push rdx
    push rsi
    mov rsi, [jsre_pos]
    movzx eax, byte [rsi]
    inc rsi
    mov edx, 10
    cmp al, 'n'
    je .value
    mov edx, 13
    cmp al, 'r'
    je .value
    mov edx, 9
    cmp al, 't'
    je .value
    mov edx, 11
    cmp al, 'v'
    je .value
    mov edx, 12
    cmp al, 'f'
    je .value
    xor edx, edx
    cmp al, '0'
    je .value
    cmp al, 'x'
    je .hex2
    cmp al, 'u'
    je .unicode
    cmp al, 'c'
    je .control
    cmp al, 0x80
    jb .self
    dec rsi
    call jsre_decode_utf8
    mov edx, eax
    jmp .value
.self:
    mov edx, eax
.value:
    mov [jsre_pos], rsi
    mov eax, edx
    pop rsi
    pop rdx
    pop rcx
    ret
.hex2:
    mov ecx, 2
    call .hex
    jmp .value
.unicode:
    cmp rsi, [jsre_end]
    jae .self_u
    cmp byte [rsi], '{'
    je .braces
    mov ecx, 4
    call .hex
    jmp .value
.braces:
    inc rsi
    xor edx, edx
.brace_digit:
    cmp rsi, [jsre_end]
    jae .value
    movzx eax, byte [rsi]
    inc rsi
    cmp al, '}'
    je .value
    call .hex_digit
    jc .value
    shl edx, 4
    or edx, eax
    jmp .brace_digit
.self_u:
    mov edx, 'u'
    jmp .value
.control:
    cmp rsi, [jsre_end]
    jae .self_c
    movzx edx, byte [rsi]
    inc rsi
    and edx, 31
    jmp .value
.self_c:
    mov edx, 'c'
    jmp .value
; .hex: ECX digits at RSI -> EDX (a bad digit: the escape is the letter)
.hex:
    xor edx, edx
.hex_loop:
    cmp rsi, [jsre_end]
    jae .hex_done
    movzx eax, byte [rsi]
    call .hex_digit
    jc .hex_done
    shl edx, 4
    or edx, eax
    inc rsi
    dec ecx
    jnz .hex_loop
.hex_done:
    ret
.hex_digit:
    sub al, '0'
    cmp al, 9
    jbe .digit_ok
    or al, 0x20
    sub al, 'a' - '0'
    cmp al, 5
    ja .no_digit
    add al, 10
.digit_ok:
    movzx eax, al
    clc
    ret
.no_digit:
    stc
    ret

; ------------------------------------------------------------------------------
; jsre_escape_atom: after '\' outside a class -> the atom (CF=0), or an
; assertion \b \B (CF=1)
; ------------------------------------------------------------------------------
jsre_escape_atom:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rsi, [jsre_pos]
    cmp rsi, [jsre_end]
    jae .bad
    movzx eax, byte [rsi]
    cmp al, 'b'
    je .wordb
    cmp al, 'B'
    je .nwordb
    mov bl, al
    or bl, 0x20
    cmp bl, 'd'
    je .shorthand
    cmp bl, 'w'
    je .shorthand
    cmp bl, 's'
    je .shorthand
    cmp al, 'k'
    je .named_ref
    cmp al, '1'
    jb .char
    cmp al, '9'
    ja .char
    ; \1 .. \99: a backreference (if there are that many groups)
    push rsi
    call jsre_number
    mov ecx, eax
    pop rdx
    cmp ecx, [jsre_total]
    ja .octal
    mov [jsre_pos], rsi
    jmp .backref
.octal:
    mov rsi, rdx                    ; not a group: the digit itself
    jmp .char
.named_ref:
    ; \k<name>
    lea rdx, [rsi + 1]
    cmp rdx, [jsre_end]
    jae .char
    cmp byte [rdx], '<'
    jne .char
    inc rdx
    mov rsi, rdx
.name_end:
    cmp rsi, [jsre_end]
    jae .bad_name
    cmp byte [rsi], '>'
    je .name_found
    inc rsi
    jmp .name_end
.name_found:
    mov rcx, rsi
    sub rcx, rdx
    inc rsi
    mov [jsre_pos], rsi
    push rsi
    mov rsi, rdx
    call jsstr_atom
    pop rsi
    ; which group has that name?
    mov rdi, [jsre_names]
    test rdi, rdi
    jz .bad_name
    xor ecx, ecx
.find_name:
    cmp ecx, [rdi + JARR_LEN]
    jae .bad_name
    mov rdx, [rdi + JARR_ELEMS]
    mov rdx, [rdx + rcx*8]
    cmp edx, eax
    je .backref
    inc ecx
    jmp .find_name
.backref:
    mov al, RX_BACKREF
    test dword [jsre_flags], RXF_ICASE
    jz .backref_op
    mov al, RX_BACKREFI
.backref_op:
    call jsre_emit
    mov eax, ecx
    call jsre_emit
    clc
    jmp .out
.wordb:
    inc rsi
    mov [jsre_pos], rsi
    mov al, RX_WORDB
    call jsre_emit
    stc
    jmp .out
.nwordb:
    inc rsi
    mov [jsre_pos], rsi
    mov al, RX_NWORDB
    call jsre_emit
    stc
    jmp .out
.shorthand:
    inc rsi
    mov [jsre_pos], rsi
    call jsre_class_begin
    call jsre_class_shorthand
    call jsre_class_emit
    clc
    jmp .out
.char:
    mov [jsre_pos], rsi
    call jsre_char_escape
    call jsre_emit_codepoint
    clc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.bad:
    lea rdi, [jsmsg_rx_escape]
    jmp jsre_error_throw
.bad_name:
    lea rdi, [jsmsg_rx_name]
    jmp jsre_error_throw

section .rodata
align 4
; code point ranges, -1 ends a list
jsre_digit_ranges:      dd '0', '9', -1
jsre_word_ranges:       dd '0', '9', 'A', 'Z', '_', '_', 'a', 'z', -1
jsre_space_ranges:      dd 9, 13, ' ', ' ', 0xA0, 0xA0, 0x1680, 0x1680, 0x2000, 0x200A
                        dd 0x2028, 0x2029, 0x202F, 0x202F, 0x205F, 0x205F, 0x3000, 0x3000
                        dd 0xFEFF, 0xFEFF, -1
jsre_not_digit_ranges:  dd 0, '0' - 1, '9' + 1, 0x10FFFF, -1
jsre_not_word_ranges:   dd 0, '0' - 1, '9' + 1, 'A' - 1, 'Z' + 1, '_' - 1, '_' + 1, 'a' - 1
                        dd 'z' + 1, 0x10FFFF, -1
jsre_not_space_ranges:  dd 0, 8, 14, 31, 33, 0x9F, 0xA1, 0x167F, 0x1681, 0x1FFF
                        dd 0x200B, 0x2027, 0x202A, 0x202E, 0x2030, 0x205E, 0x2060, 0x2FFF
                        dd 0x3001, 0xFEFE, 0xFF00, 0x10FFFF, -1
section .text

; ==============================================================================
; The matcher
; ==============================================================================

; ------------------------------------------------------------------------------
; jsre_match: RBX = program, RSI = input (first byte), RCX = its length,
; EDX = the start offset, R8D = flags, R9D = groups -> CF=0 if it matches
; there (sticky) or later (otherwise): the captures (byte offsets, -1 = none)
; are at JS_RX_ADDR + RX_CAPS, 2 per group, group 0 the whole match
; ------------------------------------------------------------------------------
jsre_match:
    push rax
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
    push r14
    push r15
    mov [jsre_in], rsi
    lea rax, [rsi + rcx]
    mov [jsre_in_end], rax
    xor eax, eax
    test r8d, RXF_ICASE
    setnz al
    mov [jsre_icase], al
    mov dword [jsre_steps], 0
    lea r15d, [r9 + r9 + 2]         ; capture slots
    mov r14d, edx                   ; the start
.start:
    ; every capture unset
    mov rdi, JS_RX_ADDR + RX_CAPS
    mov ecx, r15d
    mov rax, -1
    rep stosq
    mov rsi, rbx
    mov rdi, [jsre_in]
    add rdi, r14
    mov r13, JS_RX_ADDR + RX_STACK  ; the backtrack stack is empty
    mov r12, r13
    call jsre_run
    jnc .matched
    test r8d, RXF_STICKY
    jnz .fail
    ; the next start: past this character
    mov rax, [jsre_in]
    add rax, r14
    cmp rax, [jsre_in_end]
    jae .fail
    movzx eax, byte [rax]
    inc r14d
    cmp al, 0xC0
    jb .start
.continuation:
    mov rax, [jsre_in]
    add rax, r14
    cmp rax, [jsre_in_end]
    jae .fail
    mov al, [rax]
    and al, 0xC0
    cmp al, 0x80
    jne .start
    inc r14d
    jmp .continuation
.matched:
    clc
    jmp .out
.fail:
    stc
.out:
    pop r15
    pop r14
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
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsre_run: RSI = pc, RDI = input position, R13 = the backtrack stack's base
; for this run (entries below belong to an outer run), R12 = its top ->
; CF=0 at RX_MATCH (RDI = where it ended; the run's alternatives are gone
; from the stack, its capture undo records kept), CF=1 if it cannot match
; (the stack back at R13, captures restored). Clobbers RAX, RCX, RDX, R9-R11.
; ------------------------------------------------------------------------------
jsre_run:
.step:
    inc dword [jsre_steps]
    test dword [jsre_steps], 0xFFFFF
    jnz .go
    call vm_check_budget            ; (Esc / Ctrl+C, the desktop)
.go:
    movzx eax, byte [rsi]
    inc rsi
    cmp eax, RX_ENDAT
    ja .fail
    jmp [jsre_ops + rax*8]

.char:
    cmp rdi, [jsre_in_end]
    jae .fail
    mov al, [rsi]
    inc rsi
    cmp [rdi], al
    jne .fail
    inc rdi
    jmp .step
.chari:
    cmp rdi, [jsre_in_end]
    jae .fail
    mov al, [rsi]
    inc rsi
    mov ah, [rdi]
    mov cl, ah
    or cl, 0x20
    sub cl, 'a'
    cmp cl, 25
    ja .chari_cmp
    or ah, 0x20
.chari_cmp:
    cmp ah, al
    jne .fail
    inc rdi
    jmp .step
.any:
    cmp rdi, [jsre_in_end]
    jae .fail
    call jsre_line_break
    jc .fail
    call jsre_next_char
    jmp .step
.anynl:
    cmp rdi, [jsre_in_end]
    jae .fail
    call jsre_next_char
    jmp .step
.class:
    movzx ecx, word [rsi]           ; its size
    add rsi, 2
    cmp rdi, [jsre_in_end]
    jae .fail
    push rsi
    push rcx
    call jsre_class_match           ; RSI = class, RDI = input -> CF=1, RDI past it
    pop rcx
    pop rsi
    jnc .fail
    add rsi, rcx
    jmp .step
.bol:
    cmp rdi, [jsre_in]
    jne .fail
    jmp .step
.eol:
    cmp rdi, [jsre_in_end]
    jne .fail
    jmp .step
.bolm:
    cmp rdi, [jsre_in]
    je .step
    dec rdi
    call jsre_line_break
    lea rdi, [rdi + 1]
    jnc .fail
    jmp .step
.eolm:
    cmp rdi, [jsre_in_end]
    je .step
    call jsre_line_break
    jnc .fail
    jmp .step
.wordb:
    call jsre_at_word_boundary
    jnc .fail
    jmp .step
.nwordb:
    call jsre_at_word_boundary
    jc .fail
    jmp .step
.split:
    ; the second choice for later, the first now
    movsxd rax, dword [rsi]
    movsxd rcx, dword [rsi + 4]
    add rsi, 8
    lea rdx, [rsi + rcx]
    mov r9d, RXB_ALT
    mov r10, rdx
    mov r11, rdi
    call .push
    add rsi, rax
    jmp .step
.jmp:
    movsxd rax, dword [rsi]
    add rsi, 4
    add rsi, rax
    jmp .step
.save:
    movzx eax, byte [rsi]
    inc rsi
    mov r9d, RXB_CAP
    mov r10, rax
    mov rcx, JS_RX_ADDR + RX_CAPS
    mov r11, [rcx + rax*8]
    call .push
    mov rdx, rdi
    sub rdx, [jsre_in]
    mov [rcx + rax*8], rdx
    jmp .step
.mark:
    movzx eax, word [rsi]
    add rsi, 2
    mov r9d, RXB_REG
    mov r10, rax
    mov rcx, JS_RX_ADDR + RX_REGS
    mov r11, [rcx + rax*8]
    call .push
    mov [rcx + rax*8], rdi
    jmp .step
.check:
    movzx eax, word [rsi]
    add rsi, 2
    mov rcx, JS_RX_ADDR + RX_REGS
    cmp [rcx + rax*8], rdi
    je .fail                        ; a pass that matched nothing: no more
    jmp .step
.backref:
    xor edx, edx
    jmp .backref_common
.backrefi:
    mov edx, 1
.backref_common:
    movzx eax, byte [rsi]
    inc rsi
    call jsre_backref               ; EAX = group, EDX = any case -> CF=1 if it failed
    jc .fail
    jmp .step
.look:
    movzx edx, byte [rsi]
    mov ecx, [rsi + 1]
    add rsi, 5
    call jsre_look                  ; RSI = the sub-program, EDX = kind -> CF=1 fail
    jc .fail
    add rsi, rcx
    jmp .step
.endat:
    cmp rdi, [jsre_behind]
    jne .fail
    jmp .step
.match:
    ; keep the capture undo records, drop this run's alternatives
    mov rax, r13
    mov rcx, r13
.keep:
    cmp rax, r12
    jae .kept
    cmp qword [rax], RXB_ALT
    je .skip
    mov rdx, [rax]
    mov [rcx], rdx
    mov rdx, [rax + 8]
    mov [rcx + 8], rdx
    mov rdx, [rax + 16]
    mov [rcx + 16], rdx
    add rcx, 24
.skip:
    add rax, 24
    jmp .keep
.kept:
    mov r12, rcx
    clc
    ret
.fail:
    ; back to the latest alternative, undoing captures on the way
    cmp r12, r13
    jbe .no_match
    sub r12, 24
    mov rax, [r12]
    cmp eax, RXB_ALT
    je .alternative
    mov rcx, [r12 + 8]
    mov rdx, [r12 + 16]
    mov r9, JS_RX_ADDR + RX_CAPS
    cmp eax, RXB_CAP
    je .undo
    mov r9, JS_RX_ADDR + RX_REGS
.undo:
    mov [r9 + rcx*8], rdx
    jmp .fail
.alternative:
    mov rsi, [r12 + 8]
    mov rdi, [r12 + 16]
    jmp .step
.no_match:
    stc
    ret
; .push: R9 = kind, R10, R11 -> onto the backtrack stack
.push:
    push rax
    mov rax, JS_RX_ADDR + JS_RX_SIZE - 24
    cmp r12, rax
    jae .overflow
    mov [r12], r9
    mov [r12 + 8], r10
    mov [r12 + 16], r11
    add r12, 24
    pop rax
    ret
.overflow:
    lea rsi, [jsmsg_rx_stack]
    xor edi, edi
    mov edx, JE_RANGE
    jmp js_throw

section .rodata
align 8
jsre_ops:
    dq jsre_run.fail, jsre_run.char, jsre_run.chari, jsre_run.any, jsre_run.anynl
    dq jsre_run.class, jsre_run.bol, jsre_run.eol, jsre_run.bolm, jsre_run.eolm
    dq jsre_run.wordb, jsre_run.nwordb, jsre_run.split, jsre_run.jmp, jsre_run.save
    dq jsre_run.backref, jsre_run.backrefi, jsre_run.look, jsre_run.mark, jsre_run.check
    dq jsre_run.match, jsre_run.endat
section .text

; jsre_line_break: RDI = input position (inside it) -> CF=1 if a line break
; starts there (\n, \r, U+2028, U+2029)
jsre_line_break:
    push rax
    mov al, [rdi]
    cmp al, 10
    je .yes
    cmp al, 13
    je .yes
    cmp al, 0xE2
    jne .no
    lea rax, [rdi + 2]
    cmp rax, [jsre_in_end]
    jae .no
    cmp byte [rdi + 1], 0x80
    jne .no
    mov al, [rdi + 2]
    cmp al, 0xA8
    je .yes
    cmp al, 0xA9
    je .yes
.no:
    pop rax
    clc
    ret
.yes:
    pop rax
    stc
    ret

; jsre_next_char: RDI = input position -> past its character (UTF-8)
jsre_next_char:
    push rax
    movzx eax, byte [rdi]
    inc rdi
    cmp al, 0xC0
    jb .done
.more:
    cmp rdi, [jsre_in_end]
    jae .done
    mov al, [rdi]
    and al, 0xC0
    cmp al, 0x80
    jne .done
    inc rdi
    jmp .more
.done:
    pop rax
    ret

; jsre_char_at: RDI = input position -> EAX = the code point there, RDI past it
jsre_char_at:
    push rcx
    push rdx
    movzx eax, byte [rdi]
    inc rdi
    cmp al, 0xC0
    jb .done
    mov ecx, 1
    mov edx, eax
    and eax, 0x1F
    cmp dl, 0xE0
    jb .more
    and eax, 0x0F
    inc ecx
    cmp dl, 0xF0
    jb .more
    and eax, 0x07
    inc ecx
.more:
    cmp rdi, [jsre_in_end]
    jae .done
    movzx edx, byte [rdi]
    mov dh, dl
    and dh, 0xC0
    cmp dh, 0x80
    jne .done
    and edx, 0x3F
    shl eax, 6
    or eax, edx
    inc rdi
    dec ecx
    jnz .more
.done:
    pop rdx
    pop rcx
    ret

; jsre_class_match: RSI = a class, RDI = input position -> CF=1 (RDI past
; the character) if the character there is in it
jsre_class_match:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    call jsre_char_at               ; EAX = code point, RDI past it
    xor edx, edx                    ; 1 = in the class
    cmp eax, 0x80
    jae .ranges
    bt [rsi + RXC_BITS], eax
    jnc .result
    mov edx, 1
    jmp .result
.ranges:
    movzx ecx, word [rsi + RXC_NRANGES]
    lea rbx, [rsi + RXC_RANGES]
.range:
    test ecx, ecx
    jz .result
    cmp eax, [rbx]
    jb .next
    cmp eax, [rbx + 4]
    ja .next
    mov edx, 1
    jmp .result
.next:
    add rbx, 8
    dec ecx
    jmp .range
.result:
    test byte [rsi], 1
    jz .check
    xor edx, 1                      ; negated
.check:
    test edx, edx
    jz .no
    add rsp, 8                      ; (keep RDI past the character)
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret
.no:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret

; jsre_is_word: AL = a byte -> CF=1 for [A-Za-z0-9_]
jsre_is_word:
    push rax
    cmp al, '_'
    je .yes
    mov ah, al
    sub ah, '0'
    cmp ah, 9
    jbe .yes
    or al, 0x20
    sub al, 'a'
    cmp al, 25
    jbe .yes
    pop rax
    clc
    ret
.yes:
    pop rax
    stc
    ret

; jsre_at_word_boundary: RDI = input position -> CF=1 if a word character
; is on exactly one side
jsre_at_word_boundary:
    push rax
    push rcx
    xor ecx, ecx
    cmp rdi, [jsre_in]
    je .after
    mov al, [rdi - 1]
    call jsre_is_word
    adc ecx, 0
.after:
    cmp rdi, [jsre_in_end]
    jae .decide
    mov al, [rdi]
    call jsre_is_word
    jnc .decide
    xor ecx, 1
.decide:
    test ecx, ecx
    pop rcx
    pop rax
    jz .no
    stc
    ret
.no:
    clc
    ret

; jsre_backref: EAX = group, EDX = 1 for any case, RDI = input position ->
; CF=0 and RDI past it if the group's text is there (an unset group matches
; nothing, which always works)
jsre_backref:
    push rax
    push rbx
    push rcx
    push rsi
    mov rbx, JS_RX_ADDR + RX_CAPS
    shl eax, 4
    mov rsi, [rbx + rax]
    mov rcx, [rbx + rax + 8]
    cmp rsi, -1
    je .ok
    cmp rcx, -1
    je .ok
    sub rcx, rsi
    jle .ok
    add rsi, [jsre_in]
    lea rax, [rdi + rcx]
    cmp rax, [jsre_in_end]
    ja .fail
.byte:
    mov al, [rsi]
    mov ah, [rdi]
    cmp al, ah
    je .same
    test edx, edx
    jz .fail
    or ax, 0x2020
    cmp al, ah
    jne .fail
    sub al, 'a'
    cmp al, 25
    ja .fail
.same:
    inc rsi
    inc rdi
    dec rcx
    jnz .byte
.ok:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    clc
    ret
.fail:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; jsre_look: RSI = a lookaround's sub-program, EDX = LK_*, RDI = position ->
; CF=0 if the assertion holds (RDI unchanged); RCX is kept
; ------------------------------------------------------------------------------
jsre_look:
    push rcx
    push rsi
    push rdi
    push r13
    push qword [jsre_behind]
    mov r13, r12                    ; a run of its own above this one's records
    cmp edx, LK_BEHIND
    jae .behind
    call jsre_run
    jmp .result
.behind:
    ; some start before here from which it ends exactly here
    mov [jsre_behind], rdi
    mov rcx, rdi
.try:
    mov rdi, rcx
    push rcx
    push rsi
    call jsre_run
    pop rsi
    pop rcx
    jnc .result
    cmp rcx, [jsre_in]
    jbe .none
    dec rcx
    jmp .try
.none:
    stc
.result:
    ; CF=0: it matched. Negative kinds want the opposite.
    setc al                         ; 1 = did not match
    cmp edx, LK_NOT_AHEAD
    je .negative
    cmp edx, LK_NOT_BEHIND
    jne .done                       ; positive: it holds if it matched
.negative:
    xor al, 1                       ; 1 = it fails (the inside matched)
    jz .done
    call jsre_unwind                ; and what it captured goes
.done:
    pop qword [jsre_behind]
    pop r13
    pop rdi
    pop rsi
    pop rcx
    shr al, 1                       ; CF = the assertion fails
    ret

; jsre_unwind: R12 = stack top, R13 = the base to go back to -> records above
; it popped, their captures and registers restored
jsre_unwind:
    push rax
    push rcx
    push rdx
    push r9
.pop:
    cmp r12, r13
    jbe .done
    sub r12, 24
    mov rax, [r12]
    cmp eax, RXB_ALT
    je .pop
    mov rcx, [r12 + 8]
    mov rdx, [r12 + 16]
    mov r9, JS_RX_ADDR + RX_CAPS
    cmp eax, RXB_CAP
    je .undo
    mov r9, JS_RX_ADDR + RX_REGS
.undo:
    mov [r9 + rcx*8], rdx
    jmp .pop
.done:
    pop r9
    pop rdx
    pop rcx
    pop rax
    ret
