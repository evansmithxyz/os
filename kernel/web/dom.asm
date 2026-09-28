; ==============================================================================
; Antigravity OS - HTML parser: page text -> DOM tree
; ------------------------------------------------------------------------------
; dom_build turns browser_page_buf into a tree of nodes at DOM_ADDR. Node 0 is
; the document; every other node is an element or a text node. Nodes point
; back into the page buffer for their tag name, text and attributes, so the
; page must not change while the tree is in use.
;
; Tree building follows the parts of the HTML rules that matter for display:
;   - void elements (br, img, input, meta, link, ...) have no children
;   - script, style, title, textarea keep their content as one text node
;   - a block element closes an open <p>; <li>, <dt>/<dd>, <td>/<th>, <tr>,
;     <tbody>... and <option> close the previous one of their kind
;   - a close tag closes the nearest open element with that name (and
;     everything inside it); a close tag nothing matches is ignored
; Each element's id and class names are hashed (dom_hash) for CSS matching.
; ==============================================================================

[bits 64]

DOM_NODE_SIZE           equ 128
DOM_MAX_NODES           equ DOM_SIZE / DOM_NODE_SIZE

NODE_ELEMENT            equ 1
NODE_TEXT               equ 2

; node record
N_TYPE                  equ 0       ; db NODE_*
N_TAG                   equ 1       ; db TAGID_* (0 = not in the tag table)
N_NCLS                  equ 2       ; db number of class hashes
N_FLAGS                 equ 3       ; db NF_*
NF_COMMENT              equ 1       ; a text node that is a comment (its text is the comment's)
NF_FRAGMENT             equ 2       ; an element that is a DocumentFragment
N_PARENT                equ 4       ; dd node index (the document is 0)
N_FIRST                 equ 8       ; dd first child, 0 = none
N_LAST                  equ 12      ; dd last child
N_NEXT                  equ 16      ; dd next sibling, 0 = none
N_NAME_LEN              equ 20      ; dd
N_NAME                  equ 24      ; dq tag name (element) or text (text node)
N_ATTRS                 equ 32      ; dq attribute text (between name and '>')
N_ATTRS_LEN             equ 40      ; dd
N_TAGH                  equ 44      ; dd hash of the tag name
N_IDH                   equ 48      ; dd hash of the id, 0 = none
N_CLSH                  equ 52      ; 6 x dd class hashes
DOM_MAX_CLASSES         equ 6
N_STYLE_LEN             equ 76      ; dd style="" text
N_STYLE                 equ 80      ; dq
; 88-117: computed style, filled in by css.asm (S_*)
N_JSOBJ                 equ 120     ; dd the node's JavaScript object (kernel/js/jsdom.asm), 0 = none

; tag table flags
TF_VOID                 equ 0x01    ; no content, no close tag
TF_RAW                  equ 0x02    ; content is text up to </name>
TF_BLOCK                equ 0x04    ; closes an open <p>

; tag ids (order of dom_tags)
TAGID_HTML              equ 1
TAGID_HEAD              equ 2
TAGID_BODY              equ 3
TAGID_P                 equ 4
TAGID_LI                equ 5
TAGID_DT                equ 6
TAGID_DD                equ 7
TAGID_TD                equ 8
TAGID_TH                equ 9
TAGID_TR                equ 10
TAGID_THEAD             equ 11
TAGID_TBODY             equ 12
TAGID_TFOOT             equ 13
TAGID_OPTION            equ 14
TAGID_UL                equ 15
TAGID_OL                equ 16
TAGID_DL                equ 17
TAGID_TABLE             equ 18
TAGID_SELECT            equ 19
TAGID_A                 equ 20
TAGID_BR                equ 21
TAGID_IMG               equ 22
TAGID_HR                equ 23
TAGID_INPUT             equ 24
TAGID_STYLE             equ 25
TAGID_LINK              equ 26
TAGID_SCRIPT            equ 27
TAGID_TITLE             equ 28
TAGID_PRE               equ 29
TAGID_TEXTAREA          equ 30
TAGID_BUTTON            equ 31
TAGID_OTHER_VOID        equ 32      ; meta, base, area, col, embed, source, track, wbr, param
TAGID_OTHER_BLOCK       equ 33      ; div, h1-h6, section, ... (closes <p>)
TAGID_OTHER_RAW         equ 34      ; xmp, noembed, ...
TAGID_DETAILS           equ 35
TAGID_SUMMARY           equ 36

section .data
align 4
dom_count:              dd 0        ; nodes in use (node 0 is the document)

section .bss
alignb 8
dom_current:            resd 1      ; the element new nodes go into
dom_text_start:         resq 1      ; start of pending text, 0 = none
dom_tag_start:          resq 1
dom_attr_end:           resq 1
dom_self_closing:       resb 1
alignb 4
dom_root:               resd 1      ; parsing stays inside this element (0 = whole document)

section .text
; ------------------------------------------------------------------------------
; dom_node: EAX = node index -> RBX = its record
; ------------------------------------------------------------------------------
dom_node:
    push rax
    shl rax, 7                      ; * DOM_NODE_SIZE (upper bits of RAX are 0)
    lea rbx, [abs DOM_ADDR]
    add rbx, rax
    pop rax
    ret

; ------------------------------------------------------------------------------
; dom_hash: RSI = name, ECX = length -> EAX = FNV-1a hash of it in lower case
; (never 0)
; ------------------------------------------------------------------------------
dom_hash:
    push rcx
    push rdx
    push rsi
    mov eax, 0x811C9DC5
    test ecx, ecx
    jz .done
.byte:
    movzx edx, byte [rsi]
    cmp dl, 'A'
    jb .mix
    cmp dl, 'Z'
    ja .mix
    or dl, 0x20
.mix:
    xor eax, edx
    imul eax, eax, 0x01000193
    inc rsi
    dec ecx
    jnz .byte
.done:
    test eax, eax
    jnz .ret
    inc eax
.ret:
    pop rsi
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------------------------
; dom_new: -> EAX = a new zeroed node's index, RBX = its record; CF=1 if the
; DOM is full
; ------------------------------------------------------------------------------
dom_new:
    push rcx
    push rdi
    mov eax, [dom_count]
    cmp eax, DOM_MAX_NODES
    jae .full
    inc dword [dom_count]
    call dom_node
    push rax
    mov rdi, rbx
    xor eax, eax
    mov ecx, DOM_NODE_SIZE / 8
    rep stosq
    pop rax
    pop rdi
    pop rcx
    clc
    ret
.full:
    pop rdi
    pop rcx
    stc
    ret

; ------------------------------------------------------------------------------
; dom_append: EAX = new node -> child of dom_current (parent / sibling links)
; ------------------------------------------------------------------------------
dom_append:
    push rbx
    push rcx
    push rdx
    mov edx, eax                    ; EDX = child
    call dom_node
    mov ecx, [dom_current]
    mov [rbx + N_PARENT], ecx
    mov eax, ecx
    call dom_node                   ; RBX = parent
    mov ecx, [rbx + N_LAST]
    mov [rbx + N_LAST], edx
    test ecx, ecx
    jnz .sibling
    mov [rbx + N_FIRST], edx
    jmp .done
.sibling:
    mov eax, ecx
    call dom_node
    mov [rbx + N_NEXT], edx
.done:
    mov eax, edx
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; dom_flush_text: pending text (dom_text_start .. RSI) -> a text node
; ------------------------------------------------------------------------------
dom_flush_text:
    push rax
    push rbx
    push rcx
    mov rcx, [dom_text_start]
    test rcx, rcx
    jz .done
    mov qword [dom_text_start], 0
    mov rax, rsi
    sub rax, rcx
    jz .done
    push rcx
    push rax
    call dom_new
    pop rcx                         ; length
    pop rax                         ; start
    jc .done
    mov [rbx + N_NAME], rax
    mov [rbx + N_NAME_LEN], ecx
    mov byte [rbx + N_TYPE], NODE_TEXT
    mov rax, rbx                    ; index from the record
    sub rax, DOM_ADDR
    shr rax, 7
    call dom_append
.done:
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; dom_build: browser_page_buf -> DOM. browser_page_plain pages become one
; <pre> with the text in it.
; ------------------------------------------------------------------------------
dom_build:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    mov dword [dom_count], 0
    mov qword [dom_text_start], 0
    call dom_new                    ; node 0: the document
    mov byte [rbx + N_TYPE], NODE_ELEMENT
    mov dword [dom_current], 0

    mov dword [dom_root], 0
    lea r12, [abs browser_page_buf]
    cmp byte [browser_page_plain], 0
    je .html
    ; plain text: <pre>text</pre>
    call dom_new
    jc .done
    mov byte [rbx + N_TYPE], NODE_ELEMENT
    mov byte [rbx + N_TAG], TAGID_PRE
    lea rsi, [dom_pre_name]
    mov [rbx + N_NAME], rsi
    mov dword [rbx + N_NAME_LEN], 3
    lea rsi, [dom_no_attrs]
    mov [rbx + N_ATTRS], rsi
    mov ecx, 3
    call dom_hash
    mov [rbx + N_TAGH], eax
    mov rax, rbx
    sub rax, DOM_ADDR
    shr rax, 7
    call dom_append
    mov [dom_current], eax
    mov [dom_text_start], r12
    mov rsi, r12
    call strlen
    add rsi, rax
    call dom_flush_text
    jmp .done
.html:
    call dom_parse
.done:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; dom_parse: R12 = NUL-terminated HTML -> its nodes appended to dom_current
; (tags never close anything outside dom_root). The text must stay in memory
; while the nodes exist.
; ------------------------------------------------------------------------------
dom_parse:
    push rax
    push rsi
    push r12
.loop:
    mov al, [r12]
    test al, al
    jz .end
    cmp al, '<'
    je .maybe_tag
.text:
    cmp qword [dom_text_start], 0
    jne .next
    mov [dom_text_start], r12
.next:
    inc r12
    jmp .loop
.maybe_tag:
    ; a tag starts with a letter, '/', '!' or '?'; anything else is text
    mov al, [r12 + 1]
    cmp al, '!'
    je .tag
    cmp al, '?'
    je .tag
    cmp al, '/'
    je .tag
    or al, 0x20
    cmp al, 'a'
    jb .text
    cmp al, 'z'
    ja .text
.tag:
    mov rsi, r12
    call dom_flush_text
    inc r12
    call dom_tag
    jmp .loop
.end:
    mov rsi, r12
    call dom_flush_text
    pop r12
    pop rsi
    pop rax
    ret

; ------------------------------------------------------------------------------
; dom_parse_into: RSI = NUL-terminated HTML (kept while the nodes exist),
; EAX = element -> the parsed nodes appended to its children
; ------------------------------------------------------------------------------
dom_parse_into:
    push rax
    push r12
    push qword [dom_current]
    push qword [dom_root]
    mov [dom_current], eax
    mov [dom_root], eax
    mov qword [dom_text_start], 0
    mov r12, rsi
    call dom_parse
    pop rax
    mov [dom_root], eax
    pop rax
    mov [dom_current], eax
    pop r12
    pop rax
    ret

; ------------------------------------------------------------------------------
; dom_tag: R12 = just after '<' -> past the tag (and a raw element's content)
; ------------------------------------------------------------------------------
dom_tag:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    ; comments, <!DOCTYPE>, <?xml?>
    cmp byte [r12], '!'
    jne .not_bang
    cmp word [r12 + 1], '--'
    jne .skip_to_gt
    add r12, 3
    ; a comment node: never drawn, but scripts see it (React's markers)
    mov rsi, r12                    ; its text
.comment:
    mov al, [r12]
    test al, al
    jz .done
    inc r12
    cmp al, '-'
    jne .comment
    cmp word [r12], '->'
    jne .comment
    lea rcx, [r12 - 1]
    sub rcx, rsi                    ; its length
    add r12, 2
    call dom_new
    jc .done
    mov [rbx + N_NAME], rsi
    mov [rbx + N_NAME_LEN], ecx
    mov byte [rbx + N_TYPE], NODE_TEXT
    mov byte [rbx + N_FLAGS], NF_COMMENT
    call dom_append
    jmp .done
.not_bang:
    cmp byte [r12], '?'
    je .skip_to_gt

    xor r8d, r8d                    ; R8 = 1 for a close tag
    cmp byte [r12], '/'
    jne .name
    inc r8d
    inc r12
.name:
    mov rsi, r12                    ; RSI = name
.name_char:
    mov al, [r12]
    cmp al, '>'
    je .name_end
    cmp al, '/'
    je .name_end
    cmp al, ' '
    jbe .name_end
    test al, al
    jz .name_end
    inc r12
    jmp .name_char
.name_end:
    mov rcx, r12
    sub rcx, rsi                    ; ECX = name length
    jz .skip_to_gt
    call dom_hash
    mov edx, eax                    ; EDX = tag hash
    call dom_tag_lookup             ; AL = tag id, AH = flags
    test r8d, r8d
    jnz .close

    ; --- open tag -----------------------------------------------------------
    push r9
    movzx r9d, ax                   ; R9B = tag id, bits 8-15 = flags
    call dom_implicit_close         ; AL = tag id
    call dom_new
    jc .full
    mov byte [rbx + N_TYPE], NODE_ELEMENT
    mov [rbx + N_TAG], r9b
    mov [rbx + N_NAME], rsi
    mov [rbx + N_NAME_LEN], ecx
    mov [rbx + N_TAGH], edx
    call dom_attributes             ; R12 -> past '>'
    call dom_append                 ; EAX = the new element
    mov edi, eax
    mov eax, r9d
    pop r9
    test ah, TF_VOID
    jnz .done
    cmp byte [dom_self_closing], 0
    jne .done
    test ah, TF_RAW
    jnz .raw
    mov [dom_current], edi
    jmp .done
.raw:
    ; the content up to </name> becomes one text child
    push qword [dom_current]
    mov [dom_current], edi
    mov [dom_text_start], r12
    call dom_find_close             ; RSI = start of "</name", R12 past it
    call dom_flush_text
    pop rax
    mov [dom_current], eax
    jmp .done
.full:
    pop r9
    jmp .skip_to_gt

    ; --- close tag ----------------------------------------------------------
.close:
    ; the nearest open element with this name, then its parent
    mov eax, [dom_current]
.find_open:
    cmp eax, [dom_root]
    je .skip_to_gt                  ; nothing open matches: ignore it
    call dom_node
    cmp [rbx + N_TAGH], edx
    je .found_open
    mov eax, [rbx + N_PARENT]
    jmp .find_open
.found_open:
    mov eax, [rbx + N_PARENT]
    mov [dom_current], eax
.skip_to_gt:
    mov al, [r12]
    test al, al
    jz .done
    inc r12
    cmp al, '>'
    jne .skip_to_gt
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; dom_find_close: R12 = inside a raw element named at [RBX..] (tag hash in
; EDX) -> RSI = start of its "</name", R12 = after the closing '>'
; ------------------------------------------------------------------------------
dom_find_close:
    push rax
    push rcx
    push rdx
    push rdi
    mov rdi, [rbx + N_NAME]
    mov ecx, [rbx + N_NAME_LEN]
.scan:
    mov al, [r12]
    test al, al
    jz .eof
    cmp al, '<'
    jne .next
    cmp byte [r12 + 1], '/'
    jne .next
    ; compare the name, case-insensitively
    push rcx
    xor eax, eax
.cmp:
    cmp eax, ecx
    jae .cmp_done
    mov dl, [r12 + rax + 2]
    or dl, 0x20
    mov dh, [rdi + rax]
    or dh, 0x20
    cmp dl, dh
    jne .cmp_fail
    inc eax
    jmp .cmp
.cmp_fail:
    pop rcx
.next:
    inc r12
    jmp .scan
.cmp_done:
    pop rcx
    mov rsi, r12
.to_gt:
    mov al, [r12]
    test al, al
    jz .out
    inc r12
    cmp al, '>'
    jne .to_gt
    jmp .out
.eof:
    mov rsi, r12
.out:
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; dom_attributes: RBX = element, R12 = after its name -> R12 past '>'.
; Records the attribute text, the id and class hashes and style="".
; ------------------------------------------------------------------------------
dom_attributes:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov byte [dom_self_closing], 0
    mov [rbx + N_ATTRS], r12
.next:
    mov al, [r12]
    test al, al
    jz .end
    cmp al, '>'
    je .end
    cmp al, '/'
    jne .not_slash
    cmp byte [r12 + 1], '>'
    jne .skip
    mov byte [dom_self_closing], 1
    jmp .skip
.not_slash:
    cmp al, ' '
    jbe .skip
    ; name
    mov rdi, r12
.name_char:
    mov al, [r12]
    cmp al, '='
    je .name_end
    cmp al, '>'
    je .name_end
    cmp al, ' '
    jbe .name_end
    inc r12
    jmp .name_char
.name_end:
    mov rcx, r12
    sub rcx, rdi                    ; RDI, ECX = attribute name
    call dom_skip_spaces
    cmp byte [r12], '='
    jne .next
    inc r12
    call dom_skip_spaces
    call dom_attr_value             ; RSI, EDX = value
    ; the ones we keep
    cmp ecx, 2
    jne .not_id
    mov ax, [rdi]
    or ax, 0x2020
    cmp ax, 'id'
    jne .next
    push rcx
    mov ecx, edx
    call dom_hash
    mov [rbx + N_IDH], eax
    pop rcx
    jmp .next
.not_id:
    cmp ecx, 5
    jne .next
    mov eax, [rdi]
    or eax, 0x20202020
    cmp eax, 'clas'
    jne .not_class
    mov al, [rdi + 4]
    or al, 0x20
    cmp al, 's'
    jne .next
    call dom_classes
    jmp .next
.not_class:
    cmp eax, 'styl'
    jne .next
    mov al, [rdi + 4]
    or al, 0x20
    cmp al, 'e'
    jne .next
    mov [rbx + N_STYLE], rsi
    mov [rbx + N_STYLE_LEN], edx
    jmp .next
.skip:
    inc r12
    jmp .next
.end:
    mov rax, r12
    sub rax, [rbx + N_ATTRS]
    mov [rbx + N_ATTRS_LEN], eax
    cmp byte [r12], '>'
    jne .out
    inc r12
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; dom_skip_spaces: R12 past spaces and control characters
dom_skip_spaces:
    cmp byte [r12], 0
    je .ret
    cmp byte [r12], ' '
    ja .ret
    inc r12
    jmp dom_skip_spaces
.ret:
    ret

; dom_attr_value: R12 = at a value -> RSI = value, EDX = its length, R12 past it
dom_attr_value:
    push rax
    push rbx
    mov al, [r12]
    cmp al, '"'
    je .quoted
    cmp al, "'"
    je .quoted
    mov rsi, r12
.bare:
    mov al, [r12]
    cmp al, '>'
    je .end
    cmp al, ' '
    jbe .end
    inc r12
    jmp .bare
.quoted:
    inc r12
    mov rsi, r12
.in_quote:
    mov bl, [r12]
    test bl, bl
    jz .end
    cmp bl, al
    je .close
    inc r12
    jmp .in_quote
.close:
    mov rdx, r12
    sub rdx, rsi
    inc r12
    pop rbx
    pop rax
    ret
.end:
    mov rdx, r12
    sub rdx, rsi
    pop rbx
    pop rax
    ret

; dom_classes: RSI = class attribute, EDX = length -> N_CLSH / N_NCLS of RBX
dom_classes:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    lea rdi, [rsi + rdx]            ; RDI = end
.skip:
    cmp rsi, rdi
    jae .done
    cmp byte [rsi], ' '
    ja .word
    inc rsi
    jmp .skip
.word:
    mov rdx, rsi
.word_char:
    cmp rsi, rdi
    jae .word_end
    cmp byte [rsi], ' '
    jbe .word_end
    inc rsi
    jmp .word_char
.word_end:
    movzx eax, byte [rbx + N_NCLS]
    cmp eax, DOM_MAX_CLASSES
    jae .done
    mov rcx, rsi
    sub rcx, rdx
    push rsi
    mov rsi, rdx
    push rax
    call dom_hash
    mov ecx, eax
    pop rax
    pop rsi
    mov [rbx + N_CLSH + rax * 4], ecx
    inc byte [rbx + N_NCLS]
    jmp .skip
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; dom_tag_lookup: EDX = tag hash, RSI/ECX = name -> AL = tag id, AH = flags
; ------------------------------------------------------------------------------
dom_tag_lookup:
    push rsi
    push rdi
    lea rdi, [dom_tags]
.entry:
    mov eax, [rdi]
    test eax, eax
    jz .unknown
    cmp eax, edx
    je .found
    add rdi, 8
    jmp .entry
.found:
    mov ax, [rdi + 4]
    pop rdi
    pop rsi
    ret
.unknown:
    xor eax, eax
    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------------------------
; dom_implicit_close: AL = id of the element about to open -> dom_current
; moved out of the elements it closes
; ------------------------------------------------------------------------------
dom_implicit_close:
    push rax
    push rbx
    push rcx
    push rdx
    mov dl, al                      ; DL = new tag
    ; anything but head content ends an open <head> (<body> may be missing)
    mov ecx, 0xFFFF                 ; CL, CH = tags that stop the search (none)
    cmp dl, TAGID_TITLE
    je .head_ok
    cmp dl, TAGID_STYLE
    je .head_ok
    cmp dl, TAGID_SCRIPT
    je .head_ok
    cmp dl, TAGID_LINK
    je .head_ok
    cmp dl, TAGID_OTHER_VOID        ; meta, base
    je .head_ok
    cmp dl, TAGID_HTML
    je .head_ok
    cmp dl, TAGID_HEAD
    je .head_ok
    mov dh, TAGID_HEAD
    call .close
.head_ok:
    ; which open tags it closes, and where the search stops
    mov dh, 0                       ; DH = tag to close (0 = none)
    cmp dl, TAGID_LI
    jne .not_li
    mov dh, TAGID_LI
    mov cl, TAGID_UL
    mov ch, TAGID_OL
    jmp .close_one
.not_li:
    cmp dl, TAGID_DT
    je .dl_item
    cmp dl, TAGID_DD
    jne .not_dl_item
.dl_item:
    mov dh, TAGID_DT
    mov cl, TAGID_DL
    call .close
    mov dh, TAGID_DD
    jmp .close_one
.not_dl_item:
    cmp dl, TAGID_TD
    je .cell
    cmp dl, TAGID_TH
    jne .not_cell
.cell:
    mov dh, TAGID_TD
    mov cl, TAGID_TR
    mov ch, TAGID_TABLE
    call .close
    mov dh, TAGID_TH
    jmp .close_one
.not_cell:
    cmp dl, TAGID_TR
    jne .not_row
    mov cl, TAGID_TABLE
    mov ch, TAGID_TBODY
    mov dh, TAGID_TD
    call .close
    mov dh, TAGID_TH
    call .close
    mov dh, TAGID_TR
    jmp .close_one
.not_row:
    cmp dl, TAGID_THEAD
    jb .not_section
    cmp dl, TAGID_TFOOT
    ja .not_section
    mov cl, TAGID_TABLE
    mov dh, TAGID_TR
    call .close
    mov dh, TAGID_THEAD
    call .close
    mov dh, TAGID_TBODY
    call .close
    mov dh, TAGID_TFOOT
    jmp .close_one
.not_section:
    cmp dl, TAGID_OPTION
    jne .not_option
    mov dh, TAGID_OPTION
    mov cl, TAGID_SELECT
    jmp .close_one
.not_option:
    ; a block closes an open <p> (only the innermost few levels are searched)
    movzx eax, dl
    test eax, eax
    jz .done
    lea rbx, [dom_tag_flags]
    test byte [rbx + rax], TF_BLOCK
    jz .done
    mov dh, TAGID_P
    mov cl, TAGID_TD
    mov ch, TAGID_TABLE
.close_one:
    call .close
.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
; .close: close the nearest open DH element, unless CL/CH or the document
; comes first
.close:
    push rax
    push rbx
    mov eax, [dom_current]
.up:
    cmp eax, [dom_root]
    je .close_done
    call dom_node
    mov bl, [rbx + N_TAG]
    cmp bl, dh
    je .close_it
    cmp bl, cl
    je .close_done
    cmp bl, ch
    je .close_done
    call dom_node
    mov eax, [rbx + N_PARENT]
    jmp .up
.close_it:
    call dom_node
    mov eax, [rbx + N_PARENT]
    mov [dom_current], eax
.close_done:
    pop rbx
    pop rax
    ret

; ==============================================================================
; Changing the tree (JavaScript, kernel/js/jsdom.asm)
; A detached node has N_PARENT 0 and is not in the document's child list.
; ==============================================================================

; dom_index: RBX = node record -> EAX = its index
dom_index:
    mov rax, rbx
    sub rax, DOM_ADDR
    shr rax, 7
    ret

; ------------------------------------------------------------------------------
; dom_detach: EAX = node -> taken out of its parent's children (if it has a
; parent or is a child of the document)
; ------------------------------------------------------------------------------
dom_detach:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov edx, eax                    ; EDX = node
    call dom_node
    mov rsi, rbx                    ; RSI = its record
    mov eax, [rsi + N_PARENT]
    call dom_node                   ; RBX = parent (the document when 0)
    xor ecx, ecx                    ; previous sibling
    mov eax, [rbx + N_FIRST]
.find:
    test eax, eax
    jz .done                        ; not there: already detached
    cmp eax, edx
    je .found
    mov ecx, eax
    push rbx
    call dom_node
    mov eax, [rbx + N_NEXT]
    pop rbx
    jmp .find
.found:
    mov eax, [rsi + N_NEXT]
    test ecx, ecx
    jnz .middle
    mov [rbx + N_FIRST], eax
    jmp .last
.middle:
    push rbx
    push rax
    mov eax, ecx
    call dom_node
    pop rax
    mov [rbx + N_NEXT], eax
    pop rbx
.last:
    cmp [rbx + N_LAST], edx
    jne .done
    mov [rbx + N_LAST], ecx
.done:
    mov dword [rsi + N_PARENT], 0
    mov dword [rsi + N_NEXT], 0
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; dom_insert: EAX = node, EDX = new parent, ECX = the child to insert it before
; (0 = at the end). The node is detached from where it was first.
; ------------------------------------------------------------------------------
dom_insert:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call dom_detach
    mov esi, eax                    ; ESI = node
    call dom_node
    mov [rbx + N_PARENT], edx
    mov rdi, rbx                    ; RDI = node record
    mov eax, edx
    call dom_node                   ; RBX = parent
    test ecx, ecx
    jz .append
    ; before ECX: find the child in front of it
    xor edx, edx
    mov eax, [rbx + N_FIRST]
.find:
    test eax, eax
    jz .append                      ; not a child: append instead
    cmp eax, ecx
    je .found
    mov edx, eax
    push rbx
    call dom_node
    mov eax, [rbx + N_NEXT]
    pop rbx
    jmp .find
.found:
    mov [rdi + N_NEXT], ecx
    test edx, edx
    jnz .after
    mov [rbx + N_FIRST], esi
    jmp .done
.after:
    mov eax, edx
    call dom_node
    mov [rbx + N_NEXT], esi
    jmp .done
.append:
    mov dword [rdi + N_NEXT], 0
    mov eax, [rbx + N_LAST]
    mov [rbx + N_LAST], esi
    test eax, eax
    jnz .sibling
    mov [rbx + N_FIRST], esi
    jmp .done
.sibling:
    call dom_node
    mov [rbx + N_NEXT], esi
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; dom_contains: EAX = node, EDX = possible descendant -> CF=1 if EDX is EAX or
; inside it
dom_contains:
    push rbx
    push rdx
.up:
    cmp edx, eax
    je .yes
    test edx, edx
    jz .no
    push rax
    mov eax, edx
    call dom_node
    pop rax
    mov edx, [rbx + N_PARENT]
    jmp .up
.yes:
    pop rdx
    pop rbx
    stc
    ret
.no:
    pop rdx
    pop rbx
    clc
    ret

; dom_connected: EAX = node -> CF=1 if it is in the document
dom_connected:
    push rax
    push rbx
    push rdx
.up:
    test eax, eax
    jz .yes                         ; reached the document
    mov edx, eax
    call dom_node
    mov eax, [rbx + N_PARENT]
    test eax, eax
    jnz .up
    ; a child of the document, or detached?
    xor eax, eax
    call dom_node
    mov eax, [rbx + N_FIRST]
.child:
    test eax, eax
    jz .no
    cmp eax, edx
    je .yes
    call dom_node
    mov eax, [rbx + N_NEXT]
    jmp .child
.yes:
    pop rdx
    pop rbx
    pop rax
    stc
    ret
.no:
    pop rdx
    pop rbx
    pop rax
    clc
    ret

; ------------------------------------------------------------------------------
; dom_new_element: RSI = tag name (lower case, kept), ECX = its length
; -> EAX = a detached element, RBX = its record; CF=1 if the DOM is full
; ------------------------------------------------------------------------------
dom_new_element:
    push rdx
    call dom_new
    jc .full
    mov byte [rbx + N_TYPE], NODE_ELEMENT
    mov [rbx + N_NAME], rsi
    mov [rbx + N_NAME_LEN], ecx
    push rax
    push rsi
    lea rsi, [dom_no_attrs]
    mov [rbx + N_ATTRS], rsi
    pop rsi
    call dom_hash
    mov [rbx + N_TAGH], eax
    mov edx, eax
    call dom_tag_lookup
    mov [rbx + N_TAG], al
    pop rax
    clc
.full:
    pop rdx
    ret

; dom_new_text: RSI = text (as HTML source: entities are decoded when drawn),
; ECX = length -> EAX = a detached text node, RBX = its record; CF=1 if full
dom_new_text:
    call dom_new
    jc .full
    mov byte [rbx + N_TYPE], NODE_TEXT
    mov [rbx + N_NAME], rsi
    mov [rbx + N_NAME_LEN], ecx
    clc
.full:
    ret

; ------------------------------------------------------------------------------
; dom_set_attrs: EAX = element, RSI = new attribute text (name="value" ...,
; NUL-terminated, kept) -> recorded, with its id, classes and style="" again
; ------------------------------------------------------------------------------
dom_set_attrs:
    push rax
    push rbx
    push r12
    call dom_node
    mov dword [rbx + N_IDH], 0
    mov byte [rbx + N_NCLS], 0
    mov qword [rbx + N_STYLE], 0
    mov dword [rbx + N_STYLE_LEN], 0
    mov r12, rsi
    call dom_attributes
    pop r12
    pop rbx
    pop rax
    ret

; dom_is_raw: EAX = element -> CF=1 if its content is raw text (script, style,
; textarea, title, ...), not HTML
dom_is_raw:
    push rax
    push rbx
    call dom_node
    movzx eax, byte [rbx + N_TAG]
    test eax, eax
    jz .no
    lea rbx, [dom_tag_flags]
    test byte [rbx + rax], TF_RAW
    jz .no
    pop rbx
    pop rax
    stc
    ret
.no:
    pop rbx
    pop rax
    clc
    ret

; ------------------------------------------------------------------------------
; dom_attr: EAX = element, RDI = attribute name (lower case, NUL-terminated)
; -> RSI = value, ECX = its length; CF=1 if the element has no such attribute
; ------------------------------------------------------------------------------
dom_attr:
    push rax
    push rbx
    push rdx
    push r8
    push r12
    call dom_node
    mov r12, [rbx + N_ATTRS]
    mov r8d, [rbx + N_ATTRS_LEN]
    add r8, r12                     ; R8 = end
.next:
    cmp r12, r8
    jae .none
    mov al, [r12]
    cmp al, ' '
    jbe .skip
    cmp al, '/'
    je .skip
    ; compare the name
    mov rsi, rdi
    mov rbx, r12
.cmp:
    mov al, [rbx]
    cmp al, '='
    je .name_end
    cmp al, ' '
    jbe .name_end
    cmp al, '>'
    je .name_end
    or al, 0x20
    cmp al, [rsi]
    jne .mismatch
    inc rbx
    inc rsi
    jmp .cmp
.name_end:
    cmp byte [rsi], 0
    jne .mismatch
    mov r12, rbx
    call dom_skip_spaces
    cmp byte [r12], '='
    jne .empty
    inc r12
    call dom_skip_spaces
    call dom_attr_value
    mov ecx, edx
    jmp .found
.empty:
    mov rsi, r12
    xor ecx, ecx
.found:
    pop r12
    pop r8
    pop rdx
    pop rbx
    pop rax
    clc
    ret
.mismatch:
    ; skip this attribute: its name, then any value
.skip_name:
    mov al, [r12]
    cmp al, '='
    je .skip_value
    cmp al, ' '
    jbe .next
    inc r12
    cmp r12, r8
    jb .skip_name
    jmp .none
.skip_value:
    inc r12
    call dom_skip_spaces
    call dom_attr_value
    jmp .next
.skip:
    inc r12
    jmp .next
.none:
    pop r12
    pop r8
    pop rdx
    pop rbx
    pop rax
    stc
    ret

section .rodata
dom_pre_name:           db "pre"
dom_no_attrs:           db 0

; hash, id, flags (built by tools? no: hashes are computed at startup by
; dom_init from dom_tag_names)
section .text
; ------------------------------------------------------------------------------
; dom_init: fill dom_tags (hash -> id, flags) from dom_tag_names
; ------------------------------------------------------------------------------
dom_init:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    lea rsi, [dom_tag_names]
    lea rdi, [dom_tags]
.entry:
    movzx ecx, byte [rsi]           ; name length
    test ecx, ecx
    jz .done
    inc rsi
    call dom_hash
    mov [rdi], eax
    add rsi, rcx
    mov ax, [rsi]                   ; id, flags
    mov [rdi + 4], ax
    movzx edx, al
    push rbx
    lea rbx, [dom_tag_flags]
    mov [rbx + rdx], ah
    pop rbx
    add rsi, 2
    add rdi, 8
    jmp .entry
.done:
    mov dword [rdi], 0
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

section .bss
alignb 8
dom_tags:               resb 8 * 128        ; dd hash, db id, db flags, dw 0
dom_tag_flags:          resb 256            ; flags by tag id

section .rodata
%macro DTAG 3                       ; name, id, flags
    db %%e - %%s
%%s:
    db %1
%%e:
    db %2, %3
%endmacro
dom_tag_names:
    DTAG "html", TAGID_HTML, 0
    DTAG "head", TAGID_HEAD, 0
    DTAG "body", TAGID_BODY, 0
    DTAG "p", TAGID_P, TF_BLOCK
    DTAG "li", TAGID_LI, TF_BLOCK
    DTAG "dt", TAGID_DT, TF_BLOCK
    DTAG "dd", TAGID_DD, TF_BLOCK
    DTAG "td", TAGID_TD, 0
    DTAG "th", TAGID_TH, 0
    DTAG "tr", TAGID_TR, 0
    DTAG "thead", TAGID_THEAD, 0
    DTAG "tbody", TAGID_TBODY, 0
    DTAG "tfoot", TAGID_TFOOT, 0
    DTAG "option", TAGID_OPTION, 0
    DTAG "ul", TAGID_UL, TF_BLOCK
    DTAG "ol", TAGID_OL, TF_BLOCK
    DTAG "dl", TAGID_DL, TF_BLOCK
    DTAG "table", TAGID_TABLE, TF_BLOCK
    DTAG "select", TAGID_SELECT, 0
    DTAG "a", TAGID_A, 0
    DTAG "br", TAGID_BR, TF_VOID
    DTAG "img", TAGID_IMG, TF_VOID
    DTAG "hr", TAGID_HR, TF_VOID | TF_BLOCK
    DTAG "input", TAGID_INPUT, TF_VOID
    DTAG "style", TAGID_STYLE, TF_RAW
    DTAG "link", TAGID_LINK, TF_VOID
    DTAG "script", TAGID_SCRIPT, TF_RAW
    DTAG "title", TAGID_TITLE, TF_RAW
    DTAG "pre", TAGID_PRE, TF_BLOCK
    DTAG "textarea", TAGID_TEXTAREA, TF_RAW
    DTAG "button", TAGID_BUTTON, 0
    DTAG "meta", TAGID_OTHER_VOID, TF_VOID
    DTAG "base", TAGID_OTHER_VOID, TF_VOID
    DTAG "area", TAGID_OTHER_VOID, TF_VOID
    DTAG "col", TAGID_OTHER_VOID, TF_VOID
    DTAG "embed", TAGID_OTHER_VOID, TF_VOID
    DTAG "source", TAGID_OTHER_VOID, TF_VOID
    DTAG "track", TAGID_OTHER_VOID, TF_VOID
    DTAG "wbr", TAGID_OTHER_VOID, TF_VOID
    DTAG "param", TAGID_OTHER_VOID, TF_VOID
    DTAG "keygen", TAGID_OTHER_VOID, TF_VOID
    DTAG "div", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "h1", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "h2", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "h3", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "h4", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "h5", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "h6", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "section", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "article", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "header", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "footer", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "nav", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "main", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "aside", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "blockquote", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "figure", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "figcaption", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "address", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "center", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "details", TAGID_DETAILS, TF_BLOCK
    DTAG "summary", TAGID_SUMMARY, TF_BLOCK
    DTAG "fieldset", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "form", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "menu", TAGID_OTHER_BLOCK, TF_BLOCK
    DTAG "xmp", TAGID_OTHER_RAW, TF_RAW
    DTAG "noembed", TAGID_OTHER_RAW, TF_RAW
    DTAG "noframes", TAGID_OTHER_RAW, TF_RAW
    db 0
section .text
