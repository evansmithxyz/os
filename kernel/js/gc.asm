; ==============================================================================
; Antigravity OS - JavaScript garbage collector
; ------------------------------------------------------------------------------
; js_alloc hands out blocks of the JS heap (JS_HEAP_ADDR). Each block has an
; 8-byte header in front (payload size, flags) and a bit in the start bitmap
; (JS_GC_BITMAP_ADDR, one bit per 8 heap bytes) where its header begins.
;
; jsgc_collect is a mark-sweep collector that never moves anything. Marking is
; conservative: the roots (the kernel stack with the registers pushed on it,
; the JS value stack, call frames, the kernel .bss and the DOM nodes' pointers
; into the heap) and the contents of every block reached are read as 8-byte
; words, and a word that is a string / object value or a raw pointer into the
; heap keeps the block it points to. Roots may point inside a block (a string's
; bytes); heap words must point at a block's start. Strings are not looked
; into (GCF_LEAF). Atoms and compiled code are permanent (GCF_PERM).
;
; The sweep joins neighbouring dead blocks into free blocks, kept in lists by
; size (8 .. 256 bytes) and one first-fit list for the bigger ones; a dead run
; at the top of the heap goes back to the bump space. A collection runs when
; as many bytes as were live after the last one (8 MB at least) have been
; handed out, or when the heap is full. Compiling turns it off (jsgc_off).
; ==============================================================================

[bits 64]

GCH_SIZE                equ 0           ; dword: payload bytes (a multiple of 8)
GCH_FLAGS               equ 4           ; byte: GCF_*
GCF_MARK                equ 1
GCF_PERM                equ 2           ; never freed (atoms, compiled code)
GCF_FREE                equ 4
GCF_LEAF                equ 8           ; holds no pointers (strings)
JSGC_CLASSES            equ 32          ; exact-size free lists for 8 .. 256 bytes
JSGC_MIN_THRESHOLD      equ 0x00800000  ; 8 MB between collections at least

section .rodata
klog_js_gc:             db "js gc: live bytes 0x", 0

section .bss
alignb 8
jsgc_free:              resq JSGC_CLASSES       ; free blocks of each small size
jsgc_large:             resq 1          ; free blocks over 256 bytes
jsgc_allocated:         resq 1          ; bytes handed out since the last collection
jsgc_threshold:         resq 1
jsgc_live:              resq 1          ; bytes live after the last collection
jsgc_count:             resq 1          ; collections so far (this realm)
jsgc_sp:                resq 1          ; mark stack top
jsgc_vm_top:            resq 1          ; value stack top while collecting
jsgc_off:               resd 1          ; > 0: no collections (compiling)
jsgc_busy:              resb 1
jsgc_overflow:          resb 1          ; the mark stack ran over: rescan

section .text

; ------------------------------------------------------------------------------
; jsgc_reset: an empty heap (from js_heap_reset, before it resets js_heap_ptr)
; ------------------------------------------------------------------------------
jsgc_reset:
    push rax
    push rcx
    push rdi
    ; the start bits in use (all of the bitmap the first time)
    mov rcx, [js_heap_ptr]
    test rcx, rcx
    jnz .used
    mov ecx, JS_GC_BITMAP_SIZE / 8
    jmp .clear
.used:
    sub rcx, JS_HEAP_ADDR
    shr rcx, 6                      ; bitmap bytes
    add rcx, 8
    shr rcx, 3                      ; qwords
.clear:
    mov rdi, JS_GC_BITMAP_ADDR
    xor eax, eax
    rep stosq
    lea rdi, [jsgc_free]
    mov ecx, JSGC_CLASSES + 1
    rep stosq                       ; (and jsgc_large)
    mov [jsgc_allocated], rax
    mov [jsgc_live], rax
    mov [jsgc_count], rax
    mov [jsgc_off], eax
    mov [jsgc_busy], al
    mov qword [jsgc_threshold], JSGC_MIN_THRESHOLD
    pop rdi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; js_alloc: ECX = bytes -> RAX = a new zeroed block (8-aligned). Collects
; first when it is time; RangeError "out of memory" if nothing is left.
; js_alloc_perm: the same, never freed
; ------------------------------------------------------------------------------
js_alloc_perm:
    call js_alloc
    or byte [rax - 8 + GCH_FLAGS], GCF_PERM
    ret

js_alloc:
    push rcx
    push rdx
    push rdi
    add ecx, 7
    and ecx, ~7
    jnz .sized
    mov ecx, 8
.sized:
    mov rax, [jsgc_allocated]
    cmp rax, [jsgc_threshold]
    jb .take
    call jsgc_collect
.take:
    call jsgc_take
    test rax, rax
    jnz .got
    call jsgc_collect               ; the heap is full: collect and try again
    call jsgc_take
    test rax, rax
    jz .full
.got:
    add [jsgc_allocated], rcx
    mov rdx, rax
    mov rdi, rax
    shr ecx, 3
    xor eax, eax
    rep stosq
    mov rax, rdx
    pop rdi
    pop rdx
    pop rcx
    ret
.full:
    mov edx, JE_RANGE
    lea rsi, [jsmsg_out_of_memory]
    xor edi, edi
    jmp js_throw

; jsgc_take: ECX = payload bytes -> RAX = a block (header written, not
; zeroed), 0 if the heap has no room
jsgc_take:
    push rbx
    push rdx
    push rsi
    cmp ecx, JSGC_CLASSES * 8
    ja .large
    mov edx, ecx
    shr edx, 3
    mov rax, [jsgc_free + rdx*8 - 8]
    test rax, rax
    jz .large
    mov rbx, [rax]
    mov [jsgc_free + rdx*8 - 8], rbx
    mov byte [rax - 8 + GCH_FLAGS], 0
    jmp .out
.large:
    ; the first big enough free block
    lea rsi, [jsgc_large]           ; the link to it
.scan:
    mov rax, [rsi]
    test rax, rax
    jz .bump
    cmp [rax - 8 + GCH_SIZE], ecx
    jae .fit
    mov rsi, rax                    ; (a free block's first qword is its link)
    jmp .scan
.fit:
    mov rbx, [rax]
    mov [rsi], rbx
    mov byte [rax - 8 + GCH_FLAGS], 0
    call jsgc_split
    jmp .out
.bump:
    mov rax, [js_heap_ptr]
    lea rbx, [rax + rcx + 8]
    cmp rbx, [js_heap_end]
    ja .none
    mov [js_heap_ptr], rbx
    mov [rax + GCH_SIZE], ecx
    mov dword [rax + GCH_FLAGS], 0
    call jsgc_set_bit
    add rax, 8
    jmp .out
.none:
    xor eax, eax
.out:
    pop rsi
    pop rdx
    pop rbx
    ret

; jsgc_split: RAX = a block taken from the free lists, ECX = bytes wanted ->
; what it has beyond them (16 bytes or more) becomes a free block of its own
jsgc_split:
    push rbx
    push rdx
    mov edx, [rax - 8 + GCH_SIZE]
    sub edx, ecx
    cmp edx, 16
    jb .whole
    mov [rax - 8 + GCH_SIZE], ecx
    lea rbx, [rax + rcx]            ; the rest's header
    sub edx, 8
    mov [rbx + GCH_SIZE], edx
    mov dword [rbx + GCH_FLAGS], 0
    push rax
    mov rax, rbx
    call jsgc_set_bit
    lea rax, [rbx + 8]
    call jsgc_free_block
    pop rax
.whole:
    pop rdx
    pop rbx
    ret

; jsgc_free_block: RAX = block (its size set) -> on its free list
jsgc_free_block:
    push rcx
    push rdx
    mov byte [rax - 8 + GCH_FLAGS], GCF_FREE
    mov ecx, [rax - 8 + GCH_SIZE]
    cmp ecx, JSGC_CLASSES * 8
    ja .large
    shr ecx, 3
    mov rdx, [jsgc_free + rcx*8 - 8]
    mov [rax], rdx
    mov [jsgc_free + rcx*8 - 8], rax
    jmp .out
.large:
    mov rdx, [jsgc_large]
    mov [rax], rdx
    mov [jsgc_large], rax
.out:
    pop rdx
    pop rcx
    ret

; jsgc_set_bit / jsgc_clear_bit: RAX = a block header -> its start bit
jsgc_set_bit:
    push rax
    push rdx
    lea rdx, [rax - JS_HEAP_ADDR]
    shr rdx, 3
    mov rax, JS_GC_BITMAP_ADDR
    bts [rax], rdx
    pop rdx
    pop rax
    ret
jsgc_clear_bit:
    push rax
    push rdx
    lea rdx, [rax - JS_HEAP_ADDR]
    shr rdx, 3
    mov rax, JS_GC_BITMAP_ADDR
    btr [rax], rdx
    pop rdx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsgc_collect: a full collection (unless compiling or already collecting)
; ------------------------------------------------------------------------------
jsgc_collect:
    cmp dword [jsgc_off], 0
    jne .skip
    cmp byte [jsgc_busy], 0
    jne .skip
    mov byte [jsgc_busy], 1
    ; every register goes on the stack, which is scanned
    push rax
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
    ; the value stack's top: vm_sp, or R12 inside the interpreter
    mov rax, [vm_sp]
    cmp rax, JS_STACK_ADDR
    jb .no_sp
    cmp rax, JS_STACK_ADDR + JS_STACK_SIZE
    jbe .sp
.no_sp:
    mov eax, JS_STACK_ADDR
.sp:
    cmp r12, JS_STACK_ADDR
    jb .top
    cmp r12, JS_STACK_ADDR + JS_STACK_SIZE
    ja .top
    cmp r12, rax
    jbe .top
    mov rax, r12
.top:
    mov [jsgc_vm_top], rax
    call jsgc_mark
    call jsgc_sweep
    ; the next one after as many bytes as are live now (8 MB at least)
    mov rax, [jsgc_live]
    cmp rax, JSGC_MIN_THRESHOLD
    jae .threshold
    mov eax, JSGC_MIN_THRESHOLD
.threshold:
    mov [jsgc_threshold], rax
    mov qword [jsgc_allocated], 0
    inc qword [jsgc_count]
    mov rax, [jsgc_live]
    lea rsi, [klog_js_gc]
    call klog_hex
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
    pop rax
    mov byte [jsgc_busy], 0
.skip:
    ret

; ------------------------------------------------------------------------------
; jsgc_mark: mark everything the roots reach
; ------------------------------------------------------------------------------
jsgc_mark:
    mov qword [jsgc_sp], JS_GC_STACK_ADDR
    mov byte [jsgc_overflow], 0
    mov dl, 1                       ; roots may point inside blocks
    ; the kernel stack
    mov rsi, rsp
    mov rdi, KERNEL_STACK_TOP
    call jsgc_scan
    ; the value stack
    mov rsi, JS_STACK_ADDR
    mov rdi, [jsgc_vm_top]
    call jsgc_scan
    ; call frames
    mov rsi, JS_FRAMES_ADDR
    mov rdi, [vm_fp]
    add rdi, JFR_SIZE
    cmp rdi, JS_FRAMES_ADDR + JS_FRAMES_SIZE
    jbe .frames
    mov rdi, JS_FRAMES_ADDR
.frames:
    call jsgc_scan
    ; the kernel's variables
    lea rsi, [bss_start]
    lea rdi, [bss_end]
    and rdi, ~7
    call jsgc_scan
    call jsgc_dom_roots
    call jsgc_drain
.overflow:
    ; blocks the full mark stack dropped: scan every marked block again
    cmp byte [jsgc_overflow], 0
    je .done
    mov byte [jsgc_overflow], 0
    mov rbx, JS_HEAP_ADDR
.block:
    cmp rbx, [js_heap_ptr]
    jae .overflow
    mov al, [rbx + GCH_FLAGS]
    and al, GCF_MARK | GCF_LEAF
    cmp al, GCF_MARK
    jne .next
    lea rsi, [rbx + 8]
    mov edi, [rbx + GCH_SIZE]
    add rdi, rsi
    xor edx, edx
    call jsgc_scan
    push rbx
    call jsgc_drain
    pop rbx
.next:
    mov eax, [rbx + GCH_SIZE]
    lea rbx, [rbx + rax + 8]
    jmp .block
.done:
    ret

; jsgc_dom_roots: the DOM nodes' pointers into the heap (text and attributes
; JavaScript gave them, their JavaScript objects)
jsgc_dom_roots:
    mov rbx, DOM_ADDR
    mov ecx, [dom_count]
    mov dl, 1
.node:
    test ecx, ecx
    jz .done
    mov rax, [rbx + N_NAME]
    call jsgc_consider
    mov rax, [rbx + N_ATTRS]
    call jsgc_consider
    mov rax, [rbx + N_STYLE]
    call jsgc_consider
    mov eax, [rbx + N_JSOBJ]
    call jsgc_consider
    add rbx, DOM_NODE_SIZE
    dec ecx
    jmp .node
.done:
    ret

; jsgc_drain: scan the blocks on the mark stack (which may push more)
jsgc_drain:
    mov rbx, [jsgc_sp]
    cmp rbx, JS_GC_STACK_ADDR
    jbe .done
    sub rbx, 8
    mov [jsgc_sp], rbx
    mov rbx, [rbx]                  ; a header
    lea rsi, [rbx + 8]
    mov edi, [rbx + GCH_SIZE]
    add rdi, rsi
    xor edx, edx                    ; only block starts
    call jsgc_scan
    jmp jsgc_drain
.done:
    ret

; jsgc_scan: RSI = start, RDI = end (8-aligned), DL = 1 to accept pointers
; inside blocks -> every word that may point into the heap considered
jsgc_scan:
    push rax
    push rsi
.word:
    cmp rsi, rdi
    jae .done
    mov rax, [rsi]
    add rsi, 8
    call jsgc_consider
    jmp .word
.done:
    pop rsi
    pop rax
    ret

; jsgc_consider: RAX = a word, DL = 1 inside blocks too -> the block it
; points to marked (and queued to be scanned)
jsgc_consider:
    push rax
    push rcx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_STRING
    je .pointer
    cmp ecx, JS_TAG_OBJECT
    je .pointer
    mov rcx, rax
    shr rcx, 35                     ; raw pointers (property keys: + attributes)
    jnz .out
.pointer:
    mov eax, eax
    cmp rax, JS_HEAP_ADDR + 8
    jb .out
    cmp rax, [js_heap_ptr]
    jae .out
    call jsgc_mark_address
.out:
    pop rcx
    pop rax
    ret

; jsgc_mark_address: RAX = an address in the heap, DL = 1 inside blocks too
jsgc_mark_address:
    push rax
    push rbx
    push rcx
    test dl, dl
    jnz .inside
    test al, 7
    jnz .out
    lea rbx, [rax - 8]              ; the header, if a block starts here
    lea rcx, [rbx - JS_HEAP_ADDR]
    shr rcx, 3
    mov rax, JS_GC_BITMAP_ADDR
    bt [rax], rcx
    jnc .out
    jmp .block
.inside:
    call jsgc_find_block
    jc .out
.block:
    mov al, [rbx + GCH_FLAGS]
    test al, GCF_MARK | GCF_PERM | GCF_FREE
    jnz .out
    or byte [rbx + GCH_FLAGS], GCF_MARK
    test al, GCF_LEAF
    jnz .out
    mov rcx, [jsgc_sp]
    cmp rcx, JS_GC_STACK_ADDR + JS_GC_STACK_SIZE
    jae .overflow
    mov [rcx], rbx
    add qword [jsgc_sp], 8
    jmp .out
.overflow:
    mov byte [jsgc_overflow], 1
.out:
    pop rcx
    pop rbx
    pop rax
    ret

; jsgc_find_block: RAX = an address in the heap -> RBX = the header of the
; block holding it, CF=1 if none does
jsgc_find_block:
    push rax
    push rcx
    push rdx
    push rsi
    mov rsi, JS_GC_BITMAP_ADDR
    sub rax, JS_HEAP_ADDR
    shr rax, 3                      ; its 8-byte unit
    mov ecx, eax
    and ecx, 63
    shr rax, 6                      ; the bitmap qword
    mov edx, 2
    shl rdx, cl
    dec rdx                         ; that unit and the ones before it
    and rdx, [rsi + rax*8]
    jnz .found
.back:
    dec rax
    js .none
    mov rdx, [rsi + rax*8]
    test rdx, rdx
    jz .back
.found:
    bsr rdx, rdx
    shl rax, 6
    add rax, rdx
    shl rax, 3
    add rax, JS_HEAP_ADDR
    mov rbx, rax
    mov ecx, [rbx + GCH_SIZE]
    lea rcx, [rbx + rcx + 8]        ; the block's end
    cmp [rsp + 24], rcx
    jae .none
    pop rsi
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.none:
    pop rsi
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; jsgc_sweep: unmarked blocks freed (runs of them joined), marks cleared,
; jsgc_live counted
; ------------------------------------------------------------------------------
jsgc_sweep:
    lea rdi, [jsgc_free]
    mov ecx, JSGC_CLASSES + 1
    xor eax, eax
    rep stosq                       ; the lists are made again (and jsgc_large)
    xor r8d, r8d                    ; live bytes
    mov rbx, JS_HEAP_ADDR
.block:
    cmp rbx, [js_heap_ptr]
    jae .done
    mov al, [rbx + GCH_FLAGS]
    test al, GCF_MARK | GCF_PERM
    jz .dead
    and byte [rbx + GCH_FLAGS], ~GCF_MARK
    mov ecx, [rbx + GCH_SIZE]
    lea r8, [r8 + rcx + 8]
    lea rbx, [rbx + rcx + 8]
    jmp .block
.dead:
    ; this block and the dead ones after it: one free block
    mov rsi, rbx
.extend:
    mov ecx, [rbx + GCH_SIZE]
    lea rbx, [rbx + rcx + 8]
    cmp rbx, [js_heap_ptr]
    jae .top
    test byte [rbx + GCH_FLAGS], GCF_MARK | GCF_PERM
    jnz .run_end
    mov rax, rbx
    call jsgc_clear_bit             ; swallowed
    jmp .extend
.top:
    ; the run reaches the top: back to the bump space
    mov rax, rsi
    call jsgc_clear_bit
    mov [js_heap_ptr], rsi
    jmp .done
.run_end:
    mov rcx, rbx
    sub rcx, rsi
    sub rcx, 8
    mov [rsi + GCH_SIZE], ecx
    lea rax, [rsi + 8]
    call jsgc_free_block
    jmp .block
.done:
    mov [jsgc_live], r8
    ret
