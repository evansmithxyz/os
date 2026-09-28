; ==============================================================================
; Antigravity OS - JavaScript built-ins
; ------------------------------------------------------------------------------
; js_init_builtins makes the global object and the standard objects step 1
; needs: Object, Function, Array, String, Number, Boolean prototypes, Math,
; console, parseInt/parseFloat/isNaN/isFinite. Native functions follow the
; convention in vm.asm (RDI = arguments, ECX = count, RDX = this, R8D = 1
; under `new`, result in RAX, other registers preserved).
; ==============================================================================

[bits 64]

; JSNATIVE object, "name", routine, arity: a method made by js_init_builtins
; on the object whose pointer is in the qword `object`
%macro JSNATIVE 4
    [section .rodata]
    dq %1, %3
    db %4
    db %%e - %%s
    %%s: db %2
    %%e:
    __SECT__
%endmacro

; JSCONST object, "name", double: a read-only number property
%macro JSCONST 3
    [section .rodata]
    dq %1, %3
    db %%e - %%s
    %%s: db %2
    %%e:
    __SECT__
%endmacro

section .bss
alignb 8
jsb_math:               resq 1
jsb_console:            resq 1
jsb_object_ctor:        resq 1
jsb_array_ctor:         resq 1
jsb_string_ctor:        resq 1
jsb_number_ctor:        resq 1
jsb_boolean_ctor:       resq 1
jsb_rng:                resq 1

section .rodata
jsb_natives:
JSNATIVE js_global, "parseInt", jsb_parse_int, 2
JSNATIVE js_global, "parseFloat", jsb_parse_float, 1
JSNATIVE js_global, "isNaN", jsb_is_nan, 1
JSNATIVE js_global, "isFinite", jsb_is_finite, 1
JSNATIVE jsb_object_ctor, "keys", jsb_object_keys, 1
JSNATIVE jsb_array_ctor, "isArray", jsb_array_is_array, 1
JSNATIVE jsb_string_ctor, "fromCharCode", jsb_string_from_char_code, 1
JSNATIVE js_object_proto, "toString", jsb_object_to_string, 0
JSNATIVE js_object_proto, "valueOf", jsb_object_value_of, 0
JSNATIVE js_object_proto, "hasOwnProperty", jsb_object_has_own, 1
JSNATIVE js_function_proto, "toString", jsb_function_to_string, 0
JSNATIVE js_error_protos, "toString", jsb_error_to_string, 0
JSNATIVE js_array_proto, "push", jsb_array_push, 1
JSNATIVE js_array_proto, "pop", jsb_array_pop, 0
JSNATIVE js_array_proto, "join", jsb_array_join, 1
JSNATIVE js_array_proto, "toString", jsb_array_to_string, 0
JSNATIVE js_array_proto, "indexOf", jsb_array_index_of, 1
JSNATIVE js_array_proto, "slice", jsb_array_slice, 2
JSNATIVE js_string_proto, "toString", jsb_string_value_of, 0
JSNATIVE js_string_proto, "valueOf", jsb_string_value_of, 0
JSNATIVE js_string_proto, "charAt", jsb_string_char_at, 1
JSNATIVE js_string_proto, "charCodeAt", jsb_string_char_code_at, 1
JSNATIVE js_string_proto, "indexOf", jsb_string_index_of, 1
JSNATIVE js_string_proto, "slice", jsb_string_slice, 2
JSNATIVE js_string_proto, "substring", jsb_string_substring, 2
JSNATIVE js_string_proto, "toUpperCase", jsb_string_upper, 0
JSNATIVE js_string_proto, "toLowerCase", jsb_string_lower, 0
JSNATIVE js_string_proto, "trim", jsb_string_trim, 0
JSNATIVE js_number_proto, "toString", jsb_number_to_string, 1
JSNATIVE js_number_proto, "valueOf", jsb_number_value_of, 0
JSNATIVE js_number_proto, "toFixed", jsb_number_to_fixed, 1
JSNATIVE js_boolean_proto, "toString", jsb_boolean_to_string, 0
JSNATIVE js_boolean_proto, "valueOf", jsb_boolean_value_of, 0
JSNATIVE jsb_math, "abs", jsb_math_abs, 1
JSNATIVE jsb_math, "floor", jsb_math_floor, 1
JSNATIVE jsb_math, "ceil", jsb_math_ceil, 1
JSNATIVE jsb_math, "round", jsb_math_round, 1
JSNATIVE jsb_math, "trunc", jsb_math_trunc, 1
JSNATIVE jsb_math, "sign", jsb_math_sign, 1
JSNATIVE jsb_math, "min", jsb_math_min, 2
JSNATIVE jsb_math, "max", jsb_math_max, 2
JSNATIVE jsb_math, "sqrt", jsb_math_sqrt, 1
JSNATIVE jsb_math, "pow", jsb_math_pow, 2
JSNATIVE jsb_math, "random", jsb_math_random, 0
JSNATIVE jsb_math, "sin", jsb_math_sin, 1
JSNATIVE jsb_math, "cos", jsb_math_cos, 1
JSNATIVE jsb_math, "tan", jsb_math_tan, 1
JSNATIVE jsb_math, "atan", jsb_math_atan, 1
JSNATIVE jsb_math, "atan2", jsb_math_atan2, 2
JSNATIVE jsb_math, "exp", jsb_math_exp, 1
JSNATIVE jsb_math, "log", jsb_math_log, 1
JSNATIVE jsb_console, "log", jsb_console_log, 0
JSNATIVE jsb_console, "info", jsb_console_log, 0
JSNATIVE jsb_console, "warn", jsb_console_log, 0
JSNATIVE jsb_console, "error", jsb_console_log, 0
JSNATIVE jsb_console, "debug", jsb_console_log, 0
    dq 0

jsb_constants:
JSCONST jsb_math, "PI", 3.141592653589793
JSCONST jsb_math, "E", 2.718281828459045
JSCONST jsb_math, "LN2", 0.6931471805599453
JSCONST jsb_math, "LN10", 2.302585092994046
JSCONST jsb_math, "LOG2E", 1.4426950408889634
JSCONST jsb_math, "LOG10E", 0.4342944819032518
JSCONST jsb_math, "SQRT2", 1.4142135623730951
JSCONST jsb_math, "SQRT1_2", 0.7071067811865476
JSCONST jsb_number_ctor, "MAX_SAFE_INTEGER", 9007199254740991.0
JSCONST jsb_number_ctor, "MIN_SAFE_INTEGER", -9007199254740991.0
JSCONST jsb_number_ctor, "EPSILON", 2.220446049250313e-16
JSCONST jsb_number_ctor, "MAX_VALUE", 1.7976931348623157e308
JSCONST jsb_number_ctor, "MIN_VALUE", 5e-324
    dq 0

; constructors: variable, routine, arity, prototype variable, name
%macro JSCTOR 5
    dq %1, %2, %4
    db %3
    db %%e - %%s
    %%s: db %5
    %%e:
%endmacro
jsb_error_ctors:
    dq jsb_error_ctor_0, jsb_error_ctor_1, jsb_error_ctor_2, jsb_error_ctor_3, jsb_error_ctor_4
jsb_ctors:
JSCTOR jsb_object_ctor, jsb_object, 1, js_object_proto, "Object"
JSCTOR jsb_array_ctor, jsb_array, 1, js_array_proto, "Array"
JSCTOR jsb_string_ctor, jsb_string, 1, js_string_proto, "String"
JSCTOR jsb_number_ctor, jsb_number, 1, js_number_proto, "Number"
JSCTOR jsb_boolean_ctor, jsb_boolean, 1, js_boolean_proto, "Boolean"
    dq 0

jsb_name_global_this:   db "globalThis", 0
jsb_name_math:          db "Math", 0
jsb_name_console:       db "console", 0
jsb_name_nan:           db "NaN", 0
jsb_name_infinity:      db "Infinity", 0
jsb_name_undefined:     db "undefined", 0
jsb_name_nan_number:    db "NaN", 0
jsb_name_pos_inf:       db "POSITIVE_INFINITY", 0
jsb_name_neg_inf:       db "NEGATIVE_INFINITY", 0
jsb_class_object:       db "[object Object]", 0
jsb_class_array:        db "[object Array]", 0
jsb_class_function:     db "[object Function]", 0
jsb_class_arguments:    db "[object Arguments]", 0
jsb_class_math:         db "[object Math]", 0
jsb_class_undefined:    db "[object Undefined]", 0
jsb_class_null:         db "[object Null]", 0
jsb_class_string:       db "[object String]", 0
jsb_class_number:       db "[object Number]", 0
jsb_class_boolean:      db "[object Boolean]", 0
jsb_fn_prefix:          db "function ", 0
jsb_fn_native:          db "() { [native code] }", 0
jsb_comma:              db ",", 0
jsmsg_not_number:       db "Number.prototype.% requires that 'this' be a Number", 0
jsmsg_radix:            db "toString() radix must be between 2 and 36", 0
jsmsg_fixed:            db "toFixed() digits argument must be between 0 and 100", 0
jsmsg_this_undefined:   db "String.prototype.% called on null or undefined", 0
jsb_name_to_string:     db "toString", 0
jsb_name_to_fixed:      db "toFixed", 0
align 8
jsb_half:               dq 0.5
jsb_two53:              dq 9007199254740992.0
jsb_1e21:               dq 1.0e21

section .text

; ------------------------------------------------------------------------------
; js_init_builtins: global object, prototypes, constructors, natives
; ------------------------------------------------------------------------------
js_init_builtins:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    xor eax, eax
    call jsobj_new
    mov [js_object_proto], rax
    mov rbx, rax
    mov rax, rbx
    call jsobj_new
    mov [js_function_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [js_array_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [js_string_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [js_number_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [js_boolean_proto], rax
    mov rax, rbx
    call jsobj_new
    mov dword [rax + JOBJ_CLASS], JC_GLOBAL
    mov [js_global], rax
    mov rax, rbx
    call jsobj_new
    mov dword [rax + JOBJ_CLASS], JC_MATH
    mov [jsb_math], rax
    mov rax, rbx
    call jsobj_new
    mov dword [rax + JOBJ_CLASS], JC_CONSOLE
    mov [jsb_console], rax
    ; constructors
    lea r8, [jsb_ctors]
    call jsb_define_ctors
    call jsb_init_errors
    ; global values
    mov rax, [js_global]
    mov rcx, rax
    BOX rcx, rdx, JS_OBJ_BITS
    lea rsi, [jsb_name_global_this]
    mov edx, 1
    call jsb_define
    mov rcx, [jsb_math]
    BOX rcx, rdx, JS_OBJ_BITS
    lea rsi, [jsb_name_math]
    mov edx, 1
    call jsb_define
    mov rcx, [jsb_console]
    BOX rcx, rdx, JS_OBJ_BITS
    lea rsi, [jsb_name_console]
    mov edx, 1
    call jsb_define
    mov rcx, JS_NAN
    lea rsi, [jsb_name_nan]
    mov edx, 3
    call jsb_define
    mov rcx, JS_INF
    lea rsi, [jsb_name_infinity]
    call jsb_define
    mov rcx, JS_UNDEF
    lea rsi, [jsb_name_undefined]
    call jsb_define
    mov rax, [jsb_number_ctor]
    mov rcx, JS_NAN
    lea rsi, [jsb_name_nan_number]
    call jsb_define
    mov rcx, JS_INF
    lea rsi, [jsb_name_pos_inf]
    call jsb_define
    bts rcx, 63
    lea rsi, [jsb_name_neg_inf]
    call jsb_define
    ; methods
    lea r8, [jsb_natives]
    call jsb_define_natives
    call jsy_init
    call jscol_init
    call jsre_init
    call jsdate_init
    call jsl_init
    call jsa_init
    call jsn_init
    ; constants
    lea r8, [jsb_constants]
.constant:
    mov rdi, [r8]
    test rdi, rdi
    jz .constants_done
    movzx ecx, byte [r8 + 16]
    lea rsi, [r8 + 17]
    call jsstr_atom
    mov edx, eax
    bts rdx, 32                     ; hidden
    bts rdx, 33                     ; read-only
    mov rcx, [r8 + 8]
    mov rax, [rdi]
    call jsobj_define
    movzx ecx, byte [r8 + 16]
    lea r8, [r8 + rcx + 17]
    jmp .constant
.constants_done:
    ; Math.random seed
    lea rdi, [jsb_rng]
    mov ecx, 8
    call rand_bytes
    or qword [jsb_rng], 1
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsb_init_errors: Error, TypeError, RangeError, SyntaxError, ReferenceError:
; constructors on the global object, prototypes chained to Error.prototype
; (each with its name and an empty message)
jsb_init_errors:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    xor r8d, r8d
.kind:
    mov rax, [js_object_proto]
    test r8d, r8d
    jz .proto
    mov rax, [js_error_protos]
.proto:
    call jsobj_new
    mov rdi, rax                    ; the prototype
    lea rbx, [js_error_protos]
    mov [rbx + r8*8], rdi
    lea rsi, [jsvm_kind_names]
    mov rsi, [rsi + r8*8]
    call jsstr_from_cstr
    mov rbx, rax                    ; the name
    mov rcx, rbx
    BOX rcx, rdx, JS_STR_BITS
    mov rax, rdi
    mov rdx, [atom_name]
    call jsobj_define_hidden
    mov rcx, [atom_empty]
    BOX rcx, rdx, JS_STR_BITS
    mov rdx, [atom_message]
    call jsobj_define_hidden
    ; the constructor
    lea rax, [jsb_error_ctors]
    mov rax, [rax + r8*8]
    mov ecx, 1
    mov rdx, rbx
    call jsfn_native
    mov rsi, rax
    mov rcx, rsi
    BOX rcx, rdx, JS_OBJ_BITS
    mov rax, [js_global]
    mov rdx, rbx
    call jsobj_define_hidden
    mov rcx, rdi
    BOX rcx, rdx, JS_OBJ_BITS
    mov rax, rsi
    mov rdx, [atom_prototype]
    call jsobj_define_hidden
    mov rcx, rsi
    BOX rcx, rdx, JS_OBJ_BITS
    mov rax, rdi
    mov rdx, [atom_constructor]
    call jsobj_define_hidden
    inc r8d
    cmp r8d, JE_COUNT
    jb .kind
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Error(message) and friends; under `new` from a derived class's super()
; (R8D = 2) they fill in `this` instead of making a new object
jsb_error_ctor_0:
    push r9
    mov r9d, 0
    jmp jsb_error_common
jsb_error_ctor_1:
    push r9
    mov r9d, 1
    jmp jsb_error_common
jsb_error_ctor_2:
    push r9
    mov r9d, 2
    jmp jsb_error_common
jsb_error_ctor_3:
    push r9
    mov r9d, 3
    jmp jsb_error_common
jsb_error_ctor_4:
    push r9
    mov r9d, 4
jsb_error_common:
    push rbx
    push rcx
    push rdx
    push rdi
    xor ebx, ebx                    ; the message (0 = none)
    test ecx, ecx
    jz .have
    mov rax, [rdi]
    mov rcx, JS_UNDEF
    cmp rax, rcx
    je .have
    call js_to_string
    mov rbx, rax
.have:
    cmp r8d, 2
    jne .new
    mov rax, rdx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .new
    mov eax, eax
    mov dword [rax + JOBJ_CLASS], JC_ERROR
    mov rdi, rbx
    mov edx, r9d
    call js_error_fill
    BOX rax, rcx, JS_OBJ_BITS
    jmp .out
.new:
    mov rax, rbx
    mov edx, r9d
    call js_make_error
.out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop r9
    ret

; Error.prototype.toString: "Name: message"
jsb_error_to_string:
    push rbx
    push rcx
    push rdx
    push rsi
    mov rbx, rdx                    ; this
    call jsout_save
    mov rax, rbx
    mov rdx, [atom_name]
    call js_get
    mov rcx, JS_UNDEF
    cmp rax, rcx
    jne .name
    lea rsi, [jsvm_kind_names]
    mov rsi, [rsi]
    call jsout_cstr
    jmp .message
.name:
    call js_to_string
    call jsout_str
.message:
    mov rax, rbx
    mov rdx, [atom_message]
    call js_get
    mov rcx, JS_UNDEF
    cmp rax, rcx
    je .done
    call js_to_string
    cmp dword [rax + JSTR_LEN], 0
    je .done
    push rax
    mov al, ':'
    call jsout_byte
    mov al, ' '
    call jsout_byte
    pop rax
    call jsout_str
.done:
    call jsout_take
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsb_define_ctors: R8 = a JSCTOR table -> each constructor made, defined on
; the global object (hidden) and linked with its prototype object
jsb_define_ctors:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
.ctor:
    mov rdi, [r8]
    test rdi, rdi
    jz .done
    movzx ecx, byte [r8 + 25]
    lea rsi, [r8 + 26]
    call jsstr_atom
    mov rdx, rax                    ; name
    mov rax, [r8 + 8]
    movzx ecx, byte [r8 + 24]
    call jsfn_native
    mov [rdi], rax
    ; global.Name = ctor
    mov rcx, rax
    BOX rcx, rsi, JS_OBJ_BITS
    push rax
    mov rax, [js_global]
    call jsobj_define_hidden
    pop rax
    ; ctor.prototype = proto, proto.constructor = ctor
    mov rsi, [r8 + 16]
    mov rsi, [rsi]                  ; prototype object
    push rcx
    mov rcx, rsi
    BOX rcx, rdx, JS_OBJ_BITS
    mov rdx, [atom_prototype]
    call jsobj_define_hidden
    pop rcx
    mov rax, rsi
    mov rdx, [atom_constructor]
    call jsobj_define_hidden
    movzx ecx, byte [r8 + 25]
    lea r8, [r8 + rcx + 26]
    jmp .ctor
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsb_define_natives: R8 = a JSNATIVE table -> its functions defined (hidden)
jsb_define_natives:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
.native:
    mov rdi, [r8]
    test rdi, rdi
    jz .done
    movzx ecx, byte [r8 + 17]
    lea rsi, [r8 + 18]
    call jsstr_atom
    mov rdx, rax
    mov rax, [r8 + 8]
    movzx ecx, byte [r8 + 16]
    call jsfn_native
    mov rcx, rax
    BOX rcx, rsi, JS_OBJ_BITS
    mov rax, [rdi]
    call jsobj_define_hidden
    movzx ecx, byte [r8 + 17]
    lea r8, [r8 + rcx + 18]
    jmp .native
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsb_define: RAX = object, RSI = name, RCX = value, EDX = 1 hidden (+2 read-only)
jsb_define:
    push rax
    push rdx
    push r8
    mov r8, rdx
    push rax
    call jsstr_from_cstr
    mov edx, eax
    pop rax
    test r8d, 1
    jz .ro
    bts rdx, 32
.ro:
    test r8d, 2
    jz .define
    bts rdx, 33
.define:
    call jsobj_define
    pop r8
    pop rdx
    pop rax
    ret

; ==============================================================================
; Helpers for natives
; ==============================================================================

; jsb_arg: EAX = index -> RAX = that argument or undefined (RDI, ECX = args)
jsb_arg:
    cmp eax, ecx
    jae .undefined
    mov rax, [rdi + rax*8]
    ret
.undefined:
    mov rax, JS_UNDEF
    ret

; jsb_arg_number: EAX = index -> RAX = ToNumber(argument)
jsb_arg_number:
    call jsb_arg
    jmp js_to_number

; jsb_arg_integer: EAX = index -> RAX = ToIntegerOrInfinity(argument) as a
; signed 64-bit integer clamped to +-2^53 (NaN and undefined give 0); CF=1 when
; the argument was undefined
jsb_arg_integer:
    call jsb_arg
    push rdx
    mov rdx, JS_UNDEF
    cmp rax, rdx
    je .undefined
    call js_to_number
    call jsb_integer
    pop rdx
    clc
    ret
.undefined:
    xor eax, eax
    pop rdx
    stc
    ret

; jsb_integer: RAX = number bits -> RAX = truncated integer clamped to +-2^53
jsb_integer:
    movq xmm0, rax
    ucomisd xmm0, xmm0
    jp .zero                        ; NaN
    movsd xmm1, [jsb_two53]
    ucomisd xmm0, xmm1
    jae .max
    xorpd xmm2, xmm2
    subsd xmm2, xmm1
    ucomisd xmm0, xmm2
    jbe .min
    cvttsd2si rax, xmm0
    ret
.max:
    mov rax, 9007199254740992
    ret
.min:
    mov rax, -9007199254740992
    ret
.zero:
    xor eax, eax
    ret

; jsb_relative: RAX = relative index (integer), RDX = length -> RAX clamped to
; [0, length] (negative counts from the end)
jsb_relative:
    test rax, rax
    jns .positive
    add rax, rdx
    jns .done
    xor eax, eax
    ret
.positive:
    cmp rax, rdx
    jbe .done
    mov rax, rdx
.done:
    ret

; jsb_from_int: RAX = signed integer -> RAX = number
jsb_from_int:
    cvtsi2sd xmm0, rax
    movq rax, xmm0
    ret

; jsb_box_string: RAX = heap string -> RAX = string value
jsb_box_string:
    push rdx
    BOX rax, rdx, JS_STR_BITS
    pop rdx
    ret

; jsb_cstr: RSI = NUL-terminated text -> RAX = string value
jsb_cstr:
    call jsstr_from_cstr
    jmp jsb_box_string

; jsb_this_string: RDX = this -> RAX = ToString(this) (TypeError for
; undefined/null); RSI = method name for the message
jsb_this_string:
    mov rax, rdx
    push rdx
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jne .ok
    cmp eax, 1
    jbe .bad
.ok:
    pop rdx
    jmp js_to_string
.bad:
    pop rdx
    call jsstr_from_cstr
    mov rdi, rax
    lea rsi, [jsmsg_this_undefined]
    jmp js_throw_type

; jsb_this_array: RDX = this -> RBX = array object, CF=1 if it is not an array
jsb_this_array:
    mov rbx, rdx
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    jne .no
    mov ebx, edx
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .no
    clc
    ret
.no:
    stc
    ret

; ==============================================================================
; Global functions and constructors
; ==============================================================================

; parseInt(string, radix)
jsb_parse_int:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    mov eax, 1
    call jsb_arg
    call js_to_int32
    mov ebx, eax                    ; radix
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    call jsnum_skip_space
    xor r8d, r8d                    ; sign bit
    test rcx, rcx
    jz .nan
    cmp byte [rsi], '+'
    je .sign
    cmp byte [rsi], '-'
    jne .radix
    mov r8, 0x8000000000000000
.sign:
    inc rsi
    dec rcx
.radix:
    mov r9d, 1                      ; strip 0x
    test ebx, ebx
    jz .default
    cmp ebx, 2
    jl .nan
    cmp ebx, 36
    jg .nan
    cmp ebx, 16
    je .prefix
    xor r9d, r9d
    jmp .prefix
.default:
    mov ebx, 10
.prefix:
    test r9d, r9d
    jz .digits
    cmp rcx, 2
    jb .digits
    cmp byte [rsi], '0'
    jne .digits
    mov al, [rsi + 1]
    or al, 0x20
    cmp al, 'x'
    jne .digits
    add rsi, 2
    sub rcx, 2
    mov ebx, 16
.digits:
    call jsnum_parse_radix
    test rcx, rcx
    jz .nan
    or rax, r8
    jmp .out
.nan:
    mov rax, JS_NAN
.out:
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; parseFloat(string)
jsb_parse_float:
    push rcx
    push rdx
    push rsi
    push r8
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    call jsnum_skip_space
    xor r8d, r8d
    test rcx, rcx
    jz .nan
    cmp byte [rsi], '+'
    je .sign
    cmp byte [rsi], '-'
    jne .value
    mov r8, 0x8000000000000000
.sign:
    inc rsi
    dec rcx
.value:
    cmp rcx, 8
    jb .scan
    mov rax, "Infinity"
    cmp [rsi], rax
    jne .scan
    mov rax, JS_INF
    jmp .signed
.scan:
    xor edx, edx
    call jsnum_scan
    test rcx, rcx
    jz .nan
.signed:
    or rax, r8
    jmp .out
.nan:
    mov rax, JS_NAN
.out:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    ret

; isNaN(value)
jsb_is_nan:
    xor eax, eax
    call jsb_arg_number
    movq xmm0, rax
    ucomisd xmm0, xmm0
    setp al
    movzx eax, al
    push rdx
    mov rdx, JS_FALSE
    add rax, rdx
    pop rdx
    ret

; isFinite(value)
jsb_is_finite:
    xor eax, eax
    call jsb_arg_number
    push rdx
    btr rax, 63
    mov rdx, JS_INF
    cmp rax, rdx
    setb al
    movzx eax, al
    mov rdx, JS_FALSE
    add rax, rdx
    pop rdx
    ret

; String(value)
jsb_string:
    test ecx, ecx
    jz .empty
    xor eax, eax
    call jsb_arg
    push rcx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_SYMBOL
    pop rcx
    je .symbol
    call js_to_string
    jmp jsb_box_string
.symbol:
    mov eax, eax                    ; String(symbol): "Symbol(description)"
    jmp jsy_describe
.empty:
    mov rax, [atom_empty]
    jmp jsb_box_string

; Number(value)
jsb_number:
    test ecx, ecx
    jz .zero
    xor eax, eax
    jmp jsb_arg_number
.zero:
    xor eax, eax
    ret

; Boolean(value)
jsb_boolean:
    xor eax, eax
    call jsb_arg
    call js_truthy
    jmp js_bool

; Object(value)
jsb_object:
    xor eax, eax
    call jsb_arg
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    je .out
    call jsobj_new_plain
    BOX rax, rdx, JS_OBJ_BITS
.out:
    pop rdx
    ret

; Array(...items) / Array(length)
jsb_array:
    push rbx
    push rcx
    push rdx
    push rdi
    cmp ecx, 1
    jne .items
    mov rax, [rdi]
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jae .items
    call js_array_length_value      ; RangeError unless a valid length
    mov ecx, eax
    push rcx
    xor ecx, ecx
    call jsarr_new
    pop rcx
    call jsarr_set_length
    jmp .box
.items:
    mov ebx, ecx
    call jsarr_new
.copy:
    test ebx, ebx
    jz .box
    mov rcx, [rdi]
    call jsarr_push
    add rdi, 8
    dec ebx
    jmp .copy
.box:
    BOX rax, rdx, JS_OBJ_BITS
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; Object.keys(object)
jsb_object_keys:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    xor eax, eax
    call jsb_arg
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jne .ok
    cmp eax, 1
    ja .ok
    lea rsi, [jsmsg_to_object]
    xor edi, edi
    jmp js_throw_type
.ok:
    ; own keys only: the for-in list of an object without its prototypes
    mov rbx, rax
    cmp edx, JS_TAG_OBJECT
    jne .all
    mov edi, ebx
    push qword [rdi + JOBJ_PROTO]
    mov qword [rdi + JOBJ_PROTO], 0
    call js_forin_keys
    pop qword [rdi + JOBJ_PROTO]
    jmp .box
.all:
    call js_forin_keys
.box:
    BOX rax, rdx, JS_OBJ_BITS
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Array.isArray(value)
jsb_array_is_array:
    xor eax, eax
    call jsb_arg
    push rbx
    push rdx
    mov rdx, rax
    call jsb_this_array
    cmc
    call js_bool
    pop rdx
    pop rbx
    ret

; ==============================================================================
; Object.prototype, Function.prototype
; ==============================================================================

; Object.prototype.toString
jsb_object_to_string:
    push rbx
    push rdx
    push rsi
    lea rsi, [jsb_class_object]
    mov rax, rdx
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    je .object
    lea rsi, [jsb_class_string]
    cmp edx, JS_TAG_STRING
    je .out
    lea rsi, [jsb_class_number]
    cmp edx, JS_TAG_SPECIAL
    jb .out
    lea rsi, [jsb_class_undefined]
    test eax, eax
    jz .out
    lea rsi, [jsb_class_null]
    cmp eax, 1
    je .out
    lea rsi, [jsb_class_boolean]
    jmp .out
.object:
    mov ebx, eax
    lea rsi, [jsb_class_array]
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .not_array
    cmp dword [rbx + JOBJ_CLASS], JC_ARGUMENTS
    jne .out
    lea rsi, [jsb_class_arguments]
    jmp .out
.not_array:
    lea rsi, [jsb_class_function]
    cmp byte [rbx + JH_KIND], JK_FUNC
    je .out
    cmp byte [rbx + JH_KIND], JK_NATIVE
    je .out
    lea rsi, [jsb_class_math]
    cmp dword [rbx + JOBJ_CLASS], JC_MATH
    je .out
    lea rsi, [jsb_class_object]
.out:
    call jsb_cstr
    pop rsi
    pop rdx
    pop rbx
    ret

; Object.prototype.valueOf
jsb_object_value_of:
    mov rax, rdx
    ret

; Object.prototype.hasOwnProperty(key)
jsb_object_has_own:
    push rbx
    push rcx
    push rdx
    push rdi
    mov rbx, rdx                    ; this
    xor eax, eax
    call jsb_arg
    mov rdx, rax                    ; key
    mov rcx, rbx
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .no
    mov ebx, ebx
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .named
    call js_index
    jc .named
    cmp eax, [rbx + JARR_LEN]
    jae .no
    mov rcx, [rbx + JARR_ELEMS]
    mov rcx, [rcx + rax*8]
    mov rax, JS_HOLE
    cmp rcx, rax
    je .no
    jmp .yes
.named:
    mov rax, rdx
    call js_to_key
    mov rdx, rax
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .find
    cmp rdx, [atom_length]
    je .yes
.find:
    mov rax, rbx
    push rbx
    call jsobj_find_own
    pop rbx
    jc .no
.yes:
    stc
    jmp .out
.no:
    clc
.out:
    call js_bool
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; Function.prototype.toString: function name() { [native code] }
jsb_function_to_string:
    push rdx
    push rsi
    call jsout_save
    lea rsi, [jsb_fn_prefix]
    call jsout_cstr
    mov rax, rdx
    mov rdx, [atom_name]
    call js_get
    mov eax, eax
    call jsout_str
    lea rsi, [jsb_fn_native]
    call jsout_cstr
    call jsout_take
    pop rsi
    pop rdx
    ret

; jsout_save / jsout_take: build a string in the output buffer (the text
; already in it is kept aside) -> jsout_take: RAX = the built string value
jsout_save:
    push rax
    mov eax, [jsout_len]
    mov [jsb_out_mark], eax
    pop rax
    ret

jsout_take:
    push rcx
    push rsi
    mov ecx, [jsout_len]
    mov eax, [jsb_out_mark]
    sub ecx, eax
    lea rsi, [jsout_buf]
    add rsi, rax
    call jsstr_new
    mov ecx, [jsb_out_mark]
    mov [jsout_len], ecx
    pop rsi
    pop rcx
    jmp jsb_box_string

section .bss
jsb_out_mark:           resd 1
section .text

; ==============================================================================
; Array.prototype
; ==============================================================================

; push(...items) -> new length
jsb_array_push:
    push rbx
    push rcx
    push rdi
    call jsb_this_array
    jc .not_array
    mov rax, rbx
.item:
    test ecx, ecx
    jz .done
    push rcx
    mov rcx, [rdi]
    call jsarr_push
    pop rcx
    add rdi, 8
    dec ecx
    jmp .item
.done:
    mov eax, [rbx + JARR_LEN]
    call jsb_from_int
    jmp .out
.not_array:
    mov rax, JS_UNDEF
.out:
    pop rdi
    pop rcx
    pop rbx
    ret

; pop() -> last element
jsb_array_pop:
    push rbx
    push rcx
    call jsb_this_array
    mov rax, JS_UNDEF
    jc .out
    mov ecx, [rbx + JARR_LEN]
    test ecx, ecx
    jz .out
    dec ecx
    mov [rbx + JARR_LEN], ecx
    mov rax, [rbx + JARR_ELEMS]
    mov rax, [rax + rcx*8]
    mov rcx, JS_HOLE
    cmp rax, rcx
    jne .out
    mov rax, JS_UNDEF
.out:
    pop rcx
    pop rbx
    ret

; toString() == join()
jsb_array_to_string:
    push rcx
    xor ecx, ecx
    call jsb_array_join
    pop rcx
    ret

; join(separator)
jsb_array_join:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    call jsb_this_array
    jc .empty
    ; separator
    mov rax, JS_UNDEF
    test ecx, ecx
    jz .default_sep
    mov rax, [rdi]
.default_sep:
    mov rdx, JS_UNDEF
    cmp rax, rdx
    jne .sep
    lea rsi, [jsb_comma]
    call jsstr_from_cstr
    jmp .have_sep
.sep:
    call js_to_string
.have_sep:
    mov r10, rax                    ; separator string
    ; an array that contains itself joins as ""
    test byte [rbx + JH_FLAGS], 0x80
    jnz .empty
    or byte [rbx + JH_FLAGS], 0x80
    ; convert every element, then copy them into one string
    mov ecx, [rbx + JARR_LEN]
    call jsarr_new
    mov r8, rax                     ; the pieces
    xor r9d, r9d                    ; total length
    xor edx, edx
.piece:
    cmp edx, [rbx + JARR_LEN]
    jae .pieces_done
    mov rax, [rbx + JARR_ELEMS]
    mov rax, [rax + rdx*8]
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_SPECIAL
    jne .convert
    cmp eax, 2
    je .convert
    cmp eax, 3
    je .convert
    mov rax, [atom_empty]           ; undefined, null, holes
    jmp .have_piece
.convert:
    call js_to_string
.have_piece:
    add r9d, [rax + JSTR_LEN]
    mov rcx, rax
    mov rax, r8
    call jsarr_push
    inc edx
    jmp .piece
.pieces_done:
    and byte [rbx + JH_FLAGS], 0x7F
    mov ecx, [r8 + JARR_LEN]
    test ecx, ecx
    jz .empty
    dec ecx
    imul ecx, [r10 + JSTR_LEN]
    add ecx, r9d
    call jsstr_alloc
    mov r9, rax
    lea rdi, [rax + JSTR_DATA]
    xor edx, edx
.copy:
    cmp edx, [r8 + JARR_LEN]
    jae .done
    test edx, edx
    jz .no_sep
    lea rsi, [r10 + JSTR_DATA]
    mov ecx, [r10 + JSTR_LEN]
    rep movsb
.no_sep:
    mov rax, [r8 + JARR_ELEMS]
    mov rax, [rax + rdx*8]
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    rep movsb
    inc edx
    jmp .copy
.done:
    mov rax, r9
    jmp .box
.empty:
    mov rax, [atom_empty]
.box:
    call jsb_box_string
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; indexOf(value, fromIndex)
jsb_array_index_of:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    call jsb_this_array
    jc .none
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
    mov r8, rax                     ; the value
.loop:
    mov edx, [rbx + JARR_LEN]
    cmp r9, rdx
    jge .none
    mov rax, [rbx + JARR_ELEMS]
    mov rax, [rax + r9*8]
    mov rdx, r8
    call js_strict_equal
    jc .found
    inc r9
    jmp .loop
.found:
    mov rax, r9
    call jsb_from_int
    jmp .out
.none:
    mov rax, -1
    call jsb_from_int
.out:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; slice(start, end)
jsb_array_slice:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    call jsb_this_array
    jc .empty
    mov edx, [rbx + JARR_LEN]
    xor eax, eax
    call jsb_arg_integer
    call jsb_relative
    mov r8, rax                     ; start
    mov eax, 1
    call jsb_arg_integer
    jnc .end
    mov rax, rdx
.end:
    call jsb_relative
    mov r9, rax                     ; end
    mov ecx, r9d
    sub ecx, r8d
    jg .size
    xor ecx, ecx
.size:
    call jsarr_new
.copy:
    cmp r8, r9
    jge .box
    mov rcx, [rbx + JARR_ELEMS]
    mov rcx, [rcx + r8*8]
    call jsarr_push
    inc r8
    jmp .copy
.empty:
    xor ecx, ecx
    call jsarr_new
.box:
    BOX rax, rdx, JS_OBJ_BITS
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ==============================================================================
; String.prototype, String.fromCharCode
; ==============================================================================

; valueOf / toString
jsb_string_value_of:
    push rsi
    lea rsi, [jsb_name_to_string]
    call jsb_this_string
    pop rsi
    jmp jsb_box_string

; charAt(index)
jsb_string_char_at:
    push rbx
    push rsi
    lea rsi, [jsb_name_to_string]
    call jsb_this_string
    mov rbx, rax
    xor eax, eax
    call jsb_arg_integer
    test rax, rax
    js .empty
    mov esi, [rbx + JSTR_LEN]
    cmp rax, rsi
    jae .empty
    movzx eax, byte [rbx + JSTR_DATA + rax]
    call jsstr_char
    jmp .out
.empty:
    mov rax, [atom_empty]
.out:
    call jsb_box_string
    pop rsi
    pop rbx
    ret

; charCodeAt(index) (the byte value; strings are UTF-8 bytes for now)
jsb_string_char_code_at:
    push rbx
    push rsi
    lea rsi, [jsb_name_to_string]
    call jsb_this_string
    mov rbx, rax
    xor eax, eax
    call jsb_arg_integer
    test rax, rax
    js .nan
    mov esi, [rbx + JSTR_LEN]
    cmp rax, rsi
    jae .nan
    movzx eax, byte [rbx + JSTR_DATA + rax]
    call jsb_from_int
    jmp .out
.nan:
    mov rax, JS_NAN
.out:
    pop rsi
    pop rbx
    ret

; indexOf(search, position)
jsb_string_index_of:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    lea rsi, [jsb_name_to_string]
    call jsb_this_string
    mov rbx, rax                    ; haystack
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov r8, rax                     ; needle
    mov eax, 1
    call jsb_arg_integer
    mov edx, [rbx + JSTR_LEN]
    test rax, rax
    jns .clamp
    xor eax, eax
.clamp:
    cmp rax, rdx
    jbe .start
    mov rax, rdx
.start:
    mov r9, rax
    cmp dword [r8 + JSTR_LEN], 0
    je .found                       ; "" is found at the start position
.try:
    mov eax, [rbx + JSTR_LEN]
    sub eax, [r8 + JSTR_LEN]
    movsxd rax, eax
    cmp r9, rax
    jg .none
    lea rsi, [rbx + JSTR_DATA + r9]
    lea rdi, [r8 + JSTR_DATA]
    mov ecx, [r8 + JSTR_LEN]
    repe cmpsb
    je .found
    inc r9
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
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; slice(start, end)
jsb_string_slice:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    lea rsi, [jsb_name_to_string]
    call jsb_this_string
    mov rbx, rax
    mov edx, [rbx + JSTR_LEN]
    xor eax, eax
    call jsb_arg_integer
    call jsb_relative
    mov r8, rax
    mov eax, 1
    call jsb_arg_integer
    jnc .end
    mov rax, rdx
.end:
    call jsb_relative
    jmp jsb_substring_out

; substring(start, end)
jsb_string_substring:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    lea rsi, [jsb_name_to_string]
    call jsb_this_string
    mov rbx, rax
    mov edx, [rbx + JSTR_LEN]
    xor eax, eax
    call jsb_arg_integer
    call .clamp
    mov r8, rax
    mov eax, 1
    call jsb_arg_integer
    jnc .end
    mov rax, rdx
.end:
    call .clamp
    cmp rax, r8
    jge jsb_substring_out
    xchg rax, r8
    jmp jsb_substring_out
.clamp:
    test rax, rax
    jns .upper
    xor eax, eax
.upper:
    cmp rax, rdx
    jle .clamped
    mov rax, rdx
.clamped:
    ret

; jsb_substring_out: RBX = string, R8 = start, RAX = end (clamped) -> the
; piece; pops what slice/substring pushed
jsb_substring_out:
    mov rcx, rax
    sub rcx, r8
    jg .piece
    mov rax, [atom_empty]
    jmp .out
.piece:
    lea rsi, [rbx + JSTR_DATA + r8]
    call jsstr_new
.out:
    call jsb_box_string
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; toUpperCase() / toLowerCase() (ASCII letters)
jsb_string_upper:
    push rbx
    mov bl, 'a'
    jmp jsb_string_case
jsb_string_lower:
    push rbx
    mov bl, 'A'
jsb_string_case:
    push rcx
    push rsi
    push rdi
    lea rsi, [jsb_name_to_string]
    call jsb_this_string
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    call jsstr_new
    lea rdi, [rax + JSTR_DATA]
.loop:
    test ecx, ecx
    jz .done
    mov bh, [rdi]
    sub bh, bl
    cmp bh, 25
    ja .next
    xor byte [rdi], 0x20
.next:
    inc rdi
    dec ecx
    jmp .loop
.done:
    call jsb_box_string
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; trim()
jsb_string_trim:
    push rcx
    push rsi
    lea rsi, [jsb_name_to_string]
    call jsb_this_string
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    call jsnum_skip_space
    call jsnum_trim_end
    call jsstr_new
    call jsb_box_string
    pop rsi
    pop rcx
    ret

; String.fromCharCode(...codes)
jsb_string_from_char_code:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rdi
    mov ebx, ecx
    lea ecx, [rcx*4]
    call jsstr_alloc                ; scratch, 4 bytes per code at most
    mov rsi, rax
    lea rdi, [rax + JSTR_DATA]
.code:
    test ebx, ebx
    jz .done
    mov rax, [r8]
    call js_to_number
    call jsnum_to_int32
    and eax, 0xFFFF
    call jslex_put_utf8
    add r8, 8
    dec ebx
    jmp .code
.done:
    lea rcx, [rsi + JSTR_DATA]
    sub rdi, rcx
    mov ecx, edi
    add rsi, JSTR_DATA
    call jsstr_new
    call jsb_box_string
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ==============================================================================
; Number.prototype, Boolean.prototype
; ==============================================================================

; jsb_this_number: RDX = this, RSI = method name -> RAX = the number
jsb_this_number:
    mov rax, rdx
    push rdx
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    pop rdx
    jae .bad
    ret
.bad:
    call jsstr_from_cstr
    mov rdi, rax
    lea rsi, [jsmsg_not_number]
    jmp js_throw_type

; valueOf
jsb_number_value_of:
    push rsi
    lea rsi, [jsb_name_to_string]
    call jsb_this_number
    pop rsi
    ret

; toString(radix)
jsb_number_to_string:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    lea rsi, [jsb_name_to_string]
    call jsb_this_number
    mov r8, rax                     ; the number
    xor eax, eax
    call jsb_arg_integer
    jc .decimal
    cmp rax, 10
    je .decimal
    cmp rax, 2
    jl .bad_radix
    cmp rax, 36
    jg .bad_radix
    mov ebx, eax
    ; NaN / Infinity / non-integers too large: decimal text
    mov rax, r8
    btr rax, 63
    mov rdx, 0x7FF0000000000000
    cmp rax, rdx
    jae .decimal
    call jsout_save
    bt r8, 63
    jnc .positive
    mov al, '-'
    call jsout_byte
.positive:
    movq xmm0, r8
    mov rax, 0x7FFFFFFFFFFFFFFF
    movq xmm1, rax
    andpd xmm0, xmm1                ; |x|
    movsd xmm1, [jsb_two53]
    ucomisd xmm0, xmm1
    jae .big
    cvttsd2si rax, xmm0             ; integer part
    cvtsi2sd xmm2, rax
    subsd xmm0, xmm2                ; fraction
    call .digits
    ; fraction digits (at most 52)
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    je .take
    mov al, '.'
    call jsout_byte
    cvtsi2sd xmm3, rbx
    mov ecx, 52
.fraction:
    mulsd xmm0, xmm3
    cvttsd2si rax, xmm0
    cvtsi2sd xmm2, rax
    subsd xmm0, xmm2
    call jsnum_digit_char
    call jsout_byte
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    je .take
    dec ecx
    jnz .fraction
.take:
    call jsout_take
    jmp .out
.big:
    call jsout_take                 ; drop the sign; decimal instead
.decimal:
    mov rax, r8
    call js_to_string
    call jsb_box_string
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.bad_radix:
    mov edx, JE_RANGE
    lea rsi, [jsmsg_radix]
    xor edi, edi
    jmp js_throw

; .digits: RAX = unsigned integer, EBX = radix -> its digits appended
.digits:
    push rax
    push rcx
    push rdx
    xor ecx, ecx
.div:
    xor edx, edx
    div rbx
    push rdx
    inc ecx
    test rax, rax
    jnz .div
.emit:
    pop rax
    call jsnum_digit_char
    call jsout_byte
    dec ecx
    jnz .emit
    pop rdx
    pop rcx
    pop rax
    ret

; jsnum_digit_char: EAX = 0-35 -> AL = '0'-'9', 'a'-'z'
jsnum_digit_char:
    cmp eax, 10
    jb .dec
    add eax, 'a' - 10
    ret
.dec:
    add eax, '0'
    ret

; toFixed(digits): exact, like the specification (round half up)
jsb_number_to_fixed:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    lea rsi, [jsb_name_to_fixed]
    call jsb_this_number
    mov r8, rax
    xor eax, eax
    call jsb_arg_integer
    cmp rax, 100
    ja .bad
    mov r9d, eax                    ; fraction digits
    ; NaN, Infinity and |x| >= 1e21 use ToString
    mov rax, r8
    btr rax, 63
    movq xmm0, rax
    ucomisd xmm0, [jsb_1e21]
    jae .plain
    jp .plain
    ; n = round(|x| * 10^f): x = m * 2^e exactly
    mov rcx, rax
    shr rcx, 52
    mov rbx, 0x000FFFFFFFFFFFFF
    and rbx, rax
    test ecx, ecx
    jz .subnormal
    bts rbx, 52
    sub ecx, 1075
    jmp .scaled
.subnormal:
    mov ecx, -1074
.scaled:
    lea rdi, [jsbig_a]
    mov rax, rbx
    call jsbig_set
    push rcx
    mov ecx, r9d
    call jsbig_mul_pow10
    pop rcx
    test ecx, ecx
    js .shift_right
    call jsbig_shl
    jmp .digits
.shift_right:
    neg ecx
    call jsbig_shr_round
.digits:
    ; decimal digits of n (at least f+1 of them)
    call jsout_save
    ; x < 0 gets a "-" (so -0.001 -> "-0.00"); -0 does not
    mov rax, r8
    btr rax, 63
    jnc .no_minus
    test rax, rax
    jz .no_minus
    mov al, '-'
    call jsout_byte
.no_minus:
    lea rdi, [jsbig_a]
    xor r10d, r10d                  ; digits produced (pushed on the stack)
.divide:
    mov eax, 10
    call jsbig_divmod_small
    push rdx
    inc r10d
    cmp dword [rdi + JSBIG_LEN], 0
    jne .divide
    cmp r10d, r9d
    jbe .divide                     ; pad: 0.05 -> "005" for f = 2 ... then "0.05"
.emit:
    pop rax
    add al, '0'
    call jsout_byte
    dec r10d
    jz .fixed_done
    cmp r10d, r9d
    jne .emit
    mov al, '.'
    call jsout_byte
    jmp .emit
.fixed_done:
    call jsout_take
    jmp .out
.plain:
    mov rax, r8
    call js_to_string
    call jsb_box_string
.out:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.bad:
    mov edx, JE_RANGE
    lea rsi, [jsmsg_fixed]
    xor edi, edi
    jmp js_throw

; jsbig_shr_round: RDI = bigint >>= ECX bits, rounding half up
jsbig_shr_round:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    ; the bit just below the cut decides the rounding
    lea eax, [rcx - 1]
    mov r8d, eax
    shr r8d, 6
    xor r9d, r9d                    ; round up?
    cmp r8d, [rdi + JSBIG_LEN]
    jae .shift
    mov rdx, [rdi + JSBIG_D + r8*8]
    and eax, 63
    bt rdx, rax
    setc r9b
.shift:
    ; drop whole limbs
    mov r8d, ecx
    shr r8d, 6
    and ecx, 63
    mov ebx, [rdi + JSBIG_LEN]
    cmp r8d, ebx
    jae .zero
    xor edx, edx
.move:
    lea eax, [rdx + r8]
    cmp eax, ebx
    jae .moved
    mov rax, [rdi + JSBIG_D + rax*8]
    mov [rdi + JSBIG_D + rdx*8], rax
    inc edx
    jmp .move
.moved:
    sub ebx, r8d
    mov [rdi + JSBIG_LEN], ebx
    ; then the bits
    test ecx, ecx
    jz .norm
    xor edx, edx
.bits:
    lea eax, [rdx + 1]
    cmp eax, ebx
    jae .top
    mov rax, [rdi + JSBIG_D + rdx*8]
    mov r8, [rdi + JSBIG_D + rdx*8 + 8]
    shrd rax, r8, cl
    mov [rdi + JSBIG_D + rdx*8], rax
    inc edx
    jmp .bits
.top:
    shr qword [rdi + JSBIG_D + rdx*8], cl
.norm:
    mov ebx, [rdi + JSBIG_LEN]
.trim:
    test ebx, ebx
    jz .store
    cmp qword [rdi + JSBIG_D + rbx*8 - 8], 0
    jne .store
    dec ebx
    jmp .trim
.store:
    mov [rdi + JSBIG_LEN], ebx
    jmp .round
.zero:
    mov dword [rdi + JSBIG_LEN], 0
.round:
    test r9d, r9d
    jz .done
    mov eax, 1
    call jsbig_add_small
.done:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsbig_divmod_small: RDI = bigint /= RAX (non-zero) -> RDX = remainder
jsbig_divmod_small:
    push rax
    push rbx
    push rcx
    push r8
    mov r8, rax
    mov ecx, [rdi + JSBIG_LEN]
    xor edx, edx
    mov ebx, ecx
.loop:
    test ebx, ebx
    jz .trim
    dec ebx
    mov rax, [rdi + JSBIG_D + rbx*8]
    div r8
    mov [rdi + JSBIG_D + rbx*8], rax
    jmp .loop
.trim:
    test ecx, ecx
    jz .store
    cmp qword [rdi + JSBIG_D + rcx*8 - 8], 0
    jne .store
    dec ecx
    jmp .trim
.store:
    mov [rdi + JSBIG_LEN], ecx
    pop r8
    pop rcx
    pop rbx
    pop rax
    ret

; Boolean.prototype.toString / valueOf
jsb_boolean_to_string:
    mov rax, rdx
    call js_to_string
    jmp jsb_box_string

jsb_boolean_value_of:
    mov rax, rdx
    ret

; ==============================================================================
; Math
; ==============================================================================

; MATH_ARG: XMM0 = ToNumber(argument 0) (RAX too)
%macro MATH_ARG 0
    xor eax, eax
    call jsb_arg_number
    movq xmm0, rax
%endmacro

jsb_math_abs:
    MATH_ARG
    btr rax, 63
    ret

jsb_math_sqrt:
    MATH_ARG
    sqrtsd xmm0, xmm0
    movq rax, xmm0
    ret

; jsb_trunc: XMM0 -> XMM0 truncated toward zero (keeps -0, NaN, big values)
jsb_trunc:
    push rax
    push rdx
    movq rax, xmm0
    mov rdx, rax
    btr rdx, 63
    push rcx
    mov rcx, 0x4330000000000000     ; 2^52: already an integer (or NaN/inf)
    cmp rdx, rcx
    pop rcx
    jae .done
    cvttsd2si rdx, xmm0
    cvtsi2sd xmm0, rdx
    ; keep the sign of the input (-0.5 -> -0)
    movq rdx, xmm0
    and rax, [jsb_sign_bit]
    or rdx, rax
    movq xmm0, rdx
.done:
    pop rdx
    pop rax
    ret

jsb_math_trunc:
    MATH_ARG
    call jsb_trunc
    movq rax, xmm0
    ret

jsb_math_floor:
    MATH_ARG
    movapd xmm3, xmm0
    call jsb_trunc
    ucomisd xmm0, xmm3
    jbe .done                       ; trunc <= x (or NaN)
    subsd xmm0, [jsvm_one]
.done:
    movq rax, xmm0
    ret

jsb_math_ceil:
    MATH_ARG
    movapd xmm3, xmm0
    call jsb_trunc
    ucomisd xmm0, xmm3
    jae .done
    addsd xmm0, [jsvm_one]
    ; ceil(-0.5) is -0
    movq rax, xmm3
    bt rax, 63
    jnc .done
    movq rax, xmm0
    bts rax, 63
    movq xmm0, rax
.done:
    movq rax, xmm0
    ret

jsb_math_round:
    MATH_ARG
    movapd xmm3, xmm0               ; x
    call jsb_trunc
    ucomisd xmm0, xmm3
    jbe .floored
    subsd xmm0, [jsvm_one]          ; floor(x)
.floored:
    jp .done                        ; NaN
    movapd xmm4, xmm3
    subsd xmm4, xmm0                ; x - floor(x), exact
    ucomisd xmm4, [jsb_half]
    jb .sign
    addsd xmm0, [jsvm_one]
.sign:
    ; results that are zero keep the sign of x (-0.4 -> -0)
    xorpd xmm4, xmm4
    ucomisd xmm0, xmm4
    jne .done
    movq rax, xmm3
    and rax, [jsb_sign_bit]
    movq xmm0, rax
.done:
    movq rax, xmm0
    ret

jsb_math_sign:
    MATH_ARG
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jp .same                        ; NaN
    je .same                        ; +-0
    mov rdx, JS_ONE
    ja .positive
    bts rdx, 63
.positive:
    mov rax, rdx
    ret
.same:
    ret

; min / max over all arguments (NaN wins, -0 < +0)
jsb_math_min:
    push rbx
    mov bl, 1
    jmp jsb_math_minmax
jsb_math_max:
    push rbx
    xor ebx, ebx
jsb_math_minmax:
    push rcx
    push rdx
    push rdi
    push r8
    mov r8, JS_INF
    test bl, bl
    jnz .start
    bts r8, 63                      ; max starts at -Infinity
.start:
    xor edx, edx                    ; saw NaN
.loop:
    test ecx, ecx
    jz .done
    mov rax, [rdi]
    call js_to_number
    movq xmm0, rax
    ucomisd xmm0, xmm0
    jp .nan
    movq xmm1, r8
    test bl, bl
    jz .max
    ucomisd xmm0, xmm1
    je .equal
    jae .next
    jmp .take
.max:
    ucomisd xmm0, xmm1
    je .equal
    jbe .next
.take:
    mov r8, rax
    jmp .next
.equal:
    ; +0 vs -0: min prefers -0, max prefers +0
    test bl, bl
    jz .eq_max
    or r8, rax
    jmp .next
.eq_max:
    and r8, rax
    jmp .next
.nan:
    mov edx, 1
.next:
    add rdi, 8
    dec ecx
    jmp .loop
.done:
    mov rax, r8
    test edx, edx
    jz .out
    mov rax, JS_NAN
.out:
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; random() in [0, 1): xorshift64*
jsb_math_random:
    push rdx
    mov rax, [jsb_rng]
    mov rdx, rax
    shr rdx, 12
    xor rax, rdx
    mov rdx, rax
    shl rdx, 25
    xor rax, rdx
    mov rdx, rax
    shr rdx, 27
    xor rax, rdx
    mov [jsb_rng], rax
    mov rdx, 2685821657736338717
    imul rax, rdx
    shr rax, 11                     ; 53 random bits
    cvtsi2sd xmm0, rax
    mulsd xmm0, [jsb_two_m53]
    movq rax, xmm0
    pop rdx
    ret

; pow(x, y)
jsb_math_pow:
    push rcx
    push rdx
    xor eax, eax
    call jsb_arg_number
    mov rdx, rax                    ; x
    mov eax, 1
    call jsb_arg_number             ; y
    call jsb_pow
    pop rdx
    pop rcx
    ret

; jsb_pow: RDX = x, RAX = y -> RAX = x ** y
jsb_pow:
    push rbx
    push rcx
    push rdx
    movq xmm1, rax                  ; y
    movq xmm0, rdx                  ; x
    ; y == +-0 -> 1 (even for NaN)
    mov rcx, rax
    btr rcx, 63
    test rcx, rcx
    jz .one
    ; NaN anywhere -> NaN
    ucomisd xmm1, xmm1
    jp .nan
    ucomisd xmm0, xmm0
    jp .nan
    ; |x| == 1 and y infinite -> NaN
    mov rbx, JS_INF
    cmp rcx, rbx
    jne .finite_y
    mov rbx, rdx
    btr rbx, 63
    mov rcx, JS_ONE
    cmp rbx, rcx
    je .nan
.finite_y:
    ; integer exponent: repeated squaring (exact for small results)
    movapd xmm2, xmm1
    call jsb_trunc_xmm2
    ucomisd xmm2, xmm1
    jne .general
    cvttsd2si rcx, xmm1
    mov rbx, rcx
    test rbx, rbx
    jns .abs
    neg rbx
.abs:
    cmp rbx, 0x40000000
    ja .general
    movsd xmm2, [jsvm_one]          ; result
    movapd xmm3, xmm0               ; base
.square:
    test rbx, 1
    jz .skip
    mulsd xmm2, xmm3
.skip:
    mulsd xmm3, xmm3
    shr rbx, 1
    jnz .square
    test rcx, rcx
    jns .int_done
    ; x ** -n = 1 / x ** n, unless x ** n overflowed: then (1 / x) ** n
    movq rbx, xmm2
    btr rbx, 63
    mov rax, JS_INF
    cmp rbx, rax
    je .reciprocal_base
    movsd xmm0, [jsvm_one]
    divsd xmm0, xmm2
    movapd xmm2, xmm0
    jmp .int_done
.reciprocal_base:
    movsd xmm3, [jsvm_one]
    divsd xmm3, xmm0                ; 1 / x
    mov rbx, rcx
    neg rbx
    movsd xmm2, [jsvm_one]
.square_inv:
    test rbx, 1
    jz .skip_inv
    mulsd xmm2, xmm3
.skip_inv:
    mulsd xmm3, xmm3
    shr rbx, 1
    jnz .square_inv
.int_done:
    movq rax, xmm2
    jmp .out
.general:
    ; x < 0 with a fractional y -> NaN; otherwise 2^(y log2 x) on the x87
    xorpd xmm2, xmm2
    ucomisd xmm0, xmm2
    jb .nan
    je .zero_base
    sub rsp, 16
    movsd [rsp], xmm1
    movsd [rsp + 8], xmm0
    fld qword [rsp]                 ; y
    fld qword [rsp + 8]             ; x
    fyl2x                           ; y * log2(x)
    call jsb_x87_exp2
    fstp qword [rsp]
    mov rax, [rsp]
    add rsp, 16
    jmp .out
.zero_base:
    ; 0 ** y: y > 0 -> 0, y < 0 -> Infinity
    ucomisd xmm1, xmm2
    ja .zero
    mov rax, JS_INF
    jmp .out
.zero:
    xor eax, eax
    jmp .out
.one:
    mov rax, JS_ONE
    jmp .out
.nan:
    mov rax, JS_NAN
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

; jsb_trunc_xmm2: XMM2 truncated toward zero (other XMMs kept)
jsb_trunc_xmm2:
    push rax
    movapd xmm7, xmm0
    movapd xmm0, xmm2
    call jsb_trunc
    movapd xmm2, xmm0
    movapd xmm0, xmm7
    pop rax
    ret

; jsb_x87_exp2: ST0 = t -> ST0 = 2^t (|t| >= 2048 gives Infinity or 0)
jsb_x87_exp2:
    push rax
    push rdx
    sub rsp, 8
    fst qword [rsp]
    mov rdx, [rsp]
    btr rdx, 63
    mov rax, 0x40A0000000000000     ; 2048.0
    cmp rdx, rax
    jb .normal
    mov rax, JS_INF
    cmp rdx, rax
    ja .out                         ; NaN stays NaN
    fstp st0
    bt qword [rsp], 63
    jc .tiny
    mov [rsp], rax
    fld qword [rsp]                 ; Infinity
    jmp .out
.tiny:
    fldz
    jmp .out
.normal:
    fld st0
    frndint                         ; n
    fsub st1, st0                   ; st1 = fraction (-0.5..0.5)
    fxch st1
    f2xm1
    fld1
    faddp st1, st0                  ; 2^fraction
    fscale                          ; * 2^n
    fstp st1
.out:
    add rsp, 8
    pop rdx
    pop rax
    ret

; MATH_X87 op: XMM0/RAX = argument; result from the x87
%macro MATH_X87_BEGIN 0
    MATH_ARG
    sub rsp, 8
    mov [rsp], rax
    fld qword [rsp]
%endmacro
%macro MATH_X87_END 0
    fstp qword [rsp]
    mov rax, [rsp]
    add rsp, 8
    ret
%endmacro

jsb_math_sin:
    MATH_X87_BEGIN
    fsin
    MATH_X87_END

jsb_math_cos:
    MATH_X87_BEGIN
    fcos
    MATH_X87_END

jsb_math_tan:
    MATH_X87_BEGIN
    fptan
    fstp st0
    MATH_X87_END

jsb_math_atan:
    MATH_X87_BEGIN
    fld1
    fpatan
    MATH_X87_END

jsb_math_exp:
    MATH_X87_BEGIN
    fldl2e
    fmulp st1, st0
    call jsb_x87_exp2
    MATH_X87_END

jsb_math_log:
    MATH_X87_BEGIN
    fldln2
    fxch st1
    fyl2x
    MATH_X87_END

; atan2(y, x)
jsb_math_atan2:
    push rdx
    xor eax, eax
    call jsb_arg_number
    mov rdx, rax                    ; y
    mov eax, 1
    call jsb_arg_number             ; x
    sub rsp, 16
    mov [rsp], rdx
    mov [rsp + 8], rax
    fld qword [rsp]                 ; y
    fld qword [rsp + 8]             ; x
    fpatan                          ; atan(y / x) with the right quadrant
    fstp qword [rsp]
    mov rax, [rsp]
    add rsp, 16
    pop rdx
    ret

; ==============================================================================
; console
; ==============================================================================

; console.log(...values): strings as they are, everything else inspected
jsb_console_log:
    push rbx
    push rcx
    push rdx
    push rdi
    call jsout_reset
    xor ebx, ebx
.arg:
    cmp ebx, ecx
    jae .done
    test ebx, ebx
    jz .first
    mov al, ' '
    call jsout_byte
.first:
    mov rax, [rdi + rbx*8]
    push rcx
    xor ecx, ecx
    xor edx, edx
    call jsi_value
    pop rcx
    inc ebx
    jmp .arg
.done:
    call jsout_flush
    mov rax, JS_UNDEF
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

section .rodata
align 8
jsb_sign_bit:           dq 0x8000000000000000
jsb_two_m53:            dq 1.1102230246251565e-16   ; 2^-53
