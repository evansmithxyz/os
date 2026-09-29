; ==============================================================================
; Antigravity OS - JavaScript: fetch and XMLHttpRequest
; ------------------------------------------------------------------------------
; fetch(url) returns a promise and queues the request as a task on the event
; loop (jsev_add_timer, no delay); the task does the GET with the browser's
; HTTP(S) client (browser_fetch_any: resolved against the page, any status)
; and resolves the promise with a Response (status, ok, statusText, url,
; headers.get(), text(), json()), or rejects it with "TypeError: Failed to
; fetch". XMLHttpRequest does the same with open() / send() and its events
; (readystatechange, load, error, loadend: on* properties and listeners);
; send() on a synchronous request fetches at once. Only GET for now.
; ==============================================================================

[bits 64]

section .bss
alignb 8
jsn_response_proto:     resq 1
jsn_response_ctor:      resq 1
jsn_headers_proto:      resq 1
jsn_headers_ctor:       resq 1
jsn_xhr_proto:          resq 1
jsn_xhr_ctor:           resq 1
jsn_atom_body:          resq 1          ; hidden properties
jsn_atom_raw:           resq 1
jsn_atom_url:           resq 1
jsn_atom_method:        resq 1
jsn_atom_async:         resq 1
jsn_atom_headers:       resq 1
jsn_atom_listeners:     resq 1
jsn_atom_aborted:       resq 1
jsn_atom_req_body:      resq 1
jsn_atom_req_type:      resq 1
jsn_method_buf:         resb 16         ; the request's method, upper case
jsn_type_buf:           resb 128        ; its body's Content-Type

section .rodata
jsn_ctors:
JSCTOR jsn_response_ctor, jsn_response, 0, jsn_response_proto, "Response"
JSCTOR jsn_headers_ctor, jsn_headers, 0, jsn_headers_proto, "Headers"
JSCTOR jsn_xhr_ctor, jsn_xhr, 0, jsn_xhr_proto, "XMLHttpRequest"
    dq 0

jsn_natives:
JSNATIVE js_global, "fetch", jsn_fetch, 1
JSNATIVE jsn_response_proto, "text", jsn_response_text, 0
JSNATIVE jsn_response_proto, "json", jsn_response_json, 0
JSNATIVE jsn_headers_proto, "get", jsn_headers_get, 1
JSNATIVE jsn_headers_proto, "has", jsn_headers_has, 1
JSNATIVE jsn_xhr_proto, "open", jsn_xhr_open, 2
JSNATIVE jsn_xhr_proto, "send", jsn_xhr_send, 0
JSNATIVE jsn_xhr_proto, "abort", jsn_xhr_abort, 0
JSNATIVE jsn_xhr_proto, "setRequestHeader", jsn_xhr_set_header, 2
JSNATIVE jsn_xhr_proto, "getResponseHeader", jsn_xhr_header, 1
JSNATIVE jsn_xhr_proto, "getAllResponseHeaders", jsn_xhr_all_headers, 0
JSNATIVE jsn_xhr_proto, "addEventListener", jsn_xhr_listen, 2
JSNATIVE jsn_xhr_proto, "removeEventListener", jsn_xhr_unlisten, 2
    dq 0

; XMLHttpRequest.UNSENT ... DONE (on the constructor and its prototype)
jsn_states:
    dq jsn_str_unsent, jsn_str_opened, jsn_str_headers_received, jsn_str_loading, jsn_str_done, 0
jsn_str_unsent:         db "UNSENT", 0
jsn_str_opened:         db "OPENED", 0
jsn_str_headers_received: db "HEADERS_RECEIVED", 0
jsn_str_loading:        db "LOADING", 0
jsn_str_done:           db "DONE", 0

jsn_str_body:           db " body", 0
jsn_str_raw:            db " raw", 0
jsn_str_url_h:          db " url", 0
jsn_str_method_h:       db " method", 0
jsn_str_async_h:        db " async", 0
jsn_str_headers_h:      db " headers", 0
jsn_str_listeners_h:    db " listeners", 0
jsn_str_aborted_h:      db " aborted", 0
jsn_str_req_body_h:     db " reqbody", 0
jsn_str_req_type_h:     db " reqtype", 0
jsn_str_init_body:      db "body", 0
jsn_str_init_headers:   db "headers", 0
jsn_str_content_type:   db "Content-Type", 0
jsn_str_content_type_lc: db "content-type", 0
jsn_type_text:          db "text/plain;charset=UTF-8", 0
jsn_str_status:         db "status", 0
jsn_str_status_text:    db "statusText", 0
jsn_str_headers:        db "headers", 0
jsn_str_ok:             db "ok", 0
jsn_str_redirected:     db "redirected", 0
jsn_str_type:           db "type", 0
jsn_str_basic:          db "basic", 0
jsn_str_url:            db "url", 0
jsn_str_method:         db "method", 0
jsn_str_get:            db "GET", 0
jsn_str_json:           db "json", 0
jsn_str_ready_state:    db "readyState", 0
jsn_str_response:       db "response", 0
jsn_str_response_text:  db "responseText", 0
jsn_str_response_url:   db "responseURL", 0
jsn_str_response_type:  db "responseType", 0
jsn_str_target:         db "target", 0
jsn_str_current_target: db "currentTarget", 0
jsn_ev_rsc:             db "readystatechange", 0
jsn_ev_load:            db "load", 0
jsn_ev_error:           db "error", 0
jsn_ev_loadend:         db "loadend", 0
jsn_on_rsc:             db "onreadystatechange", 0
jsn_on_load:            db "onload", 0
jsn_on_error:           db "onerror", 0
jsn_on_loadend:         db "onloadend", 0
jsmsg_fetch_failed:     db "Failed to fetch", 0
jsmsg_illegal_ctor:     db "Illegal constructor", 0

section .text

; ------------------------------------------------------------------------------
; jsn_init: fetch, Response, Headers, XMLHttpRequest (js_init_builtins)
; ------------------------------------------------------------------------------
jsn_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov rbx, [js_object_proto]
    mov rax, rbx
    call jsobj_new
    mov [jsn_response_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [jsn_headers_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [jsn_xhr_proto], rax
    lea r8, [jsn_ctors]
    call jsb_define_ctors
    lea r8, [jsn_natives]
    call jsb_define_natives
    ; the hidden property names
%macro JSN_ATOM 2
    lea rsi, [%2]
    call jsstr_from_cstr
    mov [%1], rax
%endmacro
    JSN_ATOM jsn_atom_body, jsn_str_body
    JSN_ATOM jsn_atom_raw, jsn_str_raw
    JSN_ATOM jsn_atom_url, jsn_str_url_h
    JSN_ATOM jsn_atom_method, jsn_str_method_h
    JSN_ATOM jsn_atom_async, jsn_str_async_h
    JSN_ATOM jsn_atom_headers, jsn_str_headers_h
    JSN_ATOM jsn_atom_listeners, jsn_str_listeners_h
    JSN_ATOM jsn_atom_aborted, jsn_str_aborted_h
    JSN_ATOM jsn_atom_req_body, jsn_str_req_body_h
    JSN_ATOM jsn_atom_req_type, jsn_str_req_type_h
    ; XMLHttpRequest.UNSENT = 0 ... DONE = 4
    lea rbx, [jsn_states]
    xor r8d, r8d
.state:
    mov rsi, [rbx + r8*8]
    test rsi, rsi
    jz .done
    mov eax, r8d
    call jsb_from_int
    mov rcx, rax
    mov rax, [jsn_xhr_ctor]
    mov edx, 3                      ; hidden, read-only
    call jsb_define
    mov rax, [jsn_xhr_proto]
    call jsb_define
    inc r8d
    jmp .state
.done:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsn_put: RAX = object (raw), RSI = name, RCX = value -> own property
; (enumerable)
jsn_put:
    push rdx
    xor edx, edx
    call jsb_define
    pop rdx
    ret

; jsn_hide: RAX = object (raw), RDX = atom, RCX = value -> hidden property
jsn_hide:
    push rax
    push rdx
    mov edx, edx
    bts rdx, 32
    call jsobj_define
    pop rdx
    pop rax
    ret

; jsn_hidden: RAX = object (value), RDX = atom -> RAX = that hidden property
jsn_hidden:
    jmp js_get

; ==============================================================================
; fetch
; ==============================================================================

; fetch(url, init) -> a promise of a Response (init: method, body, and a
; Content-Type in headers)
jsn_fetch:
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
    mov rbx, rax                    ; the URL
    mov rdx, JS_UNDEF               ; RDX = init
    cmp ecx, 2
    jb .no_init
    mov eax, 1
    call jsb_arg
    mov rdx, rax
.no_init:
    call jsprom_new
    mov r8, rax
    ; the request is a task (the page goes on meanwhile):
    ; [promise, url, method, body, content type]
    mov ecx, 5
    call jsarr_new
    mov rsi, rax
    mov rcx, r8
    BOX rcx, rax, JS_OBJ_BITS
    mov rax, rsi
    call jsarr_push
    mov rcx, rbx
    BOX rcx, rax, JS_STR_BITS
    mov rax, rsi
    call jsarr_push
    lea r9, [jsn_str_method]
    mov rax, rdx
    call jsn_field
    mov rcx, rax
    mov rax, rsi
    call jsarr_push
    lea r9, [jsn_str_init_body]
    mov rax, rdx
    call jsn_field
    mov rcx, rax
    mov rax, rsi
    call jsarr_push
    lea r9, [jsn_str_init_headers]
    mov rax, rdx
    call jsn_field
    mov rdx, rax                    ; RDX = init.headers
    lea r9, [jsn_str_content_type]
    call jsn_field
    mov rcx, JS_UNDEF
    cmp rax, rcx
    jne .have_type
    mov rax, rdx
    lea r9, [jsn_str_content_type_lc]
    call jsn_field
.have_type:
    mov rcx, rax
    mov rax, rsi
    call jsarr_push
    mov rdx, rsi
    lea rax, [jsn_fetch_task]
    call jsa_closure
    push rbx
    xor edx, edx
    xor ebx, ebx
    mov rsi, JS_UNDEF
    call jsev_add_timer
    pop rbx
    mov rax, r8
    BOX rax, rcx, JS_OBJ_BITS
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsn_field: RAX = a value, R9 = a property name -> RAX = that property if
; the value is an object, else undefined
jsn_field:
    push rcx
    push rdx
    push rsi
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .none
    push rax
    mov rsi, r9
    call jsstr_from_cstr
    mov rdx, rax
    pop rax
    call js_get
    jmp .out
.none:
    mov rax, JS_UNDEF
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; jsn_is_get: RAX = a method (value) -> CF=1 if undefined or "GET" (any case)
jsn_is_get:
    push rcx
    push rdx
    mov rcx, JS_UNDEF
    cmp rax, rcx
    je .yes
    call js_to_string
    cmp dword [rax + JSTR_LEN], 3
    jne .no
    mov edx, [rax + JSTR_DATA]
    and edx, 0x00DFDFDF             ; upper case
    cmp edx, 'GET'
    jne .no
.yes:
    pop rdx
    pop rcx
    stc
    ret
.no:
    pop rdx
    pop rcx
    clc
    ret

; jsn_fetch_task: R10 data [promise, url, method, body, type] -> the request
; done, the promise settled
jsn_fetch_task:
    push rdx
    push rsi
    mov rsi, [r10 + JFN_DATA]
    mov rsi, [rsi + JARR_ELEMS]
    push r8
    push r9
    push r10
    mov r8, [rsi + 16]
    mov r9, [rsi + 24]
    mov r10, [rsi + 32]
    mov eax, [rsi + 8]
    call jsn_request
    pop r10
    pop r9
    pop r8
    jc .failed
    mov rdx, rax
    mov eax, [rsi]
    call jsprom_resolve
    jmp .out
.failed:
    push rsi
    lea rsi, [jsmsg_fetch_failed]
    call jsstr_from_cstr
    mov edx, JE_TYPE
    call js_make_error
    pop rsi
    mov rdx, rax
    mov eax, [rsi]
    call jsprom_reject
.out:
    mov rax, JS_UNDEF
    pop rsi
    pop rdx
    ret

; ------------------------------------------------------------------------------
; jsn_request: RAX = URL (heap string), R8 = method, R9 = body, R10 = the
; body's Content-Type (values; undefined: GET, no body, text/plain) ->
; RAX = a Response; CF=1 if nothing came back. Cookies go along and come
; back as for pages (cookie.asm).
; ------------------------------------------------------------------------------
jsn_request:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r11
    mov r11, rax                    ; R11 = the URL
    mov rax, r8
    call jsn_is_get
    jc .fetch
    ; the method, upper case
    mov rax, r8
    call js_to_string
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    cmp ecx, 15
    jbe .method_len
    mov ecx, 15
.method_len:
    lea rdi, [jsn_method_buf]
    mov [http_req_method], rdi
.method_byte:
    test ecx, ecx
    jz .method_done
    lodsb
    cmp al, 'a'
    jb .method_put
    cmp al, 'z'
    ja .method_put
    sub al, 32
.method_put:
    stosb
    dec ecx
    jmp .method_byte
.method_done:
    mov byte [rdi], 0
    ; the body's type
    mov rax, r10
    call jsn_is_nothing
    jc .body
    call js_to_string
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    cmp ecx, 127
    jbe .type_len
    mov ecx, 127
.type_len:
    lea rdi, [jsn_type_buf]
    mov [http_req_type], rdi
    rep movsb
    mov byte [rdi], 0
.body:
    ; the body (last: nothing is allocated after it until it is sent)
    mov rax, r9
    call jsn_is_nothing
    jc .fetch
    call js_to_string
    mov r9, rax                     ; (kept in a register while it is sent)
    lea rsi, [rax + JSTR_DATA]
    mov [http_req_body], rsi
    mov ecx, [rax + JSTR_LEN]
    mov [http_req_body_len], ecx
    cmp qword [http_req_type], 0
    jne .fetch
    lea rsi, [jsn_type_text]
    mov [http_req_type], rsi
.fetch:
    mov rax, r11
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    call browser_fetch_any
    pushf
    call http_req_clear
    popf
    jc .out
    call jsn_make_response
    clc
.out:
    pop r11
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; jsn_is_nothing: RAX = a value -> CF=1 if it is undefined or null
jsn_is_nothing:
    push rcx
    mov rcx, JS_UNDEF
    cmp rax, rcx
    je .yes
    mov rcx, JS_NULL
    cmp rax, rcx
    je .yes
    pop rcx
    clc
    ret
.yes:
    pop rcx
    stc
    ret

; jsn_make_response: browser_fetch_any's results (EAX status, R8/R9 its
; text, RSI/RDX headers, RDI/RCX body; browser_resolved the URL) -> RAX = a
; Response (value)
jsn_make_response:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov r10d, eax
    ; the texts first: the response buffer is only good until the next fetch
    push rsi
    mov rsi, rdi
    call jsstr_new
    mov rdi, rax                    ; the body
    pop rsi
    mov ecx, edx
    call jsstr_new
    mov r11, rax                    ; the header lines
    mov rsi, r8
    mov ecx, r9d
    call jsstr_new
    mov r9, rax                     ; the status text
    mov rax, [jsn_response_proto]
    call jsobj_new
    mov rbx, rax
    mov eax, r10d
    call jsb_from_int
    mov rcx, rax
    mov rax, rbx
    lea rsi, [jsn_str_status]
    call jsn_put
    mov rcx, r9
    BOX rcx, rax, JS_STR_BITS
    mov rax, rbx
    lea rsi, [jsn_str_status_text]
    call jsn_put
    mov rax, r11
    call jsn_headers_of
    mov rcx, rax
    mov rax, rbx
    lea rsi, [jsn_str_headers]
    call jsn_put
    lea eax, [r10 - 200]
    cmp eax, 100
    setb al
    shr al, 1                       ; CF = 200 .. 299
    call js_bool
    mov rcx, rax
    mov rax, rbx
    lea rsi, [jsn_str_ok]
    call jsn_put
    mov rcx, JS_FALSE
    lea rsi, [jsn_str_redirected]
    call jsn_put
    lea rsi, [jsn_str_basic]
    call jsb_cstr
    mov rcx, rax
    mov rax, rbx
    lea rsi, [jsn_str_type]
    call jsn_put
    mov rsi, [browser_resolved]
    call jsb_cstr
    mov rcx, rax
    mov rax, rbx
    lea rsi, [jsn_str_url]
    call jsn_put
    mov rcx, rdi
    BOX rcx, rax, JS_STR_BITS
    mov rax, rbx
    mov rdx, [jsn_atom_body]
    call jsn_hide
    mov rax, rbx
    BOX rax, rcx, JS_OBJ_BITS
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

; jsn_headers_of: RAX = header lines (heap string) -> RAX = a Headers (value)
jsn_headers_of:
    push rcx
    push rdx
    mov rcx, rax
    BOX rcx, rdx, JS_STR_BITS
    mov rax, [jsn_headers_proto]
    call jsobj_new
    mov rdx, [jsn_atom_raw]
    call jsn_hide
    BOX rax, rcx, JS_OBJ_BITS
    pop rdx
    pop rcx
    ret

; new Response(body, {status, statusText})
jsn_response:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    xor eax, eax
    call jsb_arg
    mov rdx, JS_UNDEF
    cmp rax, rdx
    jne .body
    mov rax, [atom_empty]
    jmp .have_body
.body:
    call js_to_string
.have_body:
    mov rbx, rax
    mov r8d, 200                    ; the status
    mov r9, [atom_empty]            ; its text
    mov eax, 1
    call jsb_arg
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .make
    mov rdi, rax
    lea rsi, [jsn_str_status]
    call jsstr_from_cstr
    mov rdx, rax
    mov rax, rdi
    call js_get
    mov rdx, JS_UNDEF
    cmp rax, rdx
    je .status_text
    call js_to_int32
    mov r8d, eax
.status_text:
    lea rsi, [jsn_str_status_text]
    call jsstr_from_cstr
    mov rdx, rax
    mov rax, rdi
    call js_get
    mov rdx, JS_UNDEF
    cmp rax, rdx
    je .make
    call js_to_string
    mov r9, rax
.make:
    ; like a fetched response, from these strings
    mov eax, r8d
    lea rsi, [r9 + JSTR_DATA]
    mov r8, rsi
    mov r9d, [r9 + JSTR_LEN]
    lea rdi, [rbx + JSTR_DATA]
    mov ecx, [rbx + JSTR_LEN]
    lea rsi, [jsn_str_body]         ; (no header lines)
    xor edx, edx
    push qword [browser_resolved]
    lea r10, [atom_empty]
    mov r10, [r10]
    lea r10, [r10 + JSTR_DATA]
    mov [browser_resolved], r10
    call jsn_make_response
    pop qword [browser_resolved]
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; new Headers()
jsn_headers:
    mov rax, [atom_empty]
    jmp jsn_headers_of

; jsn_body: RDX = a Response -> RAX = its body (value)
jsn_body:
    push rdx
    mov rax, rdx
    mov rdx, [jsn_atom_body]
    call js_get
    pop rdx
    ret

; response.text() -> a promise of the body
jsn_response_text:
    call jsn_body
    push rdx
    mov rdx, rax
    call jsprom_new
    call jsprom_resolve
    BOX rax, rdx, JS_OBJ_BITS
    pop rdx
    ret

; response.json() -> a promise of JSON.parse(body)
jsn_response_json:
    push rbx
    push rdx
    call jsn_body
    call jsn_parse_safe
    setc bl
    mov rdx, rax
    call jsprom_new
    test bl, bl
    jnz .rejected
    call jsprom_resolve
    jmp .out
.rejected:
    call jsprom_reject
.out:
    BOX rax, rdx, JS_OBJ_BITS
    pop rdx
    pop rbx
    ret

; jsn_parse_safe: RAX = text (value) -> RAX = JSON.parse(text); CF=1 (RAX =
; the error) if it is not JSON
jsn_parse_safe:
    push rbx
    lea rbx, [jsn_parse_body]
    jmp js_protected
jsn_parse_body:
    push rax
    mov rdi, rsp
    mov ecx, 1
    call jsl_json_parse
    add rsp, 8
    ret

; headers.get(name) -> the value of that header (the first), or null
jsn_headers_get:
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
    mov r8, rax                     ; the name
    mov rax, rdx
    mov rdx, [jsn_atom_raw]
    call js_get
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_STRING
    jne .null
    mov eax, eax
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    lea rbx, [rsi + rcx]            ; the end
.line:
    cmp rsi, rbx
    jae .null
    ; does this line start with the name and ':'?
    mov ecx, [r8 + JSTR_LEN]
    lea rdi, [r8 + JSTR_DATA]
    mov rdx, rsi
.char:
    test ecx, ecx
    jz .colon
    cmp rdx, rbx
    jae .null
    mov al, [rdx]
    mov ah, [rdi]
    or ax, 0x2020                   ; (letters: case does not matter)
    cmp al, ah
    jne .next_line
    inc rdx
    inc rdi
    dec ecx
    jmp .char
.colon:
    cmp rdx, rbx
    jae .null
    cmp byte [rdx], ':'
    jne .next_line
    inc rdx
.space:
    cmp rdx, rbx
    jae .value
    cmp byte [rdx], ' '
    jne .value
    inc rdx
    jmp .space
.value:
    mov rsi, rdx
.value_end:
    cmp rdx, rbx
    jae .found
    cmp byte [rdx], 13
    je .found
    cmp byte [rdx], 10
    je .found
    inc rdx
    jmp .value_end
.found:
    mov rcx, rdx
    sub rcx, rsi
    call jsstr_new
    call jsb_box_string
    jmp .out
.next_line:
    cmp rsi, rbx
    jae .null
    lodsb
    cmp al, 10
    jne .next_line
    jmp .line
.null:
    mov rax, JS_NULL
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; headers.has(name)
jsn_headers_has:
    call jsn_headers_get
    push rdx
    mov rdx, JS_NULL
    cmp rax, rdx
    pop rdx
    setne al
    shr al, 1
    jmp js_bool

; ==============================================================================
; XMLHttpRequest
; ==============================================================================

; new XMLHttpRequest()
jsn_xhr:
    test r8d, r8d
    jz .not_new
    push rbx
    push rcx
    push rsi
    mov ebx, edx                    ; this (made by new)
    call jsn_xhr_reset
    mov rcx, JS_NULL
    mov rax, rbx
    lea rsi, [jsn_on_rsc]
    call jsn_hide_cstr
    lea rsi, [jsn_on_load]
    call jsn_hide_cstr
    lea rsi, [jsn_on_error]
    call jsn_hide_cstr
    lea rsi, [jsn_on_loadend]
    call jsn_hide_cstr
    mov rax, [atom_empty]
    call jsb_box_string
    mov rcx, rax
    mov rax, rbx
    lea rsi, [jsn_str_response_type]
    call jsn_put
    mov rax, rdx
    pop rsi
    pop rcx
    pop rbx
    ret
.not_new:
    lea rsi, [jsmsg_illegal_ctor]
    xor edi, edi
    jmp js_throw_type

; jsn_hide_cstr: RAX = object (raw), RSI = name, RCX = value -> hidden
jsn_hide_cstr:
    push rdx
    mov edx, 1
    call jsb_define
    pop rdx
    ret

; jsn_xhr_reset: RBX = XMLHttpRequest (raw) -> readyState 0, status 0 and
; empty responses
jsn_xhr_reset:
    push rax
    push rcx
    push rsi
    xor ecx, ecx                    ; (the number 0)
    mov rax, rbx
    lea rsi, [jsn_str_ready_state]
    call jsn_put
    lea rsi, [jsn_str_status]
    call jsn_put
    mov rax, [atom_empty]
    call jsb_box_string
    mov rcx, rax
    mov rax, rbx
    lea rsi, [jsn_str_status_text]
    call jsn_put
    lea rsi, [jsn_str_response_text]
    call jsn_put
    lea rsi, [jsn_str_response]
    call jsn_put
    lea rsi, [jsn_str_response_url]
    call jsn_put
    pop rsi
    pop rcx
    pop rax
    ret

; jsn_this_xhr: RDX = this -> RBX = it (raw); TypeError if it is no object
jsn_this_xhr:
    mov rbx, rdx
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    jne .bad
    mov ebx, edx
    ret
.bad:
    lea rsi, [jsmsg_illegal]
    xor edi, edi
    jmp js_throw_type

; xhr.open(method, url, async = true)
jsn_xhr_open:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call jsn_this_xhr
    call jsn_xhr_reset
    xor eax, eax
    call jsb_arg
    call js_to_string
    BOX rax, rsi, JS_STR_BITS
    push rcx
    mov rcx, rax
    mov rax, rbx
    mov rdx, [jsn_atom_method]
    call jsn_hide
    pop rcx
    mov eax, 1
    call jsb_arg
    call js_to_string
    BOX rax, rsi, JS_STR_BITS
    push rcx
    mov rcx, rax
    mov rax, rbx
    mov rdx, [jsn_atom_url]
    call jsn_hide
    pop rcx
    ; async unless the third argument is given and falsy
    mov rsi, JS_TRUE
    cmp ecx, 3
    jb .async
    mov eax, 2
    call jsb_arg
    mov rsi, JS_UNDEF
    cmp rax, rsi
    mov rsi, JS_TRUE
    je .async
    call js_truthy
    call js_bool
    mov rsi, rax
.async:
    mov rcx, rsi
    mov rax, rbx
    mov rdx, [jsn_atom_async]
    call jsn_hide
    mov rcx, JS_FALSE
    mov rax, rbx
    mov rdx, [jsn_atom_aborted]
    call jsn_hide
    mov rcx, JS_UNDEF               ; no Content-Type from an earlier request
    mov rdx, [jsn_atom_req_type]
    call jsn_hide
    mov eax, 1
    call jsb_from_int
    mov rcx, rax
    mov rax, rbx
    lea rsi, [jsn_str_ready_state]
    call jsn_put
    ; readystatechange
    mov rax, rbx
    BOX rax, rcx, JS_OBJ_BITS
    lea rsi, [jsn_ev_rsc]
    lea rdi, [jsn_on_rsc]
    call jsn_xhr_fire
    mov rax, JS_UNDEF
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; xhr.send(): a task (or at once for a synchronous request)
jsn_xhr_send:
    push rbx
    push rcx
    push rdx
    push rsi
    call jsn_this_xhr
    xor eax, eax                    ; the body (undefined if none)
    call jsb_arg
    push rcx
    push rdx
    mov rcx, rax
    mov rax, rbx
    mov rdx, [jsn_atom_req_body]
    call jsn_hide
    pop rdx
    pop rcx
    mov rax, rdx
    mov rdx, [jsn_atom_async]
    call js_get
    mov rcx, JS_FALSE
    cmp rax, rcx
    je .now
    mov rdx, rbx
    BOX rdx, rax, JS_OBJ_BITS
    lea rax, [jsn_xhr_task]
    call jsa_closure
    push rbx
    xor edx, edx
    xor ebx, ebx
    mov rsi, JS_UNDEF
    call jsev_add_timer
    pop rbx
    jmp .out
.now:
    mov rax, rbx
    call jsn_xhr_run
.out:
    mov rax, JS_UNDEF
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; xhr.setRequestHeader(name, value): only Content-Type is sent
jsn_xhr_set_header:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call jsn_this_xhr
    xor eax, eax
    call jsb_arg
    call js_to_string
    cmp dword [rax + JSTR_LEN], 12
    jne .done
    lea rsi, [rax + JSTR_DATA]
    lea rdx, [jsn_str_content_type_lc]  ; (RDI is the arguments)
    push rcx
    mov ecx, 12
.byte:
    mov al, [rsi]
    cmp al, 'A'
    jb .cmp
    cmp al, 'Z'
    ja .cmp
    or al, 0x20
.cmp:
    cmp al, [rdx]
    jne .differs
    inc rsi
    inc rdx
    dec ecx
    jnz .byte
.differs:
    pop rcx
    jne .done
    mov eax, 1
    call jsb_arg
    mov rcx, rax
    mov rax, rbx
    mov rdx, [jsn_atom_req_type]
    call jsn_hide
.done:
    mov rax, JS_UNDEF
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; xhr.abort()
jsn_xhr_abort:
    push rbx
    push rcx
    push rdx
    call jsn_this_xhr
    mov rax, rbx
    mov rcx, JS_TRUE
    mov rdx, [jsn_atom_aborted]
    call jsn_hide
    call jsn_xhr_reset
    mov rax, JS_UNDEF
    pop rdx
    pop rcx
    pop rbx
    ret

; the task send() queues: R10 data = the request
jsn_xhr_task:
    mov eax, [r10 + JFN_DATA]
    call jsn_xhr_run
    mov rax, JS_UNDEF
    ret

; ------------------------------------------------------------------------------
; jsn_xhr_run: RAX = XMLHttpRequest (raw) -> its GET done, its fields set and
; readystatechange, load or error, loadend fired
; ------------------------------------------------------------------------------
jsn_xhr_run:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rbx, rax
    mov r8, rax
    BOX r8, rax, JS_OBJ_BITS        ; the request (value)
    mov rax, r8
    mov rdx, [jsn_atom_aborted]
    call js_get
    mov rcx, JS_TRUE
    cmp rax, rcx
    je .out
    ; its method, body (send()) and Content-Type (setRequestHeader())
    push r9
    push r10
    push r8
    mov rax, r8
    mov rdx, [jsn_atom_req_body]
    call js_get
    mov r9, rax
    mov rax, r8
    mov rdx, [jsn_atom_req_type]
    call js_get
    mov r10, rax
    mov rax, r8
    mov rdx, [jsn_atom_url]
    call js_get
    push rax
    mov rax, r8
    mov rdx, [jsn_atom_method]
    call js_get
    mov r8, rax
    pop rax
    mov eax, eax
    call jsn_request
    pop r8
    pop r10
    pop r9
    jc .failed
    ; the response's fields onto the request
    mov rdi, rax                    ; the Response
    lea rsi, [jsn_str_status]
    call .copy
    lea rsi, [jsn_str_status_text]
    call .copy
    mov rax, rdi
    lea rsi, [jsn_str_url]
    call jsn_get_cstr
    mov rcx, rax
    mov rax, rbx
    lea rsi, [jsn_str_response_url]
    call jsn_put
    mov rax, rdi
    lea rsi, [jsn_str_headers]
    call jsn_get_cstr
    mov rcx, rax
    mov rax, rbx
    mov rdx, [jsn_atom_headers]
    call jsn_hide
    mov rdx, rdi
    call jsn_body
    mov rcx, rax
    mov rax, rbx
    lea rsi, [jsn_str_response_text]
    call jsn_put
    ; response: the text, or parsed for responseType "json" (null if not JSON)
    mov rax, r8
    lea rsi, [jsn_str_response_type]
    call jsn_get_cstr
    call js_to_string
    mov rdx, rax
    lea rsi, [jsn_str_json]
    call jsstr_from_cstr
    call jsstr_equal
    jnc .response
    mov rax, rcx
    call jsn_parse_safe
    mov rcx, rax
    jnc .response
    mov rcx, JS_NULL
.response:
    mov rax, rbx
    lea rsi, [jsn_str_response]
    call jsn_put
    call .done_state
    lea rsi, [jsn_ev_load]
    lea rdi, [jsn_on_load]
    jmp .end
.failed:
    call .done_state
    lea rsi, [jsn_ev_error]
    lea rdi, [jsn_on_error]
.end:
    mov rax, r8
    call jsn_xhr_fire
    lea rsi, [jsn_ev_loadend]
    lea rdi, [jsn_on_loadend]
    call jsn_xhr_fire
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
; .copy: RSI = name -> the Response's (RDI) property onto the request (RBX)
.copy:
    push rsi
    mov rax, rdi
    call jsn_get_cstr
    mov rcx, rax
    mov rax, rbx
    pop rsi
    jmp jsn_put
; .done_state: readyState 4, then readystatechange
.done_state:
    mov eax, 4
    call jsb_from_int
    mov rcx, rax
    mov rax, rbx
    lea rsi, [jsn_str_ready_state]
    call jsn_put
    mov rax, r8
    lea rsi, [jsn_ev_rsc]
    lea rdi, [jsn_on_rsc]
    jmp jsn_xhr_fire

; jsn_get_cstr: RAX = object (value), RSI = name -> RAX = its property
jsn_get_cstr:
    push rdx
    push rax
    call jsstr_from_cstr
    mov rdx, rax
    pop rax
    call js_get
    pop rdx
    ret

; ------------------------------------------------------------------------------
; jsn_xhr_fire: RAX = XMLHttpRequest (value), RSI = event type, RDI = its on*
; property -> the handler, then the listeners, called with {type, target}
; (errors are printed)
; ------------------------------------------------------------------------------
jsn_xhr_fire:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, rax
    ; the event
    push rsi
    call jsobj_new_plain
    mov r9, rax
    pop rsi
    push rsi
    call jsb_cstr
    mov rcx, rax
    mov rax, r9
    lea rsi, [jsn_str_type]
    call jsn_put
    mov rcx, r8
    lea rsi, [jsn_str_target]
    call jsn_put
    lea rsi, [jsn_str_current_target]
    call jsn_put
    BOX r9, rax, JS_OBJ_BITS
    ; xhr.on<type>
    mov rax, r8
    mov rsi, rdi
    call jsn_get_cstr
    call jsn_fire_one
    ; the listeners for the type
    pop rsi
    mov rax, r8
    mov rdx, [jsn_atom_listeners]
    call js_get
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .out
    call jsn_get_cstr
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .out
    mov ebx, eax
    cmp byte [rbx + JH_KIND], JK_ARRAY
    jne .out
    xor ecx, ecx
.listener:
    cmp ecx, [rbx + JARR_LEN]
    jae .out
    mov rax, [rbx + JARR_ELEMS]
    mov rax, [rax + rcx*8]
    call jsn_fire_one
    inc ecx
    jmp .listener
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

; jsn_fire_one: RAX = handler (anything), R8 = this, R9 = the event -> called
; if it is a function
jsn_fire_one:
    call js_is_callable
    jnc .ret
    push rcx
    push rdx
    push rdi
    push r9
    mov rdi, rsp
    mov rdx, r8
    mov ecx, 1
    call js_call_safe
    jnc .done
    call js_print_error
.done:
    pop r9
    pop rdi
    pop rdx
    pop rcx
.ret:
    ret

; xhr.getResponseHeader(name)
jsn_xhr_header:
    push rdx
    mov rax, rdx
    mov rdx, [jsn_atom_headers]
    call js_get
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .null
    mov rdx, rax
    call jsn_headers_get
    pop rdx
    ret
.null:
    mov rax, JS_NULL
    pop rdx
    ret

; xhr.getAllResponseHeaders(): the header lines as they came
jsn_xhr_all_headers:
    push rdx
    mov rax, rdx
    mov rdx, [jsn_atom_headers]
    call js_get
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .empty
    mov rdx, [jsn_atom_raw]
    call js_get
    pop rdx
    ret
.empty:
    mov rax, [atom_empty]
    pop rdx
    jmp jsb_box_string

; xhr.addEventListener(type, fn)
jsn_xhr_listen:
    push rbx
    push rcx
    push rdx
    push rsi
    call jsn_listeners
    mov rcx, [rdi + 8]
    call jsarr_push
    mov rax, JS_UNDEF
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; xhr.removeEventListener(type, fn)
jsn_xhr_unlisten:
    push rbx
    push rcx
    push rdx
    push rsi
    call jsn_listeners
    mov rsi, [rdi + 8]
    mov rdx, [rax + JARR_ELEMS]
    xor ecx, ecx
.find:
    cmp ecx, [rax + JARR_LEN]
    jae .out
    cmp [rdx + rcx*8], rsi
    je .found
    inc ecx
    jmp .find
.found:
    ; the ones after it move down
    inc ecx
.move:
    cmp ecx, [rax + JARR_LEN]
    jae .shrunk
    mov rsi, [rdx + rcx*8]
    mov [rdx + rcx*8 - 8], rsi
    inc ecx
    jmp .move
.shrunk:
    dec dword [rax + JARR_LEN]
.out:
    mov rax, JS_UNDEF
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsn_listeners: RDX = this, RDI/ECX = (type, fn) -> RAX = the listener
; array for the type (raw, made if needed)
jsn_listeners:
    push rcx
    call jsn_this_xhr
    mov rax, rdx
    mov rdx, [jsn_atom_listeners]
    call js_get
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    je .have
    call jsobj_new_plain
    mov rcx, rax
    BOX rcx, rsi, JS_OBJ_BITS
    mov rax, rbx
    mov rdx, [jsn_atom_listeners]
    call jsn_hide
    mov rax, rcx
.have:
    mov rbx, rax                    ; the listeners object (value)
    mov ecx, [rsp]                  ; (the argument count)
    xor eax, eax
    call jsb_arg
    call jsl_key_atom
    mov rdx, rax                    ; the type
    mov rax, rbx
    call js_get
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    je .array
    push rdx
    xor ecx, ecx
    call jsarr_new
    pop rdx
    mov rcx, rax
    BOX rcx, rsi, JS_OBJ_BITS
    push rax
    mov eax, ebx
    call jsn_hide                   ; (a hidden key, so it is not listed)
    pop rax
    pop rcx
    ret
.array:
    mov eax, eax
    pop rcx
    ret
