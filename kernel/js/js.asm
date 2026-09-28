; ==============================================================================
; Antigravity OS - JavaScript engine: public interface
; ------------------------------------------------------------------------------
;   js_reset      empty heap, fresh global object and built-ins
;   js_eval       RSI = source, RCX = length -> RAX = completion value, CF=1 on
;                 an uncaught error (js_print_error shows it)
;   js_print_result / js_print_error    REPL-style output (the `js` command)
;   js_print_hook routine that prints one line of console.log output:
;                 RSI = text, RCX = length (no newline). Default: the console.
; Output is built in jsout_buf; values are shown the way Node.js shows them
; (jsi_value: [ 1, 2 ], { a: 'x' }, [Function: f]).
; ==============================================================================

[bits 64]

JSOUT_MAX               equ 8192
JSI_MAX_DEPTH           equ 2           ; deeper objects print as [Object]
JSI_MAX_ITEMS           equ 100         ; array elements shown

section .data
js_print_hook:          dq js_print_console

section .bss
alignb 8
js_depth:               resd 1          ; js_eval / js_call_safe nesting
js_realm:               resd 1          ; counts js_reset calls
jsout_len:              resd 1
jsi_top:                resd 1
jsi_stack:              resq 8          ; objects being printed (cycles)
jsout_buf:              resb JSOUT_MAX + 16

section .rodata
jsmsg_uncaught:         db "Uncaught ", 0
jsmsg_line:             db " (line ", 0
jsi_function:           db "[Function: ", 0
jsi_anonymous:          db "[Function (anonymous)]", 0
jsi_circular:           db "[Circular]", 0
jsi_str_object:         db "[Object]", 0
jsi_str_array:          db "[Array]", 0
jsi_arguments:          db "[Arguments] ", 0
jsi_empty_item:         db " empty item", 0
jsi_more_items:         db " more items", 0
jsi_minus_zero:         db "-0", 0
jsi_iterator:           db "[iterator]", 0
jsi_getter:             db "[Getter]", 0
jsi_setter:             db "[Setter]", 0
jsi_getter_setter:      db "[Getter/Setter]", 0
jsi_async_function:     db "[AsyncFunction: ", 0
jsi_async_anonymous:    db "[AsyncFunction (anonymous)]", 0
jsi_gen_function:       db "[GeneratorFunction: ", 0
jsi_gen_anonymous:      db "[GeneratorFunction (anonymous)]", 0
jsi_generator:          db "Object [Generator] {}", 0
jsi_pending:            db "<pending>", 0
jsi_rejected:           db "<rejected> ", 0

section .text

; ------------------------------------------------------------------------------
; js_reset: a fresh engine (heap, atoms, global object, built-ins)
; ------------------------------------------------------------------------------
js_reset:
    inc dword [js_realm]            ; whoever used the old heap must not any more
    call js_heap_reset
    call js_init_builtins
    ret

; ------------------------------------------------------------------------------
; js_eval: RSI = source, RCX = length -> RAX = completion value (the value of
; the last expression statement), CF=1 if the script threw (js_exception)
; js_call_safe: RAX = function, RDX = this, RDI = arguments, ECX = count
; -> RAX = its result, CF=1 if it threw
; Both may be used while JavaScript is running (a native running more code):
; an error then ends only the inner run.
; ------------------------------------------------------------------------------
js_eval:
    push rbx
    lea rbx, [js_eval_body]
    jmp js_protected

js_call_safe:
    push rbx
    lea rbx, [js_call]
    jmp js_protected

; js_eval_body: RSI/RCX = source -> RAX = completion value
js_eval_body:
    mov rax, JS_UNDEF
    mov [vm_completion], rax
    mov dword [vm_line], 0
    inc dword [jsgc_off]            ; no collections while compiling
    call jsp_parse_script
    call jsc_compile_script
    dec dword [jsgc_off]
    xor edx, edx
    call jsfn_new
    BOX rax, rdx, JS_OBJ_BITS
    mov rdx, [js_global]
    BOX rdx, rcx, JS_OBJ_BITS
    xor ecx, ecx
    jmp js_call

; js_protected: [RSP] = the caller's RBX, RBX = routine to run with the other
; registers as its inputs. Errors land in js_eval_fail with RSP = js_catch_rsp.
js_protected:
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
    ; the interpreter state of an outer run, restored afterwards
    push qword [vm_sp]
    push qword [vm_fp]
    push qword [vm_completion]
    mov r8d, [vm_line]
    push r8
    mov r8d, [vm_nesting]
    push r8
    mov r8d, [vm_handler_count]
    push r8
    mov r8d, [jsgc_off]             ; (an error while compiling leaves it raised)
    push r8
    push qword [js_catch_rsp]
    mov [js_catch_rsp], rsp
    cmp dword [js_depth], 0
    jne .nested
    mov dword [vm_handler_count], 0
    mov byte [js_throwing], 0
    mov qword [vm_sp], JS_STACK_ADDR
    mov qword [vm_fp], JS_FRAMES_ADDR
    mov dword [vm_nesting], 0
    mov dword [vm_budget], JSVM_BUDGET
    push rax
    mov rax, [timer_ticks]
    mov [vm_idle_tick], rax
    pop rax
    finit                           ; x87 for % and Math (64-bit precision)
.nested:
    inc dword [js_depth]
    call rbx
    clc
    jmp js_protected_out
js_eval_fail:                       ; js_throw_value lands here, RSP = js_catch_rsp
    mov rax, [js_exception]
    stc
js_protected_out:
    dec dword [js_depth]            ; (keeps CF)
    pop qword [js_catch_rsp]
    pop r8
    mov [jsgc_off], r8d
    pop r8
    mov [vm_handler_count], r8d
    pop r8
    mov [vm_nesting], r8d
    pop r8
    mov [vm_line], r8d
    pop qword [vm_completion]
    pop qword [vm_fp]
    pop qword [vm_sp]
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

; js_compile_dump: RSI = source, RCX = length -> the script's bytecode printed
; as hex, and each function's with its line (debugging: `js -d code`)
js_compile_dump:
    lea rbx, [.body]
    push rbx
    jmp js_protected
.body:
    inc dword [jsgc_off]
    call jsp_parse_script
    call jsc_compile_script
    dec dword [jsgc_off]
    mov rax, [jsc_script]
    call .function
    ret
; .function: RAX = function info (compiled) -> its code, then its inner ones
.function:
    push rax
    push rbx
    push rcx
    push rsi
    mov rbx, [rax + JFI_TEMPLATE]
    call jsout_reset
    mov eax, [rbx + JCODE_LINE]
    call jsout_u64
    mov al, ':'
    call jsout_byte
    mov ecx, [rbx + JCODE_LEN]
    mov rsi, [rbx + JCODE_CODE]
.byte:
    test ecx, ecx
    jz .flush
    mov al, ' '
    call jsout_byte
    movzx eax, byte [rsi]
    push rax
    shr eax, 4
    call jsnum_digit_char
    call jsout_byte
    pop rax
    and eax, 15
    call jsnum_digit_char
    call jsout_byte
    inc rsi
    dec ecx
    jmp .byte
.flush:
    call jsout_flush
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; js_print_result: RAX = value -> one line through js_print_hook (strings
; quoted, like the Node.js REPL); nothing for undefined
; ------------------------------------------------------------------------------
js_print_result:
    push rax
    push rcx
    push rdx
    mov rcx, JS_UNDEF
    cmp rax, rcx
    je .out
    call jsout_reset
    xor ecx, ecx
    mov edx, 1
    call jsi_value
    call jsout_flush
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; js_print_uncaught: RAX = a value, RSI = what to say first -> printed like an
; uncaught error, without a line ("Uncaught (in promise) ...")
js_print_uncaught:
    push rax
    push rcx
    push rdx
    push rsi
    call jsout_reset
    call jsout_cstr
    xor edx, edx
    call jsi_error
    jnc .flush
    xor ecx, ecx
    mov edx, 1
    call jsi_value
.flush:
    call jsout_flush
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; js_print_error: the uncaught exception -> "Uncaught <error> (line N)"
js_print_error:
    push rax
    push rcx
    push rdx
    push rsi
    call jsout_reset
    lea rsi, [jsmsg_uncaught]
    call jsout_cstr
    mov rax, [js_exception]
    mov rcx, JS_HOLE
    cmp rax, rcx
    jne .value
    lea rsi, [js_err_buf]
    call jsout_cstr
    jmp .line
.value:
    call jsi_error                  ; Error objects: "Name: message"
    jnc .line
    xor ecx, ecx
    mov edx, 1
    call jsi_value
.line:
    mov eax, [js_exception_line]
    test eax, eax
    jz .flush
    lea rsi, [jsmsg_line]
    call jsout_cstr
    call jsout_u64
    mov al, ')'
    call jsout_byte
.flush:
    call jsout_flush
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsi_error: RAX = value -> CF=0 if it is an error object, printed as
; "Name: message" (read without running any JavaScript)
jsi_error:
    push rax
    push rbx
    push rcx
    push rdx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .no
    mov eax, eax
    cmp dword [rax + JOBJ_CLASS], JC_ERROR
    jne .no
    mov rcx, rax
    mov rdx, [atom_name]
    call jsobj_lookup
    jc .no_name
    bt qword [rbx + JPE_KEY], 34
    jc .no_name
    mov rax, [rbx + JPE_VAL]
    call .string
.no_name:
    mov rax, rcx
    mov rdx, [atom_message]
    call jsobj_lookup
    jc .done
    bt qword [rbx + JPE_KEY], 34
    jc .done
    mov rax, [rbx + JPE_VAL]
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_STRING
    jne .done
    mov edx, eax
    cmp dword [rdx + JSTR_LEN], 0
    je .done
    push rax
    mov al, ':'
    call jsout_byte
    mov al, ' '
    call jsout_byte
    pop rax
    call .string
.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret
.no:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    stc
    ret
; .string: RAX = value; appended if it is a string
.string:
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_STRING
    jne .string_done
    mov eax, eax
    call jsout_str
.string_done:
    pop rdx
    ret

; js_print_console: the default js_print_hook. RSI = text, RCX = length
js_print_console:
    push rax
    push rcx
    push rsi
.loop:
    test rcx, rcx
    jz .done
    lodsb
    cmp al, 9
    jne .put
    mov al, ' '
.put:
    call con_putc
    dec rcx
    jmp .loop
.done:
    call con_newline
    pop rsi
    pop rcx
    pop rax
    ret

; ==============================================================================
; Output buffer
; ==============================================================================

jsout_reset:
    mov dword [jsout_len], 0
    ret

; jsout_flush: print the buffer as one line and empty it
jsout_flush:
    push rcx
    push rsi
    lea rsi, [jsout_buf]
    mov ecx, [jsout_len]
    call [js_print_hook]
    mov dword [jsout_len], 0
    pop rsi
    pop rcx
    ret

; jsout_byte: AL
jsout_byte:
    push rdx
    mov edx, [jsout_len]
    cmp edx, JSOUT_MAX
    jae .full
    push rdi
    lea rdi, [jsout_buf]
    mov [rdi + rdx], al
    pop rdi
    inc dword [jsout_len]
.full:
    pop rdx
    ret

; jsout_bytes: RSI = bytes, RCX = count
jsout_bytes:
    push rax
    push rcx
    push rsi
.loop:
    test rcx, rcx
    jz .done
    lodsb
    call jsout_byte
    dec rcx
    jmp .loop
.done:
    pop rsi
    pop rcx
    pop rax
    ret

; jsout_cstr: RSI = NUL-terminated text
jsout_cstr:
    push rax
    push rsi
.loop:
    lodsb
    test al, al
    jz .done
    call jsout_byte
    jmp .loop
.done:
    pop rsi
    pop rax
    ret

; jsout_str: RAX = heap string
jsout_str:
    push rcx
    push rsi
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    call jsout_bytes
    pop rsi
    pop rcx
    ret

; jsout_u64: RAX = value in decimal
jsout_u64:
    push rcx
    push rsi
    push rdi
    sub rsp, 32
    mov rdi, rsp
    call jsnum_write_u64
    mov rcx, rdi
    mov rsi, rsp
    sub rcx, rsi
    call jsout_bytes
    add rsp, 32
    pop rdi
    pop rsi
    pop rcx
    ret

; jsout_number: RAX = number bits
jsout_number:
    push rcx
    push rsi
    push rdi
    sub rsp, 32
    mov rdi, rsp
    call jsnum_to_string
    mov rsi, rsp
    call jsout_bytes
    add rsp, 32
    pop rdi
    pop rsi
    pop rcx
    ret

; ==============================================================================
; Inspecting values (console.log, REPL)
; ==============================================================================

; ------------------------------------------------------------------------------
; jsi_value: RAX = value, ECX = depth, EDX = 1 to quote strings -> appended to
; jsout_buf the way Node.js prints it
; ------------------------------------------------------------------------------
jsi_value:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rbx, rax
    shr rbx, 48
    cmp ebx, JS_TAG_SPECIAL
    jb .number
    je .special
    cmp ebx, JS_TAG_STRING
    je .string
    cmp ebx, JS_TAG_SYMBOL
    je .symbol
    mov ebx, eax                    ; object
    movzx esi, byte [rbx + JH_KIND]
    cmp esi, JK_FUNC
    je .function
    cmp esi, JK_NATIVE
    je .function
    cmp esi, JK_ITER
    je .iterator
    cmp esi, JK_OBJECT
    jne .not_host
    cmp dword [rbx + JOBJ_CLASS], JC_ERROR
    jne .not_error
    call jsi_error
    jmp .out
.not_error:
    cmp dword [rbx + JOBJ_CLASS], JC_HOST
    jb .not_host
    call jsd_inspect
    jmp .out
.not_host:
    ; cycles
    mov esi, [jsi_top]
    lea rdi, [jsi_stack]
.cycle:
    test esi, esi
    jz .not_cycle
    dec esi
    cmp [rdi + rsi*8], rbx
    jne .cycle
    lea rsi, [jsi_circular]
    jmp .cstr
.not_cycle:
    cmp ecx, JSI_MAX_DEPTH
    ja .too_deep
    cmp dword [jsi_top], 8
    jae .too_deep
    mov esi, [jsi_top]
    mov [rdi + rsi*8], rbx
    inc dword [jsi_top]
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .object
    call jsi_array
    jmp .pop
.object:
    call jsi_object
.pop:
    dec dword [jsi_top]
    jmp .out
.too_deep:
    lea rsi, [jsi_str_object]
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .cstr
    lea rsi, [jsi_str_array]
.cstr:
    call jsout_cstr
    jmp .out
.number:
    mov rsi, 0x8000000000000000
    cmp rax, rsi
    jne .plain_number
    lea rsi, [jsi_minus_zero]
    jmp .cstr
.plain_number:
    call jsout_number
    jmp .out
.special:
    call js_to_string
    call jsout_str
    jmp .out
.string:
    mov eax, eax
    test edx, edx
    jnz .quoted
    call jsout_str
    jmp .out
.quoted:
    call jsi_quoted
    jmp .out
.function:
    xor edi, edi                    ; async?
    cmp byte [rbx + JH_KIND], JK_FUNC
    jne .fn_name
    mov rax, [rbx + JFN_CODE]
    mov edi, [rax + JCODE_FLAGS2]
    and edi, JCF2_ASYNC | JCF2_GENERATOR
.fn_name:
    mov rax, JS_OBJ_BITS
    or rax, rbx
    mov rdx, [atom_name]
    call js_get
    mov eax, eax
    cmp dword [rax + JSTR_LEN], 0
    je .anonymous
    lea rsi, [jsi_function]
    test edi, edi
    jz .fn_prefix
    lea rsi, [jsi_async_function]
    test edi, JCF2_ASYNC
    jnz .fn_prefix
    lea rsi, [jsi_gen_function]
.fn_prefix:
    call jsout_cstr
    call jsout_str
    mov al, ']'
    call jsout_byte
    jmp .out
.anonymous:
    lea rsi, [jsi_anonymous]
    test edi, edi
    jz .cstr
    lea rsi, [jsi_async_anonymous]
    test edi, JCF2_ASYNC
    jnz .cstr
    lea rsi, [jsi_gen_anonymous]
    jmp .cstr
.iterator:
    lea rsi, [jsi_iterator]
    jmp .cstr
.symbol:
    mov eax, eax
    call jsy_describe
    mov eax, eax
    call jsout_str
    jmp .out
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsi_quoted: RAX = heap string -> quoted, with \n, \t, \ and the quote
; escaped. Like Node.js it uses "..." when the text has ' but no ".
jsi_quoted:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    mov bl, 0x27                    ; the quote
    mov rdi, rsi
    push rcx
    mov al, 0x27
    repne scasb
    pop rcx
    jne .quote_chosen
    mov rdi, rsi
    push rcx
    mov al, '"'
    repne scasb
    pop rcx
    je .quote_chosen
    mov bl, '"'
.quote_chosen:
    mov al, bl
    call jsout_byte
.loop:
    test ecx, ecx
    jz .done
    lodsb
    cmp al, bl
    je .escape
    cmp al, '\'
    je .escape
    cmp al, 10
    je .newline
    cmp al, 9
    je .tab
    call jsout_byte
    jmp .next
.escape:
    push rax
    mov al, '\'
    call jsout_byte
    pop rax
    call jsout_byte
    jmp .next
.newline:
    mov al, '\'
    call jsout_byte
    mov al, 'n'
    call jsout_byte
    jmp .next
.tab:
    mov al, '\'
    call jsout_byte
    mov al, 't'
    call jsout_byte
.next:
    dec ecx
    jmp .loop
.done:
    mov al, bl
    call jsout_byte
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; jsi_key: RAX = key atom -> printed bare if it is an identifier, else quoted
jsi_key:
    push rbx
    push rcx
    push rsi
    cmp byte [rax + JH_KIND], JK_SYMBOL
    je .symbol
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    test ecx, ecx
    jz .quote
    push rax
    mov al, [rsi]
    call jslex_is_ident_start
    pop rax
    jnc .quote
.check:
    push rax
    mov al, [rsi]
    call jslex_is_ident_start
    jc .ok
    sub al, '0'
    cmp al, 9
    ja .bad
.ok:
    pop rax
    inc rsi
    dec ecx
    jnz .check
    call jsout_str
    jmp .out
.bad:
    pop rax
.quote:
    call jsi_quoted
.out:
    pop rsi
    pop rcx
    pop rbx
    ret
.symbol:
    ; [Symbol(description)]
    push rax
    mov al, '['
    call jsout_byte
    pop rax
    call jsy_describe
    mov eax, eax
    call jsout_str
    mov al, ']'
    call jsout_byte
    jmp .out

; jsi_separator: EBX = items so far -> ", " before all but the first
jsi_separator:
    test ebx, ebx
    jz .first
    push rax
    mov al, ','
    call jsout_byte
    mov al, ' '
    call jsout_byte
    pop rax
.first:
    ret

; jsi_array: RBX = array object, ECX = depth
jsi_array:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, rbx
    cmp dword [r8 + JOBJ_CLASS], JC_ARGUMENTS
    jne .open
    lea rsi, [jsi_arguments]
    call jsout_cstr
.open:
    mov edx, [r8 + JARR_LEN]
    test edx, edx
    jnz .items
    call jsi_has_props
    jc .items
    mov al, '['
    call jsout_byte
    mov al, ']'
    call jsout_byte
    jmp .out
.items:
    mov al, '['
    call jsout_byte
    mov al, ' '
    call jsout_byte
    inc ecx                         ; children are one level deeper
    xor ebx, ebx                    ; items printed
    xor r9d, r9d                    ; index
.element:
    cmp r9d, [r8 + JARR_LEN]
    jae .props
    cmp ebx, JSI_MAX_ITEMS
    jae .more
    mov rsi, [r8 + JARR_ELEMS]
    mov rax, [rsi + r9*8]
    mov rdi, JS_HOLE
    cmp rax, rdi
    je .holes
    call jsi_separator
    mov edx, 1
    call jsi_value
    inc ebx
    inc r9d
    jmp .element
.holes:
    ; <N empty items>
    xor edi, edi
.count:
    cmp r9d, [r8 + JARR_LEN]
    jae .holes_done
    mov rax, [rsi + r9*8]
    mov rdx, JS_HOLE
    cmp rax, rdx
    jne .holes_done
    inc edi
    inc r9d
    jmp .count
.holes_done:
    call jsi_separator
    mov al, '<'
    call jsout_byte
    mov eax, edi
    call jsout_u64
    lea rsi, [jsi_empty_item]
    call jsout_cstr
    cmp edi, 1
    je .one_hole
    mov al, 's'
    call jsout_byte
.one_hole:
    mov al, '>'
    call jsout_byte
    inc ebx
    jmp .element
.more:
    call jsi_separator
    mov al, '.'
    call jsout_byte
    call jsout_byte
    call jsout_byte
    mov al, ' '
    call jsout_byte
    mov eax, [r8 + JARR_LEN]
    sub eax, r9d
    call jsout_u64
    lea rsi, [jsi_more_items]
    call jsout_cstr
.props:
    mov rax, r8
    call jsi_props
    mov al, ' '
    call jsout_byte
    mov al, ']'
    call jsout_byte
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsi_object: RBX = plain object, ECX = depth -> { key: value, ... }
jsi_object:
    push rax
    push rbx
    push rcx
    push rdi
    mov rdi, rbx
    cmp dword [rdi + JOBJ_CLASS], JC_REGEXP
    je .regexp
    cmp dword [rdi + JOBJ_CLASS], JC_DATE
    je .date
    cmp dword [rdi + JOBJ_CLASS], JC_MAP
    je .collection
    cmp dword [rdi + JOBJ_CLASS], JC_SET
    je .collection
    call jsi_class_name
    cmp dword [rdi + JOBJ_CLASS], JC_PROMISE
    je .promise
    mov rax, rdi
    call jsi_has_props_rax
    jc .items
    mov al, '{'
    call jsout_byte
    mov al, '}'
    call jsout_byte
    jmp .out
.items:
    mov al, '{'
    call jsout_byte
    mov al, ' '
    call jsout_byte
    xor ebx, ebx
    inc ecx
    mov rax, rdi
    call jsi_props
    mov al, ' '
    call jsout_byte
    mov al, '}'
    call jsout_byte
.out:
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret
.collection:
    call jscol_inspect
    jmp .out
.regexp:
    mov rbx, rdi
    call jsre_text
    call jsout_str
    jmp .out
.date:
    call jsdate_inspect
    jmp .out
.promise:
    ; Promise { 1 }, Promise { <pending> }, Promise { <rejected> Error: x }
    push rsi
    mov al, '{'
    call jsout_byte
    mov al, ' '
    call jsout_byte
    lea rsi, [jsi_pending]
    cmp byte [rdi + JPROM_STATE], 0
    je .state
    cmp byte [rdi + JPROM_STATE], 1
    je .settled
    lea rsi, [jsi_rejected]
    call jsout_cstr
.settled:
    mov rax, [rdi + JPROM_VALUE]
    inc ecx
    mov edx, 1
    call jsi_value
    jmp .promise_end
.state:
    call jsout_cstr
.promise_end:
    mov al, ' '
    call jsout_byte
    mov al, '}'
    call jsout_byte
    pop rsi
    jmp .out

; jsi_class_name: RDI = object; made by a constructor (its prototype is not
; Object.prototype and has a named `constructor`) -> "Name " like Node.js
jsi_class_name:
    push rax
    push rbx
    push rdx
    mov rax, [rdi + JOBJ_PROTO]
    test rax, rax
    jz .out
    cmp rax, [js_object_proto]
    je .out
    mov rdx, [atom_constructor]
    call jsobj_find_own
    jc .out
    mov rax, [rbx + JPE_VAL]
    call js_is_callable
    jnc .out
    mov rdx, [atom_name]
    call js_get
    mov eax, eax
    cmp dword [rax + JSTR_LEN], 0
    je .out
    call jsout_str
    mov al, ' '
    call jsout_byte
.out:
    pop rdx
    pop rbx
    pop rax
    ret

; jsi_has_props: R8 = object -> CF=1 if it has enumerable own properties
jsi_has_props:
    push rax
    mov rax, r8
    call jsi_has_props_rax
    pop rax
    ret

; jsi_has_props_rax: RAX = object -> CF=1 if it has enumerable own properties
; (RAX is clobbered)
jsi_has_props_rax:
    push rcx
    push rsi
    mov ecx, [rax + JOBJ_COUNT]
    mov rsi, [rax + JOBJ_PROPS]
.loop:
    test ecx, ecx
    jz .no
    mov rax, [rsi + JPE_KEY]
    test eax, eax
    jz .next
    bt rax, 32
    jnc .yes
.next:
    add rsi, JPE_SIZE
    dec ecx
    jmp .loop
.yes:
    pop rsi
    pop rcx
    stc
    ret
.no:
    pop rsi
    pop rcx
    clc
    ret

; jsi_props: RAX = object, ECX = depth for the values, EBX = items already
; printed (updated) -> key: value, ...
jsi_props:
    push rax
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r9, rax
    xor r8d, r8d                    ; pass 0: string keys, pass 1: symbol keys
.pass:
    mov edi, [r9 + JOBJ_COUNT]
    mov rsi, [r9 + JOBJ_PROPS]
.loop:
    test edi, edi
    jz .pass_done
    mov rax, [rsi + JPE_KEY]
    test eax, eax
    jz .next
    bt rax, 32
    jc .next
    mov edx, eax
    cmp byte [rdx + JH_KIND], JK_SYMBOL
    sete dl
    cmp dl, r8b
    jne .next
    call jsi_separator
    mov eax, eax
    call jsi_key
    mov al, ':'
    call jsout_byte
    mov al, ' '
    call jsout_byte
    mov rax, [rsi + JPE_VAL]
    bt qword [rsi + JPE_KEY], 34
    jc .accessor
    mov edx, 1
    call jsi_value
    jmp .printed
.accessor:
    ; [Getter], [Setter] or [Getter/Setter]
    push rsi
    mov rdx, JS_UNDEF
    lea rsi, [jsi_getter_setter]
    cmp [rax + JACC_SET], rdx
    jne .has_setter
    lea rsi, [jsi_getter]
.has_setter:
    cmp [rax + JACC_GET], rdx
    jne .accessor_text
    lea rsi, [jsi_setter]
.accessor_text:
    call jsout_cstr
    pop rsi
.printed:
    inc ebx
.next:
    add rsi, JPE_SIZE
    dec edi
    jmp .loop
.pass_done:
    inc r8d
    cmp r8d, 2
    jb .pass
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rax
    ret
