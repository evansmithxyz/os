; ==============================================================================
; Antigravity OS - JavaScript heap: allocation, strings and atoms
; ------------------------------------------------------------------------------
; The heap is a bump allocator over JS_HEAP_ADDR; js_heap_reset empties it
; before every script run (a garbage collector comes with step 3).
;
; Strings are immutable byte strings (UTF-8 passes through unchanged). Atoms
; are interned strings: one copy per distinct text, so property names compare
; by pointer. Every property key, identifier and string literal is an atom.
; Keyword atoms carry their KW_* id in JH_AUX, so the lexer needs no lookup.
; ==============================================================================

[bits 64]

JSSTR_BUCKETS           equ 16384       ; atom hash table (power of two)
JSSTR_MAX_LEN           equ 0x01000000  ; 16 MB

; Keyword ids (JH_AUX of the keyword's atom)
KW_VAR                  equ 1
KW_LET                  equ 2
KW_CONST                equ 3
KW_FUNCTION             equ 4
KW_RETURN               equ 5
KW_IF                   equ 6
KW_ELSE                 equ 7
KW_FOR                  equ 8
KW_WHILE                equ 9
KW_DO                   equ 10
KW_BREAK                equ 11
KW_CONTINUE             equ 12
KW_NEW                  equ 13
KW_TYPEOF               equ 14
KW_INSTANCEOF           equ 15
KW_IN                   equ 16
KW_DELETE               equ 17
KW_VOID                 equ 18
KW_THIS                 equ 19
KW_NULL                 equ 20
KW_TRUE                 equ 21
KW_FALSE                equ 22
KW_THROW                equ 23
KW_TRY                  equ 24
KW_CATCH                equ 25
KW_FINALLY              equ 26
KW_SWITCH               equ 27
KW_CASE                 equ 28
KW_DEFAULT              equ 29
KW_CLASS                equ 30
KW_EXTENDS              equ 31
KW_SUPER                equ 32
KW_IMPORT               equ 33
KW_EXPORT               equ 34
KW_DEBUGGER             equ 35
KW_WITH                 equ 36
KW_ENUM                 equ 37

; JSATOM label, "text" [, keyword id]: an atom made by js_heap_reset, its
; pointer kept in the qword `label`
%macro JSATOM 2-3 0
    [section .bss]
    %1: resq 1
    [section .rodata]
    dq %1
    db %3
    db %%end - %%start
    %%start: db %2
    %%end:
    __SECT__
%endmacro

section .rodata
jsatom_table:
JSATOM atom_length,      "length"
JSATOM atom_prototype,   "prototype"
JSATOM atom_constructor, "constructor"
JSATOM atom_name,        "name"
JSATOM atom_message,     "message"
JSATOM atom_stack,       "stack"
JSATOM atom_tostring,    "toString"
JSATOM atom_valueof,     "valueOf"
JSATOM atom_arguments,   "arguments"
JSATOM atom_of,          "of"
JSATOM atom_static,      "static"
JSATOM atom_get,         "get"
JSATOM atom_set,         "set"
JSATOM atom_rest_args,   " args"
JSATOM atom_then,        "then"
JSATOM atom_async,       "async"
JSATOM atom_await,       "await"
JSATOM atom_yield,       "yield"
JSATOM atom_symbol_t,    "symbol"
JSATOM atom_undefined,   "undefined"
JSATOM atom_object,      "object"
JSATOM atom_boolean,     "boolean"
JSATOM atom_number,      "number"
JSATOM atom_string,      "string"
JSATOM atom_function,    "function"
JSATOM atom_null,        "null"
JSATOM atom_true,        "true"
JSATOM atom_false,       "false"
JSATOM atom_nan,         "NaN"
JSATOM atom_infinity,    "Infinity"
JSATOM atom_let,         "let", KW_LET
JSATOM atom_var,         "var", KW_VAR
JSATOM atom_kw_const,    "const", KW_CONST
JSATOM atom_kw_function, "function", KW_FUNCTION
JSATOM atom_kw_return,   "return", KW_RETURN
JSATOM atom_kw_if,       "if", KW_IF
JSATOM atom_kw_else,     "else", KW_ELSE
JSATOM atom_kw_for,      "for", KW_FOR
JSATOM atom_kw_while,    "while", KW_WHILE
JSATOM atom_kw_do,       "do", KW_DO
JSATOM atom_kw_break,    "break", KW_BREAK
JSATOM atom_kw_continue, "continue", KW_CONTINUE
JSATOM atom_kw_new,      "new", KW_NEW
JSATOM atom_kw_typeof,   "typeof", KW_TYPEOF
JSATOM atom_kw_instanceof, "instanceof", KW_INSTANCEOF
JSATOM atom_kw_in,       "in", KW_IN
JSATOM atom_kw_delete,   "delete", KW_DELETE
JSATOM atom_kw_void,     "void", KW_VOID
JSATOM atom_kw_this,     "this", KW_THIS
JSATOM atom_kw_null,     "null", KW_NULL
JSATOM atom_kw_true,     "true", KW_TRUE
JSATOM atom_kw_false,    "false", KW_FALSE
JSATOM atom_kw_throw,    "throw", KW_THROW
JSATOM atom_kw_try,      "try", KW_TRY
JSATOM atom_kw_catch,    "catch", KW_CATCH
JSATOM atom_kw_finally,  "finally", KW_FINALLY
JSATOM atom_kw_switch,   "switch", KW_SWITCH
JSATOM atom_kw_case,     "case", KW_CASE
JSATOM atom_kw_default,  "default", KW_DEFAULT
JSATOM atom_kw_class,    "class", KW_CLASS
JSATOM atom_kw_extends,  "extends", KW_EXTENDS
JSATOM atom_kw_super,    "super", KW_SUPER
JSATOM atom_kw_import,   "import", KW_IMPORT
JSATOM atom_kw_export,   "export", KW_EXPORT
JSATOM atom_kw_debugger, "debugger", KW_DEBUGGER
JSATOM atom_kw_with,     "with", KW_WITH
JSATOM atom_kw_enum,     "enum", KW_ENUM
; DOM (kernel/js/jsdom.asm)
JSATOM atom_d_tagName, "tagName"
JSATOM atom_d_nodeName, "nodeName"
JSATOM atom_d_nodeType, "nodeType"
JSATOM atom_d_nodeValue, "nodeValue"
JSATOM atom_d_data, "data"
JSATOM atom_d_id, "id"
JSATOM atom_d_className, "className"
JSATOM atom_d_textContent, "textContent"
JSATOM atom_d_innerText, "innerText"
JSATOM atom_d_innerHTML, "innerHTML"
JSATOM atom_d_outerHTML, "outerHTML"
JSATOM atom_d_parentNode, "parentNode"
JSATOM atom_d_parentElement, "parentElement"
JSATOM atom_d_firstChild, "firstChild"
JSATOM atom_d_lastChild, "lastChild"
JSATOM atom_d_nextSibling, "nextSibling"
JSATOM atom_d_previousSibling, "previousSibling"
JSATOM atom_d_firstElementChild, "firstElementChild"
JSATOM atom_d_lastElementChild, "lastElementChild"
JSATOM atom_d_nextElementSibling, "nextElementSibling"
JSATOM atom_d_previousElementSibling, "previousElementSibling"
JSATOM atom_d_children, "children"
JSATOM atom_d_childNodes, "childNodes"
JSATOM atom_d_childElementCount, "childElementCount"
JSATOM atom_d_style, "style"
JSATOM atom_d_classList, "classList"
JSATOM atom_d_value, "value"
JSATOM atom_d_checked, "checked"
JSATOM atom_d_disabled, "disabled"
JSATOM atom_d_hidden, "hidden"
JSATOM atom_d_href, "href"
JSATOM atom_d_src, "src"
JSATOM atom_d_title, "title"
JSATOM atom_d_type, "type"
JSATOM atom_d_alt, "alt"
JSATOM atom_d_placeholder, "placeholder"
JSATOM atom_d_rel, "rel"
JSATOM atom_d_target, "target"
JSATOM atom_d_body, "body"
JSATOM atom_d_head, "head"
JSATOM atom_d_documentElement, "documentElement"
JSATOM atom_d_readyState, "readyState"
JSATOM atom_d_cssText, "cssText"
JSATOM atom_d_isConnected, "isConnected"
JSATOM atom_d_ownerDocument, "ownerDocument"
JSATOM atom_d_defaultPrevented, "defaultPrevented"
JSATOM atom_d_currentTarget, "currentTarget"
JSATOM atom_d_bubbles, "bubbles"
JSATOM atom_d_window, "window"
JSATOM atom_d_self, "self"
JSATOM atom_d_document, "document"
JSATOM atom_d_location, "location"
JSATOM atom_d_navigator, "navigator"
JSATOM atom_d_innerWidth, "innerWidth"
JSATOM atom_d_innerHeight, "innerHeight"
JSATOM atom_d_userAgent, "userAgent"
JSATOM atom_d_protocol, "protocol"
JSATOM atom_d_host, "host"
JSATOM atom_d_hostname, "hostname"
JSATOM atom_d_pathname, "pathname"
JSATOM atom_d_search, "search"
JSATOM atom_d_hash, "hash"
JSATOM atom_d_origin, "origin"
JSATOM atom_d_language, "language"
JSATOM atom_d_cookie, "cookie"
JSATOM atom_d_URL, "URL"
JSATOM atom_d_clientX, "clientX"
JSATOM atom_d_clientY, "clientY"
JSATOM atom_d_button, "button"
JSATOM atom_d_timeStamp, "timeStamp"
JSATOM atom_d_returnValue, "returnValue"
JSATOM atom_d_listeners, " listeners"          ; internal: event listeners
JSATOM atom_d_stop, " stop"                    ; internal: stopPropagation
JSATOM atom_d_style_obj, " style"              ; internal: cached style object
JSATOM atom_d_classlist_obj, " classList"      ; internal: cached classList
    dq 0

section .bss
alignb 8
js_heap_ptr:            resq 1
atom_empty:             resq 1
js_heap_end:            resq 1
jsstr_chars:            resq 256        ; one-character strings, made on demand
jsstr_buckets:          resd JSSTR_BUCKETS

section .text

; ------------------------------------------------------------------------------
; js_heap_reset: empty the heap and the atom table, then make the JSATOMs
; ------------------------------------------------------------------------------
js_heap_reset:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    call jsgc_reset
    mov qword [js_heap_ptr], JS_HEAP_ADDR
    mov qword [js_heap_end], JS_HEAP_ADDR + JS_HEAP_SIZE
    lea rdi, [jsstr_buckets]
    mov ecx, JSSTR_BUCKETS
    xor eax, eax
    rep stosd
    lea rdi, [jsstr_chars]
    mov ecx, 256
    rep stosq
    xor ecx, ecx
    call jsstr_atom
    mov [atom_empty], rax
    lea rbx, [jsatom_table]
.atom:
    mov rdi, [rbx]
    test rdi, rdi
    jz .done
    movzx ecx, byte [rbx + 9]
    lea rsi, [rbx + 10]
    call jsstr_atom
    mov [rdi], rax
    movzx ecx, byte [rbx + 8]
    mov [rax + JH_AUX], cx
    movzx ecx, byte [rbx + 9]
    lea rbx, [rbx + rcx + 10]
    jmp .atom
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; (js_alloc, the allocator, is in gc.asm)

; ==============================================================================
; Strings
; ==============================================================================

; jsstr_alloc: ECX = length -> RAX = new string, data zeroed (fill it in)
jsstr_alloc:
    cmp ecx, JSSTR_MAX_LEN
    ja .too_long
    push rcx
    add ecx, JSTR_DATA + 1
    call js_alloc
    or byte [rax - 8 + GCH_FLAGS], GCF_LEAF
    pop rcx
    mov byte [rax + JH_KIND], JK_STRING
    mov [rax + JSTR_LEN], ecx
    ret
.too_long:
    mov edx, JE_RANGE
    lea rsi, [jsmsg_string_length]
    xor edi, edi
    jmp js_throw

; jsstr_new: RSI = bytes, ECX = length -> RAX = new string
jsstr_new:
    call jsstr_alloc
    push rcx
    push rsi
    push rdi
    lea rdi, [rax + JSTR_DATA]
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    ret

; jsstr_concat: RAX = string a, RDX = string b -> RAX = new string a + b
jsstr_concat:
    push rcx
    push rsi
    push rdi
    push r8
    mov r8, rax
    mov ecx, [rdx + JSTR_LEN]
    test ecx, ecx
    jz .keep_a
    mov ecx, [r8 + JSTR_LEN]
    test ecx, ecx
    jz .take_b
    add ecx, [rdx + JSTR_LEN]
    call jsstr_alloc
    lea rdi, [rax + JSTR_DATA]
    lea rsi, [r8 + JSTR_DATA]
    mov ecx, [r8 + JSTR_LEN]
    rep movsb
    lea rsi, [rdx + JSTR_DATA]
    mov ecx, [rdx + JSTR_LEN]
    rep movsb
    jmp .out
.take_b:
    mov rax, rdx
    jmp .out
.keep_a:
    mov rax, r8
.out:
    pop r8
    pop rdi
    pop rsi
    pop rcx
    ret

; jsstr_hash_bytes: RSI = bytes, ECX = length -> EAX = FNV-1a hash (never 0)
jsstr_hash_bytes:
    push rcx
    push rdx
    push rsi
    mov eax, 2166136261
.loop:
    test ecx, ecx
    jz .done
    movzx edx, byte [rsi]
    xor eax, edx
    imul eax, eax, 16777619
    inc rsi
    dec ecx
    jmp .loop
.done:
    test eax, eax
    jnz .out
    inc eax
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; jsstr_equal: RAX = string, RDX = string -> CF=1 when the texts are equal
jsstr_equal:
    cmp rax, rdx
    je .yes
    push rcx
    push rsi
    push rdi
    mov ecx, [rax + JSTR_LEN]
    cmp ecx, [rdx + JSTR_LEN]
    jne .no_pop
    lea rsi, [rax + JSTR_DATA]
    lea rdi, [rdx + JSTR_DATA]
    repe cmpsb
    jne .no_pop
    pop rdi
    pop rsi
    pop rcx
.yes:
    stc
    ret
.no_pop:
    pop rdi
    pop rsi
    pop rcx
    clc
    ret

; jsstr_compare: RAX = string a, RDX = string b -> EAX = -1, 0, 1 (byte order)
jsstr_compare:
    push rbx
    push rcx
    push rsi
    push rdi
    mov ebx, [rax + JSTR_LEN]
    mov ecx, ebx
    cmp ecx, [rdx + JSTR_LEN]
    jbe .min
    mov ecx, [rdx + JSTR_LEN]
.min:
    lea rsi, [rax + JSTR_DATA]
    lea rdi, [rdx + JSTR_DATA]
    test ecx, ecx
    jz .lengths
    repe cmpsb
    je .lengths
    ja .greater                     ; unsigned byte compare
    jmp .less
.lengths:
    cmp ebx, [rdx + JSTR_LEN]
    ja .greater
    jb .less
    xor eax, eax
    jmp .out
.greater:
    mov eax, 1
    jmp .out
.less:
    mov eax, -1
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; jsstr_atom: RSI = bytes, ECX = length -> RAX = the atom with that text
; jsstr_find_atom: same, but CF=1 (RAX = 0) when no such atom exists yet
; jsstr_intern: RAX = string -> RAX = its atom
; ------------------------------------------------------------------------------
jsstr_atom:
    push rbx
    push rdx
    call jsstr_lookup
    jnc .out
    ; not there: make it and link it into its bucket (RBX = bucket slot)
    call jsstr_new
    mov [rax + JSTR_HASH], edx
    or byte [rax + JH_FLAGS], JSF_ATOM
    or byte [rax - 8 + GCH_FLAGS], GCF_PERM
    mov edx, [rbx]
    mov [rax + JSTR_NEXT], edx
    mov [rbx], eax
.out:
    pop rdx
    pop rbx
    ret

jsstr_find_atom:
    push rbx
    push rdx
    call jsstr_lookup
    pop rdx
    pop rbx
    ret

; jsstr_lookup: RSI, ECX -> RAX = atom (CF=0), or CF=1 with RBX = bucket slot
; and EDX = hash
jsstr_lookup:
    push rdi
    push r8
    call jsstr_hash_bytes
    mov edx, eax
    and eax, JSSTR_BUCKETS - 1
    lea rbx, [jsstr_buckets]
    lea rbx, [rbx + rax*4]
    mov r8d, [rbx]
.chain:
    test r8d, r8d
    jz .missing
    cmp [r8 + JSTR_HASH], edx
    jne .next
    cmp [r8 + JSTR_LEN], ecx
    jne .next
    push rcx
    push rsi
    lea rdi, [r8 + JSTR_DATA]
    repe cmpsb
    pop rsi
    pop rcx
    je .found
.next:
    mov r8d, [r8 + JSTR_NEXT]
    jmp .chain
.found:
    mov rax, r8
    pop r8
    pop rdi
    clc
    ret
.missing:
    xor eax, eax
    pop r8
    pop rdi
    stc
    ret

jsstr_intern:
    test byte [rax + JH_FLAGS], JSF_ATOM
    jnz .done
    push rcx
    push rsi
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    call jsstr_atom
    pop rsi
    pop rcx
.done:
    ret

; jsstr_char: EAX = byte -> RAX = the one-character string
jsstr_char:
    push rcx
    push rdx
    push rsi
    movzx edx, al
    lea rcx, [jsstr_chars]
    mov rax, [rcx + rdx*8]
    test rax, rax
    jnz .out
    push rdx
    mov rsi, rsp                    ; the byte is the low byte of the pushed RDX
    mov ecx, 1
    call jsstr_atom
    pop rdx
    lea rcx, [jsstr_chars]
    mov [rcx + rdx*8], rax
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; jsstr_from_cstr: RSI = NUL-terminated text -> RAX = its atom
jsstr_from_cstr:
    push rcx
    call strlen
    mov ecx, eax
    call jsstr_atom
    pop rcx
    ret

; jsstr_array_index: RAX = string -> EAX = array index, CF=1 if the string is
; not a canonical index ("0", "17"; not "017", "1.0", "-1")
jsstr_array_index:
    push rcx
    push rdx
    push rsi
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    test ecx, ecx
    jz .no
    cmp ecx, 10
    ja .no
    cmp byte [rsi], '0'
    jne .digits
    cmp ecx, 1
    jne .no
.digits:
    xor eax, eax
.loop:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .no
    imul rax, rax, 10
    add rax, rdx
    inc rsi
    dec ecx
    jnz .loop
    mov edx, 0xFFFFFFFE
    cmp rax, rdx
    ja .no
    clc
    jmp .out
.no:
    stc
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

section .rodata
jsmsg_out_of_memory:    db "out of memory", 0
jsmsg_string_length:    db "Invalid string length", 0
