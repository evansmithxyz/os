; ==============================================================================
; Antigravity OS - JavaScript parser
; ------------------------------------------------------------------------------
; Recursive descent over the lexer's tokens; expressions use precedence
; climbing. Builds a syntax tree in the JS_AST_ADDR arena and records every
; declaration in a scope record, so the compiler can resolve each name to a
; stack slot, a captured (heap) variable or a global.
;
;   jsp_parse_script: RSI = source, RCX = length -> RAX = script function info
;
; Nodes are JN_SIZE bytes; lists (statements, arguments, elements) are linked
; through JN_NEXT. Parse routines return the node in RAX and preserve every
; other register. Errors throw a SyntaxError (js_throw).
; ==============================================================================

[bits 64]

; --- Syntax tree nodes --------------------------------------------------------
JN_TYPE                 equ 0           ; byte, NT_*
JN_OP                   equ 1           ; byte, operator (P_*, KW_*, ...)
JN_FLAGS                equ 2           ; word
JN_LINE                 equ 4           ; dword
JN_A                    equ 8
JN_B                    equ 16
JN_C                    equ 24
JN_D                    equ 32
JN_NEXT                 equ 40
JN_E                    equ 48
JN_SIZE                 equ 56

NT_NUM                  equ 1           ; A = double bits
NT_STR                  equ 2           ; A = atom
NT_IDENT                equ 3           ; A = atom
NT_THIS                 equ 4
NT_NULL                 equ 5
NT_TRUE                 equ 6
NT_FALSE                equ 7
NT_ARRAY                equ 8           ; A = first element
NT_HOLE                 equ 9           ; [1, , 3]
NT_OBJECT               equ 10          ; A = first NT_PROP
NT_PROP                 equ 11          ; OP 0: A = key atom, OP 1: A = key expression; B = value
NT_FUNC                 equ 12          ; A = function info
NT_UNARY                equ 13          ; OP = P_NOT/P_TILDE/P_PLUS/P_MINUS or KW_TYPEOF/KW_VOID/KW_DELETE
NT_UPDATE               equ 14          ; OP = UPD_*, A = target
NT_BINARY               equ 15          ; OP = P_* or OPB_IN/OPB_INSTANCEOF; A, B
NT_LOGICAL              equ 16          ; OP = P_AND/P_OR/P_NULLISH; A, B
NT_COND                 equ 17          ; A ? B : C
NT_ASSIGN               equ 18          ; OP = P_ASSIGN or P_*_ASSIGN; A = target, B = value
NT_SEQ                  equ 19          ; A, B
NT_MEMBER               equ 20          ; A.B (B = atom)
NT_INDEX                equ 21          ; A[B]
NT_CALL                 equ 22          ; A(B...), C = argument count
NT_NEW                  equ 23          ; new A(B...), C = argument count
NT_VAR                  equ 30          ; OP = KW_VAR/KW_LET/KW_CONST, A = first NT_DECL
NT_DECL                 equ 31          ; A = atom, B = initialiser or 0
NT_EXPR                 equ 32          ; A = expression
NT_BLOCK                equ 33          ; A = first statement, E = scope
NT_IF                   equ 34          ; A = test, B = then, C = else or 0
NT_WHILE                equ 35          ; A = test, B = body
NT_DOWHILE              equ 36          ; A = body, B = test
NT_FOR                  equ 37          ; A = init, B = test, C = update, D = body, E = scope
NT_FORIN                equ 38          ; OP 0 in / 1 of; A = NT_VAR or target, B = object, D = body, E = scope
NT_RETURN               equ 39          ; A = value or 0
NT_BREAK                equ 40          ; A = label atom or 0
NT_CONTINUE             equ 41          ; A = label atom or 0
NT_EMPTY                equ 42
NT_FUNCDECL             equ 43          ; A = function info
NT_SWITCH               equ 44          ; A = discriminant, B = first NT_CASE, E = scope
NT_CASE                 equ 45          ; A = test (0 = default), B = first statement
NT_THROW                equ 46          ; A = value
NT_LABELED              equ 47          ; A = label atom, B = statement

UPD_PREINC              equ 0
UPD_PREDEC              equ 1
UPD_POSTINC             equ 2
UPD_POSTDEC             equ 3
OPB_IN                  equ 100
OPB_INSTANCEOF          equ 101

; --- Scopes, variables, functions ---------------------------------------------
JSC_PARENT              equ 0           ; enclosing scope (across functions)
JSC_FUNC                equ 8           ; function info it belongs to
JSC_VARS                equ 16          ; first JVR record
JSC_NVARS               equ 24          ; dword
JSC_KIND                equ 28          ; byte, SK_*
JSC_ENV                 equ 29          ; byte, 1 = makes a heap env at run time (compiler)
JSC_NEXT                equ 32          ; next scope of the same function
JSC_SIZE                equ 40
SK_FUNC                 equ 1
SK_BLOCK                equ 2

JVR_NEXT                equ 0
JVR_NAME                equ 8           ; atom
JVR_KIND                equ 16          ; byte, VK_*
JVR_SLOT                equ 20          ; dword, stack slot or env index (compiler)
JVR_SIZE                equ 24
VK_VAR                  equ 1
VK_LET                  equ 2
VK_CONST                equ 3
VK_PARAM                equ 4
VK_FUNC                 equ 5
VK_ARGS                 equ 6           ; `arguments`
VK_SELF                 equ 7           ; a function expression's own name

JFI_PARENT              equ 0
JFI_SCOPE               equ 8           ; function scope
JFI_BODY                equ 16          ; first statement
JFI_NAME                equ 24          ; atom or 0
JFI_FLAGS               equ 32          ; dword, FIF_*
JFI_NPARAMS             equ 36          ; dword
JFI_LINE                equ 40          ; dword
JFI_NLOCALS             equ 44          ; dword (compiler)
JFI_SCOPES              equ 48          ; first scope (linked through JSC_NEXT)
JFI_LAST_SCOPE          equ 56
JFI_TEMPLATE            equ 64          ; the compiled JK_CODE (compiler)
JFI_GLOBALS             equ 72          ; script: JVR list of top-level declarations
JFI_NGLOBALS            equ 80          ; dword (JFI_GLOBALS works as a scope's JSC_VARS)
JFI_SIZE                equ 88
FIF_INNER               equ 1           ; contains function definitions
FIF_ARGS                equ 2           ; uses `arguments`
FIF_SELF                equ 4           ; named function expression
FIF_SCRIPT              equ 8           ; the top-level script

JSP_MAX_DEPTH           equ 1500        ; nesting limit (~250 bytes of kernel stack each)

; AT_PUNCT id: ZF=1 when the current token is that punctuator
%macro AT_PUNCT 1
    cmp dword [tok_type], TK_PUNCT
    jne %%no
    cmp qword [tok_val], %1
%%no:
%endmacro

; AT_KW id: ZF=1 when the current token is that keyword
%macro AT_KW 1
    cmp dword [tok_kw], %1
%endmacro

; EXPECT id: consume the punctuator or throw "Unexpected token"
%macro EXPECT 1
    AT_PUNCT %1
    jne jsp_unexpected
    call jslex_next
%endmacro

section .bss
alignb 8
jsp_arena:              resq 1
jsp_func:               resq 1          ; current function info
jsp_scope:              resq 1          ; current scope
jsp_depth:              resd 1
jsp_no_in:              resd 1          ; 1 = `in` is not an operator (for-init)

section .rodata
jsmsg_unexpected:       db "Unexpected token '%'", 0
jsmsg_unexpected_end:   db "Unexpected end of input", 0
jsmsg_too_deep:         db "Too deeply nested", 0
jsmsg_too_big:          db "Script is too large", 0
jsmsg_bad_target:       db "Invalid left-hand side in assignment", 0
jsmsg_bad_return:       db "Illegal return statement", 0
jsmsg_too_many_args:    db "Too many arguments (255 at most)", 0
jsmsg_unsupported:      db "% is not supported yet", 0
jsmsg_need_name:        db "Function statements require a function name", 0
jsmsg_default_twice:    db "More than one default clause in switch statement", 0
jsfeat_arrow:           db "=> (arrow functions)", 0
jsfeat_template:        db "`template literals`", 0
jsfeat_regex:           db "/regular expressions/", 0
jsfeat_class:           db "class", 0
jsfeat_try:             db "try/catch", 0
jsfeat_spread:          db "... (spread)", 0
jsfeat_destructuring:   db "destructuring", 0
jsfeat_optional:        db "?. (optional chaining)", 0
jsfeat_accessor:        db "get/set accessors", 0
jsfeat_module:          db "import/export", 0
jsfeat_with:            db "with", 0
jsfeat_super:           db "super", 0
jsfeat_private:         db "#private fields", 0
jsfeat_decorator:       db "@decorators", 0
jsfeat_default_param:   db "default parameters", 0
jsfeat_get:             db "get", 0
jsfeat_set:             db "set", 0

section .text

; ------------------------------------------------------------------------------
; jsp_parse_script: RSI = source, RCX = length -> RAX = script function info
; ------------------------------------------------------------------------------
jsp_parse_script:
    push rbx
    mov qword [jsp_arena], JS_AST_ADDR
    mov qword [jsp_func], 0
    mov qword [jsp_scope], 0
    mov dword [jsp_depth], 0
    mov dword [jsp_no_in], 0
    call jsp_new_func
    mov rbx, rax
    or dword [rbx + JFI_FLAGS], FIF_SCRIPT
    mov dword [rbx + JFI_LINE], 1
    call jslex_init
.body:
    call jsp_statement_list
    cmp dword [tok_type], TK_EOF
    jne jsp_unexpected
    mov [rbx + JFI_BODY], rax
    mov rax, rbx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; Allocation
; ------------------------------------------------------------------------------

; jsp_alloc: ECX = bytes (multiple of 8) -> RAX = zeroed block in the arena
jsp_alloc:
    push rcx
    push rdi
    mov rax, [jsp_arena]
    lea rdi, [rax + rcx]
    mov rcx, JS_AST_ADDR + JS_AST_SIZE
    cmp rdi, rcx
    ja .full
    mov [jsp_arena], rdi
    mov rcx, rdi
    sub rcx, rax
    shr ecx, 3
    mov rdi, rax
    push rax
    xor eax, eax
    rep stosq
    pop rax
    pop rdi
    pop rcx
    ret
.full:
    lea rsi, [jsmsg_too_big]
    jmp jslex_error

; jsp_node: AL = node type -> RAX = new node on the current token's line
jsp_node:
    push rcx
    push rdx
    movzx edx, al
    mov ecx, JN_SIZE
    call jsp_alloc
    mov [rax + JN_TYPE], dl
    mov edx, [tok_line]
    mov [rax + JN_LINE], edx
    pop rdx
    pop rcx
    ret

; jsp_new_func: -> RAX = function info with its function scope, made current.
; Marks the enclosing function as having inner functions.
jsp_new_func:
    push rbx
    push rcx
    mov ecx, JFI_SIZE
    call jsp_alloc
    mov rbx, rax
    mov rcx, [jsp_func]
    mov [rbx + JFI_PARENT], rcx
    test rcx, rcx
    jz .top
    or dword [rcx + JFI_FLAGS], FIF_INNER
.top:
    mov ecx, [tok_line]
    mov [rbx + JFI_LINE], ecx
    mov [jsp_func], rbx
    mov al, SK_FUNC
    call jsp_push_scope
    mov [rbx + JFI_SCOPE], rax
    mov rax, rbx
    pop rcx
    pop rbx
    ret

; jsp_push_scope: AL = SK_* -> RAX = new scope inside the current one (current
; function), made current
jsp_push_scope:
    push rbx
    push rcx
    push rdx
    movzx edx, al
    mov ecx, JSC_SIZE
    call jsp_alloc
    mov [rax + JSC_KIND], dl
    mov rcx, [jsp_scope]
    mov [rax + JSC_PARENT], rcx
    mov rbx, [jsp_func]
    mov [rax + JSC_FUNC], rbx
    mov rcx, [rbx + JFI_LAST_SCOPE]
    test rcx, rcx
    jz .first
    mov [rcx + JSC_NEXT], rax
    jmp .linked
.first:
    mov [rbx + JFI_SCOPES], rax
.linked:
    mov [rbx + JFI_LAST_SCOPE], rax
    mov [jsp_scope], rax
    pop rdx
    pop rcx
    pop rbx
    ret

; jsp_pop_scope: back to the enclosing scope
jsp_pop_scope:
    push rax
    mov rax, [jsp_scope]
    mov rax, [rax + JSC_PARENT]
    mov [jsp_scope], rax
    pop rax
    ret

; jsp_scope_find: RBX = scope, RDX = atom -> RAX = variable record, CF=0 if found
jsp_scope_find:
    mov rax, [rbx + JSC_VARS]
.loop:
    test rax, rax
    jz .missing
    cmp [rax + JVR_NAME], rdx
    je .found
    mov rax, [rax + JVR_NEXT]
    jmp .loop
.found:
    clc
    ret
.missing:
    stc
    ret

; jsp_scope_add: RBX = scope, RDX = atom, CL = VK_* -> RAX = its variable
; (an existing one with that name is reused)
jsp_scope_add:
    call jsp_scope_find
    jnc .done
    push rcx
    push rdx
    mov ecx, JVR_SIZE
    call jsp_alloc
    pop rdx
    pop rcx
    mov [rax + JVR_NAME], rdx
    mov [rax + JVR_KIND], cl
    ; append (declaration order = slot order, parameters first)
    push rsi
    lea rsi, [rbx + JSC_VARS - JVR_NEXT]
.tail:
    cmp qword [rsi + JVR_NEXT], 0
    je .append
    mov rsi, [rsi + JVR_NEXT]
    jmp .tail
.append:
    mov [rsi + JVR_NEXT], rax
    pop rsi
    inc dword [rbx + JSC_NVARS]
.done:
    ret

; ------------------------------------------------------------------------------
; jsp_declare: RDX = atom, CL = VK_* kind. var/function/params go to the
; function scope, let/const to the current block. At the script's top level
; var, function, let and const are global properties and not recorded.
; ------------------------------------------------------------------------------
jsp_declare:
    push rax
    push rbx
    mov rax, [jsp_func]
    mov rbx, [jsp_scope]
    cmp cl, VK_LET
    je .block
    cmp cl, VK_CONST
    je .block
    cmp cl, VK_FUNC
    je .block                       ; function declarations bind in their block
    mov rbx, [rax + JFI_SCOPE]
.block:
    test dword [rax + JFI_FLAGS], FIF_SCRIPT
    jz .add
    cmp rbx, [rax + JFI_SCOPE]
    je .global                      ; top level of the script: global
.add:
    call jsp_scope_add
.out:
    pop rbx
    pop rax
    ret
.global:
    ; remember it: the script defines it (as undefined) before running
    lea rbx, [rax + JFI_GLOBALS - JSC_VARS]
    call jsp_scope_add
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; Errors
; ------------------------------------------------------------------------------

; jsp_unexpected: "Unexpected token 'x'" for the current token
jsp_unexpected:
    cmp dword [tok_type], TK_EOF
    je .end
    mov rsi, [tok_start]
    mov rcx, [jslex_pos]
    sub rcx, rsi
    cmp rcx, 40
    jbe .len
    mov ecx, 40
.len:
    call jsstr_new
    mov rdi, rax
    lea rsi, [jsmsg_unexpected]
    jmp jsp_error_detail
.end:
    lea rsi, [jsmsg_unexpected_end]
    jmp jslex_error

; jsp_unsupported: RDI = feature text -> "<feature> is not supported yet"
jsp_unsupported:
    mov rsi, rdi
    call jsstr_from_cstr
    mov rdi, rax
    lea rsi, [jsmsg_unsupported]
jsp_error_detail:
    mov eax, [tok_line]
    mov [vm_line], eax
    mov edx, JE_SYNTAX
    jmp js_throw

; jsp_enter: nesting check (call at the start of recursive rules)
jsp_enter:
    inc dword [jsp_depth]
    cmp dword [jsp_depth], JSP_MAX_DEPTH
    ja .deep
    ret
.deep:
    lea rsi, [jsmsg_too_deep]
    jmp jslex_error

jsp_leave:
    dec dword [jsp_depth]
    ret

; jsp_semicolon: a `;`, or one inserted before `}`, the end or a line break
jsp_semicolon:
    AT_PUNCT P_SEMI
    je .consume
    AT_PUNCT P_RBRACE
    je .ok
    cmp dword [tok_type], TK_EOF
    je .ok
    cmp byte [tok_nl], 0
    jne .ok
    jmp jsp_unexpected
.consume:
    call jslex_next
.ok:
    ret

; jsp_ident: the current token must be a non-keyword name -> RAX = atom
jsp_ident:
    cmp dword [tok_type], TK_NAME
    jne .bad
    cmp dword [tok_kw], 0
    je .ok
    cmp dword [tok_kw], KW_LET      ; `let` is fine as a plain name here
    jne .bad
.ok:
    mov rax, [tok_val]
    call jslex_next
    ret
.bad:
    AT_PUNCT P_LBRACE
    je .destructure
    AT_PUNCT P_LBRACK
    je .destructure
    jmp jsp_unexpected
.destructure:
    lea rdi, [jsfeat_destructuring]
    jmp jsp_unsupported

; ==============================================================================
; Statements
; ==============================================================================

; jsp_statement_list: statements up to `}` / `case` / `default` / the end
; -> RAX = first statement (0 if none)
jsp_statement_list:
    push rbx
    push rcx
    xor ebx, ebx                    ; first
    xor ecx, ecx                    ; last
.loop:
    cmp dword [tok_type], TK_EOF
    je .done
    AT_PUNCT P_RBRACE
    je .done
    AT_KW KW_CASE
    je .done
    AT_KW KW_DEFAULT
    je .done
    call jsp_statement
    test rcx, rcx
    jz .first
    mov [rcx + JN_NEXT], rax
    jmp .linked
.first:
    mov rbx, rax
.linked:
    mov rcx, rax
    jmp .loop
.done:
    mov rax, rbx
    pop rcx
    pop rbx
    ret

; jsp_statement -> RAX = statement node
jsp_statement:
    call jsp_enter
    call jsp_statement_inner
    call jsp_leave
    ret

jsp_statement_inner:
    cmp dword [tok_type], TK_PUNCT
    jne .not_punct
    AT_PUNCT P_LBRACE
    je jsp_block
    AT_PUNCT P_SEMI
    je .empty
    jmp jsp_expression_statement
.not_punct:
    cmp dword [tok_type], TK_NAME
    jne jsp_expression_statement
    mov eax, [tok_kw]
    cmp eax, KW_VAR
    je .var
    cmp eax, KW_LET
    je .var
    cmp eax, KW_CONST
    je .var
    cmp eax, KW_FUNCTION
    je jsp_function_declaration
    cmp eax, KW_IF
    je jsp_if
    cmp eax, KW_FOR
    je jsp_for
    cmp eax, KW_WHILE
    je jsp_while
    cmp eax, KW_DO
    je jsp_do
    cmp eax, KW_RETURN
    je jsp_return
    cmp eax, KW_BREAK
    je .break
    cmp eax, KW_CONTINUE
    je .continue
    cmp eax, KW_THROW
    je jsp_throw
    cmp eax, KW_SWITCH
    je jsp_switch
    cmp eax, KW_TRY
    je .try
    cmp eax, KW_CLASS
    je .class
    cmp eax, KW_IMPORT
    je .module
    cmp eax, KW_EXPORT
    je .module
    cmp eax, KW_WITH
    je .with
    cmp eax, KW_DEBUGGER
    je .debugger
    test eax, eax
    jnz jsp_expression_statement
    ; name ':' -> labelled statement
    call jslex_peek
    cmp dword [peek_type], TK_PUNCT
    jne jsp_expression_statement
    cmp qword [peek_val], P_COLON
    jne jsp_expression_statement
    jmp jsp_labeled
.var:
    call jslex_next
    call jsp_declarations           ; EAX still = the keyword
    call jsp_semicolon
    ret
.empty:
    mov al, NT_EMPTY
    call jsp_node
    call jslex_next
    ret
.debugger:
    mov al, NT_EMPTY
    call jsp_node
    call jslex_next
    call jsp_semicolon
    ret
.break:
    mov al, NT_BREAK
    jmp .jump
.continue:
    mov al, NT_CONTINUE
.jump:
    call jsp_node
    push rbx
    mov rbx, rax
    call jslex_next
    cmp byte [tok_nl], 0
    jne .jump_done
    cmp dword [tok_type], TK_NAME
    jne .jump_done
    cmp dword [tok_kw], 0
    jne .jump_done
    call jsp_ident
    mov [rbx + JN_A], rax
.jump_done:
    call jsp_semicolon
    mov rax, rbx
    pop rbx
    ret
.try:
    lea rdi, [jsfeat_try]
    jmp jsp_unsupported
.class:
    lea rdi, [jsfeat_class]
    jmp jsp_unsupported
.module:
    lea rdi, [jsfeat_module]
    jmp jsp_unsupported
.with:
    lea rdi, [jsfeat_with]
    jmp jsp_unsupported

; jsp_expression_statement: expression ';'
jsp_expression_statement:
    push rbx
    mov al, NT_EXPR
    call jsp_node
    mov rbx, rax
    call jsp_expression
    mov [rbx + JN_A], rax
    call jsp_semicolon
    mov rax, rbx
    pop rbx
    ret

; jsp_block: '{' statements '}' with its own scope
jsp_block:
    push rbx
    mov al, NT_BLOCK
    call jsp_node
    mov rbx, rax
    call jslex_next
    mov al, SK_BLOCK
    call jsp_push_scope
    mov [rbx + JN_E], rax
    call jsp_statement_list
    mov [rbx + JN_A], rax
    EXPECT P_RBRACE
    call jsp_pop_scope
    mov rax, rbx
    pop rbx
    ret

; jsp_labeled: name ':' statement
jsp_labeled:
    push rbx
    mov al, NT_LABELED
    call jsp_node
    mov rbx, rax
    mov rax, [tok_val]
    mov [rbx + JN_A], rax
    call jslex_next                 ; the name
    call jslex_next                 ; ':'
    call jsp_statement
    mov [rbx + JN_B], rax
    mov rax, rbx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; jsp_declarations: EAX = KW_VAR/KW_LET/KW_CONST (keyword already consumed)
; -> RAX = NT_VAR node with its NT_DECLs; each name is declared
; ------------------------------------------------------------------------------
jsp_declarations:
    push rbx
    push rcx
    push rdx
    push r8
    mov edx, eax
    mov al, NT_VAR
    call jsp_node
    mov rbx, rax
    mov [rbx + JN_OP], dl
    mov cl, VK_VAR
    cmp edx, KW_LET
    jne .not_let
    mov cl, VK_LET
.not_let:
    cmp edx, KW_CONST
    jne .kind
    mov cl, VK_CONST
.kind:
    xor r8d, r8d                    ; last declarator
.decl:
    mov al, NT_DECL
    call jsp_node
    push rax
    call jsp_ident
    mov rdx, rax
    pop rax
    mov [rax + JN_A], rdx
    call jsp_declare
    test r8, r8
    jz .first
    mov [r8 + JN_NEXT], rax
    jmp .linked
.first:
    mov [rbx + JN_A], rax
.linked:
    mov r8, rax
    AT_PUNCT P_ASSIGN
    jne .next
    call jslex_next
    call jsp_assign
    mov [r8 + JN_B], rax
.next:
    AT_PUNCT P_COMMA
    jne .done
    call jslex_next
    jmp .decl
.done:
    mov rax, rbx
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; jsp_if: if (test) statement [else statement]
jsp_if:
    push rbx
    mov al, NT_IF
    call jsp_node
    mov rbx, rax
    call jslex_next
    EXPECT P_LPAREN
    call jsp_expression
    mov [rbx + JN_A], rax
    EXPECT P_RPAREN
    call jsp_statement
    mov [rbx + JN_B], rax
    AT_KW KW_ELSE
    jne .done
    call jslex_next
    call jsp_statement
    mov [rbx + JN_C], rax
.done:
    mov rax, rbx
    pop rbx
    ret

; jsp_while: while (test) statement
jsp_while:
    push rbx
    mov al, NT_WHILE
    call jsp_node
    mov rbx, rax
    call jslex_next
    EXPECT P_LPAREN
    call jsp_expression
    mov [rbx + JN_A], rax
    EXPECT P_RPAREN
    call jsp_statement
    mov [rbx + JN_B], rax
    mov rax, rbx
    pop rbx
    ret

; jsp_do: do statement while (test) [;]
jsp_do:
    push rbx
    mov al, NT_DOWHILE
    call jsp_node
    mov rbx, rax
    call jslex_next
    call jsp_statement
    mov [rbx + JN_A], rax
    AT_KW KW_WHILE
    jne jsp_unexpected
    call jslex_next
    EXPECT P_LPAREN
    call jsp_expression
    mov [rbx + JN_B], rax
    EXPECT P_RPAREN
    AT_PUNCT P_SEMI
    jne .done
    call jslex_next
.done:
    mov rax, rbx
    pop rbx
    ret

; jsp_return: return [value] ;
jsp_return:
    push rbx
    mov rax, [jsp_func]
    test dword [rax + JFI_FLAGS], FIF_SCRIPT
    jnz .illegal
    mov al, NT_RETURN
    call jsp_node
    mov rbx, rax
    call jslex_next
    AT_PUNCT P_SEMI
    je .done
    AT_PUNCT P_RBRACE
    je .done
    cmp dword [tok_type], TK_EOF
    je .done
    cmp byte [tok_nl], 0
    jne .done
    call jsp_expression
    mov [rbx + JN_A], rax
.done:
    call jsp_semicolon
    mov rax, rbx
    pop rbx
    ret
.illegal:
    lea rsi, [jsmsg_bad_return]
    jmp jslex_error

; jsp_throw: throw value ;
jsp_throw:
    push rbx
    mov al, NT_THROW
    call jsp_node
    mov rbx, rax
    call jslex_next
    call jsp_expression
    mov [rbx + JN_A], rax
    call jsp_semicolon
    mov rax, rbx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; jsp_for: for (init; test; update) body | for (x in obj) body | for (x of arr) body
; ------------------------------------------------------------------------------
jsp_for:
    push rbx
    push rcx
    push rdx
    mov al, NT_FOR
    call jsp_node
    mov rbx, rax
    call jslex_next
    EXPECT P_LPAREN
    ; let/const in the head get their own scope around the loop
    AT_KW KW_LET
    je .scoped
    AT_KW KW_CONST
    jne .init
.scoped:
    mov al, SK_BLOCK
    call jsp_push_scope
    mov [rbx + JN_E], rax
.init:
    AT_PUNCT P_SEMI
    je .classic_no_init
    mov eax, [tok_kw]
    cmp eax, KW_VAR
    je .decl
    cmp eax, KW_LET
    je .decl
    cmp eax, KW_CONST
    je .decl
    ; expression (or the target of for-in/of)
    mov dword [jsp_no_in], 1
    call jsp_expression
    mov dword [jsp_no_in], 0
    mov rdx, rax
    call .in_or_of
    jnc .forin_target
    mov al, NT_EXPR
    call jsp_node
    mov [rax + JN_A], rdx
    mov [rbx + JN_A], rax
    jmp .classic
.decl:
    call jslex_next
    mov dword [jsp_no_in], 1
    call jsp_declarations
    mov dword [jsp_no_in], 0
    mov [rbx + JN_A], rax
    call .in_or_of
    jnc .forin
    jmp .classic
.classic_no_init:
.classic:
    EXPECT P_SEMI
    AT_PUNCT P_SEMI
    je .no_test
    call jsp_expression
    mov [rbx + JN_B], rax
.no_test:
    EXPECT P_SEMI
    AT_PUNCT P_RPAREN
    je .no_update
    call jsp_expression
    mov [rbx + JN_C], rax
.no_update:
    EXPECT P_RPAREN
    jmp .body
.forin_target:
    ; the target must be assignable
    movzx eax, byte [rdx + JN_TYPE]
    cmp eax, NT_IDENT
    je .target_ok
    cmp eax, NT_MEMBER
    je .target_ok
    cmp eax, NT_INDEX
    jne .bad_target
.target_ok:
    mov [rbx + JN_A], rdx
.forin:
    mov byte [rbx + JN_TYPE], NT_FORIN
    mov [rbx + JN_OP], cl
    call jslex_next                 ; in / of
    test cl, cl
    jnz .of
    call jsp_expression
    jmp .forin_close
.of:
    call jsp_assign
.forin_close:
    mov [rbx + JN_B], rax
    EXPECT P_RPAREN
.body:
    call jsp_statement
    mov [rbx + JN_D], rax
    cmp qword [rbx + JN_E], 0
    je .done
    call jsp_pop_scope
.done:
    mov rax, rbx
    pop rdx
    pop rcx
    pop rbx
    ret
.bad_target:
    lea rsi, [jsmsg_bad_target]
    jmp jslex_error

; .in_or_of: CF=0 with CL = 0 (in) / 1 (of) when the token is `in` or `of`
.in_or_of:
    xor ecx, ecx
    AT_KW KW_IN
    je .yes
    cmp dword [tok_type], TK_NAME
    jne .no
    mov rax, [tok_val]
    cmp rax, [atom_of]
    jne .no
    mov cl, 1
.yes:
    clc
    ret
.no:
    stc
    ret

; ------------------------------------------------------------------------------
; jsp_switch: switch (value) { case x: ... default: ... }
; ------------------------------------------------------------------------------
jsp_switch:
    push rbx
    push rcx
    push rdx
    mov al, NT_SWITCH
    call jsp_node
    mov rbx, rax
    call jslex_next
    EXPECT P_LPAREN
    call jsp_expression
    mov [rbx + JN_A], rax
    EXPECT P_RPAREN
    EXPECT P_LBRACE
    mov al, SK_BLOCK
    call jsp_push_scope
    mov [rbx + JN_E], rax
    xor ecx, ecx                    ; last case
    xor edx, edx                    ; saw default
.case:
    AT_PUNCT P_RBRACE
    je .end
    mov al, NT_CASE
    call jsp_node
    test rcx, rcx
    jz .first
    mov [rcx + JN_NEXT], rax
    jmp .linked
.first:
    mov [rbx + JN_B], rax
.linked:
    mov rcx, rax
    AT_KW KW_CASE
    je .test
    AT_KW KW_DEFAULT
    jne jsp_unexpected
    test edx, edx
    jnz .twice
    mov edx, 1
    call jslex_next
    jmp .colon
.test:
    call jslex_next
    call jsp_expression
    mov [rcx + JN_A], rax
.colon:
    EXPECT P_COLON
    call jsp_statement_list
    mov [rcx + JN_B], rax
    jmp .case
.end:
    call jslex_next
    call jsp_pop_scope
    mov rax, rbx
    pop rdx
    pop rcx
    pop rbx
    ret
.twice:
    lea rsi, [jsmsg_default_twice]
    jmp jslex_error

; ------------------------------------------------------------------------------
; Functions
; ------------------------------------------------------------------------------

; jsp_function_declaration: function name(params) { body }
jsp_function_declaration:
    push rbx
    push rcx
    push rdx
    mov al, NT_FUNCDECL
    call jsp_node
    mov rbx, rax
    call jslex_next                 ; `function`
    AT_PUNCT P_STAR
    je .generator
    cmp dword [tok_type], TK_NAME
    jne .no_name
    call jsp_ident
    mov rdx, rax
    mov cl, VK_FUNC
    call jsp_declare
    xor ecx, ecx                    ; not an expression
    call jsp_function_rest
    mov [rbx + JN_A], rax
    mov rax, rbx
    pop rdx
    pop rcx
    pop rbx
    ret
.no_name:
    lea rsi, [jsmsg_need_name]
    jmp jslex_error
.generator:
    lea rdi, [jsfeat_generator]
    jmp jsp_unsupported

; jsp_function_rest: RDX = name atom (or 0), ECX = 1 for a function expression;
; the current token is '('. -> RAX = function info
jsp_function_rest:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, [jsp_func]              ; restore afterwards
    mov r9, [jsp_scope]
    push qword [jsp_no_in]
    mov dword [jsp_no_in], 0
    call jsp_new_func
    mov rbx, rax
    mov [rbx + JFI_NAME], rdx
    mov rsi, rdx                    ; name
    mov edi, ecx                    ; expression?
    ; parameters
    EXPECT P_LPAREN
.param:
    AT_PUNCT P_RPAREN
    je .params_done
    AT_PUNCT P_ELLIPSIS
    je .rest_param
    call jsp_ident
    mov rdx, rax
    mov cl, VK_PARAM
    call jsp_declare
    inc dword [rbx + JFI_NPARAMS]
    AT_PUNCT P_ASSIGN
    je .default_param
    AT_PUNCT P_RPAREN
    je .params_done
    EXPECT P_COMMA
    jmp .param
.params_done:
    call jslex_next
    ; body
    EXPECT P_LBRACE
    call jsp_statement_list
    mov [rbx + JFI_BODY], rax
    AT_PUNCT P_RBRACE
    jne jsp_unexpected
    ; a named function expression sees its own name (unless shadowed)
    test edi, edi
    jz .no_self
    test rsi, rsi
    jz .no_self
    push rbx
    mov rbx, [rbx + JFI_SCOPE]
    mov rdx, rsi
    call jsp_scope_find
    pop rbx
    jnc .no_self
    push rbx
    mov rbx, [rbx + JFI_SCOPE]
    mov cl, VK_SELF
    call jsp_scope_add
    pop rbx
    or dword [rbx + JFI_FLAGS], FIF_SELF
.no_self:
    call jslex_next                 ; '}' (after the scope work: it may read a regex-free token)
    pop qword [jsp_no_in]
    mov [jsp_func], r8
    mov [jsp_scope], r9
    mov rax, rbx
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.rest_param:
    lea rdi, [jsfeat_spread]
    jmp jsp_unsupported
.default_param:
    lea rdi, [jsfeat_default_param]
    jmp jsp_unsupported

; ==============================================================================
; Expressions
; ==============================================================================

; jsp_expression: assignment (',' assignment)* -> RAX
jsp_expression:
    push rbx
    call jsp_assign
.loop:
    AT_PUNCT P_COMMA
    jne .done
    mov rbx, rax
    mov al, NT_SEQ
    call jsp_node
    mov [rax + JN_A], rbx
    mov rbx, rax
    call jslex_next
    call jsp_assign
    mov [rbx + JN_B], rax
    mov rax, rbx
    jmp .loop
.done:
    pop rbx
    ret

; jsp_assign: conditional [assignment-operator assign] -> RAX
jsp_assign:
    call jsp_enter
    push rbx
    push rcx
    call jsp_conditional
    cmp dword [tok_type], TK_PUNCT
    jne .done
    mov rcx, [tok_val]
    cmp ecx, P_ARROW
    je .arrow
    cmp ecx, P_ASSIGN
    je .assign
    cmp ecx, P_ADD_ASSIGN
    jb .done
    cmp ecx, P_NULLISH_ASSIGN
    ja .done
.assign:
    movzx ebx, byte [rax + JN_TYPE]
    cmp ebx, NT_IDENT
    je .target_ok
    cmp ebx, NT_MEMBER
    je .target_ok
    cmp ebx, NT_INDEX
    je .target_ok
    cmp ebx, NT_ARRAY
    je .destructure
    cmp ebx, NT_OBJECT
    je .destructure
    lea rsi, [jsmsg_bad_target]
    jmp jslex_error
.target_ok:
    mov rbx, rax
    mov al, NT_ASSIGN
    call jsp_node
    mov [rax + JN_OP], cl
    mov [rax + JN_A], rbx
    mov rbx, rax
    call jslex_next
    call jsp_assign
    mov [rbx + JN_B], rax
    mov rax, rbx
.done:
    pop rcx
    pop rbx
    call jsp_leave
    ret
.arrow:
    lea rdi, [jsfeat_arrow]
    jmp jsp_unsupported
.destructure:
    lea rdi, [jsfeat_destructuring]
    jmp jsp_unsupported

; jsp_conditional: binary ['?' assign ':' assign] -> RAX
jsp_conditional:
    push rbx
    push rcx
    xor ecx, ecx
    call jsp_binary
    AT_PUNCT P_QUESTION
    jne .done
    mov rbx, rax
    mov al, NT_COND
    call jsp_node
    mov [rax + JN_A], rbx
    mov rbx, rax
    call jslex_next
    push qword [jsp_no_in]
    mov dword [jsp_no_in], 0
    call jsp_assign
    pop qword [jsp_no_in]
    mov [rbx + JN_B], rax
    EXPECT P_COLON
    call jsp_assign
    mov [rbx + JN_C], rax
    mov rax, rbx
.done:
    pop rcx
    pop rbx
    ret

; jsp_binary_prec: current token -> EAX = precedence (0 = not a binary
; operator), EDX = operator id for the node
jsp_binary_prec:
    xor eax, eax
    cmp dword [tok_type], TK_PUNCT
    je .punct
    cmp dword [tok_type], TK_NAME
    jne .ret
    mov edx, [tok_kw]
    cmp edx, KW_INSTANCEOF
    je .instanceof
    cmp edx, KW_IN
    jne .ret
    cmp dword [jsp_no_in], 0
    jne .ret
    mov edx, OPB_IN
    mov eax, 8
    ret
.instanceof:
    mov edx, OPB_INSTANCEOF
    mov eax, 8
    ret
.punct:
    mov rdx, [tok_val]
    cmp edx, P_NULLISH
    je .p1
    cmp edx, P_OR
    je .p2
    cmp edx, P_AND
    je .p3
    cmp edx, P_PIPE
    je .p4
    cmp edx, P_CARET
    je .p5
    cmp edx, P_AMP
    je .p6
    cmp edx, P_EQ
    je .p7
    cmp edx, P_NE
    je .p7
    cmp edx, P_SEQ
    je .p7
    cmp edx, P_SNE
    je .p7
    cmp edx, P_LT
    je .p8
    cmp edx, P_LE
    je .p8
    cmp edx, P_GT
    je .p8
    cmp edx, P_GE
    je .p8
    cmp edx, P_SHL
    je .p9
    cmp edx, P_SAR
    je .p9
    cmp edx, P_SHR
    je .p9
    cmp edx, P_PLUS
    je .p10
    cmp edx, P_MINUS
    je .p10
    cmp edx, P_STAR
    je .p11
    cmp edx, P_SLASH
    je .p11
    cmp edx, P_PERCENT
    je .p11
    cmp edx, P_STARSTAR
    je .p12
.ret:
    ret
.p1:
    mov eax, 1
    ret
.p2:
    mov eax, 2
    ret
.p3:
    mov eax, 3
    ret
.p4:
    mov eax, 4
    ret
.p5:
    mov eax, 5
    ret
.p6:
    mov eax, 6
    ret
.p7:
    mov eax, 7
    ret
.p8:
    mov eax, 8
    ret
.p9:
    mov eax, 9
    ret
.p10:
    mov eax, 10
    ret
.p11:
    mov eax, 11
    ret
.p12:
    mov eax, 12
    ret

; jsp_binary: ECX = minimum precedence -> RAX (precedence climbing)
jsp_binary:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    mov r8d, ecx
    call jsp_unary
    mov rbx, rax                    ; left
.loop:
    call jsp_binary_prec
    test eax, eax
    jz .done
    cmp eax, r8d
    jb .done
    mov r9d, eax
    mov al, NT_BINARY
    cmp edx, P_AND
    je .logical
    cmp edx, P_OR
    je .logical
    cmp edx, P_NULLISH
    jne .node
.logical:
    mov al, NT_LOGICAL
.node:
    call jsp_node
    mov [rax + JN_OP], dl
    mov [rax + JN_A], rbx
    mov rbx, rax
    call jslex_next
    lea ecx, [r9 + 1]               ; left-associative
    cmp r9d, 12
    jne .right
    mov ecx, r9d                    ; ** is right-associative
.right:
    call jsp_binary
    mov [rbx + JN_B], rax
    jmp .loop
.done:
    mov rax, rbx
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; jsp_unary: prefix operators -> RAX
jsp_unary:
    call jsp_enter
    push rbx
    push rcx
    cmp dword [tok_type], TK_PUNCT
    je .punct
    mov ecx, [tok_kw]
    cmp ecx, KW_TYPEOF
    je .unary
    cmp ecx, KW_VOID
    je .unary
    cmp ecx, KW_DELETE
    je .unary
    jmp .postfix
.punct:
    mov rcx, [tok_val]
    cmp ecx, P_NOT
    je .unary
    cmp ecx, P_TILDE
    je .unary
    cmp ecx, P_PLUS
    je .unary
    cmp ecx, P_MINUS
    je .unary
    cmp ecx, P_INC
    je .prefix
    cmp ecx, P_DEC
    je .prefix
.postfix:
    call jsp_postfix
    jmp .done
.unary:
    mov al, NT_UNARY
    call jsp_node
    mov [rax + JN_OP], cl
    mov rbx, rax
    call jslex_next
    call jsp_unary
    mov [rbx + JN_A], rax
    mov rax, rbx
    jmp .done
.prefix:
    mov al, NT_UPDATE
    call jsp_node
    mov rbx, rax
    mov byte [rbx + JN_OP], UPD_PREINC
    cmp ecx, P_INC
    je .prefix_op
    mov byte [rbx + JN_OP], UPD_PREDEC
.prefix_op:
    call jslex_next
    call jsp_unary
    call jsp_check_target
    mov [rbx + JN_A], rax
    mov rax, rbx
.done:
    pop rcx
    pop rbx
    call jsp_leave
    ret

; jsp_check_target: RAX = node that must be assignable (name, a.b, a[b])
jsp_check_target:
    cmp byte [rax + JN_TYPE], NT_IDENT
    je .ok
    cmp byte [rax + JN_TYPE], NT_MEMBER
    je .ok
    cmp byte [rax + JN_TYPE], NT_INDEX
    je .ok
    lea rsi, [jsmsg_bad_target]
    jmp jslex_error
.ok:
    ret

; jsp_postfix: left-hand side [++ | --] (no line break before the operator)
jsp_postfix:
    push rbx
    call jsp_call
    cmp byte [tok_nl], 0
    jne .done
    AT_PUNCT P_INC
    je .inc
    AT_PUNCT P_DEC
    jne .done
    mov bl, UPD_POSTDEC
    jmp .update
.inc:
    mov bl, UPD_POSTINC
.update:
    call jsp_check_target
    push rax
    mov al, NT_UPDATE
    call jsp_node
    mov [rax + JN_OP], bl
    pop rbx
    mov [rax + JN_A], rbx
    call jslex_next
.done:
    pop rbx
    ret

; ------------------------------------------------------------------------------
; jsp_call: member accesses, calls and `new` -> RAX
; ------------------------------------------------------------------------------
jsp_call:
    push rbx
    push rcx
    AT_KW KW_NEW
    jne .primary
    call jsp_new
    jmp .suffix
.primary:
    call jsp_primary
.suffix:
    mov rbx, rax
.loop:
    cmp dword [tok_type], TK_PUNCT
    jne .done
    mov rcx, [tok_val]
    cmp ecx, P_DOT
    je .dot
    cmp ecx, P_LBRACK
    je .index
    cmp ecx, P_LPAREN
    je .call
    cmp ecx, P_QDOT
    je .optional
    cmp ecx, P_BACKTICK
    je .template
.done:
    mov rax, rbx
    pop rcx
    pop rbx
    ret
.dot:
    call jsp_member_dot
    jmp .loop
.index:
    call jsp_member_index
    jmp .loop
.call:
    mov al, NT_CALL
    call jsp_node
    mov [rax + JN_A], rbx
    mov rbx, rax
    call jsp_arguments
    jmp .loop
.optional:
    lea rdi, [jsfeat_optional]
    jmp jsp_unsupported
.template:
    lea rdi, [jsfeat_template]
    jmp jsp_unsupported

; jsp_member_dot: RBX = object; current token '.' -> RBX = NT_MEMBER
jsp_member_dot:
    push rax
    call jslex_next
    cmp dword [tok_type], TK_NAME
    je .name
    AT_PUNCT P_HASH
    je .private
    jmp jsp_unexpected
.name:
    mov al, NT_MEMBER
    call jsp_node
    mov [rax + JN_A], rbx
    mov rbx, [tok_val]
    mov [rax + JN_B], rbx
    mov rbx, rax
    call jslex_next
    pop rax
    ret
.private:
    lea rdi, [jsfeat_private]
    jmp jsp_unsupported

; jsp_member_index: RBX = object; current token '[' -> RBX = NT_INDEX
jsp_member_index:
    push rax
    mov al, NT_INDEX
    call jsp_node
    mov [rax + JN_A], rbx
    mov rbx, rax
    call jslex_next
    push qword [jsp_no_in]
    mov dword [jsp_no_in], 0
    call jsp_expression
    pop qword [jsp_no_in]
    mov [rbx + JN_B], rax
    EXPECT P_RBRACK
    pop rax
    ret

; jsp_arguments: RBX = call/new node; current token '(' -> B = arguments, C = count
jsp_arguments:
    push rax
    push rcx
    push rdx
    call jslex_next
    push qword [jsp_no_in]
    mov dword [jsp_no_in], 0
    xor ecx, ecx                    ; last
    xor edx, edx                    ; count
.arg:
    AT_PUNCT P_RPAREN
    je .done
    AT_PUNCT P_ELLIPSIS
    je .spread
    call jsp_assign
    test rcx, rcx
    jz .first
    mov [rcx + JN_NEXT], rax
    jmp .linked
.first:
    mov [rbx + JN_B], rax
.linked:
    mov rcx, rax
    inc edx
    cmp edx, 255
    ja .too_many
    AT_PUNCT P_RPAREN
    je .done
    EXPECT P_COMMA
    jmp .arg
.done:
    mov [rbx + JN_C], rdx
    call jslex_next
    pop qword [jsp_no_in]
    pop rdx
    pop rcx
    pop rax
    ret
.spread:
    lea rdi, [jsfeat_spread]
    jmp jsp_unsupported
.too_many:
    lea rsi, [jsmsg_too_many_args]
    jmp jslex_error

; jsp_new: new Callee[.member][(args)] -> RAX = NT_NEW
jsp_new:
    call jsp_enter
    push rbx
    push rcx
    mov al, NT_NEW
    call jsp_node
    mov rcx, rax
    call jslex_next                 ; `new`
    AT_KW KW_NEW
    jne .callee
    call jsp_new
    jmp .members
.callee:
    AT_PUNCT P_DOT
    je .meta
    call jsp_primary
.members:
    mov rbx, rax
.loop:
    AT_PUNCT P_DOT
    jne .not_dot
    call jsp_member_dot
    jmp .loop
.not_dot:
    AT_PUNCT P_LBRACK
    jne .args
    call jsp_member_index
    jmp .loop
.args:
    mov [rcx + JN_A], rbx
    mov rbx, rcx
    AT_PUNCT P_LPAREN
    jne .done
    call jsp_arguments
.done:
    mov rax, rbx
    pop rcx
    pop rbx
    call jsp_leave
    ret
.meta:
    jmp jsp_unexpected              ; new.target

; ------------------------------------------------------------------------------
; jsp_primary: literals, names, (expression), [array], {object}, function
; ------------------------------------------------------------------------------
jsp_primary:
    push rbx
    push rcx
    push rdx
    mov eax, [tok_type]
    cmp eax, TK_NUM
    je .number
    cmp eax, TK_STR
    je .string
    cmp eax, TK_NAME
    je .name
    cmp eax, TK_PUNCT
    jne jsp_unexpected
    mov rcx, [tok_val]
    cmp ecx, P_LPAREN
    je .paren
    cmp ecx, P_LBRACK
    je .array
    cmp ecx, P_LBRACE
    je .object
    cmp ecx, P_SLASH
    je .regex
    cmp ecx, P_DIV_ASSIGN
    je .regex
    cmp ecx, P_BACKTICK
    je .template
    cmp ecx, P_AT
    je .decorator
    jmp jsp_unexpected
.number:
    mov al, NT_NUM
    jmp .literal
.string:
    mov al, NT_STR
.literal:
    call jsp_node
    mov rcx, [tok_val]
    mov [rax + JN_A], rcx
    jmp .next_done
.name:
    mov ecx, [tok_kw]
    test ecx, ecx
    jz .ident
    cmp ecx, KW_THIS
    je .this
    cmp ecx, KW_NULL
    je .null
    cmp ecx, KW_TRUE
    je .true
    cmp ecx, KW_FALSE
    je .false
    cmp ecx, KW_FUNCTION
    je .function
    cmp ecx, KW_LET
    je .ident
    cmp ecx, KW_CLASS
    je .class
    cmp ecx, KW_SUPER
    je .super
    jmp jsp_unexpected
.this:
    mov al, NT_THIS
    jmp .keyword
.null:
    mov al, NT_NULL
    jmp .keyword
.true:
    mov al, NT_TRUE
    jmp .keyword
.false:
    mov al, NT_FALSE
.keyword:
    call jsp_node
    jmp .next_done
.ident:
    mov al, NT_IDENT
    call jsp_node
    mov rbx, rax
    mov rdx, [tok_val]
    mov [rbx + JN_A], rdx
    call jslex_next
    AT_PUNCT P_ARROW
    je .arrow
    cmp rdx, [atom_arguments]
    jne .ident_done
    call jsp_use_arguments
.ident_done:
    mov rax, rbx
    jmp .done
.function:
    call jslex_next
    AT_PUNCT P_STAR
    je .generator
    xor edx, edx
    cmp dword [tok_type], TK_NAME
    jne .anonymous
    call jsp_ident
    mov rdx, rax
.anonymous:
    mov al, NT_FUNC
    call jsp_node
    mov rbx, rax
    mov ecx, 1
    call jsp_function_rest
    mov [rbx + JN_A], rax
    mov rax, rbx
    jmp .done
.paren:
    call jslex_next
    AT_PUNCT P_RPAREN
    je .arrow                       ; () => ...
    push qword [jsp_no_in]
    mov dword [jsp_no_in], 0
    call jsp_expression
    pop qword [jsp_no_in]
    EXPECT P_RPAREN
    AT_PUNCT P_ARROW
    je .arrow
    jmp .done
.array:
    call jsp_array
    jmp .done
.object:
    call jsp_object
    jmp .done
.next_done:
    call jslex_next
.done:
    pop rdx
    pop rcx
    pop rbx
    ret
.arrow:
    lea rdi, [jsfeat_arrow]
    jmp jsp_unsupported
.regex:
    lea rdi, [jsfeat_regex]
    jmp jsp_unsupported
.template:
    lea rdi, [jsfeat_template]
    jmp jsp_unsupported
.class:
    lea rdi, [jsfeat_class]
    jmp jsp_unsupported
.super:
    lea rdi, [jsfeat_super]
    jmp jsp_unsupported
.decorator:
    lea rdi, [jsfeat_decorator]
    jmp jsp_unsupported
.generator:
    lea rdi, [jsfeat_generator]
    jmp jsp_unsupported

; jsp_use_arguments: the current function reads `arguments`: declare it
jsp_use_arguments:
    push rax
    push rbx
    push rcx
    push rdx
    mov rcx, [jsp_func]
    test dword [rcx + JFI_FLAGS], FIF_SCRIPT
    jnz .done                       ; a global name at the top level
    mov rbx, [rcx + JFI_SCOPE]
    mov rdx, [atom_arguments]
    call jsp_scope_find
    jnc .done                       ; a parameter or variable of that name
    or dword [rcx + JFI_FLAGS], FIF_ARGS
    mov cl, VK_ARGS
    call jsp_scope_add
.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsp_array: '[' elements ']' -> RAX = NT_ARRAY
jsp_array:
    push rbx
    push rcx
    mov al, NT_ARRAY
    call jsp_node
    mov rbx, rax
    call jslex_next
    push qword [jsp_no_in]
    mov dword [jsp_no_in], 0
    xor ecx, ecx                    ; last
.element:
    AT_PUNCT P_RBRACK
    je .done
    AT_PUNCT P_COMMA
    je .hole
    AT_PUNCT P_ELLIPSIS
    je .spread
    call jsp_assign
    jmp .append
.hole:
    mov al, NT_HOLE
    call jsp_node
.append:
    test rcx, rcx
    jz .first
    mov [rcx + JN_NEXT], rax
    jmp .linked
.first:
    mov [rbx + JN_A], rax
.linked:
    mov rcx, rax
    AT_PUNCT P_RBRACK
    je .done
    EXPECT P_COMMA
    jmp .element
.done:
    call jslex_next
    pop qword [jsp_no_in]
    mov rax, rbx
    pop rcx
    pop rbx
    ret
.spread:
    lea rdi, [jsfeat_spread]
    jmp jsp_unsupported

; jsp_object: '{' properties '}' -> RAX = NT_OBJECT
jsp_object:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov al, NT_OBJECT
    call jsp_node
    mov rbx, rax
    call jslex_next
    push qword [jsp_no_in]
    mov dword [jsp_no_in], 0
    xor r8d, r8d                    ; last property
.property:
    AT_PUNCT P_RBRACE
    je .done
    AT_PUNCT P_ELLIPSIS
    je .spread
    mov al, NT_PROP
    call jsp_node
    test r8, r8
    jz .first
    mov [r8 + JN_NEXT], rax
    jmp .linked
.first:
    mov [rbx + JN_A], rax
.linked:
    mov r8, rax
    ; the key
    mov eax, [tok_type]
    cmp eax, TK_NAME
    je .key_name
    cmp eax, TK_STR
    je .key_atom
    cmp eax, TK_NUM
    je .key_number
    AT_PUNCT P_LBRACK
    je .key_computed
    jmp jsp_unexpected
.key_name:
    ; get/set accessors: `get name(` ...
    mov rdx, [tok_val]
    call jslex_peek
    cmp dword [peek_type], TK_NAME
    je .maybe_accessor
    cmp dword [peek_type], TK_STR
    je .maybe_accessor
.key_atom:
    mov rdx, [tok_val]
    mov [r8 + JN_A], rdx
    call jslex_next
    jmp .value
.maybe_accessor:
    lea rsi, [jsfeat_get]
    call jsstr_from_cstr
    cmp rdx, rax
    je .accessor
    lea rsi, [jsfeat_set]
    call jsstr_from_cstr
    cmp rdx, rax
    je .accessor
    jmp .key_atom
.key_number:
    mov rax, [tok_val]
    call js_number_to_atom
    mov [r8 + JN_A], rax
    call jslex_next
    jmp .value
.key_computed:
    mov byte [r8 + JN_OP], 1
    call jslex_next
    call jsp_assign
    mov [r8 + JN_A], rax
    EXPECT P_RBRACK
.value:
    AT_PUNCT P_COLON
    je .colon
    AT_PUNCT P_LPAREN
    je .method
    ; shorthand {a}
    cmp byte [r8 + JN_OP], 0
    jne jsp_unexpected
    mov rdx, [r8 + JN_A]
    mov al, NT_IDENT
    call jsp_node
    mov [rax + JN_A], rdx
    mov [r8 + JN_B], rax
    cmp rdx, [atom_arguments]
    jne .next
    call jsp_use_arguments
    jmp .next
.colon:
    call jslex_next
    call jsp_assign
    mov [r8 + JN_B], rax
    jmp .next
.method:
    xor edx, edx
    cmp byte [r8 + JN_OP], 0
    jne .method_anon
    mov rdx, [r8 + JN_A]
.method_anon:
    mov al, NT_FUNC
    call jsp_node
    push rax
    xor ecx, ecx                    ; a method does not bind its own name
    call jsp_function_rest
    mov rcx, rax
    pop rax
    mov [rax + JN_A], rcx
    mov [r8 + JN_B], rax
.next:
    AT_PUNCT P_RBRACE
    je .done
    EXPECT P_COMMA
    jmp .property
.done:
    call jslex_next
    pop qword [jsp_no_in]
    mov rax, rbx
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.spread:
    lea rdi, [jsfeat_spread]
    jmp jsp_unsupported
.accessor:
    lea rdi, [jsfeat_accessor]
    jmp jsp_unsupported

section .rodata
jsfeat_generator:       db "function* (generators)", 0
