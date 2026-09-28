; ==============================================================================
; Antigravity OS - JavaScript: promises, async functions, timers, event loop
; ------------------------------------------------------------------------------
; Promises are objects of class JC_PROMISE with a state, a value and a list of
; reactions. Settling one queues a job per reaction on the microtask queue;
; jsev_drain runs the queue (after a script, a timer, an event handler) and
; then reports promises rejected with nobody listening ("Uncaught (in
; promise) ...").
;
; An async function starts with ASYNCSTART (a coroutine and its promise) and
; an implicit try whose catch rejects the promise. `await v` (jsco_suspend)
; copies the function's part of the value stack, its try handlers and its
; registers into the coroutine, subscribes to v and returns the promise to
; the caller; a job later copies it all back onto the stack (jsco_resume)
; and continues after the await, with the value or throwing the reason.
;
; Timers (setTimeout, setInterval, requestAnimationFrame) wait in a list;
; jsev_run_due runs the ones that are due. The `js` shell command waits for
; them in jsev_loop; the browser calls jsev_run_due from the desktop loop.
; ==============================================================================

[bits 64]

JPROM_STATE             equ 32          ; byte: 0 pending, 1 fulfilled, 2 rejected
JPROM_HANDLED           equ 33          ; byte: something reacts to it
JPROM_VALUE             equ 40
JPROM_REACTIONS         equ 48          ; raw array of reactions while pending, or 0
JPROM_SIZE              equ 56

; a reaction: raw array [on fulfilled, on rejected, target, JR_*]
JR_DERIVED              equ 0           ; target: the promise then() made (or undefined)
JR_AWAIT                equ 1           ; target: a suspended async function (raw)

; a job on the microtask queue: raw array [JOB_*, a, b, c]
JOB_REACTION            equ 0           ; reaction, the value, 1 if rejected
JOB_THENABLE            equ 1           ; promise (value), thenable, its then()
JOB_CALLBACK            equ 2           ; queueMicrotask(fn)

; a coroutine (JK_CORO): an async function between an await and its resumption
JCO_PROMISE             equ 8           ; the function's promise (value)
JCO_STACK               equ 16          ; its value stack slots, saved (raw block)
JCO_SLOTS               equ 24          ; dword
JCO_NHANDLERS           equ 28          ; dword
JCO_PC                  equ 32          ; after the await
JCO_ENV                 equ 40
JCO_FUNC                equ 48
JCO_HANDLERS            equ 56          ; its try handlers (JTH_SP relative), raw block
JCO_LINE                equ 64          ; dword
JCO_SIZE                equ 72

; a timer: raw array [id, function, due tick, interval (0 = once), arguments]
TM_ID                   equ 0
TM_FN                   equ 8
TM_WHEN                 equ 16
TM_INTERVAL             equ 24
TM_ARGS                 equ 32
JSEV_FRAME_MS           equ 16          ; requestAnimationFrame: about 60 per second
JSEV_MAX_DELAY          equ 0x7FFFFFFF

section .bss
alignb 8
js_promise_proto:       resq 1
jsa_promise_ctor:       resq 1
jsa_performance:        resq 1
jsev_micro:             resq 1          ; raw array of jobs
jsev_micro_head:        resq 1          ; the next job to run
jsev_timers:            resq 1          ; raw array of timers
jsev_frames:            resq 1          ; raw array of [id, callback] (requestAnimationFrame)
jsev_unhandled:         resq 1          ; raw array of promises rejected with no reaction
jsev_next_id:           resq 1
jsev_origin:            resq 1          ; timer_ticks at the start (performance.now)
jsev_last_frame:        resq 1
jsev_draining:          resb 1

section .rodata
jsa_ctors:
JSCTOR jsa_promise_ctor, jsa_promise, 1, js_promise_proto, "Promise"
    dq 0

jsa_natives:
JSNATIVE jsa_promise_ctor, "resolve", jsa_promise_resolve, 1
JSNATIVE jsa_promise_ctor, "reject", jsa_promise_reject, 1
JSNATIVE jsa_promise_ctor, "all", jsa_promise_all, 1
JSNATIVE jsa_promise_ctor, "allSettled", jsa_promise_all_settled, 1
JSNATIVE jsa_promise_ctor, "race", jsa_promise_race, 1
JSNATIVE jsa_promise_ctor, "any", jsa_promise_any, 1
JSNATIVE js_promise_proto, "then", jsa_then, 2
JSNATIVE js_promise_proto, "catch", jsa_catch, 1
JSNATIVE js_promise_proto, "finally", jsa_finally, 1
JSNATIVE js_global, "setTimeout", jsa_set_timeout, 2
JSNATIVE js_global, "setInterval", jsa_set_interval, 2
JSNATIVE js_global, "clearTimeout", jsa_clear_timer, 1
JSNATIVE js_global, "clearInterval", jsa_clear_timer, 1
JSNATIVE js_global, "requestAnimationFrame", jsa_request_frame, 1
JSNATIVE js_global, "cancelAnimationFrame", jsa_cancel_frame, 1
JSNATIVE js_global, "queueMicrotask", jsa_queue_microtask, 1
JSNATIVE jsa_performance, "now", jsa_performance_now, 0
    dq 0

jsa_name_performance:   db "performance", 0
jsa_name_errors:        db "errors", 0
jsa_name_aggregate:     db "AggregateError", 0
jsa_str_status:         db "status", 0
jsa_str_value:          db "value", 0
jsa_str_reason:         db "reason", 0
jsa_str_fulfilled:      db "fulfilled", 0
jsa_str_rejected:       db "rejected", 0
jsmsg_promise_new:      db "Promise constructor cannot be invoked without 'new'", 0
jsmsg_resolver:         db "Promise resolver % is not a function", 0
jsmsg_not_promise:      db "Method Promise.prototype.% called on incompatible receiver", 0
jsmsg_chaining:         db "Chaining cycle detected for promise #<Promise>", 0
jsmsg_all_rejected:     db "All promises were rejected", 0
jsmsg_in_promise:       db "Uncaught (in promise) ", 0
jsa_str_then:           db "then", 0
; resuming with a rejection: the reason is thrown where the await was
jsco_throw_code:        db OP_THROW

section .text

; ------------------------------------------------------------------------------
; jsa_init: Promise, timers, queueMicrotask, performance (js_init_builtins)
; ------------------------------------------------------------------------------
jsa_init:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    ; the queues
    xor ecx, ecx
    call jsarr_new
    mov [jsev_micro], rax
    call jsarr_new
    mov [jsev_timers], rax
    call jsarr_new
    mov [jsev_frames], rax
    call jsarr_new
    mov [jsev_unhandled], rax
    xor eax, eax
    mov [jsev_micro_head], rax
    mov [jsev_next_id], rax
    mov [jsev_last_frame], rax
    mov [jsev_draining], al
    mov [js_interrupted], al
    mov rax, [timer_ticks]
    mov [jsev_origin], rax
    ; Promise
    mov rax, [js_object_proto]
    call jsobj_new
    mov [js_promise_proto], rax
    lea r8, [jsa_ctors]
    call jsb_define_ctors
    ; performance
    call jsobj_new_plain
    mov [jsa_performance], rax
    mov rcx, rax
    BOX rcx, rdx, JS_OBJ_BITS
    mov rax, [js_global]
    lea rsi, [jsa_name_performance]
    mov edx, 1
    call jsb_define
    lea r8, [jsa_natives]
    call jsb_define_natives
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ==============================================================================
; Promises
; ==============================================================================

; jsprom_new: -> RAX = a pending promise (raw)
jsprom_new:
    push rcx
    mov ecx, JPROM_SIZE
    call js_alloc
    mov byte [rax + JH_KIND], JK_OBJECT
    mov dword [rax + JOBJ_CLASS], JC_PROMISE
    mov rcx, [js_promise_proto]
    mov [rax + JOBJ_PROTO], rcx
    mov rcx, JS_UNDEF
    mov [rax + JPROM_VALUE], rcx
    pop rcx
    ret

; jsprom_is: RAX = value -> CF=1 if it is a promise
jsprom_is:
    push rcx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .no
    mov ecx, eax
    cmp byte [rcx + JH_KIND], JK_OBJECT
    jne .no
    cmp dword [rcx + JOBJ_CLASS], JC_PROMISE
    jne .no
    pop rcx
    stc
    ret
.no:
    pop rcx
    clc
    ret

; jsprom_fulfill / jsprom_reject: RAX = promise (raw), RDX = value -> settled
; (a settled promise stays as it is), its reactions queued
jsprom_fulfill:
    push rcx
    mov cl, 1
    jmp jsprom_settle
jsprom_reject:
    push rcx
    mov cl, 2
jsprom_settle:
    push rax
    push rbx
    push rdx
    push rsi
    push rdi
    push r8
    cmp byte [rax + JPROM_STATE], 0
    jne .out
    mov [rax + JPROM_STATE], cl
    mov [rax + JPROM_VALUE], rdx
    mov rbx, [rax + JPROM_REACTIONS]
    mov qword [rax + JPROM_REACTIONS], 0
    xor r8d, r8d
    cmp cl, 2
    jne .reactions
    mov r8d, 1                      ; rejected
    cmp byte [rax + JPROM_HANDLED], 0
    jne .reactions
    ; nothing listens (yet): reported after the microtasks unless handled
    push rcx
    mov rcx, rax
    mov rax, [jsev_unhandled]
    call jsarr_push
    pop rcx
.reactions:
    test rbx, rbx
    jz .out
    xor esi, esi
.reaction:
    cmp esi, [rbx + JARR_LEN]
    jae .out
    mov rdi, [rbx + JARR_ELEMS]
    mov rdi, [rdi + rsi*8]
    mov eax, JOB_REACTION
    call jsev_enqueue               ; [REACTION, reaction, value, rejected]
    inc esi
    jmp .reaction
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    pop rax
    pop rcx
    ret

; ------------------------------------------------------------------------------
; jsprom_resolve: RAX = promise (raw), RDX = x -> the promise follows x: a
; thenable is adopted in a job, anything else fulfils it
; ------------------------------------------------------------------------------
jsprom_resolve:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rbx, rax
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .fulfill
    cmp edx, ebx
    jne .object
    ; resolved with itself
    lea rsi, [jsmsg_chaining]
    call jsstr_from_cstr
    mov edx, JE_TYPE
    call js_make_error
    mov rdx, rax
    jmp .reject
.object:
    mov rax, rdx
    push rdx
    mov rdx, [atom_then]
    call jsa_get_safe               ; a getter may throw
    pop rdx
    jc .threw
    call js_is_callable
    jnc .fulfill
    mov r8, rax                     ; then
    mov rdi, rbx
    BOX rdi, rax, JS_OBJ_BITS
    mov eax, JOB_THENABLE
    call jsev_enqueue               ; [THENABLE, promise, x, then]
    jmp .out
.threw:
    mov rdx, rax
.reject:
    mov rax, rbx
    call jsprom_reject
    jmp .out
.fulfill:
    mov rax, rbx
    call jsprom_fulfill
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsa_get_safe: RAX = value, RDX = atom -> RAX = value.name; CF=1 (RAX = the
; exception) if that threw
jsa_get_safe:
    push rbx
    lea rbx, [js_get]
    jmp js_protected

; jsa_call_catch: js_call_safe, except that an interrupted script (Esc /
; Ctrl+C) keeps unwinding
jsa_call_catch:
    call js_call_safe
    jnc .ok
    cmp byte [js_interrupted], 0
    jne js_throw_uncatchable
    stc
.ok:
    ret

; ------------------------------------------------------------------------------
; jsprom_then: RAX = promise (raw), RCX = on fulfilled, R8 = on rejected,
; R9 = target, R11D = JR_* -> the reaction added, or queued if it is settled
; ------------------------------------------------------------------------------
jsprom_then:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rbx, rax
    push rcx
    mov ecx, 4
    call jsarr_new
    mov rsi, rax                    ; the reaction
    pop rcx
    call jsarr_push
    mov rcx, r8
    mov rax, rsi
    call jsarr_push
    mov rcx, r9
    mov rax, rsi
    call jsarr_push
    mov ecx, r11d
    mov rax, rsi
    call jsarr_push
    mov byte [rbx + JPROM_HANDLED], 1
    movzx eax, byte [rbx + JPROM_STATE]
    test eax, eax
    jnz .settled
    mov rax, [rbx + JPROM_REACTIONS]
    test rax, rax
    jnz .add
    xor ecx, ecx
    call jsarr_new
    mov [rbx + JPROM_REACTIONS], rax
.add:
    mov rcx, rsi
    call jsarr_push
    jmp .out
.settled:
    xor r8d, r8d
    cmp eax, 2
    sete r8b
    mov rdi, rsi
    mov rdx, [rbx + JPROM_VALUE]
    mov eax, JOB_REACTION
    call jsev_enqueue
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsa_promise_of: RAX = value -> RAX = a promise for it (raw): a promise
; itself, or a new one resolved with the value (Promise.resolve)
jsa_promise_of:
    call jsprom_is
    jc .promise
    push rdx
    mov rdx, rax
    call jsprom_new
    call jsprom_resolve
    pop rdx
    ret
.promise:
    mov eax, eax
    ret

; ------------------------------------------------------------------------------
; jsa_resolving_functions: RAX = promise (raw) -> RAX = its resolve function,
; RDX = its reject function (raw); only the first call of either counts
; ------------------------------------------------------------------------------
jsa_resolving_functions:
    push rbx
    push rcx
    push rsi
    mov rsi, rax
    mov ecx, 2
    call jsarr_new
    mov rbx, rax                    ; [promise, already resolved]
    mov rcx, rsi
    BOX rcx, rax, JS_OBJ_BITS
    mov rax, rbx
    call jsarr_push
    xor ecx, ecx
    mov rax, rbx
    call jsarr_push
    lea rax, [jsa_reject_fn]
    mov ecx, 1
    mov rdx, [atom_empty]
    call jsfn_native
    mov [rax + JFN_DATA], rbx
    mov rsi, rax
    lea rax, [jsa_resolve_fn]
    call jsfn_native
    mov [rax + JFN_DATA], rbx
    mov rdx, rsi
    pop rsi
    pop rcx
    pop rbx
    ret

; resolve(value) / reject(reason): R10 = the function, its data [promise, done]
jsa_resolve_fn:
    push rbx
    mov ebx, 1
    jmp jsa_resolving
jsa_reject_fn:
    push rbx
    xor ebx, ebx
jsa_resolving:
    push rcx
    push rdx
    push rsi
    mov rsi, [r10 + JFN_DATA]
    mov rsi, [rsi + JARR_ELEMS]
    cmp qword [rsi + 8], 0
    jne .done
    mov qword [rsi + 8], 1
    xor eax, eax
    call jsb_arg
    mov rdx, rax
    mov eax, [rsi]                  ; the promise
    test ebx, ebx
    jz .reject
    call jsprom_resolve
    jmp .done
.reject:
    call jsprom_reject
.done:
    mov rax, JS_UNDEF
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; new Promise(executor)
; ------------------------------------------------------------------------------
jsa_promise:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    test r8d, r8d
    jz .not_new
    xor eax, eax
    call jsb_arg
    call js_is_callable
    jnc .bad_executor
    mov rbx, rax                    ; the executor
    call jsprom_new
    mov r9, rax
    mov ecx, edx                    ; this (made by new): its prototype
    mov rcx, [rcx + JOBJ_PROTO]
    mov [r9 + JOBJ_PROTO], rcx
    call jsa_resolving_functions
    BOX rax, rcx, JS_OBJ_BITS
    BOX rdx, rcx, JS_OBJ_BITS
    push rdx                        ; (reject, for an error)
    push rdx
    push rax
    mov rdi, rsp
    mov rax, rbx
    mov rdx, JS_UNDEF
    mov ecx, 2
    call jsa_call_catch
    add rsp, 16
    pop rbx
    jnc .done
    ; the executor threw: rejected (unless it was resolved already)
    push rax
    mov rdi, rsp
    mov rax, rbx
    mov rdx, JS_UNDEF
    mov ecx, 1
    call js_call
    add rsp, 8
.done:
    mov rax, r9
    BOX rax, rcx, JS_OBJ_BITS
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
.not_new:
    lea rsi, [jsmsg_promise_new]
    xor edi, edi
    jmp js_throw_type
.bad_executor:
    call js_to_string
    mov rdi, rax
    lea rsi, [jsmsg_resolver]
    jmp js_throw_type

; jsa_this_promise: RDX = this, RSI = method name -> RAX = the promise (raw)
jsa_this_promise:
    mov rax, rdx
    call jsprom_is
    jnc .bad
    mov eax, eax
    ret
.bad:
    call jsstr_from_cstr
    mov rdi, rax
    lea rsi, [jsmsg_not_promise]
    jmp js_throw_type

; promise.then(onFulfilled, onRejected)
jsa_then:
    push rsi
    lea rsi, [jsa_str_then]
    call jsa_this_promise
    pop rsi
    push rbx
    push rcx
    push r8
    push r9
    push r11
    mov rbx, rax
    xor eax, eax
    call jsb_arg
    push rax
    mov eax, 1
    call jsb_arg
    mov r8, rax
    pop rcx
jsa_then_common:                    ; RBX = promise, RCX/R8 = handlers
    call jsprom_new
    mov r9, rax
    BOX r9, rax, JS_OBJ_BITS        ; the derived promise
    mov rax, rbx
    xor r11d, r11d
    call jsprom_then
    mov rax, r9
    pop r11
    pop r9
    pop r8
    pop rcx
    pop rbx
    ret

; promise.catch(onRejected)
jsa_catch:
    push rsi
    lea rsi, [jsa_str_then]
    call jsa_this_promise
    pop rsi
    push rbx
    push rcx
    push r8
    push r9
    push r11
    mov rbx, rax
    xor eax, eax
    call jsb_arg
    mov r8, rax
    mov rcx, JS_UNDEF
    jmp jsa_then_common

; promise.finally(onFinally): runs it either way, then passes the value or
; the reason on (unless onFinally throws or returns a rejected promise)
jsa_finally:
    push rsi
    lea rsi, [jsa_str_then]
    call jsa_this_promise
    pop rsi
    push rbx
    push rcx
    push r8
    push r9
    push r11
    mov rbx, rax
    xor eax, eax
    call jsb_arg
    mov rcx, rax
    mov r8, rax
    call js_is_callable
    jnc jsa_then_common
    mov r9, rdx                     ; (this)
    mov rdx, rax                    ; their data: onFinally
    lea rax, [jsa_then_finally]
    call jsa_closure
    mov rcx, rax
    lea rax, [jsa_catch_finally]
    call jsa_closure
    mov r8, rax
    mov rdx, r9
    jmp jsa_then_common

; jsa_closure: RAX = native routine, RDX = its data -> RAX = a new function
; (value) with that data (read through R10 when it runs)
jsa_closure:
    push rcx
    push rdx
    push rdx
    mov ecx, 1
    mov rdx, [atom_empty]
    call jsfn_native
    pop rdx
    mov [rax + JFN_DATA], rdx
    BOX rax, rcx, JS_OBJ_BITS
    pop rdx
    pop rcx
    ret

; the functions finally() makes: R10 data = onFinally
jsa_then_finally:
    push rbx
    lea rbx, [jsa_value_thunk]
    jmp jsa_finally_step
jsa_catch_finally:
    push rbx
    lea rbx, [jsa_thrower]
jsa_finally_step:
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r11
    xor eax, eax
    call jsb_arg
    push rax                        ; the value or reason
    mov rax, [r10 + JFN_DATA]
    mov rdx, JS_UNDEF
    xor ecx, ecx
    call js_call                    ; onFinally()
    call jsa_promise_of
    mov r9, rax
    pop rdx
    mov rax, rbx
    call jsa_closure                ; () => value, or () => { throw reason }
    mov rcx, rax
    mov r8, JS_UNDEF
    mov rbx, r9
    ; the promise onFinally's result settles to, then(pass it on)
    call jsprom_new
    mov r9, rax
    BOX r9, rax, JS_OBJ_BITS
    mov rax, rbx
    xor r11d, r11d
    call jsprom_then
    mov rax, r9
    pop r11
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

jsa_value_thunk:
    mov rax, [r10 + JFN_DATA]
    ret
jsa_thrower:
    mov rax, [r10 + JFN_DATA]
    jmp js_throw_value

; Promise.resolve(value)
jsa_promise_resolve:
    xor eax, eax
    call jsb_arg
    call jsa_promise_of
    push rcx
    BOX rax, rcx, JS_OBJ_BITS
    pop rcx
    ret

; Promise.reject(reason)
jsa_promise_reject:
    push rdx
    xor eax, eax
    call jsb_arg
    mov rdx, rax
    call jsprom_new
    call jsprom_reject
    BOX rax, rdx, JS_OBJ_BITS
    pop rdx
    ret

; ------------------------------------------------------------------------------
; Promise.all / allSettled / race / any (iterable): arrays and strings
; ------------------------------------------------------------------------------
JSA_ALL                 equ 0
JSA_SETTLED             equ 1
JSA_RACE                equ 2
JSA_ANY                 equ 3

jsa_promise_all:
    push rbx
    mov ebx, JSA_ALL
    jmp jsa_combine
jsa_promise_all_settled:
    push rbx
    mov ebx, JSA_SETTLED
    jmp jsa_combine
jsa_promise_race:
    push rbx
    mov ebx, JSA_RACE
    jmp jsa_combine
jsa_promise_any:
    push rbx
    mov ebx, JSA_ANY
jsa_combine:
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
    push r14
    xor eax, eax
    call jsb_arg
    mov r11, rax                    ; the iterable
    call jsprom_new
    mov r12, rax                    ; the result
    call jsa_resolving_functions
    BOX rax, rcx, JS_OBJ_BITS
    BOX rdx, rcx, JS_OBJ_BITS
    mov r13, rax                    ; its resolve
    mov r14, rdx                    ; and reject
    ; the items
    xor ecx, ecx
    call jsarr_new
    mov rsi, rax
    mov rdx, r11
    call jsa_spread_safe
    jnc .items
    mov rdx, rax                    ; not iterable: rejected
    mov rax, r12
    call jsprom_reject
    jmp .out
.items:
    ; the shared state: [result, values, remaining, mode]
    mov ecx, 4
    call jsarr_new
    mov rdi, rax
    mov rcx, r12
    call jsarr_push
    mov ecx, [rsi + JARR_LEN]
    call jsarr_new
    call jsarr_set_length           ; (holes until the values come)
    mov rcx, rax
    mov rax, rdi
    call jsarr_push
    mov ecx, [rsi + JARR_LEN]
    mov rax, rdi
    call jsarr_push
    mov ecx, ebx
    mov rax, rdi
    call jsarr_push
    cmp dword [rsi + JARR_LEN], 0
    jne .each
    cmp ebx, JSA_RACE
    je .out                         ; race([]) stays pending
    mov rax, rdi
    call jsa_combine_finish
    jmp .out
.each:
    xor r10d, r10d                  ; index
.item:
    cmp r10d, [rsi + JARR_LEN]
    jae .out
    mov rax, [rsi + JARR_ELEMS]
    mov rax, [rax + r10*8]
    call jsa_promise_of
    mov r9, rax                     ; the item's promise
    mov rcx, r13                    ; race: resolve / reject the result
    mov r8, r14
    cmp ebx, JSA_RACE
    je .then
    ; an element function: data [state, index, done]
    push rsi
    mov ecx, 3
    call jsarr_new
    mov rsi, rax
    mov rcx, rdi
    call jsarr_push
    mov ecx, r10d
    mov rax, rsi
    call jsarr_push
    xor ecx, ecx
    mov rax, rsi
    call jsarr_push
    mov rdx, rsi
    pop rsi
    lea rax, [jsa_element_fulfilled]
    call jsa_closure
    mov rcx, rax
    cmp ebx, JSA_ALL
    je .then                        ; all: fulfilled -> element, rejected -> reject
    cmp ebx, JSA_ANY
    jne .settled
    mov r8, rax                     ; any: rejected -> element, fulfilled -> resolve
    mov rcx, r13
    jmp .then
.settled:
    lea rax, [jsa_element_rejected]
    call jsa_closure
    mov r8, rax
.then:
    push r9
    mov rax, r9
    mov r9, JS_UNDEF
    xor r11d, r11d
    call jsprom_then
    pop r9
    inc r10d
    jmp .item
.out:
    mov rax, r12
    BOX rax, rcx, JS_OBJ_BITS
    pop r14
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

; jsa_spread_safe: RAX = array, RDX = iterable -> its items appended; CF=1
; (RAX = the error) if it is not iterable
jsa_spread_safe:
    push rbx
    lea rbx, [jsa_spread_body]
    jmp js_protected
jsa_spread_body:
    call js_spread_into
    ret

; the element functions of all / allSettled / any: R10 data [state, index,
; done]; state [result (raw), values (raw), remaining, mode]
jsa_element_fulfilled:
    push rbx
    xor ebx, ebx
    jmp jsa_element
jsa_element_rejected:
    push rbx
    mov ebx, 1
jsa_element:
    push rcx
    push rdx
    push rsi
    push rdi
    xor eax, eax
    call jsb_arg
    mov rcx, rax                    ; the value or reason
    mov rsi, [r10 + JFN_DATA]
    mov rsi, [rsi + JARR_ELEMS]
    cmp qword [rsi + 16], 0
    jne .done
    mov qword [rsi + 16], 1
    mov rdi, [rsi]                  ; the state
    mov rax, [rdi + JARR_ELEMS]
    cmp qword [rax + 24], JSA_SETTLED
    jne .store
    ; allSettled: {status, value} / {status, reason}
    call jsa_settled_record
.store:
    mov rax, [rdi + JARR_ELEMS]
    mov rax, [rax + 8]              ; values
    mov edx, [rsi + 8]              ; index
    call jsarr_set
    mov rax, [rdi + JARR_ELEMS]
    dec qword [rax + 16]
    jnz .done
    mov rax, rdi
    call jsa_combine_finish
.done:
    mov rax, JS_UNDEF
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsa_settled_record: RCX = value, EBX = 1 if a reason -> RCX = the
; allSettled record for it
jsa_settled_record:
    push rax
    push rdx
    push rsi
    push rdi
    mov rdi, rcx
    call jsobj_new_plain
    mov rdx, rax
    lea rsi, [jsa_str_fulfilled]
    test ebx, ebx
    jz .status
    lea rsi, [jsa_str_rejected]
.status:
    call jsb_cstr
    mov rcx, rax
    lea rsi, [jsa_str_status]
    mov rax, rdx
    push rdx
    xor edx, edx
    call jsb_define
    pop rdx
    lea rsi, [jsa_str_value]
    test ebx, ebx
    jz .value
    lea rsi, [jsa_str_reason]
.value:
    mov rcx, rdi
    mov rax, rdx
    push rdx
    xor edx, edx
    call jsb_define
    pop rcx
    BOX rcx, rax, JS_OBJ_BITS
    pop rdi
    pop rsi
    pop rdx
    pop rax
    ret

; jsa_combine_finish: RAX = state -> the result settled from the values
; (any: rejected with an AggregateError of them)
jsa_combine_finish:
    push rax
    push rcx
    push rdx
    push rsi
    mov rsi, [rax + JARR_ELEMS]
    mov rdx, [rsi + 8]
    BOX rdx, rcx, JS_OBJ_BITS       ; the values
    mov rax, [rsi]                  ; the result
    cmp qword [rsi + 24], JSA_ANY
    je .aggregate
    call jsprom_resolve
    jmp .out
.aggregate:
    push rax
    push rdx
    lea rsi, [jsmsg_all_rejected]
    call jsstr_from_cstr
    mov edx, JE_ERROR
    call js_make_error
    mov rdx, rax                    ; the error
    mov eax, eax
    mov rcx, [rsp]                  ; errors
    lea rsi, [jsa_name_errors]
    push rdx
    mov edx, 1
    call jsb_define
    lea rsi, [jsa_name_aggregate]
    call jsb_cstr
    mov rcx, rax
    mov rax, [rsp]
    mov eax, eax
    mov rdx, [atom_name]
    bts rdx, 32                     ; hidden
    call jsobj_define
    pop rdx
    add rsp, 8
    pop rax
    call jsprom_reject
.out:
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ==============================================================================
; The microtask queue
; ==============================================================================

; jsev_enqueue: EAX = JOB_*, RDI, RDX, R8 = its operands -> queued
jsev_enqueue:
    push rax
    push rcx
    push rsi
    push rax
    mov ecx, 4
    call jsarr_new
    mov rsi, rax
    pop rcx
    call jsarr_push
    mov rcx, rdi
    mov rax, rsi
    call jsarr_push
    mov rcx, rdx
    mov rax, rsi
    call jsarr_push
    mov rcx, r8
    mov rax, rsi
    call jsarr_push
    mov rcx, rsi
    mov rax, [jsev_micro]
    call jsarr_push
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsev_drain: run the microtasks (and those they queue), then report
; promises rejected with nothing to handle them. Errors are printed through
; js_print_hook; an interrupted script ends it all (jsev_stop).
; ------------------------------------------------------------------------------
jsev_drain:
    cmp byte [jsev_draining], 0
    jne .ret
    mov byte [jsev_draining], 1
    push rax
    push rbx
    push rcx
.job:
    mov rbx, [jsev_micro]
    mov rax, [jsev_micro_head]
    cmp eax, [rbx + JARR_LEN]
    jae .empty
    inc qword [jsev_micro_head]
    mov rcx, [rbx + JARR_ELEMS]
    mov rax, [rcx + rax*8]
    call jsev_run_job
    jnc .job
    call js_print_error
    cmp byte [js_interrupted], 0
    je .job
    call jsev_stop
.empty:
    mov rbx, [jsev_micro]
    mov dword [rbx + JARR_LEN], 0
    mov qword [jsev_micro_head], 0
    call jsev_report_unhandled
    pop rcx
    pop rbx
    pop rax
    mov byte [jsev_draining], 0
.ret:
    ret

; jsev_run_job: RAX = job -> run (errors end it: CF=1, RAX = the exception)
jsev_run_job:
    push rbx
    lea rbx, [jsev_job_body]
    jmp js_protected

jsev_job_body:
    mov rsi, [rax + JARR_ELEMS]
    mov rax, [rsi]
    cmp eax, JOB_REACTION
    je .reaction
    cmp eax, JOB_THENABLE
    je .thenable
    ; queueMicrotask(fn)
    mov rax, [rsi + 8]
    mov rdx, JS_UNDEF
    xor ecx, ecx
    jmp js_call
.reaction:
    mov rdi, [rsi + 8]
    mov rdx, [rsi + 16]
    mov ecx, [rsi + 24]
    jmp jsev_reaction
.thenable:
    ; thenable.then(resolve, reject) for the promise
    mov rbx, [rsi + 16]             ; the thenable
    mov r9, [rsi + 24]              ; its then
    mov eax, [rsi + 8]
    call jsa_resolving_functions
    BOX rax, rcx, JS_OBJ_BITS
    BOX rdx, rcx, JS_OBJ_BITS
    push rdx
    push rdx
    push rax
    mov rdi, rsp
    mov rax, r9
    mov rdx, rbx
    mov ecx, 2
    call jsa_call_catch
    add rsp, 16
    pop rbx
    jnc .ret
    push rax                        ; it threw: reject (if not resolved yet)
    mov rdi, rsp
    mov rax, rbx
    mov rdx, JS_UNDEF
    mov ecx, 1
    call js_call
    add rsp, 8
.ret:
    ret

; jsev_reaction: RDI = reaction, RDX = the value, ECX = 1 if rejected
jsev_reaction:
    mov rsi, [rdi + JARR_ELEMS]
    cmp qword [rsi + 24], JR_AWAIT
    je .await
    mov r9, [rsi + 16]              ; the derived promise (or undefined)
    mov rax, [rsi]
    test ecx, ecx
    jz .handler
    mov rax, [rsi + 8]
.handler:
    call js_is_callable
    jnc .pass
    push rdx
    mov rdi, rsp
    mov rdx, JS_UNDEF
    mov ecx, 1
    call jsa_call_catch
    pop rdx
    mov rdx, rax
    mov ecx, 0
    jnc .settle
    mov ecx, 1                      ; the handler threw
    jmp .settle
.pass:
    ; no handler: the value or reason passes through
.settle:
    mov rax, r9
    shr rax, 48
    cmp eax, JS_TAG_OBJECT
    jne .ret
    mov eax, r9d
    test ecx, ecx
    jnz .reject
    jmp jsprom_resolve
.reject:
    jmp jsprom_reject
.await:
    mov rax, [rsi + 16]             ; the coroutine
    jmp jsco_resume
.ret:
    ret

; jsev_report_unhandled: rejected promises nobody reacted to -> "Uncaught
; (in promise) <reason>"
jsev_report_unhandled:
    push rax
    push rbx
    push rcx
    push rsi
    mov rbx, [jsev_unhandled]
    xor ecx, ecx
.promise:
    cmp ecx, [rbx + JARR_LEN]
    jae .done
    mov rax, [rbx + JARR_ELEMS]
    mov rax, [rax + rcx*8]
    inc ecx
    cmp byte [rax + JPROM_HANDLED], 0
    jne .promise
    mov byte [rax + JPROM_HANDLED], 1
    mov rax, [rax + JPROM_VALUE]
    lea rsi, [jsmsg_in_promise]
    call js_print_uncaught
    jmp .promise
.done:
    mov dword [rbx + JARR_LEN], 0
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; jsev_stop: an interrupted script: no more jobs or timers
jsev_stop:
    push rax
    mov rax, [jsev_micro]
    mov dword [rax + JARR_LEN], 0
    mov qword [jsev_micro_head], 0
    mov rax, [jsev_timers]
    mov dword [rax + JARR_LEN], 0
    mov rax, [jsev_frames]
    mov dword [rax + JARR_LEN], 0
    pop rax
    ret

; queueMicrotask(fn)
jsa_queue_microtask:
    xor eax, eax
    call jsl_callback
    push rdi
    mov rdi, rax
    mov eax, JOB_CALLBACK
    call jsev_enqueue
    pop rdi
    mov rax, JS_UNDEF
    ret

; ==============================================================================
; Timers
; ==============================================================================

; setTimeout(fn, delay, ...args) / setInterval(fn, delay, ...args) -> id
jsa_set_timeout:
    push rbx
    xor ebx, ebx
    jmp jsa_add_timer
jsa_set_interval:
    push rbx
    mov ebx, 1
jsa_add_timer:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    xor eax, eax
    call jsl_callback
    mov r8, rax                     ; the function
    ; the delay in milliseconds (0 .. 2^31 - 1)
    mov eax, 1
    call jsb_arg_integer
    test rax, rax
    jns .max
    xor eax, eax
.max:
    cmp rax, JSEV_MAX_DELAY
    jbe .delay
    mov eax, JSEV_MAX_DELAY
.delay:
    mov rdx, rax
    ; the arguments after the delay
    mov rsi, JS_UNDEF
    cmp ecx, 2
    jbe .record
    push rcx
    push rdx
    push rdi
    sub ecx, 2
    lea rdi, [rdi + 16]
    call jsa_array_of_args
    mov rsi, rax
    pop rdi
    pop rdx
    pop rcx
.record:
    test ebx, ebx
    jz .once
    mov ebx, edx                    ; interval (1 ms at least)
    test ebx, ebx
    jnz .once
    mov ebx, 1
.once:
    mov rax, r8
    call jsev_add_timer             ; RAX = fn, RDX = delay, EBX = interval, RSI = args
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsa_array_of_args: RDI = values, ECX = count -> RAX = an array of them (value)
jsa_array_of_args:
    push rcx
    push rdx
    push rdi
    push rsi
    mov edx, ecx
    call jsarr_new
    mov rsi, rax
.arg:
    test edx, edx
    jz .done
    mov rcx, [rdi]
    mov rax, rsi
    call jsarr_push
    add rdi, 8
    dec edx
    jmp .arg
.done:
    mov rax, rsi
    BOX rax, rcx, JS_OBJ_BITS
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------------------------
; jsev_add_timer: RAX = function (value), RDX = delay (ms), EBX = interval
; (ms, 0 = once), RSI = arguments array or undefined -> RAX = its id (number)
; ------------------------------------------------------------------------------
jsev_add_timer:
    push rcx
    push rdx
    push rdi
    push r8
    mov r8, rax
    mov ecx, 5
    call jsarr_new
    mov rdi, rax
    inc qword [jsev_next_id]
    mov rcx, [jsev_next_id]
    call jsarr_push                 ; TM_ID
    mov rcx, r8
    mov rax, rdi
    call jsarr_push                 ; TM_FN
    mov rcx, [timer_ticks]
    add rcx, rdx
    mov rax, rdi
    call jsarr_push                 ; TM_WHEN
    mov ecx, ebx
    mov rax, rdi
    call jsarr_push                 ; TM_INTERVAL
    mov rcx, rsi
    mov rax, rdi
    call jsarr_push                 ; TM_ARGS
    mov rcx, rdi
    mov rax, [jsev_timers]
    call jsarr_push
    mov rax, [jsev_next_id]
    call jsb_from_int
    pop r8
    pop rdi
    pop rdx
    pop rcx
    ret

; clearTimeout(id) / clearInterval(id)
jsa_clear_timer:
    push rbx
    xor eax, eax
    call jsb_arg_integer
    mov rbx, [jsev_timers]
    call jsev_remove_id
    pop rbx
    mov rax, JS_UNDEF
    ret

; jsev_remove_id: RBX = timer or frame list, RAX = id -> that entry removed
jsev_remove_id:
    push rcx
    push rdx
    push rsi
    mov rsi, [rbx + JARR_ELEMS]
    xor ecx, ecx
.find:
    cmp ecx, [rbx + JARR_LEN]
    jae .done
    mov rdx, [rsi + rcx*8]
    mov rdx, [rdx + JARR_ELEMS]
    cmp [rdx + TM_ID], rax
    je .found
    inc ecx
    jmp .find
.found:
    ; the last entry takes its place (order does not matter: the ids do)
    mov edx, [rbx + JARR_LEN]
    dec edx
    mov [rbx + JARR_LEN], edx
    mov rdx, [rsi + rdx*8]
    mov [rsi + rcx*8], rdx
.done:
    pop rsi
    pop rdx
    pop rcx
    ret

; requestAnimationFrame(callback) -> id
jsa_request_frame:
    push rcx
    push rdx
    push rsi
    xor eax, eax
    call jsl_callback
    mov rdx, rax
    mov ecx, 2
    call jsarr_new
    mov rsi, rax
    inc qword [jsev_next_id]
    mov rcx, [jsev_next_id]
    call jsarr_push
    mov rcx, rdx
    mov rax, rsi
    call jsarr_push
    mov rcx, rsi
    mov rax, [jsev_frames]
    call jsarr_push
    mov rax, [jsev_next_id]
    call jsb_from_int
    pop rsi
    pop rdx
    pop rcx
    ret

; cancelAnimationFrame(id)
jsa_cancel_frame:
    push rbx
    xor eax, eax
    call jsb_arg_integer
    mov rbx, [jsev_frames]
    call jsev_remove_id
    pop rbx
    mov rax, JS_UNDEF
    ret

; performance.now(): milliseconds since the realm started
jsa_performance_now:
    mov rax, [timer_ticks]
    sub rax, [jsev_origin]
    jmp jsb_from_int

; ==============================================================================
; The event loop
; ==============================================================================

; jsev_next_due: -> RAX = the tick the next timer or animation frame is due,
; -1 if nothing waits
jsev_next_due:
    push rbx
    push rcx
    push rdx
    mov rax, -1
    mov rbx, [jsev_timers]
    xor ecx, ecx
.timer:
    cmp ecx, [rbx + JARR_LEN]
    jae .frames
    mov rdx, [rbx + JARR_ELEMS]
    mov rdx, [rdx + rcx*8]
    mov rdx, [rdx + JARR_ELEMS]
    mov rdx, [rdx + TM_WHEN]
    cmp rdx, rax
    jae .next
    mov rax, rdx
.next:
    inc ecx
    jmp .timer
.frames:
    mov rbx, [jsev_frames]
    cmp dword [rbx + JARR_LEN], 0
    je .out
    mov rdx, [jsev_last_frame]
    add rdx, JSEV_FRAME_MS
    cmp rdx, rax
    jae .out
    mov rax, rdx
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; jsev_run_due: the timers due now (not ones they add: those wait for the next
; call), each followed by the microtasks, then the animation frame callbacks
; if one is due. Errors are printed through js_print_hook.
; ------------------------------------------------------------------------------
jsev_run_due:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov r10, [jsev_next_id]         ; timers made from now on wait
    mov r11, [timer_ticks]
.timer:
    cmp byte [js_interrupted], 0
    jne .done
    ; the due timer with the earliest time (then the lowest id)
    mov rbx, [jsev_timers]
    xor ecx, ecx
    mov r8, -1                      ; its index
.find:
    cmp ecx, [rbx + JARR_LEN]
    jae .found
    mov rdx, [rbx + JARR_ELEMS]
    mov rdx, [rdx + rcx*8]
    mov rdx, [rdx + JARR_ELEMS]
    cmp [rdx + TM_ID], r10
    ja .skip
    cmp [rdx + TM_WHEN], r11
    ja .skip
    cmp r8, -1
    je .take
    mov rax, [rdx + TM_WHEN]
    cmp rax, [r9 + TM_WHEN]
    jb .take
    ja .skip
    mov rax, [rdx + TM_ID]
    cmp rax, [r9 + TM_ID]
    jae .skip
.take:
    mov r8d, ecx
    mov r9, rdx                     ; its fields
.skip:
    inc ecx
    jmp .find
.found:
    cmp r8, -1
    je .frames
    ; an interval comes back; a timeout is done
    mov rcx, [r9 + TM_INTERVAL]
    test rcx, rcx
    jz .once
    add rcx, r11
    mov [r9 + TM_WHEN], rcx
    jmp .call
.once:
    mov rax, [r9 + TM_ID]
    call jsev_remove_id             ; RBX = the list
.call:
    mov rax, [r9 + TM_FN]
    mov rsi, [r9 + TM_ARGS]
    call jsev_call_with             ; fn(...args)
    call jsev_drain
    jmp .timer
.frames:
    mov rbx, [jsev_frames]
    cmp dword [rbx + JARR_LEN], 0
    je .done
    mov rax, r11
    sub rax, [jsev_last_frame]
    cmp rax, JSEV_FRAME_MS
    jb .done
    mov [jsev_last_frame], r11
    ; this frame's callbacks; the ones they request are for the next frame
    mov rsi, rbx
    xor ecx, ecx
    call jsarr_new
    mov [jsev_frames], rax
    mov rax, r11
    sub rax, [jsev_origin]
    call jsb_from_int
    mov rdi, rax                    ; the timestamp
    xor ecx, ecx
.frame:
    cmp ecx, [rsi + JARR_LEN]
    jae .done
    cmp byte [js_interrupted], 0
    jne .done
    mov rax, [rsi + JARR_ELEMS]
    mov rax, [rax + rcx*8]
    mov rax, [rax + JARR_ELEMS]
    mov rax, [rax + 8]              ; the callback
    push rcx
    push rsi
    push rdi
    mov rsi, rdi
    call jsev_call_one
    call jsev_drain
    pop rdi
    pop rsi
    pop rcx
    inc ecx
    jmp .frame
.done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsev_call_with: RAX = function, RSI = arguments array or undefined -> called
; (this = undefined); an error is printed
jsev_call_with:
    push rcx
    push rdx
    push rdi
    push rbp
    mov rbp, rsp
    xor ecx, ecx
    mov rdi, rsp
    mov rdx, rsi
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .call
    ; the arguments onto the kernel stack
    mov edx, esi
    mov ecx, [rdx + JARR_LEN]
    lea rdi, [rcx*8 + 8]
    sub rsp, rdi
    and rsp, -16
    mov rdi, rsp
    push rax
    xor eax, eax
.arg:
    cmp eax, ecx
    jae .args
    mov rsi, [rdx + JARR_ELEMS]
    mov rsi, [rsi + rax*8]
    mov [rdi + rax*8], rsi
    inc eax
    jmp .arg
.args:
    pop rax
.call:
    mov rdx, JS_UNDEF
    call js_call_safe
    jnc .out
    call js_print_error
.out:
    mov rsp, rbp
    pop rbp
    pop rdi
    pop rdx
    pop rcx
    ret

; jsev_call_one: RAX = function, RSI = its one argument -> called; an error
; is printed
jsev_call_one:
    push rcx
    push rdx
    push rdi
    push rsi
    mov rdi, rsp
    mov rdx, JS_UNDEF
    mov ecx, 1
    call js_call_safe
    jnc .out
    call js_print_error
.out:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------------------------
; jsev_loop: the `js` command after its script: microtasks, then wait for
; and run timers until none are left (Esc / Ctrl+C stops waiting)
; ------------------------------------------------------------------------------
jsev_loop:
    push rax
    call jsev_drain
.next:
    cmp byte [js_interrupted], 0
    jne .stop
    call jsev_next_due
    cmp rax, -1
    je .done
    cmp [timer_ticks], rax
    jae .run
    call con_idle
    call con_check_cancel
    jc .stop
    hlt
    jmp .next
.run:
    call jsev_run_due
    jmp .next
.stop:
    call jsev_stop
.done:
    pop rax
    ret

; ==============================================================================
; Async functions: coroutines
; ==============================================================================

; jsco_new: -> RAX = a coroutine (raw) with a new pending promise
jsco_new:
    push rcx
    push rdx
    mov ecx, JCO_SIZE
    call js_alloc
    mov byte [rax + JH_KIND], JK_CORO
    mov rdx, rax
    call jsprom_new
    BOX rax, rcx, JS_OBJ_BITS
    mov [rdx + JCO_PROMISE], rax
    mov rax, rdx
    pop rdx
    pop rcx
    ret

; jsco_drop_handlers: RDX = frame -> the try handlers made in it removed
jsco_drop_handlers:
    push rax
    push rcx
    mov ecx, [vm_handler_count]
.handler:
    test ecx, ecx
    jz .done
    lea eax, [ecx - 1]
    imul eax, eax, JTH_SIZE
    lea rax, [vm_handlers + rax]
    cmp [rax + JTH_FP], rdx
    jne .done
    dec ecx
    jmp .handler
.done:
    mov [vm_handler_count], ecx
    pop rcx
    pop rax
    ret

; jsco_finish: (interpreter) RAX = the value an async function returns ->
; its promise resolves with it; RAX = the promise
jsco_finish:
    push rbx
    push rdx
    mov rdx, [vm_fp]
    mov rbx, [rdx + JFR_CORO]
    call jsco_drop_handlers
    mov rdx, rax
    mov eax, [rbx + JCO_PROMISE]
    call jsprom_resolve
    mov rax, [rbx + JCO_PROMISE]
    pop rdx
    pop rbx
    ret

; jsco_reject: (interpreter) RAX = what an async function threw -> its
; promise rejects with it; RAX = the promise
jsco_reject:
    push rbx
    push rdx
    mov rdx, [vm_fp]
    mov rbx, [rdx + JFR_CORO]
    call jsco_drop_handlers
    mov rdx, rax
    mov eax, [rbx + JCO_PROMISE]
    call jsprom_reject
    mov rax, [rbx + JCO_PROMISE]
    pop rdx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; jsco_suspend: (interpreter, at an await) RAX = the awaited value -> the frame
; (its stack slots [f][this][locals...] up to R12, its try handlers, RSI /
; R14 / R15 / line) saved in its coroutine, which waits for the value;
; RAX = the function's promise, for the caller
; ------------------------------------------------------------------------------
jsco_suspend:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r10, rax
    mov rdx, [vm_fp]
    mov rbx, [rdx + JFR_CORO]
    mov [rbx + JCO_PC], rsi
    mov [rbx + JCO_ENV], r14
    mov [rbx + JCO_FUNC], r15
    mov eax, [vm_line]
    mov [rbx + JCO_LINE], eax
    ; the value stack slots
    mov rcx, r12
    lea rsi, [r13 - 16]
    sub rcx, rsi
    shr rcx, 3
    mov [rbx + JCO_SLOTS], ecx
    push rcx
    shl ecx, 3
    call js_alloc
    pop rcx
    mov [rbx + JCO_STACK], rax
    mov rdi, rax
    rep movsq
    ; the try handlers made in this frame (on top of the handler stack)
    mov ecx, [vm_handler_count]
    xor r9d, r9d
.count:
    test ecx, ecx
    jz .counted
    lea eax, [ecx - 1]
    imul eax, eax, JTH_SIZE
    lea rax, [vm_handlers + rax]
    cmp [rax + JTH_FP], rdx
    jne .counted
    inc r9d
    dec ecx
    jmp .count
.counted:
    mov [rbx + JCO_NHANDLERS], r9d
    test r9d, r9d
    jz .wait
    mov [vm_handler_count], ecx     ; (they leave the stack)
    push rcx
    imul ecx, r9d, JTH_SIZE
    call js_alloc
    pop rcx
    mov [rbx + JCO_HANDLERS], rax
    imul esi, ecx, JTH_SIZE
    lea rsi, [vm_handlers + rsi]
    mov rdi, rax
    imul ecx, r9d, JTH_SIZE / 8
    rep movsq
    ; their stack tops relative to the frame
    mov rdi, rax
    lea r8, [r13 - 16]
.relative:
    sub [rdi + JTH_SP], r8
    add rdi, JTH_SIZE
    dec r9d
    jnz .relative
.wait:
    ; resume when the value settles
    mov rax, r10
    call jsa_promise_of
    xor ecx, ecx
    xor r8d, r8d
    mov r9, rbx
    push r11
    mov r11d, JR_AWAIT
    call jsprom_then
    pop r11
    mov rax, [rbx + JCO_PROMISE]
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; jsco_resume: RAX = coroutine, RDX = the value, ECX = 1 to throw it -> the
; async function continues after its await (on a new frame whose return
; leaves this vm_run) until it awaits again or ends
; ------------------------------------------------------------------------------
jsco_resume:
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
    mov rbx, rax
    mov r10, rdx
    mov r11d, ecx
    inc dword [vm_nesting]
    cmp dword [vm_nesting], JSVM_MAX_NESTING
    ja vm_stack_overflow
    push qword [vm_sp]
    mov r12, [vm_sp]
    mov ecx, [rbx + JCO_SLOTS]
    lea rax, [r12 + rcx*8 + 32768]
    cmp rax, JS_STACK_ADDR + JS_STACK_SIZE
    jae vm_stack_overflow
    mov rdx, [vm_fp]
    add rdx, JFR_SIZE
    cmp rdx, JS_FRAMES_ADDR + JS_FRAMES_SIZE - JFR_SIZE
    jae vm_stack_overflow
    ; the slots back on the stack
    mov r9, r12                     ; [f][this]...
    mov rsi, [rbx + JCO_STACK]
    mov rdi, r12
    rep movsq
    mov r12, rdi
    ; a frame whose return leaves this vm_run
    mov [vm_fp], rdx
    mov [rdx + JFR_PC], rsi
    mov [rdx + JFR_BASE], r13
    mov [rdx + JFR_FUNC], r15
    mov [rdx + JFR_ENV], r14
    mov [rdx + JFR_RESULT], r9
    mov dword [rdx + JFR_FLAGS], JFRF_BOUNDARY | JFRF_ASYNC
    mov eax, [vm_line]
    mov [rdx + JFR_LINE], eax
    mov [rdx + JFR_CORO], rbx
    lea r13, [r9 + 16]
    mov r14, [rbx + JCO_ENV]
    mov r15, [rbx + JCO_FUNC]
    mov eax, [rbx + JCO_LINE]
    mov [vm_line], eax
    ; its try handlers back, for this frame and this vm_run
    lea r8, [rsp - 16]              ; RSP inside vm_run (after its call and push)
    mov ecx, [rbx + JCO_NHANDLERS]
    mov rsi, [rbx + JCO_HANDLERS]
.handler:
    test ecx, ecx
    jz .value
    mov eax, [vm_handler_count]
    cmp eax, JSVM_MAX_HANDLERS
    jae .value
    imul eax, eax, JTH_SIZE
    lea rdi, [vm_handlers + rax]
    push rcx
    mov ecx, JTH_SIZE / 8
    rep movsq
    pop rcx
    sub rdi, JTH_SIZE
    add [rdi + JTH_SP], r9
    mov [rdi + JTH_BASE], r13
    mov [rdi + JTH_FP], rdx
    mov [rdi + JTH_RSP], r8
    mov eax, [vm_nesting]
    mov [rdi + JTH_NEST], eax
    mov eax, [js_depth]
    mov [rdi + JTH_DEPTH], eax
    inc dword [vm_handler_count]
    dec ecx
    jmp .handler
.value:
    mov rsi, [rbx + JCO_PC]
    PUSHV r10
    test r11d, r11d
    jz .run
    lea rsi, [jsco_throw_code]      ; the reason is thrown at the await
.run:
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
