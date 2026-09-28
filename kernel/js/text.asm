; ==============================================================================
; Antigravity OS - JavaScript: text coding (URI escapes and base64)
; ------------------------------------------------------------------------------
; encodeURIComponent / encodeURI / decodeURIComponent / decodeURI, escape /
; unescape and atob / btoa. Strings are UTF-8 bytes, so these work on bytes:
; a %XX escape is one byte, and atob gives a string of the decoded bytes
; (charCodeAt reads them back one by one).
; ==============================================================================

[bits 64]

section .rodata
jstx_natives:
JSNATIVE js_global, "encodeURIComponent", jstx_encode_component, 1
JSNATIVE js_global, "encodeURI", jstx_encode_uri, 1
JSNATIVE js_global, "decodeURIComponent", jstx_decode_component, 1
JSNATIVE js_global, "decodeURI", jstx_decode_uri, 1
JSNATIVE js_global, "escape", jstx_escape, 1
JSNATIVE js_global, "unescape", jstx_unescape, 1
JSNATIVE js_global, "btoa", jstx_btoa, 1
JSNATIVE js_global, "atob", jstx_atob, 1
    dq 0

; bytes kept as they are (bit n = byte n)
jstx_keep_component:    db 0x00, 0x00, 0x00, 0x00, 0x82, 0x67, 0xFF, 0x03, 0xFE, 0xFF, 0xFF, 0x87, 0xFE, 0xFF, 0xFF, 0x47
                        times 16 db 0
jstx_keep_uri:          db 0x00, 0x00, 0x00, 0x00, 0xDA, 0xFF, 0xFF, 0xAF, 0xFF, 0xFF, 0xFF, 0x87, 0xFE, 0xFF, 0xFF, 0x47
                        times 16 db 0
jstx_keep_escape:       db 0x00, 0x00, 0x00, 0x00, 0x00, 0xEC, 0xFF, 0x03, 0xFF, 0xFF, 0xFF, 0x87, 0xFE, 0xFF, 0xFF, 0x07
                        times 16 db 0
; decodeURI leaves the escapes of these as they are: ; , / ? : @ & = + $ #
jstx_reserved:          db 0x00, 0x00, 0x00, 0x00, 0x58, 0x98, 0x00, 0xAC, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
                        times 16 db 0
jstx_hex:               db "0123456789ABCDEF"
jstx_base64:            db "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
jsmsg_uri_malformed:    db "URI malformed", 0
jsmsg_base64:           db "The string to be decoded is not correctly encoded.", 0

section .text

; jstx_init: the functions on the global object
jstx_init:
    push r8
    lea r8, [jstx_natives]
    call jsb_define_natives
    pop r8
    ret

; jstx_result: R9 = scratch string, RDI = end of the bytes written -> RAX =
; a string of them (value)
jstx_result:
    lea rsi, [r9 + JSTR_DATA]
    mov rcx, rdi
    sub rcx, rsi
    call jsstr_new
    jmp jsb_box_string

; encodeURIComponent(s) / encodeURI(s) / escape(s): %XX for every byte not kept
jstx_encode_component:
    push r8
    lea r8, [jstx_keep_component]
    jmp jstx_encode
jstx_encode_uri:
    push r8
    lea r8, [jstx_keep_uri]
    jmp jstx_encode
jstx_escape:
    push r8
    lea r8, [jstx_keep_escape]
jstx_encode:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov ecx, [rax + JSTR_LEN]
    push rax
    lea ecx, [rcx + rcx*2]
    call jsstr_alloc
    mov r9, rax
    pop rbx
    lea rsi, [rbx + JSTR_DATA]
    mov ecx, [rbx + JSTR_LEN]
    lea rdi, [r9 + JSTR_DATA]
.byte:
    test ecx, ecx
    jz .done
    movzx eax, byte [rsi]
    inc rsi
    dec ecx
    bt [r8], eax
    jc .keep
    mov byte [rdi], '%'
    mov edx, eax
    shr edx, 4
    mov dl, [jstx_hex + rdx]
    mov [rdi + 1], dl
    and eax, 15
    mov al, [jstx_hex + rax]
    mov [rdi + 2], al
    add rdi, 3
    jmp .byte
.keep:
    stosb
    jmp .byte
.done:
    call jstx_result
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop r8
    ret

; jstx_hex_value: AL = character -> EAX = its value, CF=1 if not a hex digit
jstx_hex_value:
    movzx eax, al
    sub eax, '0'
    cmp eax, 9
    jbe .ok
    or eax, 0x20                    ; ('A' - '0') | 0x20 = 'a' - '0'
    sub eax, 'a' - '0'
    cmp eax, 5
    ja .bad
    add eax, 10
.ok:
    clc
    ret
.bad:
    stc
    ret

; decodeURIComponent(s) / decodeURI(s) / unescape(s): %XX -> the byte (and
; for unescape %uXXXX -> the character)
jstx_decode_component:
    push r8
    xor r8d, r8d
    jmp jstx_decode
jstx_decode_uri:
    push r8
    lea r8, [jstx_reserved]
    jmp jstx_decode
jstx_unescape:
    push r8
    mov r8d, 1                      ; (unescape: lenient, and %u)
jstx_decode:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov ecx, [rax + JSTR_LEN]
    push rax
    call jsstr_alloc                ; (never longer than the text)
    mov r9, rax
    pop rbx
    lea rsi, [rbx + JSTR_DATA]
    mov ecx, [rbx + JSTR_LEN]
    lea rdi, [r9 + JSTR_DATA]
.byte:
    test ecx, ecx
    jz .done
    mov al, [rsi]
    cmp al, '%'
    je .escape
.copy:
    movsb
    dec ecx
    jmp .byte
.escape:
    cmp r8, 1
    jne .xx
    cmp ecx, 6
    jb .xx
    cmp byte [rsi + 1], 'u'
    je .unicode
.xx:
    cmp ecx, 3
    jb .malformed
    mov al, [rsi + 1]
    call jstx_hex_value
    jc .malformed
    mov edx, eax
    mov al, [rsi + 2]
    call jstx_hex_value
    jc .malformed
    shl edx, 4
    or eax, edx
    cmp r8, 1
    jbe .put
    bt [r8], eax
    jc .copy                        ; decodeURI: a reserved character stays escaped
.put:
    stosb
    add rsi, 3
    sub ecx, 3
    jmp .byte
.unicode:
    ; %uXXXX
    push rbx
    xor edx, edx
    mov ebx, 2
.u_digit:
    mov al, [rsi + rbx]
    call jstx_hex_value
    jc .u_bad
    shl edx, 4
    or edx, eax
    inc ebx
    cmp ebx, 6
    jb .u_digit
    pop rbx
    mov eax, edx
    call jslex_put_utf8
    add rsi, 6
    sub ecx, 6
    jmp .byte
.u_bad:
    pop rbx
    jmp .copy
.malformed:
    cmp r8, 1
    je .copy                        ; unescape leaves a bad escape alone
    mov edx, JE_URI
    lea rsi, [jsmsg_uri_malformed]
    xor edi, edi
    jmp js_throw
.done:
    call jstx_result
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop r8
    ret

; btoa(s): the bytes of s in base64
jstx_btoa:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov rbx, rax
    mov eax, [rbx + JSTR_LEN]
    add eax, 2
    xor edx, edx
    mov ecx, 3
    div ecx
    lea ecx, [rax*4]
    call jsstr_alloc
    mov r9, rax
    lea rsi, [rbx + JSTR_DATA]
    mov ecx, [rbx + JSTR_LEN]
    lea rdi, [r9 + JSTR_DATA]
.group:
    cmp ecx, 3
    jb .tail
    movzx eax, byte [rsi]
    shl eax, 8
    mov al, [rsi + 1]
    shl eax, 8
    mov al, [rsi + 2]
    add rsi, 3
    sub ecx, 3
    mov edx, 4
    call .emit
    jmp .group
.tail:
    test ecx, ecx
    jz .done
    movzx eax, byte [rsi]
    shl eax, 16
    cmp ecx, 2
    jb .one
    mov ah, [rsi + 1]
    mov edx, 3
    call .emit
    mov byte [rdi], '='
    inc rdi
    jmp .done
.one:
    mov edx, 2
    call .emit
    mov word [rdi], '=='
    add rdi, 2
.done:
    call jstx_result
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
; .emit: EAX = 24 bits, EDX = how many of its 4 characters to write
.emit:
    push rcx
    mov ecx, 18
.char:
    push rax
    shr eax, cl
    and eax, 63
    mov al, [jstx_base64 + rax]
    stosb
    pop rax
    sub ecx, 6
    dec edx
    jnz .char
    pop rcx
    ret

; atob(s): the bytes that base64 text s stands for (white space is skipped)
jstx_atob:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov ecx, [rax + JSTR_LEN]
    push rax
    call jsstr_alloc
    mov r9, rax
    pop rbx
    lea rsi, [rbx + JSTR_DATA]
    mov ecx, [rbx + JSTR_LEN]
    lea rdi, [r9 + JSTR_DATA]
    xor edx, edx                    ; bits so far
    xor r8d, r8d                    ; how many
.char:
    test ecx, ecx
    jz .end
    movzx eax, byte [rsi]
    inc rsi
    dec ecx
    cmp al, ' '
    je .char
    cmp al, 9
    jb .value
    cmp al, 13
    jbe .char
.value:
    cmp al, '='
    je .end
    call jstx_base64_value
    jc .bad
    shl edx, 6
    or edx, eax
    add r8d, 6
    cmp r8d, 8
    jb .char
    sub r8d, 8
    mov eax, edx
    push rcx
    mov ecx, r8d
    shr eax, cl
    pop rcx
    stosb
    jmp .char
.end:
    call jstx_result
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.bad:
    mov edx, JE_ERROR
    lea rsi, [jsmsg_base64]
    xor edi, edi
    jmp js_throw

; jstx_base64_value: AL = character -> EAX = 0..63, CF=1 if not base64
jstx_base64_value:
    cmp al, 'A'
    jb .other
    cmp al, 'Z'
    jbe .upper
    cmp al, 'a'
    jb .bad
    cmp al, 'z'
    ja .bad
    sub eax, 'a' - 26
    clc
    ret
.upper:
    sub eax, 'A'
    clc
    ret
.other:
    cmp al, '+'
    je .plus
    cmp al, '/'
    je .slash
    cmp al, '0'
    jb .bad
    cmp al, '9'
    ja .bad
    sub eax, '0' - 52
    clc
    ret
.plus:
    mov eax, 62
    clc
    ret
.slash:
    mov eax, 63
    clc
    ret
.bad:
    stc
    ret
