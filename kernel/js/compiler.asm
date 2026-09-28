; ==============================================================================
; Antigravity OS - JavaScript compiler: syntax tree -> bytecode
; ------------------------------------------------------------------------------
; jsc_compile_script turns the parser's tree into JK_CODE templates (one per
; function) on the heap. Code is emitted into JS_CODEBUF_ADDR; a nested
; function is emitted after its parent's partial code, copied to the heap and
; its scratch space handed back, so the parent continues where it was.
;
; Where variables live:
;   * a function without inner functions keeps every variable (parameters,
;     var, let, const) in stack slots of its frame: GETLOC/SETLOC;
;   * a function with inner functions keeps them in heap environments that
;     closures can capture: one for the function scope (made by the call)
;     and one per block scope that declares something (ENTERENV/LEAVEENV).
;     GETENV depth,index walks `depth` parent links;
;   * names declared nowhere, and top-level declarations, are properties of
;     the global object: GETGLOB/SETGLOB.
; Compile routines preserve every register except RAX.
; ==============================================================================

[bits 64]

; Loop / switch / label contexts (for break and continue)
JLC_PARENT              equ 0
JLC_LABEL               equ 8           ; atom or 0
JLC_KIND                equ 16          ; byte, LC_*
JLC_POPS                equ 17          ; byte, stack values to drop when jumping out past it
JLC_BREAK_ENV           equ 20          ; dword, env depth at the break target
JLC_CONT_ENV            equ 24          ; dword, env depth at the continue target
JLC_BREAKS              equ 32          ; patch list
JLC_CONTS               equ 40          ; patch list
JLC_FINALLY             equ 48          ; LC_TRY: the finally block (0 = none)
JLC_SCOPE               equ 56          ; LC_TRY: the scope at the try statement
JLC_SIZE                equ 64
LC_LOOP                 equ 1
LC_SWITCH               equ 2
LC_BLOCK                equ 3
LC_TRY                  equ 4           ; inside try { } (or catch { } with a finally)

; Name resolution results (jsc_resolve)
RES_LOCAL               equ 1
RES_ENV                 equ 2
RES_GLOBAL              equ 3

section .rodata
; binary / compound-assignment operator -> opcode
jsc_binops:
    db P_PLUS, OP_ADD, P_MINUS, OP_SUB, P_STAR, OP_MUL, P_SLASH, OP_DIV
    db P_PERCENT, OP_MOD, P_SHL, OP_SHL, P_SAR, OP_SAR, P_SHR, OP_SHR
    db P_AMP, OP_BAND, P_PIPE, OP_BOR, P_CARET, OP_BXOR, P_EQ, OP_EQ
    db P_NE, OP_NE, P_SEQ, OP_SEQ, P_SNE, OP_SNE, P_LT, OP_LT, P_LE, OP_LE
    db P_GT, OP_GT, P_GE, OP_GE, OPB_IN, OP_IN, OPB_INSTANCEOF, OP_INSTANCEOF
    db P_STARSTAR, OP_POW, P_POW_ASSIGN, OP_POW
    db P_ADD_ASSIGN, OP_ADD, P_SUB_ASSIGN, OP_SUB, P_MUL_ASSIGN, OP_MUL
    db P_DIV_ASSIGN, OP_DIV, P_MOD_ASSIGN, OP_MOD, P_SHL_ASSIGN, OP_SHL
    db P_SAR_ASSIGN, OP_SAR, P_SHR_ASSIGN, OP_SHR, P_AND_ASSIGN, OP_BAND
    db P_OR_ASSIGN, OP_BOR, P_XOR_ASSIGN, OP_BXOR
    db 0
jsmsg_illegal_break:    db "Illegal break statement", 0
jsmsg_illegal_continue: db "Illegal continue statement: no surrounding iteration statement", 0
jsmsg_undefined_label:  db "Undefined label '%'", 0

section .bss
alignb 8
jsc_code_ptr:           resq 1          ; next free byte in JS_CODEBUF
jsc_code_start:         resq 1          ; start of the current function's code
jsc_fi:                 resq 1          ; current function info
jsc_scope:              resq 1          ; current scope
jsc_loop:               resq 1          ; innermost loop context
jsc_pending_label:      resq 1          ; label for the next loop
jsc_script:             resq 1          ; the script's function info
jsc_chain:              resq 1          ; patch list of the ?. in the current chain
jsc_env_depth:          resd 1          ; block envs entered in this function
jsc_completion:         resd 1          ; 1 = expression statements set the completion value
jsc_line:               resd 1          ; line of the last OP_LINE
                        resd 1          ; (jsc_function saves jsc_line as a qword)

section .text

; ------------------------------------------------------------------------------
; jsc_compile_script: RAX = script function info -> RAX = its JK_CODE template
; ------------------------------------------------------------------------------
jsc_compile_script:
    mov [jsc_script], rax
    mov qword [jsc_code_ptr], JS_CODEBUF_ADDR
    mov qword [jsc_fi], 0
    mov qword [jsc_scope], 0
    mov qword [jsc_loop], 0
    mov qword [jsc_pending_label], 0
    jmp jsc_function

; ==============================================================================
; Emitting
; ==============================================================================

; jsc_room: make sure 32 more bytes fit in the code buffer
jsc_room:
    push rax
    mov rax, [jsc_code_ptr]
    add rax, 32
    cmp rax, JS_CODEBUF_ADDR + JS_CODEBUF_SIZE
    pop rax
    ja .full
    ret
.full:
    lea rsi, [jsmsg_too_big]
    jmp jslex_error

; jsc_op: AL = opcode (or any byte)
jsc_op:
    call jsc_room
    push rdi
    mov rdi, [jsc_code_ptr]
    mov [rdi], al
    inc rdi
    mov [jsc_code_ptr], rdi
    pop rdi
    ret

; jsc_u16 / jsc_u32 / jsc_u64: operand in AX / EAX / RAX
jsc_u16:
    push rdi
    mov rdi, [jsc_code_ptr]
    mov [rdi], ax
    add rdi, 2
    mov [jsc_code_ptr], rdi
    pop rdi
    ret

jsc_u32:
    push rdi
    mov rdi, [jsc_code_ptr]
    mov [rdi], eax
    add rdi, 4
    mov [jsc_code_ptr], rdi
    pop rdi
    ret

jsc_u64:
    push rdi
    mov rdi, [jsc_code_ptr]
    mov [rdi], rax
    add rdi, 8
    mov [jsc_code_ptr], rdi
    pop rdi
    ret

; jsc_op_u32: AL = opcode, EDX = 32-bit operand
jsc_op_u32:
    call jsc_op
    push rax
    mov eax, edx
    call jsc_u32
    pop rax
    ret

; jsc_op_u32_cache: AL = opcode, EDX = atom; operand + a zero cache slot
jsc_op_u32_cache:
    call jsc_op_u32
    push rax
    xor eax, eax
    call jsc_u32
    pop rax
    ret

; jsc_jump: AL = jump opcode -> RAX = address of its rel32 (patch it later)
jsc_jump:
    call jsc_op
    mov rax, [jsc_code_ptr]
    push rax
    xor eax, eax
    call jsc_u32
    pop rax
    ret

; jsc_jump_to: AL = jump opcode, RDX = target address
jsc_jump_to:
    push rax
    call jsc_op
    mov rax, rdx
    sub rax, [jsc_code_ptr]
    sub rax, 4
    call jsc_u32
    pop rax
    ret

; jsc_patch_here: RAX = rel32 address -> jumps to the current position
jsc_patch_here:
    push rdx
    mov rdx, [jsc_code_ptr]
    call jsc_patch_to
    pop rdx
    ret

; jsc_patch_to: RAX = rel32 address, RDX = target
jsc_patch_to:
    push rcx
    mov rcx, rdx
    sub rcx, rax
    sub rcx, 4
    mov [rax], ecx
    pop rcx
    ret

; jsc_add_patch: RBX = address of a patch list head, RAX = rel32 address
jsc_add_patch:
    push rax
    push rcx
    mov rcx, rax
    push rcx
    mov ecx, 16
    call jsp_alloc
    pop rcx
    mov [rax + 8], rcx
    mov rcx, [rbx]
    mov [rax], rcx
    mov [rbx], rax
    pop rcx
    pop rax
    ret

; jsc_resolve_patches: RAX = patch list, RDX = target
jsc_resolve_patches:
    push rax
    push rbx
    mov rbx, rax
.loop:
    test rbx, rbx
    jz .done
    mov rax, [rbx + 8]
    call jsc_patch_to
    mov rbx, [rbx]
    jmp .loop
.done:
    pop rbx
    pop rax
    ret

; jsc_line_of: RAX = node; emits OP_LINE when the line changed
jsc_line_of:
    push rax
    push rdx
    mov edx, [rax + JN_LINE]
    cmp edx, [jsc_line]
    je .same
    mov [jsc_line], edx
    mov al, OP_LINE
    call jsc_op_u32
.same:
    pop rdx
    pop rax
    ret

; ==============================================================================
; Functions and scopes
; ==============================================================================

; ------------------------------------------------------------------------------
; jsc_function: RAX = function info -> RAX = compiled JK_CODE template
; ------------------------------------------------------------------------------
jsc_function:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push qword [jsc_code_start]
    push qword [jsc_fi]
    push qword [jsc_scope]
    push qword [jsc_loop]
    push qword [jsc_pending_label]
    push qword [jsc_env_depth]      ; + jsc_completion
    push qword [jsc_line]
    mov rbx, rax
    mov [jsc_fi], rbx
    mov rax, [rbx + JFI_SCOPE]
    mov [jsc_scope], rax
    mov qword [jsc_loop], 0
    mov qword [jsc_pending_label], 0
    mov dword [jsc_env_depth], 0
    mov dword [jsc_line], 0
    xor eax, eax
    test dword [rbx + JFI_FLAGS], FIF_SCRIPT
    setnz al
    mov [jsc_completion], eax
    mov rax, [jsc_code_ptr]
    mov [jsc_code_start], rax
    call jsc_assign_slots
    ; top-level var/let/const/function names exist before the code runs
    mov rsi, [rbx + JFI_GLOBALS]
.globals:
    test rsi, rsi
    jz .body
    mov rdx, [rsi + JVR_NAME]
    mov al, OP_DECLGLOB
    call jsc_op_u32
    mov rsi, [rsi + JVR_NEXT]
    jmp .globals
.body:
    ; an async function: a promise, and every error rejects it
    test dword [rbx + JFI_FLAGS], FIF_ASYNC
    jz .params
    mov al, OP_ASYNCSTART
    call jsc_op
    mov al, OP_TRY
    call jsc_jump
    mov [rbx + JFI_ASYNCTRY], rax
.params:
    test dword [rbx + JFI_FLAGS], FIF_PARAMCODE
    jz .fields
    call jsc_param_code
.fields:
    ; a base class's constructor sets its fields first (a derived one after super())
    mov eax, [rbx + JFI_FLAGS]
    and eax, FIF_CLASSCTOR | FIF_DERIVED
    cmp eax, FIF_CLASSCTOR
    jne .hoist
    mov rax, rbx
    call jsc_fields
.hoist:
    ; function declarations first (hoisting), then the statements
    mov rax, [rbx + JFI_BODY]
    call jsc_hoist
    call jsc_statements
    test dword [rbx + JFI_FLAGS], FIF_SCRIPT
    jz .plain_end
    mov al, OP_GETCOMPL
    call jsc_op
    mov al, OP_RET
    call jsc_op
    jmp .template
.plain_end:
    mov al, OP_RETUNDEF
    call jsc_op
    test dword [rbx + JFI_FLAGS], FIF_ASYNC
    jz .template
    mov rax, [rbx + JFI_ASYNCTRY]
    call jsc_patch_here
    mov al, OP_ASYNCREJECT
    call jsc_op
.template:
    mov ecx, JCODE_SIZE
    call js_alloc_perm
    mov rdi, rax
    mov byte [rdi + JH_KIND], JK_CODE
    mov ecx, [rbx + JFI_FLAGS]
    xor eax, eax
    test ecx, FIF_INNER
    jz .f1
    or al, JCF_HEAPENV
.f1:
    test ecx, FIF_ARGS
    jz .f2
    or al, JCF_ARGUMENTS
.f2:
    test ecx, FIF_SELF
    jz .f3
    or al, JCF_SELF
.f3:
    test ecx, FIF_SCRIPT
    jz .f4
    or al, JCF_SCRIPT
.f4:
    test ecx, FIF_ARROW
    jz .f5
    or al, JCF_ARROW
.f5:
    test ecx, FIF_CLASSCTOR
    jz .f5a
    or al, JCF_CLASSCTOR
.f5a:
    test ecx, FIF_DERIVED
    jz .f5b
    or al, JCF_DERIVED
.f5b:
    cmp qword [rbx + JFI_REST], 0
    je .f6
    or al, JCF_REST
    mov rcx, [rbx + JFI_REST]
    mov ecx, [rcx + JVR_SLOT]
    mov [rdi + JCODE_RESTSLOT], ecx
.f6:
    mov [rdi + JCODE_FLAGS], al
    xor eax, eax
    test dword [rbx + JFI_FLAGS], FIF_ASYNC
    jz .f7
    or eax, JCF2_ASYNC
.f7:
    mov [rdi + JCODE_FLAGS2], eax
    mov eax, [rbx + JFI_NPARAMS]
    mov [rdi + JCODE_NPARAMS], ax
    mov eax, [rbx + JFI_NLOCALS]
    mov [rdi + JCODE_NLOCALS], eax
    mov rax, [rbx + JFI_SCOPE]
    mov eax, [rax + JSC_NVARS]
    mov [rdi + JCODE_NENV], eax
    mov rax, [rbx + JFI_NAME]
    mov [rdi + JCODE_NAME], rax
    mov eax, [rbx + JFI_LINE]
    mov [rdi + JCODE_LINE], eax
    ; slots of `arguments` and of the function's own name
    mov rsi, [rbx + JFI_SCOPE]
    mov rsi, [rsi + JSC_VARS]
.special:
    test rsi, rsi
    jz .code
    mov eax, [rsi + JVR_SLOT]
    cmp byte [rsi + JVR_KIND], VK_ARGS
    jne .not_args
    mov [rdi + JCODE_ARGSLOT], eax
.not_args:
    cmp byte [rsi + JVR_KIND], VK_SELF
    jne .next_special
    mov [rdi + JCODE_SELFSLOT], eax
.next_special:
    mov rsi, [rsi + JVR_NEXT]
    jmp .special
.code:
    ; copy the bytecode to the heap and give the scratch space back
    mov rcx, [jsc_code_ptr]
    sub rcx, [jsc_code_start]
    mov [rdi + JCODE_LEN], ecx
    call js_alloc_perm
    mov [rdi + JCODE_CODE], rax
    push rdi
    mov rsi, [jsc_code_start]
    mov rdi, rax
    rep movsb
    pop rdi
    mov rax, [jsc_code_start]
    mov [jsc_code_ptr], rax
    mov [rbx + JFI_TEMPLATE], rdi
    mov rax, rdi
    pop qword [jsc_line]
    pop qword [jsc_env_depth]
    pop qword [jsc_pending_label]
    pop qword [jsc_loop]
    pop qword [jsc_scope]
    pop qword [jsc_fi]
    pop qword [jsc_code_start]
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsc_assign_slots: RBX = function info; gives every variable its slot and
; marks which scopes make heap environments. Parameters come first (the call
; puts the arguments in slots 0..n-1).
jsc_assign_slots:
    push rax
    push rcx
    push rsi
    mov rsi, [rbx + JFI_SCOPES]
    xor ecx, ecx                    ; next stack slot (stack functions)
    test dword [rbx + JFI_FLAGS], FIF_INNER
    jnz .heap
.stack_scope:
    test rsi, rsi
    jz .stack_done
    mov byte [rsi + JSC_ENV], 0
    call .number
    mov rsi, [rsi + JSC_NEXT]
    jmp .stack_scope
.stack_done:
    mov [rbx + JFI_NLOCALS], ecx
    jmp .out
.heap:
    test rsi, rsi
    jz .heap_done
    xor ecx, ecx
    call .number
    mov byte [rsi + JSC_ENV], 1
    cmp rsi, [rbx + JFI_SCOPE]
    je .heap_next                   ; the function scope always gets one
    test ecx, ecx
    jnz .heap_next
    mov byte [rsi + JSC_ENV], 0     ; a block that declares nothing
.heap_next:
    mov rsi, [rsi + JSC_NEXT]
    jmp .heap
.heap_done:
    mov eax, [rbx + JFI_NPARAMS]
    mov [rbx + JFI_NLOCALS], eax
.out:
    pop rsi
    pop rcx
    pop rax
    ret
; .number: RSI = scope, ECX = next slot -> its variables numbered (in the
; function scope: parameters, then the rest)
.number:
    push rax
    cmp rsi, [rbx + JFI_SCOPE]
    jne .all
    mov rax, [rsi + JSC_VARS]
.params:
    test rax, rax
    jz .others
    cmp byte [rax + JVR_KIND], VK_PARAM
    jne .param_next
    mov [rax + JVR_SLOT], ecx
    inc ecx
.param_next:
    mov rax, [rax + JVR_NEXT]
    jmp .params
.others:
    mov rax, [rsi + JSC_VARS]
.other:
    test rax, rax
    jz .numbered
    cmp byte [rax + JVR_KIND], VK_PARAM
    je .other_next
    mov [rax + JVR_SLOT], ecx
    inc ecx
.other_next:
    mov rax, [rax + JVR_NEXT]
    jmp .other
.all:
    mov rax, [rsi + JSC_VARS]
.any:
    test rax, rax
    jz .numbered
    mov [rax + JVR_SLOT], ecx
    inc ecx
    mov rax, [rax + JVR_NEXT]
    jmp .any
.numbered:
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsc_resolve: RDX = atom -> EAX = RES_*, ECX = slot, EBX = env depth,
; RSI = variable record (0 for globals)
; ------------------------------------------------------------------------------
jsc_resolve:
    push rdi
    push r8
    mov rdi, [jsc_scope]
    xor r8d, r8d                    ; env depth
.scope:
    test rdi, rdi
    jz .global
    mov rsi, [rdi + JSC_VARS]
.var:
    test rsi, rsi
    jz .next_scope
    cmp [rsi + JVR_NAME], rdx
    je .found
    mov rsi, [rsi + JVR_NEXT]
    jmp .var
.next_scope:
    cmp byte [rdi + JSC_ENV], 0
    je .no_env
    inc r8d
.no_env:
    mov rdi, [rdi + JSC_PARENT]
    jmp .scope
.found:
    mov ecx, [rsi + JVR_SLOT]
    mov ebx, r8d
    mov rax, [rdi + JSC_FUNC]
    cmp rax, [jsc_fi]
    jne .env
    test dword [rax + JFI_FLAGS], FIF_INNER
    jnz .env
    mov eax, RES_LOCAL
    jmp .out
.env:
    mov eax, RES_ENV
    jmp .out
.global:
    xor esi, esi
    mov eax, RES_GLOBAL
.out:
    pop r8
    pop rdi
    ret

; jsc_load: RDX = atom -> emits code pushing the variable's value
jsc_load:
    push rax
    push rbx
    push rcx
    push rsi
    call jsc_resolve
    cmp eax, RES_LOCAL
    je .local
    cmp eax, RES_ENV
    je .env
    mov al, OP_GETGLOB
    call jsc_op_u32_cache
    jmp .out
.local:
    mov al, OP_GETLOC
    call jsc_op
    mov eax, ecx
    call jsc_u16
    jmp .out
.env:
    mov al, OP_GETENV
    call jsc_op
    mov al, bl
    call jsc_op
    mov eax, ecx
    call jsc_u16
.out:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; jsc_store: RDX = atom, EDI = 1 when this initialises the declaration
; -> emits code storing the top of the stack (which stays there)
jsc_store:
    push rax
    push rbx
    push rcx
    push rsi
    call jsc_resolve
    test edi, edi
    jnz .kind_ok
    test rsi, rsi
    jnz .check_const
    ; a global: a top-level const?
    push rbx
    mov rbx, [jsc_script]
    lea rbx, [rbx + JFI_GLOBALS - JSC_VARS]
    push rax
    call jsp_scope_find
    mov rsi, rax
    pop rax
    pop rbx
    jc .no_record
.check_const:
    cmp byte [rsi + JVR_KIND], VK_CONST
    jne .kind_ok
    push rax
    mov al, OP_CONSTERR
    call jsc_op_u32
    pop rax
    jmp .kind_ok
.no_record:
    xor esi, esi
.kind_ok:
    cmp eax, RES_LOCAL
    je .local
    cmp eax, RES_ENV
    je .env
    mov al, OP_SETGLOB
    call jsc_op_u32_cache
    jmp .out
.local:
    mov al, OP_SETLOC
    call jsc_op
    mov eax, ecx
    call jsc_u16
    jmp .out
.env:
    mov al, OP_SETENV
    call jsc_op
    mov al, bl
    call jsc_op
    mov eax, ecx
    call jsc_u16
.out:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; jsc_enter_scope: RAX = scope (or 0) -> makes it current, emits ENTERENV when
; it has a heap env. -> RAX = previous scope (give it to jsc_leave_scope)
jsc_enter_scope:
    test rax, rax
    jz .none
    push rdx
    mov rdx, [jsc_scope]
    mov [jsc_scope], rax
    cmp byte [rax + JSC_ENV], 0
    je .no_env
    push rax
    mov al, OP_ENTERENV
    call jsc_op
    mov rax, [rsp]
    mov eax, [rax + JSC_NVARS]
    call jsc_u16
    pop rax
    inc dword [jsc_env_depth]
.no_env:
    mov rax, rdx
    pop rdx
    ret
.none:
    mov rax, [jsc_scope]
    ret

; jsc_leave_scope: RAX = scope to go back to; emits LEAVEENV if the current
; scope made an env
jsc_leave_scope:
    push rdx
    mov rdx, [jsc_scope]
    cmp rdx, rax
    je .same
    cmp byte [rdx + JSC_ENV], 0
    je .restore
    push rax
    mov al, OP_LEAVEENV
    call jsc_op
    pop rax
    dec dword [jsc_env_depth]
.restore:
    mov [jsc_scope], rax
.same:
    pop rdx
    ret

; jsc_hoist: RAX = first statement; function declarations in this list are
; created before anything else runs
jsc_hoist:
    push rax
    push rbx
    push rdx
    push rdi
    mov rbx, rax
.loop:
    test rbx, rbx
    jz .done
    cmp byte [rbx + JN_TYPE], NT_FUNCDECL
    jne .next
    or word [rbx + JN_FLAGS], 1     ; created here, not where it stands
    call jsc_funcdecl
.next:
    mov rbx, [rbx + JN_NEXT]
    jmp .loop
.done:
    pop rdi
    pop rdx
    pop rbx
    pop rax
    ret

; jsc_funcdecl: RBX = NT_FUNCDECL -> creates the function and binds its name
jsc_funcdecl:
    push rax
    push rdx
    push rdi
    mov rax, [rbx + JN_A]
    mov rdx, [rax + JFI_NAME]
    call jsc_function
    push rdx
    mov edx, eax
    mov al, OP_CLOSURE
    call jsc_op_u32
    pop rdx
    mov edi, 1
    call jsc_store
    mov al, OP_POP
    call jsc_op
    pop rdi
    pop rdx
    pop rax
    ret

; ==============================================================================
; Statements
; ==============================================================================

; jsc_statements: RAX = first statement of a list
jsc_statements:
    push rax
.loop:
    test rax, rax
    jz .done
    call jsc_stmt
    mov rax, [rax + JN_NEXT]
    jmp .loop
.done:
    pop rax
    ret

; jsc_stmt: RAX = statement node
jsc_stmt:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rbx, rax
    movzx ecx, byte [rbx + JN_TYPE]
    cmp ecx, NT_FUNCDECL
    je .funcdecl
    cmp ecx, NT_EMPTY
    je .out
    cmp ecx, NT_BLOCK
    je .block
    cmp ecx, NT_LABELED
    je .labeled
    call jsc_line_of
    cmp ecx, NT_EXPR
    je .expr
    cmp ecx, NT_VAR
    je .var
    cmp ecx, NT_IF
    je .if
    cmp ecx, NT_WHILE
    je .while
    cmp ecx, NT_DOWHILE
    je .dowhile
    cmp ecx, NT_FOR
    je .for
    cmp ecx, NT_FORIN
    je .forin
    cmp ecx, NT_RETURN
    je .return
    cmp ecx, NT_BREAK
    je .jump
    cmp ecx, NT_CONTINUE
    je .jump
    cmp ecx, NT_THROW
    je .throw
    cmp ecx, NT_SWITCH
    je .switch
    cmp ecx, NT_TRY
    je .try
    cmp ecx, NT_CLASS
    je .class
    jmp .out
.expr:
    mov rax, [rbx + JN_A]
    call jsc_expr
    mov al, OP_POP
    cmp dword [jsc_completion], 0
    je .expr_op
    mov al, OP_COMPLETION
.expr_op:
    call jsc_op
    jmp .out
.var:
    call jsc_declarations
    jmp .out
.block:
    mov rax, [rbx + JN_E]
    call jsc_enter_scope
    mov rdx, rax
    mov rax, [rbx + JN_A]
    call jsc_hoist
    call jsc_statements
    mov rax, rdx
    call jsc_leave_scope
    jmp .out
.if:
    mov rax, [rbx + JN_A]
    call jsc_expr
    mov al, OP_JF
    call jsc_jump
    mov rsi, rax                    ; -> else
    mov rax, [rbx + JN_B]
    call jsc_stmt
    cmp qword [rbx + JN_C], 0
    je .if_end
    mov al, OP_JMP
    call jsc_jump
    mov rdi, rax                    ; -> end
    mov rax, rsi
    call jsc_patch_here
    mov rax, [rbx + JN_C]
    call jsc_stmt
    mov rax, rdi
    call jsc_patch_here
    jmp .out
.if_end:
    mov rax, rsi
    call jsc_patch_here
    jmp .out
.return:
    mov rax, [rbx + JN_A]
    test rax, rax
    jz .return_undef
    call jsc_expr
    call jsc_leave_tries             ; ENDTRY and finally blocks on the way out
    mov al, OP_RET
    call jsc_op
    jmp .out
.return_undef:
    mov al, OP_UNDEF
    call jsc_op
    call jsc_leave_tries
    mov al, OP_RET
    call jsc_op
    jmp .out
.throw:
    mov rax, [rbx + JN_A]
    call jsc_expr
    mov al, OP_THROW
    call jsc_op
    jmp .out
.while:
    call jsc_while
    jmp .out
.dowhile:
    call jsc_dowhile
    jmp .out
.for:
    call jsc_for
    jmp .out
.forin:
    call jsc_forin
    jmp .out
.switch:
    call jsc_switch
    jmp .out
.try:
    call jsc_try
    jmp .out
.class:
    call jsc_class
    mov rdx, [rbx + JN_A]
    mov edi, 1
    call jsc_store
    mov al, OP_POP
    call jsc_op
    jmp .out
.jump:
    call jsc_break_continue
    jmp .out
.labeled:
    call jsc_labeled
    jmp .out
.funcdecl:
    ; hoisted with its statement list, unless it is a lone statement
    ; (if (x) function f() {})
    test word [rbx + JN_FLAGS], 1
    jnz .out
    call jsc_funcdecl
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsc_declarations: RBX = NT_VAR node
jsc_declarations:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    movzx ecx, byte [rbx + JN_OP]
    mov rsi, [rbx + JN_A]
    mov edi, 1                      ; initialising
.decl:
    test rsi, rsi
    jz .done
    mov rdx, [rsi + JN_A]
    mov rax, [rsi + JN_B]
    test word [rsi + JN_FLAGS], JNF_PATTERN
    jnz .pattern
    test rax, rax
    jz .no_init
    call jsc_named_expr
    jmp .store
.pattern:
    test rax, rax
    jnz .pattern_value
    mov al, OP_UNDEF
    call jsc_op
    jmp .pattern_store
.pattern_value:
    call jsc_expr
.pattern_store:
    mov rax, rdx
    call jsc_destructure            ; (EDI = 1: declarations)
    jmp .next
.no_init:
    cmp ecx, KW_VAR
    je .next
    mov al, OP_UNDEF                ; let x;  (fresh each time round a loop)
    call jsc_op
.store:
    call jsc_store
    mov al, OP_POP
    call jsc_op
.next:
    mov rsi, [rsi + JN_NEXT]
    jmp .decl
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsc_named_expr: RAX = expression, RDX = the name it is assigned to; an
; anonymous function gets that name (var f = function () {})
jsc_named_expr:
    cmp byte [rax + JN_TYPE], NT_FUNC
    jne jsc_expr
    push rbx
    mov rbx, [rax + JN_A]
    cmp qword [rbx + JFI_NAME], 0
    jne .named
    mov [rbx + JFI_NAME], rdx
.named:
    pop rbx
    jmp jsc_expr

; ------------------------------------------------------------------------------
; Loops. Each pushes a context for break/continue (jsc_push_loop).
; ------------------------------------------------------------------------------

; jsc_pops: ECX = values to drop -> that many OP_POPs, ECX = 0
jsc_pops:
    push rax
    mov al, OP_POP
.loop:
    test ecx, ecx
    jz .done
    call jsc_op
    dec ecx
    jmp .loop
.done:
    pop rax
    ret

; jsc_leave_try: RAX = an LC_TRY context being left by a jump -> LEAVEENV down
; to its env depth, ENDTRY, then its finally block (compiled as it stands at
; the try statement). jsc_env_depth is the try's afterwards.
jsc_leave_try:
    push rax
    push rbx
    push rcx
    mov rbx, rax
    mov ecx, [jsc_env_depth]
    sub ecx, [rbx + JLC_BREAK_ENV]
    mov al, OP_LEAVEENV
.leave:
    test ecx, ecx
    jle .left
    call jsc_op
    dec ecx
    jmp .leave
.left:
    mov eax, [rbx + JLC_BREAK_ENV]
    mov [jsc_env_depth], eax
    mov al, OP_ENDTRY
    call jsc_op
    mov rax, [rbx + JLC_FINALLY]
    test rax, rax
    jz .done
    push qword [jsc_loop]
    push qword [jsc_scope]
    mov rcx, [rbx + JLC_PARENT]
    mov [jsc_loop], rcx
    mov rcx, [rbx + JLC_SCOPE]
    mov [jsc_scope], rcx
    call jsc_stmt
    pop qword [jsc_scope]
    pop qword [jsc_loop]
.done:
    pop rcx
    pop rbx
    pop rax
    ret

; jsc_leave_tries: before a return: every try of this function, innermost
; first (the return value stays on the stack meanwhile)
jsc_leave_tries:
    push rax
    push rbx
    push qword [jsc_env_depth]
    mov rbx, [jsc_loop]
.loop:
    test rbx, rbx
    jz .done
    cmp byte [rbx + JLC_KIND], LC_TRY
    jne .next
    mov rax, rbx
    call jsc_leave_try
.next:
    mov rbx, [rbx + JLC_PARENT]
    jmp .loop
.done:
    pop qword [jsc_env_depth]
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsc_try: RBX = NT_TRY
;     TRY -> fin                     (with a finally block)
;       TRY -> catch                 (with a catch block)
;         block
;       ENDTRY, JMP after
;     catch: [bind the exception] catch block
;     after:
;     ENDTRY, finally block, JMP end
;   fin: finally block, THROW        (the exception is on the stack)
;   end:
; ------------------------------------------------------------------------------
jsc_try:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push qword [jsc_pending_label]
    mov qword [jsc_pending_label], 0
    xor r8d, r8d                    ; the finally context
    cmp qword [rbx + JN_D], 0
    je .no_finally
    mov al, LC_TRY
    xor ecx, ecx
    call jsc_push_loop
    mov r8, rax
    mov rcx, [rbx + JN_D]
    mov [r8 + JLC_FINALLY], rcx
    mov rcx, [jsc_scope]
    mov [r8 + JLC_SCOPE], rcx
    mov al, OP_TRY
    call jsc_jump
    mov r9, rax                     ; -> fin
.no_finally:
    cmp qword [rbx + JN_C], 0
    je .no_catch
    mov al, LC_TRY
    xor ecx, ecx
    call jsc_push_loop
    mov rdi, rax
    mov rcx, [jsc_scope]
    mov [rdi + JLC_SCOPE], rcx
    mov al, OP_TRY
    call jsc_jump
    mov rsi, rax                    ; -> catch
    mov rax, [rbx + JN_A]
    call jsc_stmt
    mov al, OP_ENDTRY
    call jsc_op
    mov rax, rdi
    call jsc_pop_loop
    mov al, OP_JMP
    call jsc_jump
    mov rdi, rax                    ; -> after
    mov rax, rsi
    call jsc_patch_here
    ; catch: the exception is on the stack
    mov rax, [rbx + JN_E]
    call jsc_enter_scope
    mov rsi, rax
    mov rdx, [rbx + JN_B]
    test rdx, rdx
    jz .no_binding
    push rdi
    mov edi, 1
    mov rax, rdx
    cmp byte [rbx + JN_OP], 1
    je .catch_pattern
    call jsc_store
    pop rdi
.no_binding:
    mov al, OP_POP
    call jsc_op
    jmp .catch_body
.catch_pattern:
    call jsc_destructure
    pop rdi
.catch_body:
    mov rax, [rbx + JN_C]
    call jsc_stmt
    mov rax, rsi
    call jsc_leave_scope
    mov rax, rdi
    call jsc_patch_here
    jmp .body_done
.no_catch:
    mov rax, [rbx + JN_A]
    call jsc_stmt
.body_done:
    test r8, r8
    jz .done
    mov al, OP_ENDTRY
    call jsc_op
    mov rax, r8
    call jsc_pop_loop
    mov rax, [rbx + JN_D]
    call jsc_stmt
    mov al, OP_JMP
    call jsc_jump
    mov rdi, rax                    ; -> end
    mov rax, r9
    call jsc_patch_here
    mov rax, [rbx + JN_D]
    call jsc_stmt
    mov al, OP_THROW
    call jsc_op
    mov rax, rdi
    call jsc_patch_here
.done:
    pop qword [jsc_pending_label]
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsc_push_loop: AL = LC_*, CL = values on the stack while inside it
; -> RAX = context (its label is the pending one)
jsc_push_loop:
    push rdx
    push rcx
    movzx edx, al
    mov ecx, JLC_SIZE
    call jsp_alloc
    pop rcx
    mov [rax + JLC_KIND], dl
    mov [rax + JLC_POPS], cl
    mov rdx, [jsc_pending_label]
    mov [rax + JLC_LABEL], rdx
    mov qword [jsc_pending_label], 0
    mov edx, [jsc_env_depth]
    mov [rax + JLC_BREAK_ENV], edx
    mov [rax + JLC_CONT_ENV], edx
    mov rdx, [jsc_loop]
    mov [rax + JLC_PARENT], rdx
    mov [jsc_loop], rax
    pop rdx
    ret

; jsc_pop_loop: RAX = context; its breaks jump to the current position
jsc_pop_loop:
    push rax
    push rdx
    mov rdx, [rax + JLC_PARENT]
    mov [jsc_loop], rdx
    mov rdx, [jsc_code_ptr]
    mov rax, [rax + JLC_BREAKS]
    call jsc_resolve_patches
    pop rdx
    pop rax
    ret

; jsc_continue_here: RAX = context; its continues jump to the current position
jsc_continue_here:
    push rax
    push rdx
    mov rdx, [jsc_code_ptr]
    mov rax, [rax + JLC_CONTS]
    call jsc_resolve_patches
    pop rdx
    pop rax
    ret

; jsc_while: RBX = NT_WHILE
jsc_while:
    push rax
    push rdx
    push rsi
    push rdi
    mov al, LC_LOOP
    xor ecx, ecx
    call jsc_push_loop
    mov rdi, rax                    ; context
    mov rsi, [jsc_code_ptr]         ; top
    mov rax, [rbx + JN_A]
    call jsc_expr
    mov al, OP_JF
    call jsc_jump
    push rbx
    lea rbx, [rdi + JLC_BREAKS]
    call jsc_add_patch
    pop rbx
    mov rax, [rbx + JN_B]
    call jsc_stmt
    mov rdx, rsi
    mov al, OP_JMP
    call jsc_jump_to
    mov rax, [rdi + JLC_CONTS]
    call jsc_resolve_patches        ; continue -> top
    mov rax, rdi
    call jsc_pop_loop
    pop rdi
    pop rsi
    pop rdx
    pop rax
    ret

; jsc_dowhile: RBX = NT_DOWHILE
jsc_dowhile:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov al, LC_LOOP
    xor ecx, ecx
    call jsc_push_loop
    mov rdi, rax
    mov rsi, [jsc_code_ptr]
    mov rax, [rbx + JN_A]
    call jsc_stmt
    mov rax, rdi
    call jsc_continue_here
    mov rax, [rbx + JN_B]
    call jsc_expr
    mov rdx, rsi
    mov al, OP_JT
    call jsc_jump_to
    mov rax, rdi
    call jsc_pop_loop
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsc_for: RBX = NT_FOR
jsc_for:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rax, [rbx + JN_E]
    call jsc_enter_scope
    mov r8, rax                     ; scope to return to
    ; init
    mov rax, [rbx + JN_A]
    test rax, rax
    jz .loop
    cmp byte [rax + JN_TYPE], NT_VAR
    jne .init_expr
    push rbx
    mov rbx, rax
    call jsc_declarations
    pop rbx
    jmp .loop
.init_expr:
    mov rax, [rax + JN_A]
    call jsc_expr
    mov al, OP_POP
    call jsc_op
.loop:
    mov al, LC_LOOP
    xor ecx, ecx
    call jsc_push_loop
    mov rdi, rax
    mov rsi, [jsc_code_ptr]         ; top
    mov rax, [rbx + JN_B]
    test rax, rax
    jz .body
    call jsc_expr
    mov al, OP_JF
    call jsc_jump
    push rbx
    lea rbx, [rdi + JLC_BREAKS]
    call jsc_add_patch
    pop rbx
.body:
    mov rax, [rbx + JN_D]
    call jsc_stmt
    mov rax, rdi
    call jsc_continue_here
    ; each iteration gets fresh let bindings (closures keep the old ones)
    mov rax, [jsc_scope]
    cmp rax, r8
    je .update
    cmp byte [rax + JSC_ENV], 0
    je .update
    mov al, OP_COPYENV
    call jsc_op
.update:
    mov rax, [rbx + JN_C]
    test rax, rax
    jz .again
    call jsc_expr
    mov al, OP_POP
    call jsc_op
.again:
    mov rdx, rsi
    mov al, OP_JMP
    call jsc_jump_to
    mov rax, rdi
    call jsc_pop_loop
    mov rax, r8
    call jsc_leave_scope
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsc_forin: RBX = NT_FORIN (OP 0 = in, 1 = of)
jsc_forin:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rax, [rbx + JN_B]
    call jsc_expr
    mov al, OP_FORIN
    cmp byte [rbx + JN_OP], 0
    je .kind
    mov al, OP_FOROF
.kind:
    call jsc_op
    mov al, LC_LOOP
    mov cl, 1                       ; the iterator
    call jsc_push_loop
    mov rdi, rax
    mov rsi, [jsc_code_ptr]         ; top
    mov al, OP_ITERNEXT
    call jsc_jump
    push rbx
    lea rbx, [rdi + JLC_BREAKS]
    call jsc_add_patch
    pop rbx
    ; per-iteration scope for let/const
    mov rax, [rbx + JN_E]
    call jsc_enter_scope
    mov r8, rax
    mov eax, [jsc_env_depth]
    mov [rdi + JLC_CONT_ENV], eax
    ; assign the value
    mov rax, [rbx + JN_A]
    cmp byte [rax + JN_TYPE], NT_VAR
    jne .target
    mov rax, [rax + JN_A]           ; the NT_DECL
    push rdi
    mov edi, 1
    test word [rax + JN_FLAGS], JNF_PATTERN
    jz .decl_name
    mov rax, [rax + JN_A]
    call jsc_destructure
    pop rdi
    jmp .body
.decl_name:
    mov rdx, [rax + JN_A]
    call jsc_store
    pop rdi
    mov al, OP_POP
    call jsc_op
    jmp .body
.target:
    push rdi
    xor edi, edi
    call jsc_destructure
    pop rdi
.body:
    mov rax, [rbx + JN_D]
    call jsc_stmt
    mov rax, rdi
    call jsc_continue_here
    mov rax, r8
    call jsc_leave_scope
    mov rdx, rsi
    mov al, OP_JMP
    call jsc_jump_to
    mov rax, rdi
    call jsc_pop_loop
    mov al, OP_POP                  ; the iterator
    call jsc_op
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsc_store_top: RAX = target (name, a.b, a[b]); stores the value on top of the
; stack into it and pops it
jsc_store_top:
    push rax
    push rbx
    push rdx
    push rdi
    mov rbx, rax
    cmp byte [rbx + JN_TYPE], NT_IDENT
    jne .member
    mov rdx, [rbx + JN_A]
    xor edi, edi
    call jsc_store
    jmp .pop
.member:
    mov rax, [rbx + JN_A]
    call jsc_expr                   ; v o
    cmp byte [rbx + JN_TYPE], NT_MEMBER
    jne .index
    mov al, OP_SWAP                 ; o v
    call jsc_op
    mov rdx, [rbx + JN_B]
    mov al, OP_SETPROP
    call jsc_op_u32
    jmp .pop
.index:
    mov rax, [rbx + JN_B]
    call jsc_expr                   ; v o k
    mov al, OP_ROT3                 ; k v o
    call jsc_op
    call jsc_op                     ; o k v
    mov al, OP_SETELEM
    call jsc_op
.pop:
    mov al, OP_POP
    call jsc_op
    pop rdi
    pop rdx
    pop rbx
    pop rax
    ret

; jsc_switch: RBX = NT_SWITCH
jsc_switch:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov rax, [rbx + JN_A]
    call jsc_expr                   ; the discriminant stays on the stack
    mov rax, [rbx + JN_E]
    call jsc_enter_scope
    mov r8, rax
    mov al, LC_SWITCH
    mov cl, 1
    call jsc_push_loop
    mov rdi, rax
    ; hoist declarations of every case
    mov rsi, [rbx + JN_B]
.hoist:
    test rsi, rsi
    jz .tests
    mov rax, [rsi + JN_B]
    call jsc_hoist
    mov rsi, [rsi + JN_NEXT]
    jmp .hoist
.tests:
    xor r9d, r9d                    ; default case
    mov rsi, [rbx + JN_B]
.test:
    test rsi, rsi
    jz .tests_done
    cmp qword [rsi + JN_A], 0
    jne .has_test
    mov r9, rsi
    jmp .next_test
.has_test:
    mov al, OP_DUP
    call jsc_op
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov al, OP_SEQ
    call jsc_op
    mov al, OP_JT
    call jsc_jump
    mov [rsi + JN_C], rax           ; patched to the case body
.next_test:
    mov rsi, [rsi + JN_NEXT]
    jmp .test
.tests_done:
    mov al, OP_JMP
    call jsc_jump
    test r9, r9
    jz .no_default
    mov [r9 + JN_C], rax
    jmp .bodies
.no_default:
    push rbx
    lea rbx, [rdi + JLC_BREAKS]
    call jsc_add_patch
    pop rbx
.bodies:
    mov rsi, [rbx + JN_B]
.body:
    test rsi, rsi
    jz .end
    mov rax, [rsi + JN_C]
    call jsc_patch_here
    mov rax, [rsi + JN_B]
    call jsc_statements
    mov rsi, [rsi + JN_NEXT]
    jmp .body
.end:
    mov rax, rdi
    call jsc_pop_loop
    mov rax, r8
    call jsc_leave_scope
    mov al, OP_POP                  ; the discriminant
    call jsc_op
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsc_labeled: RBX = NT_LABELED
jsc_labeled:
    push rax
    push rcx
    push rdx
    mov rax, [rbx + JN_A]
    mov [jsc_pending_label], rax
    mov rax, [rbx + JN_B]
    movzx edx, byte [rax + JN_TYPE]
    cmp edx, NT_WHILE
    je .loop
    cmp edx, NT_DOWHILE
    je .loop
    cmp edx, NT_FOR
    je .loop
    cmp edx, NT_FORIN
    je .loop
    cmp edx, NT_SWITCH
    je .loop
    cmp edx, NT_LABELED
    je .loop
    ; a labelled block: only `break label` leaves it
    mov al, LC_BLOCK
    xor ecx, ecx
    call jsc_push_loop
    mov rdx, rax
    mov rax, [rbx + JN_B]
    call jsc_stmt
    mov rax, rdx
    call jsc_pop_loop
    jmp .out
.loop:
    call jsc_stmt
.out:
    mov qword [jsc_pending_label], 0
    pop rdx
    pop rcx
    pop rax
    ret

; jsc_break_continue: RBX = NT_BREAK / NT_CONTINUE
jsc_break_continue:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov rdx, [rbx + JN_A]           ; label
    mov rsi, [jsc_loop]
    xor ecx, ecx                    ; values to pop
.find:
    test rsi, rsi
    jz .illegal
    test rdx, rdx
    jz .unlabeled
    cmp [rsi + JLC_LABEL], rdx
    jne .outer
    cmp byte [rbx + JN_TYPE], NT_BREAK
    je .found
    cmp byte [rsi + JLC_KIND], LC_LOOP
    je .found
    jmp .illegal
.unlabeled:
    cmp byte [rsi + JLC_KIND], LC_LOOP
    je .found
    cmp byte [rbx + JN_TYPE], NT_BREAK
    jne .outer
    cmp byte [rsi + JLC_KIND], LC_SWITCH
    je .found
.outer:
    movzx eax, byte [rsi + JLC_POPS]
    add ecx, eax
    mov rsi, [rsi + JLC_PARENT]
    jmp .find
.found:
    push qword [jsc_env_depth]      ; the jump changes it only on its way out
    ; try blocks on the way out: ENDTRY, and their finally code
    mov rdi, [jsc_loop]
    xor ecx, ecx                    ; values to pop so far
.walk:
    cmp rdi, rsi
    je .walked
    cmp byte [rdi + JLC_KIND], LC_TRY
    jne .walk_pops
    call jsc_pops                   ; ECX values, then 0
    push rax
    mov rax, rdi
    call jsc_leave_try
    pop rax
.walk_pops:
    movzx eax, byte [rdi + JLC_POPS]
    add ecx, eax
    mov rdi, [rdi + JLC_PARENT]
    jmp .walk
.walked:
    call jsc_pops
.envs:
    mov ecx, [jsc_env_depth]
    cmp byte [rbx + JN_TYPE], NT_BREAK
    jne .cont_env
    sub ecx, [rsi + JLC_BREAK_ENV]
    lea rdi, [rsi + JLC_BREAKS]
    jmp .leave
.cont_env:
    sub ecx, [rsi + JLC_CONT_ENV]
    lea rdi, [rsi + JLC_CONTS]
.leave:
    mov al, OP_LEAVEENV
.leave_loop:
    test ecx, ecx
    jle .jump
    call jsc_op
    dec ecx
    jmp .leave_loop
.jump:
    mov al, OP_JMP
    call jsc_jump
    push rbx
    mov rbx, rdi
    call jsc_add_patch
    pop rbx
    pop qword [jsc_env_depth]
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
.illegal:
    mov eax, [rbx + JN_LINE]
    mov [vm_line], eax
    test rdx, rdx
    jnz .no_label
    lea rsi, [jsmsg_illegal_break]
    cmp byte [rbx + JN_TYPE], NT_BREAK
    je .throw
    lea rsi, [jsmsg_illegal_continue]
.throw:
    mov edx, JE_SYNTAX
    xor edi, edi
    jmp js_throw
.no_label:
    mov rdi, rdx
    lea rsi, [jsmsg_undefined_label]
    mov edx, JE_SYNTAX
    jmp js_throw

; ==============================================================================
; Expressions: each leaves exactly one value on the stack
; ==============================================================================

; jsc_binop: EDX = operator id -> AL = opcode (0 if none)
jsc_binop:
    push rsi
    lea rsi, [jsc_binops]
.loop:
    mov al, [rsi]
    test al, al
    jz .none
    cmp al, dl
    je .found
    add rsi, 2
    jmp .loop
.found:
    mov al, [rsi + 1]
    pop rsi
    ret
.none:
    xor eax, eax
    pop rsi
    ret

; jsc_expr: RAX = expression node
jsc_expr:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rbx, rax
    movzx ecx, byte [rbx + JN_TYPE]
    cmp ecx, NT_NUM
    je .num
    cmp ecx, NT_STR
    je .str
    cmp ecx, NT_IDENT
    je .ident
    cmp ecx, NT_THIS
    je .this
    cmp ecx, NT_NULL
    je .null
    cmp ecx, NT_TRUE
    je .true
    cmp ecx, NT_FALSE
    je .false
    cmp ecx, NT_ARRAY
    je .array
    cmp ecx, NT_OBJECT
    je .object
    cmp ecx, NT_FUNC
    je .func
    cmp ecx, NT_UNARY
    je .unary
    cmp ecx, NT_UPDATE
    je .update
    cmp ecx, NT_BINARY
    je .binary
    cmp ecx, NT_LOGICAL
    je .logical
    cmp ecx, NT_COND
    je .cond
    cmp ecx, NT_ASSIGN
    je .assign
    cmp ecx, NT_SEQ
    je .seq
    cmp ecx, NT_MEMBER
    je .member
    cmp ecx, NT_INDEX
    je .index
    cmp ecx, NT_CALL
    je .call
    cmp ecx, NT_NEW
    je .new
    cmp ecx, NT_TEMPLATE
    je .template
    cmp ecx, NT_CLASS
    je .class
    cmp ecx, NT_SUPERCALL
    je .supercall
    cmp ecx, NT_SUPERMEMBER
    je .supermember
    cmp ecx, NT_CHAIN
    je .chain
    cmp ecx, NT_AWAIT
    je .await
    ; NT_HOLE outside an array: undefined
    mov al, OP_UNDEF
    call jsc_op
    jmp .out
.num:
    mov al, OP_NUM
    call jsc_op
    mov rax, [rbx + JN_A]
    call jsc_u64
    jmp .out
.str:
    mov rdx, [rbx + JN_A]
    mov al, OP_STR
    call jsc_op_u32
    jmp .out
.ident:
    mov rdx, [rbx + JN_A]
    call jsc_load
    jmp .out
.this:
    mov al, OP_THIS
    jmp .op
.null:
    mov al, OP_NULL
    jmp .op
.true:
    mov al, OP_TRUE
    jmp .op
.false:
    mov al, OP_FALSE
.op:
    call jsc_op
    jmp .out
.array:
    mov al, OP_ARRAY
    call jsc_op
    mov rsi, [rbx + JN_A]
.element:
    test rsi, rsi
    jz .out
    cmp byte [rsi + JN_TYPE], NT_HOLE
    jne .element_value
    mov al, OP_HOLE
    call jsc_op
    jmp .append
.element_value:
    mov rax, rsi
    cmp byte [rsi + JN_TYPE], NT_SPREAD
    jne .element_plain
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov al, OP_SPREAD
    call jsc_op
    jmp .next_element
.element_plain:
    call jsc_expr
.append:
    mov al, OP_APPEND
    call jsc_op
.next_element:
    mov rsi, [rsi + JN_NEXT]
    jmp .element
.object:
    mov al, OP_OBJECT
    call jsc_op
    mov rsi, [rbx + JN_A]
.property:
    test rsi, rsi
    jz .out
    cmp byte [rsi + JN_OP], 2
    jne .not_spread
    mov rax, [rsi + JN_A]           ; ...spread
    call jsc_expr
    mov al, OP_OBJSPREAD
    call jsc_op
    jmp .next_property
.not_spread:
    cmp byte [rsi + JN_OP], 3
    jb .data_property
    ; get / set
    mov rax, [rsi + JN_B]
    call jsc_expr
    mov rdx, [rsi + JN_A]
    mov al, OP_INITGET
    cmp byte [rsi + JN_OP], 3
    je .accessor_op
    mov al, OP_INITSET
.accessor_op:
    call jsc_op_u32
    jmp .next_property
.data_property:
    cmp byte [rsi + JN_OP], 0
    jne .computed
    mov rdx, [rsi + JN_A]
    mov rax, [rsi + JN_B]
    call jsc_named_expr
    mov al, OP_INITPROP
    call jsc_op_u32
    jmp .next_property
.computed:
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov rax, [rsi + JN_B]
    call jsc_expr
    mov al, OP_INITELEM
    call jsc_op
.next_property:
    mov rsi, [rsi + JN_NEXT]
    jmp .property
.func:
    mov rax, [rbx + JN_A]
    call jsc_function
    mov edx, eax
    mov al, OP_CLOSURE
    call jsc_op_u32
    jmp .out
.unary:
    call jsc_unary
    jmp .out
.await:
    mov rax, [rbx + JN_A]
    call jsc_expr
    mov al, OP_AWAIT
    call jsc_op
    jmp .out
.update:
    call jsc_update
    jmp .out
.binary:
    mov rax, [rbx + JN_A]
    call jsc_expr
    mov rax, [rbx + JN_B]
    call jsc_expr
    movzx edx, byte [rbx + JN_OP]
    call jsc_binop
    call jsc_op
    jmp .out
.logical:
    mov rax, [rbx + JN_A]
    call jsc_expr
    movzx edx, byte [rbx + JN_OP]
    call jsc_logical_op
    call jsc_jump
    mov rsi, rax
    mov rax, [rbx + JN_B]
    call jsc_expr
    mov rax, rsi
    call jsc_patch_here
    jmp .out
.cond:
    mov rax, [rbx + JN_A]
    call jsc_expr
    mov al, OP_JF
    call jsc_jump
    mov rsi, rax
    mov rax, [rbx + JN_B]
    call jsc_expr
    mov al, OP_JMP
    call jsc_jump
    mov rdi, rax
    mov rax, rsi
    call jsc_patch_here
    mov rax, [rbx + JN_C]
    call jsc_expr
    mov rax, rdi
    call jsc_patch_here
    jmp .out
.assign:
    call jsc_assign
    jmp .out
.seq:
    mov rax, [rbx + JN_A]
    call jsc_expr
    mov al, OP_POP
    call jsc_op
    mov rax, [rbx + JN_B]
    call jsc_expr
    jmp .out
.member:
    mov rax, [rbx + JN_A]
    call jsc_expr
    call jsc_optional
    mov rdx, [rbx + JN_B]
    mov al, OP_GETPROP
    call jsc_op_u32_cache
    jmp .out
.index:
    mov rax, [rbx + JN_A]
    call jsc_expr
    call jsc_optional
    mov rax, [rbx + JN_B]
    call jsc_expr
    mov al, OP_GETELEM
    call jsc_op
    jmp .out
.call:
    call jsc_call
    jmp .out
.new:
    call jsc_new
    jmp .out
.template:
    ; "piece" + String(expression) + "piece" ...
    mov rsi, [rbx + JN_A]
    mov rdx, [rsi + JN_A]
    mov al, OP_STR
    call jsc_op_u32
.template_piece:
    mov rsi, [rsi + JN_NEXT]
    test rsi, rsi
    jz .out
    cmp byte [rsi + JN_TYPE], NT_STR
    jne .template_expr
    mov rdx, [rsi + JN_A]
    cmp dword [rdx + JSTR_LEN], 0
    je .template_piece
    mov al, OP_STR
    call jsc_op_u32
    mov al, OP_ADD
    call jsc_op
    jmp .template_piece
.template_expr:
    mov rax, rsi
    call jsc_expr
    mov al, OP_TOSTR
    call jsc_op
    mov al, OP_ADD
    call jsc_op
    jmp .template_piece
.class:
    call jsc_class
    jmp .out
.supercall:
    call jsc_supercall
    jmp .out
.supermember:
    mov rdx, [rbx + JN_B]
    mov al, OP_SUPERGET
    call jsc_op_u32
    jmp .out
.chain:
    ; a?.b...: every ?. jumps here with undefined
    push qword [jsc_chain]
    mov qword [jsc_chain], 0
    mov rax, [rbx + JN_A]
    call jsc_expr
    mov rax, [jsc_chain]
    mov rdx, [jsc_code_ptr]
    call jsc_resolve_patches
    pop qword [jsc_chain]
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsc_logical_op: EDX = P_AND/P_OR/P_NULLISH (or the matching assignment)
; -> AL = the jump that skips the right-hand side
jsc_logical_op:
    mov al, OP_JFK
    cmp edx, P_AND
    je .ret
    cmp edx, P_LAND_ASSIGN
    je .ret
    mov al, OP_JTK
    cmp edx, P_OR
    je .ret
    cmp edx, P_LOR_ASSIGN
    je .ret
    mov al, OP_JNNK
.ret:
    ret

; jsc_unary: RBX = NT_UNARY
jsc_unary:
    push rax
    push rcx
    push rdx
    push rsi
    movzx ecx, byte [rbx + JN_OP]
    mov rsi, [rbx + JN_A]
    cmp ecx, KW_TYPEOF
    je .typeof
    cmp ecx, KW_DELETE
    je .delete
    cmp ecx, KW_VOID
    je .void
    cmp ecx, P_MINUS
    jne .operand
    cmp byte [rsi + JN_TYPE], NT_NUM
    jne .operand
    ; -literal: a constant
    mov al, OP_NUM
    call jsc_op
    mov rax, [rsi + JN_A]
    btc rax, 63
    call jsc_u64
    jmp .out
.operand:
    mov rax, rsi
    call jsc_expr
    mov al, OP_NOT
    cmp ecx, P_NOT
    je .emit
    mov al, OP_BNOT
    cmp ecx, P_TILDE
    je .emit
    mov al, OP_PLUS
    cmp ecx, P_PLUS
    je .emit
    mov al, OP_NEG
.emit:
    call jsc_op
    jmp .out
.typeof:
    cmp byte [rsi + JN_TYPE], NT_IDENT
    jne .typeof_value
    push rbx
    push rcx
    push rsi
    mov rdx, [rsi + JN_A]
    call jsc_resolve
    pop rsi
    pop rcx
    pop rbx
    cmp eax, RES_GLOBAL
    jne .typeof_value
    mov al, OP_TYPEOFGLOB
    call jsc_op_u32
    jmp .out
.typeof_value:
    mov rax, rsi
    call jsc_expr
    mov al, OP_TYPEOF
    jmp .emit
.void:
    mov rax, rsi
    call jsc_expr
    mov al, OP_POP
    call jsc_op
    mov al, OP_UNDEF
    jmp .emit
.delete:
    movzx eax, byte [rsi + JN_TYPE]
    cmp eax, NT_MEMBER
    je .delete_member
    cmp eax, NT_INDEX
    je .delete_index
    cmp eax, NT_IDENT
    je .delete_name
    mov rax, rsi
    call jsc_expr
    mov al, OP_POP
    call jsc_op
.delete_name:
    mov al, OP_TRUE
    jmp .emit
.delete_member:
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov rdx, [rsi + JN_B]
    mov al, OP_DELPROP
    call jsc_op_u32
    jmp .out
.delete_index:
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov rax, [rsi + JN_B]
    call jsc_expr
    mov al, OP_DELELEM
    jmp .emit
.out:
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsc_update: RBX = NT_UPDATE (++/--, prefix or postfix)
jsc_update:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    movzx ecx, byte [rbx + JN_OP]
    mov rsi, [rbx + JN_A]
    mov dil, OP_INC
    test ecx, 1
    jz .kind
    mov dil, OP_DEC
.kind:
    movzx eax, byte [rsi + JN_TYPE]
    cmp eax, NT_MEMBER
    je .member
    cmp eax, NT_INDEX
    je .index
    ; a name
    mov rdx, [rsi + JN_A]
    call jsc_load
    cmp ecx, UPD_POSTINC
    jae .name_post
    mov al, dil
    call jsc_op
    push rdi
    xor edi, edi
    call jsc_store
    pop rdi
    jmp .out
.name_post:
    mov al, OP_TONUM
    call jsc_op
    mov al, OP_DUP
    call jsc_op
    mov al, dil
    call jsc_op
    push rdi
    xor edi, edi
    call jsc_store
    pop rdi
    mov al, OP_POP
    call jsc_op
    jmp .out
.member:
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov al, OP_DUP
    call jsc_op
    mov rdx, [rsi + JN_B]
    mov al, OP_GETPROP
    call jsc_op_u32_cache
    cmp ecx, UPD_POSTINC
    jae .member_post
    mov al, dil
    call jsc_op
    mov al, OP_SETPROP
    call jsc_op_u32
    jmp .out
.member_post:
    mov al, OP_TONUM
    call jsc_op
    mov al, OP_DUP
    call jsc_op
    mov al, OP_ROT3
    call jsc_op
    mov al, dil
    call jsc_op
    mov al, OP_SETPROP
    call jsc_op_u32
    mov al, OP_POP
    call jsc_op
    jmp .out
.index:
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov rax, [rsi + JN_B]
    call jsc_expr
    mov al, OP_DUP2
    call jsc_op
    mov al, OP_GETELEM
    call jsc_op
    cmp ecx, UPD_POSTINC
    jae .index_post
    mov al, dil
    call jsc_op
    mov al, OP_SETELEM
    call jsc_op
    jmp .out
.index_post:
    mov al, OP_TONUM
    call jsc_op
    mov al, OP_DUP
    call jsc_op
    mov al, OP_ROT4
    call jsc_op
    mov al, dil
    call jsc_op
    mov al, OP_SETELEM
    call jsc_op
    mov al, OP_POP
    call jsc_op
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsc_assign: RBX = NT_ASSIGN
jsc_assign:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    movzx ecx, byte [rbx + JN_OP]
    mov rsi, [rbx + JN_A]           ; target
    cmp ecx, P_LAND_ASSIGN
    jae .logical
    cmp ecx, P_ASSIGN
    jne .compound
    ; plain assignment
    movzx eax, byte [rsi + JN_TYPE]
    cmp eax, NT_APAT
    je .set_pattern
    cmp eax, NT_OPAT
    je .set_pattern
    cmp eax, NT_MEMBER
    je .set_member
    cmp eax, NT_INDEX
    je .set_index
    mov rdx, [rsi + JN_A]
    mov rax, [rbx + JN_B]
    call jsc_named_expr
    xor edi, edi
    call jsc_store
    jmp .out
.set_member:
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov rax, [rbx + JN_B]
    call jsc_expr
    mov rdx, [rsi + JN_B]
    mov al, OP_SETPROP
    call jsc_op_u32
    jmp .out
.set_pattern:
    ; [a, b] = value: the value is also the result
    mov rax, [rbx + JN_B]
    call jsc_expr
    mov al, OP_DUP
    call jsc_op
    mov rax, rsi
    xor edi, edi
    call jsc_destructure
    jmp .out
.set_index:
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov rax, [rsi + JN_B]
    call jsc_expr
    mov rax, [rbx + JN_B]
    call jsc_expr
    mov al, OP_SETELEM
    call jsc_op
    jmp .out
.compound:
    mov edx, ecx
    call jsc_binop
    mov r8b, al                     ; the operator
    movzx eax, byte [rsi + JN_TYPE]
    cmp eax, NT_MEMBER
    je .compound_member
    cmp eax, NT_INDEX
    je .compound_index
    mov rdx, [rsi + JN_A]
    call jsc_load
    mov rax, [rbx + JN_B]
    call jsc_expr
    mov al, r8b
    call jsc_op
    xor edi, edi
    call jsc_store
    jmp .out
.compound_member:
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov al, OP_DUP
    call jsc_op
    mov rdx, [rsi + JN_B]
    mov al, OP_GETPROP
    call jsc_op_u32_cache
    mov rax, [rbx + JN_B]
    call jsc_expr
    mov al, r8b
    call jsc_op
    mov rdx, [rsi + JN_B]
    mov al, OP_SETPROP
    call jsc_op_u32
    jmp .out
.compound_index:
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov rax, [rsi + JN_B]
    call jsc_expr
    mov al, OP_DUP2
    call jsc_op
    mov al, OP_GETELEM
    call jsc_op
    mov rax, [rbx + JN_B]
    call jsc_expr
    mov al, r8b
    call jsc_op
    mov al, OP_SETELEM
    call jsc_op
    jmp .out
.logical:
    mov edx, ecx
    call jsc_logical_op
    mov r8b, al
    movzx eax, byte [rsi + JN_TYPE]
    cmp eax, NT_MEMBER
    je .logical_member
    cmp eax, NT_INDEX
    je .logical_index
    ; x ||= v: x, J?K end, v, store x, end
    mov rdx, [rsi + JN_A]
    call jsc_load
    mov al, r8b
    call jsc_jump
    mov rdi, rax
    push rdx
    mov rax, [rbx + JN_B]
    call jsc_named_expr
    pop rdx
    push rdi
    xor edi, edi
    call jsc_store
    pop rdi
    mov rax, rdi
    call jsc_patch_here
    jmp .out
.logical_member:
    mov rax, [rsi + JN_A]
    call jsc_expr                   ; o
    mov al, OP_DUP
    call jsc_op
    mov rdx, [rsi + JN_B]
    mov al, OP_GETPROP
    call jsc_op_u32_cache           ; o v
    mov al, r8b
    call jsc_jump
    mov rdi, rax                    ; -> keep
    mov rax, [rbx + JN_B]
    call jsc_expr                   ; o nv
    mov rdx, [rsi + JN_B]
    mov al, OP_SETPROP
    call jsc_op_u32                 ; nv
    mov al, OP_JMP
    call jsc_jump
    mov rdx, rax
    mov rax, rdi
    call jsc_patch_here             ; keep: o v
    mov al, OP_SWAP
    call jsc_op
    mov al, OP_POP
    call jsc_op
    mov rax, rdx
    call jsc_patch_here
    jmp .out
.logical_index:
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov rax, [rsi + JN_B]
    call jsc_expr                   ; o k
    mov al, OP_DUP2
    call jsc_op
    mov al, OP_GETELEM
    call jsc_op                     ; o k v
    mov al, r8b
    call jsc_jump
    mov rdi, rax
    mov rax, [rbx + JN_B]
    call jsc_expr                   ; o k nv
    mov al, OP_SETELEM
    call jsc_op                     ; nv
    mov al, OP_JMP
    call jsc_jump
    mov rdx, rax
    mov rax, rdi
    call jsc_patch_here             ; keep: o k v
    mov al, OP_ROT3                 ; v o k
    call jsc_op
    mov al, OP_POP
    call jsc_op
    call jsc_op
    mov rax, rdx
    call jsc_patch_here
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsc_class: RBX = NT_CLASS -> code leaving the constructor on the stack:
;   [parent] CLASS flags, code; then per member: DUP [GETPROP prototype]
;   closure METHOD key, kind   (static fields: DUP value INITPROP POP)
; ------------------------------------------------------------------------------
jsc_class:
    push rax
    push rcx
    push rdx
    push rsi
    xor ecx, ecx
    mov rax, [rbx + JN_B]
    test rax, rax
    jz .ctor
    call jsc_expr
    mov ecx, 1
.ctor:
    mov rax, [rbx + JN_D]
    call jsc_function
    mov rdx, rax
    mov al, OP_CLASS
    call jsc_op
    mov al, cl
    call jsc_op
    mov eax, edx
    call jsc_u32
    mov rsi, [rbx + JN_C]
.member:
    test rsi, rsi
    jz .done
    mov al, OP_DUP
    call jsc_op
    test byte [rsi + JN_OP], CM_STATIC
    jnz .target
    mov rdx, [atom_prototype]
    mov al, OP_GETPROP
    call jsc_op_u32_cache
.target:
    test byte [rsi + JN_OP], CM_FIELD
    jz .method
    ; a static field
    mov rax, [rsi + JN_B]
    test rax, rax
    jnz .field_value
    mov al, OP_UNDEF
    call jsc_op
    jmp .field_store
.field_value:
    mov rdx, [rsi + JN_A]
    call jsc_named_expr
.field_store:
    mov rdx, [rsi + JN_A]
    mov al, OP_INITPROP
    call jsc_op_u32
    mov al, OP_POP
    call jsc_op
    jmp .next
.method:
    xor ecx, ecx
    test byte [rsi + JN_OP], CM_GET
    jz .not_get
    mov ecx, 1
.not_get:
    test byte [rsi + JN_OP], CM_SET
    jz .kind
    mov ecx, 2
.kind:
    test byte [rsi + JN_OP], CM_COMPUTED
    jnz .computed
    mov rax, [rsi + JN_B]
    call jsc_expr
    mov rdx, [rsi + JN_A]
    mov al, OP_METHOD
    call jsc_op_u32
    mov al, cl
    call jsc_op
    jmp .next
.computed:
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov rax, [rsi + JN_B]
    call jsc_expr
    mov al, OP_METHODE
    call jsc_op
    mov al, cl
    call jsc_op
.next:
    mov rsi, [rsi + JN_NEXT]
    jmp .member
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsc_supercall: RBX = NT_SUPERCALL -> the parent constructor called on this,
; then the derived class's fields; the value is this
jsc_supercall:
    push rax
    push rdx
    mov al, OP_SUPERFN
    call jsc_op
    mov al, OP_THIS
    call jsc_op
    xor edx, edx
    mov al, OP_SUPERCALL
    call jsc_args
    mov al, OP_POP
    call jsc_op
    mov rax, [jsc_fi]
    test dword [rax + JFI_FLAGS], FIF_DERIVED
    jz .this
    call jsc_fields
.this:
    mov al, OP_THIS
    call jsc_op
    pop rdx
    pop rax
    ret

; jsc_fields: RAX = class constructor's function info -> this.field = value
; for each instance field
jsc_fields:
    push rax
    push rdx
    push rsi
    mov rsi, [rax + JFI_FIELDS]
.field:
    test rsi, rsi
    jz .done
    mov al, OP_THIS
    call jsc_op
    mov rax, [rsi + JN_B]
    test rax, rax
    jnz .value
    mov al, OP_UNDEF
    call jsc_op
    jmp .store
.value:
    mov rdx, [rsi + JN_A]
    call jsc_named_expr
.store:
    mov rdx, [rsi + JN_A]
    mov al, OP_INITPROP
    call jsc_op_u32
    mov al, OP_POP
    call jsc_op
    mov rsi, [rsi + JN_NEXT]
    jmp .field
.done:
    pop rsi
    pop rdx
    pop rax
    ret

; jsc_optional: RBX = member / index / call node -> if it follows ?. (the
; object is on the stack), a jump to the chain's end when it is null/undefined
jsc_optional:
    test word [rbx + JN_FLAGS], JNF_OPTIONAL
    jz .ret
    push rax
    push rbx
    mov al, OP_JNULLISH
    call jsc_jump
    lea rbx, [jsc_chain]
    call jsc_add_patch
    pop rbx
    pop rax
.ret:
    ret

; jsc_call: RBX = NT_CALL
jsc_call:
    push rax
    push rcx
    push rdx
    push rsi
    mov rsi, [rbx + JN_A]           ; callee
    xor edx, edx                    ; name for error messages
    movzx eax, byte [rsi + JN_TYPE]
    cmp eax, NT_MEMBER
    je .method
    cmp eax, NT_INDEX
    je .method_index
    cmp eax, NT_SUPERMEMBER
    je .super_method
    cmp eax, NT_IDENT
    jne .plain
    mov rdx, [rsi + JN_A]
.plain:
    mov rax, rsi
    call jsc_expr
    mov al, OP_UNDEF                ; this
    call jsc_op
    jmp .args
.method:
    mov rax, [rsi + JN_A]
    call jsc_expr
    push rbx
    mov rbx, rsi
    call jsc_optional               ; a?.b()
    pop rbx
    mov rdx, [rsi + JN_B]
    mov al, OP_GETMETHOD
    call jsc_op_u32
    jmp .args
.super_method:
    mov rdx, [rsi + JN_B]
    mov al, OP_SUPERGET
    call jsc_op_u32
    mov al, OP_THIS
    call jsc_op
    jmp .args
.method_index:
    mov rax, [rsi + JN_A]
    call jsc_expr
    push rbx
    mov rbx, rsi
    call jsc_optional
    pop rbx
    mov rax, [rsi + JN_B]
    call jsc_expr
    mov al, OP_GETMETHODE
    call jsc_op
.args:
    test word [rbx + JN_FLAGS], JNF_OPTIONAL
    jz .not_optional
    ; f?.(): nothing to call -> undefined at the chain's end
    push rbx
    mov al, OP_JNULLCALL
    call jsc_jump
    lea rbx, [jsc_chain]
    call jsc_add_patch
    pop rbx
.not_optional:
    mov al, OP_CALL
    call jsc_args
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsc_new: RBX = NT_NEW
jsc_new:
    push rax
    push rdx
    push rsi
    mov rsi, [rbx + JN_A]
    xor edx, edx
    cmp byte [rsi + JN_TYPE], NT_IDENT
    jne .callee
    mov rdx, [rsi + JN_A]
.callee:
    cmp byte [rsi + JN_TYPE], NT_MEMBER
    jne .emit_callee
    mov rdx, [rsi + JN_B]
.emit_callee:
    mov rax, rsi
    call jsc_expr
    mov al, OP_UNDEF                ; the slot for `this`
    call jsc_op
    mov al, OP_NEW
    call jsc_args
    pop rsi
    pop rdx
    pop rax
    ret

; jsc_args: RBX = call / new node, AL = OP_CALL / OP_NEW, EDX = name for
; errors -> the arguments and the call. With ...spread they go in an array
; and OP_CALLA / OP_NEWA spread it.
jsc_args:
    push rax
    push rcx
    push rsi
    mov cl, al
    test word [rbx + JN_FLAGS], JNF_SPREAD
    jnz .spread
    mov rax, [rbx + JN_B]
.arg:
    test rax, rax
    jz .emit
    call jsc_expr
    mov rax, [rax + JN_NEXT]
    jmp .arg
.emit:
    mov al, cl
    call jsc_op
    mov al, [rbx + JN_C]
    call jsc_op
    mov eax, edx
    call jsc_u32
    jmp .out
.spread:
    mov al, OP_ARRAY
    call jsc_op
    mov rsi, [rbx + JN_B]
.item:
    test rsi, rsi
    jz .emit_array
    cmp byte [rsi + JN_TYPE], NT_SPREAD
    je .item_spread
    mov rax, rsi
    call jsc_expr
    mov al, OP_APPEND
    call jsc_op
    jmp .item_next
.item_spread:
    mov rax, [rsi + JN_A]
    call jsc_expr
    mov al, OP_SPREAD
    call jsc_op
.item_next:
    mov rsi, [rsi + JN_NEXT]
    jmp .item
.emit_array:
    mov al, OP_CALLA
    cmp cl, OP_CALL
    je .emit_a
    mov al, OP_NEWA
    cmp cl, OP_NEW
    je .emit_a
    mov al, OP_SUPERCALLA
.emit_a:
    call jsc_op_u32
.out:
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsc_destructure: RAX = target (name, a.b, a[b], [..] or {..} pattern), EDI =
; 1 when it declares -> code that stores the value on top of the stack into
; it, taking the value off the stack
; ------------------------------------------------------------------------------
jsc_destructure:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov rbx, rax
    movzx eax, byte [rbx + JN_TYPE]
    cmp eax, NT_APAT
    je .array
    cmp eax, NT_OPAT
    je .object
    cmp eax, NT_IDENT
    jne .member
    mov rdx, [rbx + JN_A]
    call jsc_store
    mov al, OP_POP
    call jsc_op
    jmp .out
.member:
    mov rax, rbx
    call jsc_store_top
    jmp .out
.array:
    xor ecx, ecx                    ; index
    mov rsi, [rbx + JN_A]
.item:
    test rsi, rsi
    jz .done
    cmp qword [rsi + JN_A], 0
    je .item_next                   ; a hole
    mov al, OP_DUP
    call jsc_op
    test byte [rsi + JN_OP], 1
    jnz .rest
    mov al, OP_NUM
    call jsc_op
    push rcx
    cvtsi2sd xmm0, rcx
    movq rax, xmm0
    call jsc_u64
    pop rcx
    mov al, OP_GETELEM
    call jsc_op
    jmp .value
.rest:
    mov al, OP_ARRREST
    mov edx, ecx
    call jsc_op_u32
    jmp .value
.item_next:
    inc ecx
    mov rsi, [rsi + JN_NEXT]
    jmp .item
.value:
    ; the default, then the target
    call jsc_default
    mov rax, [rsi + JN_A]
    call jsc_destructure
    cmp byte [rbx + JN_TYPE], NT_OPAT
    je .prop_next
    jmp .item_next
.object:
    mov rsi, [rbx + JN_A]
.prop:
    test rsi, rsi
    jz .done
    mov al, OP_DUP
    call jsc_op
    test byte [rsi + JN_OP], 1
    jnz .object_rest
    test byte [rsi + JN_OP], 2
    jnz .computed
    mov rdx, [rsi + JN_C]
    mov al, OP_GETPROP
    call jsc_op_u32_cache
    jmp .value
.computed:
    mov rax, [rsi + JN_C]
    call jsc_expr
    mov al, OP_GETELEM
    call jsc_op
    jmp .value
.object_rest:
    ; the named keys before it are left out
    xor ecx, ecx
    mov rax, [rbx + JN_A]
.excluded:
    cmp rax, rsi
    je .excluded_done
    test byte [rax + JN_OP], 2
    jnz .excluded_next
    mov rdx, [rax + JN_C]
    push rax
    mov al, OP_STR
    call jsc_op_u32
    pop rax
    inc ecx
.excluded_next:
    mov rax, [rax + JN_NEXT]
    jmp .excluded
.excluded_done:
    mov al, OP_OBJREST
    call jsc_op
    mov eax, ecx
    call jsc_u16
    jmp .value
.prop_next:
    mov rsi, [rsi + JN_NEXT]
    jmp .prop
.done:
    mov al, OP_POP
    call jsc_op
.out:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsc_default: RSI = pattern element / parameter with a default in JN_B;
; the value is on the stack -> it is replaced by the default when undefined
jsc_default:
    cmp qword [rsi + JN_B], 0
    je .ret
    push rax
    push rdx
    mov al, OP_DUP
    call jsc_op
    mov al, OP_UNDEF
    call jsc_op
    mov al, OP_SEQ
    call jsc_op
    mov al, OP_JF
    call jsc_jump
    push rax
    mov al, OP_POP
    call jsc_op
    ; a function default gets the target's name
    xor edx, edx
    mov rax, [rsi + JN_A]
    test rax, rax
    jz .named
    cmp byte [rax + JN_TYPE], NT_IDENT
    jne .named
    mov rdx, [rax + JN_A]
.named:
    mov rax, [rsi + JN_B]
    test rdx, rdx
    jz .plain
    call jsc_named_expr
    jmp .patch
.plain:
    call jsc_expr
.patch:
    pop rax
    call jsc_patch_here
    pop rdx
    pop rax
.ret:
    ret

; jsc_param_code: RBX = function info -> defaults and patterns of its
; parameters, at the start of the function
jsc_param_code:
    push rax
    push rdx
    push rsi
    push rdi
    mov edi, 1
    mov rsi, [rbx + JFI_PARAMS]
.param:
    test rsi, rsi
    jz .done
    ; the variable that received the argument
    mov rax, [rsi + JN_A]
    mov rdx, [rsi + JN_E]           ; a pattern's hidden name
    cmp byte [rax + JN_TYPE], NT_IDENT
    jne .load
    test byte [rsi + JN_OP], 1
    jnz .next                       ; ...rest name: filled in by the call
    cmp qword [rsi + JN_B], 0
    je .next                        ; a plain name
    mov rdx, [rax + JN_A]
.load:
    call jsc_load
    call jsc_default
    mov rax, [rsi + JN_A]
    call jsc_destructure            ; a name: stores the default back
.next:
    mov rsi, [rsi + JN_NEXT]
    jmp .param
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rax
    ret
