; ==============================================================================
; Antigravity OS - JavaScript: symbols, iterators, generators
; ------------------------------------------------------------------------------
; A symbol is the value tag JS_TAG_SYMBOL around a permanent JK_SYMBOL block;
; that pointer works as a property key just like an atom (for-in and
; Object.keys skip it). Symbol.iterator & co. are made once per realm.
;
; Iteration: for-of, spread and destructuring take arrays and strings as they
; are, and anything else through the protocol: value[Symbol.iterator]() gives
; an iterator whose next() returns {value, done}. The iterators the engine
; makes (arrays, strings, Map, Set) are JC_ITERATOR objects (JIO_* fields).
;
; A generator function starts with GENSTART, which saves the new frame in a
; coroutine (the one async functions use, async.asm) and returns a generator
; object instead of running the body. next(v) resumes it (jsco_resume) until
; YIELD saves it again or it returns; an implicit try (GENTHROW) marks it
; finished when an error leaves it.
; ==============================================================================

[bits 64]

JSYM_DESC               equ 8           ; the description (string value or undefined)
JSYM_SIZE               equ 16

JIO_SRC                 equ 32          ; value: what it goes through
JIO_POS                 equ 40          ; dword: the next index
JIO_KIND                equ 44          ; dword: ITK_*
JIO_SIZE                equ 48
ITK_VALUES              equ 0           ; array values
ITK_KEYS                equ 1           ; array indices
ITK_ENTRIES             equ 2           ; [index, value]
ITK_STRING              equ 3           ; characters (UTF-8 sequences)
ITK_MAP_ENTRIES         equ 4           ; Map / Set (collections.asm)
ITK_MAP_KEYS            equ 5
ITK_MAP_VALUES          equ 6

JGEN_CORO               equ 32          ; raw: its coroutine
JGEN_STATE              equ 40          ; dword: GS_*
JGEN_SIZE               equ 48
GS_START                equ 0           ; not started
GS_YIELDED              equ 1           ; stopped at a yield
GS_RUNNING              equ 2
GS_DONE                 equ 3

section .bss
alignb 8
js_symbol_proto:        resq 1
jsy_symbol_ctor:        resq 1
jsy_registry:           resq 1          ; Symbol.for: key atom -> symbol
sym_iterator:           resq 1          ; the well-known symbols (values)
sym_async_iterator:     resq 1
sym_has_instance:       resq 1
sym_to_primitive:       resq 1
sym_to_string_tag:      resq 1
sym_species:            resq 1
js_iter_proto:          resq 1          ; %IteratorPrototype%
js_listiter_proto:      resq 1          ; the engine's iterators
js_generator_proto:     resq 1
jsy_atom_value:         resq 1
jsy_atom_done:          resq 1
jsy_atom_next:          resq 1
jsy_atom_return:        resq 1
jsy_atom_throw:         resq 1

section .rodata
jsy_ctors:
JSCTOR jsy_symbol_ctor, jsy_symbol, 0, js_symbol_proto, "Symbol"
    dq 0

jsy_natives:
JSNATIVE jsy_symbol_ctor, "for", jsy_symbol_for, 1
JSNATIVE jsy_symbol_ctor, "keyFor", jsy_symbol_key_for, 1
JSNATIVE js_symbol_proto, "toString", jsy_symbol_to_string, 0
JSNATIVE js_symbol_proto, "valueOf", jsy_symbol_value_of, 0
JSNATIVE js_listiter_proto, "next", jsit_next, 0
JSNATIVE js_generator_proto, "next", jsgen_next, 1
JSNATIVE js_generator_proto, "return", jsgen_return, 1
JSNATIVE js_generator_proto, "throw", jsgen_throw, 1
JSNATIVE js_array_proto, "values", jsit_array_values, 0
JSNATIVE js_array_proto, "keys", jsit_array_keys, 0
JSNATIVE js_array_proto, "entries", jsit_array_entries, 0
JSNATIVE jsb_object_ctor, "getOwnPropertySymbols", jsy_own_symbols, 1
    dq 0

; the well-known symbols: variable, description (also the name on Symbol)
jsy_well_known:
    dq sym_iterator, jsy_str_iterator
    dq sym_async_iterator, jsy_str_async_iterator
    dq sym_has_instance, jsy_str_has_instance
    dq sym_to_primitive, jsy_str_to_primitive
    dq sym_to_string_tag, jsy_str_to_string_tag
    dq sym_species, jsy_str_species
    dq 0
jsy_str_iterator:       db "iterator", 0
jsy_str_async_iterator: db "asyncIterator", 0
jsy_str_has_instance:   db "hasInstance", 0
jsy_str_to_primitive:   db "toPrimitive", 0
jsy_str_to_string_tag:  db "toStringTag", 0
jsy_str_species:        db "species", 0
jsy_str_symbol_prefix:  db "Symbol.", 0
jsy_str_open:           db "Symbol(", 0
jsy_str_description:    db "description", 0
jsy_str_value:          db "value", 0
jsy_str_done:           db "done", 0
jsy_str_next:           db "next", 0
jsy_str_return:         db "return", 0
jsy_str_throw:          db "throw", 0
jsy_str_values:         db "values", 0
jsmsg_symbol_new:       db "Symbol is not a constructor", 0
jsmsg_symbol_string:    db "Cannot convert a Symbol value to a string", 0
jsmsg_symbol_number:    db "Cannot convert a Symbol value to a number", 0
jsmsg_not_symbol:       db "% is not a symbol", 0
jsmsg_iter_result:      db "Iterator result % is not an object", 0
jsmsg_gen_running:      db "Generator is already running", 0
jsmsg_not_generator:    db "next method called on incompatible receiver %", 0
; resuming a generator with throw(): the reason is thrown where it stopped
jsgen_throw_code:       db OP_THROW

section .text

; ------------------------------------------------------------------------------
; jsy_init: Symbol and the well-known symbols, the iterator prototypes, the
; generator prototype (js_init_builtins)
; ------------------------------------------------------------------------------
jsy_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov rbx, [js_object_proto]
    mov rax, rbx
    call jsobj_new
    mov [js_symbol_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [js_iter_proto], rax
    call jsobj_new                  ; (inherits %IteratorPrototype%)
    mov [js_listiter_proto], rax
    mov rax, [js_iter_proto]
    call jsobj_new
    mov [js_generator_proto], rax
    call jsobj_new_plain
    mov [jsy_registry], rax
    lea r8, [jsy_ctors]
    call jsb_define_ctors
    lea r8, [jsy_natives]
    call jsb_define_natives
%macro JSY_ATOM 2
    lea rsi, [%2]
    call jsstr_from_cstr
    mov [%1], rax
%endmacro
    JSY_ATOM jsy_atom_value, jsy_str_value
    JSY_ATOM jsy_atom_done, jsy_str_done
    JSY_ATOM jsy_atom_next, jsy_str_next
    JSY_ATOM jsy_atom_return, jsy_str_return
    JSY_ATOM jsy_atom_throw, jsy_str_throw
    ; Symbol.iterator, ...: "Symbol.iterator" described, defined on Symbol
    lea rbx, [jsy_well_known]
.well_known:
    cmp qword [rbx], 0
    je .made
    mov rsi, [rbx + 8]
    push rsi
    lea rsi, [jsy_str_symbol_prefix]
    call jsstr_from_cstr
    mov rdx, rax
    pop rsi
    push rsi
    call jsstr_from_cstr
    xchg rax, rdx
    call jsstr_concat
    call jsstr_intern
    call jsb_box_string
    call jsy_new
    mov rcx, [rbx]
    mov [rcx], rax
    mov rcx, rax
    pop rsi
    mov rax, [jsy_symbol_ctor]
    mov edx, 3                      ; hidden, read-only
    call jsb_define
    add rbx, 16
    jmp .well_known
.made:
    ; symbol.description (a getter)
    lea rsi, [jsy_str_description]
    call jsstr_from_cstr
    mov rdx, rax
    bts rdx, 32
    lea rax, [jsy_symbol_description]
    call jsy_native0
    mov rcx, rax
    mov rax, [js_symbol_proto]
    mov r8d, 1
    call jsobj_define_accessor
    ; [Symbol.iterator] methods
    mov rax, [js_iter_proto]
    lea rcx, [jsy_return_this]
    call jsy_define_iterator_method
    mov rax, [js_array_proto]
    lea rcx, [jsit_array_values]
    call jsy_define_iterator_method
    mov rax, [js_string_proto]
    lea rcx, [jsit_string_iterator]
    call jsy_define_iterator_method
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsy_native0: RAX = routine -> RAX = a native function (value) with no name
jsy_native0:
    push rcx
    push rdx
    xor ecx, ecx
    mov rdx, [atom_empty]
    call jsfn_native
    BOX rax, rcx, JS_OBJ_BITS
    pop rdx
    pop rcx
    ret

; jsy_define_iterator_method: RAX = object, RCX = routine -> object[Symbol.iterator]
jsy_define_iterator_method:
    push rax
    push rcx
    push rdx
    push rax
    mov rax, rcx
    call jsy_native0
    mov rcx, rax
    pop rax
    mov edx, [sym_iterator]
    bts rdx, 32                     ; hidden
    call jsobj_define
    pop rdx
    pop rcx
    pop rax
    ret

jsy_return_this:
    mov rax, rdx
    ret

; ==============================================================================
; Symbols
; ==============================================================================

; jsy_new: RAX = description (string value or undefined) -> RAX = a new symbol
jsy_new:
    push rcx
    push rdx
    mov rdx, rax
    mov ecx, JSYM_SIZE
    call js_alloc_perm
    mov byte [rax + JH_KIND], JK_SYMBOL
    mov [rax + JSYM_DESC], rdx
    mov rdx, JS_SYM_BITS
    or rax, rdx
    pop rdx
    pop rcx
    ret

; Symbol(description)
jsy_symbol:
    test r8d, r8d
    jnz .new
    xor eax, eax
    call jsb_arg
    push rdx
    mov rdx, JS_UNDEF
    cmp rax, rdx
    pop rdx
    je .made
    call js_to_string
    call jsstr_intern               ; (permanent, like the symbol)
    call jsb_box_string
.made:
    jmp jsy_new
.new:
    lea rsi, [jsmsg_symbol_new]
    xor edi, edi
    jmp js_throw_type

; jsy_this_symbol: RDX = this -> RAX = the symbol block (raw); TypeError
; otherwise
jsy_this_symbol:
    mov rax, rdx
    shr rax, 48
    cmp eax, JS_TAG_SYMBOL
    jne .bad
    mov eax, edx
    ret
.bad:
    mov rax, rdx
    call js_to_string
    mov rdi, rax
    lea rsi, [jsmsg_not_symbol]
    jmp js_throw_type

; symbol.toString() -> "Symbol(description)"
jsy_symbol_to_string:
    call jsy_this_symbol
    jmp jsy_describe

; jsy_describe: RAX = symbol block -> RAX = "Symbol(description)" (value)
jsy_describe:
    push rcx
    push rdx
    push rsi
    push rax
    lea rsi, [jsy_str_open]
    call jsstr_from_cstr
    pop rcx
    mov rdx, [rcx + JSYM_DESC]
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_STRING
    jne .close
    mov edx, edx
    call jsstr_concat
.close:
    push rax
    mov eax, ')'
    call jsstr_char
    mov rdx, rax
    pop rax
    call jsstr_concat
    call jsb_box_string
    pop rsi
    pop rdx
    pop rcx
    ret

; symbol.valueOf()
jsy_symbol_value_of:
    call jsy_this_symbol
    mov rax, rdx
    ret

; symbol.description
jsy_symbol_description:
    call jsy_this_symbol
    mov rax, [rax + JSYM_DESC]
    ret

; Symbol.for(key): the same symbol for the same key, realm-wide
jsy_symbol_for:
    push rcx
    push rdx
    xor eax, eax
    call jsb_arg
    call js_to_string
    call jsstr_intern
    mov rdx, rax                    ; the key
    mov rax, [jsy_registry]
    push rbx
    call jsobj_find_own
    jnc .found
    pop rbx
    mov rax, rdx
    call jsb_box_string
    call jsy_new
    mov rcx, rax
    mov rax, [jsy_registry]
    call jsobj_define
    mov rax, rcx
    pop rdx
    pop rcx
    ret
.found:
    mov rax, [rbx + JPE_VAL]
    pop rbx
    pop rdx
    pop rcx
    ret

; Symbol.keyFor(symbol) -> its key, or undefined if it is not from Symbol.for
jsy_symbol_key_for:
    push rbx
    push rcx
    push rdx
    xor eax, eax
    call jsb_arg
    mov rdx, rax
    call jsy_this_symbol
    mov rax, [jsy_registry]
    mov ecx, [rax + JOBJ_COUNT]
    mov rbx, [rax + JOBJ_PROPS]
.entry:
    test ecx, ecx
    jz .none
    cmp [rbx + JPE_VAL], rdx
    je .found
    add rbx, JPE_SIZE
    dec ecx
    jmp .entry
.found:
    mov eax, [rbx + JPE_KEY]
    call jsb_box_string
    jmp .out
.none:
    mov rax, JS_UNDEF
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

; Object.getOwnPropertySymbols(object)
jsy_own_symbols:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    xor ecx, ecx
    call jsarr_new
    mov r8, rax
    xor eax, eax
    mov ecx, [rsp + 24]             ; (the argument count)
    call jsb_arg
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .done
    mov ebx, eax
    mov ecx, [rbx + JOBJ_COUNT]
    mov rsi, [rbx + JOBJ_PROPS]
.prop:
    test ecx, ecx
    jz .done
    mov eax, [rsi + JPE_KEY]
    test eax, eax
    jz .next
    cmp byte [rax + JH_KIND], JK_SYMBOL
    jne .next
    push rcx
    mov rcx, JS_SYM_BITS
    or rcx, rax
    mov rax, r8
    call jsarr_push
    pop rcx
.next:
    add rsi, JPE_SIZE
    dec ecx
    jmp .prop
.done:
    mov rax, r8
    BOX rax, rcx, JS_OBJ_BITS
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; js_symbol_error_string / js_symbol_error_number: a symbol where a string
; or number is needed (TypeError)
js_symbol_error_string:
    lea rsi, [jsmsg_symbol_string]
    xor edi, edi
    jmp js_throw_type
js_symbol_error_number:
    lea rsi, [jsmsg_symbol_number]
    xor edi, edi
    jmp js_throw_type

; ==============================================================================
; Iterators
; ==============================================================================

; jsit_new: RAX = what to go through (value), ECX = ITK_* -> RAX = an
; iterator (value)
jsit_new:
    push rcx
    push rdx
    mov rdx, rax
    push rcx
    mov ecx, JIO_SIZE
    call js_alloc
    pop rcx
    mov byte [rax + JH_KIND], JK_OBJECT
    mov dword [rax + JOBJ_CLASS], JC_ITERATOR
    mov [rax + JIO_SRC], rdx
    mov [rax + JIO_KIND], ecx
    mov rcx, [js_listiter_proto]
    mov [rax + JOBJ_PROTO], rcx
    BOX rax, rcx, JS_OBJ_BITS
    pop rdx
    pop rcx
    ret

; array.values() / keys() / entries(), string[Symbol.iterator]()
jsit_array_values:
    push rcx
    xor ecx, ecx
    jmp jsit_array_common
jsit_array_keys:
    push rcx
    mov ecx, ITK_KEYS
    jmp jsit_array_common
jsit_array_entries:
    push rcx
    mov ecx, ITK_ENTRIES
jsit_array_common:
    mov rax, rdx
    call jsit_new
    pop rcx
    ret
jsit_string_iterator:
    push rcx
    mov rax, rdx
    call js_to_string
    call jsb_box_string
    mov ecx, ITK_STRING
    call jsit_new
    pop rcx
    ret

; jsit_result: RAX = value, ECX = 1 if done -> RAX = {value, done} (value)
jsit_result:
    push rcx
    push rdx
    push rsi
    mov rsi, rax
    call jsobj_new_plain
    push rcx
    mov rcx, rsi
    mov edx, [jsy_atom_value]
    call jsobj_define
    pop rcx
    test ecx, 1
    mov rcx, JS_FALSE
    jz .done
    mov rcx, JS_TRUE
.done:
    mov edx, [jsy_atom_done]
    call jsobj_define
    BOX rax, rcx, JS_OBJ_BITS
    pop rsi
    pop rdx
    pop rcx
    ret

; iterator.next() for JC_ITERATOR objects
jsit_next:
    push rbx
    push rcx
    push rdx
    push rsi
    mov rax, rdx
    shr rax, 48
    cmp eax, JS_TAG_OBJECT
    jne .done
    mov ebx, edx
    cmp dword [rbx + JOBJ_CLASS], JC_ITERATOR
    jne .done
    call jsit_step_raw
    jc .done
    xor ecx, ecx
    jmp .result
.done:
    mov rax, JS_UNDEF
    mov ecx, 1
.result:
    call jsit_result
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; jsit_step_raw: RBX = a JC_ITERATOR (raw) -> RAX = its next value, CF=1 when
; it is exhausted (from then on it stays so)
; ------------------------------------------------------------------------------
jsit_step_raw:
    push rcx
    push rdx
    push rsi
    mov ecx, [rbx + JIO_POS]
    mov edx, [rbx + JIO_SRC]
    mov eax, [rbx + JIO_KIND]
    cmp eax, ITK_STRING
    je .string
    cmp eax, ITK_MAP_ENTRIES
    jae .map
    ; an array (or array-like with a length)
    mov rsi, [rbx + JIO_SRC]
    shr rsi, 48
    cmp esi, JS_TAG_OBJECT
    jne .end
    cmp byte [rdx + JH_KIND], JK_ARRAY
    jne .end
    cmp ecx, [rdx + JARR_LEN]
    jae .end
    inc dword [rbx + JIO_POS]
    cmp eax, ITK_KEYS
    je .key
    mov rsi, [rdx + JARR_ELEMS]
    mov rsi, [rsi + rcx*8]
    mov rax, JS_HOLE
    cmp rsi, rax
    jne .value
    mov rsi, JS_UNDEF
.value:
    cmp dword [rbx + JIO_KIND], ITK_ENTRIES
    je .entry
    mov rax, rsi
    jmp .yes
.key:
    mov eax, ecx
    call jsb_from_int
    jmp .yes
.entry:
    mov eax, ecx
    call jsb_from_int
    mov rdx, rsi
    call jsit_pair
    jmp .yes
.string:
    cmp ecx, [rdx + JSTR_LEN]
    jae .end
    call jsit_char_at               ; RDX = string, ECX = index -> RAX, ECX = bytes
    add [rbx + JIO_POS], ecx
    jmp .yes
.map:
    call jscol_iter_step            ; (collections.asm)
    jc .end
.yes:
    pop rsi
    pop rdx
    pop rcx
    clc
    ret
.end:
    mov dword [rbx + JIO_POS], 0x7FFFFFFF
    pop rsi
    pop rdx
    pop rcx
    stc
    ret

; jsit_pair: RAX, RDX = values -> RAX = [RAX, RDX] (value)
jsit_pair:
    push rcx
    push rsi
    push rdi
    mov rsi, rax
    mov rdi, rdx
    mov ecx, 2
    call jsarr_new
    mov rcx, rsi
    call jsarr_push
    mov rcx, rdi
    call jsarr_push
    BOX rax, rcx, JS_OBJ_BITS
    pop rdi
    pop rsi
    pop rcx
    ret

; jsit_char_at: RDX = string (raw), ECX = byte index -> RAX = the character
; there (a whole UTF-8 sequence, string value), ECX = its length in bytes
jsit_char_at:
    push rsi
    movzx eax, byte [rdx + JSTR_DATA + rcx]
    mov esi, 1
    cmp al, 0xC0
    jb .len
    inc esi
    cmp al, 0xE0
    jb .len
    inc esi
    cmp al, 0xF0
    jb .len
    inc esi
.len:
    ; not past the end
    mov eax, [rdx + JSTR_LEN]
    sub eax, ecx
    cmp esi, eax
    jbe .have
    mov esi, eax
.have:
    cmp esi, 1
    je .byte
    push rcx
    lea rax, [rdx + JSTR_DATA + rcx]
    push rsi
    mov ecx, esi
    mov rsi, rax
    call jsstr_new
    pop rsi
    pop rcx
    jmp .box
.byte:
    movzx eax, byte [rdx + JSTR_DATA + rcx]
    call jsstr_char
.box:
    call jsb_box_string
    mov ecx, esi
    pop rsi
    ret

; ------------------------------------------------------------------------------
; js_get_iterator: RAX = value -> RAX = its iterator (value[Symbol.iterator]()),
; RDX = the iterator's next method; TypeError if it is not iterable
; ------------------------------------------------------------------------------
js_get_iterator:
    push rcx
    push rdi
    push rsi
    push rax
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_SPECIAL
    jne .get
    cmp eax, 1
    jbe .not_iterable               ; undefined / null
.get:
    mov edx, [sym_iterator]
    call js_get
    call js_is_callable
    jnc .not_iterable
    mov rdx, [rsp]                  ; this = the value
    xor ecx, ecx
    call js_call
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .not_iterable
    push rax
    mov rdx, [jsy_atom_next]
    call js_get
    mov rdx, rax
    pop rax
    add rsp, 8
    pop rsi
    pop rdi
    pop rcx
    ret
.not_iterable:
    pop rax
    call js_to_string_safe
    mov rdi, rax
    lea rsi, [jsmsg_not_iterable]
    jmp js_throw_type

; js_to_string_safe: RAX = value -> RAX = a string for messages (symbols too)
js_to_string_safe:
    push rcx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_SYMBOL
    je .symbol
    cmp ecx, JS_TAG_OBJECT
    je .object
    pop rcx
    jmp js_to_string
.symbol:
    mov eax, eax
    call jsy_describe
    mov eax, eax
    pop rcx
    ret
.object:
    push rsi
    lea rsi, [jsb_class_object]
    call jsstr_from_cstr
    pop rsi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; js_iter_step: RAX = iterator, RDX = its next method -> RAX = the next
; value, CF=1 when done
; ------------------------------------------------------------------------------
js_iter_step:
    push rbx
    push rcx
    push rdx
    push rdi
    ; the engine's own iterators, without a call
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .call
    mov ebx, eax
    cmp dword [rbx + JOBJ_CLASS], JC_ITERATOR
    jne .call
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .call
    mov ecx, edx
    cmp byte [rcx + JH_KIND], JK_NATIVE
    jne .call
    lea rdi, [jsit_next]
    cmp [rcx + JFN_NATIVE], rdi
    jne .call
    call jsit_step_raw
    jmp .out
.call:
    xchg rax, rdx                   ; next.call(iterator)
    xor ecx, ecx
    call js_call
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .bad
    push rax
    mov rdx, [jsy_atom_done]
    call js_get
    call js_truthy
    pop rax
    jc .done
    mov rdx, [jsy_atom_value]
    call js_get
    clc
    jmp .out
.done:
    stc
.out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
.bad:
    call js_to_string_safe
    mov rdi, rax
    lea rsi, [jsmsg_iter_result]
    jmp js_throw_type

; jsit_collect: RAX = array (raw), RDX = an iterable -> its values appended
; (through the protocol)
jsit_collect:
    push rax
    push rcx
    push rdx
    push rsi
    mov rsi, rax
    mov rax, rdx
    call js_get_iterator
.item:
    push rax
    call js_iter_step
    jc .done
    mov rcx, rax
    mov rax, rsi
    call jsarr_push
    pop rax
    jmp .item
.done:
    pop rax
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ==============================================================================
; Generators
; ==============================================================================

; jsgen_start: (interpreter, GENSTART first in a generator function) -> the
; frame saved in a new coroutine; RAX = the generator object for the caller
jsgen_start:
    push rbx
    push rcx
    push rdx
    call jsco_new_bare
    mov rbx, rax
    mov ecx, JGEN_SIZE
    call js_alloc
    mov byte [rax + JH_KIND], JK_OBJECT
    mov dword [rax + JOBJ_CLASS], JC_GENERATOR
    mov rcx, [js_generator_proto]
    mov [rax + JOBJ_PROTO], rcx
    mov [rax + JGEN_CORO], rbx
    BOX rax, rcx, JS_OBJ_BITS
    mov [rbx + JCO_PROMISE], rax    ; (the generator, for this coroutine)
    mov dword [rbx + JCO_FLAGS], JFRF_GEN
    mov rdx, [vm_fp]
    mov [rdx + JFR_CORO], rbx
    call jsco_save
    pop rdx
    pop rcx
    pop rbx
    ret

; jsgen_yield: (interpreter, at a yield) RAX = the value -> the frame saved,
; the generator stopped at the yield; RAX = the value, for next()
jsgen_yield:
    push rbx
    push rdx
    mov rdx, [vm_fp]
    mov rbx, [rdx + JFR_CORO]
    call jsco_save
    mov rdx, [rbx + JCO_PROMISE]
    mov edx, edx
    mov dword [rdx + JGEN_STATE], GS_YIELDED
    pop rdx
    pop rbx
    ret

; jsgen_finish: (interpreter) a generator returns or an error leaves it ->
; finished; its try handlers dropped
jsgen_finish:
    push rbx
    push rdx
    mov rdx, [vm_fp]
    mov rbx, [rdx + JFR_CORO]
    call jsco_drop_handlers
    mov rbx, [rbx + JCO_PROMISE]
    mov ebx, ebx
    mov dword [rbx + JGEN_STATE], GS_DONE
    pop rdx
    pop rbx
    ret

; jsgen_delegate: RAX = iterator, RDX = its next, RCX = the value sent (yield*)
; -> next(value): CF=1 if it is done (RAX = its value, what yield* gives),
; else RAX = the value to yield
jsgen_delegate:
    push rbx
    push rcx
    push rdx
    push rdi
    push rcx
    mov rdi, rsp
    xchg rax, rdx
    mov ecx, 1
    call js_call
    add rsp, 8
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .bad
    mov rbx, rax
    mov rdx, [jsy_atom_done]
    call js_get
    call js_truthy
    setc cl
    mov rax, rbx
    mov rdx, [jsy_atom_value]
    call js_get
    shr cl, 1                       ; CF = done
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
.bad:
    call js_to_string_safe
    mov rdi, rax
    lea rsi, [jsmsg_iter_result]
    jmp js_throw_type

; jsgen_this: RDX = this -> RBX = the generator (raw); TypeError otherwise
jsgen_this:
    mov rbx, rdx
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    jne .bad
    mov ebx, edx
    cmp dword [rbx + JOBJ_CLASS], JC_GENERATOR
    jne .bad
    ret
.bad:
    mov rax, rdx
    call js_to_string_safe
    mov rdi, rax
    lea rsi, [jsmsg_not_generator]
    jmp js_throw_type

; gen.next(value) / gen.throw(reason) / gen.return(value)
jsgen_next:
    push rcx
    xor ecx, ecx
    jmp jsgen_resume_common
jsgen_throw:
    push rcx
    mov ecx, 1
    jmp jsgen_resume_common
jsgen_return:
    push rcx
    mov ecx, 2
jsgen_resume_common:
    push rbx
    push rdx
    push r8
    mov r8d, ecx                    ; 0 next, 1 throw, 2 return
    call jsgen_this
    xor eax, eax
    mov ecx, [rsp + 24]             ; (the argument count)
    call jsb_arg
    mov rdx, rax                    ; the value
    mov eax, [rbx + JGEN_STATE]
    cmp eax, GS_RUNNING
    je .running
    cmp eax, GS_DONE
    je .finished
    cmp r8d, 2
    je .close                       ; return(): finished (finally blocks are skipped)
    cmp eax, GS_START
    jne .resume
    cmp r8d, 1
    je .close_throw                 ; throw() before it started
.resume:
    mov dword [rbx + JGEN_STATE], GS_RUNNING
    mov rax, [rbx + JGEN_CORO]
    mov ecx, r8d
    call jsco_resume                ; until a yield or the end
    xor ecx, ecx
    cmp dword [rbx + JGEN_STATE], GS_YIELDED
    je .result
    mov dword [rbx + JGEN_STATE], GS_DONE
    mov ecx, 1
    jmp .result
.finished:
    cmp r8d, 1
    je .throw
    mov rax, JS_UNDEF
    cmp r8d, 2
    jne .done_result
    mov rax, rdx
.done_result:
    mov ecx, 1
.result:
    call jsit_result
    pop r8
    pop rdx
    pop rbx
    pop rcx
    ret
.close:
    mov dword [rbx + JGEN_STATE], GS_DONE
    mov rax, rdx
    mov ecx, 1
    jmp .result
.close_throw:
    mov dword [rbx + JGEN_STATE], GS_DONE
.throw:
    mov rax, rdx
    jmp js_throw_value
.running:
    lea rsi, [jsmsg_gen_running]
    xor edi, edi
    jmp js_throw_type
