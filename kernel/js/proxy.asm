; ==============================================================================
; Antigravity OS - JavaScript: Proxy
; ------------------------------------------------------------------------------
; A proxy (JC_PROXY) keeps its target and handler; reading, writing, `in`,
; delete and listing keys come here (from js_get, js_put, js_in, js_delete,
; js_forin_keys) and go to the handler's trap, or on to the target when it
; has none. Traps: get, set, has, deleteProperty, ownKeys. Proxies of
; functions are not callable.
; ==============================================================================

[bits 64]

JPX_TARGET              equ JOBJ_SIZE           ; value
JPX_HANDLER             equ JOBJ_SIZE + 8       ; value
JPX_SIZE                equ JOBJ_SIZE + 16

section .bss
alignb 8
jsprx_ctor:             resq 1
jsprx_proto:            resq 1          ; (Proxy.prototype: unused, as in the standard)
jsprx_atoms:                            ; the trap names (atoms), in jsprx_names order
jsprx_atom_get:         resq 1
jsprx_atom_set:         resq 1
jsprx_atom_has:         resq 1
jsprx_atom_delete:      resq 1
jsprx_atom_own_keys:    resq 1
JSPRX_ATOMS             equ 5

section .rodata
jsprx_ctors:
JSCTOR jsprx_ctor, jsprx_new, 2, jsprx_proto, "Proxy"
    dq 0
jsprx_names:            dq jsprx_str_get, jsprx_str_set, jsprx_str_has, jsprx_str_delete, jsprx_str_own_keys
jsprx_str_get:          db "get", 0
jsprx_str_set:          db "set", 0
jsprx_str_has:          db "has", 0
jsprx_str_delete:       db "deleteProperty", 0
jsprx_str_own_keys:     db "ownKeys", 0
jsmsg_proxy_args:       db "Cannot create proxy with a non-object as target or handler", 0
jsmsg_proxy_new:        db "Constructor Proxy requires 'new'", 0

section .text

; jsprx_init: the constructor, the trap names
jsprx_init:
    push rax
    push rbx
    push rsi
    push r8
    mov rax, [js_object_proto]
    call jsobj_new
    mov [jsprx_proto], rax
    lea r8, [jsprx_ctors]
    call jsb_define_ctors
    xor ebx, ebx
.atom:
    mov rsi, [jsprx_names + rbx*8]
    call jsstr_from_cstr
    call jsstr_intern
    mov [jsprx_atoms + rbx*8], rax
    inc ebx
    cmp ebx, JSPRX_ATOMS
    jb .atom
    pop r8
    pop rsi
    pop rbx
    pop rax
    ret

; new Proxy(target, handler)
jsprx_new:
    push rbx
    push rcx
    push rdx
    cmp r8d, 1
    jne .not_new
    push rcx
    xor eax, eax
    call jsb_arg
    mov rbx, rax                    ; target
    pop rcx
    mov eax, 1
    call jsb_arg
    mov rdx, rax                    ; handler
    mov rcx, rbx
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .bad
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .bad
    mov ecx, JPX_SIZE
    call js_alloc
    mov byte [rax + JH_KIND], JK_OBJECT
    mov dword [rax + JOBJ_CLASS], JC_PROXY
    mov [rax + JPX_TARGET], rbx
    mov [rax + JPX_HANDLER], rdx
    BOX rax, rcx, JS_OBJ_BITS
    pop rdx
    pop rcx
    pop rbx
    ret
.bad:
    lea rsi, [jsmsg_proxy_args]
    xor edi, edi
    jmp js_throw_type
.not_new:
    lea rsi, [jsmsg_proxy_new]
    xor edi, edi
    jmp js_throw_type

; jsprx_trap: RDI = proxy (raw), EAX = trap number -> RAX = the handler's trap,
; CF=1 if it has none
jsprx_trap:
    push rdx
    mov rdx, [jsprx_atoms + rax*8]
    mov rax, [rdi + JPX_HANDLER]
    call js_get
    pop rdx
    push rcx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    pop rcx
    jne .none
    clc
    ret
.none:
    stc
    ret

; jsprx_key_value: RDX = a property key (atom or symbol, raw) -> RAX = it as
; a value
jsprx_key_value:
    mov eax, edx
    cmp byte [rax + JH_KIND], JK_SYMBOL
    je .symbol
    push rdx
    BOX rax, rdx, JS_STR_BITS
    pop rdx
    ret
.symbol:
    push rdx
    mov rdx, JS_SYM_BITS
    or rax, rdx
    pop rdx
    ret

; jsprx_boxed: RAX = proxy (raw) -> RAX = it as a value
jsprx_boxed:
    push rdx
    BOX rax, rdx, JS_OBJ_BITS
    pop rdx
    ret

; jsprx_call_trap: RAX = trap, RDI = proxy (raw), ECX = arguments on the stack
; above the return address ([RSP+8] ...) -> RAX = its result
jsprx_call_trap:
    push rdx
    push rdi
    mov rdx, [rdi + JPX_HANDLER]    ; this = the handler
    lea rdi, [rsp + 24]
    call js_call
    pop rdi
    pop rdx
    ret

; ------------------------------------------------------------------------------
; jsprx_get: RDI = proxy (raw), RDX = key (raw) -> RAX = value, CF=0
; ------------------------------------------------------------------------------
jsprx_get:
    push rcx
    push rdi
    mov eax, 0                      ; get
    call jsprx_trap
    jc .forward
    ; get(target, key, receiver)
    push rax
    mov rax, rdi
    call jsprx_boxed
    xchg rax, [rsp]                 ; receiver; RAX = the trap
    push rax
    call jsprx_key_value
    xchg rax, [rsp]                 ; key; RAX = the trap
    push qword [rdi + JPX_TARGET]
    mov ecx, 3
    call jsprx_call_trap
    add rsp, 24
    jmp .out
.forward:
    ; (as an element: array targets keep theirs apart from named properties)
    push rdx
    call jsprx_key_value
    mov rdx, rax
    mov rax, [rdi + JPX_TARGET]
    call js_get_elem
    pop rdx
.out:
    pop rdi
    pop rcx
    clc
    ret

; ------------------------------------------------------------------------------
; jsprx_set: RAX = proxy (raw), RDX = key (raw), RCX = value -> CF=0
; ------------------------------------------------------------------------------
jsprx_set:
    push rax
    push rcx
    push rdi
    mov rdi, rax
    mov eax, 1                      ; set
    call jsprx_trap
    jc .forward
    ; set(target, key, value, receiver)
    push rax
    mov rax, rdi
    call jsprx_boxed
    xchg rax, [rsp]                 ; receiver; RAX = the trap
    push rcx                        ; value
    push rax
    call jsprx_key_value
    xchg rax, [rsp]                 ; key; RAX = the trap
    push qword [rdi + JPX_TARGET]
    mov ecx, 4
    call jsprx_call_trap
    add rsp, 32
    jmp .out
.forward:
    push rdx
    call jsprx_key_value
    mov rdx, rax
    mov rax, [rdi + JPX_TARGET]
    call js_put_elem
    pop rdx
.out:
    pop rdi
    pop rcx
    pop rax
    clc
    ret

; ------------------------------------------------------------------------------
; jsprx_has: RAX = proxy (raw), RDX = key (raw) -> CF=1 if it has the key
; ------------------------------------------------------------------------------
jsprx_has:
    push rax
    push rcx
    push rdi
    mov rdi, rax
    mov eax, 2                      ; has
    call jsprx_trap
    jc .forward
    push rax
    call jsprx_key_value
    xchg rax, [rsp]
    push qword [rdi + JPX_TARGET]
    mov ecx, 2
    call jsprx_call_trap
    add rsp, 16
    call js_truthy
    jmp .out
.forward:
    call jsprx_key_value            ; js_in: RAX = key, RDX = object
    push rdx
    mov rdx, [rdi + JPX_TARGET]
    call js_in
    pop rdx
.out:
    pop rdi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsprx_delete: RAX = proxy (raw), RDX = key (raw) -> CF=1 if it is gone
; ------------------------------------------------------------------------------
jsprx_delete:
    push rax
    push rcx
    push rdi
    mov rdi, rax
    mov eax, 3                      ; deleteProperty
    call jsprx_trap
    jc .forward
    push rax
    call jsprx_key_value
    xchg rax, [rsp]
    push qword [rdi + JPX_TARGET]
    mov ecx, 2
    call jsprx_call_trap
    add rsp, 16
    call js_truthy
    jmp .out
.forward:
    call jsprx_key_value
    push rdx
    mov rdx, rax
    mov rax, [rdi + JPX_TARGET]
    call js_delete
    pop rdx
.out:
    pop rdi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsprx_keys: RBX = proxy (raw) -> RAX = an array of its string keys (raw),
; CF=0; CF=1 (RBX = the target, raw) when it has no ownKeys trap
; ------------------------------------------------------------------------------
jsprx_keys:
    push rcx
    push rdx
    push rdi
    push r8
    mov rdi, rbx
    mov eax, 4                      ; ownKeys
    call jsprx_trap
    jc .target
    push qword [rdi + JPX_TARGET]
    mov ecx, 1
    call jsprx_call_trap
    add rsp, 8
    ; the strings in it
    mov r8, rax
    xor ecx, ecx
    call jsarr_new
    mov rdi, rax
    mov rcx, r8
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .done
    mov r8d, r8d
    cmp byte [r8 + JH_KIND], JK_ARRAY
    jne .done
    xor edx, edx
.key:
    cmp edx, [r8 + JARR_LEN]
    jae .done
    mov rax, [r8 + JARR_ELEMS]
    mov rcx, [rax + rdx*8]
    mov rax, rcx
    shr rax, 48
    cmp eax, JS_TAG_STRING
    jne .next
    mov rax, rdi
    call jsarr_push
.next:
    inc edx
    jmp .key
.done:
    mov rax, rdi
    pop r8
    pop rdi
    pop rdx
    pop rcx
    clc
    ret
.target:
    mov rax, [rdi + JPX_TARGET]
    mov ebx, eax
    pop r8
    pop rdi
    pop rdx
    pop rcx
    stc
    ret
