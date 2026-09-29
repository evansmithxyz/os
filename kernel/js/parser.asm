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
NT_TRY                  equ 48          ; A = block, B = catch name atom / pattern (OP 1) or 0,
                                        ; C = catch block (0 = none), D = finally, E = catch scope
NT_TEMPLATE             equ 49          ; A = first piece: NT_STR and expressions, alternating
NT_SPREAD               equ 50          ; ...A (array literals, arguments)
NT_CHAIN                equ 51          ; A = an expression with ?. in it (they jump to its end)
NT_APAT                 equ 52          ; [a, b = 1, ...c]: A = first NT_PELEM
NT_OPAT                 equ 53          ; {a, b: c, ...d}: A = first NT_PELEM
NT_PELEM                equ 54          ; A = target (0 = hole), B = default, C = key atom or
                                        ; expression; OP bit 0 = rest, bit 1 = computed key
NT_PARAM                equ 55          ; A = target (NT_IDENT or pattern), B = default,
                                        ; OP 1 = rest, E = hidden variable atom of a pattern

NT_CLASS                equ 56          ; A = name atom or 0, B = parent expression or 0,
                                        ; C = first NT_CLASSMEM, D = constructor's function
                                        ; info; OP 1 = a declaration
NT_CLASSMEM             equ 57          ; OP = CM_*, A = key atom (or expression), B =
                                        ; NT_FUNC or a field's initial value (or 0)
NT_SUPERCALL            equ 58          ; super(B...), C = argument count
NT_SUPERMEMBER          equ 59          ; super.B (B = atom)
NT_AWAIT                equ 60          ; await A
NT_YIELD                equ 61          ; yield A (A = 0: undefined); OP = 1: yield*
NT_REGEX                equ 62          ; /A/B (pattern and flags atoms)
NT_WITH                 equ 64          ; with (A) B: C = the hidden variable holding A, E = its scope
NT_NEWTARGET            equ 65          ; new.target
NT_TAGSTR               equ 63          ; a tagged template's strings: A = first NT_STR
                                        ; (A = cooked, B = raw atom), C = their count
CM_STATIC               equ 1
CM_GET                  equ 2
CM_SET                  equ 4
CM_FIELD                equ 8
CM_COMPUTED             equ 16
CM_ASYNC                equ 32
CM_GEN                  equ 64
CM_BLOCK                equ 128         ; static { ... }: B = its function, called on the class

JNF_PATTERN             equ 1           ; NT_DECL: A is a pattern node
JNF_OPTIONAL            equ 2           ; member / index / call after ?.
JNF_SPREAD              equ 4           ; NT_CALL / NT_NEW: an argument is ...spread
JNF_AWAIT               equ 8           ; NT_FORIN: for await (each value awaited)

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
JSC_INDEXED             equ 30          ; byte: its variables in the compiler's index (1), too many (2)
JSC_NEXT                equ 32          ; next scope of the same function
JSC_NENV                equ 40          ; dword: its captured variables (the env's size; compiler)
JSC_LAST                equ 48          ; last JVR record
JSC_SIZE                equ 56
SK_FUNC                 equ 1
SK_BLOCK                equ 2

JVR_NEXT                equ 0
JVR_NAME                equ 8           ; atom
JVR_KIND                equ 16          ; byte, VK_*
JVR_FLAGS               equ 17          ; byte, JVRF_*
JVR_SLOT                equ 20          ; dword, stack slot, or env index if captured (compiler)
JVR_STACK               equ 24          ; dword, its stack slot (parameters, arguments: where it arrives)
JVR_SIZE                equ 32
JVRF_CAPTURED           equ 1           ; an inner function uses it: it lives in a heap env
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
JFI_GLOBALS             equ 72          ; script: a scope (in no chain) of its top-level declarations
JFI_PARAMS              equ 88          ; first NT_PARAM
JFI_REST                equ 96          ; the variable of a ...rest parameter, or 0
JFI_FIELDS              equ 104         ; class constructor: first instance field (NT_CLASSMEM)
JFI_ASYNCTRY            equ 112         ; qword: the implicit TRY of an async function
JFI_USES                equ 120         ; names this function uses (JU_* list)
JFI_FREE                equ 128         ; names its inner functions use and do not declare
JFI_GEN                 equ 136         ; dword: its generation in jsp_note_use's table
JFI_SIZE                equ 144
JU_NEXT                 equ 0
JU_NAME                 equ 8
JU_SIZE                 equ 16
FIF_INNER               equ 1           ; contains function definitions
FIF_ARGS                equ 2           ; uses `arguments`
FIF_SELF                equ 4           ; named function expression
FIF_SCRIPT              equ 8           ; the top-level script
FIF_ARROW               equ 16          ; an arrow function (this and arguments from outside)
FIF_PARAMCODE           equ 32          ; defaults or patterns in its parameters
FIF_CLASSCTOR           equ 64          ; a class's constructor
FIF_DERIVED             equ 128         ; ... of a class that extends another
FIF_ASYNC               equ 256         ; an async function
FIF_GENERATOR           equ 512         ; a generator function

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
jsp_no_in:              resq 1          ; 1 = `in` is not an operator (for-init; saved as a qword)
jsp_next_async:         resq 1          ; 1 = the next function made is async
jsp_next_gen:           resq 1          ; 1 = the next function made is a generator
jsp_names_gen:          resd 1          ; the name tables' current generation
jsp_names_count:        resd 1          ; entries in jsp_close_func's set
jsp_index_gen:          resd 1          ; this script's generation in the scope index
jsp_with_count:         resd 1          ; with statements so far (their hidden variables' names)
jsp_body_only:          resb 1          ; jsp_function_rest: no parameter list (static { })
alignb 8
jsp_with_chain:         resq 1          ; the with statements around (JU_* list of hidden names)
jsp_index_count:        resd 1          ; variables in it
jsp_ahead_tpl:          resd 32         ; jsp_arrow_ahead: depths of open ${
jsp_ahead_saved:        resb 64

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
jsmsg_try_alone:        db "Missing catch or finally after try", 0
jsfeat_destructuring:   db "destructuring", 0
jsfeat_module:          db "import/export", 0
jsfeat_decorator:       db "@decorators", 0

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
    call jsp_new_gen
    mov [jsp_index_gen], eax
    mov dword [jsp_index_count], 0
    mov dword [jsp_with_count], 0
    mov qword [jsp_with_chain], 0
    call jsp_new_func
    mov rbx, rax
    or dword [rbx + JFI_FLAGS], FIF_SCRIPT
    push rcx
    mov ecx, JSC_SIZE
    call jsp_alloc
    mov [rbx + JFI_GLOBALS], rax
    pop rcx
    mov dword [rbx + JFI_LINE], 1
    call jslex_init
.body:
    call jsp_statement_list
    cmp dword [tok_type], TK_EOF
    jne jsp_unexpected
    mov [rbx + JFI_BODY], rax
    push rax
    mov rax, rbx
    call jsp_close_func
    pop rax
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
    call jsp_new_gen
    mov [rbx + JFI_GEN], eax
    cmp dword [jsp_next_async], 0
    je .sync
    mov dword [jsp_next_async], 0
    or dword [rbx + JFI_FLAGS], FIF_ASYNC
.sync:
    cmp dword [jsp_next_gen], 0
    je .plain
    mov dword [jsp_next_gen], 0
    or dword [rbx + JFI_FLAGS], FIF_GENERATOR
.plain:
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
    cmp byte [rbx + JSC_INDEXED], 1
    je .indexed
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
.indexed:
    push rsi
    push rdi
    mov rdi, rbx
    call jsp_index_find
    mov rax, rsi
    pop rdi
    pop rsi
    test rax, rax
    jz .missing
    clc
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
    mov rsi, [rbx + JSC_LAST]
    test rsi, rsi
    jnz .append
    lea rsi, [rbx + JSC_VARS - JVR_NEXT]
.append:
    mov [rsi + JVR_NEXT], rax
    mov [rbx + JSC_LAST], rax
    pop rsi
    inc dword [rbx + JSC_NVARS]
    ; (many variables: indexed)
    cmp byte [rbx + JSC_INDEXED], 1
    je .index_one
    ja .done
    cmp dword [rbx + JSC_NVARS], JSP_INDEX_MIN
    jbe .done
    call jsp_index_scope
.done:
    ret
.index_one:
    push rsi
    push rdi
    mov rdi, rbx
    mov rsi, rax
    call jsp_index_put
    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------------------------
; The scope index: the variables of scopes with more than JSP_INDEX_MIN of
; them, hashed by (scope, name) at JS_NAMES_ADDR + JNS_INDEX in 32-byte
; entries {atom, scope, variable, generation dd}. Each script takes a new
; generation, which empties it; the compiler looks names up in it too.
; ------------------------------------------------------------------------------
JSP_INDEX_MIN           equ 8
JSP_INDEX_SLOTS         equ 16384
JSP_INDEX_LIMIT         equ 12288

; jsp_index_slot: RDI = scope, RDX = atom -> RAX = its first slot number
jsp_index_slot:
    push rcx
    mov rcx, 0x9E3779B97F4A7C15
    mov rax, rdi
    imul rax, rcx
    xor rax, rdx
    imul rax, rcx
    shr rax, 64 - 14
    pop rcx
    ret

; jsp_index_scope: RBX = scope -> its variables in the index (JSC_INDEXED 1),
; or too many (2)
jsp_index_scope:
    push rsi
    push rdi
    mov rdi, rbx
    mov byte [rbx + JSC_INDEXED], 1
    mov rsi, [rbx + JSC_VARS]
.var:
    test rsi, rsi
    jz .out
    call jsp_index_put
    mov rsi, [rsi + JVR_NEXT]
    jmp .var
.out:
    pop rdi
    pop rsi
    ret

; jsp_index_put: RDI = scope, RSI = one of its variables -> in the index (if
; it is full, the scope's JSC_INDEXED becomes 2: looked up the slow way)
jsp_index_put:
    push rax
    push rcx
    push rdx
    push r9
    cmp dword [jsp_index_count], JSP_INDEX_LIMIT
    jae .full
    inc dword [jsp_index_count]
    mov ecx, [jsp_index_gen]
    mov rdx, [rsi + JVR_NAME]
    call jsp_index_slot
.probe:
    mov r9, rax
    shl r9, 5
    add r9, JS_NAMES_ADDR + JNS_INDEX
    cmp [r9 + 24], ecx
    jne .put
    inc eax
    and eax, JSP_INDEX_SLOTS - 1
    jmp .probe
.put:
    mov [r9], rdx
    mov [r9 + 8], rdi
    mov [r9 + 16], rsi
    mov [r9 + 24], ecx
    jmp .out
.full:
    mov byte [rdi + JSC_INDEXED], 2
.out:
    pop r9
    pop rdx
    pop rcx
    pop rax
    ret

; jsp_index_find: RDI = an indexed scope, RDX = atom -> RSI = its variable, or 0
jsp_index_find:
    push rax
    push rcx
    mov ecx, [jsp_index_gen]
    call jsp_index_slot
.probe:
    mov rsi, rax
    shl rsi, 5
    add rsi, JS_NAMES_ADDR + JNS_INDEX
    cmp [rsi + 24], ecx
    jne .missing
    cmp [rsi], rdx
    jne .next
    cmp [rsi + 8], rdi
    je .found
.next:
    inc eax
    and eax, JSP_INDEX_SLOTS - 1
    jmp .probe
.missing:
    xor esi, esi
    pop rcx
    pop rax
    ret
.found:
    mov rsi, [rsi + 16]
    pop rcx
    pop rax
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
    mov rbx, [rax + JFI_GLOBALS]
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
    call jsp_async_function
    je jsp_function_declaration
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
    je jsp_try
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
.class:
    push rcx
    mov ecx, 1
    call jsp_class
    pop rcx
    ret
.module:
    ; (import(...) and import.meta are expressions)
    cmp eax, KW_IMPORT
    jne .not_expression
    call jslex_peek
    cmp dword [peek_type], TK_PUNCT
    jne .not_expression
    cmp qword [peek_val], P_LPAREN
    je jsp_expression_statement
    cmp qword [peek_val], P_DOT
    je jsp_expression_statement
.not_expression:
    lea rdi, [jsfeat_module]
    jmp jsp_unsupported
.with:
    jmp jsp_with

; jsp_with: with (object) statement -> RAX = NT_WITH. The object goes in a
; hidden variable (" with1", ...) of a block scope around the statement; names
; used inside are looked up in it first (the compiler's jsc_with_*)
jsp_with:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov al, NT_WITH
    call jsp_node
    mov rbx, rax
    call jslex_next
    EXPECT P_LPAREN
    call jsp_expression
    mov [rbx + JN_A], rax
    EXPECT P_RPAREN
    mov al, SK_BLOCK
    call jsp_push_scope
    mov [rbx + JN_E], rax
    ; its name: " with" and a number
    inc dword [jsp_with_count]
    sub rsp, 32
    mov eax, [jsp_with_count]
    lea rdi, [rsp + 31]
    mov ecx, 10
.digit:
    xor edx, edx
    div ecx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test eax, eax
    jnz .digit
    sub rdi, 5
    mov dword [rdi], ' wit'
    mov byte [rdi + 4], 'h'
    lea rcx, [rsp + 31]
    sub rcx, rdi
    mov rsi, rdi
    call jsstr_atom
    add rsp, 32
    mov [rbx + JN_C], rax
    mov rdx, rax
    mov cl, VK_LET
    call jsp_declare
    ; the body, inside it
    push qword [jsp_with_chain]
    mov ecx, JU_SIZE
    call jsp_alloc
    mov [rax + JU_NAME], rdx
    mov rcx, [jsp_with_chain]
    mov [rax + JU_NEXT], rcx
    mov [jsp_with_chain], rax
    call jsp_note_use               ; (inner functions keep it)
    call jsp_statement
    mov [rbx + JN_B], rax
    pop qword [jsp_with_chain]
    call jsp_pop_scope
    mov rax, rbx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsp_try: try { } [catch [(name)] { }] [finally { }]
jsp_try:
    push rbx
    push rcx
    push rdx
    mov al, NT_TRY
    call jsp_node
    mov rbx, rax
    call jslex_next
    AT_PUNCT P_LBRACE
    jne jsp_unexpected
    call jsp_block
    mov [rbx + JN_A], rax
    xor ecx, ecx                    ; saw catch or finally
    AT_KW KW_CATCH
    jne .finally
    inc ecx
    call jslex_next
    ; the catch variable lives in its own scope around the block
    mov al, SK_BLOCK
    call jsp_push_scope
    mov [rbx + JN_E], rax
    AT_PUNCT P_LPAREN
    jne .catch_block
    call jslex_next
    push rcx
    mov cl, VK_LET
    cmp dword [tok_type], TK_NAME
    jne .catch_pattern
    call jsp_ident
    mov [rbx + JN_B], rax
    mov rdx, rax
    call jsp_declare
    jmp .catch_named
.catch_pattern:
    call jsp_binding_pattern
    mov [rbx + JN_B], rax
    mov byte [rbx + JN_OP], 1
.catch_named:
    pop rcx
    EXPECT P_RPAREN
.catch_block:
    AT_PUNCT P_LBRACE
    jne jsp_unexpected
    call jsp_block
    mov [rbx + JN_C], rax
    call jsp_pop_scope
.finally:
    AT_KW KW_FINALLY
    jne .end
    inc ecx
    call jslex_next
    AT_PUNCT P_LBRACE
    jne jsp_unexpected
    call jsp_block
    mov [rbx + JN_D], rax
.end:
    test ecx, ecx
    jz .alone
    mov rax, rbx
    pop rdx
    pop rcx
    pop rbx
    ret
.alone:
    lea rsi, [jsmsg_try_alone]
    jmp jslex_error

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
    AT_PUNCT P_LBRACK
    je .pattern
    AT_PUNCT P_LBRACE
    je .pattern
    push rax
    call jsp_ident
    mov rdx, rax
    pop rax
    mov [rax + JN_A], rdx
    call jsp_declare
    jmp .declared
.pattern:
    push rax
    call jsp_binding_pattern
    mov rdx, rax
    pop rax
    mov [rax + JN_A], rdx
    or word [rax + JN_FLAGS], JNF_PATTERN
.declared:
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
    ; for await (x of ...): each value awaited
    cmp dword [tok_type], TK_NAME
    jne .no_await
    mov rax, [tok_val]
    cmp rax, [atom_await]
    jne .no_await
    or word [rbx + JN_FLAGS], JNF_AWAIT
    call jslex_next
.no_await:
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
    ; the target must be assignable (a literal becomes a pattern)
    push rcx
    mov rax, rdx
    call jsp_to_target
    pop rcx
    mov rdx, rax
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
    jne .named
    mov dword [jsp_next_gen], 1     ; function*
    call jslex_next
.named:
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
    cmp byte [jsp_body_only], 0
    jne .body_only
    call jsp_params
.body_only:
    mov byte [jsp_body_only], 0
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
    mov rax, rbx
    call jsp_close_func
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
; ------------------------------------------------------------------------------
; jsp_params: RBX = the new function's info; current token '(' -> each
; parameter declared in its function scope (plain names, patterns, defaults,
; ...rest), JFI_PARAMS / JFI_NPARAMS / JFI_REST set; past the ')'
; ------------------------------------------------------------------------------
jsp_params:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    EXPECT P_LPAREN
    xor r8d, r8d                    ; last NT_PARAM
    xor r9d, r9d                    ; index
.param:
    AT_PUNCT P_RPAREN
    je .done
    mov al, NT_PARAM
    call jsp_node
    mov r10, rax
    test r8, r8
    jz .first
    mov [r8 + JN_NEXT], r10
    jmp .linked
.first:
    mov [rbx + JFI_PARAMS], r10
.linked:
    mov r8, r10
    xor edi, edi                    ; rest?
    AT_PUNCT P_ELLIPSIS
    jne .target
    call jslex_next
    mov edi, 1
    mov byte [r10 + JN_OP], 1
.target:
    cmp dword [tok_type], TK_NAME
    jne .pattern
    ; a name: its own slot
    call jsp_ident
    mov rdx, rax
    mov al, NT_IDENT
    call jsp_node
    mov [rax + JN_A], rdx
    mov [r10 + JN_A], rax
    jmp .declare
.pattern:
    mov cl, VK_VAR
    call jsp_binding_pattern
    mov [r10 + JN_A], rax
    or dword [rbx + JFI_FLAGS], FIF_PARAMCODE
    mov ecx, r9d
    call jsp_hidden_name
    mov rdx, rax
    mov [r10 + JN_E], rdx
.declare:
    ; RDX = the name that gets the argument
    push rbx
    mov rbx, [rbx + JFI_SCOPE]
    mov cl, VK_PARAM
    test edi, edi
    jz .add
    mov cl, VK_VAR
.add:
    call jsp_scope_add
    pop rbx
    test edi, edi
    jnz .rest
    inc dword [rbx + JFI_NPARAMS]
    AT_PUNCT P_ASSIGN
    jne .next
    call jslex_next
    call jsp_assign
    mov [r10 + JN_B], rax
    or dword [rbx + JFI_FLAGS], FIF_PARAMCODE
.next:
    inc r9d
    AT_PUNCT P_RPAREN
    je .done
    EXPECT P_COMMA
    jmp .param
.rest:
    mov [rbx + JFI_REST], rax
    AT_PUNCT P_RPAREN
    je .done
    lea rsi, [jsmsg_rest_last]
    jmp jslex_error
.done:
    call jslex_next
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsp_hidden_name: ECX = parameter index -> RAX = an atom no script can name
; (" p" + two letters), for the argument a pattern takes apart
jsp_hidden_name:
    push rcx
    push rsi
    sub rsp, 8
    mov byte [rsp], ' '
    mov byte [rsp + 1], 'p'
    mov eax, ecx
    shr eax, 4
    and eax, 15
    add al, 'a'
    mov [rsp + 2], al
    mov eax, ecx
    and eax, 15
    add al, 'a'
    mov [rsp + 3], al
    mov rsi, rsp
    mov ecx, 4
    call jsstr_atom
    add rsp, 8
    pop rsi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; jsp_binding_pattern: current token '[' or '{', CL = VK_* for the names in it
; -> RAX = NT_APAT / NT_OPAT (names declared)
; jsp_binding_target: a name (declared, -> NT_IDENT) or a nested pattern
; ------------------------------------------------------------------------------
jsp_binding_target:
    cmp dword [tok_type], TK_NAME
    jne jsp_binding_pattern
    push rdx
    call jsp_ident
    mov rdx, rax
    call jsp_declare
    mov al, NT_IDENT
    call jsp_node
    mov [rax + JN_A], rdx
    pop rdx
    ret

jsp_binding_pattern:
    call jsp_enter
    push rbx
    push rdx
    push r8
    push r9
    AT_PUNCT P_LBRACK
    je .array
    AT_PUNCT P_LBRACE
    jne jsp_unexpected
    ; { key: target = default, name = default, [expr]: target, ...rest }
    mov al, NT_OPAT
    call jsp_node
    mov rbx, rax
    call jslex_next
    xor r8d, r8d
.prop:
    AT_PUNCT P_RBRACE
    je .end
    call .element
    AT_PUNCT P_ELLIPSIS
    jne .key
    call jslex_next
    mov byte [r9 + JN_OP], 1
    call jsp_binding_target
    mov [r9 + JN_A], rax
    jmp .prop_next
.key:
    AT_PUNCT P_LBRACK
    je .computed
    mov eax, [tok_type]
    cmp eax, TK_NAME
    je .key_name
    cmp eax, TK_STR
    je .key_atom
    cmp eax, TK_NUM
    jne jsp_unexpected
    mov rax, [tok_val]
    call js_number_to_atom
    mov [r9 + JN_C], rax
    call jslex_next
    jmp .colon
.key_atom:
    mov rax, [tok_val]
    mov [r9 + JN_C], rax
    call jslex_next
    jmp .colon
.key_name:
    mov rdx, [tok_val]
    mov [r9 + JN_C], rdx
    call jslex_next
    AT_PUNCT P_COLON
    je .colon
    ; shorthand {a} / {a = 1}: the key is the name
    call jsp_declare
    mov al, NT_IDENT
    call jsp_node
    mov [rax + JN_A], rdx
    mov [r9 + JN_A], rax
    jmp .default
.computed:
    or byte [r9 + JN_OP], 2
    call jslex_next
    call jsp_assign
    mov [r9 + JN_C], rax
    EXPECT P_RBRACK
.colon:
    EXPECT P_COLON
    call jsp_binding_target
    mov [r9 + JN_A], rax
.default:
    AT_PUNCT P_ASSIGN
    jne .prop_next
    call jslex_next
    call jsp_assign
    mov [r9 + JN_B], rax
.prop_next:
    AT_PUNCT P_RBRACE
    je .end
    EXPECT P_COMMA
    jmp .prop
.array:
    ; [target = default, , ...rest]
    mov al, NT_APAT
    call jsp_node
    mov rbx, rax
    call jslex_next
    xor r8d, r8d
.item:
    AT_PUNCT P_RBRACK
    je .end
    call .element
    AT_PUNCT P_COMMA
    je .hole
    AT_PUNCT P_ELLIPSIS
    jne .item_target
    call jslex_next
    mov byte [r9 + JN_OP], 1
.item_target:
    call jsp_binding_target
    mov [r9 + JN_A], rax
    AT_PUNCT P_ASSIGN
    jne .item_next
    call jslex_next
    call jsp_assign
    mov [r9 + JN_B], rax
.item_next:
    AT_PUNCT P_RBRACK
    je .end
.hole:
    EXPECT P_COMMA
    jmp .item
.end:
    call jslex_next
    mov rax, rbx
    pop r9
    pop r8
    pop rdx
    pop rbx
    call jsp_leave
    ret
; .element: a new NT_PELEM appended to RBX's list -> R9 (R8 = the last one)
.element:
    push rax
    mov al, NT_PELEM
    call jsp_node
    mov r9, rax
    test r8, r8
    jz .el_first
    mov [r8 + JN_NEXT], r9
    jmp .el_done
.el_first:
    mov [rbx + JN_A], r9
.el_done:
    mov r8, r9
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsp_to_pattern: RAX = an array or object literal on the left of '=' (or of
; for-of) -> RAX = the same as an assignment pattern
; ------------------------------------------------------------------------------
jsp_to_pattern:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    mov rsi, rax
    mov al, NT_APAT
    cmp byte [rsi + JN_TYPE], NT_ARRAY
    je .make
    mov al, NT_OPAT
.make:
    call jsp_node
    mov rbx, rax
    xor r8d, r8d
    mov rsi, [rsi + JN_A]           ; elements / properties
.item:
    test rsi, rsi
    jz .done
    mov al, NT_PELEM
    call jsp_node
    mov r9, rax
    test r8, r8
    jz .first
    mov [r8 + JN_NEXT], r9
    jmp .linked
.first:
    mov [rbx + JN_A], r9
.linked:
    mov r8, r9
    cmp byte [rbx + JN_TYPE], NT_OPAT
    je .property
    ; array element
    cmp byte [rsi + JN_TYPE], NT_HOLE
    je .next
    mov rax, rsi
    cmp byte [rsi + JN_TYPE], NT_SPREAD
    jne .value
    mov byte [r9 + JN_OP], 1
    mov rax, [rsi + JN_A]
    jmp .value
.property:
    cmp byte [rsi + JN_OP], 2
    jne .keyed
    mov byte [r9 + JN_OP], 1        ; ...rest
    mov rax, [rsi + JN_A]
    jmp .value
.keyed:
    mov rax, [rsi + JN_A]
    mov [r9 + JN_C], rax
    cmp byte [rsi + JN_OP], 1
    jne .key_done
    or byte [r9 + JN_OP], 2
.key_done:
    mov rax, [rsi + JN_B]
.value:
    ; target = default
    cmp byte [rax + JN_TYPE], NT_ASSIGN
    jne .target
    cmp byte [rax + JN_OP], P_ASSIGN
    jne .target
    mov rcx, [rax + JN_B]
    mov [r9 + JN_B], rcx
    mov rax, [rax + JN_A]
.target:
    call jsp_to_target
    mov [r9 + JN_A], rax
.next:
    mov rsi, [rsi + JN_NEXT]
    jmp .item
.done:
    mov rax, rbx
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsp_to_target: RAX = expression that must be assignable -> RAX = the target
; (a name, a.b, a[b], or a nested literal made a pattern)
jsp_to_target:
    cmp byte [rax + JN_TYPE], NT_IDENT
    je .ok
    cmp byte [rax + JN_TYPE], NT_MEMBER
    je .ok
    cmp byte [rax + JN_TYPE], NT_INDEX
    je .ok
    cmp byte [rax + JN_TYPE], NT_ARRAY
    je jsp_to_pattern
    cmp byte [rax + JN_TYPE], NT_OBJECT
    je jsp_to_pattern
    lea rsi, [jsmsg_bad_target]
    jmp jslex_error
.ok:
    ret

; ------------------------------------------------------------------------------
; jsp_arrow: RDX = the single parameter's name (x => ...), or 0 with the
; current token '(' -> RAX = NT_FUNC of an arrow function
; ------------------------------------------------------------------------------
jsp_arrow:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    mov r8, [jsp_func]
    mov r9, [jsp_scope]
    push qword [jsp_no_in]
    mov dword [jsp_no_in], 0
    mov al, NT_FUNC
    call jsp_node
    mov r10, rax
    call jsp_new_func
    mov rbx, rax
    or dword [rbx + JFI_FLAGS], FIF_ARROW
    mov [r10 + JN_A], rbx
    test rdx, rdx
    jz .list
    ; x => ...
    push rbx
    mov rbx, [rbx + JFI_SCOPE]
    mov cl, VK_PARAM
    call jsp_scope_add
    pop rbx
    mov dword [rbx + JFI_NPARAMS], 1
    jmp .arrow
.list:
    call jsp_params
.arrow:
    EXPECT P_ARROW
    AT_PUNCT P_LBRACE
    je .block
    ; an expression: the value it returns
    mov al, NT_RETURN
    call jsp_node
    mov rcx, rax
    call jsp_assign
    mov [rcx + JN_A], rax
    mov [rbx + JFI_BODY], rcx
    jmp .done
.block:
    call jslex_next
    call jsp_statement_list
    mov [rbx + JFI_BODY], rax
    AT_PUNCT P_RBRACE
    jne jsp_unexpected
    call jslex_next
.done:
    mov rax, rbx
    call jsp_close_func
    pop qword [jsp_no_in]
    mov [jsp_func], r8
    mov [jsp_scope], r9
    mov rax, r10
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; jsp_arrow_ahead: current token '(' -> CF=1 if the parentheses are an arrow
; function's parameters (the ')' is followed by =>). Looks ahead with the
; lexer and comes back.
; ------------------------------------------------------------------------------
jsp_arrow_ahead:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    lea rsi, [jslex_state]
    lea rdi, [jsp_ahead_saved]
    mov ecx, JSLEX_STATE_SIZE
    rep movsb
    xor edx, edx                    ; bracket depth
    xor ecx, ecx                    ; open ${ (their depths on jsp_ahead_tpl)
    xor r8d, r8d                    ; 1 = a '/' here starts a regular expression
.token:
    mov eax, [tok_type]
    cmp eax, TK_EOF
    je .no
    ; a regular expression literal: skipped whole (its \ and quotes are not tokens)
    test r8d, r8d
    jz .not_regex
    cmp eax, TK_PUNCT
    jne .not_regex
    mov rax, [tok_val]
    cmp eax, P_SLASH
    je .regex
    cmp eax, P_DIV_ASSIGN
    jne .not_regex
.regex:
    push rdx
    call jslex_regex
    pop rdx
    xor r8d, r8d
    call jslex_next
    jmp .token
.not_regex:
    call .regex_after
    mov eax, [tok_type]
    cmp eax, TK_TEMPLATE
    jne .punct
    cmp byte [tok_tail], 0
    jne .next
    ; ${ ... }: remember the depth it opened at
    cmp ecx, 32
    jae .no
    lea rsi, [jsp_ahead_tpl]
    mov [rsi + rcx*4], edx
    inc ecx
    inc edx
    jmp .next
.punct:
    cmp eax, TK_PUNCT
    jne .next
    mov rax, [tok_val]
    cmp eax, P_LPAREN
    je .open
    cmp eax, P_LBRACK
    je .open
    cmp eax, P_LBRACE
    je .open
    cmp eax, P_RPAREN
    je .close
    cmp eax, P_RBRACK
    je .close
    cmp eax, P_RBRACE
    jne .next
    ; the end of a ${ }?
    test ecx, ecx
    jz .close
    lea rsi, [jsp_ahead_tpl]
    lea eax, [edx - 1]
    cmp eax, [rsi + rcx*4 - 4]
    jne .close
    dec ecx
    dec edx
    call jslex_template_resume
    jmp .token
.open:
    inc edx
    jmp .next
.close:
    dec edx
    jnz .next
    ; the matching ')': is => next?
    call jslex_next
    AT_PUNCT P_ARROW
    je .yes
    jmp .no
.next:
    call jslex_next
    jmp .token
.yes:
    call .restore
    stc
    jmp .out
.no:
    call .restore
    clc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
.restore:
    push rcx
    lea rsi, [jsp_ahead_saved]
    lea rdi, [jslex_state]
    mov ecx, JSLEX_STATE_SIZE
    rep movsb
    pop rcx
    ret
; .regex_after: R8D = 1 if a '/' after the current token starts a regular
; expression (it does not end an expression: not a name, number, string,
; ')' ']' '}' ++ --)
.regex_after:
    push rax
    xor r8d, r8d
    mov eax, [tok_type]
    cmp eax, TK_NUM
    je .ends
    cmp eax, TK_STR
    je .ends
    cmp eax, TK_TEMPLATE
    je .ends
    cmp eax, TK_NAME
    jne .punct_after
    mov eax, [tok_kw]
    test eax, eax
    jz .ends                        ; a name
    cmp eax, KW_THIS
    je .ends
    cmp eax, KW_NULL
    je .ends
    cmp eax, KW_TRUE
    je .ends
    cmp eax, KW_FALSE
    je .ends
    cmp eax, KW_SUPER
    je .ends
    jmp .starts                     ; return, typeof, in, ...
.punct_after:
    mov rax, [tok_val]
    cmp eax, P_RPAREN
    je .ends
    cmp eax, P_RBRACK
    je .ends
    cmp eax, P_RBRACE
    je .ends
    cmp eax, P_INC
    je .ends
    cmp eax, P_DEC
    je .ends
.starts:
    mov r8d, 1
.ends:
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsp_template: current token is a template's first piece -> RAX = NT_TEMPLATE
; ------------------------------------------------------------------------------
jsp_template:
    push rbx
    push rcx
    push rdx
    mov al, NT_TEMPLATE
    call jsp_node
    mov rbx, rax
    xor ecx, ecx                    ; last piece
.piece:
    mov al, NT_STR
    call jsp_node
    mov rdx, [tok_val]
    mov [rax + JN_A], rdx
    call .append
    cmp byte [tok_tail], 0
    jne .end
    call jslex_next
    push qword [jsp_no_in]
    mov dword [jsp_no_in], 0
    call jsp_expression
    pop qword [jsp_no_in]
    call .append
    AT_PUNCT P_RBRACE
    jne jsp_unexpected
    call jslex_template_resume
    jmp .piece
.end:
    call jslex_next
    mov rax, rbx
    pop rdx
    pop rcx
    pop rbx
    ret
; .append: RAX = node after the last one (RCX)
.append:
    test rcx, rcx
    jz .first
    mov [rcx + JN_NEXT], rax
    mov rcx, rax
    ret
.first:
    mov [rbx + JN_A], rax
    mov rcx, rax
    ret

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
    ; yield inside a generator
    cmp dword [tok_type], TK_NAME
    jne .not_yield
    mov rcx, [tok_val]
    cmp rcx, [atom_yield]
    jne .not_yield
    mov rcx, [jsp_func]
    test dword [rcx + JFI_FLAGS], FIF_GENERATOR
    jz .not_yield
    mov al, NT_YIELD
    call jsp_node
    mov rbx, rax
    call jslex_next
    cmp byte [tok_nl], 0
    jne .yield_done                 ; `yield` alone on its line
    AT_PUNCT P_STAR
    jne .yield_operand
    mov byte [rbx + JN_OP], 1       ; yield*
    call jslex_next
    jmp .yield_value
.yield_operand:
    cmp dword [tok_type], TK_EOF
    je .yield_done
    cmp dword [tok_type], TK_PUNCT
    jne .yield_value
    mov rcx, [tok_val]
    cmp ecx, P_RPAREN
    je .yield_done
    cmp ecx, P_RBRACK
    je .yield_done
    cmp ecx, P_RBRACE
    je .yield_done
    cmp ecx, P_COMMA
    je .yield_done
    cmp ecx, P_SEMI
    je .yield_done
    cmp ecx, P_COLON
    je .yield_done
.yield_value:
    call jsp_assign
    mov [rbx + JN_A], rax
.yield_done:
    mov rax, rbx
    pop rcx
    pop rbx
    call jsp_leave
    ret
.not_yield:
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
    cmp ecx, P_ASSIGN
    jne .bad_target
    cmp ebx, NT_ARRAY
    je .pattern
    cmp ebx, NT_OBJECT
    je .pattern
.bad_target:
    lea rsi, [jsmsg_bad_target]
    jmp jslex_error
.pattern:
    call jsp_to_pattern
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
    jmp jsp_unexpected              ; `a + b => c`

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
    ; await, inside async functions
    mov rcx, [tok_val]
    cmp rcx, [atom_await]
    jne .keyword
    mov rcx, [jsp_func]
    test dword [rcx + JFI_FLAGS], FIF_ASYNC
    jz .keyword
    mov al, NT_AWAIT
    call jsp_node
    mov rbx, rax
    call jslex_next
    call jsp_unary
    mov [rbx + JN_A], rax
    mov rax, rbx
    jmp .done
.keyword:
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
    push r8
    xor r8d, r8d                    ; 1 = the chain has a ?.
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
.done:
    cmp dword [tok_type], TK_TEMPLATE
    je .template
    mov rax, rbx
    test r8d, r8d
    jz .plain
    ; a ?. somewhere: the whole chain is its jump target
    mov al, NT_CHAIN
    call jsp_node
    mov [rax + JN_A], rbx
.plain:
    pop r8
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
    mov r8d, 1
    call jslex_next
    AT_PUNCT P_LPAREN
    je .optional_call
    AT_PUNCT P_LBRACK
    je .optional_index
    call jsp_member_name
    or word [rbx + JN_FLAGS], JNF_OPTIONAL
    jmp .loop
.optional_index:
    call jsp_member_index
    or word [rbx + JN_FLAGS], JNF_OPTIONAL
    jmp .loop
.optional_call:
    mov al, NT_CALL
    call jsp_node
    mov [rax + JN_A], rbx
    or word [rax + JN_FLAGS], JNF_OPTIONAL
    mov rbx, rax
    call jsp_arguments
    jmp .loop
.template:
    ; tag`...`: a call of the tag with the strings and the values
    mov al, NT_CALL
    call jsp_node
    mov [rax + JN_A], rbx
    mov rbx, rax
    call jsp_tagged_args
    jmp .loop

; jsp_tagged_args: RBX = NT_CALL, the current token a template -> its
; arguments: NT_TAGSTR, then the ${} expressions
jsp_tagged_args:
    push rax
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    mov al, NT_TAGSTR
    call jsp_node
    mov rdi, rax
    mov [rbx + JN_B], rdi
    mov r8, rdi                     ; last argument
    xor r9d, r9d                    ; last piece
    mov edx, 1                      ; arguments
    mov r10d, 1                     ; the first piece starts after the `
.piece:
    mov al, NT_STR
    call jsp_node
    mov rcx, [tok_val]
    mov [rax + JN_A], rcx
    ; raw: the source text between ` or } and ` or ${
    push rax
    push rsi
    mov rsi, [tok_start]
    add rsi, r10
    xor r10d, r10d
    mov rcx, [jslex_pos]
    sub rcx, rsi
    dec rcx
    cmp byte [tok_tail], 0
    jne .raw
    dec rcx
.raw:
    call jsstr_atom
    mov rcx, rax
    pop rsi
    pop rax
    mov [rax + JN_B], rcx
    test r9, r9
    jz .first_piece
    mov [r9 + JN_NEXT], rax
    jmp .linked
.first_piece:
    mov [rdi + JN_A], rax
.linked:
    mov r9, rax
    inc qword [rdi + JN_C]
    cmp byte [tok_tail], 0
    jne .end
    call jslex_next
    push qword [jsp_no_in]
    mov dword [jsp_no_in], 0
    call jsp_expression
    pop qword [jsp_no_in]
    mov [r8 + JN_NEXT], rax
    mov r8, rax
    inc edx
    AT_PUNCT P_RBRACE
    jne jsp_unexpected
    call jslex_template_resume
    jmp .piece
.end:
    cmp edx, 255
    ja .too_many
    mov [rbx + JN_C], rdx
    call jslex_next
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret
.too_many:
    lea rsi, [jsmsg_too_many_args]
    jmp jslex_error

; jsp_member_dot: RBX = object; current token '.' -> RBX = NT_MEMBER
; jsp_member_name: the same with the name as the current token (after ?.)
jsp_member_dot:
    call jslex_next
jsp_member_name:
    push rax
    cmp dword [tok_type], TK_NAME
    je .name
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
    jmp .have
.spread:
    call jsp_spread
    or word [rbx + JN_FLAGS], JNF_SPREAD
.have:
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
    ; new.target: the function `new` called (undefined otherwise)
    call jslex_next
    cmp dword [tok_type], TK_NAME
    jne jsp_unexpected
    mov rax, [tok_val]
    cmp rax, [atom_d_target]
    jne jsp_unexpected
    call jslex_next
    mov al, NT_NEWTARGET
    call jsp_node
    pop rcx
    pop rbx
    call jsp_leave
    ret

; ------------------------------------------------------------------------------
; jsp_primary: literals, names, (expression), [array], {object}, function
; ------------------------------------------------------------------------------
jsp_primary:
    push rbx
    push rcx
    push rdx
    ; import(...) / import.meta: the prelude's __import / __importMeta (no modules)
    cmp dword [tok_kw], KW_IMPORT
    je .import
    mov eax, [tok_type]
    cmp eax, TK_NUM
    je .number
    cmp eax, TK_STR
    je .string
    cmp eax, TK_NAME
    je .name
    cmp eax, TK_TEMPLATE
    je .template
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
.import:
    call jslex_next
    mov rdx, [atom_import_fn]
    AT_PUNCT P_LPAREN
    je .import_name
    EXPECT P_DOT
    cmp dword [tok_type], TK_NAME
    jne jsp_unexpected
    call jslex_next                 ; (meta)
    mov rdx, [atom_import_meta]
.import_name:
    call jsp_note_use
    mov al, NT_IDENT
    call jsp_node
    mov [rax + JN_A], rdx
    pop rdx
    pop rcx
    pop rbx
    ret
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
    call jsp_async_function
    je .function
    mov rax, [tok_val]
    cmp rax, [atom_async]
    jne .plain_ident
    call jslex_peek
    cmp byte [peek_nl], 0
    jne .plain_ident
    cmp dword [peek_type], TK_NAME
    jne .async_paren
    cmp dword [peek_kw], 0
    je .async_name
    jmp .plain_ident
.async_paren:
    cmp dword [peek_type], TK_PUNCT
    jne .plain_ident
    cmp qword [peek_val], P_LPAREN
    jne .plain_ident
    ; async (a, b) => ... or a call of a function named async
    call jslex_next
    call jsp_arrow_ahead
    jnc .async_call
    mov dword [jsp_next_async], 1
    xor edx, edx
    call jsp_arrow
    jmp .done
.async_call:
    mov al, NT_IDENT
    call jsp_node
    mov rdx, [atom_async]
    mov [rax + JN_A], rdx
    call jsp_note_use
    jmp .done
.async_name:
    ; async x => ... (x => made async)
    call jslex_next
    mov dword [jsp_next_async], 1
.plain_ident:
    ; (#x alone, as in `#x in obj`: the private name is the key)
    mov rdx, [tok_val]
    cmp byte [rdx + JSTR_DATA], '#'
    je .private_name
    mov al, NT_IDENT
    call jsp_node
    mov rbx, rax
    mov rdx, [tok_val]
    mov [rbx + JN_A], rdx
    call jsp_note_use
    call jslex_next
    AT_PUNCT P_ARROW
    je .single_arrow
    mov dword [jsp_next_async], 0   ; (async x without =>)
    cmp rdx, [atom_arguments]
    jne .ident_done
    call jsp_use_arguments
.ident_done:
    mov rax, rbx
    jmp .done
.private_name:
    mov al, NT_STR
    call jsp_node
    mov [rax + JN_A], rdx
    call jslex_next
    jmp .done
.function:
    call jslex_next
    AT_PUNCT P_STAR
    jne .function_name
    mov dword [jsp_next_gen], 1     ; function*
    call jslex_next
.function_name:
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
.single_arrow:
    call jsp_arrow                  ; x => ...
    jmp .done
.paren:
    call jsp_arrow_ahead
    jnc .group
    xor edx, edx
    call jsp_arrow                  ; (a, b) => ...
    jmp .done
.group:
    call jslex_next
    push qword [jsp_no_in]
    mov dword [jsp_no_in], 0
    call jsp_expression
    pop qword [jsp_no_in]
    EXPECT P_RPAREN
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
.template:
    call jsp_template
    jmp .done
.regex:
    call jslex_regex
    push rax
    mov al, NT_REGEX
    call jsp_node
    pop rcx
    mov [rax + JN_A], rcx
    mov [rax + JN_B], rdx
    jmp .next_done
.class:
    xor ecx, ecx
    call jsp_class
    jmp .done
.super:
    call jslex_next
    AT_PUNCT P_LPAREN
    je .super_call
    AT_PUNCT P_DOT
    jne jsp_unexpected
    call jslex_next
    cmp dword [tok_type], TK_NAME
    jne jsp_unexpected
    mov al, NT_SUPERMEMBER
    call jsp_node
    mov rcx, [tok_val]
    mov [rax + JN_B], rcx
    jmp .next_done
.super_call:
    mov al, NT_SUPERCALL
    call jsp_node
    mov rbx, rax
    call jsp_arguments
    mov rax, rbx
    jmp .done
.decorator:
    lea rdi, [jsfeat_decorator]
    jmp jsp_unsupported

; jsp_async_function: current token a name -> ZF=1 (and `async` consumed,
; the next function marked async) if it is `async function`
jsp_async_function:
    push rax
    mov rax, [tok_val]
    cmp rax, [atom_async]
    jne .out
    call jslex_peek
    cmp byte [peek_nl], 0
    jne .out
    cmp dword [peek_kw], KW_FUNCTION
    jne .out
    call jslex_next
    mov dword [jsp_next_async], 1
    xor eax, eax                    ; ZF=1
.out:
    pop rax
    ret

; jsp_modifier_ahead: current token `async` in an object or class -> CF=1 if
; a method name follows on the same line (so it is a modifier)
jsp_modifier_ahead:
    call jslex_peek
    cmp byte [peek_nl], 0
    jne .no
    cmp dword [peek_type], TK_NAME
    je .yes
    cmp dword [peek_type], TK_STR
    je .yes
    cmp dword [peek_type], TK_NUM
    je .yes
    cmp dword [peek_type], TK_PUNCT
    jne .no
    cmp qword [peek_val], P_LBRACK
    jne .no
.yes:
    stc
    ret
.no:
    clc
    ret

; ------------------------------------------------------------------------------
; Closures: which variables inner functions use (they need a heap env; the
; rest stay in stack slots). Every name a function uses is noted; when it
; ends, the names it does not declare go to its parent's free list, and the
; parent marks its variables of the names on its own free list captured.
; By name, so a shadowed name may be captured without need (never the other
; way round).
; ------------------------------------------------------------------------------

; The names are counted in hash tables at JS_NAMES_ADDR, entries of 16 bytes
; {atom, generation dd, bits dd}; an entry of an older generation is free, so
; a table is emptied by taking a new generation.
JNS_SET                 equ 0           ; jsp_close_func's set: 32768 entries
JNS_SET_SLOTS           equ 16384
JNS_SET_LIMIT           equ 12288       ; more names than this: the slow way
JNS_USES                equ 0x40000     ; jsp_note_use's recent names: 4096 entries
JNS_INDEX               equ 0x80000     ; the compiler's scope index (compiler.asm)
JNS_DECL                equ 1           ; the function declares the name
JNS_FREE                equ 2           ; an inner function uses it
JNS_PASSED              equ 4           ; passed on to the parent already

; jsp_new_gen: -> EAX = a new generation (the tables are cleared the first time)
jsp_new_gen:
    mov eax, [jsp_names_gen]
    inc eax
    cmp eax, 1
    ja .ok
    push rcx
    push rdi
    mov edi, JS_NAMES_ADDR
    mov ecx, JS_NAMES_SIZE / 8
    xor eax, eax
    rep stosq
    pop rdi
    pop rcx
    mov eax, 1
.ok:
    mov [jsp_names_gen], eax
    ret

; jsp_note_use: RDX = a name the current function uses (inside with
; statements, their hidden variables too)
jsp_note_use:
    cmp qword [jsp_with_chain], 0
    je jsp_note_one
    push rax
    push rdx
    call jsp_note_one
    mov rax, [jsp_with_chain]
.with:
    test rax, rax
    jz .done
    mov rdx, [rax + JU_NAME]
    call jsp_note_one
    mov rax, [rax + JU_NEXT]
    jmp .with
.done:
    pop rdx
    pop rax
    ret

; jsp_note_one: RDX = a name the current function uses
jsp_note_one:
    push rax
    push rbx
    push rcx
    mov rbx, [jsp_func]
    test rbx, rbx
    jz .out
    ; (noted lately by this function: once is enough; a collision in the
    ; table only repeats a name)
    mov rax, rdx
    mov rcx, 0x9E3779B97F4A7C15
    imul rax, rcx
    shr rax, 64 - 12
    shl eax, 4
    add rax, JS_NAMES_ADDR + JNS_USES
    mov ecx, [rbx + JFI_GEN]
    cmp [rax + 8], ecx
    jne .note
    cmp [rax], rdx
    je .out
.note:
    mov [rax], rdx
    mov [rax + 8], ecx
    mov ecx, JU_SIZE
    call jsp_alloc
    mov [rax + JU_NAME], rdx
    mov rcx, [rbx + JFI_USES]
    mov [rax + JU_NEXT], rcx
    mov [rbx + JFI_USES], rax
.out:
    pop rcx
    pop rbx
    pop rax
    ret

; jsp_name_entry: RDX = atom -> RAX = its entry in jsp_close_func's set (new
; ones with no bits), CF=1 if the set is full
jsp_name_entry:
    push rcx
    push rsi
    mov rax, rdx
    mov rcx, 0x9E3779B97F4A7C15
    imul rax, rcx
    shr rax, 64 - 14
    mov ecx, [jsp_names_gen]
.probe:
    mov rsi, rax
    shl rsi, 4
    add rsi, JS_NAMES_ADDR + JNS_SET
    cmp [rsi + 8], ecx
    jne .new
    cmp [rsi], rdx
    je .found
    inc eax
    and eax, JNS_SET_SLOTS - 1
    jmp .probe
.new:
    cmp dword [jsp_names_count], JNS_SET_LIMIT
    jae .full
    inc dword [jsp_names_count]
    mov [rsi], rdx
    mov [rsi + 8], ecx
    mov dword [rsi + 12], 0
.found:
    mov rax, rsi
    pop rsi
    pop rcx
    clc
    ret
.full:
    pop rsi
    pop rcx
    stc
    ret

; jsp_close_func: RAX = a function that has been parsed -> its variables that
; inner functions use marked JVRF_CAPTURED; the names it does not declare
; passed on to its parent (each once)
jsp_close_func:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov rbx, rax
    call jsp_new_gen
    mov dword [jsp_names_count], 0
    ; the names it declares
    mov rsi, [rbx + JFI_SCOPE]
    mov rsi, [rsi + JSC_VARS]
.decl:
    test rsi, rsi
    jz .free
    mov rdx, [rsi + JVR_NAME]
    call jsp_name_entry
    jc .full
    or byte [rax + 12], JNS_DECL
    mov rsi, [rsi + JVR_NEXT]
    jmp .decl
.free:
    ; names its inner functions use: captured here, or passed on
    mov rsi, [rbx + JFI_FREE]
.free_name:
    test rsi, rsi
    jz .mark
    mov rdx, [rsi + JU_NAME]
    call jsp_name_entry
    jc .full
    or byte [rax + 12], JNS_FREE
    call .pass_up
    mov rsi, [rsi + JU_NEXT]
    jmp .free_name
.mark:
    ; its variables (in any block) of those names are captured
    mov rcx, [rbx + JFI_SCOPES]
.mark_scope:
    test rcx, rcx
    jz .uses
    mov rsi, [rcx + JSC_VARS]
.mark_var:
    test rsi, rsi
    jz .mark_next
    mov rdx, [rsi + JVR_NAME]
    call jsp_name_entry
    jc .full
    test byte [rax + 12], JNS_FREE
    jz .mark_skip
    or byte [rsi + JVR_FLAGS], JVRF_CAPTURED
.mark_skip:
    mov rsi, [rsi + JVR_NEXT]
    jmp .mark_var
.mark_next:
    mov rcx, [rcx + JSC_NEXT]
    jmp .mark_scope
.uses:
    ; its own uses of names it does not declare: the parent's (or further up)
    mov rsi, [rbx + JFI_USES]
.use:
    test rsi, rsi
    jz .done
    mov rdx, [rsi + JU_NAME]
    call jsp_name_entry
    jc .full
    call .pass_up
    mov rsi, [rsi + JU_NEXT]
    jmp .use
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.full:
    ; too many names for the set: every variable captured and every name
    ; passed on (more than needed, never less)
    mov rcx, [rbx + JFI_SCOPES]
.all_scope:
    test rcx, rcx
    jz .all_free
    mov rsi, [rcx + JSC_VARS]
.all_var:
    test rsi, rsi
    jz .all_next
    or byte [rsi + JVR_FLAGS], JVRF_CAPTURED
    mov rsi, [rsi + JVR_NEXT]
    jmp .all_var
.all_next:
    mov rcx, [rcx + JSC_NEXT]
    jmp .all_scope
.all_free:
    mov rsi, [rbx + JFI_FREE]
.all_free_name:
    test rsi, rsi
    jz .all_uses
    mov rdx, [rsi + JU_NAME]
    call .push_up
    mov rsi, [rsi + JU_NEXT]
    jmp .all_free_name
.all_uses:
    mov rsi, [rbx + JFI_USES]
.all_use:
    test rsi, rsi
    jz .done
    mov rdx, [rsi + JU_NAME]
    call .push_up
    mov rsi, [rsi + JU_NEXT]
    jmp .all_use
; .pass_up: RAX = the entry of RDX = a name -> onto the parent's free list,
; unless the function declares it or passed it on already
.pass_up:
    test byte [rax + 12], JNS_DECL | JNS_PASSED
    jnz .kept
    or byte [rax + 12], JNS_PASSED
.push_up:
    push rax
    push rcx
    mov rcx, [rbx + JFI_PARENT]
    test rcx, rcx
    jz .no_parent
    push rcx
    mov ecx, JU_SIZE
    call jsp_alloc
    pop rcx
    mov [rax + JU_NAME], rdx
    push rdx
    mov rdx, [rcx + JFI_FREE]
    mov [rax + JU_NEXT], rdx
    mov [rcx + JFI_FREE], rax
    pop rdx
.no_parent:
    pop rcx
    pop rax
.kept:
    ret

; jsp_use_arguments: the current function reads `arguments`: declare it
jsp_use_arguments:
    push rax
    push rbx
    push rcx
    push rdx
    mov rcx, [jsp_func]
.function:
    test dword [rcx + JFI_FLAGS], FIF_ARROW
    jz .own
    mov rcx, [rcx + JFI_PARENT]     ; arrows use the enclosing function's
    jmp .function
.own:
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
.spread:
    call jsp_spread
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

; ------------------------------------------------------------------------------
; jsp_class: current token `class`, ECX = 1 for a declaration -> RAX = NT_CLASS.
; The constructor's function info is made first, so instance field values
; are parsed as if they were at the start of the constructor.
; ------------------------------------------------------------------------------
jsp_class:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov r11d, ecx                   ; declaration?
    mov al, NT_CLASS
    call jsp_node
    mov rbx, rax
    mov [rbx + JN_OP], r11b
    call jslex_next                 ; `class`
    xor edx, edx
    cmp dword [tok_type], TK_NAME
    jne .named
    AT_KW KW_EXTENDS
    je .named
    call jsp_ident
    mov rdx, rax
    mov [rbx + JN_A], rdx
    test r11d, r11d
    jz .named
    mov cl, VK_LET
    call jsp_declare
.named:
    test r11d, r11d
    jz .heritage
    test rdx, rdx
    jz .no_name
.heritage:
    AT_KW KW_EXTENDS
    jne .body
    call jslex_next
    call jsp_call
    mov [rbx + JN_B], rax
.body:
    EXPECT P_LBRACE
    mov r8, [jsp_func]
    mov r9, [jsp_scope]
    call jsp_new_func
    mov r10, rax                    ; the constructor
    mov [r10 + JFI_NAME], rdx
    or dword [r10 + JFI_FLAGS], FIF_CLASSCTOR
    cmp qword [rbx + JN_B], 0
    je .base
    or dword [r10 + JFI_FLAGS], FIF_DERIVED
.base:
    mov [jsp_func], r8              ; members are parsed outside it
    mov [jsp_scope], r9
    mov [rbx + JN_D], r10
    xor esi, esi                    ; last member
    xor edi, edi                    ; last instance field
    mov qword [rbx + JN_E], 0       ; 1 = it has a constructor
.member:
    AT_PUNCT P_RBRACE
    je .end
    AT_PUNCT P_SEMI
    jne .member_start
    call jslex_next
    jmp .member
.member_start:
    mov al, NT_CLASSMEM
    call jsp_node
    mov rcx, rax
    ; static
    cmp dword [tok_type], TK_NAME
    jne .accessor
    mov rax, [tok_val]
    cmp rax, [atom_static]
    jne .accessor
    call jslex_peek
    cmp dword [peek_type], TK_PUNCT
    jne .is_static
    cmp qword [peek_val], P_LPAREN
    je .key                         ; a method named static
    cmp qword [peek_val], P_ASSIGN
    je .key
    cmp qword [peek_val], P_SEMI
    je .key
    cmp qword [peek_val], P_LBRACE
    je .static_block
.is_static:
    or byte [rcx + JN_OP], CM_STATIC
    call jslex_next
.accessor:
    AT_PUNCT P_STAR
    jne .not_star
    or byte [rcx + JN_OP], CM_GEN
    call jslex_next
    jmp .key
.not_star:
    cmp dword [tok_type], TK_NAME
    jne .key
    mov rax, [tok_val]
    cmp rax, [atom_async]
    jne .not_async
    call jsp_modifier_ahead
    jnc .key
    or byte [rcx + JN_OP], CM_ASYNC
    call jslex_next
    jmp .key
.not_async:
    mov dl, CM_GET
    cmp rax, [atom_get]
    je .maybe_accessor
    mov dl, CM_SET
    cmp rax, [atom_set]
    jne .key
.maybe_accessor:
    call jslex_peek
    cmp dword [peek_type], TK_NAME
    je .is_accessor
    cmp dword [peek_type], TK_STR
    je .is_accessor
    cmp dword [peek_type], TK_NUM
    je .is_accessor
    cmp dword [peek_type], TK_PUNCT
    jne .key
    cmp qword [peek_val], P_LBRACK
    jne .key
.is_accessor:
    or [rcx + JN_OP], dl
    call jslex_next
.key:
    AT_PUNCT P_LBRACK
    je .computed
    mov eax, [tok_type]
    cmp eax, TK_NAME
    je .key_atom
    cmp eax, TK_STR
    je .key_atom
    cmp eax, TK_NUM
    jne jsp_unexpected
    mov rax, [tok_val]
    call js_number_to_atom
    mov [rcx + JN_A], rax
    call jslex_next
    jmp .after_key
.key_atom:
    mov rax, [tok_val]
    mov [rcx + JN_A], rax
    call jslex_next
    jmp .after_key
.computed:
    or byte [rcx + JN_OP], CM_COMPUTED
    call jslex_next
    call jsp_assign
    mov [rcx + JN_A], rax
    EXPECT P_RBRACK
.after_key:
    AT_PUNCT P_LPAREN
    jne .field
    ; the constructor?
    test byte [rcx + JN_OP], CM_STATIC | CM_GET | CM_SET | CM_COMPUTED | CM_ASYNC | CM_GEN
    jnz .method
    mov rax, [rcx + JN_A]
    cmp rax, [atom_constructor]
    jne .method
    mov [jsp_func], r10
    mov rax, [r10 + JFI_SCOPE]
    mov [jsp_scope], rax
    push rbx
    mov rbx, r10
    call jsp_params
    pop rbx
    EXPECT P_LBRACE
    call jsp_statement_list
    mov [r10 + JFI_BODY], rax
    AT_PUNCT P_RBRACE
    jne jsp_unexpected
    call jslex_next
    mov [jsp_func], r8
    mov [jsp_scope], r9
    mov qword [rbx + JN_E], 1
    jmp .member
.static_block:
    ; static { ... }: a hidden static method (" static"), called when the
    ; class is made
    or byte [rcx + JN_OP], CM_STATIC | CM_BLOCK
    call jslex_next                 ; (`static`: the token is the {)
    mov rax, [atom_static_block]
    mov [rcx + JN_A], rax
    push rcx
    mov al, NT_FUNC
    call jsp_node
    push rax
    xor ecx, ecx
    xor edx, edx
    mov byte [jsp_body_only], 1
    call jsp_function_rest
    mov rdx, rax
    pop rax
    mov [rax + JN_A], rdx
    pop rcx
    mov [rcx + JN_B], rax
    jmp .link
.method:
    xor edx, edx
    test byte [rcx + JN_OP], CM_COMPUTED
    jnz .method_fn
    mov rdx, [rcx + JN_A]
.method_fn:
    push rcx
    test byte [rcx + JN_OP], CM_ASYNC
    jz .method_sync
    mov dword [jsp_next_async], 1
.method_sync:
    test byte [rcx + JN_OP], CM_GEN
    jz .method_plain
    mov dword [jsp_next_gen], 1
.method_plain:
    mov al, NT_FUNC
    call jsp_node
    push rax
    xor ecx, ecx
    call jsp_function_rest
    mov rdx, rax
    pop rax
    mov [rax + JN_A], rdx
    pop rcx
    mov [rcx + JN_B], rax
    jmp .link
.field:
    or byte [rcx + JN_OP], CM_FIELD
    AT_PUNCT P_ASSIGN
    jne .field_end
    call jslex_next
    test byte [rcx + JN_OP], CM_STATIC
    jnz .static_value
    ; an instance field's value belongs to the constructor
    mov [jsp_func], r10
    mov rax, [r10 + JFI_SCOPE]
    mov [jsp_scope], rax
    call jsp_assign
    mov [jsp_func], r8
    mov [jsp_scope], r9
    jmp .field_value
.static_value:
    call jsp_assign
.field_value:
    mov [rcx + JN_B], rax
.field_end:
    call jsp_semicolon
    test byte [rcx + JN_OP], CM_STATIC
    jnz .link
    ; instance fields: the constructor's list
    test rdi, rdi
    jz .first_field
    mov [rdi + JN_NEXT], rcx
    jmp .field_linked
.first_field:
    mov [r10 + JFI_FIELDS], rcx
.field_linked:
    mov rdi, rcx
    jmp .member
.link:
    test rsi, rsi
    jz .first_member
    mov [rsi + JN_NEXT], rcx
    jmp .linked
.first_member:
    mov [rbx + JN_C], rcx
.linked:
    mov rsi, rcx
    jmp .member
.end:
    call jslex_next
    cmp qword [rbx + JN_E], 0
    jne .done
    cmp qword [rbx + JN_B], 0
    je .done
    ; a derived class without a constructor: constructor(... args) { super(... args) }
    mov [jsp_func], r10
    mov rax, [r10 + JFI_SCOPE]
    mov [jsp_scope], rax
    push rbx
    mov rbx, rax
    mov rdx, [atom_rest_args]
    mov cl, VK_VAR
    call jsp_scope_add
    pop rbx
    mov [r10 + JFI_REST], rax
    mov al, NT_IDENT
    call jsp_node
    mov [rax + JN_A], rdx
    mov rcx, rax
    mov al, NT_PARAM
    call jsp_node
    mov byte [rax + JN_OP], 1
    mov [rax + JN_A], rcx
    mov [r10 + JFI_PARAMS], rax
    mov al, NT_IDENT
    call jsp_node
    mov [rax + JN_A], rdx
    mov rcx, rax
    mov al, NT_SPREAD
    call jsp_node
    mov [rax + JN_A], rcx
    mov rcx, rax
    mov al, NT_SUPERCALL
    call jsp_node
    mov [rax + JN_B], rcx
    mov qword [rax + JN_C], 1
    or word [rax + JN_FLAGS], JNF_SPREAD
    mov rcx, rax
    mov al, NT_EXPR
    call jsp_node
    mov [rax + JN_A], rcx
    mov [r10 + JFI_BODY], rax
    mov [jsp_func], r8
    mov [jsp_scope], r9
.done:
    mov rax, r10
    call jsp_close_func             ; the constructor (and the fields)
    mov qword [rbx + JN_E], 0
    mov rax, rbx
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.no_name:
    lea rsi, [jsmsg_class_name]
    jmp jslex_error

; jsp_spread: current token '...' -> RAX = NT_SPREAD of the expression after it
jsp_spread:
    push rbx
    mov al, NT_SPREAD
    call jsp_node
    mov rbx, rax
    call jslex_next
    call jsp_assign
    mov [rbx + JN_A], rax
    mov rax, rbx
    pop rbx
    ret

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
    xor esi, esi                    ; 1 = an async method
    AT_PUNCT P_RBRACE
    je .done
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
    AT_PUNCT P_STAR
    jne .not_star
    or esi, 2                       ; *method() {}
    call jslex_next
    jmp .key
.not_star:
    AT_PUNCT P_ELLIPSIS
    jne .key
    ; ...spread: its own enumerable properties
    mov byte [r8 + JN_OP], 2
    call jslex_next
    call jsp_assign
    mov [r8 + JN_A], rax
    jmp .next
.key:
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
    ; async methods: `async name(` ...
    mov rdx, [tok_val]
    test esi, 1
    jnz .not_async
    cmp rdx, [atom_async]
    jne .not_async
    call jsp_modifier_ahead
    jnc .not_async
    or esi, 1
    call jslex_next
    AT_PUNCT P_STAR
    jne .key
    or esi, 2
    call jslex_next
    jmp .key
.not_async:
    ; get/set accessors: `get name(` ...
    cmp rdx, [atom_get]
    je .maybe_accessor
    cmp rdx, [atom_set]
    jne .key_atom
.maybe_accessor:
    call jslex_peek
    cmp dword [peek_type], TK_NAME
    je .accessor
    cmp dword [peek_type], TK_STR
    je .accessor
    cmp dword [peek_type], TK_NUM
    je .accessor
.key_atom:
    mov rdx, [tok_val]
    mov [r8 + JN_A], rdx
    call jslex_next
    jmp .value
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
    call jsp_note_use
    mov al, NT_IDENT
    call jsp_node
    mov [rax + JN_A], rdx
    mov [r8 + JN_B], rax
    cmp rdx, [atom_arguments]
    jne .cover
    call jsp_use_arguments
.cover:
    ; {a = 1} is only valid as a pattern ({a = 1} = obj)
    AT_PUNCT P_ASSIGN
    jne .next
    mov al, NT_ASSIGN
    call jsp_node
    mov byte [rax + JN_OP], P_ASSIGN
    mov rdx, [r8 + JN_B]
    mov [rax + JN_A], rdx
    mov [r8 + JN_B], rax
    mov rdx, rax
    call jslex_next
    call jsp_assign
    mov [rdx + JN_B], rax
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
    mov eax, esi
    and eax, 1
    mov [jsp_next_async], eax
    mov eax, esi
    shr eax, 1
    mov [jsp_next_gen], eax
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
.accessor:
    ; get key() { } / set key(value) { }
    mov byte [r8 + JN_OP], 3
    cmp rdx, [atom_get]
    je .accessor_key
    mov byte [r8 + JN_OP], 4
.accessor_key:
    call jslex_next
    mov rdx, [tok_val]
    cmp dword [tok_type], TK_NUM
    jne .accessor_name
    mov rax, rdx
    call js_number_to_atom
    mov rdx, rax
.accessor_name:
    mov [r8 + JN_A], rdx
    call jslex_next
    mov al, NT_FUNC
    call jsp_node
    push rax
    xor ecx, ecx
    call jsp_function_rest
    mov rcx, rax
    pop rax
    mov [rax + JN_A], rcx
    mov [r8 + JN_B], rax
    jmp .next

section .rodata
jsfeat_generator:       db "function* (generators)", 0
jsmsg_rest_last:        db "Rest parameter must be last formal parameter", 0
jsmsg_class_name:       db "A class declaration needs a name", 0
