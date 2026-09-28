; ==============================================================================
; Antigravity OS - JavaScript: Map, Set, WeakMap, WeakSet
; ------------------------------------------------------------------------------
; A Map keeps its entries in insertion order in one array, key and value side
; by side (a deleted entry's key becomes JS_HOLE and stays, so iterators that
; are running go on correctly), and a hash table of dwords (entry number + 1,
; 0 = empty, linear probing) that grows as the entries do. Keys compare with
; SameValueZero: strings by their text, numbers by value (NaN is NaN, -0 is
; 0), everything else by identity. A Set is a Map whose values are its keys.
; WeakMap / WeakSet are the same with object keys only (not weak: nothing is
; freed while the collection lives).
; ==============================================================================

[bits 64]

JMAP_ENTRIES            equ 32          ; raw array: key, value, key, value ...
JMAP_COUNT              equ 40          ; dword: live entries
JMAP_TCAP               equ 44          ; dword: hash table slots (a power of two)
JMAP_TABLE              equ 48          ; raw: the hash table
JMAP_SIZE               equ 56

section .bss
alignb 8
jscol_map_proto:        resq 1
jscol_map_ctor:         resq 1
jscol_set_proto:        resq 1
jscol_set_ctor:         resq 1
jscol_weakmap_proto:    resq 1
jscol_weakmap_ctor:     resq 1
jscol_weakset_proto:    resq 1
jscol_weakset_ctor:     resq 1

section .rodata
jscol_ctors:
JSCTOR jscol_map_ctor, jscol_map, 0, jscol_map_proto, "Map"
JSCTOR jscol_set_ctor, jscol_set, 0, jscol_set_proto, "Set"
JSCTOR jscol_weakmap_ctor, jscol_weakmap, 0, jscol_weakmap_proto, "WeakMap"
JSCTOR jscol_weakset_ctor, jscol_weakset, 0, jscol_weakset_proto, "WeakSet"
    dq 0

jscol_natives:
JSNATIVE jscol_map_proto, "get", jscol_get, 1
JSNATIVE jscol_map_proto, "set", jscol_set_entry, 2
JSNATIVE jscol_map_proto, "has", jscol_has, 1
JSNATIVE jscol_map_proto, "delete", jscol_delete, 1
JSNATIVE jscol_map_proto, "clear", jscol_clear, 0
JSNATIVE jscol_map_proto, "forEach", jscol_for_each, 1
JSNATIVE jscol_map_proto, "keys", jscol_keys, 0
JSNATIVE jscol_map_proto, "values", jscol_values, 0
JSNATIVE jscol_map_proto, "entries", jscol_entries, 0
JSNATIVE jscol_set_proto, "add", jscol_add, 1
JSNATIVE jscol_set_proto, "has", jscol_has, 1
JSNATIVE jscol_set_proto, "delete", jscol_delete, 1
JSNATIVE jscol_set_proto, "clear", jscol_clear, 0
JSNATIVE jscol_set_proto, "forEach", jscol_for_each, 1
JSNATIVE jscol_set_proto, "values", jscol_values, 0
JSNATIVE jscol_set_proto, "keys", jscol_values, 0
JSNATIVE jscol_set_proto, "entries", jscol_entries, 0
JSNATIVE jscol_weakmap_proto, "get", jscol_get, 1
JSNATIVE jscol_weakmap_proto, "set", jscol_set_entry, 2
JSNATIVE jscol_weakmap_proto, "has", jscol_has, 1
JSNATIVE jscol_weakmap_proto, "delete", jscol_delete, 1
JSNATIVE jscol_weakset_proto, "add", jscol_add, 1
JSNATIVE jscol_weakset_proto, "has", jscol_has, 1
JSNATIVE jscol_weakset_proto, "delete", jscol_delete, 1
    dq 0

jscol_str_size:         db "size", 0
jsmsg_col_new:          db "Constructor % requires 'new'", 0
jsmsg_col_receiver:     db "Method % called on incompatible receiver", 0
jsmsg_weak_key:         db "Invalid value used as weak map key", 0
jsmsg_entry:            db "Iterator value % is not an entry object", 0
jscol_name_map:         db "Map", 0
jscol_name_set:         db "Set", 0

section .text

; ------------------------------------------------------------------------------
; jscol_init: Map, Set, WeakMap, WeakSet (js_init_builtins, after jsy_init)
; ------------------------------------------------------------------------------
jscol_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov rbx, [js_object_proto]
    mov rax, rbx
    call jsobj_new
    mov [jscol_map_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [jscol_set_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [jscol_weakmap_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [jscol_weakset_proto], rax
    lea r8, [jscol_ctors]
    call jsb_define_ctors
    lea r8, [jscol_natives]
    call jsb_define_natives
    ; size (a getter) on Map and Set
    lea rsi, [jscol_str_size]
    call jsstr_from_cstr
    mov rdx, rax
    bts rdx, 32
    lea rax, [jscol_size]
    call jsy_native0
    mov rcx, rax
    mov r8d, 1
    mov rax, [jscol_map_proto]
    call jsobj_define_accessor
    mov rax, [jscol_set_proto]
    call jsobj_define_accessor
    ; [Symbol.iterator]: entries for Map, values for Set
    mov rax, [jscol_map_proto]
    lea rcx, [jscol_entries]
    call jsy_define_iterator_method
    mov rax, [jscol_set_proto]
    lea rcx, [jscol_values]
    call jsy_define_iterator_method
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; The table
; ==============================================================================

; jscol_new: RAX = prototype, ECX = JC_MAP / JC_SET -> RAX = an empty one (raw)
jscol_new:
    push rcx
    push rdx
    mov rdx, rax
    push rcx
    mov ecx, JMAP_SIZE
    call js_alloc
    pop rcx
    mov byte [rax + JH_KIND], JK_OBJECT
    mov [rax + JOBJ_CLASS], ecx
    mov [rax + JOBJ_PROTO], rdx
    call jscol_reset
    pop rdx
    pop rcx
    ret

; jscol_reset: RAX = map (raw) -> empty (a new entry array and table)
jscol_reset:
    push rax
    push rbx
    push rcx
    mov rbx, rax
    mov ecx, 8
    call jsarr_new
    mov [rbx + JMAP_ENTRIES], rax
    mov dword [rbx + JMAP_COUNT], 0
    mov dword [rbx + JMAP_TCAP], 16
    mov ecx, 16 * 4
    call js_alloc
    or byte [rax - 8 + GCH_FLAGS], GCF_LEAF
    mov [rbx + JMAP_TABLE], rax
    pop rcx
    pop rbx
    pop rax
    ret

; jscol_hash: RAX = key -> RAX = the key as stored (-0 as 0, one NaN),
; EDX = its hash
jscol_hash:
    push rcx
    push rsi
    push r8
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_SPECIAL
    jb .number
    cmp ecx, JS_TAG_STRING
    jne .bits
    ; a string: its text
    mov esi, eax
    mov ecx, [rsi + JSTR_LEN]
    add rsi, JSTR_DATA
    mov edx, 2166136261             ; FNV-1a
.byte:
    test ecx, ecx
    jz .out
    movzx r8d, byte [rsi]
    xor edx, r8d
    imul edx, edx, 16777619
    inc rsi
    dec ecx
    jmp .byte
.number:
    mov rcx, 0x8000000000000000
    cmp rax, rcx
    jne .nan
    xor eax, eax                    ; -0 -> 0
.nan:
    mov rcx, rax
    btr rcx, 63
    mov rsi, JS_INF
    cmp rcx, rsi
    jbe .bits
    mov rax, JS_NAN                 ; one NaN
.bits:
    mov rdx, rax
    shr rdx, 32
    xor edx, eax
    imul edx, edx, -1640531535       ; (0x9E3779B1)
    mov ecx, edx
    shr ecx, 15
    xor edx, ecx
.out:
    pop r8
    pop rsi
    pop rcx
    ret

; jscol_same: RAX, RDX = keys (as stored) -> CF=1 if the same (SameValueZero)
jscol_same:
    cmp rax, rdx
    je .yes
    push rcx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_STRING
    jne .no
    mov rcx, rdx
    shr rcx, 48
    cmp ecx, JS_TAG_STRING
    jne .no
    pop rcx
    push rax
    push rdx
    mov eax, eax
    mov edx, edx
    call jsstr_equal
    pop rdx
    pop rax
    ret
.no:
    pop rcx
    clc
    ret
.yes:
    stc
    ret

; ------------------------------------------------------------------------------
; jscol_find: RBX = map (raw), RAX = key -> ECX = its entry number, CF=0
; if it is there; else CF=1 and ECX = the free slot for it in the table.
; RAX = the key as stored.
; ------------------------------------------------------------------------------
jscol_find:
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    call jscol_hash
    mov r8d, [rbx + JMAP_TCAP]
    dec r8d                         ; the mask
    mov rdi, [rbx + JMAP_TABLE]
    mov r9, [rbx + JMAP_ENTRIES]
    mov r9, [r9 + JARR_ELEMS]
    mov ecx, edx
.probe:
    and ecx, r8d
    mov esi, [rdi + rcx*4]
    test esi, esi
    jz .missing
    dec esi
    push rdx
    mov rdx, rsi
    shl rdx, 4
    mov rdx, [r9 + rdx]             ; its key
    call jscol_same
    pop rdx
    jc .found
    inc ecx
    jmp .probe
.found:
    mov ecx, esi
    clc
    jmp .out
.missing:
    stc
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    ret

; jscol_insert: RBX = map, RAX = key (as stored), RCX = value -> a new entry
jscol_insert:
    push rax
    push rcx
    push rdx
    push rsi
    ; room in the table: at most half full (deleted entries count)
    mov rdx, [rbx + JMAP_ENTRIES]
    mov edx, [rdx + JARR_LEN]
    shr edx, 1                      ; entries so far
    inc edx
    shl edx, 1
    cmp edx, [rbx + JMAP_TCAP]
    jb .room
    call jscol_grow
.room:
    mov rsi, rcx
    mov rdx, [rbx + JMAP_ENTRIES]
    mov edx, [rdx + JARR_LEN]
    shr edx, 1                      ; the new entry's number
    push rdx
    push rax
    mov rcx, rax
    mov rax, [rbx + JMAP_ENTRIES]
    call jsarr_push
    mov rcx, rsi
    call jsarr_push
    pop rax
    call jscol_find                 ; ECX = the slot
    pop rdx
    inc edx
    mov rsi, [rbx + JMAP_TABLE]
    mov [rsi + rcx*4], edx
    inc dword [rbx + JMAP_COUNT]
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jscol_grow: RBX = map -> a table twice as big, made again from the entries
jscol_grow:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov ecx, [rbx + JMAP_TCAP]
    add ecx, ecx
    mov [rbx + JMAP_TCAP], ecx
    shl ecx, 2
    call js_alloc
    or byte [rax - 8 + GCH_FLAGS], GCF_LEAF
    mov [rbx + JMAP_TABLE], rax
    mov rdi, [rbx + JMAP_ENTRIES]
    mov esi, [rdi + JARR_LEN]
    shr esi, 1
    xor edx, edx                    ; entry number
.entry:
    cmp edx, esi
    jae .done
    mov rax, [rdi + JARR_ELEMS]
    mov r8, rdx
    shl r8, 4
    mov rax, [rax + r8]
    mov rcx, JS_HOLE
    cmp rax, rcx
    je .next
    call jscol_find
    mov rax, [rbx + JMAP_TABLE]
    lea r8d, [edx + 1]
    mov [rax + rcx*4], r8d
.next:
    inc edx
    jmp .entry
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ==============================================================================
; Constructors and methods
; ==============================================================================

; new Map(entries) / new Set(values) / new WeakMap / new WeakSet
jscol_map:
    push rbx
    push rcx
    mov rbx, [jscol_map_proto]
    mov ecx, JC_MAP
    jmp jscol_construct
jscol_set:
    push rbx
    push rcx
    mov rbx, [jscol_set_proto]
    mov ecx, JC_SET
    jmp jscol_construct
jscol_weakmap:
    push rbx
    push rcx
    mov rbx, [jscol_weakmap_proto]
    mov ecx, JC_WEAKMAP
    jmp jscol_construct
jscol_weakset:
    push rbx
    push rcx
    mov rbx, [jscol_weakset_proto]
    mov ecx, JC_WEAKSET
jscol_construct:
    push rdx
    push rsi
    push rdi
    push r8
    test r8d, r8d
    jz .not_new
    ; the prototype `new` gave this (subclasses), else the default
    mov rax, rdx
    shr rax, 48
    cmp eax, JS_TAG_OBJECT
    jne .proto
    mov eax, edx
    mov rbx, [rax + JOBJ_PROTO]
.proto:
    mov rax, rbx
    call jscol_new
    mov rbx, rax
    ; the initial items
    mov ecx, [rsp + 32]             ; (the argument count)
    xor eax, eax
    call jsb_arg
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    jne .items
    cmp eax, 1
    jbe .done                       ; undefined / null
.items:
    push rax
    xor ecx, ecx
    call jsarr_new
    mov rsi, rax
    pop rdx
    call jsit_collect
    xor ecx, ecx
.item:
    cmp ecx, [rsi + JARR_LEN]
    jae .done
    mov rax, [rsi + JARR_ELEMS]
    mov rax, [rax + rcx*8]
    push rcx
    cmp dword [rbx + JOBJ_CLASS], JC_SET
    je .value
    cmp dword [rbx + JOBJ_CLASS], JC_WEAKSET
    je .value
    ; a [key, value] entry
    call jscol_entry
    jmp .put
.value:
    mov rcx, rax
.put:
    call jscol_put
    pop rcx
    inc ecx
    jmp .item
.done:
    mov rax, rbx
    BOX rax, rcx, JS_OBJ_BITS
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.not_new:
    lea rsi, [jscol_name_map]
    call jsstr_from_cstr
    mov rdi, rax
    lea rsi, [jsmsg_col_new]
    jmp js_throw_type

; jscol_entry: RAX = an entry ([key, value]) -> RAX = key, RCX = value
jscol_entry:
    push rdx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .bad
    push rax
    mov rdx, 0x3FF0000000000000     ; 1
    call js_get_elem
    mov rcx, rax
    pop rax
    xor edx, edx                    ; 0
    call js_get_elem
    pop rdx
    ret
.bad:
    call js_to_string_safe
    mov rdi, rax
    lea rsi, [jsmsg_entry]
    jmp js_throw_type

; jscol_put: RBX = map, RAX = key, RCX = value -> set (weak ones: object
; keys only)
jscol_put:
    push rax
    push rcx
    push rdx
    push rsi
    cmp dword [rbx + JOBJ_CLASS], JC_WEAKMAP
    jb .key
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .bad_key
.key:
    mov rsi, rcx
    call jscol_find
    setc dl                         ; (not there)
    cmp dword [rbx + JOBJ_CLASS], JC_SET
    je .same
    cmp dword [rbx + JOBJ_CLASS], JC_WEAKSET
    jne .found
.same:
    mov rsi, rax                    ; a set's value is its key (-0 as 0)
.found:
    test dl, dl
    jnz .new
    mov rdx, [rbx + JMAP_ENTRIES]
    mov rdx, [rdx + JARR_ELEMS]
    shl rcx, 4
    mov [rdx + rcx + 8], rsi
    jmp .out
.new:
    mov rcx, rsi
    call jscol_insert
.out:
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
.bad_key:
    lea rsi, [jsmsg_weak_key]
    xor edi, edi
    jmp js_throw_type

; jscol_this: RDX = this -> RBX = the collection (raw); TypeError otherwise
jscol_this:
    mov rbx, rdx
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    jne .bad
    mov ebx, edx
    cmp byte [rbx + JH_KIND], JK_OBJECT
    jne .bad
    cmp dword [rbx + JOBJ_CLASS], JC_MAP
    jb .bad
    cmp dword [rbx + JOBJ_CLASS], JC_WEAKSET
    ja .bad
    ret
.bad:
    lea rsi, [jscol_name_map]
    call jsstr_from_cstr
    mov rdi, rax
    lea rsi, [jsmsg_col_receiver]
    jmp js_throw_type

; map.get(key)
jscol_get:
    push rbx
    push rcx
    push rdx
    call jscol_this
    xor eax, eax
    call jsb_arg
    call jscol_find
    mov rax, JS_UNDEF
    jc .out
    mov rax, [rbx + JMAP_ENTRIES]
    mov rax, [rax + JARR_ELEMS]
    shl rcx, 4
    mov rax, [rax + rcx + 8]
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

; map.set(key, value) -> the map
jscol_set_entry:
    push rbx
    push rcx
    call jscol_this
    xor eax, eax
    call jsb_arg
    push rax
    mov eax, 1
    call jsb_arg
    mov rcx, rax
    pop rax
    call jscol_put
    mov rax, rdx
    pop rcx
    pop rbx
    ret

; set.add(value) -> the set
jscol_add:
    push rbx
    push rcx
    call jscol_this
    xor eax, eax
    call jsb_arg
    mov rcx, rax
    call jscol_put
    mov rax, rdx
    pop rcx
    pop rbx
    ret

; map.has(key) / set.has(value)
jscol_has:
    push rbx
    push rcx
    call jscol_this
    xor eax, eax
    call jsb_arg
    call jscol_find
    cmc
    call js_bool
    pop rcx
    pop rbx
    ret

; map.delete(key) -> whether it was there
jscol_delete:
    push rbx
    push rcx
    push rdx
    call jscol_this
    xor eax, eax
    call jsb_arg
    call jscol_find
    jc .no
    mov rax, [rbx + JMAP_ENTRIES]
    mov rax, [rax + JARR_ELEMS]
    shl rcx, 4
    mov rdx, JS_HOLE
    mov [rax + rcx], rdx
    mov rdx, JS_UNDEF
    mov [rax + rcx + 8], rdx
    dec dword [rbx + JMAP_COUNT]
    stc
    jmp .out
.no:
    clc
.out:
    call js_bool
    pop rdx
    pop rcx
    pop rbx
    ret

; map.clear()
jscol_clear:
    push rbx
    call jscol_this
    mov rax, rbx
    call jscol_reset
    mov rax, JS_UNDEF
    pop rbx
    ret

; map.size
jscol_size:
    push rbx
    call jscol_this
    mov eax, [rbx + JMAP_COUNT]
    call jsb_from_int
    pop rbx
    ret

; map.forEach(callback, thisArg): callback(value, key, map) for each entry,
; including those added meanwhile
jscol_for_each:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    call jscol_this
    mov eax, 1
    call jsb_arg
    mov r9, rax                     ; thisArg
    xor eax, eax
    call jsl_callback
    mov rsi, rax
    mov r8, rdx                     ; the map (value)
    xor ecx, ecx
.entry:
    mov rax, [rbx + JMAP_ENTRIES]
    mov edx, [rax + JARR_LEN]
    shr edx, 1
    cmp ecx, edx
    jae .done
    mov rax, [rax + JARR_ELEMS]
    mov rdi, rcx
    shl rdi, 4
    add rdi, rax                    ; the entry
    mov rdx, JS_HOLE
    cmp [rdi], rdx
    je .next
    push rcx
    push r8                         ; (map)
    push qword [rdi]                ; key
    push qword [rdi + 8]            ; value
    mov rdi, rsp
    mov rax, rsi
    mov rdx, r9
    mov ecx, 3
    call js_call
    add rsp, 24
    pop rcx
.next:
    inc ecx
    jmp .entry
.done:
    mov rax, JS_UNDEF
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; map.keys() / values() / entries() (set.values() and keys() are the same)
jscol_keys:
    push rcx
    mov ecx, ITK_MAP_KEYS
    jmp jscol_iterator
jscol_values:
    push rcx
    mov ecx, ITK_MAP_VALUES
    jmp jscol_iterator
jscol_entries:
    push rcx
    mov ecx, ITK_MAP_ENTRIES
jscol_iterator:
    push rbx
    call jscol_this
    mov rax, rdx
    call jsit_new
    pop rbx
    pop rcx
    ret

; ------------------------------------------------------------------------------
; jscol_iter_step: RBX = a Map / Set iterator -> RAX = the next key, value or
; [key, value], CF=1 at the end (jsit_step_raw)
; ------------------------------------------------------------------------------
jscol_iter_step:
    push rcx
    push rdx
    push rsi
    mov esi, [rbx + JIO_SRC]        ; the map
    mov ecx, [rbx + JIO_POS]
.entry:
    mov rax, [rsi + JMAP_ENTRIES]
    mov edx, [rax + JARR_LEN]
    shr edx, 1
    cmp ecx, edx
    jae .end
    mov rax, [rax + JARR_ELEMS]
    mov rdx, rcx
    shl rdx, 4
    add rax, rdx                    ; the entry
    mov rdx, JS_HOLE
    cmp [rax], rdx
    jne .found
    inc ecx
    jmp .entry
.found:
    lea edx, [ecx + 1]
    mov [rbx + JIO_POS], edx
    mov rdx, [rax + 8]              ; value
    mov rax, [rax]                  ; key
    cmp dword [rbx + JIO_KIND], ITK_MAP_KEYS
    je .yes
    cmp dword [rbx + JIO_KIND], ITK_MAP_VALUES
    je .value
    call jsit_pair
    jmp .yes
.value:
    mov rax, rdx
.yes:
    pop rsi
    pop rdx
    pop rcx
    clc
    ret
.end:
    mov [rbx + JIO_POS], ecx
    pop rsi
    pop rdx
    pop rcx
    stc
    ret

; ------------------------------------------------------------------------------
; jscol_inspect: RDI = a Map or Set -> "Map(2) { 'a' => 1 }" / "Set(1) { 1 }"
; in jsout_buf (console.log); ECX = depth
; ------------------------------------------------------------------------------
jscol_inspect:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov r8d, ecx
    inc r8d
    lea rsi, [jscol_name_map]
    cmp dword [rdi + JOBJ_CLASS], JC_MAP
    je .name
    lea rsi, [jscol_name_set]
.name:
    call jsout_cstr
    mov al, '('
    call jsout_byte
    mov eax, [rdi + JMAP_COUNT]
    call jsout_u64
    mov al, ')'
    call jsout_byte
    mov al, ' '
    call jsout_byte
    mov al, '{'
    call jsout_byte
    xor ebx, ebx                    ; items so far
    xor esi, esi                    ; entry number
.entry:
    mov rax, [rdi + JMAP_ENTRIES]
    mov edx, [rax + JARR_LEN]
    shr edx, 1
    cmp esi, edx
    jae .close
    mov rax, [rax + JARR_ELEMS]
    mov rcx, rsi
    shl rcx, 4
    add rax, rcx                    ; the entry
    mov rdx, JS_HOLE
    cmp [rax], rdx
    je .next
    push rax
    mov al, ','
    test ebx, ebx
    jz .first
    call jsout_byte
.first:
    mov al, ' '
    call jsout_byte
    pop rax
    inc ebx
    push rax
    mov rax, [rax]
    mov ecx, r8d
    mov edx, 1
    call jsi_value
    pop rax
    cmp dword [rdi + JOBJ_CLASS], JC_MAP
    jne .next
    push rax
    mov al, ' '
    call jsout_byte
    mov al, '='
    call jsout_byte
    mov al, '>'
    call jsout_byte
    mov al, ' '
    call jsout_byte
    pop rax
    mov rax, [rax + 8]
    mov ecx, r8d
    mov edx, 1
    call jsi_value
.next:
    inc esi
    jmp .entry
.close:
    test ebx, ebx
    jz .brace
    mov al, ' '
    call jsout_byte
.brace:
    mov al, '}'
    call jsout_byte
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
