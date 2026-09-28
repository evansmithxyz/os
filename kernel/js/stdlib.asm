; ==============================================================================
; Antigravity OS - JavaScript standard library (step 3)
; ------------------------------------------------------------------------------
; The everyday methods: Array.prototype (forEach, map, filter, reduce, sort,
; splice, ...), Array.from / of, String.prototype (split, replace, includes,
; padStart, ...), Object (assign, entries, create, defineProperty, ...),
; Function.prototype (call, apply, bind), Number, more Math, and JSON.
; Natives follow vm.asm's convention (RDI = arguments, ECX = count, RDX =
; this, R10 = the function itself; result in RAX, other registers kept).
; ==============================================================================

[bits 64]

; jsl_natives uses the JSNATIVE layout of builtins.asm (object variable,
; routine, arity, name)
%macro JSLNATIVE 4
    [section .rodata]
    dq %1, %3
    db %4
    db %%e - %%s
    %%s: db %2
    %%e:
    __SECT__
%endmacro

section .bss
alignb 8
jsl_json:               resq 1          ; the JSON object
jsl_atom_enumerable:    resq 1
jsl_atom_writable:      resq 1
jsl_atom_configurable:  resq 1
jsl_atom_value:         resq 1
jsl_atom_tojson:        resq 1

section .rodata
jsl_natives:
JSLNATIVE js_array_proto, "forEach", jsl_array_for_each, 1
JSLNATIVE js_array_proto, "map", jsl_array_map, 1
JSLNATIVE js_array_proto, "filter", jsl_array_filter, 1
JSLNATIVE js_array_proto, "some", jsl_array_some, 1
JSLNATIVE js_array_proto, "every", jsl_array_every, 1
JSLNATIVE js_array_proto, "find", jsl_array_find, 1
JSLNATIVE js_array_proto, "findIndex", jsl_array_find_index, 1
JSLNATIVE js_array_proto, "findLast", jsl_array_find_last, 1
JSLNATIVE js_array_proto, "findLastIndex", jsl_array_find_last_index, 1
JSLNATIVE js_array_proto, "reduce", jsl_array_reduce, 1
JSLNATIVE js_array_proto, "reduceRight", jsl_array_reduce_right, 1
JSLNATIVE js_array_proto, "includes", jsl_array_includes, 1
JSLNATIVE js_array_proto, "lastIndexOf", jsl_array_last_index_of, 1
JSLNATIVE js_array_proto, "concat", jsl_array_concat, 1
JSLNATIVE js_array_proto, "reverse", jsl_array_reverse, 0
JSLNATIVE js_array_proto, "sort", jsl_array_sort, 1
JSLNATIVE js_array_proto, "splice", jsl_array_splice, 2
JSLNATIVE js_array_proto, "shift", jsl_array_shift, 0
JSLNATIVE js_array_proto, "unshift", jsl_array_unshift, 1
JSLNATIVE js_array_proto, "fill", jsl_array_fill, 1
JSLNATIVE js_array_proto, "flat", jsl_array_flat, 0
JSLNATIVE js_array_proto, "flatMap", jsl_array_flat_map, 1
JSLNATIVE js_array_proto, "at", jsl_array_at, 1
JSLNATIVE jsb_array_ctor, "from", jsl_array_from, 1
JSLNATIVE jsb_array_ctor, "of", jsl_array_of, 0
JSLNATIVE js_function_proto, "call", jsl_function_call, 1
JSLNATIVE js_function_proto, "apply", jsl_function_apply, 2
JSLNATIVE js_function_proto, "bind", jsl_function_bind, 1
JSLNATIVE js_string_proto, "split", jsl_string_split, 2
JSLNATIVE js_string_proto, "replace", jsl_string_replace, 2
JSLNATIVE js_string_proto, "replaceAll", jsl_string_replace_all, 2
JSLNATIVE js_string_proto, "includes", jsl_string_includes, 1
JSLNATIVE js_string_proto, "startsWith", jsl_string_starts_with, 1
JSLNATIVE js_string_proto, "endsWith", jsl_string_ends_with, 1
JSLNATIVE js_string_proto, "padStart", jsl_string_pad_start, 2
JSLNATIVE js_string_proto, "padEnd", jsl_string_pad_end, 2
JSLNATIVE js_string_proto, "repeat", jsl_string_repeat, 1
JSLNATIVE js_string_proto, "trimStart", jsl_string_trim_start, 0
JSLNATIVE js_string_proto, "trimEnd", jsl_string_trim_end, 0
JSLNATIVE js_string_proto, "lastIndexOf", jsl_string_last_index_of, 1
JSLNATIVE js_string_proto, "at", jsl_string_at, 1
JSLNATIVE js_string_proto, "concat", jsl_string_concat, 1
JSLNATIVE js_string_proto, "localeCompare", jsl_string_locale_compare, 1
JSLNATIVE js_string_proto, "codePointAt", jsb_string_char_code_at, 1
JSLNATIVE js_string_proto, "normalize", jsb_string_value_of, 0
JSLNATIVE jsb_object_ctor, "values", jsl_object_values, 1
JSLNATIVE jsb_object_ctor, "entries", jsl_object_entries, 1
JSLNATIVE jsb_object_ctor, "assign", jsl_object_assign, 2
JSLNATIVE jsb_object_ctor, "create", jsl_object_create, 2
JSLNATIVE jsb_object_ctor, "getPrototypeOf", jsl_object_get_proto, 1
JSLNATIVE jsb_object_ctor, "setPrototypeOf", jsl_object_set_proto, 2
JSLNATIVE jsb_object_ctor, "freeze", jsl_object_freeze, 1
JSLNATIVE jsb_object_ctor, "seal", jsl_object_identity, 1
JSLNATIVE jsb_object_ctor, "preventExtensions", jsl_object_identity, 1
JSLNATIVE jsb_object_ctor, "defineProperty", jsl_object_define_property, 3
JSLNATIVE jsb_object_ctor, "defineProperties", jsl_object_define_properties, 2
JSLNATIVE jsb_object_ctor, "getOwnPropertyNames", jsl_object_own_names, 1
JSLNATIVE jsb_object_ctor, "getOwnPropertyDescriptor", jsl_object_own_descriptor, 2
JSLNATIVE jsb_object_ctor, "fromEntries", jsl_object_from_entries, 1
JSLNATIVE jsb_object_ctor, "is", jsl_object_is, 2
JSLNATIVE js_object_proto, "isPrototypeOf", jsl_object_is_prototype_of, 1
JSLNATIVE js_object_proto, "propertyIsEnumerable", jsl_object_property_enumerable, 1
JSLNATIVE js_object_proto, "toLocaleString", jsb_object_to_string, 0
JSLNATIVE jsb_number_ctor, "isInteger", jsl_number_is_integer, 1
JSLNATIVE jsb_number_ctor, "isSafeInteger", jsl_number_is_safe_integer, 1
JSLNATIVE jsb_number_ctor, "isFinite", jsl_number_is_finite, 1
JSLNATIVE jsb_number_ctor, "isNaN", jsl_number_is_nan, 1
JSLNATIVE jsb_number_ctor, "parseFloat", jsb_parse_float, 1
JSLNATIVE jsb_number_ctor, "parseInt", jsb_parse_int, 2
JSLNATIVE jsb_math, "hypot", jsl_math_hypot, 2
JSLNATIVE jsb_math, "cbrt", jsl_math_cbrt, 1
JSLNATIVE jsb_math, "log10", jsl_math_log10, 1
JSLNATIVE jsb_math, "log2", jsl_math_log2, 1
JSLNATIVE jsb_math, "log1p", jsl_math_log1p, 1
JSLNATIVE jsb_math, "expm1", jsl_math_expm1, 1
JSLNATIVE jsb_math, "sinh", jsl_math_sinh, 1
JSLNATIVE jsb_math, "cosh", jsl_math_cosh, 1
JSLNATIVE jsb_math, "tanh", jsl_math_tanh, 1
JSLNATIVE jsb_math, "asin", jsl_math_asin, 1
JSLNATIVE jsb_math, "acos", jsl_math_acos, 1
JSLNATIVE jsb_math, "fround", jsl_math_fround, 1
JSLNATIVE jsb_math, "clz32", jsl_math_clz32, 1
JSLNATIVE jsb_math, "imul", jsl_math_imul, 2
JSLNATIVE jsl_json, "stringify", jsl_json_stringify, 3
JSLNATIVE jsl_json, "parse", jsl_json_parse, 2
    dq 0

jsl_name_json:          db "JSON", 0
jsmsg_callback:         db "% is not a function", 0
jsmsg_reduce_empty:     db "Reduce of empty array with no initial value", 0
jsmsg_repeat:           db "Invalid count value", 0
jsmsg_proto:            db "Object prototype may only be an Object or null", 0
jsmsg_descriptor:       db "Property description must be an object", 0
jsmsg_circular:         db "Converting circular structure to JSON", 0
jsmsg_json:             db "Unexpected token '%' in JSON", 0
jsmsg_json_end:         db "Unexpected end of JSON input", 0
jsl_str_callback:       db "callback", 0
jsl_str_null:           db "null", 0
jsl_str_true:           db "true", 0
jsl_str_false:          db "false", 0
jsl_str_tojson:         db "toJSON", 0
jsl_str_enumerable:     db "enumerable", 0
jsl_str_writable:       db "writable", 0
jsl_str_configurable:   db "configurable", 0
jsl_str_get:            db "get", 0
jsl_str_set:            db "set", 0
jsl_str_value:          db "value", 0
jsl_str_space:          db " ", 0
jsl_ten_spaces:         db "          ", 0
jsmsg_not_object:       db "Object.defineProperty called on non-object", 0
jsmsg_cyclic:           db "Cyclic __proto__ value", 0
align 8
jsl_three:              dq 3.0
jsl_log1p_limit:        dq 0.29
jsl_third:              dq 0.3333333333333333
jsl_float_max:          dq 3.4028234663852886e38

section .text

; ------------------------------------------------------------------------------
; jsl_init: the JSON object and every method above (from js_init_builtins)
; ------------------------------------------------------------------------------
jsl_init:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    call jsobj_new_plain
    mov [jsl_json], rax
    mov rcx, rax
    BOX rcx, rdx, JS_OBJ_BITS
    mov rax, [js_global]
    lea rsi, [jsl_name_json]
    mov edx, 1
    call jsb_define
    lea rsi, [jsl_str_enumerable]
    call jsstr_from_cstr
    mov [jsl_atom_enumerable], rax
    lea rsi, [jsl_str_writable]
    call jsstr_from_cstr
    mov [jsl_atom_writable], rax
    lea rsi, [jsl_str_configurable]
    call jsstr_from_cstr
    mov [jsl_atom_configurable], rax
    lea rsi, [jsl_str_value]
    call jsstr_from_cstr
    mov [jsl_atom_value], rax
    lea rsi, [jsl_str_tojson]
    call jsstr_from_cstr
    mov [jsl_atom_tojson], rax
    lea r8, [jsl_natives]
    call jsb_define_natives
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ==============================================================================
; Helpers
; ==============================================================================

; jsl_this_array: RDX = this -> RBX = array (raw); a non-array `this` gives a
; TypeError through js_throw_type
jsl_this_array:
    call jsb_this_array
    jc .bad
    ret
.bad:
    lea rsi, [jsmsg_illegal]
    xor edi, edi
    jmp js_throw_type

; jsl_callback: EAX = argument index -> RAX = that argument, which must be a
; function (TypeError otherwise)
jsl_callback:
    call jsb_arg
    call js_is_callable
    jc .ok
    call js_to_string
    mov rdi, rax
    lea rsi, [jsmsg_callback]
    jmp js_throw_type
.ok:
    ret

; jsl_elem: RBX = array, EDX = index -> RAX = element (a hole is undefined)
jsl_elem:
    push rcx
    mov rax, JS_UNDEF
    cmp edx, [rbx + JARR_LEN]
    jae .out
    mov rax, [rbx + JARR_ELEMS]
    mov rax, [rax + rdx*8]
    mov rcx, JS_HOLE
    cmp rax, rcx
    jne .out
    mov rax, JS_UNDEF
.out:
    pop rcx
    ret

; jsl_is_hole: RBX = array, EDX = index -> CF=1 if it is a hole (or past the end)
jsl_is_hole:
    push rax
    push rcx
    cmp edx, [rbx + JARR_LEN]
    jae .yes
    mov rax, [rbx + JARR_ELEMS]
    mov rax, [rax + rdx*8]
    mov rcx, JS_HOLE
    cmp rax, rcx
    je .yes
    pop rcx
    pop rax
    clc
    ret
.yes:
    pop rcx
    pop rax
    stc
    ret

; jsl_call3: RAX = function, R9 = this, R11 = the array value, EDX = index,
; RCX = element -> RAX = fn.call(this, element, index, array)
jsl_call3:
    push rcx
    push rdx
    push rdi
    push r11
    mov rdi, rax
    mov eax, edx
    call jsb_from_int
    push rax                        ; index
    mov rax, rdi
    ; the three arguments on the kernel stack, in order
    sub rsp, 8
    mov [rsp], rcx                  ; [rsp] element, [rsp+8] index, [rsp+16] array
    mov rdi, rsp
    mov rdx, r9
    mov ecx, 3
    call js_call
    add rsp, 16
    pop r11
    pop rdi
    pop rdx
    pop rcx
    ret

; jsl_new_array: -> RAX = empty array (raw), R8 too
jsl_new_array:
    push rcx
    xor ecx, ecx
    call jsarr_new
    mov r8, rax
    pop rcx
    ret

; jsl_box_obj: RAX = raw object -> RAX = its value
jsl_box_obj:
    push rdx
    BOX rax, rdx, JS_OBJ_BITS
    pop rdx
    ret

; ------------------------------------------------------------------------------
; A growable text buffer on the heap (JSON.stringify, split, ...), re-entrant:
; R15 = the buffer cell (data pointer, length, capacity)
; ------------------------------------------------------------------------------
JSLB_DATA               equ 8
JSLB_LEN                equ 16
JSLB_CAP                equ 20
JSLB_SIZE               equ 24

jslb_new:
    push rax
    push rcx
    mov ecx, JSLB_SIZE
    call js_alloc
    mov r15, rax
    mov ecx, 64
    call js_alloc
    or byte [rax - 8 + GCH_FLAGS], GCF_LEAF
    mov [r15 + JSLB_DATA], rax
    mov dword [r15 + JSLB_CAP], 64
    pop rcx
    pop rax
    ret

; jslb_byte: AL -> appended
jslb_byte:
    push rcx
    push rdx
    mov edx, [r15 + JSLB_LEN]
    cmp edx, [r15 + JSLB_CAP]
    jb .room
    call jslb_grow
.room:
    mov rcx, [r15 + JSLB_DATA]
    mov [rcx + rdx], al
    inc dword [r15 + JSLB_LEN]
    pop rdx
    pop rcx
    ret

; jslb_grow: twice the room (the old data is left behind)
jslb_grow:
    push rax
    push rcx
    push rsi
    push rdi
    mov ecx, [r15 + JSLB_CAP]
    add ecx, ecx
    cmp ecx, JSSTR_MAX_LEN
    ja .too_long
    mov [r15 + JSLB_CAP], ecx
    call js_alloc
    or byte [rax - 8 + GCH_FLAGS], GCF_LEAF
    mov rdi, rax
    mov rsi, [r15 + JSLB_DATA]
    mov ecx, [r15 + JSLB_LEN]
    rep movsb
    mov [r15 + JSLB_DATA], rax
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret
.too_long:
    mov edx, JE_RANGE
    lea rsi, [jsmsg_string_length]
    xor edi, edi
    jmp js_throw

; jslb_bytes: RSI = bytes, RCX = count
jslb_bytes:
    push rax
    push rcx
    push rsi
.loop:
    test rcx, rcx
    jz .done
    lodsb
    call jslb_byte
    dec rcx
    jmp .loop
.done:
    pop rsi
    pop rcx
    pop rax
    ret

; jslb_cstr: RSI = NUL-terminated text
jslb_cstr:
    push rax
    push rsi
.loop:
    lodsb
    test al, al
    jz .done
    call jslb_byte
    jmp .loop
.done:
    pop rsi
    pop rax
    ret

; jslb_str: RAX = heap string
jslb_str:
    push rcx
    push rsi
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    call jslb_bytes
    pop rsi
    pop rcx
    ret

; jslb_value: -> RAX = the text as a string value
jslb_value:
    push rcx
    push rsi
    mov rsi, [r15 + JSLB_DATA]
    mov ecx, [r15 + JSLB_LEN]
    call jsstr_new
    pop rsi
    pop rcx
    jmp jsb_box_string

; ==============================================================================
; Array.prototype with callbacks
; ==============================================================================

; JSL_ITERATE kind: the loop shared by forEach / map / filter / some / every /
; find / findIndex. RBX = array, RAX = callback, R9 = thisArg
%macro JSL_ARRAY_CALLBACK_ENTRY 0
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call jsl_this_array
    mov r11, rbx
    BOX r11, rax, JS_OBJ_BITS       ; the array value (third argument)
    mov eax, 1
    call jsb_arg
    mov r9, rax                     ; thisArg
    xor eax, eax
    call jsl_callback
    mov rsi, rax                    ; the callback
    mov r10d, [rbx + JARR_LEN]      ; the length at the start
%endmacro

%macro JSL_ARRAY_CALLBACK_EXIT 0
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
%endmacro

; forEach(callback, thisArg)
jsl_array_for_each:
    JSL_ARRAY_CALLBACK_ENTRY
    xor edx, edx
.item:
    cmp edx, r10d
    jae .done
    call jsl_is_hole
    jc .next
    call jsl_elem
    mov rcx, rax
    mov rax, rsi
    call jsl_call3
.next:
    inc edx
    jmp .item
.done:
    mov rax, JS_UNDEF
    JSL_ARRAY_CALLBACK_EXIT

; map(callback, thisArg)
jsl_array_map:
    JSL_ARRAY_CALLBACK_ENTRY
    mov ecx, r10d
    call jsarr_new
    mov r8, rax
    call jsarr_set_length           ; holes stay holes
    xor edx, edx
.item:
    cmp edx, r10d
    jae .done
    call jsl_is_hole
    jc .next
    call jsl_elem
    mov rcx, rax
    mov rax, rsi
    call jsl_call3
    mov rcx, rax
    mov rax, r8
    call jsarr_set
.next:
    inc edx
    jmp .item
.done:
    mov rax, r8
    call jsl_box_obj
    JSL_ARRAY_CALLBACK_EXIT

; filter(callback, thisArg)
jsl_array_filter:
    JSL_ARRAY_CALLBACK_ENTRY
    call jsl_new_array
    xor edx, edx
.item:
    cmp edx, r10d
    jae .done
    call jsl_is_hole
    jc .next
    call jsl_elem
    mov rcx, rax
    mov rax, rsi
    call jsl_call3
    call js_truthy
    jnc .next
    mov rax, r8
    call jsarr_push
.next:
    inc edx
    jmp .item
.done:
    mov rax, r8
    call jsl_box_obj
    JSL_ARRAY_CALLBACK_EXIT

; some(callback) / every(callback)
jsl_array_some:
    JSL_ARRAY_CALLBACK_ENTRY
    mov r8d, 1                      ; stop when truthy
    jmp jsl_some_every
jsl_array_every:
    JSL_ARRAY_CALLBACK_ENTRY
    xor r8d, r8d                    ; stop when falsy
jsl_some_every:
    xor edx, edx
.item:
    cmp edx, r10d
    jae .end
    call jsl_is_hole
    jc .next
    call jsl_elem
    mov rcx, rax
    mov rax, rsi
    call jsl_call3
    call js_truthy
    setc al
    cmp al, r8b
    je .stop
.next:
    inc edx
    jmp .item
.stop:
    mov eax, r8d                    ; some: true, every: false
    jmp .result
.end:
    mov eax, r8d
    xor eax, 1                      ; some: false, every: true
.result:
    shr al, 1
    call js_bool
    JSL_ARRAY_CALLBACK_EXIT

; find / findIndex / findLast / findLastIndex
jsl_array_find:
    JSL_ARRAY_CALLBACK_ENTRY
    xor r8d, r8d
    jmp jsl_find
jsl_array_find_index:
    JSL_ARRAY_CALLBACK_ENTRY
    mov r8d, 1
    jmp jsl_find
jsl_array_find_last:
    JSL_ARRAY_CALLBACK_ENTRY
    mov r8d, 2
    jmp jsl_find
jsl_array_find_last_index:
    JSL_ARRAY_CALLBACK_ENTRY
    mov r8d, 3
; R8D bit 0: return the index, bit 1: from the end
jsl_find:
    xor edx, edx
    test r8d, 2
    jz .item
    mov edx, r10d
    dec edx
.item:
    cmp edx, r10d
    jae .none                       ; (also -1 going backwards)
    call jsl_elem
    mov rcx, rax
    mov rax, rsi
    call jsl_call3
    call js_truthy
    jc .found
    test r8d, 2
    jnz .back
    inc edx
    jmp .item
.back:
    dec edx
    jmp .item
.found:
    test r8d, 1
    jnz .index
    mov rax, rcx
    JSL_ARRAY_CALLBACK_EXIT
.index:
    mov eax, edx
    call jsb_from_int
    JSL_ARRAY_CALLBACK_EXIT
.none:
    mov rax, JS_UNDEF
    test r8d, 1
    jz .out
    mov rax, -1
    call jsb_from_int
.out:
    JSL_ARRAY_CALLBACK_EXIT

; reduce(callback, initial) / reduceRight
jsl_array_reduce:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    xor r8d, r8d                    ; forwards
    jmp jsl_reduce
jsl_array_reduce_right:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov r8d, 1
jsl_reduce:
    call jsl_this_array
    mov r11, rbx
    BOX r11, rax, JS_OBJ_BITS
    xor eax, eax
    call jsl_callback
    mov rsi, rax
    mov r10d, [rbx + JARR_LEN]
    ; the start and the accumulator
    xor edx, edx
    test r8d, r8d
    jz .start
    lea edx, [r10 - 1]
.start:
    cmp ecx, 2
    jb .first_item
    mov eax, 1
    call jsb_arg
    mov r9, rax                     ; initial value
    jmp .loop
.first_item:
    ; the first element that is there
    cmp edx, r10d
    jae .empty
    call jsl_is_hole
    jnc .take_first
    call .step
    jmp .first_item
.take_first:
    call jsl_elem
    mov r9, rax
    call .step
.loop:
    cmp edx, r10d
    jae .done
    call jsl_is_hole
    jc .skip
    ; callback(accumulator, element, index, array)
    call jsl_elem
    push r11
    mov rdi, rax
    mov eax, edx
    call jsb_from_int
    push rax
    push rdi
    push r9
    mov rdi, rsp
    mov rax, rsi
    push rdx
    push rcx
    mov rdx, JS_UNDEF
    mov ecx, 4
    call js_call
    pop rcx
    pop rdx
    add rsp, 32
    mov r9, rax
.skip:
    call .step
    jmp .loop
.done:
    mov rax, r9
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
.empty:
    mov edx, JE_TYPE
    lea rsi, [jsmsg_reduce_empty]
    xor edi, edi
    jmp js_throw
; .step: EDX to the next index (R8D = 1: backwards; below 0 wraps above the length)
.step:
    test r8d, r8d
    jnz .step_back
    inc edx
    ret
.step_back:
    dec edx
    ret

; ==============================================================================
; Array.prototype without callbacks
; ==============================================================================

; includes(value, from): like indexOf, but NaN finds NaN
jsl_array_includes:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    call jsl_this_array
    mov eax, 1
    call jsb_arg_integer
    mov r9, rax
    mov edx, [rbx + JARR_LEN]
    test r9, r9
    jns .from
    add r9, rdx
    jns .from
    xor r9d, r9d
.from:
    xor eax, eax
    call jsb_arg
    mov r8, rax
.loop:
    mov edx, [rbx + JARR_LEN]
    cmp r9, rdx
    jge .no
    mov edx, r9d
    call jsl_elem
    mov rdx, r8
    call jsl_same_value_zero
    jc .yes
    inc r9
    jmp .loop
.yes:
    stc
    jmp .out
.no:
    clc
.out:
    call js_bool
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; jsl_same_value_zero: RAX, RDX -> CF=1 if equal (=== but NaN equals NaN)
jsl_same_value_zero:
    call js_strict_equal
    jc .ret
    push rcx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_SPECIAL
    jae .no
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_SPECIAL
    jae .no
    movq xmm0, rax
    movq xmm1, rdx
    ucomisd xmm0, xmm0
    jnp .no
    ucomisd xmm1, xmm1
    jnp .no
    pop rcx
    stc
    ret
.no:
    pop rcx
    clc
.ret:
    ret

; lastIndexOf(value, from)
jsl_array_last_index_of:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    call jsl_this_array
    mov r9d, [rbx + JARR_LEN]
    dec r9                          ; from the end
    cmp ecx, 2
    jb .value
    mov eax, 1
    call jsb_arg_integer
    test rax, rax
    jns .clamp
    mov edx, [rbx + JARR_LEN]
    add rax, rdx
.clamp:
    cmp rax, r9
    jg .value
    mov r9, rax
.value:
    xor eax, eax
    call jsb_arg
    mov r8, rax
.loop:
    test r9, r9
    js .none
    mov edx, r9d
    call jsl_is_hole
    jc .next
    call jsl_elem
    mov rdx, r8
    call js_strict_equal
    jc .found
.next:
    dec r9
    jmp .loop
.found:
    mov rax, r9
    jmp .number
.none:
    mov rax, -1
.number:
    call jsb_from_int
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; concat(...values): arrays are spread, anything else appended
jsl_array_concat:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    call jsl_this_array
    mov rsi, rdi
    call jsl_new_array
    mov rdx, rbx
    BOX rdx, rax, JS_OBJ_BITS
    mov rax, r8
    call js_spread_into
.arg:
    test ecx, ecx
    jz .done
    mov rdx, [rsi]
    push rcx
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .single
    mov ecx, edx
    cmp byte [rcx + JH_KIND], JK_ARRAY
    jne .single
    mov rax, r8
    call js_spread_into
    jmp .next
.single:
    mov rcx, rdx
    mov rax, r8
    call jsarr_push
.next:
    pop rcx
    add rsi, 8
    dec ecx
    jmp .arg
.done:
    mov rax, r8
    call jsl_box_obj
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; reverse(): in place
jsl_array_reverse:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call jsl_this_array
    mov rsi, [rbx + JARR_ELEMS]
    xor ecx, ecx
    mov edx, [rbx + JARR_LEN]
    dec edx
.swap:
    cmp ecx, edx
    jge .done
    mov rax, [rsi + rcx*8]
    mov rdi, [rsi + rdx*8]
    mov [rsi + rcx*8], rdi
    mov [rsi + rdx*8], rax
    inc ecx
    dec edx
    jmp .swap
.done:
    mov rax, rbx
    call jsl_box_obj
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; sort(compare): a stable merge sort; undefined goes last, holes after that.
; Without a compare function the elements compare as strings.
; ------------------------------------------------------------------------------
jsl_array_sort:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call jsl_this_array
    xor r9d, r9d                    ; the compare function (0 = as strings)
    test ecx, ecx
    jz .gather
    mov rax, [rdi]
    mov rdx, JS_UNDEF
    cmp rax, rdx
    je .gather
    xor eax, eax
    call jsl_callback
    mov r9, rax
.gather:
    ; the values to sort (not undefined, not holes) to the front, in order
    mov rsi, [rbx + JARR_ELEMS]
    mov r10d, [rbx + JARR_LEN]
    xor ecx, ecx                    ; read
    xor edx, edx                    ; values kept
    xor r11d, r11d                  ; undefineds
.scan:
    cmp ecx, r10d
    jae .scanned
    mov rax, [rsi + rcx*8]
    mov rdi, JS_HOLE
    cmp rax, rdi
    je .scan_next
    mov rdi, JS_UNDEF
    cmp rax, rdi
    jne .keep
    inc r11d
    jmp .scan_next
.keep:
    mov [rsi + rdx*8], rax
    inc edx
.scan_next:
    inc ecx
    jmp .scan
.scanned:
    ; sort elems[0 .. edx)
    mov r8d, edx
    push rdx
    push rcx
    mov ecx, r8d
    lea ecx, [rcx*8 + 8]
    call js_alloc                   ; scratch
    mov rdi, rax
    pop rcx
    pop rdx
    mov ecx, r8d
    call jsl_merge_sort             ; RSI = values, RDI = scratch, ECX = count
    ; then the undefineds, then holes
    mov ecx, r8d
    mov rax, JS_UNDEF
.undefined:
    test r11d, r11d
    jz .holes
    mov [rsi + rcx*8], rax
    inc ecx
    dec r11d
    jmp .undefined
.holes:
    mov rax, JS_HOLE
.hole:
    cmp ecx, r10d
    jae .done
    mov [rsi + rcx*8], rax
    inc ecx
    jmp .hole
.done:
    mov rax, rbx
    call jsl_box_obj
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

; jsl_merge_sort: RSI = values, RDI = scratch (as big), ECX = count, R9 =
; compare function or 0 -> RSI sorted (bottom-up merge sort, stable)
jsl_merge_sort:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r15d, ecx                   ; n
    mov r14d, 1                     ; run width
.pass:
    cmp r14d, r15d
    jae .sorted
    xor r13d, r13d                  ; left start
.pair:
    cmp r13d, r15d
    jae .copy_back
    ; left [r13, mid), right [mid, end)
    lea r12d, [r13 + r14]           ; mid
    cmp r12d, r15d
    jbe .mid_ok
    mov r12d, r15d
.mid_ok:
    lea r11d, [r12 + r14]           ; end
    cmp r11d, r15d
    jbe .end_ok
    mov r11d, r15d
.end_ok:
    mov ecx, r13d                   ; i (left)
    mov edx, r12d                   ; j (right)
    mov r10d, r13d                  ; k (output)
.merge:
    cmp ecx, r12d
    jae .take_right
    cmp edx, r11d
    jae .take_left
    ; right < left ? right : left   (ties keep the left: stable)
    mov rax, [rsi + rdx*8]
    mov rbx, [rsi + rcx*8]
    call jsl_sort_less              ; CF=1: RAX < RBX
    jc .take_right
.take_left:
    cmp ecx, r12d
    jae .run_done
    mov rax, [rsi + rcx*8]
    mov [rdi + r10*8], rax
    inc ecx
    inc r10d
    jmp .merge
.take_right:
    cmp edx, r11d
    jae .run_done
    mov rax, [rsi + rdx*8]
    mov [rdi + r10*8], rax
    inc edx
    inc r10d
    jmp .merge
.run_done:
    mov r13d, r11d
    jmp .pair
.copy_back:
    xor ecx, ecx
.copy:
    cmp ecx, r15d
    jae .copied
    mov rax, [rdi + rcx*8]
    mov [rsi + rcx*8], rax
    inc ecx
    jmp .copy
.copied:
    add r14d, r14d
    jmp .pass
.sorted:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsl_sort_less: RAX = a, RBX = b, R9 = compare function or 0 -> CF=1 if a
; sorts before b
jsl_sort_less:
    push rax
    push rcx
    push rdx
    push rdi
    test r9, r9
    jz .strings
    push rbx
    push rax
    mov rdi, rsp
    mov rax, r9
    mov rdx, JS_UNDEF
    mov ecx, 2
    call js_call
    add rsp, 16
    call js_to_number
    movq xmm0, rax
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jp .no
    jb .yes
    jmp .no
.strings:
    call js_to_string
    mov rdx, rax
    mov rax, rbx
    call js_to_string
    xchg rax, rdx
    call jsstr_compare
    test eax, eax
    js .yes
.no:
    pop rdi
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.yes:
    pop rdi
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; splice(start, deleteCount, ...items) -> the removed elements
jsl_array_splice:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call jsl_this_array
    mov r11d, ecx                   ; argument count
    mov edx, [rbx + JARR_LEN]
    xor eax, eax
    call jsb_arg_integer
    call jsb_relative
    mov r9, rax                     ; start
    ; how many to remove
    mov r10, rdx
    sub r10, r9                     ; everything after start
    test r11d, r11d
    jnz .count
    xor r10d, r10d                  ; splice(): nothing
.count:
    cmp r11d, 2
    jb .count_done
    mov eax, 1
    call jsb_arg_integer
    test rax, rax
    jns .count_max
    xor eax, eax
.count_max:
    cmp rax, r10
    jge .count_done
    mov r10, rax
.count_done:
    ; the removed ones
    call jsl_new_array
    xor ecx, ecx
.removed:
    cmp ecx, r10d
    jae .items
    lea edx, [r9 + rcx]
    push rcx
    mov rax, [rbx + JARR_ELEMS]
    mov rcx, [rax + rdx*8]
    mov rax, r8
    call jsarr_push
    pop rcx
    inc ecx
    jmp .removed
.items:
    ; new items: argument count - 2
    mov esi, r11d
    sub esi, 2
    jns .have_items
    xor esi, esi
.have_items:
    ; shift the tail: length changes by items - removed
    mov edx, [rbx + JARR_LEN]
    mov eax, edx
    add eax, esi
    sub eax, r10d                   ; new length
    push rax
    cmp esi, r10d
    jbe .shrink
    ; grow first, then move the tail right (from the end)
    mov ecx, eax
    mov rax, rbx
    call jsarr_reserve
    mov rax, [rbx + JARR_ELEMS]
    mov ecx, edx                    ; old length
.right:
    lea r11d, [r9 + r10]
    cmp ecx, r11d
    jbe .moved
    dec ecx
    mov r11, [rax + rcx*8]
    push rcx
    add ecx, esi
    sub ecx, r10d
    mov [rax + rcx*8], r11
    pop rcx
    jmp .right
.shrink:
    ; move the tail left
    mov rax, [rbx + JARR_ELEMS]
    lea ecx, [r9 + r10]             ; from
.left:
    cmp ecx, edx
    jae .moved
    mov r11, [rax + rcx*8]
    push rcx
    sub ecx, r10d
    add ecx, esi
    mov [rax + rcx*8], r11
    pop rcx
    inc ecx
    jmp .left
.moved:
    pop rax
    mov [rbx + JARR_LEN], eax
    ; write the items
    mov rax, [rbx + JARR_ELEMS]
    xor ecx, ecx
.write:
    cmp ecx, esi
    jae .done
    mov r11, [rdi + rcx*8 + 16]     ; arguments from the third
    lea edx, [r9 + rcx]
    mov [rax + rdx*8], r11
    inc ecx
    jmp .write
.done:
    mov rax, r8
    call jsl_box_obj
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

; shift(): the first element, removed
jsl_array_shift:
    push rbx
    push rcx
    push rdx
    push rsi
    call jsl_this_array
    mov ecx, [rbx + JARR_LEN]
    mov rax, JS_UNDEF
    test ecx, ecx
    jz .out
    xor edx, edx
    call jsl_elem
    mov rsi, [rbx + JARR_ELEMS]
    xor edx, edx
.move:
    inc edx
    cmp edx, ecx
    jae .moved
    push rax
    mov rax, [rsi + rdx*8]
    mov [rsi + rdx*8 - 8], rax
    pop rax
    jmp .move
.moved:
    dec dword [rbx + JARR_LEN]
.out:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; unshift(...items) -> new length
jsl_array_unshift:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    call jsl_this_array
    mov r8d, ecx                    ; items
    mov edx, [rbx + JARR_LEN]
    lea ecx, [rdx + r8]
    mov rax, rbx
    call jsarr_reserve
    mov rsi, [rbx + JARR_ELEMS]
    ; move everything right by the item count
    mov ecx, edx
.right:
    test ecx, ecx
    jz .write
    dec ecx
    mov rax, [rsi + rcx*8]
    push rcx
    add ecx, r8d
    mov [rsi + rcx*8], rax
    pop rcx
    jmp .right
.write:
    xor ecx, ecx
.item:
    cmp ecx, r8d
    jae .done
    mov rax, [rdi + rcx*8]
    mov [rsi + rcx*8], rax
    inc ecx
    jmp .item
.done:
    add edx, r8d
    mov [rbx + JARR_LEN], edx
    mov eax, edx
    call jsb_from_int
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; fill(value, start, end)
jsl_array_fill:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    call jsl_this_array
    mov edx, [rbx + JARR_LEN]
    mov eax, 1
    call jsb_arg_integer
    call jsb_relative
    mov r8, rax
    mov eax, 2
    call jsb_arg_integer
    jnc .end
    mov rax, rdx
.end:
    call jsb_relative
    mov r9, rax
    xor eax, eax
    call jsb_arg
    mov rcx, [rbx + JARR_ELEMS]
.fill:
    cmp r8, r9
    jge .done
    mov [rcx + r8*8], rax
    inc r8
    jmp .fill
.done:
    mov rax, rbx
    call jsl_box_obj
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; flat(depth = 1)
jsl_array_flat:
    push rbx
    push rcx
    push rdx
    push r8
    call jsl_this_array
    mov edx, 1
    test ecx, ecx
    jz .depth
    xor eax, eax
    call jsb_arg_integer
    mov edx, 0x7FFFFFFF             ; (Infinity)
    cmp rax, rdx
    jg .depth
    mov edx, eax
.depth:
    call jsl_new_array
    call jsl_flatten                ; RBX into R8, EDX levels
    mov rax, r8
    call jsl_box_obj
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; jsl_flatten: RBX = array, R8 = target, EDX = levels -> elements appended,
; arrays among them flattened EDX levels deep (holes skipped)
jsl_flatten:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov esi, edx
    xor edx, edx
.item:
    cmp edx, [rbx + JARR_LEN]
    jae .done
    call jsl_is_hole
    jc .next
    call jsl_elem
    test esi, esi
    jle .append
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .append
    mov ecx, eax
    cmp byte [rcx + JH_KIND], JK_ARRAY
    jne .append
    push rbx
    push rdx
    mov rbx, rcx
    lea edx, [rsi - 1]
    call jsl_flatten
    pop rdx
    pop rbx
    jmp .next
.append:
    mov rcx, rax
    mov rax, r8
    call jsarr_push
.next:
    inc edx
    jmp .item
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; flatMap(callback, thisArg): map, then flat(1)
jsl_array_flat_map:
    push rbx
    push rdx
    push r8
    call jsl_array_map
    mov ebx, eax
    call jsl_new_array
    mov edx, 1
    call jsl_flatten
    mov rax, r8
    call jsl_box_obj
    pop r8
    pop rdx
    pop rbx
    ret

; at(index): negative counts from the end
jsl_array_at:
    push rbx
    push rdx
    call jsl_this_array
    xor eax, eax
    call jsb_arg_integer
    test rax, rax
    jns .index
    mov edx, [rbx + JARR_LEN]
    add rax, rdx
    js .undefined
.index:
    mov edx, [rbx + JARR_LEN]
    cmp rax, rdx
    jae .undefined
    mov edx, eax
    call jsl_elem
    jmp .out
.undefined:
    mov rax, JS_UNDEF
.out:
    pop rdx
    pop rbx
    ret

; Array.from(arrayLike or iterable, mapFn)
jsl_array_from:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov r10d, ecx
    call jsl_new_array
    xor eax, eax
    call jsb_arg
    mov rsi, rax
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_STRING
    je .spread
    cmp ecx, JS_TAG_OBJECT
    jne .map
    mov ecx, eax
    cmp byte [rcx + JH_KIND], JK_ARRAY
    je .spread
    ; array-like: { length: n, 0: ..., 1: ... }
    mov rdx, [atom_length]
    call js_get
    call js_to_number
    call jsb_integer
    mov r9, rax
    xor edx, edx
.like:
    cmp rdx, r9
    jge .map
    mov eax, edx
    call jsb_from_int
    push rdx
    mov rdx, rax
    mov rax, rsi
    call js_get_elem
    mov rcx, rax
    mov rax, r8
    call jsarr_push
    pop rdx
    inc edx
    jmp .like
.spread:
    mov rdx, rsi
    mov rax, r8
    call js_spread_into
.map:
    cmp r10d, 2
    jb .done
    mov ecx, r10d
    mov eax, 1
    call jsb_arg
    call js_is_callable
    jnc .done
    ; results = items.map(mapFn)
    mov rsi, rax
    mov rbx, r8
    mov r11, rbx
    BOX r11, rax, JS_OBJ_BITS
    mov r9, JS_UNDEF
    xor edx, edx
.mapped:
    cmp edx, [rbx + JARR_LEN]
    jae .done
    call jsl_elem
    mov rcx, rax
    mov rax, rsi
    call jsl_call3
    mov rcx, [rbx + JARR_ELEMS]
    mov [rcx + rdx*8], rax
    inc edx
    jmp .mapped
.done:
    mov rax, r8
    call jsl_box_obj
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

; Array.of(...items)
jsl_array_of:
    push rcx
    push rdx
    push rdi
    push r8
    call jsl_new_array
.item:
    test ecx, ecx
    jz .done
    push rcx
    mov rcx, [rdi]
    mov rax, r8
    call jsarr_push
    pop rcx
    add rdi, 8
    dec ecx
    jmp .item
.done:
    mov rax, r8
    call jsl_box_obj
    pop r8
    pop rdi
    pop rdx
    pop rcx
    ret

; ==============================================================================
; Function.prototype
; ==============================================================================

; call(thisArg, ...args)
jsl_function_call:
    push rcx
    push rdx
    push rdi
    mov rax, JS_UNDEF
    test ecx, ecx
    jz .no_this
    mov rax, [rdi]
    add rdi, 8
    dec ecx
.no_this:
    xchg rax, rdx                   ; RDX = thisArg, RAX = the function
    call js_call
    pop rdi
    pop rdx
    pop rcx
    ret

; apply(thisArg, argsArray)
jsl_function_apply:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    mov rsi, rdx                    ; the function
    mov eax, 1
    call jsb_arg
    mov rbx, rax
    xor eax, eax
    call jsb_arg
    mov rdx, rax                    ; thisArg
    ; the arguments: an array (or arguments), else none
    xor ecx, ecx
    mov rdi, rsp                    ; (no arguments: any pointer)
    mov rax, rbx
    shr rax, 48
    cmp eax, JS_TAG_OBJECT
    jne .call
    mov ebx, ebx
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .call
    ; holes become undefined: copy them onto the kernel stack
    mov ecx, [rbx + JARR_LEN]
    cmp ecx, 0x10000
    jbe .copy
    mov ecx, 0x10000
.copy:
    push rbp
    mov rbp, rsp
    lea rax, [rcx*8 + 8]
    sub rsp, rax
    and rsp, -16
    mov rdi, rsp
    push rdx
    xor edx, edx
.arg:
    cmp edx, ecx
    jae .args_done
    call jsl_elem
    mov [rdi + rdx*8], rax
    inc edx
    jmp .arg
.args_done:
    pop rdx
    mov rax, rsi
    call js_call
    mov rsp, rbp
    pop rbp
    jmp .out
.call:
    mov rax, rsi
    call js_call
.out:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; bind(thisArg, ...args) -> a function calling this one with them first
jsl_function_bind:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rax, rdx
    call js_is_callable
    jnc .bad
    mov rsi, rdx                    ; the target
    ; data: [target, thisArg, bound args array]
    call jsl_new_array              ; R8
    push rcx
    mov rcx, rsi
    mov rax, r8
    call jsarr_push
    pop rcx
    mov rax, JS_UNDEF
    test ecx, ecx
    jz .this
    mov rax, [rdi]
.this:
    push rcx
    mov rcx, rax
    mov rax, r8
    call jsarr_push
    pop rcx
    mov rbx, r8
    call jsl_new_array
    xchg rbx, r8                    ; RBX = bound args, R8 = data
    dec ecx
    jle .args_done
    add rdi, 8
.arg:
    push rcx
    mov rcx, [rdi]
    mov rax, rbx
    call jsarr_push
    pop rcx
    add rdi, 8
    dec ecx
    jnz .arg
.args_done:
    mov rcx, rbx
    BOX rcx, rax, JS_OBJ_BITS
    mov rax, r8
    call jsarr_push
    ; the bound function
    lea rax, [jsl_bound_call]
    xor ecx, ecx
    mov rdx, [atom_empty]
    call jsfn_native
    mov [rax + JFN_DATA], r8
    call jsl_box_obj
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.bad:
    lea rsi, [jsmsg_illegal]
    xor edi, edi
    jmp js_throw_type

; jsl_bound_call: a function made by bind(): R10 = itself -> the target
; called with the bound this and arguments, then these
jsl_bound_call:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push rbp
    mov rbp, rsp
    mov rsi, [r10 + JFN_DATA]       ; [target, this, args]
    mov rsi, [rsi + JARR_ELEMS]
    mov rbx, [rsi + 16]
    mov ebx, ebx                    ; the bound arguments
    ; all the arguments on the kernel stack
    mov eax, [rbx + JARR_LEN]
    add eax, ecx
    lea rax, [rax*8 + 8]
    sub rsp, rax
    and rsp, -16
    mov rdx, rdi                    ; the call's own arguments
    mov rdi, rsp
    xor eax, eax
.bound:
    cmp eax, [rbx + JARR_LEN]
    jae .own
    push rsi
    mov rsi, [rbx + JARR_ELEMS]
    mov rsi, [rsi + rax*8]
    mov [rdi + rax*8], rsi
    pop rsi
    inc eax
    jmp .bound
.own:
    push rcx
.own_arg:
    test ecx, ecx
    jz .call
    push rsi
    mov rsi, [rdx]
    mov [rdi + rax*8], rsi
    pop rsi
    add rdx, 8
    inc eax
    dec ecx
    jmp .own_arg
.call:
    pop rcx
    mov ecx, eax                    ; total
    mov rax, [rsi]                  ; target
    cmp r8d, 1
    je .construct                   ; new bound(...): new target(...)
    mov rdx, [rsi + 8]              ; this
    call js_call
    jmp .done
.construct:
    call js_construct
.done:
    mov rsp, rbp
    pop rbp
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ==============================================================================
; String.prototype
; ==============================================================================

; JSL_THIS_STRING "name": RDX = this -> RAX = ToString(this) (TypeError for
; null / undefined); RSI is clobbered
%macro JSL_THIS_STRING 1
    [section .rodata]
    %%name: db %1, 0
    __SECT__
    lea rsi, [%%name]
    call jsb_this_string
%endmacro

; jsl_match_at: RBX = string, R8 = pattern, R9 = position -> CF=1 if the
; pattern is there
jsl_match_at:
    push rax
    push rcx
    push rsi
    push rdi
    test r9, r9
    js .no
    mov eax, [rbx + JSTR_LEN]
    mov ecx, [r8 + JSTR_LEN]
    sub rax, rcx
    cmp r9, rax
    jg .no
    test ecx, ecx
    jz .yes
    lea rsi, [rbx + JSTR_DATA + r9]
    lea rdi, [r8 + JSTR_DATA]
    repe cmpsb
    jne .no
.yes:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    stc
    ret
.no:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    clc
    ret

; jsl_search: RBX = string, R8 = pattern, R9 = start (0 or more) -> R9 =
; where the pattern is next found, CF=1 when it is not there
jsl_search:
    push rax
    push rcx
    mov eax, [rbx + JSTR_LEN]
    mov ecx, [r8 + JSTR_LEN]
    sub rax, rcx
.try:
    cmp r9, rax
    jg .none
    call jsl_match_at
    jc .found
    inc r9
    jmp .try
.found:
    pop rcx
    pop rax
    clc
    ret
.none:
    pop rcx
    pop rax
    stc
    ret

; split(separator, limit)
jsl_string_split:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    JSL_THIS_STRING "split"
    mov rbx, rax
    mov r11d, -1                    ; the limit
    mov eax, 1
    call jsb_arg
    mov rdx, JS_UNDEF
    cmp rax, rdx
    je .limit_done
    call js_to_int32
    mov r11d, eax
.limit_done:
    push rcx
    xor ecx, ecx
    call jsarr_new
    mov r10, rax                    ; the pieces
    pop rcx
    test r11d, r11d
    jz .done
    xor eax, eax
    call jsb_arg
    mov rdx, JS_UNDEF
    cmp rax, rdx
    je .whole
    call js_to_string
    mov r8, rax
    cmp dword [r8 + JSTR_LEN], 0
    je .chars
    xor edi, edi                    ; where the next piece starts
.next:
    mov r9, rdi
    call jsl_search
    jc .last
    call .piece
    cmp [r10 + JARR_LEN], r11d
    jae .done
    mov edi, r9d
    add edi, [r8 + JSTR_LEN]
    jmp .next
.last:
    mov r9d, [rbx + JSTR_LEN]
    call .piece
    jmp .done
.chars:
    xor edi, edi
.char:
    cmp edi, [rbx + JSTR_LEN]
    jae .done
    cmp [r10 + JARR_LEN], r11d
    jae .done
    lea r9d, [rdi + 1]
    call .piece
    inc edi
    jmp .char
.whole:
    xor edi, edi
    mov r9d, [rbx + JSTR_LEN]
    call .piece
.done:
    mov rax, r10
    call jsl_box_obj
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
; .piece: bytes RDI .. R9 of RBX appended to R10
.piece:
    push rax
    push rcx
    push rsi
    lea rsi, [rbx + JSTR_DATA + rdi]
    mov ecx, r9d
    sub ecx, edi
    call jsstr_new
    mov rcx, rax
    BOX rcx, rax, JS_STR_BITS
    mov rax, r10
    call jsarr_push
    pop rsi
    pop rcx
    pop rax
    ret

; replace(pattern, replacement) / replaceAll: string patterns (regular
; expressions come later); the replacement is a function or a string where
; $$, $&, $` and $' stand for "$", the match, and the text before / after it
jsl_string_replace_all:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r15
    mov r11d, 1                     ; bit 0: all, bit 1: function
    jmp jsl_replace
jsl_string_replace:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r15
    xor r11d, r11d
jsl_replace:
    JSL_THIS_STRING "replace"
    mov rbx, rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov r8, rax                     ; the pattern
    mov eax, 1
    call jsb_arg
    call js_is_callable
    jc .function
    call js_to_string
    jmp .replacement
.function:
    or r11d, 2
.replacement:
    mov r10, rax
    call jslb_new
    xor edi, edi                    ; copied up to here
    xor r9d, r9d
.search:
    call jsl_search
    jc .rest
    lea rsi, [rbx + JSTR_DATA + rdi]
    mov ecx, r9d
    sub ecx, edi
    call jslb_bytes
    call .substitute
    mov edi, r9d
    add edi, [r8 + JSTR_LEN]
    test r11d, 1
    jz .rest
    cmp dword [r8 + JSTR_LEN], 0
    jne .again
    ; an empty pattern matches between all the characters
    cmp edi, [rbx + JSTR_LEN]
    jae .rest
    mov al, [rbx + JSTR_DATA + rdi]
    call jslb_byte
    inc edi
.again:
    mov r9d, edi
    jmp .search
.rest:
    lea rsi, [rbx + JSTR_DATA + rdi]
    mov ecx, [rbx + JSTR_LEN]
    sub ecx, edi
    call jslb_bytes
    call jslb_value
    pop r15
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
; .substitute: the replacement for the match at R9 appended
.substitute:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    test r11d, 2
    jnz .call
    mov ecx, [r10 + JSTR_LEN]
    lea rsi, [r10 + JSTR_DATA]
.sub_char:
    test ecx, ecx
    jz .sub_done
    lodsb
    dec ecx
    cmp al, '$'
    jne .sub_put
    test ecx, ecx
    jz .sub_put
    mov dl, [rsi]
    cmp dl, '$'
    je .dollar
    cmp dl, '&'
    je .match
    cmp dl, '`'
    je .before
    cmp dl, "'"
    je .after
.sub_put:
    call jslb_byte
    jmp .sub_char
.dollar:
    inc rsi
    dec ecx
    jmp .sub_put
.match:
    inc rsi
    dec ecx
    mov rax, r8
    call jslb_str
    jmp .sub_char
.before:
    inc rsi
    dec ecx
    push rcx
    push rsi
    lea rsi, [rbx + JSTR_DATA]
    mov ecx, r9d
    call jslb_bytes
    pop rsi
    pop rcx
    jmp .sub_char
.after:
    inc rsi
    dec ecx
    push rcx
    push rsi
    mov eax, r9d
    add eax, [r8 + JSTR_LEN]
    lea rsi, [rbx + JSTR_DATA + rax]
    mov ecx, [rbx + JSTR_LEN]
    sub ecx, eax
    call jslb_bytes
    pop rsi
    pop rcx
    jmp .sub_char
.call:
    ; replacement(match, offset, string)
    mov rax, rbx
    BOX rax, rdx, JS_STR_BITS
    push rax
    mov eax, r9d
    call jsb_from_int
    push rax
    mov rax, r8
    BOX rax, rdx, JS_STR_BITS
    push rax
    mov rdi, rsp
    mov rax, r10
    mov rdx, JS_UNDEF
    mov ecx, 3
    call js_call
    add rsp, 24
    call js_to_string
    call jslb_str
.sub_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; includes(search, position) / startsWith(search, position) /
; endsWith(search, end)
jsl_string_includes:
    push rbx
    push rdx
    push rsi
    push r8
    push r9
    push r11
    xor r11d, r11d
    jmp jsl_string_has
jsl_string_starts_with:
    push rbx
    push rdx
    push rsi
    push r8
    push r9
    push r11
    mov r11d, 1
    jmp jsl_string_has
jsl_string_ends_with:
    push rbx
    push rdx
    push rsi
    push r8
    push r9
    push r11
    mov r11d, 2
jsl_string_has:
    JSL_THIS_STRING "includes"
    mov rbx, rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov r8, rax
    mov edx, [rbx + JSTR_LEN]
    mov eax, 1
    call jsb_arg_integer
    jnc .position
    xor eax, eax
    cmp r11d, 2
    jne .position
    mov rax, rdx                    ; endsWith: the end by default
.position:
    test rax, rax
    jns .upper
    xor eax, eax
.upper:
    cmp rax, rdx
    jle .clamped
    mov rax, rdx
.clamped:
    mov r9, rax
    cmp r11d, 1
    jb .search
    je .at
    ; endsWith: the pattern ends at the position
    mov eax, [r8 + JSTR_LEN]
    sub r9, rax
    js .no
.at:
    call jsl_match_at
    jmp .result
.search:
    call jsl_search
    cmc
    jmp .result
.no:
    clc
.result:
    call js_bool
    pop r11
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rbx
    ret

; padStart(length, filler) / padEnd(length, filler)
jsl_string_pad_start:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r11
    push r15
    xor r11d, r11d
    jmp jsl_string_pad
jsl_string_pad_end:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r11
    push r15
    mov r11d, 1
jsl_string_pad:
    JSL_THIS_STRING "padStart"
    mov rbx, rax
    xor eax, eax
    call jsb_arg_integer
    mov r9, rax                     ; the length wanted
    mov eax, 1
    call jsb_arg
    mov rdx, JS_UNDEF
    cmp rax, rdx
    je .space
    call js_to_string
    jmp .filler
.space:
    lea rsi, [jsl_str_space]
    call jsstr_from_cstr
.filler:
    mov r8, rax
    mov eax, [rbx + JSTR_LEN]
    sub r9, rax                     ; how many to add
    jle .same
    cmp dword [r8 + JSTR_LEN], 0
    je .same
    call jslb_new
    test r11d, r11d
    jz .pad
    mov rax, rbx
    call jslb_str
.pad:
    xor edx, edx
.fill:
    mov al, [r8 + JSTR_DATA + rdx]
    call jslb_byte
    inc edx
    cmp edx, [r8 + JSTR_LEN]
    jb .count
    xor edx, edx
.count:
    dec r9
    jnz .fill
    test r11d, r11d
    jnz .text
    mov rax, rbx
    call jslb_str
.text:
    call jslb_value
    jmp .out
.same:
    mov rax, rbx
    call jsb_box_string
.out:
    pop r15
    pop r11
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; repeat(count)
jsl_string_repeat:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    JSL_THIS_STRING "repeat"
    mov rbx, rax
    xor eax, eax
    call jsb_arg_integer
    test rax, rax
    js .bad
    mov rcx, 9007199254740992       ; Infinity
    cmp rax, rcx
    jae .bad
    mov rcx, rax
    cmp dword [rbx + JSTR_LEN], 0
    je .empty
    test rcx, rcx
    jz .empty
    cmp rcx, JSSTR_MAX_LEN
    ja .too_long
    mov eax, [rbx + JSTR_LEN]
    imul rax, rcx
    cmp rax, JSSTR_MAX_LEN
    ja .too_long
    push rcx
    mov ecx, eax
    call jsstr_alloc
    pop rcx
    lea rdi, [rax + JSTR_DATA]
.copy:
    push rcx
    lea rsi, [rbx + JSTR_DATA]
    mov ecx, [rbx + JSTR_LEN]
    rep movsb
    pop rcx
    dec rcx
    jnz .copy
    jmp .out
.empty:
    mov rax, [atom_empty]
.out:
    call jsb_box_string
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.bad:
    mov edx, JE_RANGE
    lea rsi, [jsmsg_repeat]
    xor edi, edi
    jmp js_throw
.too_long:
    mov edx, JE_RANGE
    lea rsi, [jsmsg_string_length]
    xor edi, edi
    jmp js_throw

; trimStart() / trimEnd()
jsl_string_trim_start:
    push rcx
    push rsi
    JSL_THIS_STRING "trimStart"
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    call jsnum_skip_space
    jmp jsl_trim_out
jsl_string_trim_end:
    push rcx
    push rsi
    JSL_THIS_STRING "trimEnd"
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    call jsnum_trim_end
jsl_trim_out:
    call jsstr_new
    call jsb_box_string
    pop rsi
    pop rcx
    ret

; lastIndexOf(search, position)
jsl_string_last_index_of:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    JSL_THIS_STRING "lastIndexOf"
    mov rbx, rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov r8, rax
    mov r9d, [rbx + JSTR_LEN]
    mov eax, 1
    call jsb_arg_number
    movq xmm0, rax
    ucomisd xmm0, xmm0
    jp .from                        ; NaN and undefined: from the end
    call jsb_integer
    test rax, rax
    jns .max
    xor eax, eax
.max:
    cmp rax, r9
    jge .from
    mov r9, rax
.from:
    mov eax, [rbx + JSTR_LEN]
    mov edx, [r8 + JSTR_LEN]
    sub rax, rdx
    cmp r9, rax
    jle .try
    mov r9, rax
.try:
    test r9, r9
    js .none
    call jsl_match_at
    jc .found
    dec r9
    jmp .try
.found:
    mov rax, r9
    jmp .number
.none:
    mov rax, -1
.number:
    call jsb_from_int
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; at(index): negative counts from the end
jsl_string_at:
    push rbx
    push rdx
    push rsi
    JSL_THIS_STRING "at"
    mov rbx, rax
    xor eax, eax
    call jsb_arg_integer
    mov edx, [rbx + JSTR_LEN]
    test rax, rax
    jns .index
    add rax, rdx
    js .undefined
.index:
    cmp rax, rdx
    jae .undefined
    movzx eax, byte [rbx + JSTR_DATA + rax]
    call jsstr_char
    call jsb_box_string
    jmp .out
.undefined:
    mov rax, JS_UNDEF
.out:
    pop rsi
    pop rdx
    pop rbx
    ret

; concat(...values)
jsl_string_concat:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    JSL_THIS_STRING "concat"
    mov r8, rax
.arg:
    test ecx, ecx
    jz .done
    mov rax, [rdi]
    call js_to_string
    mov rdx, rax
    mov rax, r8
    push rcx
    call jsstr_concat
    pop rcx
    mov r8, rax
    add rdi, 8
    dec ecx
    jmp .arg
.done:
    mov rax, r8
    call jsb_box_string
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; localeCompare(other): byte order for now
jsl_string_locale_compare:
    push rdx
    push rsi
    JSL_THIS_STRING "localeCompare"
    push rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov rdx, rax
    pop rax
    call jsstr_compare
    movsx rax, eax
    call jsb_from_int
    pop rsi
    pop rdx
    ret

; ==============================================================================
; Object
; ==============================================================================

; jsl_arg_coercible: EAX = argument index -> RAX = that argument (TypeError
; for null and undefined)
jsl_arg_coercible:
    call jsb_arg
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jne .ok
    cmp eax, 1
    jbe .bad
.ok:
    pop rdx
    ret
.bad:
    lea rsi, [jsmsg_to_object]
    xor edi, edi
    jmp js_throw_type

; jsl_arg_object: EAX = argument index -> RAX = that argument, which must be
; an object (TypeError otherwise)
jsl_arg_object:
    call jsb_arg
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .bad
    pop rdx
    ret
.bad:
    lea rsi, [jsmsg_not_object]
    xor edi, edi
    jmp js_throw_type

; jsl_key_atom: RAX = key value -> RAX = its atom
jsl_key_atom:
    call js_to_string
    jmp jsstr_intern

; Object.values(object) / Object.entries(object)
jsl_object_values:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r11
    xor r11d, r11d
    jmp jsl_object_list
jsl_object_entries:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r11
    mov r11d, 1
jsl_object_list:
    xor eax, eax
    call jsl_arg_coercible
    mov rsi, rax
    call js_own_keys
    mov rbx, rax                    ; the keys
    call jsl_new_array
    xor r9d, r9d
.key:
    cmp r9d, [rbx + JARR_LEN]
    jae .done
    mov rdx, [rbx + JARR_ELEMS]
    mov rdx, [rdx + r9*8]
    mov rax, rsi
    push rdx
    call js_get_elem
    pop rdx
    mov rcx, rax
    test r11d, r11d
    jz .push
    ; [key, value]
    push r8
    call jsl_new_array
    push rcx
    mov rcx, rdx
    mov rax, r8
    call jsarr_push
    pop rcx
    mov rax, r8
    call jsarr_push
    mov rcx, r8
    BOX rcx, rax, JS_OBJ_BITS
    pop r8
.push:
    mov rax, r8
    call jsarr_push
    inc r9d
    jmp .key
.done:
    mov rax, r8
    call jsl_box_obj
    pop r11
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Object.assign(target, ...sources): ordinary assignments (setters and host
; objects such as element.style see them)
jsl_object_assign:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    xor eax, eax
    call jsl_arg_coercible
    mov r8, rax                     ; the target
.source:
    dec ecx
    jle .done
    add rdi, 8
    mov rsi, [rdi]
    mov rdx, rsi
    call vm_nullish_rdx
    jc .source
    mov rax, rsi
    call js_own_keys
    mov rbx, rax
    xor r9d, r9d
.key:
    cmp r9d, [rbx + JARR_LEN]
    jae .source
    mov rdx, [rbx + JARR_ELEMS]
    mov rdx, [rdx + r9*8]
    mov rax, rsi
    push rdx
    call js_get_elem
    pop rdx
    push rcx
    mov rcx, rax
    mov rax, r8
    call js_put_elem
    pop rcx
    inc r9d
    jmp .key
.done:
    mov rax, r8
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsl_proto_arg: RAX = value -> RAX = object pointer, or 0 for null
; (TypeError for anything else)
jsl_proto_arg:
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    je .object
    mov rdx, JS_NULL
    cmp rax, rdx
    jne .bad
    xor eax, eax
    pop rdx
    ret
.object:
    mov eax, eax
    pop rdx
    ret
.bad:
    lea rsi, [jsmsg_proto]
    xor edi, edi
    jmp js_throw_type

; jsl_proto_of: RAX = value (not null or undefined) -> RAX = its prototype
; (raw, 0 = none)
jsl_proto_of:
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    je .object
    cmp edx, JS_TAG_STRING
    je .string
    cmp edx, JS_TAG_SPECIAL
    je .boolean
    mov rax, [js_number_proto]
    jmp .out
.string:
    mov rax, [js_string_proto]
    jmp .out
.boolean:
    mov rax, [js_boolean_proto]
    jmp .out
.object:
    mov eax, eax
    mov rax, [rax + JOBJ_PROTO]
.out:
    pop rdx
    ret

; Object.create(prototype, properties)
jsl_object_create:
    push rcx
    push rdx
    push rdi
    xor eax, eax
    call jsb_arg
    call jsl_proto_arg
    call jsobj_new
    call jsl_box_obj
    cmp ecx, 2
    jb .done
    mov rdx, [rdi + 8]
    mov rcx, JS_UNDEF
    cmp rdx, rcx
    je .done
    call jsl_define_all
.done:
    pop rdi
    pop rdx
    pop rcx
    ret

; Object.getPrototypeOf(value)
jsl_object_get_proto:
    xor eax, eax
    call jsl_arg_coercible
    call jsl_proto_of
    test rax, rax
    jz .null
    jmp jsl_box_obj
.null:
    mov rax, JS_NULL
    ret

; Object.setPrototypeOf(object, prototype)
jsl_object_set_proto:
    push rcx
    push rdx
    push rsi
    xor eax, eax
    call jsl_arg_coercible
    mov rdx, rax
    mov eax, 1
    call jsb_arg
    call jsl_proto_arg
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .done                       ; primitives stay as they are
    ; no cycles
    mov rsi, rax
.walk:
    test rsi, rsi
    jz .set
    cmp esi, edx
    je .cyclic
    mov rsi, [rsi + JOBJ_PROTO]
    jmp .walk
.set:
    mov ecx, edx
    mov [rcx + JOBJ_PROTO], rax
.done:
    mov rax, rdx
    pop rsi
    pop rdx
    pop rcx
    ret
.cyclic:
    lea rsi, [jsmsg_cyclic]
    xor edi, edi
    jmp js_throw_type

; Object.freeze(object): its own data properties become read-only (array
; elements stay writable for now)
jsl_object_freeze:
    push rcx
    push rdx
    push rsi
    xor eax, eax
    call jsb_arg
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .done
    mov edx, eax
    mov ecx, [rdx + JOBJ_COUNT]
    mov rsi, [rdx + JOBJ_PROPS]
.prop:
    test ecx, ecx
    jz .done
    cmp dword [rsi + JPE_KEY], 0
    je .next
    or byte [rsi + JPE_KEY + 4], JPA_FIXED
    bt qword [rsi + JPE_KEY], 34
    jc .next
    bts qword [rsi + JPE_KEY], 33
.next:
    add rsi, JPE_SIZE
    dec ecx
    jmp .prop
.done:
    pop rsi
    pop rdx
    pop rcx
    ret

; Object.seal / preventExtensions: the object as it is
jsl_object_identity:
    xor eax, eax
    jmp jsb_arg

; Object.defineProperty(object, key, descriptor)
jsl_object_define_property:
    push rcx
    push rdx
    xor eax, eax
    call jsl_arg_object
    push rax
    mov eax, 2
    call jsb_arg
    push rax
    mov eax, 1
    call jsb_arg
    mov rdx, rax
    pop rcx
    pop rax
    call jsl_define_one
    pop rdx
    pop rcx
    ret

; Object.defineProperties(object, properties)
jsl_object_define_properties:
    push rdx
    mov eax, 1
    call jsb_arg
    mov rdx, rax
    xor eax, eax
    call jsl_arg_object
    call jsl_define_all
    pop rdx
    ret

; jsl_define_all: RAX = object, RDX = { key: descriptor, ... }
jsl_define_all:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r9
    mov rsi, rax
    mov rax, rdx
    call js_own_keys
    mov rbx, rax
    xor r9d, r9d
.key:
    cmp r9d, [rbx + JARR_LEN]
    jae .done
    push rdx
    mov rax, rdx
    mov rdx, [rbx + JARR_ELEMS]
    mov rdx, [rdx + r9*8]
    push rdx
    call js_get_elem
    mov rcx, rax                    ; the descriptor
    pop rdx
    mov rax, rsi
    call jsl_define_one
    pop rdx
    inc r9d
    jmp .key
.done:
    pop r9
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsl_field: RSI = object value, RDX = atom -> RAX = its property (own or
; inherited), CF=1 (RAX = undefined) when there is none
jsl_field:
    push rbx
    mov eax, esi
    call jsobj_lookup
    jc .absent
    mov rax, rsi
    call js_get
    pop rbx
    clc
    ret
.absent:
    mov rax, JS_UNDEF
    pop rbx
    stc
    ret

; ------------------------------------------------------------------------------
; jsl_define_one: RAX = object (value), RDX = key, RCX = descriptor.
; What the descriptor leaves out keeps the property's current attributes (a
; new property: hidden and read-only, as in the standard)
; ------------------------------------------------------------------------------
jsl_define_one:
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
    mov r10, rax                    ; the object
    mov rsi, rcx                    ; the descriptor
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .bad_descriptor
    mov rax, rdx
    call jsl_key_atom
    mov r11, rax                    ; the key
    ; an array element
    mov ebx, r10d
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .named
    call jsstr_array_index
    jc .named
    mov rdx, [jsl_atom_value]
    call jsl_field
    mov rcx, rax
    mov rax, r11
    BOX rax, rdx, JS_STR_BITS
    mov rdx, rax
    mov rax, r10
    call js_put_elem
    jmp .done
.named:
    mov eax, r10d
    mov edx, r11d
    call jsobj_find_own
    mov r9d, JPA_HIDDEN | JPA_READONLY | JPA_FIXED
    jc .attributes
    mov r9, [rbx + JPE_KEY]
    shr r9, 32
    and r9d, JPA_HIDDEN | JPA_READONLY | JPA_FIXED
.attributes:
    mov rdx, [jsl_atom_enumerable]
    call jsl_field
    jc .writable
    or r9d, 1
    call js_truthy
    jnc .writable
    and r9d, ~1
.writable:
    mov rdx, [jsl_atom_writable]
    call jsl_field
    jc .configurable
    or r9d, 2
    call js_truthy
    jnc .configurable
    and r9d, ~2
.configurable:
    mov rdx, [jsl_atom_configurable]
    call jsl_field
    jc .accessor
    or r9d, JPA_FIXED
    call js_truthy
    jnc .accessor
    and r9d, ~JPA_FIXED
.accessor:
    xor edi, edi                    ; an accessor half seen
    mov edx, r11d
    mov eax, r9d
    and eax, JPA_HIDDEN | JPA_FIXED
    shl rax, 32
    or rdx, rax                     ; key | hidden
    push rdx
    mov rdx, [atom_get]
    call jsl_field
    pop rdx
    jc .setter
    mov edi, 1
    mov rcx, rax
    mov rax, r10
    mov eax, eax
    mov r8d, 1
    call jsobj_define_accessor
.setter:
    push rdx
    mov rdx, [atom_set]
    call jsl_field
    pop rdx
    jc .accessor_done
    mov edi, 1
    mov rcx, rax
    mov rax, r10
    mov eax, eax
    mov r8d, 2
    call jsobj_define_accessor
.accessor_done:
    test edi, edi
    jnz .done
    ; a data property
    mov rdx, [jsl_atom_value]
    call jsl_field
    jnc .define
    ; no value: an existing property keeps its own
    mov eax, r10d
    mov edx, r11d
    call jsobj_find_own
    mov rax, JS_UNDEF
    jc .define                      ; (a new one is undefined)
    mov rax, [rbx + JPE_KEY]
    btr rax, 32
    btr rax, 33
    btr rax, 35
    mov rdx, r9
    shl rdx, 32
    or rax, rdx
    mov [rbx + JPE_KEY], rax
    jmp .done
.define:
    mov rcx, rax
    mov edx, r11d
    mov rax, r9
    shl rax, 32
    or rdx, rax
    mov rax, r10
    mov eax, eax
    call jsobj_define
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
.bad_descriptor:
    lea rsi, [jsmsg_descriptor]
    xor edi, edi
    jmp js_throw_type

; Object.getOwnPropertyNames(object): enumerable keys, then hidden ones
jsl_object_own_names:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    xor eax, eax
    call jsl_arg_coercible
    mov rbx, rax
    call js_own_keys
    mov r8, rax
    mov rdx, rbx
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .done
    mov ebx, ebx
    mov ecx, [rbx + JOBJ_COUNT]
    mov rsi, [rbx + JOBJ_PROPS]
.prop:
    test ecx, ecx
    jz .length
    mov rax, [rsi + JPE_KEY]
    test eax, eax
    jz .next
    bt rax, 32
    jnc .next
    push rcx
    mov ecx, eax
    BOX rcx, rax, JS_STR_BITS
    mov rax, r8
    call jsarr_push
    pop rcx
.next:
    add rsi, JPE_SIZE
    dec ecx
    jmp .prop
.length:
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .done
    mov rcx, [atom_length]
    BOX rcx, rax, JS_STR_BITS
    mov rax, r8
    call jsarr_push
.done:
    mov rax, r8
    call jsl_box_obj
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Object.getOwnPropertyDescriptor(object, key)
jsl_object_own_descriptor:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    xor eax, eax
    call jsl_arg_coercible
    mov r10, rax
    mov eax, 1
    call jsb_arg
    call jsl_key_atom
    mov r9, rax
    mov rdx, r10
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .undefined
    mov ebx, r10d
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .named
    call jsstr_array_index
    jc .named
    cmp eax, [rbx + JARR_LEN]
    jae .undefined
    mov rdx, [rbx + JARR_ELEMS]
    mov rcx, [rdx + rax*8]
    mov rdx, JS_HOLE
    cmp rcx, rdx
    je .undefined
    xor r8d, r8d                    ; enumerable and writable
    jmp .data
.named:
    mov eax, r10d
    mov edx, r9d
    call jsobj_find_own
    jc .undefined
    mov r8, [rbx + JPE_KEY]
    shr r8, 32
    mov rcx, [rbx + JPE_VAL]
    bt r8d, 2
    jc .accessor
.data:
    call jsobj_new_plain
    mov rsi, rax
    mov rdx, [jsl_atom_value]
    call .put
    bt r8d, 1
    cmc
    call .put_bool_writable
    jmp .common
.accessor:
    call jsobj_new_plain
    mov rsi, rax
    mov rbx, rcx                    ; the accessor cell
    mov rcx, [rbx + JACC_GET]
    mov rdx, [atom_get]
    call .put
    mov rcx, [rbx + JACC_SET]
    mov rdx, [atom_set]
    call .put
.common:
    bt r8d, 0
    cmc
    call js_bool
    mov rcx, rax
    mov rdx, [jsl_atom_enumerable]
    call .put
    bt r8d, 3                       ; JPA_FIXED
    cmc
    call js_bool
    mov rcx, rax
    mov rdx, [jsl_atom_configurable]
    call .put
    mov rax, rsi
    call jsl_box_obj
    jmp .out
.undefined:
    mov rax, JS_UNDEF
.out:
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.put_bool_writable:
    call js_bool
    mov rcx, rax
    mov rdx, [jsl_atom_writable]
; .put: RSI = the descriptor, RDX = atom, RCX = value
.put:
    push rax
    mov rax, rsi
    call jsobj_define
    pop rax
    ret

; Object.fromEntries(array of [key, value])
jsl_object_from_entries:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    xor eax, eax
    call jsl_arg_coercible
    mov rdx, rax
    call jsb_this_array
    jc .not_iterable
    call jsobj_new_plain
    call jsl_box_obj
    mov rsi, rax
    xor r9d, r9d
.entry:
    cmp r9d, [rbx + JARR_LEN]
    jae .done
    mov edx, r9d
    call jsl_elem
    mov rdi, rax
    xor edx, edx                    ; 0
    call js_get_elem
    push rax
    mov rax, rdi
    mov rdx, 0x3FF0000000000000     ; 1
    call js_get_elem
    mov rcx, rax
    pop rdx
    mov rax, rsi
    call js_put_elem
    inc r9d
    jmp .entry
.done:
    mov rax, rsi
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.not_iterable:
    mov rax, rdx
    call js_to_string
    mov rdi, rax
    lea rsi, [jsmsg_not_iterable]
    jmp js_throw_type

; Object.is(a, b): === except that NaN is NaN and 0 is not -0
jsl_object_is:
    push rcx
    push rdx
    mov eax, 1
    call jsb_arg
    mov rdx, rax
    xor eax, eax
    call jsb_arg
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_SPECIAL
    jae .other
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_SPECIAL
    jae .other
    cmp rax, rdx
    je .yes
    movq xmm0, rax
    movq xmm1, rdx
    ucomisd xmm0, xmm0
    jnp .no
    ucomisd xmm1, xmm1
    jnp .no
.yes:
    stc
    jmp .out
.no:
    clc
    jmp .out
.other:
    call js_strict_equal
.out:
    call js_bool
    pop rdx
    pop rcx
    ret

; Object.prototype.isPrototypeOf(value)
jsl_object_is_prototype_of:
    push rcx
    push rdx
    xor eax, eax
    call jsb_arg
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .no
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .no
    mov eax, eax
    mov edx, edx
.walk:
    mov rax, [rax + JOBJ_PROTO]
    test rax, rax
    jz .no
    cmp rax, rdx
    jne .walk
    stc
    jmp .out
.no:
    clc
.out:
    call js_bool
    pop rdx
    pop rcx
    ret

; Object.prototype.propertyIsEnumerable(key)
jsl_object_property_enumerable:
    push rbx
    push rcx
    push rdx
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .no
    xor eax, eax
    call jsb_arg
    call jsl_key_atom
    mov ebx, edx
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .named
    push rax
    call jsstr_array_index
    jc .not_index
    add rsp, 8
    mov edx, eax
    call jsl_is_hole
    cmc
    jmp .out
.not_index:
    pop rax
.named:
    xchg eax, edx                   ; RAX = object, EDX = atom
    mov eax, eax
    call jsobj_find_own
    jc .no
    bt qword [rbx + JPE_KEY], 32
    cmc
    jmp .out
.no:
    clc
.out:
    call js_bool
    pop rdx
    pop rcx
    pop rbx
    ret

; ==============================================================================
; Number
; ==============================================================================

; jsl_is_integer: RAX = value -> CF=1 if it is a number without a fraction
jsl_is_integer:
    push rax
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jae .no
    mov rdx, rax
    btr rdx, 63
    push rax
    mov rax, JS_INF
    cmp rdx, rax
    pop rax
    jae .no
    movq xmm0, rax
    movq xmm5, rax
    call jsb_trunc
    ucomisd xmm0, xmm5
    jne .no
    pop rdx
    pop rax
    stc
    ret
.no:
    pop rdx
    pop rax
    clc
    ret

; Number.isInteger(value)
jsl_number_is_integer:
    xor eax, eax
    call jsb_arg
    call jsl_is_integer
    jmp js_bool

; Number.isSafeInteger(value)
jsl_number_is_safe_integer:
    xor eax, eax
    call jsb_arg
    call jsl_is_integer
    jnc .out
    btr rax, 63
    movq xmm0, rax
    ucomisd xmm0, [jsb_two53]       ; CF=1 below 2^53
.out:
    jmp js_bool

; Number.isFinite(value)
jsl_number_is_finite:
    xor eax, eax
    call jsb_arg
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jae .no
    btr rax, 63
    mov rdx, JS_INF
    cmp rax, rdx                    ; CF=1 below Infinity
    jmp .out
.no:
    clc
.out:
    pop rdx
    jmp js_bool

; Number.isNaN(value)
jsl_number_is_nan:
    xor eax, eax
    call jsb_arg
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jae .no
    movq xmm0, rax
    ucomisd xmm0, xmm0
    jnp .no
    stc
    jmp .out
.no:
    clc
.out:
    pop rdx
    jmp js_bool

; ==============================================================================
; Math
; ==============================================================================

; hypot(...values)
jsl_math_hypot:
    push rcx
    push rdx
    push rdi
    push rsi
    xorpd xmm3, xmm3                ; the sum of squares
    xor esi, esi                    ; bit 0: Infinity seen, bit 1: NaN seen
.arg:
    test ecx, ecx
    jz .done
    mov rax, [rdi]
    call js_to_number
    mov rdx, rax
    btr rdx, 63
    push rax
    mov rax, JS_INF
    cmp rdx, rax
    pop rax
    jb .finite
    ja .nan
    or esi, 1
    jmp .next
.nan:
    or esi, 2
    jmp .next
.finite:
    movq xmm0, rax
    mulsd xmm0, xmm0
    addsd xmm3, xmm0
.next:
    add rdi, 8
    dec ecx
    jmp .arg
.done:
    mov rax, JS_INF
    test esi, 1
    jnz .out
    mov rax, JS_NAN
    test esi, 2
    jnz .out
    sqrtsd xmm0, xmm3
    movq rax, xmm0
.out:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ret

; jsl_x87_expm1: ST0 = x -> ST0 = e^x - 1 (exact near 0)
jsl_x87_expm1:
    fldl2e
    fmulp st1, st0                  ; t = x * log2(e)
    fld st0
    fabs
    fld1
    fcomip st0, st1                 ; 1 >= |t| ?
    fstp st0
    jb .large                       ; (NaN too)
    f2xm1
    ret
.large:
    call jsb_x87_exp2
    fld1
    fsubp st1, st0
    ret

; MATH_X87_ABS: the argument's sign in RDX bit 63, |x| on the x87 and in [rsp]
%macro MATH_X87_ABS 0
    push rdx
    MATH_ARG
    mov rdx, rax
    btr rax, 63
    sub rsp, 8
    mov [rsp], rax
    fld qword [rsp]
%endmacro
%macro MATH_X87_SIGNED_END 0
    fstp qword [rsp]
    mov rax, [rsp]
    add rsp, 8
    bt rdx, 63
    jnc %%plus
    bts rax, 63
%%plus:
    pop rdx
    ret
%endmacro

jsl_math_log10:
    MATH_X87_BEGIN
    fldlg2
    fxch st1
    fyl2x
    MATH_X87_END

jsl_math_log2:
    MATH_X87_BEGIN
    fld1
    fxch st1
    fyl2x
    MATH_X87_END

; log1p(x) = ln(1 + x), exact near 0
jsl_math_log1p:
    MATH_X87_BEGIN
    fld st0
    fabs
    fld qword [jsl_log1p_limit]
    fcomip st0, st1
    fstp st0
    jb .large
    fldln2
    fxch st1
    fyl2xp1
    MATH_X87_END
.large:
    fld1
    faddp st1, st0
    fldln2
    fxch st1
    fyl2x
    MATH_X87_END

jsl_math_expm1:
    MATH_X87_BEGIN
    call jsl_x87_expm1
    MATH_X87_END

; cbrt(x): 2^(log2|x| / 3), one Newton step, the sign of x
jsl_math_cbrt:
    MATH_X87_ABS
    fstp st0
    mov rax, [rsp]
    test rax, rax
    jz .same
    push rcx
    mov rcx, JS_INF
    cmp rax, rcx
    pop rcx
    jae .same
    fld1
    fld qword [rsp]
    fyl2x                           ; log2 |x|
    fdiv qword [jsl_three]
    call jsb_x87_exp2               ; y
    fld st0
    fmul st0, st0                   ; y^2
    fdivr qword [rsp]               ; |x| / y^2
    fxch st1
    fadd st0, st0                   ; 2y
    faddp st1, st0
    fdiv qword [jsl_three]          ; (2y + |x|/y^2) / 3
    MATH_X87_SIGNED_END
.same:
    fld qword [rsp]
    MATH_X87_SIGNED_END

; sinh(x) = (E + E / (E + 1)) / 2 with E = expm1(|x|), the sign of x
jsl_math_sinh:
    MATH_X87_ABS
    push rcx
    mov rax, [rsp + 8]
    mov rcx, 0x4090000000000000     ; 1024: overflows anyway
    cmp rax, rcx
    pop rcx
    jbe .compute
    fld st0
    fmul st0, st0                   ; Infinity (NaN stays NaN)
    fstp st1
    MATH_X87_SIGNED_END
.compute:
    call jsl_x87_expm1
    fld st0
    fld1
    fadd st0, st1                   ; E + 1
    fdivp st1, st0                  ; E / (E + 1)
    faddp st1, st0
    fmul qword [jsb_half]
    MATH_X87_SIGNED_END

; cosh(x) = (e^|x| + e^-|x|) / 2
jsl_math_cosh:
    MATH_X87_ABS
    xor edx, edx                    ; always positive
    call jsl_x87_expm1
    fld1
    faddp st1, st0                  ; e^|x|
    fld1
    fdiv st0, st1                   ; e^-|x|
    faddp st1, st0
    fmul qword [jsb_half]
    MATH_X87_SIGNED_END

; tanh(x) = E / (E + 2) with E = expm1(2|x|), the sign of x (1 beyond 22)
jsl_math_tanh:
    MATH_X87_ABS
    push rcx
    mov rax, [rsp + 8]
    mov rcx, 0x4036000000000000     ; 22
    cmp rax, rcx
    jbe .compute
    mov rcx, JS_INF
    cmp rax, rcx
    ja .done                        ; NaN
    fstp st0
    fld1
    jmp .done
.compute:
    fadd st0, st0
    call jsl_x87_expm1
    fld st0
    fld1
    fadd st0, st0
    faddp st1, st0                  ; E + 2
    fdivp st1, st0
.done:
    pop rcx
    MATH_X87_SIGNED_END

; asin(x) = atan2(x, sqrt((1 - x)(1 + x)))
jsl_math_asin:
    MATH_X87_BEGIN
    call jsl_x87_root_one_minus_square
    fpatan
    MATH_X87_END

; acos(x) = atan2(sqrt((1 - x)(1 + x)), x)
jsl_math_acos:
    MATH_X87_BEGIN
    call jsl_x87_root_one_minus_square
    fxch st1
    fpatan
    MATH_X87_END

; jsl_x87_root_one_minus_square: ST0 = x -> ST0 = sqrt(1 - x^2), ST1 = x
jsl_x87_root_one_minus_square:
    fld1
    fsub st0, st1                   ; 1 - x
    fld1
    fadd st0, st2                   ; 1 + x
    fmulp st1, st0
    fsqrt
    ret

; fround(x): to single precision and back
jsl_math_fround:
    MATH_ARG
    cvtsd2ss xmm0, xmm0
    cvtss2sd xmm0, xmm0
    movq rax, xmm0
    ret

; clz32(x)
jsl_math_clz32:
    xor eax, eax
    call jsb_arg
    call js_to_int32
    push rcx
    mov ecx, 32
    test eax, eax
    jz .count
    bsr eax, eax
    mov ecx, 31
    sub ecx, eax
.count:
    mov eax, ecx
    pop rcx
    jmp jsb_from_int

; imul(a, b)
jsl_math_imul:
    push rdx
    xor eax, eax
    call jsb_arg
    call js_to_int32
    mov edx, eax
    mov eax, 1
    call jsb_arg
    call js_to_int32
    imul eax, edx
    movsxd rax, eax
    pop rdx
    jmp jsb_from_int

; ==============================================================================
; JSON
; ==============================================================================

; ------------------------------------------------------------------------------
; JSON.stringify(value, replacer, space). While it runs: R15 = the text,
; R14 = the replacer function or 0, R13 = the indent string or 0, R12 = the
; objects being written (cycles), R11D = the depth
; ------------------------------------------------------------------------------
jsl_json_stringify:
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
    push r14
    push r15
    xor eax, eax
    call jsb_arg
    mov rbx, rax                    ; the value
    ; the replacer (a function; allow-lists come later)
    xor r14d, r14d
    mov eax, 1
    call jsb_arg
    call js_is_callable
    jnc .space
    mov r14, rax
.space:
    ; the indent: a count of spaces (10 at most) or a string's first 10 bytes
    xor r13d, r13d
    mov eax, 2
    call jsb_arg
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_STRING
    je .gap_string
    cmp edx, JS_TAG_SPECIAL
    jae .gap_done
    call jsb_integer
    test rax, rax
    jle .gap_done
    cmp rax, 10
    jbe .spaces
    mov eax, 10
.spaces:
    lea rsi, [jsl_ten_spaces]
    mov ecx, eax
    call jsstr_new
    mov r13, rax
    jmp .gap_done
.gap_string:
    mov eax, eax
    mov ecx, [rax + JSTR_LEN]
    test ecx, ecx
    jz .gap_done
    cmp ecx, 10
    jbe .gap_copy
    mov ecx, 10
.gap_copy:
    lea rsi, [rax + JSTR_DATA]
    call jsstr_new
    mov r13, rax
.gap_done:
    xor ecx, ecx
    call jsarr_new
    mov r12, rax
    xor r11d, r11d
    call jslb_new
    ; the holder { "": value } a replacer gets as `this`
    mov rsi, JS_UNDEF
    test r14, r14
    jz .write
    call jsobj_new_plain
    mov edx, [atom_empty]
    mov rcx, rbx
    call jsobj_define
    call jsl_box_obj
    mov rsi, rax
.write:
    mov rax, rbx
    mov rdx, [atom_empty]
    BOX rdx, rcx, JS_STR_BITS
    call jsl_json_value
    mov rax, JS_UNDEF
    jc .out
    call jslb_value
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
    pop rbx
    ret

; jsl_json_value: RAX = value, RDX = its key (a string value), RSI = the
; object holding it -> its JSON appended; CF=1 when it has none (undefined,
; functions), nothing written then
jsl_json_value:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rbx, rax
    ; value.toJSON(key)
    mov rcx, rbx
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .replacer
    push rdx
    mov rax, rbx
    mov rdx, [jsl_atom_tojson]
    call js_get
    pop rdx
    call js_is_callable
    jnc .replacer
    push rdx
    mov rdi, rsp
    mov rdx, rbx
    mov ecx, 1
    call js_call
    pop rdx
    mov rbx, rax
.replacer:
    test r14, r14
    jz .kind
    push rbx
    push rdx
    mov rdi, rsp                    ; (key, value)
    mov rax, r14
    mov rdx, rsi
    mov ecx, 2
    call js_call
    pop rdx
    add rsp, 8
    mov rbx, rax
.kind:
    mov rcx, rbx
    shr rcx, 48
    cmp ecx, JS_TAG_STRING
    je .string
    cmp ecx, JS_TAG_OBJECT
    je .object
    cmp ecx, JS_TAG_SPECIAL
    je .special
    ; a number: finite ones as text, the rest as null
    mov rax, rbx
    btr rax, 63
    mov rcx, JS_INF
    cmp rax, rcx
    jae .null
    mov rax, rbx
    call js_to_string
    call jslb_str
    jmp .written
.special:
    cmp ebx, 1
    je .null
    jb .nothing                     ; undefined
    lea rsi, [jsl_str_true]
    cmp ebx, 3
    je .word
    lea rsi, [jsl_str_false]
    cmp ebx, 2
    je .word
    jmp .nothing
.null:
    lea rsi, [jsl_str_null]
.word:
    call jslb_cstr
    jmp .written
.string:
    mov eax, ebx
    call jsl_json_quote
    jmp .written
.object:
    mov rax, rbx
    call js_is_callable
    jc .nothing
    ; a cycle?
    mov rdi, [r12 + JARR_ELEMS]
    mov ecx, [r12 + JARR_LEN]
.seen:
    test ecx, ecx
    jz .fresh
    cmp [rdi], rbx
    je .circular
    add rdi, 8
    dec ecx
    jmp .seen
.fresh:
    mov rcx, rbx
    mov rax, r12
    call jsarr_push
    mov eax, ebx
    cmp byte [rax + JH_KIND], JK_ARRAY
    je .array
    call jsl_json_object
    jmp .object_done
.array:
    call jsl_json_array
.object_done:
    dec dword [r12 + JARR_LEN]
.written:
    clc
    jmp .out
.nothing:
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.circular:
    lea rsi, [jsmsg_circular]
    xor edi, edi
    jmp js_throw_type

; jsl_json_newline: a line break and the indent for depth R11D (with an indent)
jsl_json_newline:
    test r13, r13
    jz .ret
    push rax
    push rcx
    mov al, 10
    call jslb_byte
    mov ecx, r11d
.level:
    test ecx, ecx
    jz .done
    mov rax, r13
    call jslb_str
    dec ecx
    jmp .level
.done:
    pop rcx
    pop rax
.ret:
    ret

; jsl_json_array: RBX = array value -> [ ... ] (holes and undefined as null)
jsl_json_array:
    push rax
    push rbx
    push rdx
    push rsi
    push r8
    push r9
    mov r8, rbx
    mov ebx, ebx
    mov al, '['
    call jslb_byte
    cmp dword [rbx + JARR_LEN], 0
    je .close
    inc r11d
    xor r9d, r9d
.item:
    cmp r9d, [rbx + JARR_LEN]
    jae .end
    test r9d, r9d
    jz .first
    mov al, ','
    call jslb_byte
.first:
    call jsl_json_newline
    mov eax, r9d
    call jsb_from_int
    call js_to_string
    mov rdx, rax
    BOX rdx, rax, JS_STR_BITS       ; the key
    push rdx
    mov edx, r9d
    call jsl_elem
    pop rdx
    mov rsi, r8
    call jsl_json_value
    jnc .next
    lea rsi, [jsl_str_null]
    call jslb_cstr
.next:
    inc r9d
    jmp .item
.end:
    dec r11d
    call jsl_json_newline
.close:
    mov al, ']'
    call jslb_byte
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rbx
    pop rax
    ret

; jsl_json_object: RBX = object value -> { "key": value, ... } (own
; enumerable properties; those without a JSON form are left out)
jsl_json_object:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r8, rbx
    mov al, '{'
    call jslb_byte
    mov rax, r8
    call js_own_keys
    mov rdi, rax
    xor r9d, r9d                    ; the key index
    xor r10d, r10d                  ; any written
    inc r11d
.key:
    cmp r9d, [rdi + JARR_LEN]
    jae .end
    mov ecx, [r15 + JSLB_LEN]       ; to undo a property without JSON
    test r10d, r10d
    jz .first
    mov al, ','
    call jslb_byte
.first:
    call jsl_json_newline
    mov rdx, [rdi + JARR_ELEMS]
    mov rdx, [rdx + r9*8]
    mov eax, edx
    call jsl_json_quote
    mov al, ':'
    call jslb_byte
    test r13, r13
    jz .value
    mov al, ' '
    call jslb_byte
.value:
    mov rax, r8
    push rdx
    call js_get_elem
    pop rdx
    mov rsi, r8
    call jsl_json_value
    jc .undo
    mov r10d, 1
    jmp .next
.undo:
    mov [r15 + JSLB_LEN], ecx
.next:
    inc r9d
    jmp .key
.end:
    dec r11d
    test r10d, r10d
    jz .close
    call jsl_json_newline
.close:
    mov al, '}'
    call jslb_byte
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsl_json_quote: RAX = string -> "text" with JSON escapes
jsl_json_quote:
    push rax
    push rcx
    push rdx
    push rsi
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    mov al, '"'
    call jslb_byte
.char:
    test ecx, ecx
    jz .end
    lodsb
    dec ecx
    cmp al, '"'
    je .escape
    cmp al, '\'
    je .escape
    cmp al, 0x20
    jb .control
    call jslb_byte
    jmp .char
.escape:
    push rax
    mov al, '\'
    call jslb_byte
    pop rax
    call jslb_byte
    jmp .char
.control:
    mov dl, 'n'
    cmp al, 10
    je .short
    mov dl, 'r'
    cmp al, 13
    je .short
    mov dl, 't'
    cmp al, 9
    je .short
    mov dl, 'b'
    cmp al, 8
    je .short
    mov dl, 'f'
    cmp al, 12
    je .short
    mov dl, al                      ; \u00XX
    mov al, '\'
    call jslb_byte
    mov al, 'u'
    call jslb_byte
    mov al, '0'
    call jslb_byte
    call jslb_byte
    mov al, dl
    shr al, 4
    call .hex
    mov al, dl
    and al, 15
    call .hex
    jmp .char
.short:
    mov al, '\'
    call jslb_byte
    mov al, dl
    call jslb_byte
    jmp .char
.hex:
    add al, '0'
    cmp al, '9'
    jbe .digit
    add al, 'a' - '9' - 1
.digit:
    jmp jslb_byte
.end:
    mov al, '"'
    call jslb_byte
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; JSON.parse(text). While it runs: RSI = the text, R9 = its end, R15 = scratch
; for strings, R11D = the depth. (A reviver function comes later.)
; ------------------------------------------------------------------------------
JSL_JSON_MAX_DEPTH      equ 512

jsl_json_parse:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r11
    push r15
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov rbx, rax
    lea rsi, [rax + JSTR_DATA]
    mov r9d, [rax + JSTR_LEN]
    add r9, rsi
    call jslb_new
    xor r11d, r11d
    call jsl_jp_value
    call jsl_jp_space
    cmp rsi, r9
    jb jsl_jp_unexpected
    pop r15
    pop r11
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

jsl_jp_unexpected:
    movzx eax, byte [rsi]
    call jsstr_char
    mov rdi, rax
    mov edx, JE_SYNTAX
    lea rsi, [jsmsg_json]
    jmp js_throw
jsl_jp_end:
    mov edx, JE_SYNTAX
    lea rsi, [jsmsg_json_end]
    xor edi, edi
    jmp js_throw

; jsl_jp_space: RSI past spaces, tabs and line breaks
jsl_jp_space:
    cmp rsi, r9
    jae .done
    cmp byte [rsi], ' '
    je .skip
    cmp byte [rsi], 10
    je .skip
    cmp byte [rsi], 13
    je .skip
    cmp byte [rsi], 9
    jne .done
.skip:
    inc rsi
    jmp jsl_jp_space
.done:
    ret

; jsl_jp_deeper: one level deeper (arrays, objects)
jsl_jp_deeper:
    inc r11d
    cmp r11d, JSL_JSON_MAX_DEPTH
    ja .too_deep
    ret
.too_deep:
    mov edx, JE_RANGE
    lea rsi, [jsmsg_too_deep]
    xor edi, edi
    jmp js_throw

; jsl_jp_value: -> RAX = the value at RSI
jsl_jp_value:
    call jsl_jp_space
    cmp rsi, r9
    jae jsl_jp_end
    movzx eax, byte [rsi]
    cmp al, '{'
    je jsl_jp_object
    cmp al, '['
    je jsl_jp_array
    cmp al, '"'
    je .string
    cmp al, 't'
    je .true
    cmp al, 'f'
    je .false
    cmp al, 'n'
    je .null
    cmp al, '-'
    je jsl_jp_number
    sub al, '0'
    cmp al, 9
    jbe jsl_jp_number
    jmp jsl_jp_unexpected
.string:
    call jsl_jp_string
    jmp jsb_box_string
.true:
    push rdi
    lea rdi, [jsl_str_true]
    call jsl_jp_word
    pop rdi
    mov rax, JS_TRUE
    ret
.false:
    push rdi
    lea rdi, [jsl_str_false]
    call jsl_jp_word
    pop rdi
    mov rax, JS_FALSE
    ret
.null:
    push rdi
    lea rdi, [jsl_str_null]
    call jsl_jp_word
    pop rdi
    mov rax, JS_NULL
    ret

; jsl_jp_word: RDI = the word expected at RSI -> RSI past it
jsl_jp_word:
    mov al, [rdi]
    test al, al
    jz .done
    cmp rsi, r9
    jae jsl_jp_end
    cmp [rsi], al
    jne jsl_jp_unexpected
    inc rsi
    inc rdi
    jmp jsl_jp_word
.done:
    ret

; jsl_jp_number: -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?
jsl_jp_number:
    push rbx
    push rcx
    push rdx
    push rdi
    mov rdi, rsi                    ; the start
    cmp byte [rsi], '-'
    jne .int
    inc rsi
.int:
    cmp rsi, r9
    jae jsl_jp_end
    cmp byte [rsi], '0'
    jne .int_digits
    inc rsi
    jmp .fraction
.int_digits:
    call .digits_required
.fraction:
    cmp rsi, r9
    jae .scan
    cmp byte [rsi], '.'
    jne .exponent
    inc rsi
    call .digits_required
.exponent:
    cmp rsi, r9
    jae .scan
    mov al, [rsi]
    or al, 0x20
    cmp al, 'e'
    jne .scan
    inc rsi
    cmp rsi, r9
    jae jsl_jp_end
    cmp byte [rsi], '+'
    je .exponent_sign
    cmp byte [rsi], '-'
    jne .exponent_digits
.exponent_sign:
    inc rsi
.exponent_digits:
    call .digits_required
.scan:
    mov rbx, rsi                    ; the end
    mov rsi, rdi
    cmp byte [rsi], '-'
    jne .unsigned
    inc rsi
.unsigned:
    mov rcx, rbx
    sub rcx, rsi
    xor edx, edx
    push rdi
    call jsnum_scan
    pop rdi
    mov rsi, rbx
    cmp byte [rdi], '-'
    jne .done
    bts rax, 63
.done:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
; .digits_required: one digit or more at RSI
.digits_required:
    cmp rsi, r9
    jae jsl_jp_end
    mov al, [rsi]
    sub al, '0'
    cmp al, 9
    ja jsl_jp_unexpected
.digits:
    cmp rsi, r9
    jae .digits_done
    mov al, [rsi]
    sub al, '0'
    cmp al, 9
    ja .digits_done
    inc rsi
    jmp .digits
.digits_done:
    ret

; jsl_jp_string: RSI at the opening quote -> RAX = the string (heap)
jsl_jp_string:
    push rcx
    push rdx
    push rdi
    inc rsi
    mov dword [r15 + JSLB_LEN], 0
.char:
    cmp rsi, r9
    jae jsl_jp_end
    lodsb
    cmp al, '"'
    je .end
    cmp al, '\'
    je .escape
    cmp al, 0x20
    jb .bad
    call jslb_byte
    jmp .char
.escape:
    cmp rsi, r9
    jae jsl_jp_end
    lodsb
    cmp al, '"'
    je .put
    cmp al, '\'
    je .put
    cmp al, '/'
    je .put
    mov dl, 8
    cmp al, 'b'
    je .put_dl
    mov dl, 12
    cmp al, 'f'
    je .put_dl
    mov dl, 10
    cmp al, 'n'
    je .put_dl
    mov dl, 13
    cmp al, 'r'
    je .put_dl
    mov dl, 9
    cmp al, 't'
    je .put_dl
    cmp al, 'u'
    je .unicode
.bad:
    dec rsi
    jmp jsl_jp_unexpected
.put_dl:
    mov al, dl
.put:
    call jslb_byte
    jmp .char
.unicode:
    call .hex4
    ; a high surrogate and then a low one: one code point
    mov edx, eax
    and edx, 0xFC00
    cmp edx, 0xD800
    jne .code
    lea rdx, [rsi + 6]
    cmp rdx, r9
    ja .code
    cmp word [rsi], '\u'
    jne .code
    push rax
    add rsi, 2
    call .hex4
    mov edx, eax
    and edx, 0xFC00
    cmp edx, 0xDC00
    jne .not_pair
    pop rdx
    sub edx, 0xD800
    shl edx, 10
    sub eax, 0xDC00
    add eax, edx
    add eax, 0x10000
    jmp .code
.not_pair:
    pop rdx
    push rax
    mov eax, edx
    call .utf8
    pop rax
.code:
    call .utf8
    jmp .char
.end:
    push rsi
    mov rsi, [r15 + JSLB_DATA]
    mov ecx, [r15 + JSLB_LEN]
    call jsstr_new
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ret
; .utf8: EAX = code point appended
.utf8:
    push rsi
    push rdi
    push rcx
    sub rsp, 8
    mov rdi, rsp
    call jslex_put_utf8
    mov rcx, rdi
    mov rsi, rsp
    sub rcx, rsi
    call jslb_bytes
    add rsp, 8
    pop rcx
    pop rdi
    pop rsi
    ret
; .hex4: four hex digits at RSI -> EAX
.hex4:
    push rcx
    push rdx
    lea rdx, [rsi + 4]
    cmp rdx, r9
    ja jsl_jp_end
    xor edx, edx
    mov ecx, 4
.hex:
    movzx eax, byte [rsi]
    sub al, '0'
    cmp al, 9
    jbe .nibble
    movzx eax, byte [rsi]
    or al, 0x20
    sub al, 'a'
    cmp al, 5
    ja jsl_jp_unexpected
    add al, 10
.nibble:
    shl edx, 4
    or edx, eax
    inc rsi
    dec ecx
    jnz .hex
    mov eax, edx
    pop rdx
    pop rcx
    ret

; jsl_jp_array: [ value, ... ]
jsl_jp_array:
    push rbx
    push rcx
    call jsl_jp_deeper
    inc rsi
    xor ecx, ecx
    call jsarr_new
    mov rbx, rax
    call jsl_jp_space
    cmp rsi, r9
    jae jsl_jp_end
    cmp byte [rsi], ']'
    je .close
.item:
    call jsl_jp_value
    mov rcx, rax
    mov rax, rbx
    call jsarr_push
    call jsl_jp_space
    cmp rsi, r9
    jae jsl_jp_end
    lodsb
    cmp al, ','
    je .item
    cmp al, ']'
    je .done
    dec rsi
    jmp jsl_jp_unexpected
.close:
    inc rsi
.done:
    dec r11d
    mov rax, rbx
    call jsl_box_obj
    pop rcx
    pop rbx
    ret

; jsl_jp_object: { "key": value, ... }
jsl_jp_object:
    push rbx
    push rcx
    push rdx
    call jsl_jp_deeper
    inc rsi
    call jsobj_new_plain
    call jsl_box_obj
    mov rbx, rax
    call jsl_jp_space
    cmp rsi, r9
    jae jsl_jp_end
    cmp byte [rsi], '}'
    je .close
.member:
    call jsl_jp_space
    cmp rsi, r9
    jae jsl_jp_end
    cmp byte [rsi], '"'
    jne jsl_jp_unexpected
    call jsl_jp_string
    call jsb_box_string
    push rax                        ; the key
    call jsl_jp_space
    cmp rsi, r9
    jae jsl_jp_end
    cmp byte [rsi], ':'
    jne jsl_jp_unexpected
    inc rsi
    call jsl_jp_value
    mov rcx, rax
    pop rdx
    mov rax, rbx
    call js_put_elem
    call jsl_jp_space
    cmp rsi, r9
    jae jsl_jp_end
    lodsb
    cmp al, ','
    je .member
    cmp al, '}'
    je .done
    dec rsi
    jmp jsl_jp_unexpected
.close:
    inc rsi
.done:
    dec r11d
    mov rax, rbx
    pop rdx
    pop rcx
    pop rbx
    ret
