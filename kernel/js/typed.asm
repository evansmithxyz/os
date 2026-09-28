; ==============================================================================
; Antigravity OS - JavaScript: ArrayBuffer, typed arrays and DataView
; ------------------------------------------------------------------------------
; An ArrayBuffer holds its bytes in a block of their own (GCF_LEAF). A typed
; array (Int8Array ... Float64Array) is a view of part of one: js_get / js_put
; and the element operations come here for its indexes (jsta_get, jsta_put,
; ...); length, byteLength, byteOffset and buffer are its own properties. The
; list methods (map, forEach, ...) are in the prelude (kernel/js/prelude.js).
; ==============================================================================

[bits 64]

; ArrayBuffer (JC_ARRAYBUFFER)
JAB_DATA                equ JOBJ_SIZE           ; raw: the bytes
JAB_LEN                 equ JOBJ_SIZE + 8       ; dword
JAB_SIZE                equ JOBJ_SIZE + 16
; typed array (JC_TYPED)
JTA_BUFFER              equ JOBJ_SIZE           ; raw: the ArrayBuffer
JTA_DATA                equ JOBJ_SIZE + 8       ; raw: its first element
JTA_LEN                 equ JOBJ_SIZE + 16      ; dword: elements
JTA_OFFSET              equ JOBJ_SIZE + 20      ; dword: byte offset in the buffer
JTA_KIND                equ JOBJ_SIZE + 24      ; byte: TA_*
JTA_SIZE                equ JOBJ_SIZE + 32
; DataView (JC_DATAVIEW)
JDV_BUFFER              equ JOBJ_SIZE
JDV_DATA                equ JOBJ_SIZE + 8
JDV_LEN                 equ JOBJ_SIZE + 16      ; dword
JDV_SIZE                equ JOBJ_SIZE + 24

TA_INT8                 equ 0
TA_UINT8                equ 1
TA_UINT8C               equ 2
TA_INT16                equ 3
TA_UINT16               equ 4
TA_INT32                equ 5
TA_UINT32               equ 6
TA_FLOAT32              equ 7
TA_FLOAT64              equ 8
TA_KINDS                equ 9

section .bss
alignb 8
jsta_buffer_proto:      resq 1
jsta_buffer_ctor:       resq 1
jsta_proto:             resq 1          ; %TypedArray%.prototype
jsta_dataview_proto:    resq 1
jsta_dataview_ctor:     resq 1
jsta_protos:            resq TA_KINDS   ; Int8Array.prototype ... (TA_* order)
jsta_ctors:             resq TA_KINDS

section .rodata
jsta_ctor_list:
JSCTOR jsta_buffer_ctor, jsta_array_buffer, 1, jsta_buffer_proto, "ArrayBuffer"
JSCTOR jsta_dataview_ctor, jsta_data_view, 1, jsta_dataview_proto, "DataView"
JSCTOR jsta_ctors + 0, jsta_new_int8, 3, jsta_protos + 0, "Int8Array"
JSCTOR jsta_ctors + 8, jsta_new_uint8, 3, jsta_protos + 8, "Uint8Array"
JSCTOR jsta_ctors + 16, jsta_new_uint8c, 3, jsta_protos + 16, "Uint8ClampedArray"
JSCTOR jsta_ctors + 24, jsta_new_int16, 3, jsta_protos + 24, "Int16Array"
JSCTOR jsta_ctors + 32, jsta_new_uint16, 3, jsta_protos + 32, "Uint16Array"
JSCTOR jsta_ctors + 40, jsta_new_int32, 3, jsta_protos + 40, "Int32Array"
JSCTOR jsta_ctors + 48, jsta_new_uint32, 3, jsta_protos + 48, "Uint32Array"
JSCTOR jsta_ctors + 56, jsta_new_float32, 3, jsta_protos + 56, "Float32Array"
JSCTOR jsta_ctors + 64, jsta_new_float64, 3, jsta_protos + 64, "Float64Array"
    dq 0

jsta_natives:
JSNATIVE jsta_buffer_ctor, "isView", jsta_is_view, 1
JSNATIVE jsta_buffer_proto, "slice", jsta_buffer_slice, 2
JSNATIVE jsta_proto, "subarray", jsta_subarray, 2
JSNATIVE jsta_proto, "set", jsta_set, 1
JSNATIVE js_global, "__bytesToString", jsta_bytes_to_string, 1
JSNATIVE jsta_dataview_proto, "getInt8", jsdv_get_int8, 1
JSNATIVE jsta_dataview_proto, "getUint8", jsdv_get_uint8, 1
JSNATIVE jsta_dataview_proto, "getInt16", jsdv_get_int16, 2
JSNATIVE jsta_dataview_proto, "getUint16", jsdv_get_uint16, 2
JSNATIVE jsta_dataview_proto, "getInt32", jsdv_get_int32, 2
JSNATIVE jsta_dataview_proto, "getUint32", jsdv_get_uint32, 2
JSNATIVE jsta_dataview_proto, "getFloat32", jsdv_get_float32, 2
JSNATIVE jsta_dataview_proto, "getFloat64", jsdv_get_float64, 2
JSNATIVE jsta_dataview_proto, "setInt8", jsdv_set_int8, 2
JSNATIVE jsta_dataview_proto, "setUint8", jsdv_set_uint8, 2
JSNATIVE jsta_dataview_proto, "setInt16", jsdv_set_int16, 3
JSNATIVE jsta_dataview_proto, "setUint16", jsdv_set_uint16, 3
JSNATIVE jsta_dataview_proto, "setInt32", jsdv_set_int32, 3
JSNATIVE jsta_dataview_proto, "setUint32", jsdv_set_uint32, 3
JSNATIVE jsta_dataview_proto, "setFloat32", jsdv_set_float32, 3
JSNATIVE jsta_dataview_proto, "setFloat64", jsdv_set_float64, 3
    dq 0

jsta_shift:             db 0, 0, 0, 1, 1, 2, 2, 2, 3    ; log2 of the element size
jsta_kind_names:        dq jsta_name_int8, jsta_name_uint8, jsta_name_uint8c, jsta_name_int16, jsta_name_uint16
                        dq jsta_name_int32, jsta_name_uint32, jsta_name_float32, jsta_name_float64
jsta_name_int8:         db "Int8Array", 0
jsta_name_uint8:        db "Uint8Array", 0
jsta_name_uint8c:       db "Uint8ClampedArray", 0
jsta_name_int16:        db "Int16Array", 0
jsta_name_uint16:       db "Uint16Array", 0
jsta_name_int32:        db "Int32Array", 0
jsta_name_uint32:       db "Uint32Array", 0
jsta_name_float32:      db "Float32Array", 0
jsta_name_float64:      db "Float64Array", 0
jsta_str_byte_length:   db "byteLength", 0
jsta_str_byte_offset:   db "byteOffset", 0
jsta_str_buffer:        db "buffer", 0
jsmsg_ta_new:           db "Constructor requires 'new'", 0
jsmsg_ta_length:        db "Invalid typed array length", 0
jsmsg_ta_offset:        db "Start offset of the view is outside the bounds of the buffer, or not a multiple of the element size", 0
jsmsg_ta_buffer:        db "Invalid array buffer length", 0
jsmsg_dv_buffer:        db "First argument to DataView constructor must be an ArrayBuffer", 0
jsmsg_dv_offset:        db "Offset is outside the bounds of the DataView", 0
jsmsg_ta_this:          db "this is not a typed array", 0

section .bss
alignb 8
jsta_atom_byte_length:  resq 1
jsta_atom_byte_offset:  resq 1
jsta_atom_buffer:       resq 1

section .text

; ------------------------------------------------------------------------------
; jsta_init: the constructors and prototypes
; ------------------------------------------------------------------------------
jsta_init:
    push rax
    push rbx
    push rcx
    push rsi
    push r8
    mov rax, [js_object_proto]
    call jsobj_new
    mov [jsta_buffer_proto], rax
    mov rax, [js_object_proto]
    call jsobj_new
    mov [jsta_dataview_proto], rax
    mov rax, [js_object_proto]
    call jsobj_new
    mov [jsta_proto], rax
    xor ebx, ebx
.proto:
    mov rax, [jsta_proto]
    call jsobj_new
    mov [jsta_protos + rbx*8], rax
    inc ebx
    cmp ebx, TA_KINDS
    jb .proto
    lea r8, [jsta_ctor_list]
    call jsb_define_ctors
    lea r8, [jsta_natives]
    call jsb_define_natives
    lea rsi, [jsta_str_byte_length]
    call jsstr_from_cstr
    call jsstr_intern
    mov [jsta_atom_byte_length], rax
    lea rsi, [jsta_str_byte_offset]
    call jsstr_from_cstr
    call jsstr_intern
    mov [jsta_atom_byte_offset], rax
    lea rsi, [jsta_str_buffer]
    call jsstr_from_cstr
    call jsstr_intern
    mov [jsta_atom_buffer], rax
    pop r8
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; jsta_need_new: R8D = 1 under new, else TypeError
jsta_need_new:
    cmp r8d, 1
    jne .no
    ret
.no:
    lea rsi, [jsmsg_ta_new]
    xor edi, edi
    jmp js_throw_type

; jsta_range_error: RSI = message
jsta_range_error:
    xor edi, edi
    mov edx, JE_RANGE
    jmp js_throw

; jsta_define: RAX = object (raw), RDX = atom, RCX = value -> a hidden,
; read-only own property
jsta_define:
    push rdx
    mov edx, edx
    bts rdx, 32                     ; hidden
    bts rdx, 33                     ; read-only
    call jsobj_define
    pop rdx
    ret

; ------------------------------------------------------------------------------
; ArrayBuffer
; ------------------------------------------------------------------------------

; jsta_buffer_new: ECX = byte length -> RAX = a zeroed ArrayBuffer (raw)
jsta_buffer_new:
    push rbx
    push rcx
    push rdx
    push rdi
    mov ebx, ecx
    lea ecx, [rbx + 8]
    call js_alloc
    or byte [rax - 8 + GCH_FLAGS], GCF_LEAF
    mov rdi, rax
    push rax
    lea ecx, [rbx + 8]
    xor eax, eax
    rep stosb
    pop rdi                         ; the bytes
    mov ecx, JAB_SIZE
    call js_alloc
    mov byte [rax + JH_KIND], JK_OBJECT
    mov dword [rax + JOBJ_CLASS], JC_ARRAYBUFFER
    mov rcx, [jsta_buffer_proto]
    mov [rax + JOBJ_PROTO], rcx
    mov [rax + JAB_DATA], rdi
    mov [rax + JAB_LEN], ebx
    push rax
    mov eax, ebx
    call jsb_from_int
    mov rcx, rax
    pop rax
    mov rdx, [jsta_atom_byte_length]
    call jsta_define
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; new ArrayBuffer(byteLength)
jsta_array_buffer:
    push rcx
    call jsta_need_new
    xor eax, eax
    call jsb_arg_integer
    test rax, rax
    js .bad
    cmp rax, 0x4000000
    ja .bad
    mov ecx, eax
    call jsta_buffer_new
    BOX rax, rcx, JS_OBJ_BITS
    pop rcx
    ret
.bad:
    lea rsi, [jsmsg_ta_buffer]
    jmp jsta_range_error

; jsta_class_of: RAX = value -> ECX = its JOBJ_CLASS (objects), else -1
jsta_class_of:
    push rax
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .none
    mov eax, eax
    cmp byte [rax + JH_KIND], JK_OBJECT
    jne .none
    mov ecx, [rax + JOBJ_CLASS]
    pop rax
    ret
.none:
    mov ecx, -1
    pop rax
    ret

; ArrayBuffer.isView(value)
jsta_is_view:
    push rcx
    xor eax, eax
    call jsb_arg
    call jsta_class_of
    cmp ecx, JC_TYPED
    je .yes
    cmp ecx, JC_DATAVIEW
    je .yes
    clc
    jmp .out
.yes:
    stc
.out:
    call js_bool
    pop rcx
    ret

; jsta_clamp_range: RAX = begin, RDX = end (relative, signed), ECX = length
; -> EAX = start, EDX = end (0 <= start <= end <= length)
jsta_clamp_range:
    test rax, rax
    jns .begin_pos
    add rax, rcx
    jns .begin_pos
    xor eax, eax
.begin_pos:
    cmp rax, rcx
    jbe .begin_ok
    mov rax, rcx
.begin_ok:
    test rdx, rdx
    jns .end_pos
    add rdx, rcx
    jns .end_pos
    xor edx, edx
.end_pos:
    cmp rdx, rcx
    jbe .end_ok
    mov rdx, rcx
.end_ok:
    cmp rdx, rax
    jae .ok
    mov rdx, rax
.ok:
    ret

; ArrayBuffer.prototype.slice(begin, end): a copy of those bytes
jsta_buffer_slice:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r10d, ecx                   ; argument count
    mov rax, rdx
    call jsta_class_of
    cmp ecx, JC_ARRAYBUFFER
    jne .bad
    mov r8d, edx                    ; the buffer (raw)
    mov ecx, r10d
    mov eax, 1
    call jsb_arg_integer
    mov r9, rax
    jnc .end_given
    mov r9d, [r8 + JAB_LEN]
.end_given:
    mov ecx, r10d
    xor eax, eax
    call jsb_arg_integer
    mov rdx, r9
    mov ecx, [r8 + JAB_LEN]
    call jsta_clamp_range
    mov ebx, eax                    ; start
    mov ecx, edx
    sub ecx, eax                    ; count
    call jsta_buffer_new
    push rax
    mov rdi, [rax + JAB_DATA]
    mov rsi, [r8 + JAB_DATA]
    add rsi, rbx
    rep movsb
    pop rax
    BOX rax, rcx, JS_OBJ_BITS
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
    lea rsi, [jsmsg_ta_this]
    xor edi, edi
    jmp js_throw_type

; ------------------------------------------------------------------------------
; Typed arrays
; ------------------------------------------------------------------------------

; jsta_view_new: EBX = kind, RSI = ArrayBuffer (raw), EDX = byte offset,
; ECX = length (elements) -> RAX = the typed array (raw)
jsta_view_new:
    push rcx
    push rdx
    push rdi
    push rcx
    mov ecx, JTA_SIZE
    call js_alloc
    pop rcx
    mov byte [rax + JH_KIND], JK_OBJECT
    mov dword [rax + JOBJ_CLASS], JC_TYPED
    mov rdi, [jsta_protos + rbx*8]
    mov [rax + JOBJ_PROTO], rdi
    mov [rax + JTA_BUFFER], rsi
    mov rdi, [rsi + JAB_DATA]
    add rdi, rdx
    mov [rax + JTA_DATA], rdi
    mov [rax + JTA_LEN], ecx
    mov [rax + JTA_OFFSET], edx
    mov [rax + JTA_KIND], bl
    ; own properties: length, byteLength, byteOffset, buffer
    push rax
    mov rdi, rax
    mov eax, ecx
    call jsb_from_int
    mov rcx, rax
    mov rax, rdi
    mov rdx, [atom_length]
    call jsta_define
    mov eax, [rdi + JTA_LEN]
    push rcx
    mov cl, [jsta_shift + rbx]
    shl eax, cl
    pop rcx
    call jsb_from_int
    mov rcx, rax
    mov rax, rdi
    mov rdx, [jsta_atom_byte_length]
    call jsta_define
    mov eax, [rdi + JTA_OFFSET]
    call jsb_from_int
    mov rcx, rax
    mov rax, rdi
    mov rdx, [jsta_atom_byte_offset]
    call jsta_define
    mov rcx, rsi
    BOX rcx, rdx, JS_OBJ_BITS
    mov rax, rdi
    mov rdx, [jsta_atom_buffer]
    call jsta_define
    pop rax
    pop rdi
    pop rdx
    pop rcx
    ret

; new Int8Array(...) ... new Float64Array(...)
jsta_new_int8:
    push rbx
    mov ebx, TA_INT8
    jmp jsta_construct
jsta_new_uint8:
    push rbx
    mov ebx, TA_UINT8
    jmp jsta_construct
jsta_new_uint8c:
    push rbx
    mov ebx, TA_UINT8C
    jmp jsta_construct
jsta_new_int16:
    push rbx
    mov ebx, TA_INT16
    jmp jsta_construct
jsta_new_uint16:
    push rbx
    mov ebx, TA_UINT16
    jmp jsta_construct
jsta_new_int32:
    push rbx
    mov ebx, TA_INT32
    jmp jsta_construct
jsta_new_uint32:
    push rbx
    mov ebx, TA_UINT32
    jmp jsta_construct
jsta_new_float32:
    push rbx
    mov ebx, TA_FLOAT32
    jmp jsta_construct
jsta_new_float64:
    push rbx
    mov ebx, TA_FLOAT64
; jsta_construct: EBX = kind ([RSP] = the caller's RBX), the arguments:
; (length) | (typed array / array / iterable / array-like) | (buffer, offset, length)
jsta_construct:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    call jsta_need_new
    mov r10d, ecx                   ; argument count
    xor eax, eax
    call jsb_arg
    mov r9, rax                     ; the first argument
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    je .object
    ; a length (undefined: 0)
    mov ecx, r10d
    xor eax, eax
    call jsb_arg_integer
    test rax, rax
    js .bad_length
    cmp rax, 0x4000000
    ja .bad_length
    mov r8, rax
    mov cl, [jsta_shift + rbx]
    shl rax, cl
    mov ecx, eax
    call jsta_buffer_new
    mov rsi, rax
    xor edx, edx
    mov ecx, r8d
    call jsta_view_new
    jmp .done
.object:
    mov rax, r9
    call jsta_class_of
    cmp ecx, JC_ARRAYBUFFER
    je .buffer
    ; values: from an iterable, or an array-like
    push rbx
    xor ecx, ecx
    call jsarr_new
    mov r8, rax                     ; the values
    mov rax, r9
    mov rdx, [sym_iterator]
    call js_get
    mov rcx, JS_UNDEF
    cmp rax, rcx
    je .array_like
    mov rax, r8
    mov rdx, r9
    call jsit_collect
    jmp .values
.array_like:
    mov rax, r9
    call jsl_array_like_to_array
    mov r8, rax
.values:
    pop rbx
    mov ecx, [r8 + JARR_LEN]
    push rcx
    mov eax, ecx
    mov cl, [jsta_shift + rbx]
    shl eax, cl
    mov ecx, eax
    call jsta_buffer_new
    mov rsi, rax
    pop rcx
    xor edx, edx
    call jsta_view_new
    ; copy them in
    mov rdi, rax
    xor edx, edx
.copy:
    cmp edx, [r8 + JARR_LEN]
    jae .copied
    mov rax, [r8 + JARR_ELEMS]
    mov rax, [rax + rdx*8]
    mov rcx, JS_HOLE
    cmp rax, rcx
    jne .store
    mov rax, JS_UNDEF
.store:
    mov rcx, rax
    mov rax, rdi
    call jsta_store
    inc edx
    jmp .copy
.copied:
    mov rax, rdi
    jmp .done
.buffer:
    ; a view of a buffer: (buffer, byteOffset, length)
    mov esi, r9d
    mov ecx, r10d
    mov eax, 1
    call jsb_arg_integer
    test rax, rax
    js .bad_offset
    mov ecx, [rsi + JAB_LEN]
    cmp rax, rcx
    ja .bad_offset
    mov cl, [jsta_shift + rbx]
    mov rdx, rax
    mov r8, rax
    shr r8, cl
    shl r8, cl
    cmp r8, rax
    jne .bad_offset                 ; not a multiple of the element size
    push rdx
    mov ecx, r10d
    mov eax, 2
    call jsb_arg_integer
    pop rdx
    jnc .length_given
    ; the rest of the buffer
    mov eax, [rsi + JAB_LEN]
    sub eax, edx
    mov cl, [jsta_shift + rbx]
    mov r8d, eax
    shr eax, cl
    shl eax, cl
    cmp eax, r8d
    jne .bad_length
    shr eax, cl
    mov ecx, eax
    jmp .view
.length_given:
    test rax, rax
    js .bad_length
    mov r8, rax
    mov cl, [jsta_shift + rbx]
    shl rax, cl
    add rax, rdx
    mov ecx, [rsi + JAB_LEN]
    cmp rax, rcx
    ja .bad_length
    mov ecx, r8d
.view:
    call jsta_view_new
.done:
    BOX rax, rcx, JS_OBJ_BITS
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.bad_length:
    lea rsi, [jsmsg_ta_length]
    jmp jsta_range_error
.bad_offset:
    lea rsi, [jsmsg_ta_offset]
    jmp jsta_range_error

; jsta_load: RAX = typed array (raw), EDX = index (< its length) -> RAX = the
; element (a number)
jsta_load:
    push rcx
    push rdx
    push rsi
    mov rsi, [rax + JTA_DATA]
    movzx ecx, byte [rax + JTA_KIND]
    mov edx, edx
    jmp [.kinds + rcx*8]
.kinds:
    dq .int8, .uint8, .uint8, .int16, .uint16, .int32, .uint32, .float32, .float64
.int8:
    movsx rax, byte [rsi + rdx]
    jmp .integer
.uint8:
    movzx eax, byte [rsi + rdx]
    jmp .integer
.int16:
    movsx rax, word [rsi + rdx*2]
    jmp .integer
.uint16:
    movzx eax, word [rsi + rdx*2]
    jmp .integer
.int32:
    movsxd rax, dword [rsi + rdx*4]
    jmp .integer
.uint32:
    mov eax, [rsi + rdx*4]
.integer:
    cvtsi2sd xmm0, rax
    movq rax, xmm0
    jmp .out
.float32:
    cvtss2sd xmm0, [rsi + rdx*4]
    movq rax, xmm0
    jmp .out
.float64:
    mov rax, [rsi + rdx*8]
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; jsta_store: RAX = typed array (raw), EDX = index, RCX = value -> stored
; (converted to the element type; an index past the end is ignored)
jsta_store:
    push rax
    push rcx
    push rdx
    push rsi
    cmp edx, [rax + JTA_LEN]
    jae .out
    mov rsi, [rax + JTA_DATA]
    push rax
    mov rax, rcx
    call js_to_number
    mov rcx, rax
    pop rax
    push rdx
    movzx edx, byte [rax + JTA_KIND]
    mov rax, rcx                    ; the number
    jmp [.kinds + rdx*8]
.kinds:
    dq .int8, .int8, .clamped, .int16, .int16, .int32, .int32, .float32, .float64
.int8:
    call jsnum_to_int32
    pop rdx
    mov [rsi + rdx], al
    jmp .out
.clamped:
    ; round to nearest (even), clamp to 0 .. 255; NaN is 0
    movq xmm0, rax
    xor eax, eax
    ucomisd xmm0, xmm0
    jp .clamp_store
    cvtsd2si rax, xmm0
    test rax, rax
    jns .not_neg
    xor eax, eax
.not_neg:
    cmp rax, 255
    jbe .clamp_store
    mov eax, 255
.clamp_store:
    pop rdx
    mov [rsi + rdx], al
    jmp .out
.int16:
    call jsnum_to_int32
    pop rdx
    mov [rsi + rdx*2], ax
    jmp .out
.int32:
    call jsnum_to_int32
    pop rdx
    mov [rsi + rdx*4], eax
    jmp .out
.float32:
    movq xmm0, rax
    cvtsd2ss xmm0, xmm0
    pop rdx
    movd [rsi + rdx*4], xmm0
    jmp .out
.float64:
    pop rdx
    mov [rsi + rdx*8], rax
.out:
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; --- the hooks: js_get / js_put / js_get_elem / js_put_elem (objects of the
; exotic classes, JC_EXOTIC and up) -----------------------------------------------

; jsx_get: RDI = object (raw), RDX = atom -> RAX = value, CF=0 if handled
jsx_get:
    cmp dword [rdi + JOBJ_CLASS], JC_PROXY
    je jsprx_get
    cmp dword [rdi + JOBJ_CLASS], JC_TYPED
    jne .not_ours
    push rdx
    mov eax, edx
    call jsstr_array_index
    mov edx, eax
    jc .not_index
    mov rax, rdi
    call jsta_element
    pop rdx
    clc
    ret
.not_index:
    pop rdx
.not_ours:
    stc
    ret

; jsta_element: RAX = typed array (raw), EDX = index -> RAX = element or undefined
jsta_element:
    cmp edx, [rax + JTA_LEN]
    jae .undefined
    jmp jsta_load
.undefined:
    mov rax, JS_UNDEF
    ret

; jsx_get_elem: RAX = object value, RDX = key value -> RAX = value, CF=0 if
; handled (other keys: the named path, with RAX and RDX as they were)
jsx_get_elem:
    push rbx
    push rdx
    push rdi
    mov ebx, eax
    cmp dword [rbx + JOBJ_CLASS], JC_PROXY
    je .proxy
    cmp dword [rbx + JOBJ_CLASS], JC_TYPED
    jne .not_ours
    push rax
    call js_index
    mov edx, eax
    pop rax
    jc .not_ours
    mov rax, rbx
    call jsta_element
    jmp .ours
.proxy:
    ; (the key as a property key, then the get trap)
    mov rax, rdx
    call js_to_key
    mov rdx, rax
    mov rdi, rbx
    call jsprx_get
.ours:
    pop rdi
    pop rdx
    pop rbx
    clc
    ret
.not_ours:
    pop rdi
    pop rdx
    pop rbx
    stc
    ret

; jsx_put: RAX = object (raw), RDX = atom, RCX = value -> CF=0 if handled
jsx_put:
    cmp dword [rax + JOBJ_CLASS], JC_PROXY
    je jsprx_set
    cmp dword [rax + JOBJ_CLASS], JC_TYPED
    jne .not_ours
    push rax
    push rdx
    mov eax, edx
    call jsstr_array_index
    mov edx, eax
    pop rax                         ; (the atom, unused)
    pop rax
    jc .not_index
    call jsta_store
    clc
    ret
.not_index:
.not_ours:
    stc
    ret

; jsx_put_elem: RAX = object value, RDX = key value, RCX = value -> CF=0 if
; handled (RAX, RDX kept)
jsx_put_elem:
    push rax
    push rbx
    push rdx
    mov ebx, eax
    cmp dword [rbx + JOBJ_CLASS], JC_PROXY
    je .proxy
    cmp dword [rbx + JOBJ_CLASS], JC_TYPED
    jne .not_ours
    push rax
    call js_index
    mov edx, eax
    pop rax
    jc .not_ours
    mov rax, rbx
    call jsta_store
    jmp .ours
.proxy:
    mov rax, rdx
    call js_to_key
    mov rdx, rax
    mov rax, rbx
    call jsprx_set
.ours:
    pop rdx
    pop rbx
    pop rax
    clc
    ret
.not_ours:
    pop rdx
    pop rbx
    pop rax
    stc
    ret

; --- methods -----------------------------------------------------------------------

; jsta_this: RDX = this -> RBX = typed array (raw), TypeError if it is not one
jsta_this:
    push rax
    push rcx
    mov rax, rdx
    call jsta_class_of
    cmp ecx, JC_TYPED
    jne .bad
    mov ebx, edx
    pop rcx
    pop rax
    ret
.bad:
    lea rsi, [jsmsg_ta_this]
    xor edi, edi
    jmp js_throw_type

; subarray(begin, end): a view of the same buffer
jsta_subarray:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    call jsta_this
    mov r8d, ecx                    ; argument count
    xor eax, eax
    call jsb_arg_integer
    mov r9, rax
    mov ecx, r8d
    mov eax, 1
    call jsb_arg_integer
    mov rdx, rax
    jnc .end_given
    mov edx, [rbx + JTA_LEN]
.end_given:
    mov rax, r9
    mov ecx, [rbx + JTA_LEN]
    call jsta_clamp_range
    mov ecx, edx
    sub ecx, eax                    ; length
    movzx edx, byte [rbx + JTA_KIND]
    push rcx
    mov cl, [jsta_shift + rdx]
    shl eax, cl
    pop rcx
    add eax, [rbx + JTA_OFFSET]
    mov rsi, [rbx + JTA_BUFFER]
    push rdx
    mov edx, eax                    ; byte offset
    pop rax
    push rbx
    mov ebx, eax                    ; kind
    call jsta_view_new
    pop rbx
    BOX rax, rcx, JS_OBJ_BITS
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; set(source, offset): the source's values stored from offset on
jsta_set:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    call jsta_this
    mov r9d, ecx
    mov eax, 1
    call jsb_arg_integer
    test rax, rax
    js .range
    mov r8, rax                     ; offset
    mov ecx, r9d
    xor eax, eax
    call jsb_arg
    ; the values first (the source may share the buffer)
    call jsl_array_like_to_array
    mov r9, rax
    mov ecx, [r9 + JARR_LEN]
    add rcx, r8
    cmp ecx, [rbx + JTA_LEN]
    ja .range
    xor edx, edx
.value:
    cmp edx, [r9 + JARR_LEN]
    jae .done
    mov rax, [r9 + JARR_ELEMS]
    mov rcx, [rax + rdx*8]
    push rdx
    add edx, r8d
    mov rax, rbx
    call jsta_store
    pop rdx
    inc edx
    jmp .value
.done:
    mov rax, JS_UNDEF
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret
.range:
    lea rsi, [jsmsg_dv_offset]
    jmp jsta_range_error

; __bytesToString(view or buffer): a string of those bytes (TextDecoder)
jsta_bytes_to_string:
    push rbx
    push rcx
    push rsi
    xor eax, eax
    call jsb_arg
    call jsta_class_of
    mov ebx, eax
    cmp ecx, JC_ARRAYBUFFER
    je .buffer
    cmp ecx, JC_TYPED
    je .typed
    cmp ecx, JC_DATAVIEW
    je .view
    mov rax, [atom_empty]
    jmp .out
.buffer:
    mov rsi, [rbx + JAB_DATA]
    mov ecx, [rbx + JAB_LEN]
    jmp .make
.typed:
    mov rsi, [rbx + JTA_DATA]
    mov ecx, [rbx + JTA_LEN]
    movzx eax, byte [rbx + JTA_KIND]
    push rcx
    mov cl, [jsta_shift + rax]
    mov eax, [rsp]
    shl eax, cl
    pop rcx
    mov ecx, eax
    jmp .make
.view:
    mov rsi, [rbx + JDV_DATA]
    mov ecx, [rbx + JDV_LEN]
.make:
    call jsstr_new
.out:
    call jsb_box_string
    pop rsi
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; DataView
; ------------------------------------------------------------------------------

; new DataView(buffer, byteOffset, byteLength)
jsta_data_view:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    call jsta_need_new
    mov r9d, ecx
    xor eax, eax
    call jsb_arg
    mov r8, rax
    call jsta_class_of
    cmp ecx, JC_ARRAYBUFFER
    jne .not_buffer
    mov esi, r8d
    mov ecx, r9d
    mov eax, 1
    call jsb_arg_integer
    test rax, rax
    js .range
    mov edx, [rsi + JAB_LEN]
    cmp rax, rdx
    ja .range
    mov rbx, rax                    ; offset
    mov ecx, r9d
    mov eax, 2
    call jsb_arg_integer
    jnc .length
    mov eax, [rsi + JAB_LEN]
    sub eax, ebx
.length:
    test rax, rax
    js .range
    lea rdx, [rax + rbx]
    mov ecx, [rsi + JAB_LEN]
    cmp rdx, rcx
    ja .range
    mov r8, rax
    mov ecx, JDV_SIZE
    call js_alloc
    mov byte [rax + JH_KIND], JK_OBJECT
    mov dword [rax + JOBJ_CLASS], JC_DATAVIEW
    mov rcx, [jsta_dataview_proto]
    mov [rax + JOBJ_PROTO], rcx
    mov [rax + JDV_BUFFER], rsi
    mov rcx, [rsi + JAB_DATA]
    add rcx, rbx
    mov [rax + JDV_DATA], rcx
    mov [rax + JDV_LEN], r8d
    mov rdi, rax
    mov eax, r8d
    call jsb_from_int
    mov rcx, rax
    mov rax, rdi
    mov rdx, [jsta_atom_byte_length]
    call jsta_define
    mov eax, ebx
    call jsb_from_int
    mov rcx, rax
    mov rax, rdi
    mov rdx, [jsta_atom_byte_offset]
    call jsta_define
    mov rcx, rsi
    BOX rcx, rdx, JS_OBJ_BITS
    mov rdx, [jsta_atom_buffer]
    call jsta_define
    BOX rax, rcx, JS_OBJ_BITS
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.not_buffer:
    lea rsi, [jsmsg_dv_buffer]
    xor edi, edi
    jmp js_throw_type
.range:
    lea rsi, [jsmsg_dv_offset]
    jmp jsta_range_error

; the get/set methods: EBX = TA_* kind of the value
jsdv_get_int8:
    push rbx
    mov ebx, TA_INT8
    jmp jsdv_get
jsdv_get_uint8:
    push rbx
    mov ebx, TA_UINT8
    jmp jsdv_get
jsdv_get_int16:
    push rbx
    mov ebx, TA_INT16
    jmp jsdv_get
jsdv_get_uint16:
    push rbx
    mov ebx, TA_UINT16
    jmp jsdv_get
jsdv_get_int32:
    push rbx
    mov ebx, TA_INT32
    jmp jsdv_get
jsdv_get_uint32:
    push rbx
    mov ebx, TA_UINT32
    jmp jsdv_get
jsdv_get_float32:
    push rbx
    mov ebx, TA_FLOAT32
    jmp jsdv_get
jsdv_get_float64:
    push rbx
    mov ebx, TA_FLOAT64
    jmp jsdv_get
jsdv_set_int8:
    push rbx
    mov ebx, TA_INT8
    jmp jsdv_set
jsdv_set_uint8:
    push rbx
    mov ebx, TA_UINT8
    jmp jsdv_set
jsdv_set_int16:
    push rbx
    mov ebx, TA_INT16
    jmp jsdv_set
jsdv_set_uint16:
    push rbx
    mov ebx, TA_UINT16
    jmp jsdv_set
jsdv_set_int32:
    push rbx
    mov ebx, TA_INT32
    jmp jsdv_set
jsdv_set_uint32:
    push rbx
    mov ebx, TA_UINT32
    jmp jsdv_set
jsdv_set_float32:
    push rbx
    mov ebx, TA_FLOAT32
    jmp jsdv_set
jsdv_set_float64:
    push rbx
    mov ebx, TA_FLOAT64
    jmp jsdv_set

; jsdv_place: RDX = this, EBX = kind, R10 = arguments, R8D = their count ->
; RSI = the value's first byte, ECX = its size (RangeError past the end)
jsdv_place:
    push rax
    push rdi
    push r11
    mov rax, rdx
    call jsta_class_of
    cmp ecx, JC_DATAVIEW
    jne .bad
    mov r11d, edx
    mov rdi, r10
    mov ecx, r8d
    xor eax, eax
    call jsb_arg_integer
    test rax, rax
    js .range
    mov cl, [jsta_shift + rbx]
    mov edi, 1
    shl edi, cl
    lea rsi, [rax + rdi]
    mov ecx, [r11 + JDV_LEN]
    cmp rsi, rcx
    ja .range
    mov rsi, [r11 + JDV_DATA]
    add rsi, rax
    mov ecx, edi
    pop r11
    pop rdi
    pop rax
    ret
.bad:
    lea rsi, [jsmsg_ta_this]
    xor edi, edi
    jmp js_throw_type
.range:
    lea rsi, [jsmsg_dv_offset]
    jmp jsta_range_error

; jsdv_little: argument AL (1 or 2) truthy? -> CF=1: little-endian
jsdv_little:
    push rcx
    push rdi
    movzx eax, al
    mov rdi, r10
    mov ecx, r8d
    call jsb_arg
    call js_truthy
    pop rdi
    pop rcx
    ret

; jsdv_reverse: the caller's [RSP] = scratch bytes, ECX = how many -> reversed
jsdv_reverse:
    push rax
    push rdx
    push rsi
    push rdi
    lea rsi, [rsp + 40]
    lea rdi, [rsi + rcx - 1]
.swap:
    cmp rsi, rdi
    jae .done
    mov al, [rsi]
    mov dl, [rdi]
    mov [rsi], dl
    mov [rdi], al
    inc rsi
    dec rdi
    jmp .swap
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rax
    ret

; jsdv_get: EBX = kind ([RSP] = the caller's RBX) -> the value at argument 0,
; little-endian when argument 1 is truthy
jsdv_get:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r10
    mov r8d, ecx
    mov r10, rdi
    call jsdv_place                 ; RSI = bytes, ECX = size
    sub rsp, 16
    mov rdi, rsp
    push rcx
    rep movsb
    pop rcx
    mov al, 1
    call jsdv_little
    jc .ordered
    call jsdv_reverse
.ordered:
    mov rsi, rsp
    jmp [.kinds + rbx*8]
.kinds:
    dq .int8, .uint8, .uint8, .int16, .uint16, .int32, .uint32, .float32, .float64
.int8:
    movsx rax, byte [rsi]
    jmp .integer
.uint8:
    movzx eax, byte [rsi]
    jmp .integer
.int16:
    movsx rax, word [rsi]
    jmp .integer
.uint16:
    movzx eax, word [rsi]
    jmp .integer
.int32:
    movsxd rax, dword [rsi]
    jmp .integer
.uint32:
    mov eax, [rsi]
.integer:
    cvtsi2sd xmm0, rax
    movq rax, xmm0
    jmp .out
.float32:
    cvtss2sd xmm0, [rsi]
    movq rax, xmm0
    jmp .out
.float64:
    mov rax, [rsi]
.out:
    add rsp, 16
    pop r10
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsdv_set: EBX = kind ([RSP] = the caller's RBX) -> argument 1 stored at the
; offset in argument 0, little-endian when argument 2 is truthy
jsdv_set:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r8d, ecx
    mov r10, rdi
    call jsdv_place
    mov r9, rsi                     ; the destination
    push rcx
    mov ecx, r8d
    mov eax, 1
    call jsb_arg
    call js_to_number
    pop rcx
    sub rsp, 16
    mov rsi, rsp
    jmp [.kinds + rbx*8]
.kinds:
    dq .int8, .int8, .int8, .int16, .int16, .int32, .int32, .float32, .float64
.int8:
    call jsnum_to_int32
    mov [rsi], al
    jmp .ordered
.int16:
    call jsnum_to_int32
    mov [rsi], ax
    jmp .ordered
.int32:
    call jsnum_to_int32
    mov [rsi], eax
    jmp .ordered
.float32:
    movq xmm0, rax
    cvtsd2ss xmm0, xmm0
    movd [rsi], xmm0
    jmp .ordered
.float64:
    mov [rsi], rax
.ordered:
    mov al, 2
    call jsdv_little
    jc .copy
    call jsdv_reverse
.copy:
    mov rsi, rsp
    mov rdi, r9
    rep movsb
    add rsp, 16
    mov rax, JS_UNDEF
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
