; ==============================================================================
; Antigravity OS - JavaScript regular expressions: RegExp and string methods
; ------------------------------------------------------------------------------
; A RegExp (class JC_REGEXP) keeps its compiled program (regexp.asm), its
; source, flags, group count and group names; lastIndex is an ordinary
; (hidden) property. exec / test and the string methods match, matchAll,
; search, replace, replaceAll and split with a regular expression are here;
; stdlib.asm's replace / replaceAll / split pass regular expressions on.
; ==============================================================================

[bits 64]

JRE_PROG                equ 32          ; raw: the program
JRE_SOURCE              equ 40          ; string value
JRE_FLAGS               equ 48          ; dword: RXF_*
JRE_NGROUPS             equ 52          ; dword: capturing groups
JRE_NAMES               equ 56          ; raw array of group names, or 0
JRE_SIZE                equ 64

section .bss
alignb 8
js_regexp_proto:        resq 1
jsre_regexp_ctor:       resq 1
jsre_atom_last_index:   resq 1
jsre_atom_index:        resq 1
jsre_atom_input:        resq 1
jsre_atom_groups:       resq 1

section .rodata
jsre_ctors:
JSCTOR jsre_regexp_ctor, jsre_regexp, 2, js_regexp_proto, "RegExp"
    dq 0

jsre_natives:
JSNATIVE js_regexp_proto, "exec", jsre_exec_method, 1
JSNATIVE js_regexp_proto, "test", jsre_test_method, 1
JSNATIVE js_regexp_proto, "toString", jsre_to_string, 0
JSNATIVE js_string_proto, "match", jsre_string_match, 1
JSNATIVE js_string_proto, "matchAll", jsre_string_match_all, 1
JSNATIVE js_string_proto, "search", jsre_string_search, 1
    dq 0

; the flag getters: name, flag bit
jsre_getters:
    dq jsre_str_global, RXF_GLOBAL
    dq jsre_str_ignore_case, RXF_ICASE
    dq jsre_str_multiline, RXF_MULTILINE
    dq jsre_str_dot_all, RXF_DOTALL
    dq jsre_str_unicode, RXF_UNICODE
    dq jsre_str_sticky, RXF_STICKY
    dq jsre_str_has_indices, RXF_INDICES
    dq 0
jsre_str_global:        db "global", 0
jsre_str_ignore_case:   db "ignoreCase", 0
jsre_str_multiline:     db "multiline", 0
jsre_str_dot_all:       db "dotAll", 0
jsre_str_unicode:       db "unicode", 0
jsre_str_sticky:        db "sticky", 0
jsre_str_has_indices:   db "hasIndices", 0
jsre_str_source:        db "source", 0
jsre_str_flags:         db "flags", 0
jsre_str_last_index:    db "lastIndex", 0
jsre_str_index:         db "index", 0
jsre_str_input:         db "input", 0
jsre_str_groups:        db "groups", 0
jsre_str_empty_group:   db "(?:)", 0
; the flags in the order `flags` lists them, with their bits
jsre_flag_order:        db 'd', RXF_INDICES, 'g', RXF_GLOBAL, 'i', RXF_ICASE, 'm', RXF_MULTILINE
                        db 's', RXF_DOTALL, 'u', RXF_UNICODE, 'y', RXF_STICKY, 0
jsmsg_not_regexp:       db "Method RegExp.prototype.% called on incompatible receiver", 0
jsmsg_match_all:        db "String.prototype.% called with a non-global RegExp argument", 0
jsre_str_exec:          db "exec", 0
jsre_str_match_all:     db "matchAll", 0
jsre_str_replace_all:   db "replaceAll", 0

section .text

; ------------------------------------------------------------------------------
; jsre_init: RegExp (js_init_builtins)
; ------------------------------------------------------------------------------
jsre_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov rax, [js_object_proto]
    call jsobj_new
    mov [js_regexp_proto], rax
    lea r8, [jsre_ctors]
    call jsb_define_ctors
    lea r8, [jsre_natives]
    call jsb_define_natives
%macro JSRE_ATOM 2
    lea rsi, [%2]
    call jsstr_from_cstr
    mov [%1], rax
%endmacro
    JSRE_ATOM jsre_atom_last_index, jsre_str_last_index
    JSRE_ATOM jsre_atom_index, jsre_str_index
    JSRE_ATOM jsre_atom_input, jsre_str_input
    JSRE_ATOM jsre_atom_groups, jsre_str_groups
    ; global, ignoreCase, ...: getters reading the flags (R10 data = the bit)
    lea rbx, [jsre_getters]
.getter:
    mov rsi, [rbx]
    test rsi, rsi
    jz .source
    call jsstr_from_cstr
    mov rdx, rax
    bts rdx, 32
    lea rax, [jsre_flag_getter]
    push rdx
    mov rdx, [rbx + 8]
    call jsa_closure
    pop rdx
    mov rcx, rax
    mov rax, [js_regexp_proto]
    mov r8d, 1
    call jsobj_define_accessor
    add rbx, 16
    jmp .getter
.source:
    lea rsi, [jsre_str_source]
    lea rax, [jsre_source_getter]
    call .define_getter
    lea rsi, [jsre_str_flags]
    lea rax, [jsre_flags_getter]
    call .define_getter
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.define_getter:
    push rax
    call jsstr_from_cstr
    mov rdx, rax
    bts rdx, 32
    pop rax
    call jsy_native0
    mov rcx, rax
    mov rax, [js_regexp_proto]
    mov r8d, 1
    jmp jsobj_define_accessor

; ------------------------------------------------------------------------------
; jsre_new: RAX = pattern, RDX = flags (heap strings) -> RAX = a new RegExp
; (value); a bad pattern throws a SyntaxError
; ------------------------------------------------------------------------------
jsre_new:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov rsi, rax
    call jsre_compile               ; RAX = program, ECX groups, EDX flags, R8 names
    push rax
    push rcx
    push rdx
    mov ecx, JRE_SIZE
    call js_alloc
    mov rbx, rax
    mov byte [rbx + JH_KIND], JK_OBJECT
    mov dword [rbx + JOBJ_CLASS], JC_REGEXP
    mov rax, [js_regexp_proto]
    mov [rbx + JOBJ_PROTO], rax
    pop rdx
    pop rcx
    pop rax
    mov [rbx + JRE_PROG], rax
    mov [rbx + JRE_FLAGS], edx
    mov [rbx + JRE_NGROUPS], ecx
    mov [rbx + JRE_NAMES], r8
    mov rax, rsi
    call jsb_box_string
    mov [rbx + JRE_SOURCE], rax
    ; lastIndex = 0 (hidden, writable)
    xor ecx, ecx
    mov edx, [jsre_atom_last_index]
    bts rdx, 32
    mov rax, rbx
    call jsobj_define
    mov rax, rbx
    BOX rax, rcx, JS_OBJ_BITS
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsre_is: RAX = value -> CF=1 if it is a RegExp
jsre_is:
    push rcx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .no
    mov ecx, eax
    cmp byte [rcx + JH_KIND], JK_OBJECT
    jne .no
    cmp dword [rcx + JOBJ_CLASS], JC_REGEXP
    jne .no
    pop rcx
    stc
    ret
.no:
    pop rcx
    clc
    ret

; RegExp(pattern, flags) / new RegExp(...)
jsre_regexp:
    push rcx
    push rdx
    push rsi
    xor eax, eax
    call jsb_arg
    call jsre_is
    jnc .text
    ; from another RegExp: its source, and its flags unless new ones are given
    mov esi, eax
    mov rax, [rsi + JRE_SOURCE]
    mov eax, eax
    push rax
    mov eax, 1
    call jsb_arg
    mov rdx, JS_UNDEF
    cmp rax, rdx
    jne .new_flags
    mov eax, [rsi + JRE_FLAGS]
    call jsre_flags_string
    jmp .flags_done
.text:
    mov rdx, JS_UNDEF
    cmp rax, rdx
    jne .to_string
    lea rsi, [jsre_str_empty_group]
    call jsstr_from_cstr
    jmp .pattern
.to_string:
    call js_to_string
.pattern:
    push rax
    mov eax, 1
    call jsb_arg
    mov rdx, JS_UNDEF
    cmp rax, rdx
    jne .new_flags
    mov rax, [atom_empty]
    jmp .flags_done
.new_flags:
    call js_to_string
.flags_done:
    mov rdx, rax
    pop rax
    call jsre_new
    pop rsi
    pop rdx
    pop rcx
    ret

; jsre_flags_string: EAX = RXF_* -> RAX = "dgimsuy" (those set; heap string)
jsre_flags_string:
    push rcx
    push rdx
    push rsi
    push rdi
    sub rsp, 16
    mov rdi, rsp
    lea rsi, [jsre_flag_order]
    mov edx, eax
.flag:
    mov cl, [rsi]
    test cl, cl
    jz .done
    test dl, [rsi + 1]
    jz .next
    mov [rdi], cl
    inc rdi
.next:
    add rsi, 2
    jmp .flag
.done:
    mov rcx, rdi
    mov rsi, rsp
    sub rcx, rsi
    call jsstr_new
    add rsp, 16
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; jsre_this: RDX = this -> RBX = the RegExp (raw); TypeError otherwise
jsre_this:
    mov rax, rdx
    call jsre_is
    jnc .bad
    mov ebx, edx
    ret
.bad:
    call jsstr_from_cstr
    mov rdi, rax
    lea rsi, [jsmsg_not_regexp]
    jmp js_throw_type

; the flag getters: R10 data = the bit
jsre_flag_getter:
    push rbx
    push rsi
    lea rsi, [jsre_str_flags]
    call jsre_this
    mov eax, [rbx + JRE_FLAGS]
    test rax, [r10 + JFN_DATA]
    setnz al
    shr al, 1
    call js_bool
    pop rsi
    pop rbx
    ret

jsre_source_getter:
    push rbx
    push rsi
    lea rsi, [jsre_str_source]
    call jsre_this
    mov rax, [rbx + JRE_SOURCE]
    pop rsi
    pop rbx
    ret

jsre_flags_getter:
    push rbx
    push rsi
    lea rsi, [jsre_str_flags]
    call jsre_this
    mov eax, [rbx + JRE_FLAGS]
    call jsre_flags_string
    call jsb_box_string
    pop rsi
    pop rbx
    ret

; regexp.toString() -> "/source/flags"
jsre_to_string:
    push rbx
    push rdx
    push rsi
    lea rsi, [jsre_str_source]
    call jsre_this
    call jsre_text
    call jsb_box_string
    pop rsi
    pop rdx
    pop rbx
    ret

; jsre_text: RBX = RegExp -> RAX = "/source/flags" (heap string)
jsre_text:
    push rdx
    mov eax, '/'
    call jsstr_char
    mov rdx, [rbx + JRE_SOURCE]
    mov edx, edx
    call jsstr_concat
    push rax
    mov eax, '/'
    call jsstr_char
    mov rdx, rax
    pop rax
    call jsstr_concat
    push rax
    mov eax, [rbx + JRE_FLAGS]
    call jsre_flags_string
    mov rdx, rax
    pop rax
    call jsstr_concat
    pop rdx
    ret

; ==============================================================================
; Matching
; ==============================================================================

; jsre_find: RBX = RegExp, R8 = input (heap string), EDX = where to start,
; EAX = extra RXF_* (RXF_STICKY) -> CF=0 if it matches: ECX = the match's
; start, EDX = its end (the captures in JS_RX_ADDR)
jsre_find:
    push rax
    push rsi
    push r8
    push r9
    mov ecx, [r8 + JSTR_LEN]
    cmp edx, ecx
    ja .none
    lea rsi, [r8 + JSTR_DATA]
    or eax, [rbx + JRE_FLAGS]
    mov r8d, eax
    mov r9d, [rbx + JRE_NGROUPS]
    push rbx
    mov rbx, [rbx + JRE_PROG]
    call jsre_match
    pop rbx
    jc .none
    mov rax, JS_RX_ADDR + RX_CAPS
    mov rcx, [rax]
    mov rdx, [rax + 8]
    pop r9
    pop r8
    pop rsi
    pop rax
    clc
    ret
.none:
    pop r9
    pop r8
    pop rsi
    pop rax
    stc
    ret

; jsre_captures: RBX = RegExp, R8 = input -> RAX = a raw array of the match
; and its groups (strings, undefined for groups that took no part), copied
; out of JS_RX_ADDR
jsre_captures:
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    mov ecx, [rbx + JRE_NGROUPS]
    inc ecx
    mov r9d, ecx
    call jsarr_new
    mov rdi, rax
    mov rsi, JS_RX_ADDR + RX_CAPS
.group:
    test r9d, r9d
    jz .done
    mov rax, [rsi]
    mov rdx, [rsi + 8]
    mov rcx, JS_UNDEF
    cmp rax, -1
    je .push
    cmp rdx, -1
    je .push
    push rsi
    lea rsi, [r8 + JSTR_DATA + rax]
    mov rcx, rdx
    sub rcx, rax
    call jsstr_new
    pop rsi
    mov rcx, rax
    BOX rcx, rax, JS_STR_BITS
.push:
    mov rax, rdi
    call jsarr_push
    add rsi, 16
    dec r9d
    jmp .group
.done:
    mov rax, rdi
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; jsre_groups: RBX = RegExp, RAX = captures (raw array) -> RAX = the groups
; object {name: value} (value), or undefined without named groups
jsre_groups:
    push rcx
    push rdx
    push rsi
    push rdi
    mov rdi, [rbx + JRE_NAMES]
    test rdi, rdi
    jz .none
    mov rsi, rax
    call jsobj_new_plain
    push rax
    xor ecx, ecx
.name:
    cmp ecx, [rdi + JARR_LEN]
    jae .done
    mov rdx, [rdi + JARR_ELEMS]
    mov rdx, [rdx + rcx*8]
    push rdx
    shr rdx, 48
    cmp edx, JS_TAG_STRING
    pop rdx
    jne .next
    mov edx, edx
    push rcx
    mov rax, JS_UNDEF
    cmp ecx, [rsi + JARR_LEN]
    jae .value
    mov rax, [rsi + JARR_ELEMS]
    mov rax, [rax + rcx*8]
.value:
    mov rcx, rax
    mov rax, [rsp + 8]
    call jsobj_define
    pop rcx
.next:
    inc ecx
    jmp .name
.done:
    pop rax
    BOX rax, rcx, JS_OBJ_BITS
    jmp .out
.none:
    mov rax, JS_UNDEF
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; jsre_last_index: RBX = RegExp -> RAX = lastIndex as an integer (0 ..)
jsre_last_index:
    push rdx
    mov rax, rbx
    BOX rax, rdx, JS_OBJ_BITS
    mov rdx, [jsre_atom_last_index]
    call js_get
    call js_to_number
    call jsb_integer
    test rax, rax
    jns .out
    xor eax, eax
.out:
    pop rdx
    ret

; jsre_set_last_index: RBX = RegExp, EAX = new lastIndex
jsre_set_last_index:
    push rax
    push rcx
    push rdx
    call jsb_from_int
    mov rcx, rax
    mov rax, rbx
    BOX rax, rdx, JS_OBJ_BITS
    mov rdx, [jsre_atom_last_index]
    call js_put
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsre_exec: RBX = RegExp, R8 = input (heap string) -> RAX = the exec result
; (value) or null; lastIndex follows the global / sticky flags
; ------------------------------------------------------------------------------
jsre_exec:
    push rcx
    push rdx
    push rsi
    xor edx, edx
    test dword [rbx + JRE_FLAGS], RXF_GLOBAL | RXF_STICKY
    jz .find
    call jsre_last_index
    mov edx, [r8 + JSTR_LEN]
    cmp rax, rdx
    ja .fail
    mov edx, eax
.find:
    xor eax, eax
    call jsre_find
    jc .fail
    test dword [rbx + JRE_FLAGS], RXF_GLOBAL | RXF_STICKY
    jz .result
    mov eax, edx
    call jsre_set_last_index
.result:
    call jsre_result                ; ECX = index
    jmp .out
.fail:
    test dword [rbx + JRE_FLAGS], RXF_GLOBAL | RXF_STICKY
    jz .null
    xor eax, eax
    call jsre_set_last_index
.null:
    mov rax, JS_NULL
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; jsre_result: RBX = RegExp, R8 = input, ECX = the match's index (captures in
; JS_RX_ADDR) -> RAX = [match, groups...] with index, input and groups
jsre_result:
    push rcx
    push rdx
    push rsi
    push rdi
    mov edi, ecx                    ; the index
    call jsre_captures
    mov rsi, rax                    ; the array
    call jsre_groups
    push rax
    mov eax, edi
    call jsb_from_int
    mov rcx, rax
    mov rax, rsi
    mov edx, [jsre_atom_index]
    call jsobj_define
    mov rcx, r8
    BOX rcx, rdx, JS_STR_BITS
    mov rax, rsi
    mov edx, [jsre_atom_input]
    call jsobj_define
    pop rcx
    mov rax, rsi
    mov edx, [jsre_atom_groups]
    call jsobj_define
    mov rax, rsi
    BOX rax, rcx, JS_OBJ_BITS
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; regexp.exec(string)
jsre_exec_method:
    push rbx
    push rsi
    push r8
    lea rsi, [jsre_str_exec]
    call jsre_this
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov r8, rax
    call jsre_exec
    pop r8
    pop rsi
    pop rbx
    ret

; regexp.test(string)
jsre_test_method:
    call jsre_exec_method
    push rdx
    mov rdx, JS_NULL
    cmp rax, rdx
    pop rdx
    setne al
    shr al, 1
    jmp js_bool

; jsre_arg_regexp: EAX = argument index, R11D = flags if it has to be made
; from a string -> RBX = a RegExp (raw): the argument, or new RegExp(it)
jsre_arg_regexp:
    push rdx
    call jsb_arg
    call jsre_is
    jc .have
    push rax
    mov rdx, JS_UNDEF
    cmp rax, rdx
    pop rax
    jne .text
    mov rax, [atom_empty]
    jmp .make
.text:
    call js_to_string
.make:
    push rax
    mov eax, r11d
    call jsre_flags_string
    mov rdx, rax
    pop rax
    call jsre_new
.have:
    mov ebx, eax
    pop rdx
    ret

; ------------------------------------------------------------------------------
; string.match(regexp): exec, or all the matched texts for a global one
; ------------------------------------------------------------------------------
jsre_string_match:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r11
    lea rsi, [jsre_str_exec]
    call jsb_this_string
    mov r8, rax
    xor r11d, r11d
    xor eax, eax
    call jsre_arg_regexp
    test dword [rbx + JRE_FLAGS], RXF_GLOBAL
    jnz .all
    call jsre_exec
    jmp .out
.all:
    xor ecx, ecx
    call jsarr_new
    mov r9, rax
    xor edx, edx
.next:
    xor eax, eax
    call jsre_find
    jc .done
    push rcx
    push rdx
    push rsi
    lea rsi, [r8 + JSTR_DATA + rcx]
    sub edx, ecx
    mov ecx, edx
    call jsstr_new
    call jsb_box_string
    mov rcx, rax
    mov rax, r9
    call jsarr_push
    pop rsi
    pop rdx
    pop rcx
    call jsre_advance               ; an empty match: on by one character
    jmp .next
.done:
    xor eax, eax
    call jsre_set_last_index
    mov rax, JS_NULL
    cmp dword [r9 + JARR_LEN], 0
    je .out
    mov rax, r9
    BOX rax, rcx, JS_OBJ_BITS
.out:
    pop r11
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsre_advance: ECX = a match's start, EDX = its end, R8 = input -> EDX =
; where the next search starts (one character on for an empty match)
jsre_advance:
    cmp ecx, edx
    jne .ret
    cmp edx, [r8 + JSTR_LEN]
    jae .past
    push rax
    movzx eax, byte [r8 + JSTR_DATA + rdx]
    inc edx
    cmp al, 0xC0
    jb .done
.more:
    cmp edx, [r8 + JSTR_LEN]
    jae .done
    mov al, [r8 + JSTR_DATA + rdx]
    and al, 0xC0
    cmp al, 0x80
    jne .done
    inc edx
    jmp .more
.done:
    pop rax
.ret:
    ret
.past:
    inc edx                         ; (past the end: the search stops)
    ret

; string.matchAll(regexp) -> an iterator of exec results (a global one)
jsre_string_match_all:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r11
    lea rsi, [jsre_str_match_all]
    call jsb_this_string
    mov r8, rax
    mov r11d, RXF_GLOBAL
    xor eax, eax
    call jsre_arg_regexp
    test dword [rbx + JRE_FLAGS], RXF_GLOBAL
    jz .not_global
    xor ecx, ecx
    call jsarr_new
    mov r9, rax
    xor edx, edx
.next:
    xor eax, eax
    call jsre_find
    jc .done
    push rdx
    push rcx
    call jsre_result
    mov rcx, rax
    mov rax, r9
    call jsarr_push
    pop rcx
    pop rdx
    call jsre_advance
    jmp .next
.done:
    mov rax, r9
    BOX rax, rcx, JS_OBJ_BITS
    xor ecx, ecx                    ; ITK_VALUES
    call jsit_new
    pop r11
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.not_global:
    lea rsi, [jsre_str_match_all]
    call jsstr_from_cstr
    mov rdi, rax
    lea rsi, [jsmsg_match_all]
    jmp js_throw_type

; string.search(regexp) -> the first match's index, or -1
jsre_string_search:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r11
    lea rsi, [jsre_str_exec]
    call jsb_this_string
    mov r8, rax
    xor r11d, r11d
    xor eax, eax
    call jsre_arg_regexp
    xor edx, edx
    xor eax, eax
    call jsre_find
    mov rax, -1
    jc .number
    mov eax, ecx
.number:
    call jsb_from_int
    pop r11
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; jsre_replace: (stdlib's replace / replaceAll with a RegExp first) RDX =
; this, RDI / ECX = arguments, R11D = 1 for replaceAll -> RAX = the new string
; ------------------------------------------------------------------------------
jsre_replace:
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
    push r15
    lea rsi, [jsre_str_exec]
    call jsb_this_string
    mov r8, rax                     ; the input
    xor eax, eax
    call jsb_arg
    mov ebx, eax                    ; the RegExp
    test r11d, r11d
    jz .args
    test dword [rbx + JRE_FLAGS], RXF_GLOBAL
    jz .not_global
.args:
    mov eax, 1
    call jsb_arg
    mov r9, rax                     ; a function, or the replacement text
    call js_is_callable
    jc .function
    call js_to_string
    mov r9, rax
    xor r10d, r10d                  ; 0 = text
    jmp .start
.function:
    mov r10d, 1
.start:
    call jslb_new
    xor r12d, r12d                  ; copied up to here
    xor edx, edx                    ; the search starts here
    test dword [rbx + JRE_FLAGS], RXF_GLOBAL
    jnz .search
    test dword [rbx + JRE_FLAGS], RXF_STICKY
    jz .search
    call jsre_last_index
    mov edx, eax
.search:
    xor eax, eax
    call jsre_find
    jc .rest
    mov r13d, edx                   ; the match's end
    ; the text before it
    push rcx
    lea rsi, [r8 + JSTR_DATA + r12]
    sub ecx, r12d
    call jslb_bytes
    pop rcx
    call jsre_captures
    call jsre_substitute            ; RAX = captures, ECX = index -> appended
    mov r12d, r13d
    test dword [rbx + JRE_FLAGS], RXF_GLOBAL
    jz .rest
    mov edx, r13d
    call jsre_advance
    jmp .search
.rest:
    lea rsi, [r8 + JSTR_DATA + r12]
    mov ecx, [r8 + JSTR_LEN]
    sub ecx, r12d
    call jslb_bytes
    test dword [rbx + JRE_FLAGS], RXF_GLOBAL
    jz .value
    xor eax, eax
    call jsre_set_last_index
.value:
    call jslb_value
    pop r15
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
.not_global:
    lea rsi, [jsre_str_replace_all]
    call jsstr_from_cstr
    mov rdi, rax
    lea rsi, [jsmsg_match_all]
    jmp js_throw_type

; ------------------------------------------------------------------------------
; jsre_substitute: (jsre_replace) RAX = captures (raw array), ECX = the
; match's index, R8 = input, R9 = replacement (function if R10D = 1, else a
; heap string with $1 $<name> $& $` $' $$), R15 = the text -> appended
; ------------------------------------------------------------------------------
jsre_substitute:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r11
    mov rdi, rax
    mov r11d, ecx
    test r10d, r10d
    jnz .call
    mov rsi, r9
    mov ecx, [rsi + JSTR_LEN]
    add rsi, JSTR_DATA
.char:
    test ecx, ecx
    jz .done
    lodsb
    dec ecx
    cmp al, '$'
    jne .put
    test ecx, ecx
    jz .put
    mov dl, [rsi]
    cmp dl, '$'
    je .dollar
    cmp dl, '&'
    je .whole
    cmp dl, '`'
    je .before
    cmp dl, "'"
    je .after
    cmp dl, '<'
    je .named
    sub dl, '0'
    cmp dl, 9
    jbe .number
.put:
    call jslb_byte
    jmp .char
.dollar:
    inc rsi
    dec ecx
    jmp .put
.whole:
    inc rsi
    dec ecx
    xor eax, eax
    call .group_text
    jmp .char
.before:
    inc rsi
    dec ecx
    push rcx
    push rsi
    lea rsi, [r8 + JSTR_DATA]
    mov ecx, r11d
    call jslb_bytes
    pop rsi
    pop rcx
    jmp .char
.after:
    inc rsi
    dec ecx
    push rcx
    push rsi
    mov rax, [rdi + JARR_ELEMS]
    mov eax, [rax]                  ; the match
    mov eax, [rax + JSTR_LEN]
    add eax, r11d
    lea rsi, [r8 + JSTR_DATA + rax]
    mov ecx, [r8 + JSTR_LEN]
    sub ecx, eax
    call jslb_bytes
    pop rsi
    pop rcx
    jmp .char
.number:
    ; $1 .. $99 (two digits if that group exists)
    movzx eax, dl
    test eax, eax
    jz .put_dollar                  ; $0 is not a group
    cmp ecx, 2
    jb .one_digit
    movzx edx, byte [rsi + 1]
    sub edx, '0'
    cmp edx, 9
    ja .one_digit
    imul edx, eax, 10
    movzx ebx, byte [rsi + 1]
    lea edx, [edx + ebx - '0']
    cmp edx, [rdi + JARR_LEN]
    jae .one_digit
    mov eax, edx
    add rsi, 2
    sub ecx, 2
    call .group_text
    jmp .char
.one_digit:
    cmp eax, [rdi + JARR_LEN]
    jae .put_dollar
    inc rsi
    dec ecx
    call .group_text
    jmp .char
.put_dollar:
    mov al, '$'
    jmp .put
.named:
    ; $<name>: the named group's text (only if there are named groups)
    mov rbx, [rsp + 40]             ; (the RegExp: the caller's RBX)
    cmp qword [rbx + JRE_NAMES], 0
    je .put_dollar
    push rcx
    push rsi
    inc rsi
    mov rdx, rsi
.name_end:
    test ecx, ecx
    jz .no_name
    cmp byte [rsi], '>'
    je .name_found
    inc rsi
    dec ecx
    jmp .name_end
.no_name:
    pop rsi
    pop rcx
    jmp .put_dollar
.name_found:
    mov rcx, rsi
    sub rcx, rdx
    push rsi
    mov rsi, rdx
    call jsstr_atom
    pop rsi
    mov rbx, [rbx + JRE_NAMES]
    xor edx, edx
.find:
    cmp edx, [rbx + JARR_LEN]
    jae .found_none
    mov rcx, [rbx + JARR_ELEMS]
    cmp [rcx + rdx*8], eax
    je .found
    inc edx
    jmp .find
.found:
    mov eax, edx
    call .group_text
.found_none:
    ; past the '>'
    inc rsi
    mov rax, rsi
    pop rsi
    pop rcx
    sub rax, rsi
    add rsi, rax
    sub ecx, eax
    jmp .char
.call:
    ; replacer(match, p1, ..., index, input[, groups])
    mov ecx, [rdi + JARR_LEN]
    mov eax, r11d
    call jsb_from_int
    mov rcx, rax
    mov rax, rdi
    call jsarr_push
    mov rcx, r8
    BOX rcx, rax, JS_STR_BITS
    mov rax, rdi
    call jsarr_push
    mov rbx, [rsp + 40]             ; (the RegExp)
    cmp qword [rbx + JRE_NAMES], 0
    je .args
    ; (the groups)
    push rdi
    mov rax, rdi
    call jsre_groups
    pop rdi
    mov rcx, rax
    mov rax, rdi
    call jsarr_push
.args:
    mov rax, r9
    mov rsi, rdi
    call jsev_call_list             ; RAX = function, RSI = argument array -> RAX
    call js_to_string
    call jslb_str
.done:
    pop r11
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
; .group_text: EAX = group -> its text appended (nothing if unset)
.group_text:
    push rax
    push rdx
    mov rdx, [rdi + JARR_ELEMS]
    mov rax, [rdx + rax*8]
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_STRING
    jne .no_text
    mov eax, eax
    call jslb_str
.no_text:
    pop rdx
    pop rax
    ret

; jsev_call_list: RAX = function, RSI = arguments (raw array) -> RAX = its
; result (this = undefined; an error goes on up)
jsev_call_list:
    push rcx
    push rdx
    push rdi
    push rbp
    mov rbp, rsp
    mov ecx, [rsi + JARR_LEN]
    lea rdx, [rcx*8 + 8]
    sub rsp, rdx
    and rsp, -16
    mov rdi, rsp
    xor edx, edx
.arg:
    cmp edx, ecx
    jae .call
    push rax
    mov rax, [rsi + JARR_ELEMS]
    mov rax, [rax + rdx*8]
    mov [rdi + rdx*8], rax
    pop rax
    inc edx
    jmp .arg
.call:
    mov rdx, JS_UNDEF
    call js_call
    mov rsp, rbp
    pop rbp
    pop rdi
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------------------------
; jsre_split: (stdlib's split with a RegExp first) RDX = this, RDI / ECX =
; arguments -> RAX = the pieces, with the groups of each separator
; ------------------------------------------------------------------------------
jsre_split:
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
    lea rsi, [jsre_str_exec]
    call jsb_this_string
    mov r8, rax
    mov r11d, -1                    ; the limit
    mov eax, 1
    call jsb_arg
    mov rdx, JS_UNDEF
    cmp rax, rdx
    je .limit_done
    call js_to_int32
    mov r11d, eax
.limit_done:
    xor eax, eax
    call jsb_arg
    mov ebx, eax
    push rcx
    xor ecx, ecx
    call jsarr_new
    mov r10, rax                    ; the pieces
    pop rcx
    test r11d, r11d
    jz .out
    mov r9d, [r8 + JSTR_LEN]
    test r9d, r9d
    jnz .split
    ; an empty string: [] if the expression matches it, else [""]
    xor edx, edx
    mov eax, RXF_STICKY
    call jsre_find
    jnc .out
    xor edx, edx
    xor ecx, ecx
    call .piece
    jmp .out
.split:
    xor r12d, r12d                  ; p: where the next piece starts
    xor edx, edx                    ; q: where to look
.next:
    cmp edx, r9d
    jae .last
    xor eax, eax
    call jsre_find                  ; ECX = start, EDX = end
    jc .last
    cmp ecx, r9d
    jae .last
    cmp edx, r12d
    je .empty_at_p                  ; an empty match where the piece starts
    ; the piece [p, start)
    push rdx
    mov edx, ecx
    mov ecx, r12d
    call .piece
    pop rdx
    cmp [r10 + JARR_LEN], r11d
    jae .out
    ; the separator's groups
    push rdx
    call jsre_captures
    mov rsi, rax
    mov ecx, 1
.group:
    cmp ecx, [rsi + JARR_LEN]
    jae .groups_done
    push rcx
    mov rax, [rsi + JARR_ELEMS]
    mov rcx, [rax + rcx*8]
    mov rax, r10
    call jsarr_push
    pop rcx
    cmp [r10 + JARR_LEN], r11d
    jae .out_pop
    inc ecx
    jmp .group
.groups_done:
    pop rdx
    mov r12d, edx
    jmp .next
.empty_at_p:
    mov edx, ecx
    call jsre_advance
    jmp .next
.last:
    mov ecx, r12d
    mov edx, r9d
    call .piece
    jmp .out
.out_pop:
    pop rdx
.out:
    mov rax, r10
    BOX rax, rcx, JS_OBJ_BITS
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
; .piece: bytes ECX .. EDX of the input -> pushed onto the pieces
.piece:
    push rax
    push rcx
    push rsi
    lea rsi, [r8 + JSTR_DATA + rcx]
    sub edx, ecx
    mov ecx, edx
    call jsstr_new
    mov rcx, rax
    BOX rcx, rax, JS_STR_BITS
    mov rax, r10
    call jsarr_push
    pop rsi
    pop rcx
    pop rax
    ret
