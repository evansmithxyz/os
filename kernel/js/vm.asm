; ==============================================================================
; Antigravity OS - JavaScript interpreter
; ------------------------------------------------------------------------------
; A stack machine over the bytecode from compiler.asm. JavaScript calls do not
; recurse on the kernel stack: CALL pushes a frame record (JS_FRAMES_ADDR) and
; jumps into the callee; RET pops it. Native functions and conversions that run
; JavaScript (toString, valueOf) re-enter through js_call, which runs a nested
; vm_run until its boundary frame returns.
;
; Registers while vm_run executes (handlers keep them; helpers preserve them):
;   RSI = pc          R12 = value stack top (next free slot)
;   R13 = frame base  (first argument; `this` at [R13-8], callee at [R13-16])
;   R14 = environment (heap env of the innermost scope that has one, or 0)
;   R15 = the running function object     RBP = the opcode table
; Everything else is scratch inside handlers. Before calling anything that
; may run JavaScript, a handler stores R12 in vm_sp (VMCALL).
;
; Natives: RDI = arguments, ECX = count, RDX = this, R8D = 1 under `new` (2
; from super()), R10 = the native function object itself -> RAX = result.
; They preserve every other register, like normal routines.
; Errors: js_throw / js_throw_value unwind to js_eval (no try/catch yet).
; ==============================================================================

[bits 64]

JSVM_MAX_NESTING        equ 200         ; js_call inside natives inside js_call ...
JSVM_BUDGET             equ 20000       ; ops between checks for Ctrl+C / redraw

%macro NEXT 0
    movzx eax, byte [rsi]
    inc rsi
    jmp [rbp + rax*8]
%endmacro

%macro PUSHV 1
    mov [r12], %1
    add r12, 8
%endmacro

%macro POPV 1
    sub r12, 8
    mov %1, [r12]
%endmacro

%macro VMCALL 1
    mov [vm_sp], r12
    call %1
%endmacro

; BOX reg, tmp, bits: reg |= bits (JS_OBJ_BITS / JS_STR_BITS)
%macro BOX 3
    mov %2, %3
    or %1, %2
%endmacro

; IS_OBJ value, tmp: ZF=1 if value is an object
%macro IS_OBJ 2
    mov %2, %1
    shr %2, 48
    cmp %2, JS_TAG_OBJECT
%endmacro

section .rodata
align 8
vm_ops:
%macro OPC 1
    dq vmop_%1
%endmacro
JS_OPCODE_LIST
%unmacro OPC 1

jsvm_one:               dq 1.0
jsvm_kind_names:        dq jsmsg_kind_error, jsmsg_kind_type, jsmsg_kind_reference
                        dq jsmsg_kind_syntax, jsmsg_kind_range
jsmsg_kind_error:       db "Error", 0
jsmsg_kind_type:        db "TypeError", 0
jsmsg_kind_reference:   db "ReferenceError", 0
jsmsg_kind_syntax:      db "SyntaxError", 0
jsmsg_kind_range:       db "RangeError", 0
jsmsg_not_defined:      db "% is not defined", 0
jsmsg_not_function:     db "% is not a function", 0
jsmsg_not_constructor:  db "% is not a constructor", 0
jsmsg_value:            db "value", 0
jsmsg_read_undefined:   db "Cannot read properties of undefined (reading '%')", 0
jsmsg_read_null:        db "Cannot read properties of null (reading '%')", 0
jsmsg_set_undefined:    db "Cannot set properties of undefined (setting '%')", 0
jsmsg_set_null:         db "Cannot set properties of null (setting '%')", 0
jsmsg_to_object:        db "Cannot convert undefined or null to object", 0
jsmsg_to_primitive:     db "Cannot convert object to primitive value", 0
jsmsg_const:            db "Assignment to constant variable.", 0
jsmsg_stack:            db "Maximum call stack size exceeded", 0
jsmsg_not_iterable:     db "% is not iterable", 0
jsmsg_instanceof:       db "Right-hand side of 'instanceof' is not callable", 0
jsmsg_in:               db "Cannot use 'in' operator to search for '%' in a primitive", 0
jsmsg_interrupted:      db "Script interrupted", 0
jsmsg_class_call:       db "Class constructor % cannot be invoked without 'new'", 0
jsmsg_extends:          db "Class extends value % is not a constructor or null", 0
jsmsg_super:            db "'super' keyword unexpected here", 0
jsvm_at_line:           db 10, "    at line ", 0
jsmsg_handlers:         db "Too many nested try blocks", 0

section .bss
alignb 8
vm_sp:                  resq 1          ; value stack top when JavaScript is called out
vm_fp:                  resq 1          ; current frame record
vm_completion:          resq 1          ; value of the last top-level expression statement
vm_idle_tick:           resq 1
js_catch_rsp:           resq 1          ; kernel RSP to unwind to (js_eval)
js_exception:           resq 1          ; thrown value; JS_HOLE = message in js_err_buf
vm_line:                resd 1          ; current source line
vm_budget:              resd 1
vm_nesting:             resd 1          ; js_call depth
js_call_flags:          resd 1          ; JFRF_* for the frame js_call makes
js_exception_line:      resd 1
js_err_buf:             resb 256
vm_handler_count:       resd 1
js_throwing:            resb 1
alignb 8
vm_handlers:            resb JTH_SIZE * JSVM_MAX_HANDLERS

section .text

; ==============================================================================
; Errors
; ==============================================================================

; ------------------------------------------------------------------------------
; js_throw: EDX = JE_* kind, RSI = message (a '%' is replaced by RDI), RDI =
; detail string (heap string) or 0. Throws a new Error object of that kind
; (js_err_buf keeps "Kind: message" as text). Does not return.
; ------------------------------------------------------------------------------
js_throw:
    mov r9d, edx                    ; the kind
    push rdi
    lea rdi, [js_err_buf]
    lea rax, [jsvm_kind_names]
    mov rax, [rax + rdx*8]
.kind:
    mov cl, [rax]
    test cl, cl
    jz .kind_done
    mov [rdi], cl
    inc rdi
    inc rax
    jmp .kind
.kind_done:
    mov word [rdi], ': '
    add rdi, 2
    mov r10, rdi                    ; the message starts here
    pop rdx                         ; detail
    lea r8, [js_err_buf + 250]
.msg:
    lodsb
    test al, al
    jz .done
    cmp al, '%'
    je .detail
    cmp rdi, r8
    jae .msg
    stosb
    jmp .msg
.detail:
    test rdx, rdx
    jz .msg
    mov ecx, [rdx + JSTR_LEN]
    cmp ecx, 120
    jbe .copy
    mov ecx, 120
.copy:
    push rsi
    lea rsi, [rdx + JSTR_DATA]
.copy_loop:
    test ecx, ecx
    jz .copied
    cmp rdi, r8
    jae .copied
    movsb
    dec ecx
    jmp .copy_loop
.copied:
    pop rsi
    jmp .msg
.done:
    mov byte [rdi], 0
    cmp byte [js_throwing], 0
    jne .fallback                   ; making the error object failed (no memory)
    mov byte [js_throwing], 1
    mov rsi, r10
    mov rcx, rdi
    sub rcx, r10
    call jsstr_new
    mov edx, r9d
    call js_make_error
    mov byte [js_throwing], 0
    jmp js_throw_value
.fallback:
    mov byte [js_throwing], 0
    mov rax, JS_HOLE                ; the text in js_err_buf stands for it
    jmp js_throw_value

; ------------------------------------------------------------------------------
; js_make_error: EDX = JE_* kind, RAX = message (heap string) or 0 -> RAX = a
; new error object (its prototype says the kind; message and stack own)
; ------------------------------------------------------------------------------
js_make_error:
    push rbx
    push rcx
    push rdx
    push rdi
    mov rdi, rax
    lea rbx, [js_error_protos]
    mov rax, [rbx + rdx*8]
    call jsobj_new
    mov dword [rax + JOBJ_CLASS], JC_ERROR
    call js_error_fill
    BOX rax, rcx, JS_OBJ_BITS
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; js_error_fill: RAX = object, RDI = message (heap string) or 0, EDX = kind
; -> its message and stack ("Kind: message" + "\n    at line N") set
js_error_fill:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rbx, rax
    mov r8d, edx
    test rdi, rdi
    jz .stack
    mov rcx, rdi
    BOX rcx, rsi, JS_STR_BITS
    mov rdx, [atom_message]
    call jsobj_define_hidden
.stack:
    call jsout_save
    lea rsi, [jsvm_kind_names]
    mov rsi, [rsi + r8*8]
    call jsout_cstr
    test rdi, rdi
    jz .at
    mov al, ':'
    call jsout_byte
    mov al, ' '
    call jsout_byte
    mov rax, rdi
    call jsout_str
.at:
    lea rsi, [jsvm_at_line]
    call jsout_cstr
    mov eax, [vm_line]
    call jsout_u64
    call jsout_take
    mov rcx, rax
    mov rax, rbx
    mov rdx, [atom_stack]
    call jsobj_define_hidden
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; js_throw_value: RAX = the thrown value (`throw x`). Does not return: it
; goes to the innermost try (catch) of this js_eval / js_call_safe level, or
; ends that level (js_eval_fail).
; ------------------------------------------------------------------------------
js_throw_value:
    mov [js_exception], rax
    mov edx, [vm_line]
    mov [js_exception_line], edx
    mov ecx, [vm_handler_count]
    test ecx, ecx
    jz js_throw_uncatchable.out
    dec ecx
    imul rbx, rcx, JTH_SIZE
    lea rdx, [vm_handlers]
    add rbx, rdx
    mov edx, [js_depth]
    cmp edx, [rbx + JTH_DEPTH]
    jne js_throw_uncatchable.out    ; the handler is outside this js_eval level
    mov [vm_handler_count], ecx
    ; back to the state at TRY, the exception pushed, on to the catch code
    mov rsp, [rbx + JTH_RSP]
    mov r12, [rbx + JTH_SP]
    mov r13, [rbx + JTH_BASE]
    mov r14, [rbx + JTH_ENV]
    mov r15, [rbx + JTH_FUNC]
    mov rdx, [rbx + JTH_FP]
    mov [vm_fp], rdx
    mov edx, [rbx + JTH_NEST]
    mov [vm_nesting], edx
    mov rsi, [rbx + JTH_PC]
    lea rbp, [vm_ops]
    PUSHV rax
    NEXT

; js_throw_uncatchable: RAX = value -> ends this js_eval level, whatever
; try/catch is in the way (Esc / Ctrl+C)
js_throw_uncatchable:
    mov [js_exception], rax
    mov edx, [vm_line]
    mov [js_exception_line], edx
.out:
    mov rsp, [js_catch_rsp]
    jmp js_eval_fail

; js_throw_type: RSI = message, RDI = detail (TypeError)
js_throw_type:
    mov edx, JE_TYPE
    jmp js_throw

; ==============================================================================
; Conversions
; ==============================================================================

; js_truthy: RAX = value -> CF=1 if truthy
js_truthy:
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jb .number
    je .special
    cmp edx, JS_TAG_STRING
    je .string
    pop rdx
    stc                             ; objects
    ret
.number:
    mov rdx, rax
    btr rdx, 63
    test rdx, rdx
    jz .false                       ; +0, -0
    push rcx
    mov rcx, JS_INF
    cmp rdx, rcx
    pop rcx
    ja .false                       ; NaN
    pop rdx
    stc
    ret
.special:
    mov rdx, JS_TRUE
    cmp rax, rdx
    je .true
.false:
    pop rdx
    clc
    ret
.true:
    pop rdx
    stc
    ret
.string:
    mov edx, eax
    cmp dword [rdx + JSTR_LEN], 0
    je .false
    pop rdx
    stc
    ret

; js_bool: CF -> RAX = JS_TRUE / JS_FALSE
js_bool:
    mov rax, JS_FALSE
    adc rax, 0
    ret

; js_to_number: RAX = value -> RAX = number (bits)
js_to_number:
    push rdx
.again:
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jb .done
    je .special
    cmp edx, JS_TAG_STRING
    je .string
    mov edx, 1                      ; hint: number
    call js_to_primitive
    jmp .again
.special:
    cmp eax, 1
    je .zero                        ; null
    cmp eax, 2
    je .zero                        ; false
    cmp eax, 3
    je .one                         ; true
    mov rax, JS_NAN                 ; undefined, hole
    jmp .done
.zero:
    xor eax, eax
    jmp .done
.one:
    mov rax, JS_ONE
    jmp .done
.string:
    push rcx
    push rsi
    mov esi, eax
    mov ecx, [rsi + JSTR_LEN]
    add rsi, JSTR_DATA
    call jsnum_string_to_number
    pop rsi
    pop rcx
.done:
    pop rdx
    ret

; js_to_int32: RAX = value -> EAX = ToInt32 (RAX zero-extended)
js_to_int32:
    call js_to_number
    jmp jsnum_to_int32

; js_to_primitive: RAX = value, EDX = hint (1 = number/default, 2 = string)
; -> RAX = primitive (calls valueOf / toString)
js_to_primitive:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    mov rbx, rax
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    jne .done
    mov rbx, rax                    ; the object
    mov r8d, 2                      ; two methods to try
    mov rcx, [atom_valueof]
    mov rdi, [atom_tostring]
    cmp edx, 2
    jne .try
    xchg rcx, rdi
.try:
    mov rax, rbx
    mov rdx, rcx
    call js_get
    call js_is_callable
    jnc .next
    mov rdx, rbx                    ; this
    push rcx
    xor ecx, ecx
    call js_call
    pop rcx
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    pop rdx
    jne .done
.next:
    mov rcx, rdi
    dec r8d
    jnz .try
    lea rsi, [jsmsg_to_primitive]
    xor edi, edi
    jmp js_throw_type
.done:
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; js_to_string: RAX = value -> RAX = string (heap pointer, not boxed)
js_to_string:
    push rdx
.again:
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jb .number
    je .special
    cmp edx, JS_TAG_STRING
    je .string
    mov edx, 2                      ; hint: string
    call js_to_primitive
    jmp .again
.string:
    mov eax, eax
    pop rdx
    ret
.special:
    mov rdx, [atom_null]
    cmp eax, 1
    je .atom
    mov rdx, [atom_false]
    cmp eax, 2
    je .atom
    mov rdx, [atom_true]
    cmp eax, 3
    je .atom
    mov rdx, [atom_undefined]
.atom:
    mov rax, rdx
    pop rdx
    ret
.number:
    push rcx
    push rsi
    push rdi
    sub rsp, 32
    mov rdi, rsp
    call jsnum_to_string
    mov rsi, rsp
    call jsstr_new
    add rsp, 32
    pop rdi
    pop rsi
    pop rcx
    pop rdx
    ret

; js_number_to_atom: RAX = number bits -> RAX = atom of its text
js_number_to_atom:
    push rcx
    push rsi
    push rdi
    sub rsp, 32
    mov rdi, rsp
    call jsnum_to_string
    mov rsi, rsp
    call jsstr_atom
    add rsp, 32
    pop rdi
    pop rsi
    pop rcx
    ret

; js_to_key: RAX = value -> RAX = property key atom
js_to_key:
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jb .number
    call js_to_string
    call jsstr_intern
    pop rdx
    ret
.number:
    call js_number_to_atom
    pop rdx
    ret

; js_index: RDX = key value -> EAX = array index, CF=0 when the key is one
; (a number 0 <= n < 2^32-1 with no fraction, or its canonical string)
js_index:
    push rcx
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_SPECIAL
    jb .number
    cmp ecx, JS_TAG_STRING
    jne .no
    mov eax, edx
    call jsstr_array_index
    pop rcx
    ret
.number:
    movq xmm0, rdx
    cvttsd2si rax, xmm0
    test rax, rax
    js .no
    mov ecx, 0xFFFFFFFE
    cmp rax, rcx
    ja .no
    cvtsi2sd xmm1, rax
    ucomisd xmm0, xmm1
    jne .no
    jp .no
    pop rcx
    clc
    ret
.no:
    pop rcx
    stc
    ret

; js_typeof: RAX = value -> RAX = atom ("number", "string", ...)
js_typeof:
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jb .number
    je .special
    cmp edx, JS_TAG_STRING
    je .string
    mov edx, eax
    mov rax, [atom_function]
    cmp byte [rdx + JH_KIND], JK_FUNC
    je .out
    cmp byte [rdx + JH_KIND], JK_NATIVE
    je .out
    mov rax, [atom_object]
    jmp .out
.number:
    mov rax, [atom_number]
    jmp .out
.string:
    mov rax, [atom_string]
    jmp .out
.special:
    mov rdx, rax
    mov rax, [atom_object]
    cmp edx, 1
    je .out                         ; null
    mov rax, [atom_boolean]
    cmp edx, 2
    je .out
    cmp edx, 3
    je .out
    mov rax, [atom_undefined]
.out:
    pop rdx
    ret

; js_is_callable: RAX = value -> CF=1 for functions
js_is_callable:
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .no
    mov edx, eax
    cmp byte [rdx + JH_KIND], JK_FUNC
    je .yes
    cmp byte [rdx + JH_KIND], JK_NATIVE
    je .yes
.no:
    pop rdx
    clc
    ret
.yes:
    pop rdx
    stc
    ret

; ==============================================================================
; Operators
; ==============================================================================

; js_strict_equal: RAX, RDX -> CF=1 if a === b
js_strict_equal:
    push rcx
    push r8
    mov rcx, rax
    shr rcx, 48
    mov r8, rdx
    shr r8, 48
    cmp ecx, JS_TAG_SPECIAL
    jae .not_number
    cmp r8d, JS_TAG_SPECIAL
    jae .no
    movq xmm0, rax
    movq xmm1, rdx
    ucomisd xmm0, xmm1
    jne .no
    jp .no
    jmp .yes
.not_number:
    cmp rax, rdx
    je .yes
    cmp ecx, JS_TAG_STRING
    jne .no
    cmp r8d, JS_TAG_STRING
    jne .no
    push rax
    push rdx
    mov eax, eax
    mov edx, edx
    call jsstr_equal
    pop rdx
    pop rax
    jc .yes
.no:
    pop r8
    pop rcx
    clc
    ret
.yes:
    pop r8
    pop rcx
    stc
    ret

; js_loose_equal: RAX, RDX -> CF=1 if a == b
js_loose_equal:
    push rax
    push rcx
    push rdx
    push r8
.again:
    mov rcx, rax
    shr rcx, 48
    mov r8, rdx
    shr r8, 48
    ; same kind of value: ===
    cmp ecx, JS_TAG_SPECIAL
    jb .a_number
    cmp r8d, JS_TAG_SPECIAL
    jb .mixed
    cmp ecx, r8d
    jne .mixed
    cmp ecx, JS_TAG_SPECIAL
    jne .strict
    ; both specials: null/undefined/hole equal each other; booleans ===
    call .is_nullish
    jc .a_nullish
    xchg rax, rdx
    call .is_nullish
    xchg rax, rdx
    jc .no
.strict:
    call js_strict_equal
    jmp .out
.a_nullish:
    xchg rax, rdx
    call .is_nullish
    xchg rax, rdx
    jc .yes
    jmp .no
.a_number:
    cmp r8d, JS_TAG_SPECIAL
    jb .strict
.mixed:
    ; null/undefined only equal each other
    call .is_nullish
    jc .no
    xchg rax, rdx
    call .is_nullish
    xchg rax, rdx
    jc .no
    ; booleans -> numbers
    cmp ecx, JS_TAG_SPECIAL
    jne .b_bool
    call js_to_number
    jmp .again
.b_bool:
    cmp r8d, JS_TAG_SPECIAL
    jne .objects
    xchg rax, rdx
    call js_to_number
    xchg rax, rdx
    jmp .again
.objects:
    ; object vs primitive -> primitive
    cmp ecx, JS_TAG_OBJECT
    jne .b_object
    cmp r8d, JS_TAG_OBJECT
    je .no                          ; two different objects (=== failed above)
    push rdx
    mov edx, 1
    call js_to_primitive
    pop rdx
    jmp .again
.b_object:
    cmp r8d, JS_TAG_OBJECT
    jne .num_str
    xchg rax, rdx
    push rdx
    mov edx, 1
    call js_to_primitive
    pop rdx
    xchg rax, rdx
    jmp .again
.num_str:
    ; number vs string: compare as numbers
    call js_to_number
    xchg rax, rdx
    call js_to_number
    xchg rax, rdx
    call js_strict_equal
    jmp .out
.yes:
    stc
    jmp .out
.no:
    clc
.out:
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret

; .is_nullish: RAX -> CF=1 for undefined, null, hole
.is_nullish:
    push rcx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_SPECIAL
    jne .nn_no
    cmp eax, 2
    je .nn_no
    cmp eax, 3
    je .nn_no
    pop rcx
    stc
    ret
.nn_no:
    pop rcx
    clc
    ret

; js_less: RAX = x, RDX = y -> EAX = 1 (x < y), 0 (not), 2 (undefined: NaN)
js_less:
    push rcx
    push rdx
    push r8
    push rdx
    mov edx, 1
    call js_to_primitive
    mov r8, rax
    pop rax
    call js_to_primitive
    mov rdx, rax                    ; y
    mov rax, r8                     ; x
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_STRING
    jne .numbers
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_STRING
    jne .numbers
    mov eax, eax
    mov edx, edx
    call jsstr_compare
    shr eax, 31                     ; -1 -> 1
    jmp .out
.numbers:
    call js_to_number
    xchg rax, rdx
    call js_to_number
    xchg rax, rdx
    movq xmm0, rax
    movq xmm1, rdx
    ucomisd xmm0, xmm1
    jp .undefined
    mov eax, 0
    jae .out
    mov eax, 1
    jmp .out
.undefined:
    mov eax, 2
.out:
    pop r8
    pop rdx
    pop rcx
    ret

; js_add: RAX = a, RDX = b -> RAX = a + b (numbers or string concatenation)
js_add:
    push rcx
    push rdx
    push r8
    push rdx
    mov edx, 1
    call js_to_primitive
    mov r8, rax
    pop rax
    call js_to_primitive
    mov rdx, rax                    ; b
    mov rax, r8                     ; a
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_STRING
    je .concat
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_STRING
    je .concat
    call js_to_number
    xchg rax, rdx
    call js_to_number
    movq xmm1, rax
    movq xmm0, rdx
    addsd xmm0, xmm1
    movq rax, xmm0
    jmp .out
.concat:
    call js_to_string
    xchg rax, rdx
    call js_to_string
    xchg rax, rdx
    call jsstr_concat
    BOX rax, rcx, JS_STR_BITS
.out:
    pop r8
    pop rdx
    pop rcx
    ret

; js_mod: RAX = a, RDX = b (numbers) -> RAX = a % b (sign of a, like fmod)
js_mod:
    push rcx
    sub rsp, 16
    mov [rsp], rdx
    mov [rsp + 8], rax
    fld qword [rsp]                 ; b
    fld qword [rsp + 8]             ; a
.again:
    fprem
    fnstsw ax
    test ah, 4                      ; C2: not finished
    jnz .again
    fstp qword [rsp + 8]
    fstp st0
    mov rax, [rsp + 8]
    add rsp, 16
    pop rcx
    ret

; js_instanceof: RAX = value, RDX = constructor -> CF=1 if value instanceof it
js_instanceof:
    push rax
    push rbx
    push rdx
    push rcx
    xchg rax, rdx
    call js_is_callable
    jnc .not_callable
    mov rbx, rdx                    ; the value
    mov rcx, rbx
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .no
    mov rdx, [atom_prototype]
    call js_get
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .no
    mov eax, eax                    ; prototype object
    mov ebx, ebx
.walk:
    mov rbx, [rbx + JOBJ_PROTO]
    test rbx, rbx
    jz .no
    cmp rbx, rax
    jne .walk
    pop rcx
    pop rdx
    pop rbx
    pop rax
    stc
    ret
.no:
    pop rcx
    pop rdx
    pop rbx
    pop rax
    clc
    ret
.not_callable:
    lea rsi, [jsmsg_instanceof]
    xor edi, edi
    jmp js_throw_type

; js_in: RAX = key, RDX = object -> CF=1 if the object (or its prototypes) has it
js_in:
    push rax
    push rbx
    push rcx
    push rdx
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .primitive
    xchg rax, rdx                   ; RAX = object, RDX = key
    mov ecx, eax
    cmp byte [rcx + JH_KIND], JK_ARRAY
    jne .named
    push rax
    call js_index
    mov ebx, eax
    pop rax
    jc .named
    cmp ebx, [rcx + JARR_LEN]
    jae .no
    mov rax, [rcx + JARR_ELEMS]
    mov rbx, [rax + rbx*8]
    mov rax, JS_HOLE
    cmp rbx, rax
    je .no
    jmp .yes
.named:
    push rax
    mov rax, rdx
    call js_to_key
    mov rdx, rax
    pop rax
    cmp byte [rcx + JH_KIND], JK_ARRAY
    jne .lookup
    cmp rdx, [atom_length]
    je .yes
.lookup:
    mov eax, eax
    call jsobj_lookup
    jc .no
.yes:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret
.no:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret
.primitive:
    call js_to_string
    mov rdi, rax
    lea rsi, [jsmsg_in]
    jmp js_throw_type

; ==============================================================================
; Properties
; ==============================================================================

; ------------------------------------------------------------------------------
; js_get: RAX = value, RDX = atom -> RAX = value.name
; ------------------------------------------------------------------------------
js_get:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    mov r8, rax                     ; the receiver (a getter's this)
    mov edx, edx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    je .object
    cmp ecx, JS_TAG_STRING
    je .string
    cmp ecx, JS_TAG_SPECIAL
    jb .number
    cmp eax, 2
    je .boolean
    cmp eax, 3
    je .boolean
    ; undefined / null
    mov rdi, rdx
    lea rsi, [jsmsg_read_undefined]
    cmp eax, 1
    jne .throw
    lea rsi, [jsmsg_read_null]
.throw:
    jmp js_throw_type
.number:
    mov rax, [js_number_proto]
    jmp .lookup
.boolean:
    mov rax, [js_boolean_proto]
    jmp .lookup
.string:
    cmp rdx, [atom_length]
    jne .string_proto
    mov eax, eax
    mov eax, [rax + JSTR_LEN]
    cvtsi2sd xmm0, rax
    movq rax, xmm0
    jmp .out
.string_proto:
    mov rax, [js_string_proto]
    jmp .lookup
.object:
    mov edi, eax
    movzx ecx, byte [rdi + JH_KIND]
    cmp ecx, JK_ARRAY
    je .array
    cmp ecx, JK_FUNC
    je .function
    cmp ecx, JK_NATIVE
    je .native
    cmp dword [rdi + JOBJ_CLASS], JC_HOST
    jb .object_lookup
    call jsd_get                    ; DOM properties (CF=0: RAX = the value)
    jnc .out
.object_lookup:
    mov rax, rdi
.lookup:
    call jsobj_lookup
    jc .undefined
.entry:
    bt qword [rbx + JPE_KEY], 34    ; an accessor: call its getter
    jc .getter
    mov rax, [rbx + JPE_VAL]
    jmp .out
.getter:
    mov rax, [rbx + JPE_VAL]
    mov rax, [rax + JACC_GET]
    mov rcx, JS_UNDEF
    cmp rax, rcx
    je .out
    mov rdx, r8
    xor ecx, ecx
    call js_call
    jmp .out
.undefined:
    mov rax, JS_UNDEF
    jmp .out
.array:
    cmp rdx, [atom_length]
    jne .object_lookup
    mov eax, [rdi + JARR_LEN]
    cvtsi2sd xmm0, rax
    movq rax, xmm0
    jmp .out
.function:
    cmp rdx, [atom_prototype]
    je .prototype
    mov rax, rdi
    call jsobj_find_own
    jnc .own
    mov rcx, [rdi + JFN_CODE]
    cmp rdx, [atom_name]
    je .fn_name
    cmp rdx, [atom_length]
    jne .object_lookup
    movzx eax, word [rcx + JCODE_NPARAMS]
    cvtsi2sd xmm0, rax
    movq rax, xmm0
    jmp .out
.fn_name:
    mov rax, [rcx + JCODE_NAME]
    jmp .name
.own:
    jmp .entry
.prototype:
    call jsfn_prototype
    jmp .out
.native:
    mov rax, rdi
    call jsobj_find_own
    jnc .own
    cmp rdx, [atom_name]
    je .native_name
    cmp rdx, [atom_length]
    jne .object_lookup
    mov eax, [rdi + JFN_NARGS]
    cvtsi2sd xmm0, rax
    movq rax, xmm0
    jmp .out
.native_name:
    mov rax, [rdi + JFN_NAME]
.name:
    test rax, rax
    jnz .name_ok
    mov rax, [atom_empty]
.name_ok:
    BOX rax, rcx, JS_STR_BITS
.out:
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsfn_prototype: RDI = JK_FUNC object -> RAX = its .prototype (made on first use)
jsfn_prototype:
    mov rax, [rdi + JFN_PROTO_OBJ]
    test rax, rax
    jnz .ret
    push rcx
    push rdx
    call jsobj_new_plain
    mov rcx, rdi
    BOX rcx, rdx, JS_OBJ_BITS
    mov rdx, [atom_constructor]
    call jsobj_define_hidden
    BOX rax, rdx, JS_OBJ_BITS
    mov [rdi + JFN_PROTO_OBJ], rax
    pop rdx
    pop rcx
.ret:
    ret

; ------------------------------------------------------------------------------
; js_put: RAX = value, RDX = atom, RCX = new value (value.name = new value)
; ------------------------------------------------------------------------------
js_put:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    mov edx, edx
    mov rbx, rax
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    je .object
    cmp ebx, JS_TAG_SPECIAL
    jne .out                        ; strings, numbers: ignored
    cmp eax, 2
    jae .out                        ; booleans
    mov rdi, rdx
    lea rsi, [jsmsg_set_undefined]
    cmp eax, 1
    jne .throw
    lea rsi, [jsmsg_set_null]
.throw:
    jmp js_throw_type
.object:
    mov eax, eax
    movzx ebx, byte [rax + JH_KIND]
    cmp ebx, JK_ARRAY
    jne .not_array
    cmp rdx, [atom_length]
    jne .plain
    push rax
    mov rax, rcx
    call js_array_length_value
    mov ecx, eax
    pop rax
    call jsarr_set_length
    jmp .out
.not_array:
    cmp ebx, JK_FUNC
    jne .plain
    cmp rdx, [atom_prototype]
    jne .plain
    mov [rax + JFN_PROTO_OBJ], rcx
    jmp .out
.plain:
    cmp dword [rax + JOBJ_CLASS], JC_HOST
    jb .ordinary
    call jsd_put                    ; DOM properties (CF=0: handled)
    jnc .out
.ordinary:
    ; an accessor here or on a prototype: its setter
    push rbx
    call jsobj_lookup
    jc .data
    bt qword [rbx + JPE_KEY], 34
    jnc .data
    mov rbx, [rbx + JPE_VAL]
    mov rbx, [rbx + JACC_SET]
    mov rdi, JS_UNDEF
    cmp rbx, rdi
    je .setter_done                 ; no setter: ignored
    push rcx
    mov rdi, rsp                    ; the argument
    mov rdx, rax
    BOX rdx, rcx, JS_OBJ_BITS       ; this
    mov rax, rbx
    mov ecx, 1
    call js_call
    pop rcx
.setter_done:
    pop rbx
    jmp .out
.data:
    pop rbx
    call jsobj_put
.out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; js_array_length_value: RAX = value -> EAX = valid array length (RangeError)
js_array_length_value:
    push rdx
    call js_to_number
    mov rdx, rax
    call js_index
    jc .bad
    cmp eax, JARR_MAX
    ja .bad
    pop rdx
    ret
.bad:
    mov edx, JE_RANGE
    lea rsi, [jsmsg_array_length]
    xor edi, edi
    jmp js_throw

; ------------------------------------------------------------------------------
; js_get_elem: RAX = value, RDX = key -> RAX = value[key]
; ------------------------------------------------------------------------------
js_get_elem:
    push rbx
    push rcx
    push rdx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    je .object
    cmp ecx, JS_TAG_STRING
    je .string
    jmp .named
.object:
    mov ebx, eax
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .named
    push rax
    call js_index
    mov ecx, eax
    pop rax
    jc .named
    mov rax, JS_UNDEF
    cmp ecx, [rbx + JARR_LEN]
    jae .out
    mov rdx, [rbx + JARR_ELEMS]
    mov rax, [rdx + rcx*8]
    mov rdx, JS_HOLE
    cmp rax, rdx
    jne .out
    mov rax, JS_UNDEF
    jmp .out
.string:
    mov ebx, eax
    push rax
    call js_index
    mov ecx, eax
    pop rax
    jc .named
    mov rax, JS_UNDEF
    cmp ecx, [rbx + JSTR_LEN]
    jae .out
    movzx eax, byte [rbx + JSTR_DATA + rcx]
    call jsstr_char
    BOX rax, rdx, JS_STR_BITS
    jmp .out
.named:
    ; undefined/null: report the key in the error
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_SPECIAL
    jne .key
    cmp eax, 2
    jae .key
    push rax
    mov rax, rdx
    call js_to_key
    mov rdx, rax
    pop rax
    call js_get                     ; throws
.key:
    push rax
    mov rax, rdx
    call js_to_key
    mov rdx, rax
    pop rax
    call js_get
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

; js_put_elem: RAX = value, RDX = key, RCX = new value
js_put_elem:
    push rax
    push rbx
    push rdx
    mov rbx, rax
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    jne .named
    mov ebx, eax
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .named
    push rax
    call js_index
    mov edx, eax
    pop rax
    jc .named_key
    cmp edx, JARR_MAX
    jae .named_key
    mov rax, rbx
    call jsarr_set
    jmp .out
.named_key:
    mov rdx, [rsp]                  ; the original key
.named:
    push rax
    mov rax, rdx
    call js_to_key
    mov rdx, rax
    pop rax
    call js_put
.out:
    pop rdx
    pop rbx
    pop rax
    ret

; js_delete: RAX = value, RDX = key -> CF=1 if the property is gone
js_delete:
    push rax
    push rbx
    push rcx
    push rdx
    mov rbx, rax
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    je .object
    cmp ebx, JS_TAG_SPECIAL
    jne .yes
    cmp eax, 2
    jae .yes
    lea rsi, [jsmsg_to_object]
    xor edi, edi
    jmp js_throw_type
.object:
    mov ebx, eax
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .named
    push rdx
    call js_index
    mov ecx, eax
    pop rdx
    jc .named
    cmp ecx, [rbx + JARR_LEN]
    jae .yes
    mov rax, [rbx + JARR_ELEMS]
    mov rdx, JS_HOLE
    mov [rax + rcx*8], rdx
    jmp .yes
.named:
    mov rax, rdx
    call js_to_key
    mov rdx, rax
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .remove
    cmp rdx, [atom_length]
    je .no
.remove:
    mov rax, rbx
    call jsobj_delete
    jc .no
.yes:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret
.no:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret

; ------------------------------------------------------------------------------
; js_forin_keys: RAX = value -> RAX = array (raw pointer) of its enumerable
; keys: indices first, then named properties, then those of its prototypes
; ------------------------------------------------------------------------------
js_forin_keys:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rbx, rax
    xor ecx, ecx
    call jsarr_new
    mov r8, rax                     ; the key array
    mov rcx, rbx
    shr rcx, 48
    cmp ecx, JS_TAG_STRING
    je .string
    cmp ecx, JS_TAG_OBJECT
    jne .done
    mov ebx, ebx
.object:
    test rbx, rbx
    jz .done
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .props
    xor edx, edx
.index:
    cmp edx, [rbx + JARR_LEN]
    jae .props
    mov rax, [rbx + JARR_ELEMS]
    mov rax, [rax + rdx*8]
    mov rcx, JS_HOLE
    cmp rax, rcx
    je .next_index
    mov eax, edx
    cvtsi2sd xmm0, rax
    movq rax, xmm0
    call js_number_to_atom
    call .add_key
.next_index:
    inc edx
    jmp .index
.props:
    mov ecx, [rbx + JOBJ_COUNT]
    mov rsi, [rbx + JOBJ_PROPS]
.prop:
    test ecx, ecx
    jz .proto
    mov rax, [rsi + JPE_KEY]
    test eax, eax
    jz .next_prop
    bt rax, 32                      ; JPA_HIDDEN
    jc .next_prop
    mov eax, eax
    call .add_key
.next_prop:
    add rsi, JPE_SIZE
    dec ecx
    jmp .prop
.proto:
    mov rbx, [rbx + JOBJ_PROTO]
    jmp .object
.string:
    mov ebx, ebx
    xor edx, edx
.char:
    cmp edx, [rbx + JSTR_LEN]
    jae .done
    mov eax, edx
    cvtsi2sd xmm0, rax
    movq rax, xmm0
    call js_number_to_atom
    call .add_key
    inc edx
    jmp .char
.done:
    mov rax, r8
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; .add_key: RAX = atom; appended to R8 unless already there
.add_key:
    push rcx
    push rdx
    push rdi
    mov rdi, [r8 + JARR_ELEMS]
    mov ecx, [r8 + JARR_LEN]
    mov rdx, JS_STR_BITS
    or rax, rdx
.dup:
    test ecx, ecx
    jz .append
    cmp [rdi], rax
    je .skip
    add rdi, 8
    dec ecx
    jmp .dup
.append:
    push rax
    mov rcx, rax
    mov rax, r8
    call jsarr_push
    pop rax
.skip:
    pop rdi
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------------------------
; js_spread_into: RAX = array, RDX = value -> the value's items appended
; (arrays and strings; anything else is not iterable yet)
; ------------------------------------------------------------------------------
js_spread_into:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    mov rsi, rax                    ; the array being built
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_STRING
    je .string
    cmp ecx, JS_TAG_OBJECT
    jne .not_iterable
    mov ebx, edx
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .not_iterable
    xor edi, edi
.item:
    cmp edi, [rbx + JARR_LEN]
    jae .done
    mov rax, [rbx + JARR_ELEMS]
    mov rcx, [rax + rdi*8]
    mov rax, JS_HOLE
    cmp rcx, rax
    jne .push
    mov rcx, JS_UNDEF
.push:
    mov rax, rsi
    call jsarr_push
    inc edi
    jmp .item
.string:
    mov ebx, edx
    xor edi, edi
.char:
    cmp edi, [rbx + JSTR_LEN]
    jae .done
    movzx eax, byte [rbx + JSTR_DATA + rdi]
    call jsstr_char
    mov rcx, rax
    BOX rcx, rax, JS_STR_BITS
    mov rax, rsi
    call jsarr_push
    inc edi
    jmp .char
.done:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.not_iterable:
    mov rax, rdx
    call js_to_string
    mov rdi, rax
    lea rsi, [jsmsg_not_iterable]
    jmp js_throw_type

; js_own_keys: RAX = value -> RAX = array (raw) of its own enumerable keys
; (strings; for objects without their prototypes' keys)
js_own_keys:
    push rdx
    push rdi
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .any
    mov edi, eax
    push qword [rdi + JOBJ_PROTO]
    mov qword [rdi + JOBJ_PROTO], 0
    call js_forin_keys
    pop qword [rdi + JOBJ_PROTO]
    pop rdi
    pop rdx
    ret
.any:
    call js_forin_keys
    pop rdi
    pop rdx
    ret

; js_copy_props: RAX = object (raw), RDX = source -> the source's own
; enumerable properties copied onto the object ({...src}, Object.assign)
js_copy_props:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rsi, rax
    mov rdi, rdx
    call vm_nullish_rdx
    jc .done
    mov rax, rdi
    call js_own_keys
    mov rbx, rax
    xor ecx, ecx
.key:
    cmp ecx, [rbx + JARR_LEN]
    jae .done
    mov rdx, [rbx + JARR_ELEMS]
    mov rdx, [rdx + rcx*8]          ; the key (a string value)
    push rcx
    mov rax, rdi
    push rdx
    call js_get_elem
    mov rcx, rax
    pop rdx
    mov edx, edx
    mov rax, rsi
    call jsobj_define
    pop rcx
    inc ecx
    jmp .key
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; vm_nullish_rdx: RDX = value -> CF=1 for null / undefined
vm_nullish_rdx:
    push rax
    mov rax, rdx
    call vm_nullish
    pop rax
    ret

; js_array_rest: RAX = value, EDX = start -> RAX = array of its items from
; there on (arrays, strings)
js_array_rest:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rbx, rax
    xor ecx, ecx
    call jsarr_new
    mov rsi, rax
    mov rax, rbx
    shr rax, 48
    cmp eax, JS_TAG_STRING
    je .string
    cmp eax, JS_TAG_OBJECT
    jne .done
    mov ebx, ebx
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .done
.item:
    cmp edx, [rbx + JARR_LEN]
    jae .done
    mov rax, [rbx + JARR_ELEMS]
    mov rcx, [rax + rdx*8]
    mov rax, JS_HOLE
    cmp rcx, rax
    jne .push
    mov rcx, JS_UNDEF
.push:
    mov rax, rsi
    call jsarr_push
    inc edx
    jmp .item
.string:
    mov ebx, ebx
.char:
    cmp edx, [rbx + JSTR_LEN]
    jae .done
    movzx eax, byte [rbx + JSTR_DATA + rdx]
    call jsstr_char
    mov rcx, rax
    BOX rcx, rax, JS_STR_BITS
    mov rax, rsi
    call jsarr_push
    inc edx
    jmp .char
.done:
    mov rax, rsi
    BOX rax, rcx, JS_OBJ_BITS
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; js_object_rest: RAX = source, RDI = excluded keys (string values), ECX =
; how many -> RAX = a new object with the other own enumerable properties
js_object_rest:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    mov r8, rax                     ; source
    mov r9, rdi                     ; excluded
    mov r10d, ecx
    call jsobj_new_plain
    mov rsi, rax                    ; the result
    mov rdx, r8
    call vm_nullish_rdx
    jc .done
    mov rax, r8
    call js_own_keys
    mov rbx, rax
    xor ecx, ecx
.key:
    cmp ecx, [rbx + JARR_LEN]
    jae .done
    mov rdx, [rbx + JARR_ELEMS]
    mov rdx, [rdx + rcx*8]
    ; excluded? (keys are atoms: compare the texts)
    push rcx
    xor ecx, ecx
.excluded:
    cmp ecx, r10d
    jae .copy
    mov rax, [r9 + rcx*8]
    push rdx
    call js_strict_equal
    pop rdx
    jc .skip
    inc ecx
    jmp .excluded
.copy:
    mov rax, r8
    push rdx
    call js_get_elem
    mov rcx, rax
    pop rdx
    mov rax, rdx
    call js_to_key
    mov edx, eax
    mov rax, rsi
    call jsobj_define
.skip:
    pop rcx
    inc ecx
    jmp .key
.done:
    mov rax, rsi
    BOX rax, rcx, JS_OBJ_BITS
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ==============================================================================
; Functions and calls
; ==============================================================================

; jsfn_new: RAX = JK_CODE template, RDX = environment -> RAX = function (raw)
jsfn_new:
    push rcx
    push rdi
    mov rdi, rax
    mov ecx, JFN_SIZE
    call js_alloc
    mov byte [rax + JH_KIND], JK_FUNC
    mov rcx, [js_function_proto]
    mov [rax + JOBJ_PROTO], rcx
    mov [rax + JFN_CODE], rdi
    mov [rax + JFN_ENV], rdx
    pop rdi
    pop rcx
    ret

; jsfn_native: RAX = routine, ECX = declared argument count, RDX = name atom
; -> RAX = native function object (raw)
jsfn_native:
    push rdi
    push rcx
    mov rdi, rax
    mov ecx, JFN_SIZE
    call js_alloc
    pop rcx
    mov byte [rax + JH_KIND], JK_NATIVE
    mov [rax + JFN_NATIVE], rdi
    mov [rax + JFN_NARGS], ecx
    mov [rax + JFN_NAME], rdx
    mov rdi, [js_function_proto]
    mov [rax + JOBJ_PROTO], rdi
    pop rdi
    ret

; ------------------------------------------------------------------------------
; js_call: RAX = function, RDX = this, RDI = arguments, ECX = count
; -> RAX = result. Runs JavaScript functions in a nested vm_run.
; ------------------------------------------------------------------------------
js_call:
    mov dword [js_call_flags], JFRF_BOUNDARY
js_call_flagged:
    push rbx
    mov rbx, rax
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    jne .not_function
    mov ebx, eax
    cmp byte [rbx + JH_KIND], JK_NATIVE
    je .native
    cmp byte [rbx + JH_KIND], JK_FUNC
    jne .not_function
    ; a class constructor only runs under new
    test dword [js_call_flags], JFRF_CONSTRUCT
    jnz .callable
    mov rbx, [rbx + JFN_CODE]
    test byte [rbx + JCODE_FLAGS], JCF_CLASSCTOR
    jnz .class
.callable:
    pop rbx
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    inc dword [vm_nesting]
    cmp dword [vm_nesting], JSVM_MAX_NESTING
    ja vm_stack_overflow
    push qword [vm_sp]              ; restored afterwards (vm_run keeps no registers)
    mov r12, [vm_sp]
    mov rbx, r12                    ; callee slot
    lea r8, [r12 + rcx*8 + 32]
    cmp r8, JS_STACK_ADDR + JS_STACK_SIZE
    jae vm_stack_overflow
    mov [r12], rax
    mov [r12 + 8], rdx
    add r12, 16
    mov r8d, ecx
.copy:
    test r8d, r8d
    jz .enter
    mov rax, [rdi]
    mov [r12], rax
    add rdi, 8
    add r12, 8
    dec r8d
    jmp .copy
.enter:
    mov r8d, [js_call_flags]
    call vm_enter_js
    call vm_run
    pop qword [vm_sp]
    dec dword [vm_nesting]
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.native:
    push r8
    push r10
    xor r8d, r8d
    test dword [js_call_flags], JFRF_CONSTRUCT
    jz .plain
    mov r8d, 1                      ; (from js_construct)
.plain:
    mov r10, rbx
    call [rbx + JFN_NATIVE]
    pop r10
    pop r8
    pop rbx
    ret
.class:
    mov edi, [rbx + JCODE_NAME]
    pop rbx
    lea rsi, [jsmsg_class_call]
    jmp js_throw_type
.not_function:
    pop rbx
    lea rsi, [jsmsg_not_function]
    push rax
    lea rsi, [jsmsg_value]
    call jsstr_from_cstr
    mov rdi, rax
    pop rax
    lea rsi, [jsmsg_not_function]
    jmp js_throw_type

; ------------------------------------------------------------------------------
; js_construct: RAX = function, RDI = arguments, ECX = count -> RAX = the
; result of new f(...arguments)
; ------------------------------------------------------------------------------
js_construct:
    push rbx
    push rdx
    call js_is_callable
    jnc .not_constructor
    mov ebx, eax
    cmp byte [rbx + JH_KIND], JK_FUNC
    jne .this
    mov rdx, [rbx + JFN_CODE]
    test byte [rdx + JCODE_FLAGS], JCF_ARROW
    jnz .not_constructor
.this:
    ; this = a new object inheriting f.prototype
    push rax
    mov rdx, [atom_prototype]
    call js_get
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    mov rdx, [js_object_proto]
    jne .proto
    mov edx, eax
.proto:
    mov rax, rdx
    call jsobj_new
    BOX rax, rdx, JS_OBJ_BITS
    mov rdx, rax
    pop rax
    push rdx
    mov dword [js_call_flags], JFRF_BOUNDARY | JFRF_CONSTRUCT
    call js_call_flagged
    pop rdx
    ; (a JavaScript frame already put this in place of a non-object result)
    mov rbx, rax
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    je .out
    mov rax, rdx
.out:
    pop rdx
    pop rbx
    ret
.not_constructor:
    lea rsi, [jsmsg_value]
    call jsstr_from_cstr
    mov rdi, rax
    lea rsi, [jsmsg_not_constructor]
    jmp js_throw_type

vm_stack_overflow:
    mov edx, JE_RANGE
    lea rsi, [jsmsg_stack]
    xor edi, edi
    jmp js_throw

; ------------------------------------------------------------------------------
; vm_enter_js: start a JavaScript function. RBX = callee slot on the value
; stack ([f][this][args...]), ECX = argument count, R8D = frame flags, R12 =
; stack top after the arguments. Saves the caller's RSI/R13/R14/R15 in a new
; frame and sets them up for the callee. Clobbers RAX, RCX, RDX, RDI, R8-R11.
; ------------------------------------------------------------------------------
vm_enter_js:
    dec dword [vm_budget]
    jnz .budget_ok
    call vm_check_budget
.budget_ok:
    mov rdx, [vm_fp]
    add rdx, JFR_SIZE
    cmp rdx, JS_FRAMES_ADDR + JS_FRAMES_SIZE - JFR_SIZE
    jae vm_stack_overflow
    lea rax, [r12 + 32768]          ; room for locals and temporaries
    cmp rax, JS_STACK_ADDR + JS_STACK_SIZE
    jae vm_stack_overflow
    mov [vm_fp], rdx
    mov [rdx + JFR_PC], rsi
    mov [rdx + JFR_BASE], r13
    mov [rdx + JFR_FUNC], r15
    mov [rdx + JFR_ENV], r14
    mov [rdx + JFR_RESULT], rbx
    mov [rdx + JFR_FLAGS], r8d
    mov eax, [vm_line]
    mov [rdx + JFR_LINE], eax
    mov r15d, [rbx]                 ; the function object
    mov r9, [r15 + JFN_CODE]        ; its template
    lea r13, [rbx + 16]
    test byte [r9 + JCODE_FLAGS], JCF_ARROW
    jz .own_this
    mov rax, [r15 + JFN_THIS]
    mov [rbx + 8], rax
    jmp .this_ok
.own_this:
    ; sloppy-mode `this`: undefined/null -> the global object
    mov rax, [rbx + 8]
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jne .this_ok
    cmp eax, 1
    ja .this_ok
    mov rax, [js_global]
    BOX rax, rdx, JS_OBJ_BITS
    mov [rbx + 8], rax
.this_ok:
    movzx r10d, word [r9 + JCODE_NPARAMS]
    xor r11d, r11d                  ; the arguments object
    test byte [r9 + JCODE_FLAGS], JCF_ARGUMENTS
    jz .params
    push rcx
    call jsarr_new
    mov r11, rax
    mov rdi, r13
    mov edx, ecx
.args:
    test edx, edx
    jz .args_done
    mov rcx, [rdi]
    mov rax, r11
    call jsarr_push
    add rdi, 8
    dec edx
    jmp .args
.args_done:
    mov dword [r11 + JOBJ_CLASS], JC_ARGUMENTS
    BOX r11, rax, JS_OBJ_BITS
    pop rcx
.params:
    ; ...rest: the arguments after the named ones
    xor r8d, r8d
    test byte [r9 + JCODE_FLAGS], JCF_REST
    jz .missing_params
    push rcx
    mov edx, ecx
    sub edx, r10d
    jg .rest_count
    xor edx, edx
.rest_count:
    push rdx
    mov ecx, edx
    call jsarr_new
    mov r8, rax
    pop rdx
    lea rdi, [r13 + r10*8]
.rest_item:
    test edx, edx
    jz .rest_done
    mov rcx, [rdi]
    mov rax, r8
    call jsarr_push
    add rdi, 8
    dec edx
    jmp .rest_item
.rest_done:
    BOX r8, rax, JS_OBJ_BITS
    pop rcx
.missing_params:
    ; missing arguments are undefined; extra ones are dropped
    mov rax, JS_UNDEF
.missing:
    cmp ecx, r10d
    jae .params_done
    mov [r13 + rcx*8], rax
    inc ecx
    jmp .missing
.params_done:
    lea r12, [r13 + r10*8]
    test byte [r9 + JCODE_FLAGS], JCF_HEAPENV
    jz .stack_locals
    ; variables live in a heap environment
    mov ecx, [r9 + JCODE_NENV]
    lea ecx, [rcx*8 + JENV_VALS]
    call js_alloc
    mov byte [rax + JH_KIND], JK_ENV
    mov ecx, [r9 + JCODE_NENV]
    mov [rax + JENV_COUNT], ecx
    mov rdx, [r15 + JFN_ENV]
    mov [rax + JENV_PARENT], rdx
    mov r14, rax
    xor edx, edx
    mov rdi, JS_UNDEF
.env_fill:
    cmp edx, ecx
    jae .env_params
    mov [r14 + JENV_VALS + rdx*8], rdi
    inc edx
    jmp .env_fill
.env_params:
    xor edx, edx
.env_param:
    cmp edx, r10d
    jae .env_special
    mov rax, [r13 + rdx*8]
    mov [r14 + JENV_VALS + rdx*8], rax
    inc edx
    jmp .env_param
.env_special:
    test byte [r9 + JCODE_FLAGS], JCF_ARGUMENTS
    jz .env_rest
    mov edx, [r9 + JCODE_ARGSLOT]
    mov [r14 + JENV_VALS + rdx*8], r11
.env_rest:
    test byte [r9 + JCODE_FLAGS], JCF_REST
    jz .env_self
    mov edx, [r9 + JCODE_RESTSLOT]
    mov [r14 + JENV_VALS + rdx*8], r8
.env_self:
    test byte [r9 + JCODE_FLAGS], JCF_SELF
    jz .code
    mov edx, [r9 + JCODE_SELFSLOT]
    mov rax, [rbx]
    mov [r14 + JENV_VALS + rdx*8], rax
    jmp .code
.stack_locals:
    mov r14, [r15 + JFN_ENV]
    mov ecx, [r9 + JCODE_NLOCALS]
    sub ecx, r10d
    mov rax, JS_UNDEF
.local:
    test ecx, ecx
    jle .stack_special
    PUSHV rax
    dec ecx
    jmp .local
.stack_special:
    test byte [r9 + JCODE_FLAGS], JCF_ARGUMENTS
    jz .stack_rest
    mov edx, [r9 + JCODE_ARGSLOT]
    mov [r13 + rdx*8], r11
.stack_rest:
    test byte [r9 + JCODE_FLAGS], JCF_REST
    jz .stack_self
    mov edx, [r9 + JCODE_RESTSLOT]
    mov [r13 + rdx*8], r8
.stack_self:
    test byte [r9 + JCODE_FLAGS], JCF_SELF
    jz .code
    mov edx, [r9 + JCODE_SELFSLOT]
    mov rax, [rbx]
    mov [r13 + rdx*8], rax
.code:
    mov rsi, [r9 + JCODE_CODE]
    ret

; vm_check_budget: every JSVM_BUDGET calls/backward jumps: let the desktop
; redraw and stop the script on Esc / Ctrl+C
vm_check_budget:
    mov dword [vm_budget], JSVM_BUDGET
    push rax
    mov rax, [timer_ticks]
    sub rax, [vm_idle_tick]
    cmp rax, TICKS(20)
    jb .out
    mov rax, [timer_ticks]
    mov [vm_idle_tick], rax
    call con_idle
    call con_check_cancel
    jc .cancel
.out:
    pop rax
    ret
.cancel:
    lea rsi, [jsmsg_interrupted]
    call jsstr_from_cstr
    xor edx, edx
    call js_make_error
    jmp js_throw_uncatchable

; vm_run: execute from the registers vm_enter_js set up until the boundary
; frame returns -> RAX = its result
vm_run:
    push rbp
    lea rbp, [vm_ops]
    NEXT

; ==============================================================================
; Opcode handlers
; ==============================================================================

vmop_UNDEF:
    mov rax, JS_UNDEF
    PUSHV rax
    NEXT
vmop_NULL:
    mov rax, JS_NULL
    PUSHV rax
    NEXT
vmop_TRUE:
    mov rax, JS_TRUE
    PUSHV rax
    NEXT
vmop_FALSE:
    mov rax, JS_FALSE
    PUSHV rax
    NEXT
vmop_HOLE:
    mov rax, JS_HOLE
    PUSHV rax
    NEXT
vmop_NUM:
    mov rax, [rsi]
    add rsi, 8
    PUSHV rax
    NEXT
vmop_STR:
    mov eax, [rsi]
    add rsi, 4
    BOX rax, rdx, JS_STR_BITS
    PUSHV rax
    NEXT
vmop_THIS:
    mov rax, [r13 - 8]
    PUSHV rax
    NEXT
vmop_POP:
    sub r12, 8
    NEXT
vmop_DUP:
    mov rax, [r12 - 8]
    PUSHV rax
    NEXT
vmop_DUP2:
    mov rax, [r12 - 16]
    mov rdx, [r12 - 8]
    mov [r12], rax
    mov [r12 + 8], rdx
    add r12, 16
    NEXT
vmop_SWAP:
    mov rax, [r12 - 16]
    mov rdx, [r12 - 8]
    mov [r12 - 16], rdx
    mov [r12 - 8], rax
    NEXT
vmop_ROT3:                          ; a b c -> c a b
    mov rax, [r12 - 24]
    mov rdx, [r12 - 16]
    mov rcx, [r12 - 8]
    mov [r12 - 24], rcx
    mov [r12 - 16], rax
    mov [r12 - 8], rdx
    NEXT
vmop_ROT4:                          ; a b c d -> d a b c
    mov rax, [r12 - 32]
    mov rdx, [r12 - 24]
    mov rcx, [r12 - 16]
    mov rbx, [r12 - 8]
    mov [r12 - 32], rbx
    mov [r12 - 24], rax
    mov [r12 - 16], rdx
    mov [r12 - 8], rcx
    NEXT

vmop_GETLOC:
    movzx eax, word [rsi]
    add rsi, 2
    mov rax, [r13 + rax*8]
    PUSHV rax
    NEXT
vmop_SETLOC:
    movzx eax, word [rsi]
    add rsi, 2
    mov rdx, [r12 - 8]
    mov [r13 + rax*8], rdx
    NEXT
vmop_GETENV:
    movzx ecx, byte [rsi]
    movzx eax, word [rsi + 1]
    add rsi, 3
    mov rdx, r14
.up:
    test ecx, ecx
    jz .here
    mov rdx, [rdx + JENV_PARENT]
    dec ecx
    jmp .up
.here:
    mov rax, [rdx + JENV_VALS + rax*8]
    PUSHV rax
    NEXT
vmop_SETENV:
    movzx ecx, byte [rsi]
    movzx eax, word [rsi + 1]
    add rsi, 3
    mov rdx, r14
.up:
    test ecx, ecx
    jz .here
    mov rdx, [rdx + JENV_PARENT]
    dec ecx
    jmp .up
.here:
    mov rcx, [r12 - 8]
    mov [rdx + JENV_VALS + rax*8], rcx
    NEXT

; GETGLOB atom, cache: the cache holds the property's index in the global object
vmop_GETGLOB:
    mov edx, [rsi]
    mov ecx, [rsi + 4]
    add rsi, 8
    mov rax, [js_global]
    cmp ecx, [rax + JOBJ_COUNT]
    jae .slow
    mov rbx, [rax + JOBJ_PROPS]
    shl ecx, 4
    add rbx, rcx
    cmp [rbx + JPE_KEY], edx
    jne .slow
    bt qword [rbx + JPE_KEY], 34
    jc .accessor
    mov rax, [rbx + JPE_VAL]
    PUSHV rax
    NEXT
.slow:
    call jsobj_find_own
    jc .inherited
    call vm_cache_index             ; [RSI-4] = index of RBX
    bt qword [rbx + JPE_KEY], 34
    jc .accessor
    mov rax, [rbx + JPE_VAL]
    PUSHV rax
    NEXT
.inherited:
    call jsobj_lookup
    jc .missing
    bt qword [rbx + JPE_KEY], 34
    jc .accessor
    mov rax, [rbx + JPE_VAL]
    PUSHV rax
    NEXT
.accessor:
    mov rax, [js_global]
    BOX rax, rcx, JS_OBJ_BITS
    VMCALL js_get
    PUSHV rax
    NEXT
.missing:
    mov rdi, rdx
    lea rsi, [jsmsg_not_defined]
    mov edx, JE_REFERENCE
    jmp js_throw

; vm_cache_index: RAX = object, RBX = its entry -> stores the entry index in
; the cache operand that ends at RSI
vm_cache_index:
    push rcx
    mov rcx, rbx
    sub rcx, [rax + JOBJ_PROPS]
    shr rcx, 4
    mov [rsi - 4], ecx
    pop rcx
    ret

vmop_SETGLOB:
    mov edx, [rsi]
    mov ecx, [rsi + 4]
    add rsi, 8
    mov rdi, [r12 - 8]              ; the value (stays)
    mov rax, [js_global]
    cmp ecx, [rax + JOBJ_COUNT]
    jae .slow
    mov rbx, [rax + JOBJ_PROPS]
    shl ecx, 4
    add rbx, rcx
    cmp [rbx + JPE_KEY], edx
    jne .slow
    test byte [rbx + JPE_KEY + 4], JPA_READONLY | JPA_ACCESSOR
    jnz .slow                       ; read-only (NaN, ...) or an accessor
    mov [rbx + JPE_VAL], rdi
.done:
    NEXT
.slow:
    mov rcx, rdi
    push rax
    BOX rax, rbx, JS_OBJ_BITS
    VMCALL js_put
    pop rax
    call jsobj_find_own
    jc .done
    call vm_cache_index
    NEXT

vmop_DECLGLOB:
    mov edx, [rsi]
    add rsi, 4
    mov rax, [js_global]
    call jsobj_find_own
    jnc .exists
    mov rcx, JS_UNDEF
    call jsobj_add
.exists:
    NEXT

vmop_TYPEOFGLOB:
    mov edx, [rsi]
    add rsi, 4
    mov rax, [js_global]
    call jsobj_lookup
    mov rax, JS_UNDEF
    jc .typeof
    mov rax, [rbx + JPE_VAL]
.typeof:
    call js_typeof
    BOX rax, rdx, JS_STR_BITS
    PUSHV rax
    NEXT

; GETPROP atom, cache: own properties of objects hit the cached index
vmop_GETPROP:
    mov edx, [rsi]
    mov ecx, [rsi + 4]
    add rsi, 8
    POPV rax
    mov rbx, rax
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    jne .generic
    mov edi, eax
    cmp ecx, [rdi + JOBJ_COUNT]
    jae .own
    mov rbx, [rdi + JOBJ_PROPS]
    shl ecx, 4
    add rbx, rcx
    cmp [rbx + JPE_KEY], edx
    jne .own
    bt qword [rbx + JPE_KEY], 34
    jc .generic                     ; an accessor
    mov rax, [rbx + JPE_VAL]
    PUSHV rax
    NEXT
.own:
    push rax
    mov rax, rdi
    call jsobj_find_own
    jc .not_own
    call vm_cache_index
    pop rax
    bt qword [rbx + JPE_KEY], 34
    jc .generic
    mov rax, [rbx + JPE_VAL]
    PUSHV rax
    NEXT
.not_own:
    pop rax
.generic:
    VMCALL js_get
    PUSHV rax
    NEXT

vmop_SETPROP:
    mov edx, [rsi]
    add rsi, 4
    POPV rcx
    POPV rax
    VMCALL js_put
    PUSHV rcx
    NEXT

vmop_GETELEM:
    POPV rdx
    POPV rax
    ; fast path: array[integer]
    mov rbx, rax
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    jne .generic
    mov ebx, eax
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .generic
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_SPECIAL
    jae .generic
    movq xmm0, rdx
    cvttsd2si rcx, xmm0
    mov edi, [rbx + JARR_LEN]
    cmp rcx, rdi                    ; also rejects negatives (unsigned)
    jae .generic
    cvtsi2sd xmm1, rcx
    ucomisd xmm0, xmm1
    jne .generic
    mov rdi, [rbx + JARR_ELEMS]
    mov rax, [rdi + rcx*8]
    mov rdi, JS_HOLE
    cmp rax, rdi
    jne .push
    mov rax, JS_UNDEF
.push:
    PUSHV rax
    NEXT
.generic:
    VMCALL js_get_elem
    PUSHV rax
    NEXT

vmop_SETELEM:
    POPV rcx
    POPV rdx
    POPV rax
    mov rbx, rax
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    jne .generic
    mov ebx, eax
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .generic
    mov rdi, rdx
    shr rdi, 48
    cmp edi, JS_TAG_SPECIAL
    jae .generic
    movq xmm0, rdx
    cvttsd2si rdi, xmm0
    mov r8d, [rbx + JARR_LEN]
    cmp rdi, r8                     ; also rejects negatives (unsigned)
    jae .generic
    cvtsi2sd xmm1, rdi
    ucomisd xmm0, xmm1
    jne .generic
    mov rax, [rbx + JARR_ELEMS]
    mov [rax + rdi*8], rcx
    PUSHV rcx
    NEXT
.generic:
    VMCALL js_put_elem
    PUSHV rcx
    NEXT

vmop_GETMETHOD:
    mov edx, [rsi]
    add rsi, 4
    mov rax, [r12 - 8]
    VMCALL js_get
    mov rdx, [r12 - 8]
    mov [r12 - 8], rax              ; f
    PUSHV rdx                       ; this
    NEXT

vmop_GETMETHODE:
    mov rdx, [r12 - 8]
    mov rax, [r12 - 16]
    VMCALL js_get_elem
    mov rdx, [r12 - 16]
    mov [r12 - 16], rax
    mov [r12 - 8], rdx
    NEXT

vmop_DELPROP:
    mov edx, [rsi]
    add rsi, 4
    BOX rdx, rax, JS_STR_BITS
    POPV rax
    VMCALL js_delete
    call js_bool
    PUSHV rax
    NEXT

vmop_DELELEM:
    POPV rdx
    POPV rax
    VMCALL js_delete
    call js_bool
    PUSHV rax
    NEXT

; CALL argc, name: [f][this][args] -> result
vmop_CALL:
    movzx ecx, byte [rsi]
    mov r9d, [rsi + 1]
    add rsi, 5
.common:                            ; ECX = argument count, R9D = name
    lea rax, [rcx*8 + 16]
    mov rbx, r12
    sub rbx, rax                    ; callee slot
    mov rax, [rbx]
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne vm_not_function
    mov edi, eax
    cmp byte [rdi + JH_KIND], JK_FUNC
    je .js
    cmp byte [rdi + JH_KIND], JK_NATIVE
    jne vm_not_function
    mov rax, [rdi + JFN_NATIVE]
    mov rdx, [rbx + 8]
    mov r10, rdi                    ; natives also get themselves
    lea rdi, [rbx + 16]
    xor r8d, r8d
    mov [vm_sp], r12
    call rax
    mov r12, rbx
    PUSHV rax
    NEXT
.js:
    mov rdx, [rdi + JFN_CODE]
    test byte [rdx + JCODE_FLAGS], JCF_CLASSCTOR
    jnz .class
    xor r8d, r8d
    call vm_enter_js
    NEXT
.class:
    lea rsi, [jsmsg_class_call]
    jmp vm_call_error

; vm_not_function: R9D = name atom (or 0)
vm_not_function:
    lea rsi, [jsmsg_not_function]
vm_call_error:
    mov edi, r9d
    test edi, edi
    jnz .named
    push rsi
    lea rsi, [jsmsg_value]
    call jsstr_from_cstr
    mov rdi, rax
    pop rsi
.named:
    jmp js_throw_type

; NEW argc, name: [f][undefined][args] -> new object
vmop_NEW:
    movzx ecx, byte [rsi]
    mov r9d, [rsi + 1]
    add rsi, 5
.common:
    lea rax, [rcx*8 + 16]
    mov rbx, r12
    sub rbx, rax
    mov rax, [rbx]
    call js_is_callable
    jnc .not_constructor
    ; arrow functions are not constructors
    mov edx, eax
    cmp byte [rdx + JH_KIND], JK_FUNC
    jne .constructor
    mov rdx, [rdx + JFN_CODE]
    test byte [rdx + JCODE_FLAGS], JCF_ARROW
    jnz .not_constructor
.constructor:
    ; this = a new object inheriting f.prototype
    push rcx
    mov rdx, [atom_prototype]
    VMCALL js_get
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    mov rdx, [js_object_proto]
    jne .proto
    mov edx, eax
.proto:
    mov rax, rdx
    call jsobj_new
    BOX rax, rdx, JS_OBJ_BITS
    mov [rbx + 8], rax
    pop rcx
    mov edi, [rbx]
    cmp byte [rdi + JH_KIND], JK_FUNC
    jne .native
    mov r8d, JFRF_CONSTRUCT
    call vm_enter_js
    NEXT
.native:
    mov rax, [rdi + JFN_NATIVE]
    mov rdx, [rbx + 8]
    mov r10, rdi                    ; natives also get themselves
    lea rdi, [rbx + 16]
    mov r8d, 1
    mov [vm_sp], r12
    call rax
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    je .result
    mov rax, [rbx + 8]
.result:
    mov r12, rbx
    PUSHV rax
    NEXT
.not_constructor:
    lea rsi, [jsmsg_not_constructor]
    jmp vm_call_error

vmop_RETUNDEF:
    mov rax, JS_UNDEF
    jmp vm_return
vmop_RET:
    POPV rax
vm_return:
    mov rdx, [vm_fp]
    test dword [rdx + JFR_FLAGS], JFRF_CONSTRUCT
    jz .value
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    je .value
    mov rax, [r13 - 8]              ; `new` returns this
.value:
    mov r12, [rdx + JFR_RESULT]
    mov rsi, [rdx + JFR_PC]
    mov r13, [rdx + JFR_BASE]
    mov r15, [rdx + JFR_FUNC]
    mov r14, [rdx + JFR_ENV]
    mov ecx, [rdx + JFR_LINE]
    mov [vm_line], ecx
    mov ecx, [rdx + JFR_FLAGS]
    sub rdx, JFR_SIZE
    mov [vm_fp], rdx
    test ecx, JFRF_BOUNDARY
    jnz .leave
    PUSHV rax
    NEXT
.leave:
    pop rbp
    ret

; --- arithmetic ---------------------------------------------------------------

; vm_numbers: pop b, a -> xmm0 = a, xmm1 = b (ToNumber)
%macro VM_NUMBERS 0
    POPV rdx
    POPV rax
    mov rcx, rax
    or rcx, rdx
    shr rcx, 48
    ; both numbers when neither tag reaches 0xFFF9 (OR of two tags can still be
    ; below it only if both are)
    cmp ecx, JS_TAG_SPECIAL
    jb %%fast
    mov [vm_sp], r12
    call js_to_number
    xchg rax, rdx
    call js_to_number
    xchg rax, rdx
%%fast:
    movq xmm0, rax
    movq xmm1, rdx
%endmacro

vmop_ADD:
    mov rax, [r12 - 16]
    mov rdx, [r12 - 8]
    mov rcx, rax
    or rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_SPECIAL
    jae .slow
    sub r12, 8
    movq xmm0, rax
    movq xmm1, rdx
    addsd xmm0, xmm1
    movq [r12 - 8], xmm0
    NEXT
.slow:
    sub r12, 16
    VMCALL js_add
    PUSHV rax
    NEXT

vmop_SUB:
    VM_NUMBERS
    subsd xmm0, xmm1
    movq rax, xmm0
    PUSHV rax
    NEXT
vmop_MUL:
    VM_NUMBERS
    mulsd xmm0, xmm1
    movq rax, xmm0
    PUSHV rax
    NEXT
vmop_DIV:
    VM_NUMBERS
    divsd xmm0, xmm1
    movq rax, xmm0
    PUSHV rax
    NEXT
vmop_MOD:
    VM_NUMBERS
    call js_mod
    PUSHV rax
    NEXT
vmop_POW:
    VM_NUMBERS
    xchg rax, rdx                   ; jsb_pow: RDX = base, RAX = exponent
    call jsb_pow
    PUSHV rax
    NEXT

; --- bitwise: operands are ToInt32 ------------------------------------------------
%macro VM_INT32S 0                  ; -> EAX = a, EDX = b (as int32), ECX spare
    POPV rdx
    POPV rax
    mov [vm_sp], r12
    call js_to_int32
    xchg rax, rdx
    call js_to_int32
    xchg rax, rdx
%endmacro

%macro VM_PUSH_INT32 0              ; EAX = int32 result
    movsxd rax, eax
    cvtsi2sd xmm0, rax
    movq rax, xmm0
    PUSHV rax
    NEXT
%endmacro

vmop_BAND:
    VM_INT32S
    and eax, edx
    VM_PUSH_INT32
vmop_BOR:
    VM_INT32S
    or eax, edx
    VM_PUSH_INT32
vmop_BXOR:
    VM_INT32S
    xor eax, edx
    VM_PUSH_INT32
vmop_SHL:
    VM_INT32S
    mov ecx, edx
    shl eax, cl
    VM_PUSH_INT32
vmop_SAR:
    VM_INT32S
    mov ecx, edx
    sar eax, cl
    VM_PUSH_INT32
vmop_SHR:
    VM_INT32S
    mov ecx, edx
    shr eax, cl
    mov eax, eax                    ; unsigned result
    cvtsi2sd xmm0, rax
    movq rax, xmm0
    PUSHV rax
    NEXT

; --- comparisons -----------------------------------------------------------------
vmop_SEQ:
    POPV rdx
    POPV rax
    call js_strict_equal
    call js_bool
    PUSHV rax
    NEXT
vmop_SNE:
    POPV rdx
    POPV rax
    call js_strict_equal
    cmc
    call js_bool
    PUSHV rax
    NEXT
vmop_EQ:
    POPV rdx
    POPV rax
    VMCALL js_loose_equal
    call js_bool
    PUSHV rax
    NEXT
vmop_NE:
    POPV rdx
    POPV rax
    VMCALL js_loose_equal
    cmc
    call js_bool
    PUSHV rax
    NEXT

; VM_COMPARE cc: numbers fast, else js_less
%macro VM_COMPARE 2                 ; %1 = setcc for numbers (a ? b), %2 = slow kind
    mov rax, [r12 - 16]
    mov rdx, [r12 - 8]
    sub r12, 16
    mov rcx, rax
    or rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_SPECIAL
    jae %%slow
    movq xmm0, rax
    movq xmm1, rdx
    xor eax, eax
    ucomisd xmm0, xmm1
    jp %%push                       ; NaN: false
    %1 al
    jmp %%push
%%slow:
    mov [vm_sp], r12
%if %2 == 0                         ; a < b
    call js_less
    cmp eax, 1
    sete al
%elif %2 == 1                       ; a > b  ==  b < a
    xchg rax, rdx
    call js_less
    cmp eax, 1
    sete al
%elif %2 == 2                       ; a <= b ==  !(b < a) and not undefined
    xchg rax, rdx
    call js_less
    test eax, eax
    sete al
%else                               ; a >= b ==  !(a < b) and not undefined
    call js_less
    test eax, eax
    sete al
%endif
%%push:
    movzx eax, al
    mov rdx, JS_FALSE
    add rax, rdx
    PUSHV rax
    NEXT
%endmacro

vmop_LT:
    VM_COMPARE setb, 0
vmop_GT:
    VM_COMPARE seta, 1
vmop_LE:
    VM_COMPARE setbe, 2
vmop_GE:
    VM_COMPARE setae, 3

vmop_INSTANCEOF:
    POPV rdx
    POPV rax
    VMCALL js_instanceof
    call js_bool
    PUSHV rax
    NEXT

vmop_IN:
    POPV rdx
    POPV rax
    VMCALL js_in
    call js_bool
    PUSHV rax
    NEXT

; --- unary -----------------------------------------------------------------------
vmop_NEG:
    POPV rax
    VMCALL js_to_number
    btc rax, 63
    PUSHV rax
    NEXT
vmop_PLUS:
vmop_TONUM:
    POPV rax
    VMCALL js_to_number
    PUSHV rax
    NEXT
vmop_NOT:
    POPV rax
    call js_truthy
    cmc
    call js_bool
    PUSHV rax
    NEXT
vmop_BNOT:
    POPV rax
    VMCALL js_to_int32
    not eax
    VM_PUSH_INT32
vmop_TYPEOF:
    POPV rax
    call js_typeof
    BOX rax, rdx, JS_STR_BITS
    PUSHV rax
    NEXT
vmop_INC:
    POPV rax
    VMCALL js_to_number
    movq xmm0, rax
    addsd xmm0, [jsvm_one]
    movq rax, xmm0
    PUSHV rax
    NEXT
vmop_DEC:
    POPV rax
    VMCALL js_to_number
    movq xmm0, rax
    subsd xmm0, [jsvm_one]
    movq rax, xmm0
    PUSHV rax
    NEXT

; --- jumps -----------------------------------------------------------------------
vmop_JMP:
    movsxd rax, dword [rsi]
    lea rsi, [rsi + rax + 4]
    test rax, rax
    jns .next
    dec dword [vm_budget]           ; a loop: check for Ctrl+C now and then
    jnz .next
    mov [vm_sp], r12
    call vm_check_budget
.next:
    NEXT

vmop_JF:
    POPV rax
    call js_truthy
    jc vm_no_jump
vm_jump:
    movsxd rax, dword [rsi]
    lea rsi, [rsi + rax + 4]
    NEXT
vm_no_jump:
    add rsi, 4
    NEXT

vmop_JT:
    POPV rax
    call js_truthy
    jc vm_jump
    jmp vm_no_jump

vmop_JFK:                           ; &&: falsy -> jump keeping it
    mov rax, [r12 - 8]
    call js_truthy
    jnc vm_jump
    sub r12, 8
    jmp vm_no_jump

vmop_JTK:                           ; ||: truthy -> jump keeping it
    mov rax, [r12 - 8]
    call js_truthy
    jc vm_jump
    sub r12, 8
    jmp vm_no_jump

vmop_JNNK:                          ; ??: not null/undefined -> jump keeping it
    mov rax, [r12 - 8]
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jne vm_jump
    cmp eax, 2
    jae vm_jump
    sub r12, 8
    jmp vm_no_jump

; --- literals ----------------------------------------------------------------------
vmop_OBJECT:
    call jsobj_new_plain
    BOX rax, rdx, JS_OBJ_BITS
    PUSHV rax
    NEXT

vmop_INITPROP:
    mov edx, [rsi]
    add rsi, 4
    POPV rcx
    mov eax, [r12 - 8]
    call jsobj_define
    NEXT

vmop_INITELEM:
    POPV rcx
    POPV rax
    mov [vm_sp], r12
    call js_to_key
    mov edx, eax
    mov eax, [r12 - 8]
    call jsobj_define
    NEXT

vmop_ARRAY:
    xor ecx, ecx
    call jsarr_new
    BOX rax, rdx, JS_OBJ_BITS
    PUSHV rax
    NEXT

vmop_APPEND:
    POPV rcx
    mov eax, [r12 - 8]
    call jsarr_push
    NEXT

vmop_CLOSURE:
    mov eax, [rsi]
    add rsi, 4
    mov rdx, r14
    call jsfn_new
    mov rdx, [rax + JFN_CODE]
    test byte [rdx + JCODE_FLAGS], JCF_ARROW
    jz .box
    mov rdx, [r13 - 8]              ; the `this` it will always have
    mov [rax + JFN_THIS], rdx
    mov rdx, [r15 + JFN_HOME]       ; and super
    mov [rax + JFN_HOME], rdx
.box:
    BOX rax, rdx, JS_OBJ_BITS
    PUSHV rax
    NEXT

; --- environments -------------------------------------------------------------------
vmop_ENTERENV:
    movzx ecx, word [rsi]
    add rsi, 2
    push rcx
    lea ecx, [rcx*8 + JENV_VALS]
    call js_alloc
    pop rcx
    mov byte [rax + JH_KIND], JK_ENV
    mov [rax + JENV_COUNT], ecx
    mov [rax + JENV_PARENT], r14
    mov rdx, JS_UNDEF
.fill:
    test ecx, ecx
    jz .done
    dec ecx
    mov [rax + JENV_VALS + rcx*8], rdx
    jmp .fill
.done:
    mov r14, rax
    NEXT

vmop_LEAVEENV:
    mov r14, [r14 + JENV_PARENT]
    NEXT

vmop_COPYENV:
    mov ecx, [r14 + JENV_COUNT]
    push rcx
    lea ecx, [rcx*8 + JENV_VALS]
    call js_alloc
    mov rdi, rax
    mov rdx, rsi
    mov rsi, r14
    rep movsb
    mov rsi, rdx
    pop rcx
    mov r14, rax
    NEXT

; --- iteration -------------------------------------------------------------------------
vmop_FORIN:
    POPV rax
    VMCALL js_forin_keys
    BOX rax, rdx, JS_OBJ_BITS
    mov bl, JIM_KEYS
    jmp vm_new_iter

vmop_FOROF:
    POPV rax
    mov rdx, rax
    shr rdx, 48
    mov bl, JIM_STRING
    cmp edx, JS_TAG_STRING
    je vm_new_iter
    cmp edx, JS_TAG_OBJECT
    jne .not_iterable
    mov edx, eax
    mov bl, JIM_ARRAY
    cmp byte [rdx + JH_KIND], JK_ARRAY
    je vm_new_iter
.not_iterable:
    mov [vm_sp], r12
    call js_to_string
    mov rdi, rax
    lea rsi, [jsmsg_not_iterable]
    jmp js_throw_type

; vm_new_iter: RAX = source value, BL = JIM_* -> pushes the iterator
vm_new_iter:
    mov rdx, rax
    mov ecx, JIT_SIZE
    call js_alloc
    mov byte [rax + JH_KIND], JK_ITER
    mov [rax + JIT_MODE], bl
    mov [rax + JIT_SRC], rdx
    BOX rax, rdx, JS_OBJ_BITS
    PUSHV rax
    NEXT

vmop_ITERNEXT:
    mov ebx, [r12 - 8]              ; the iterator
    mov ecx, [rbx + JIT_POS]
    mov edx, [rbx + JIT_SRC]        ; array or string
    cmp byte [rbx + JIT_MODE], JIM_STRING
    je .string
    cmp ecx, [rdx + JARR_LEN]
    jae vm_jump
    mov rdi, [rdx + JARR_ELEMS]
    mov rax, [rdi + rcx*8]
    mov rdi, JS_HOLE
    cmp rax, rdi
    jne .value
    mov rax, JS_UNDEF
    jmp .value
.string:
    cmp ecx, [rdx + JSTR_LEN]
    jae vm_jump
    movzx eax, byte [rdx + JSTR_DATA + rcx]
    call jsstr_char
    BOX rax, rdi, JS_STR_BITS
.value:
    inc dword [rbx + JIT_POS]
    PUSHV rax
    add rsi, 4
    NEXT

; --- misc ---------------------------------------------------------------------------------
vmop_THROW:
    POPV rax
    jmp js_throw_value

vmop_LINE:
    mov eax, [rsi]
    add rsi, 4
    mov [vm_line], eax
    NEXT

vmop_COMPLETION:
    POPV rax
    mov [vm_completion], rax
    NEXT

vmop_GETCOMPL:
    mov rax, [vm_completion]
    PUSHV rax
    NEXT

vmop_TOSTR:
    POPV rax
    VMCALL js_to_string
    BOX rax, rdx, JS_STR_BITS
    PUSHV rax
    NEXT

vmop_SPREAD:
    POPV rdx
    mov eax, [r12 - 8]
    VMCALL js_spread_into
    NEXT

vmop_OBJSPREAD:
    POPV rdx
    mov eax, [r12 - 8]
    VMCALL js_copy_props
    NEXT

; CALLA / NEWA name32: [f][this][array] -> the array's items as arguments
vmop_CALLA:
    mov r9d, [rsi]
    add rsi, 4
    call vm_spread_args
    jmp vmop_CALL.common
vmop_NEWA:
    mov r9d, [rsi]
    add rsi, 4
    call vm_spread_args
    jmp vmop_NEW.common

; vm_spread_args: the array on top of the stack -> its items in its place,
; ECX = how many
vm_spread_args:
    POPV rax
    mov eax, eax
    mov ecx, [rax + JARR_LEN]
    lea rdx, [r12 + rcx*8 + 32768]
    cmp rdx, JS_STACK_ADDR + JS_STACK_SIZE
    jae vm_stack_overflow
    mov rdi, [rax + JARR_ELEMS]
    xor edx, edx
    mov r8, JS_HOLE
.item:
    cmp edx, ecx
    jae .done
    mov rax, [rdi + rdx*8]
    cmp rax, r8
    jne .push
    mov rax, JS_UNDEF
.push:
    PUSHV rax
    inc edx
    jmp .item
.done:
    ret

vmop_JNULLISH:
    mov rax, [r12 - 8]
    call vm_nullish
    jnc vm_no_jump
    mov rax, JS_UNDEF
    mov [r12 - 8], rax
    jmp vm_jump

vmop_JNULLCALL:
    mov rax, [r12 - 16]
    call vm_nullish
    jnc vm_no_jump
    sub r12, 16
    mov rax, JS_UNDEF
    PUSHV rax
    jmp vm_jump

; vm_nullish: RAX = value -> CF=1 for null / undefined
vm_nullish:
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jne .no
    cmp eax, 1
    ja .no
    pop rdx
    stc
    ret
.no:
    pop rdx
    clc
    ret

vmop_ARRREST:
    mov edx, [rsi]
    add rsi, 4
    POPV rax
    VMCALL js_array_rest
    PUSHV rax
    NEXT

vmop_OBJREST:
    movzx ecx, word [rsi]
    add rsi, 2
    lea rax, [rcx*8]
    sub r12, rax                    ; the keys are at [R12], the object below
    mov rdi, r12
    mov rax, [r12 - 8]
    VMCALL js_object_rest
    mov [r12 - 8], rax
    NEXT

; INITGET / INITSET atom32: [obj f] -> [obj]
vmop_INITGET:
    mov r8d, 1
    jmp vm_init_accessor
vmop_INITSET:
    mov r8d, 2
vm_init_accessor:
    mov edx, [rsi]
    add rsi, 4
    POPV rcx
    mov eax, [r12 - 8]
    call jsobj_define_accessor
    NEXT

; CLASS u8 flags, code32: [parent] -> the constructor, with its prototype
vmop_CLASS:
    movzx ebx, byte [rsi]
    mov edi, [rsi + 1]              ; the constructor's code
    add rsi, 5
    mov r8, [js_object_proto]       ; the prototype's prototype
    xor r9d, r9d                    ; the parent constructor (raw), 0 = none
    test ebx, 1
    jz .make
    POPV rax
    mov rdx, JS_NULL
    cmp rax, rdx
    je .null_parent
    call js_is_callable
    jnc .bad_parent
    mov r9d, eax
    mov rdx, [atom_prototype]
    VMCALL js_get
    mov rdx, rax
    shr rdx, 48
    xor r8d, r8d
    cmp edx, JS_TAG_OBJECT
    jne .make                       ; (null)
    mov r8d, eax
    jmp .make
.null_parent:
    xor r8d, r8d
.make:
    mov rax, rdi
    mov rdx, r14
    call jsfn_new
    mov rbx, rax                    ; the constructor
    mov rax, r8
    call jsobj_new
    mov rdi, rax                    ; its prototype object
    mov rcx, rbx
    BOX rcx, rdx, JS_OBJ_BITS
    mov rdx, [atom_constructor]
    call jsobj_define_hidden
    mov rax, rdi
    BOX rax, rdx, JS_OBJ_BITS
    mov [rbx + JFN_PROTO_OBJ], rax
    mov [rbx + JFN_HOME], rdi
    test r9, r9
    jz .push
    mov [rbx + JOBJ_PROTO], r9      ; statics are inherited too
.push:
    mov rax, rbx
    BOX rax, rdx, JS_OBJ_BITS
    PUSHV rax
    NEXT
.bad_parent:
    mov [vm_sp], r12
    call js_to_string
    mov rdi, rax
    lea rsi, [jsmsg_extends]
    jmp js_throw_type

; METHOD atom32, u8 kind: [target f] -> []
vmop_METHOD:
    mov edx, [rsi]
    movzx r8d, byte [rsi + 4]
    add rsi, 5
    POPV rcx
    POPV rax
    call vm_define_method
    NEXT

; METHODE u8 kind: [target key f] -> []
vmop_METHODE:
    movzx r8d, byte [rsi]
    inc rsi
    POPV rcx
    POPV rax
    mov [vm_sp], r12
    call js_to_key
    mov edx, eax
    POPV rax
    call vm_define_method
    NEXT

; vm_define_method: RAX = target (value), EDX = key atom, RCX = function,
; R8D = 0 method / 1 getter / 2 setter -> defined (not enumerable), with the
; target as the function's home object (super)
vm_define_method:
    push rax
    push rdx
    mov eax, eax
    mov rdx, rcx
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .define
    mov edx, ecx
    cmp byte [rdx + JH_KIND], JK_FUNC
    jne .define
    mov [rdx + JFN_HOME], rax
.define:
    mov edx, [rsp]
    test r8d, r8d
    jnz .accessor
    call jsobj_define_hidden
    jmp .out
.accessor:
    bts rdx, 32                     ; hidden
    call jsobj_define_accessor
.out:
    pop rdx
    pop rax
    ret

; SUPERFN: -> the parent constructor (the prototype of the running function)
vmop_SUPERFN:
    mov rax, [r15 + JOBJ_PROTO]
    test rax, rax
    jz .null
    BOX rax, rdx, JS_OBJ_BITS
    PUSHV rax
    NEXT
.null:
    mov rax, JS_NULL
    PUSHV rax
    NEXT

; SUPERCALL u8 n, name32: [parent][this][args] -> result. Like CALL, but a
; class constructor may be called, and natives fill in `this` (R8D = 2)
vmop_SUPERCALL:
    movzx ecx, byte [rsi]
    mov r9d, [rsi + 1]
    add rsi, 5
.common:
    lea rax, [rcx*8 + 16]
    mov rbx, r12
    sub rbx, rax
    mov rax, [rbx]
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne vm_not_function
    mov edi, eax
    cmp byte [rdi + JH_KIND], JK_FUNC
    je .js
    cmp byte [rdi + JH_KIND], JK_NATIVE
    jne vm_not_function
    mov rax, [rdi + JFN_NATIVE]
    mov rdx, [rbx + 8]
    mov r10, rdi                    ; natives also get themselves
    lea rdi, [rbx + 16]
    mov r8d, 2
    mov [vm_sp], r12
    call rax
    mov r12, rbx
    PUSHV rax
    NEXT
.js:
    xor r8d, r8d
    call vm_enter_js
    NEXT

vmop_SUPERCALLA:
    mov r9d, [rsi]
    add rsi, 4
    call vm_spread_args
    jmp vmop_SUPERCALL.common

; SUPERGET atom32: -> super.name (on the prototype of the method's home object)
vmop_SUPERGET:
    mov edx, [rsi]
    add rsi, 4
    mov rax, [r15 + JFN_HOME]
    test rax, rax
    jz .bad
    mov rax, [rax + JOBJ_PROTO]
    test rax, rax
    jz .undefined
    BOX rax, rcx, JS_OBJ_BITS
    VMCALL js_get
    PUSHV rax
    NEXT
.undefined:
    mov rax, JS_UNDEF
    PUSHV rax
    NEXT
.bad:
    mov edx, JE_SYNTAX
    lea rsi, [jsmsg_super]
    xor edi, edi
    jmp js_throw

; TRY rel32: a handler for exceptions until ENDTRY
vmop_TRY:
    mov ecx, [vm_handler_count]
    cmp ecx, JSVM_MAX_HANDLERS
    jae .too_many
    imul rbx, rcx, JTH_SIZE
    lea rdx, [vm_handlers]
    add rbx, rdx
    movsxd rax, dword [rsi]
    lea rax, [rsi + rax + 4]
    mov [rbx + JTH_PC], rax
    mov [rbx + JTH_SP], r12
    mov [rbx + JTH_BASE], r13
    mov [rbx + JTH_ENV], r14
    mov [rbx + JTH_FUNC], r15
    mov rax, [vm_fp]
    mov [rbx + JTH_FP], rax
    mov [rbx + JTH_RSP], rsp
    mov eax, [vm_nesting]
    mov [rbx + JTH_NEST], eax
    mov eax, [js_depth]
    mov [rbx + JTH_DEPTH], eax
    inc ecx
    mov [vm_handler_count], ecx
    add rsi, 4
    NEXT
.too_many:
    mov edx, JE_RANGE
    lea rsi, [jsmsg_handlers]
    xor edi, edi
    jmp js_throw

vmop_ENDTRY:
    dec dword [vm_handler_count]
    NEXT

vmop_CONSTERR:
    lea rsi, [jsmsg_const]
    xor edi, edi
    jmp js_throw_type
