; ==============================================================================
; Antigravity OS - Shell command: js (JavaScript)
; ------------------------------------------------------------------------------
;   js <code>        run a line of JavaScript and print its value, e.g. js 1 + 2
;   js <file.js>     run a script from the disk
; Every run starts with a fresh engine (kernel/js/). console.log prints to the
; console; an uncaught error prints "Uncaught <error> (line N)".
; ==============================================================================

[bits 64]

section .rodata
msg_js_usage:           db "Usage: js <code> | js <file.js>   e.g. js 1 + 2", 10, 0
msg_js_ram:             db "js needs at least 112 MB of RAM", 10, 0
msg_js_too_big:         db "Script is too large (1 MB at most)", 10, 0

section .text

; cmd_js: RSI = the code or a file name
cmd_js:
    cmp byte [rsi], 0
    je .usage
    cmp qword [mem_total_bytes], JS_MIN_RAM
    jb .no_ram
    cmp word [rsi], '-d'
    je .dump
    ; a single word ending in .js that names a file: run the file
    call strlen
    mov rcx, rax
    cmp rcx, 4
    jb .inline
    cmp dword [rsi + rcx - 3], 0x736A2E + 0     ; ".js" (+ the NUL)
    jne .inline
    mov rdi, rsi
    mov al, ' '
    push rcx
    repne scasb
    pop rcx
    je .inline                      ; contains a space: code
    mov rbx, rsi
    call fs_find_file
    test rax, rax
    jz .inline_rbx
    mov ecx, [rax + INODE_SIZE]
    cmp ecx, JS_SRC_SIZE
    ja .too_big
    mov rdi, JS_SRC_ADDR
    mov ecx, JS_SRC_SIZE
    call fs_read_file
    mov rcx, rax
    mov rsi, JS_SRC_ADDR
    jmp .run
.inline_rbx:
    mov rsi, rbx
    call strlen
    mov rcx, rax
.inline:
.run:
    call js_reset
    call js_eval
    jc .error
    jmp js_print_result
.error:
    mov al, [con_attr]
    push rax
    mov byte [con_attr], COLOR_LIGHT_RED
    call js_print_error
    pop rax
    mov [con_attr], al
    ret
.dump:
    ; js -d <code>: the compiled script's bytecode in hex (debugging)
    add rsi, 3
    call strlen
    mov rcx, rax
    call js_reset
    call js_compile_dump
    ret
.usage:
    mov bl, COLOR_YELLOW
    lea rsi, [msg_js_usage]
    jmp con_puts_color
.no_ram:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_js_ram]
    jmp con_puts_color
.too_big:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_js_too_big]
    jmp con_puts_color
