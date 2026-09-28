; ==============================================================================
; Antigravity OS - JavaScript objects and arrays
; ------------------------------------------------------------------------------
; An object keeps its properties in insertion order in an array of 16-byte
; entries (key atom + attribute bits, value). Lookups scan it; the bytecode
; caches the index a property was last found at (see OP_GETPROP in vm.asm).
; Arrays add a dense vector of values; missing elements hold JS_HOLE.
; ==============================================================================

[bits 64]

section .bss
alignb 8
js_object_proto:        resq 1          ; Object.prototype (raw pointers)
js_function_proto:      resq 1
js_array_proto:         resq 1
js_string_proto:        resq 1
js_number_proto:        resq 1
js_boolean_proto:       resq 1
js_global:              resq 1          ; the global object

section .text

; ------------------------------------------------------------------------------
; jsobj_new: RAX = prototype (0 = none) -> RAX = new plain object
; jsobj_new_plain: -> RAX = new object inheriting Object.prototype
; ------------------------------------------------------------------------------
jsobj_new:
    push rcx
    push rdx
    mov rdx, rax
    mov ecx, JOBJ_SIZE
    call js_alloc
    mov byte [rax + JH_KIND], JK_OBJECT
    mov [rax + JOBJ_PROTO], rdx
    pop rdx
    pop rcx
    ret

jsobj_new_plain:
    mov rax, [js_object_proto]
    jmp jsobj_new

; ------------------------------------------------------------------------------
; jsobj_find_own: RAX = object, EDX = atom -> RBX = entry, CF=0 if found
; (CF=1 when the object has no such own property)
; ------------------------------------------------------------------------------
jsobj_find_own:
    push rcx
    mov ecx, [rax + JOBJ_COUNT]
    mov rbx, [rax + JOBJ_PROPS]
.loop:
    test ecx, ecx
    jz .missing
    cmp [rbx + JPE_KEY], edx
    je .found
    add rbx, JPE_SIZE
    dec ecx
    jmp .loop
.found:
    pop rcx
    clc
    ret
.missing:
    pop rcx
    stc
    ret

; ------------------------------------------------------------------------------
; jsobj_lookup: RAX = object, EDX = atom -> RBX = entry in the object or its
; prototype chain, CF=0 if found
; ------------------------------------------------------------------------------
jsobj_lookup:
    push rax
.loop:
    call jsobj_find_own
    jnc .found
    mov rax, [rax + JOBJ_PROTO]
    test rax, rax
    jnz .loop
    pop rax
    stc
    ret
.found:
    pop rax
    clc
    ret

; ------------------------------------------------------------------------------
; jsobj_add: RAX = object, RDX = key (atom | attributes << 32), RCX = value
; -> RBX = the new entry. The caller made sure the key is not there yet.
; ------------------------------------------------------------------------------
jsobj_add:
    push rax
    push rcx
    push rsi
    push rdi
    mov esi, [rax + JOBJ_COUNT]
    cmp esi, [rax + JOBJ_CAP]
    jb .room
    call jsobj_grow
    mov esi, [rax + JOBJ_COUNT]
.room:
    mov rbx, [rax + JOBJ_PROPS]
    shl esi, 4
    add rbx, rsi
    mov [rbx + JPE_KEY], rdx
    mov [rbx + JPE_VAL], rcx
    inc dword [rax + JOBJ_COUNT]
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; jsobj_grow: RAX = object; doubles the property array, dropping deleted entries
jsobj_grow:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rbx, rax
    mov ecx, [rbx + JOBJ_CAP]
    add ecx, ecx
    cmp ecx, 4
    jae .size
    mov ecx, 4
.size:
    mov [rbx + JOBJ_CAP], ecx
    shl ecx, 4
    call js_alloc
    mov rdi, rax
    mov rsi, [rbx + JOBJ_PROPS]
    mov [rbx + JOBJ_PROPS], rax
    mov ecx, [rbx + JOBJ_COUNT]
    xor edx, edx                    ; live entries copied
.copy:
    test ecx, ecx
    jz .done
    mov rax, [rsi + JPE_KEY]
    test eax, eax
    jz .skip
    mov [rdi + JPE_KEY], rax
    mov rax, [rsi + JPE_VAL]
    mov [rdi + JPE_VAL], rax
    add rdi, JPE_SIZE
    inc edx
.skip:
    add rsi, JPE_SIZE
    dec ecx
    jmp .copy
.done:
    mov [rbx + JOBJ_COUNT], edx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsobj_define: RAX = object, RDX = key (atom | attributes << 32), RCX = value.
; Creates the own property or overwrites it (attributes included).
; ------------------------------------------------------------------------------
jsobj_define:
    push rbx
    call jsobj_find_own
    jc .add
    mov [rbx + JPE_KEY], rdx
    mov [rbx + JPE_VAL], rcx
    pop rbx
    ret
.add:
    call jsobj_add
    pop rbx
    ret

; jsobj_define_hidden: RAX = object, EDX = atom, RCX = value (not enumerable)
jsobj_define_hidden:
    push rdx
    mov edx, edx
    bts rdx, 32                     ; JPA_HIDDEN << 32
    call jsobj_define
    pop rdx
    ret

; ------------------------------------------------------------------------------
; jsobj_put: RAX = object, EDX = atom, RCX = value. Ordinary assignment:
; overwrites a writable own property or adds one; a read-only property here
; or up the prototype chain keeps its value.
; ------------------------------------------------------------------------------
jsobj_put:
    push rbx
    push rdx
    mov edx, edx
    call jsobj_find_own
    jc .inherited
    bt qword [rbx + JPE_KEY], 33    ; JPA_READONLY
    jc .out
    mov [rbx + JPE_VAL], rcx
    jmp .out
.inherited:
    call jsobj_lookup
    jc .add
    bt qword [rbx + JPE_KEY], 33
    jc .out
.add:
    call jsobj_add
.out:
    pop rdx
    pop rbx
    ret

; jsobj_delete: RAX = object, EDX = atom -> removes the own property
; (CF=1 if it is read-only and stays)
jsobj_delete:
    push rbx
    call jsobj_find_own
    jc .gone
    bt qword [rbx + JPE_KEY], 33
    jc .keep
    mov qword [rbx + JPE_KEY], 0
    mov qword [rbx + JPE_VAL], 0
.gone:
    pop rbx
    clc
    ret
.keep:
    pop rbx
    stc
    ret

; ==============================================================================
; Arrays
; ==============================================================================

; jsarr_new: ECX = capacity -> RAX = empty array
jsarr_new:
    push rcx
    push rdx
    mov edx, ecx
    mov ecx, JARR_SIZE
    call js_alloc
    mov byte [rax + JH_KIND], JK_ARRAY
    mov rcx, [js_array_proto]
    mov [rax + JOBJ_PROTO], rcx
    mov ecx, edx
    call jsarr_reserve
    pop rdx
    pop rcx
    ret

; jsarr_reserve: RAX = array, ECX = capacity needed (grows by doubling)
jsarr_reserve:
    cmp ecx, [rax + JARR_CAP]
    jbe .ret
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    cmp ecx, JARR_MAX
    ja .too_big
    mov rbx, rax
    mov edx, [rbx + JARR_CAP]
    add edx, edx
    cmp edx, ecx
    jae .size
    mov edx, ecx
.size:
    cmp edx, 4
    jae .alloc
    mov edx, 4
.alloc:
    mov ecx, edx
    shl ecx, 3
    call js_alloc
    mov rdi, rax
    mov rsi, [rbx + JARR_ELEMS]
    mov ecx, [rbx + JARR_LEN]
    rep movsq
    mov [rbx + JARR_ELEMS], rax
    mov [rbx + JARR_CAP], edx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.ret:
    ret
.too_big:
    mov edx, JE_RANGE
    lea rsi, [jsmsg_array_length]
    xor edi, edi
    jmp js_throw

; jsarr_push: RAX = array, RCX = value
jsarr_push:
    push rbx
    push rcx
    push rdx
    mov edx, [rax + JARR_LEN]
    push rcx
    lea ecx, [rdx + 1]
    call jsarr_reserve
    pop rcx
    mov rbx, [rax + JARR_ELEMS]
    mov [rbx + rdx*8], rcx
    inc edx
    mov [rax + JARR_LEN], edx
    pop rdx
    pop rcx
    pop rbx
    ret

; jsarr_set_length: RAX = array, ECX = new length (new elements are holes)
jsarr_set_length:
    push rbx
    push rcx
    push rdx
    push rdi
    mov edx, [rax + JARR_LEN]
    cmp ecx, edx
    jbe .store
    call jsarr_reserve
    mov rbx, [rax + JARR_ELEMS]
    mov rdi, JS_HOLE
.fill:
    mov [rbx + rdx*8], rdi
    inc edx
    cmp edx, ecx
    jb .fill
.store:
    mov [rax + JARR_LEN], ecx
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsarr_set: RAX = array, EDX = index, RCX = value (grows the array)
jsarr_set:
    push rbx
    cmp edx, [rax + JARR_LEN]
    jb .store
    push rcx
    lea ecx, [rdx + 1]
    call jsarr_set_length
    pop rcx
.store:
    mov rbx, [rax + JARR_ELEMS]
    mov [rbx + rdx*8], rcx
    pop rbx
    ret

section .rodata
jsmsg_array_length:     db "Invalid array length", 0
