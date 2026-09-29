; ==============================================================================
; Antigravity OS - JavaScript <-> DOM (the browser's scripting)
; ------------------------------------------------------------------------------
; Every DOM node (web/dom.asm) can have a JavaScript object: a host object of
; class JC_NODE whose JSD_NODE field is the node index; the node keeps it in
; N_JSOBJ, so the same node always gives the same object. Reading or writing a
; host object's properties comes here first (jsd_get / jsd_put, called by
; js_get / js_put in vm.asm); methods live on the prototypes made by jsd_init.
;
; Text and attribute values in the DOM are kept as HTML source (the page's own
; text, or text that scripts set, with & < > " written as entities), so
; layout.asm draws both the same way; reading them from JavaScript decodes
; the entities.
;
; The browser calls:
;   jsd_page_load    after a page's DOM and styles are ready: runs its
;                    <script>s in order, then DOMContentLoaded and load
;   jsd_page_click   a click on a node: the click event, bubbling up
; Changes to the DOM set jsd_dirty; jsd_after restyles and lays the page out
; again. console.log output goes to the serial log as "[klog] js: ...".
; ==============================================================================

[bits 64]

JSD_BLD                 equ JS_SRC_ADDR         ; string builder (JS_SRC is free in the browser)
JSD_BLD_MAX             equ JS_SRC_SIZE - 16
JSD_MAX_SELS            equ 8                   ; selectors in one querySelector list
JSD_MAX_SCRIPTS         equ 256
JSD_MAX_EXTERNAL        equ 64                  ; <script src> fetched per page

; JSDNATIVE object, "name", routine, arity (same layout as JSNATIVE)
%macro JSDNATIVE 4
    [section .rodata]
    dq %1, %3
    db %4
    db %%e - %%s
    %%s: db %2
    %%e:
    __SECT__
%endmacro

; JSDPROP atom, getter, setter: a property of DOM nodes (0 = read-only / none)
%macro JSDPROP 3
    dq %1, %2, %3
%endmacro

section .bss
alignb 8
jsd_node_proto:         resq 1
jsd_style_proto:        resq 1
jsd_classlist_proto:    resq 1
jsd_event_proto:        resq 1
jsd_location_proto:     resq 1
; the prototypes of wrapped nodes, from the page prelude (__domProtos); 0 = jsd_node_proto
jsd_tag_protos:         resq 1          ; object: lower-case tag name -> prototype
jsd_element_proto:      resq 1          ; other elements (HTMLElement.prototype)
jsd_text_proto:         resq 1
jsd_comment_proto:      resq 1
jsd_fragment_proto:     resq 1
jsd_document_proto:     resq 1
jsd_saved_hook:         resq 1
jsd_bld_len:            resd 1
jsd_realm:              resd 1          ; js_realm when the page's scripts started
jsd_script_count:       resd 1
jsd_script_node:        resd 1          ; the <script> running now (document.write)
jsd_write_parent:       resd 1
jsd_write_before:       resd 1
jsd_sel_count:          resd 1
jsd_external:           resd 1
jsd_url_proto_end:      resd 1          ; location: offsets into the page URL
jsd_url_host_start:     resd 1
jsd_url_host_end:       resd 1
jsd_url_path_end:       resd 1
jsd_url_search_end:     resd 1
jsd_url_len:            resd 1
jsd_dirty:              resb 1          ; the DOM changed: restyle and lay out
jsd_loading:            resb 1          ; the page's scripts are running
jsd_enabled:            resb 1          ; the page has a JavaScript realm
jsd_nav_pending:        resb 1          ; location.href was set: browser_url_buf
jsd_sel_bad:            resb 1
jsd_in_script:          resb 1          ; one of the page's <script>s is running
alignb 8
jsd_name_buf:           resb 128
jsd_log_buf:            resb 240
jsd_scripts:            resd JSD_MAX_SCRIPTS
jsd_sels:               resb CSS_RULE_SIZE * JSD_MAX_SELS

section .rodata
jsd_natives:
JSDNATIVE jsd_node_proto, "getElementById", jsd_get_element_by_id, 1
JSDNATIVE jsd_node_proto, "querySelector", jsd_query_selector, 1
JSDNATIVE jsd_node_proto, "querySelectorAll", jsd_query_selector_all, 1
JSDNATIVE jsd_node_proto, "getElementsByTagName", jsd_get_by_tag, 1
JSDNATIVE jsd_node_proto, "getElementsByClassName", jsd_get_by_class, 1
JSDNATIVE jsd_node_proto, "createElement", jsd_create_element, 1
JSDNATIVE jsd_node_proto, "createTextNode", jsd_create_text_node, 1
JSDNATIVE jsd_node_proto, "createComment", jsd_create_comment, 1
JSDNATIVE jsd_node_proto, "createDocumentFragment", jsd_create_fragment, 0
JSDNATIVE jsd_node_proto, "write", jsd_write, 1
JSDNATIVE jsd_node_proto, "writeln", jsd_writeln, 1
JSDNATIVE jsd_node_proto, "getAttribute", jsd_get_attribute, 1
JSDNATIVE jsd_node_proto, "setAttribute", jsd_set_attribute, 2
JSDNATIVE jsd_node_proto, "removeAttribute", jsd_remove_attribute, 1
JSDNATIVE jsd_node_proto, "hasAttribute", jsd_has_attribute, 1
JSDNATIVE jsd_node_proto, "getAttributeNames", jsd_get_attribute_names, 0
JSDNATIVE jsd_node_proto, "dispatchEvent", jsd_dispatch_event, 1
JSDNATIVE jsd_node_proto, "appendChild", jsd_append_child, 1
JSDNATIVE jsd_node_proto, "removeChild", jsd_remove_child, 1
JSDNATIVE jsd_node_proto, "insertBefore", jsd_insert_before, 2
JSDNATIVE jsd_node_proto, "replaceChild", jsd_replace_child, 2
JSDNATIVE jsd_node_proto, "remove", jsd_remove, 0
JSDNATIVE jsd_node_proto, "append", jsd_append, 1
JSDNATIVE jsd_node_proto, "contains", jsd_contains, 1
JSDNATIVE jsd_node_proto, "matches", jsd_matches, 1
JSDNATIVE jsd_node_proto, "closest", jsd_closest, 1
JSDNATIVE jsd_node_proto, "cloneNode", jsd_clone_node, 1
JSDNATIVE jsd_node_proto, "hasChildNodes", jsd_has_child_nodes, 0
JSDNATIVE jsd_node_proto, "addEventListener", jsd_add_listener, 2
JSDNATIVE jsd_node_proto, "removeEventListener", jsd_remove_listener, 2
JSDNATIVE jsd_node_proto, "click", jsd_click, 0
JSDNATIVE jsd_node_proto, "focus", jsd_focus, 0
JSDNATIVE jsd_node_proto, "blur", jsd_blur, 0
JSDNATIVE jsd_classlist_proto, "add", jsd_classlist_add, 1
JSDNATIVE jsd_classlist_proto, "remove", jsd_classlist_remove, 1
JSDNATIVE jsd_classlist_proto, "toggle", jsd_classlist_toggle, 1
JSDNATIVE jsd_classlist_proto, "contains", jsd_classlist_contains, 1
JSDNATIVE jsd_style_proto, "getPropertyValue", jsd_style_get_property, 1
JSDNATIVE jsd_style_proto, "setProperty", jsd_style_set_property, 2
JSDNATIVE jsd_style_proto, "removeProperty", jsd_style_remove_property, 1
JSDNATIVE jsd_event_proto, "preventDefault", jsd_prevent_default, 0
JSDNATIVE jsd_event_proto, "stopPropagation", jsd_stop_propagation, 0
JSDNATIVE jsd_event_proto, "stopImmediatePropagation", jsd_stop_propagation, 0
JSDNATIVE jsd_location_proto, "reload", jsd_location_reload, 0
JSDNATIVE jsd_location_proto, "assign", jsd_location_assign, 1
JSDNATIVE jsd_location_proto, "replace", jsd_location_assign, 1
JSDNATIVE jsd_location_proto, "toString", jsd_location_to_string, 0
JSDNATIVE js_global, "alert", jsd_alert, 1
JSDNATIVE js_global, "confirm", jsd_confirm, 1
JSDNATIVE js_global, "prompt", jsd_prompt, 1
JSDNATIVE js_global, "addEventListener", jsd_add_listener, 2
JSDNATIVE js_global, "removeEventListener", jsd_remove_listener, 2
JSDNATIVE js_global, "__domProtos", jsd_set_protos, 6
JSDNATIVE js_global, "__currentScript", jsd_current_script, 0
JSDNATIVE js_global, "__formSubmit", jsd_form_submit, 2
JSDNATIVE js_global, "dispatchEvent", jsd_dispatch_event, 1
    dq 0

; properties of DOM nodes: atom, getter, setter
align 8
jsd_props:
JSDPROP atom_d_nodeType, jsd_g_node_type, 0
JSDPROP atom_d_nodeName, jsd_g_node_name, 0
JSDPROP atom_d_tagName, jsd_g_tag_name, 0
JSDPROP atom_d_nodeValue, jsd_g_node_value, jsd_s_node_value
JSDPROP atom_d_data, jsd_g_node_value, jsd_s_node_value
JSDPROP atom_d_textContent, jsd_g_text_content, jsd_s_text_content
JSDPROP atom_d_innerText, jsd_g_text_content, jsd_s_text_content
JSDPROP atom_d_innerHTML, jsd_g_inner_html, jsd_s_inner_html
JSDPROP atom_d_outerHTML, jsd_g_outer_html, 0
JSDPROP atom_d_id, jsd_g_attr, jsd_s_attr
JSDPROP atom_d_className, jsd_g_attr, jsd_s_attr
JSDPROP atom_name, jsd_g_attr, jsd_s_attr
JSDPROP atom_d_type, jsd_g_attr, jsd_s_attr
JSDPROP atom_d_alt, jsd_g_attr, jsd_s_attr
JSDPROP atom_d_placeholder, jsd_g_attr, jsd_s_attr
JSDPROP atom_d_rel, jsd_g_attr, jsd_s_attr
JSDPROP atom_d_target, jsd_g_attr, jsd_s_attr
JSDPROP atom_d_title, jsd_g_title, jsd_s_title
JSDPROP atom_d_value, jsd_g_value, jsd_s_value
JSDPROP atom_d_checked, jsd_g_checked, jsd_s_checked
JSDPROP atom_d_disabled, jsd_g_bool_attr, jsd_s_bool_attr
JSDPROP atom_d_hidden, jsd_g_bool_attr, jsd_s_bool_attr
JSDPROP atom_d_parentNode, jsd_g_parent_node, 0
JSDPROP atom_d_parentElement, jsd_g_parent_element, 0
JSDPROP atom_d_firstChild, jsd_g_first_child, 0
JSDPROP atom_d_lastChild, jsd_g_last_child, 0
JSDPROP atom_d_nextSibling, jsd_g_next_sibling, 0
JSDPROP atom_d_previousSibling, jsd_g_previous_sibling, 0
JSDPROP atom_d_firstElementChild, jsd_g_first_element_child, 0
JSDPROP atom_d_lastElementChild, jsd_g_last_element_child, 0
JSDPROP atom_d_nextElementSibling, jsd_g_next_element_sibling, 0
JSDPROP atom_d_previousElementSibling, jsd_g_previous_element_sibling, 0
JSDPROP atom_d_children, jsd_g_children, 0
JSDPROP atom_d_childNodes, jsd_g_child_nodes, 0
JSDPROP atom_d_childElementCount, jsd_g_child_element_count, 0
JSDPROP atom_d_style, jsd_g_style, jsd_s_style
JSDPROP atom_d_classList, jsd_g_class_list, 0
JSDPROP atom_d_isConnected, jsd_g_is_connected, 0
JSDPROP atom_d_ownerDocument, jsd_g_owner_document, 0
JSDPROP atom_d_body, jsd_g_body, 0
JSDPROP atom_d_head, jsd_g_head, 0
JSDPROP atom_d_documentElement, jsd_g_document_element, 0
JSDPROP atom_d_readyState, jsd_g_ready_state, 0
JSDPROP atom_d_cookie, jsd_g_cookie, jsd_s_cookie
JSDPROP atom_d_URL, jsd_g_url, 0
JSDPROP atom_d_location, jsd_g_location, jsd_s_location
    dq 0

jsd_prelude_src:        incbin "js/dom.js"
jsd_prelude_len         equ $ - jsd_prelude_src
jsd_str_class:          db "class", 0
jsd_str_style:          db "style", 0
jsd_str_value:          db "value", 0
jsd_str_src:            db "src", 0
jsd_str_type:           db "type", 0
jsd_str_javascript:     db "javascript", 0
jsd_str_ecmascript:     db "ecmascript", 0
jsd_str_div:            db "div"
jsd_str_text_name:      db "#text", 0
jsd_str_comment_name:   db "#comment", 0
jsd_str_comment_open:   db "<!--", 0
jsd_str_comment_close:  db "-->", 0
jsd_str_fragment_name:  db "#document-fragment", 0
jsd_str_fragment_name_len equ $ - jsd_str_fragment_name - 1
jsd_str_document_name:  db "#document", 0
jsd_str_loading:        db "loading", 0
jsd_str_complete:       db "complete", 0
jsd_str_click:          db "click", 0
jsd_str_dom_loaded:     db "DOMContentLoaded", 0
jsd_str_load:           db "load", 0
jsd_str_handler_open:   db "(function (event) {", 10, 0
jsd_str_handler_close:  db 10, "})", 0
jsd_str_user_agent:     db "Mozilla/5.0 (Antigravity OS) CyberSurf/1.0", 0
jsd_str_language:       db "en-US", 0
jsd_str_amp:            db "&amp;", 0
jsd_str_lt:             db "&lt;", 0
jsd_str_gt:             db "&gt;", 0
jsd_str_quot:           db "&quot;", 0
jsd_str_alert:          db "Alert: ", 0
jsd_klog_js:            db "js: ", 0
jsd_klog_alert:         db "js alert: ", 0
jsd_klog_nav:           db "js: navigate -> ", 0
jsd_str_style_class:    db "[object CSSStyleDeclaration]", 0
jsd_str_list_class:     db "[object DOMTokenList]", 0
jsmsg_not_node:         db "Failed to execute '%' on 'Node': parameter is not of type 'Node'.", 0
jsmsg_hierarchy:        db "Failed to execute '%': the new child contains the parent.", 0
jsmsg_not_child:        db "Failed to execute '%': the node is not a child of this node.", 0
jsmsg_illegal:          db "Illegal invocation", 0
jsmsg_bad_selector:     db "'%' is not a valid selector", 0
jsd_name_append:        db "appendChild", 0
jsd_name_submit:        db "submit", 0
jsd_name_insert:        db "insertBefore", 0
jsd_name_remove:        db "removeChild", 0
jsd_name_replace:       db "replaceChild", 0

section .text

; ==============================================================================
; Setting up a page's realm
; ==============================================================================

; ------------------------------------------------------------------------------
; jsd_init: after js_reset: window (the global object), document, location,
; navigator and the DOM prototypes
; ------------------------------------------------------------------------------
jsd_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    xor eax, eax                    ; (the prelude sets these again)
    mov [jsd_tag_protos], rax
    mov [jsd_element_proto], rax
    mov [jsd_text_proto], rax
    mov [jsd_comment_proto], rax
    mov [jsd_fragment_proto], rax
    mov [jsd_document_proto], rax
    mov rbx, [js_object_proto]
    mov rax, rbx
    call jsobj_new
    mov [jsd_node_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [jsd_style_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [jsd_classlist_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [jsd_event_proto], rax
    mov rax, rbx
    call jsobj_new
    mov [jsd_location_proto], rax
    lea r8, [jsd_natives]
    call jsb_define_natives
    mov rdi, [js_global]
    ; window, self: the global object itself
    mov rcx, rdi
    BOX rcx, rdx, JS_OBJ_BITS
    mov rax, rdi
    mov rdx, [atom_d_window]
    call jsobj_define_hidden
    mov rdx, [atom_d_self]
    call jsobj_define_hidden
    ; document
    xor eax, eax
    call jsd_wrap
    mov rcx, rax
    mov rax, rdi
    mov rdx, [atom_d_document]
    call jsobj_define_hidden
    ; location
    mov ecx, JC_LOCATION
    xor eax, eax
    mov rdx, [jsd_location_proto]
    call jsd_host_new
    mov rcx, rax
    BOX rcx, rdx, JS_OBJ_BITS
    mov rax, rdi
    mov rdx, [atom_d_location]
    call jsobj_define_hidden
    ; navigator
    call jsobj_new_plain
    mov rbx, rax
    lea rsi, [jsd_str_user_agent]
    call jsb_cstr
    mov rcx, rax
    mov rax, rbx
    mov rdx, [atom_d_userAgent]
    call jsobj_define
    lea rsi, [jsd_str_language]
    call jsb_cstr
    mov rcx, rax
    mov rax, rbx
    mov rdx, [atom_d_language]
    call jsobj_define
    mov rcx, rbx
    BOX rcx, rdx, JS_OBJ_BITS
    mov rax, rdi
    mov rdx, [atom_d_navigator]
    call jsobj_define_hidden
    ; viewport size in CSS pixels (twice the browser's pixels, like @media)
    mov eax, [browser_vp_w]
    test eax, eax
    jnz .width
    mov eax, 880
.width:
    shl eax, 1
    call jsb_from_int
    mov rcx, rax
    mov rax, rdi
    mov rdx, [atom_d_innerWidth]
    call jsobj_define
    mov eax, [browser_vp_h]
    test eax, eax
    jnz .height
    mov eax, 560
.height:
    shl eax, 1
    call jsb_from_int
    mov rcx, rax
    mov rax, rdi
    mov rdx, [atom_d_innerHeight]
    call jsobj_define
    ; the DOM classes and the rest of the web APIs (kernel/js/dom.js)
    lea rsi, [jsd_prelude_src]
    mov ecx, jsd_prelude_len
    call js_run_prelude
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsd_host_new: ECX = class, EAX = node, RDX = prototype -> RAX = host object
jsd_host_new:
    push rbx
    push rcx
    mov ebx, eax
    push rcx
    mov ecx, JSD_SIZE
    call js_alloc
    pop rcx
    mov byte [rax + JH_KIND], JK_OBJECT
    mov [rax + JOBJ_CLASS], ecx
    mov [rax + JOBJ_PROTO], rdx
    mov [rax + JSD_NODE], ebx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; jsd_wrap: EAX = node -> RAX = its JavaScript object (made once)
; jsd_wrap_opt: EAX = node or -1 -> its object or null
; ------------------------------------------------------------------------------
jsd_wrap:
    push rbx
    push rcx
    push rdx
    call dom_node
    mov edx, [rbx + N_JSOBJ]
    test edx, edx
    jnz .have
    mov ecx, JC_NODE
    call jsd_proto_for
    call jsd_host_new
    mov [rbx + N_JSOBJ], eax
    mov edx, eax
.have:
    mov eax, edx
    BOX rax, rcx, JS_OBJ_BITS
    pop rdx
    pop rcx
    pop rbx
    ret

; jsd_proto_for: RBX = node record -> RDX = the prototype of its object
; (Document, Text, Comment, DocumentFragment, HTMLDivElement, ...)
jsd_proto_for:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    mov rdx, [jsd_document_proto]
    cmp rbx, DOM_ADDR
    je .chosen
    mov rdx, [jsd_comment_proto]
    test byte [rbx + N_FLAGS], NF_COMMENT
    jnz .chosen
    mov rdx, [jsd_text_proto]
    cmp byte [rbx + N_TYPE], NODE_TEXT
    je .chosen
    mov rdx, [jsd_fragment_proto]
    test byte [rbx + N_FLAGS], NF_FRAGMENT
    jnz .chosen
    ; an element: by its tag name
    mov rdx, [jsd_element_proto]
    cmp qword [jsd_tag_protos], 0
    je .chosen
    mov rsi, [rbx + N_NAME]
    mov ecx, [rbx + N_NAME_LEN]
    cmp ecx, 32
    ja .chosen
    ; (lower case in a buffer of its own: callers keep things in jsd_name_buf)
    sub rsp, 32
    mov rdi, rsp
    push rcx
.lower:
    test ecx, ecx
    jz .lowered
    lodsb
    cmp al, 'A'
    jb .put
    cmp al, 'Z'
    ja .put
    or al, 0x20
.put:
    stosb
    dec ecx
    jmp .lower
.lowered:
    pop rcx
    mov rsi, rsp
    call jsstr_find_atom
    lea rsp, [rsp + 32]
    jc .chosen
    push rdx
    mov rdx, rax
    mov rax, [jsd_tag_protos]
    call jsobj_find_own
    pop rdx
    jc .chosen
    mov rax, [rbx + JPE_VAL]
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .chosen
    mov edx, eax
.chosen:
    test rdx, rdx
    jnz .out
    mov rdx, [jsd_node_proto]
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; __domProtos(tags, element, text, comment, fragment, document): the page
; prelude's prototypes for wrapped nodes (objects; anything else: the default)
jsd_set_protos:
    push rbx
    push rdx
    lea rbx, [jsd_tag_protos]
    xor edx, edx
.arg:
    mov eax, edx
    call jsb_arg
    push rcx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    pop rcx
    je .object
    xor eax, eax
.object:
    mov eax, eax
    mov [rbx + rdx*8], rax
    inc edx
    cmp edx, 6
    jb .arg
    ; -> [the nodes' prototype (the native methods), the events' prototype]
    push rcx
    mov ecx, 2
    call jsarr_new
    mov rbx, rax
    mov rcx, [jsd_node_proto]
    BOX rcx, rdx, JS_OBJ_BITS
    call jsarr_push
    mov rcx, [jsd_event_proto]
    BOX rcx, rdx, JS_OBJ_BITS
    call jsarr_push
    pop rcx
    BOX rax, rdx, JS_OBJ_BITS
    pop rdx
    pop rbx
    ret

jsd_wrap_opt:
    cmp eax, -1
    je .null
    jmp jsd_wrap
.null:
    mov rax, JS_NULL
    ret

; jsd_node_of: RAX = value -> EAX = its node, CF=1 if it is not a DOM node
jsd_node_of:
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .no
    mov edx, eax
    cmp byte [rdx + JH_KIND], JK_OBJECT
    jne .no
    cmp dword [rdx + JOBJ_CLASS], JC_NODE
    jne .no
    mov eax, [rdx + JSD_NODE]
    pop rdx
    clc
    ret
.no:
    pop rdx
    stc
    ret

; jsd_this_node: RDX = this -> EAX = its node, RBX = record (TypeError if none)
jsd_this_node:
    mov rax, rdx
    call jsd_node_of
    jc .bad
    jmp dom_node
.bad:
    lea rsi, [jsmsg_illegal]
    xor edi, edi
    jmp js_throw_type

; jsd_arg_node: EAX = argument index, RSI = method name -> EAX = the node
; argument (TypeError if it is not one)
jsd_arg_node:
    call jsb_arg
    call jsd_node_of
    jc .bad
    ret
.bad:
    call jsstr_from_cstr
    mov rdi, rax
    lea rsi, [jsmsg_not_node]
    jmp js_throw_type

; jsd_this_host: RDX = this -> EAX = the node of a style / classList object
jsd_this_host:
    mov rax, rdx
    push rdx
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    pop rdx
    jne jsd_this_node.bad
    mov eax, edx
    cmp dword [rax + JOBJ_CLASS], JC_HOST
    jb jsd_this_node.bad
    mov eax, [rax + JSD_NODE]
    ret

; ==============================================================================
; String builder (JSD_BLD)
; ==============================================================================

jsd_bld_reset:
    mov dword [jsd_bld_len], 0
    ret

; jsd_bld_byte: AL
jsd_bld_byte:
    push rdx
    mov edx, [jsd_bld_len]
    cmp edx, JSD_BLD_MAX
    jae .full
    push rdi
    mov rdi, JSD_BLD
    mov [rdi + rdx], al
    pop rdi
    inc dword [jsd_bld_len]
.full:
    pop rdx
    ret

; jsd_bld_bytes: RSI = bytes, RCX = count
jsd_bld_bytes:
    push rax
    push rcx
    push rsi
.loop:
    test rcx, rcx
    jz .done
    lodsb
    call jsd_bld_byte
    dec rcx
    jmp .loop
.done:
    pop rsi
    pop rcx
    pop rax
    ret

; jsd_bld_cstr: RSI = NUL-terminated text
jsd_bld_cstr:
    push rax
    push rsi
.loop:
    lodsb
    test al, al
    jz .done
    call jsd_bld_byte
    jmp .loop
.done:
    pop rsi
    pop rax
    ret

; jsd_bld_str: RAX = heap string
jsd_bld_str:
    push rcx
    push rsi
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    call jsd_bld_bytes
    pop rsi
    pop rcx
    ret

; jsd_bld_take: -> RAX = a new heap string with the built text
jsd_bld_take:
    push rcx
    push rsi
    mov ecx, [jsd_bld_len]
    mov rsi, JSD_BLD
    call jsstr_new
    pop rsi
    pop rcx
    ret

; jsd_bld_value: -> RAX = the built text as a string value
jsd_bld_value:
    call jsd_bld_take
    jmp jsb_box_string

; ==============================================================================
; Text: entities in, entities out
; ==============================================================================

; ------------------------------------------------------------------------------
; jsd_decode: RSI = HTML text, RCX = length -> the text with &entities; decoded
; (to UTF-8) appended to the builder
; ------------------------------------------------------------------------------
jsd_decode:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    lea r8, [rsi + rcx]             ; end
.loop:
    cmp rsi, r8
    jae .done
    lodsb
    cmp al, '&'
    je .entity
.byte:
    call jsd_bld_byte
    jmp .loop
.entity:
    mov rbx, rsi                    ; after '&'
    cmp rsi, r8
    jae .literal
    cmp byte [rsi], '#'
    je .number
    ; named: "name;" from layout's table
    lea rdx, [lay_entities]
.entry:
    movzx ecx, byte [rdx]
    test ecx, ecx
    jz .literal
    lea rax, [rsi + rcx]
    cmp rax, r8
    ja .next_entry
    push rsi
    push rdi
    lea rdi, [rdx + 1]
    push rcx
    repe cmpsb
    pop rcx
    pop rdi
    pop rsi
    je .named
.next_entry:
    lea rdx, [rdx + rcx + 3]
    jmp .entry
.named:
    add rsi, rcx
    movzx eax, word [rdx + rcx + 1]
    jmp .code_point
.number:
    inc rsi
    xor eax, eax
    mov ecx, 10
    cmp rsi, r8
    jae .literal
    mov dl, [rsi]
    or dl, 0x20
    cmp dl, 'x'
    jne .digits
    mov ecx, 16
    inc rsi
.digits:
    xor edx, edx                    ; digits seen
.digit:
    cmp rsi, r8
    jae .literal
    push rax
    movzx eax, byte [rsi]
    call jsnum_digit_value
    mov edi, eax
    pop rax
    cmp edi, ecx
    jae .number_end
    imul eax, ecx
    add eax, edi
    and eax, 0x1FFFFF
    inc rsi
    inc edx
    jmp .digit
.number_end:
    test edx, edx
    jz .literal
    cmp byte [rsi], ';'
    jne .code_point
    inc rsi
.code_point:
    push rdi
    sub rsp, 8
    mov rdi, rsp
    call jslex_put_utf8
    mov rcx, rdi
    mov rdi, rsp
    sub rcx, rdi
    push rsi
    mov rsi, rdi
    call jsd_bld_bytes
    pop rsi
    add rsp, 8
    pop rdi
    jmp .loop
.literal:
    mov rsi, rbx
    mov al, '&'
    jmp .byte
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsd_encode: RSI = text, RCX = length, DL = 1 to escape '"' too
; -> the text with & < > (") as entities appended to the builder
jsd_encode:
    push rax
    push rcx
    push rsi
    push rdi
.loop:
    test rcx, rcx
    jz .done
    lodsb
    lea rdi, [jsd_str_amp]
    cmp al, '&'
    je .entity
    lea rdi, [jsd_str_lt]
    cmp al, '<'
    je .entity
    lea rdi, [jsd_str_gt]
    cmp al, '>'
    je .entity
    lea rdi, [jsd_str_quot]
    cmp al, '"'
    jne .plain
    test dl, dl
    jnz .entity
.plain:
    call jsd_bld_byte
    jmp .next
.entity:
    push rsi
    mov rsi, rdi
    call jsd_bld_cstr
    pop rsi
.next:
    dec rcx
    jmp .loop
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; jsd_encoded_string: RAX = value -> RAX = heap string of ToString(value) with
; & < > encoded (for text nodes)
jsd_encoded_string:
    push rcx
    push rdx
    push rsi
    call js_to_string
    call jsd_bld_reset
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    xor edx, edx
    call jsd_encode
    call jsd_bld_take
    pop rsi
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------------------------
; jsd_text_of: EAX = node -> its text content (decoded) appended to the builder
; ------------------------------------------------------------------------------
jsd_text_of:
    push rax
    push rbx
    push rdx
    mov edx, eax                    ; root
.node:
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_TEXT
    jne .next
    test byte [rbx + N_FLAGS], NF_COMMENT
    jnz .next
    call jsd_text_node_text
.next:
    call jsd_next
    test eax, eax
    jnz .node
    pop rdx
    pop rbx
    pop rax
    ret

; jsd_text_node_text: EAX = text node -> its text, decoded unless it is the
; content of a raw element (script, style)
jsd_text_node_text:
    push rax
    push rbx
    push rcx
    push rsi
    call dom_node
    mov rsi, [rbx + N_NAME]
    mov ecx, [rbx + N_NAME_LEN]
    mov eax, [rbx + N_PARENT]
    call dom_is_raw
    jc .raw
    call jsd_decode
    jmp .done
.raw:
    call jsd_bld_bytes
.done:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; jsd_next: EAX = node, EDX = root -> EAX = the next node inside root in
; document order (0 = no more)
jsd_next:
    push rbx
    call dom_node
    mov eax, [rbx + N_FIRST]
    test eax, eax
    jnz .out
    mov rax, rbx
    sub rax, DOM_ADDR
    shr rax, 7
.up:
    cmp eax, edx
    je .end
    call dom_node
    mov eax, [rbx + N_NEXT]
    test eax, eax
    jnz .out
    mov eax, [rbx + N_PARENT]
    test eax, eax
    jnz .up
.end:
    xor eax, eax
.out:
    pop rbx
    ret

; ------------------------------------------------------------------------------
; jsd_serialize: EAX = node -> its HTML (outerHTML) appended to the builder
; jsd_serialize_children: EAX = node -> its children's HTML (innerHTML)
; ------------------------------------------------------------------------------
jsd_serialize:
    push rax
    push rbx
    push rcx
    push rsi
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_TEXT
    jne .element
    test byte [rbx + N_FLAGS], NF_COMMENT
    jnz .comment
    mov rsi, [rbx + N_NAME]
    mov ecx, [rbx + N_NAME_LEN]
    call jsd_bld_bytes
    jmp .done
.comment:
    lea rsi, [jsd_str_comment_open]
    call jsd_bld_cstr
    mov rsi, [rbx + N_NAME]
    mov ecx, [rbx + N_NAME_LEN]
    call jsd_bld_bytes
    lea rsi, [jsd_str_comment_close]
    call jsd_bld_cstr
    jmp .done
.element:
    test eax, eax
    jz .children                    ; the document
    push rax
    mov al, '<'
    call jsd_bld_byte
    mov rsi, [rbx + N_NAME]
    mov ecx, [rbx + N_NAME_LEN]
    call jsd_bld_bytes
    ; attributes as written, without a trailing '/' or spaces
    mov rsi, [rbx + N_ATTRS]
    mov ecx, [rbx + N_ATTRS_LEN]
.trim:
    test ecx, ecx
    jz .attrs_done
    mov al, [rsi + rcx - 1]
    cmp al, ' '
    jbe .trim_one
    cmp al, '/'
    jne .attrs
.trim_one:
    dec ecx
    jmp .trim
.attrs:
    ; skip leading spaces, then one space before them
.lead:
    cmp byte [rsi], ' '
    ja .write_attrs
    inc rsi
    dec ecx
    jnz .lead
    jmp .attrs_done
.write_attrs:
    mov al, ' '
    call jsd_bld_byte
    call jsd_bld_bytes
.attrs_done:
    mov al, '>'
    call jsd_bld_byte
    pop rax
    ; void elements have no content or end tag
    movzx ecx, byte [rbx + N_TAG]
    test ecx, ecx
    jz .content
    push rbx
    lea rbx, [dom_tag_flags]
    test byte [rbx + rcx], TF_VOID
    pop rbx
    jnz .done
.content:
    call jsd_serialize_children
    mov al, '<'
    call jsd_bld_byte
    mov al, '/'
    call jsd_bld_byte
    mov rsi, [rbx + N_NAME]
    mov ecx, [rbx + N_NAME_LEN]
    call jsd_bld_bytes
    mov al, '>'
    call jsd_bld_byte
    jmp .done
.children:
    call jsd_serialize_children
.done:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

jsd_serialize_children:
    push rax
    push rbx
    call dom_node
    mov eax, [rbx + N_FIRST]
.child:
    test eax, eax
    jz .done
    call jsd_serialize
    call dom_node
    mov eax, [rbx + N_NEXT]
    jmp .child
.done:
    pop rbx
    pop rax
    ret

; jsd_clear_children: EAX = node -> all its children detached
jsd_clear_children:
    push rax
    push rbx
    push rdx
    mov edx, eax
.child:
    mov eax, edx
    call dom_node
    mov eax, [rbx + N_FIRST]
    test eax, eax
    jz .done
    call dom_detach
    jmp .child
.done:
    mov byte [jsd_dirty], 1
    pop rdx
    pop rbx
    pop rax
    ret

; jsd_set_text: EAX = node, RCX = value -> its text content replaced (a text
; node's own text, or the element's children by one text node)
jsd_set_text:
    push rax
    push rbx
    push rcx
    push rsi
    push rdx
    mov edx, eax
    call dom_node
    ; the new text (encoded, unless it is the content of a raw element)
    push rax
    mov rax, rcx
    mov eax, edx
    cmp byte [rbx + N_TYPE], NODE_TEXT
    jne .raw_check
    mov eax, [rbx + N_PARENT]
.raw_check:
    call dom_is_raw
    mov rax, rcx
    jc .raw
    call jsd_encoded_string
    jmp .have
.raw:
    call js_to_string
.have:
    mov rcx, rax
    pop rax
    cmp byte [rbx + N_TYPE], NODE_TEXT
    jne .element
    lea rsi, [rcx + JSTR_DATA]
    mov [rbx + N_NAME], rsi
    mov eax, [rcx + JSTR_LEN]
    mov [rbx + N_NAME_LEN], eax
    jmp .done
.element:
    mov eax, edx
    call jsd_clear_children
    mov eax, [rcx + JSTR_LEN]
    test eax, eax
    jz .done
    lea rsi, [rcx + JSTR_DATA]
    mov ecx, eax
    call dom_new_text
    jc .done
    push rcx
    xor ecx, ecx
    call dom_insert                 ; EAX = the text node, EDX = the element
    pop rcx
.done:
    mov byte [jsd_dirty], 1
    pop rdx
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ==============================================================================
; Attributes
; ==============================================================================

; jsd_lower_name: RAX = heap string -> RSI = jsd_name_buf with it in lower
; case (NUL-terminated), ECX = length
jsd_lower_name:
    push rax
    push rdi
    mov ecx, [rax + JSTR_LEN]
    cmp ecx, 120
    jbe .len
    mov ecx, 120
.len:
    lea rsi, [rax + JSTR_DATA]
    lea rdi, [jsd_name_buf]
    push rcx
.copy:
    test ecx, ecx
    jz .copied
    lodsb
    cmp al, 'A'
    jb .put
    cmp al, 'Z'
    ja .put
    or al, 0x20
.put:
    stosb
    dec ecx
    jmp .copy
.copied:
    mov byte [rdi], 0
    pop rcx
    lea rsi, [jsd_name_buf]
    pop rdi
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsd_get_attr: EAX = element, RSI = attribute name (lower case, NUL-terminated)
; -> RAX = its value (decoded string value), CF=1 (RAX = null) if absent
; ------------------------------------------------------------------------------
jsd_get_attr:
    push rcx
    push rsi
    push rdi
    mov rdi, rsi
    call dom_attr
    jc .none
    call jsd_bld_reset
    call jsd_decode
    call jsd_bld_value
    pop rdi
    pop rsi
    pop rcx
    clc
    ret
.none:
    mov rax, JS_NULL
    pop rdi
    pop rsi
    pop rcx
    stc
    ret

; ------------------------------------------------------------------------------
; jsd_set_attr: EAX = element, RSI = name (lower case), ECX = its length,
; RDX = new value (heap string) or 0 to remove it -> the attribute text
; rebuilt; id, class and style="" noticed again
; ------------------------------------------------------------------------------
jsd_set_attr:
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
    push r12
    mov r10, rsi                    ; name
    mov r11d, ecx
    call jsd_bld_reset
    call dom_node
    mov r12, [rbx + N_ATTRS]
    mov r8d, [rbx + N_ATTRS_LEN]
    add r8, r12                     ; end
    mov ebx, eax                    ; EBX = the element from here on
.attr:
    call jsd_attr_next              ; R9 = start, RDI/ECX = name, R12 = end
    jc .others_done
    ; same name? then it is dropped
    cmp ecx, r11d
    jne .keep
    push rsi
    push rdi
    push rcx
    mov rsi, r10
.cmp:
    mov al, [rdi]
    or al, 0x20
    cmp al, [rsi]
    jne .cmp_done
    inc rdi
    inc rsi
    dec ecx
    jnz .cmp
.cmp_done:
    pop rcx
    pop rdi
    pop rsi
    je .attr
.keep:
    mov al, ' '
    call jsd_bld_byte
    push rsi
    push rcx
    mov rsi, r9
    mov rcx, r12
    sub rcx, r9
    call jsd_bld_bytes
    pop rcx
    pop rsi
    jmp .attr
.others_done:
    test rdx, rdx
    jz .store
    mov al, ' '
    call jsd_bld_byte
    mov rsi, r10
    mov ecx, r11d
    call jsd_bld_bytes
    mov al, '='
    call jsd_bld_byte
    mov al, '"'
    call jsd_bld_byte
    mov ecx, [rdx + JSTR_LEN]
    lea rsi, [rdx + JSTR_DATA]
    push rdx
    mov dl, 1
    call jsd_encode
    pop rdx
    mov al, '"'
    call jsd_bld_byte
.store:
    call jsd_bld_take
    lea rsi, [rax + JSTR_DATA]
    mov eax, ebx
    call dom_set_attrs
    mov byte [jsd_dirty], 1
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
    pop rax
    ret

; jsd_attr_next: R12 = in attribute text, R8 = its end -> R9 = start of the
; next attribute, RDI/ECX = its name, R12 = after it (and its value);
; CF=1 when there are no more
jsd_attr_next:
    push rax
    push rdx
    push rsi
.skip:
    cmp r12, r8
    jae .none
    mov al, [r12]
    cmp al, ' '
    jbe .skip_one
    cmp al, '/'
    je .skip_one
    cmp al, '>'
    je .none
    jmp .name
.skip_one:
    inc r12
    jmp .skip
.name:
    mov r9, r12
    mov rdi, r12
.name_char:
    cmp r12, r8
    jae .name_end
    mov al, [r12]
    cmp al, '='
    je .name_end
    cmp al, ' '
    jbe .name_end
    cmp al, '>'
    je .name_end
    inc r12
    jmp .name_char
.name_end:
    mov rcx, r12
    sub rcx, rdi
    ; a value?
    mov rsi, r12
.spaces:
    cmp rsi, r8
    jae .done
    cmp byte [rsi], ' '
    ja .check
    inc rsi
    jmp .spaces
.check:
    cmp byte [rsi], '='
    jne .done
    lea r12, [rsi + 1]
    call dom_skip_spaces
    call dom_attr_value             ; R12 past the value
    cmp r12, r8
    jbe .done
    mov r12, r8
.done:
    pop rsi
    pop rdx
    pop rax
    clc
    ret
.none:
    pop rsi
    pop rdx
    pop rax
    stc
    ret

; jsd_set_attr_value: EAX = element, RSI = name (NUL-terminated, lower case),
; RCX = value (any JS value) -> set to ToString(value)
jsd_set_attr_value:
    push rax
    push rcx
    push rdx
    push rsi
    push rax
    mov rax, rcx
    call js_to_string
    mov rdx, rax
    pop rax
    push rax
    call strlen
    mov ecx, eax
    pop rax
    call jsd_set_attr
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsd_remove_attr_named: EAX = element, RSI = name (NUL-terminated, lower case)
jsd_remove_attr_named:
    push rax
    push rcx
    push rdx
    push rax
    call strlen
    mov ecx, eax
    pop rax
    xor edx, edx
    call jsd_set_attr
    pop rdx
    pop rcx
    pop rax
    ret

; ==============================================================================
; Finding elements
; ==============================================================================

; jsd_find_tag: EAX = root, EDX = tag id -> EAX = the first descendant with
; that tag (in document order), CF=1 if none
jsd_find_tag:
    push rbx
    push rcx
    push rdx
    mov ecx, edx
    mov edx, eax
.next:
    call jsd_next
    test eax, eax
    jz .none
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    jne .next
    cmp [rbx + N_TAG], cl
    jne .next
    pop rdx
    pop rcx
    pop rbx
    clc
    ret
.none:
    pop rdx
    pop rcx
    pop rbx
    stc
    ret

; jsd_bad_selector: RAX = a selector list with one the engine cannot use ->
; SyntaxError (scripts with a fallback, like jQuery's, use it)
jsd_bad_selector:
    mov rdi, rax
    lea rsi, [jsmsg_bad_selector]
    mov edx, JE_SYNTAX
    jmp js_throw

; ------------------------------------------------------------------------------
; jsd_compile_selectors: RAX = selector list (heap string) -> jsd_sels /
; jsd_sel_count (unsupported selectors are left out, jsd_sel_bad set)
; ------------------------------------------------------------------------------
jsd_compile_selectors:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov dword [jsd_sel_count], 0
    mov byte [jsd_sel_bad], 0
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    lea r8, [rsi + rcx]             ; end
.selector:
    ; one selector: up to a ',' outside parentheses
    mov rbx, rsi
    xor edx, edx                    ; paren depth
.scan:
    cmp rsi, r8
    jae .cut
    mov al, [rsi]
    cmp al, '('
    jne .not_open
    inc edx
.not_open:
    cmp al, ')'
    jne .not_close
    dec edx
.not_close:
    cmp al, ','
    jne .scan_next
    test edx, edx
    jz .cut
.scan_next:
    inc rsi
    jmp .scan
.cut:
    mov rcx, rsi
    sub rcx, rbx
    mov eax, [jsd_sel_count]
    cmp eax, JSD_MAX_SELS
    jae .skip
    imul eax, eax, CSS_RULE_SIZE
    lea rdi, [jsd_sels]
    add rdi, rax
    push rsi
    mov rsi, rbx
    call css_compile_selector
    pop rsi
    jc .bad
    inc dword [jsd_sel_count]
    jmp .skip
.bad:
    mov byte [jsd_sel_bad], 1
.skip:
    cmp rsi, r8
    jae .done
    inc rsi                         ; past ','
    jmp .selector
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsd_selector_match: EAX = node -> CF=0 if it is an element matching one of
; the compiled selectors
jsd_selector_match:
    push rbx
    push rcx
    push rsi
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    jne .no
    test eax, eax
    jz .no
    xor ecx, ecx
    lea rsi, [jsd_sels]
.try:
    cmp ecx, [jsd_sel_count]
    jae .no
    call css_selector_matches
    jnc .yes
    add rsi, CSS_RULE_SIZE
    inc ecx
    jmp .try
.yes:
    pop rsi
    pop rcx
    pop rbx
    clc
    ret
.no:
    pop rsi
    pop rcx
    pop rbx
    stc
    ret

; jsd_collect_start: -> RAX = a new empty array (raw) in R8 for jsd_collect
; jsd_collect: EAX = node -> its object appended to the array in R8
jsd_collect:
    push rax
    push rcx
    call jsd_wrap
    mov rcx, rax
    mov rax, r8
    call jsarr_push
    pop rcx
    pop rax
    ret

; ==============================================================================
; Properties of host objects (called from js_get / js_put)
; ==============================================================================

; ------------------------------------------------------------------------------
; jsd_get: RDI = host object, RDX = atom -> RAX = value, CF=0; CF=1 if it is
; not one of ours (ordinary lookup follows)
; ------------------------------------------------------------------------------
jsd_get:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov ecx, [rdi + JOBJ_CLASS]
    mov eax, [rdi + JSD_NODE]
    cmp ecx, JC_NODE
    je .node
    cmp ecx, JC_STYLE
    je .style
    cmp ecx, JC_CLASSLIST
    je .class_list
    cmp ecx, JC_LOCATION
    je .location
    jmp .not_ours
.node:
    lea rsi, [jsd_props]
.prop:
    mov rcx, [rsi]
    test rcx, rcx
    jz .not_ours
    cmp rdx, [rcx]
    je .found
    add rsi, 24
    jmp .prop
.found:
    mov rcx, [rsi + 8]
    call dom_node
    call rcx                        ; EAX = node, RBX = record, RDX = atom, RDI = object
    jmp .ours
.style:
    ; methods (getPropertyValue, ...) are on the prototype
    push rax
    mov rax, rdi
    push rbx
    call jsobj_lookup
    pop rbx
    pop rax
    jnc .not_ours
    cmp rdx, [atom_d_cssText]
    je .css_text
    call jsd_style_name             ; RSI/ECX = the CSS property name
    call jsd_style_value
    jmp .ours
.css_text:
    lea rsi, [jsd_str_style]
    call jsd_get_attr
    jnc .ours
    mov rax, [atom_empty]
    call jsb_box_string
    jmp .ours
.class_list:
    cmp rdx, [atom_d_value]
    je .class_value
    cmp rdx, [atom_length]
    jne .not_ours
    call dom_node
    movzx eax, byte [rbx + N_NCLS]
    call jsb_from_int
    jmp .ours
.class_value:
    lea rsi, [jsd_str_class]
    call jsd_get_attr
    jnc .ours
    mov rax, [atom_empty]
    call jsb_box_string
    jmp .ours
.location:
    call jsd_location_get
    jc .not_ours
.ours:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    clc
    ret
.not_ours:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    stc
    ret

; ------------------------------------------------------------------------------
; jsd_put: RAX = host object, RDX = atom, RCX = value -> CF=0 if handled
; ------------------------------------------------------------------------------
jsd_put:
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
    mov rdi, rax
    mov r8d, [rdi + JOBJ_CLASS]
    mov eax, [rdi + JSD_NODE]
    cmp r8d, JC_NODE
    je .node
    cmp r8d, JC_STYLE
    je .style
    cmp r8d, JC_CLASSLIST
    je .class_list
    cmp r8d, JC_LOCATION
    je .location
    jmp .not_ours
.node:
    lea rsi, [jsd_props]
.prop:
    mov r8, [rsi]
    test r8, r8
    jz .not_ours
    cmp rdx, [r8]
    je .found
    add rsi, 24
    jmp .prop
.found:
    mov r8, [rsi + 16]
    test r8, r8
    jz .ours                        ; read-only: ignored
    call dom_node
    call r8                         ; EAX = node, RBX = record, RCX = value, RDX = atom
    jmp .ours
.style:
    cmp rdx, [atom_d_cssText]
    je .css_text
    mov rbx, rcx                    ; the value
    call jsd_style_name
    call jsd_style_put
    jmp .ours
.css_text:
    lea rsi, [jsd_str_style]
    call jsd_set_attr_value
    jmp .ours
.class_list:
    cmp rdx, [atom_d_value]
    jne .not_ours
    lea rsi, [jsd_str_class]
    call jsd_set_attr_value
    jmp .ours
.location:
    cmp rdx, [atom_d_href]
    jne .ours                       ; other parts: ignored
    mov rax, rcx
    call jsd_navigate
.ours:
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
    clc
    ret
.not_ours:
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
    stc
    ret

; --- getters: EAX = node, RBX = record, RDX = atom, RDI = object -> RAX -------

jsd_g_node_type:
    mov eax, 9                      ; the document
    cmp rbx, DOM_ADDR
    je .number
    mov eax, 8
    test byte [rbx + N_FLAGS], NF_COMMENT
    jnz .number
    mov eax, 11
    test byte [rbx + N_FLAGS], NF_FRAGMENT
    jnz .number
    mov eax, 1
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    je .number
    mov eax, 3
.number:
    jmp jsb_from_int

jsd_g_node_name:
    cmp rbx, DOM_ADDR
    je .document
    test byte [rbx + N_FLAGS], NF_COMMENT
    jnz .comment
    test byte [rbx + N_FLAGS], NF_FRAGMENT
    jnz .fragment
    cmp byte [rbx + N_TYPE], NODE_TEXT
    je .text
    jmp jsd_g_tag_name
.comment:
    lea rsi, [jsd_str_comment_name]
    jmp jsb_cstr
.fragment:
    lea rsi, [jsd_str_fragment_name]
    jmp jsb_cstr
.document:
    lea rsi, [jsd_str_document_name]
    jmp jsb_cstr
.text:
    lea rsi, [jsd_str_text_name]
    jmp jsb_cstr

; tagName: the name in upper case
jsd_g_tag_name:
    cmp rbx, DOM_ADDR
    je .none
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    jne .none
    call jsd_bld_reset
    mov rsi, [rbx + N_NAME]
    mov ecx, [rbx + N_NAME_LEN]
.char:
    test ecx, ecx
    jz .done
    lodsb
    cmp al, 'a'
    jb .put
    cmp al, 'z'
    ja .put
    sub al, 32
.put:
    call jsd_bld_byte
    dec ecx
    jmp .char
.done:
    jmp jsd_bld_value
.none:
    mov rax, JS_UNDEF
    ret

jsd_g_node_value:
    cmp byte [rbx + N_TYPE], NODE_TEXT
    jne .null
    call jsd_bld_reset
    call jsd_text_node_text
    jmp jsd_bld_value
.null:
    mov rax, JS_NULL
    ret

jsd_g_text_content:
    test eax, eax
    jz .null                        ; the document
    call jsd_bld_reset
    call jsd_text_of
    jmp jsd_bld_value
.null:
    mov rax, JS_NULL
    ret

jsd_g_inner_html:
    call jsd_bld_reset
    call jsd_serialize_children
    jmp jsd_bld_value

jsd_g_outer_html:
    call jsd_bld_reset
    call jsd_serialize
    jmp jsd_bld_value

; id, className, href, src, name, type, alt, ...: the attribute, or ""
jsd_g_attr:
    call jsd_attr_name_of
    call jsd_get_attr
    jnc .ret
    mov rax, [atom_empty]
    jmp jsb_box_string
.ret:
    ret

; jsd_attr_name_of: RDX = property atom -> RSI = attribute name
jsd_attr_name_of:
    lea rsi, [jsd_str_class]
    cmp rdx, [atom_d_className]
    je .ret
    lea rsi, [rdx + JSTR_DATA]      ; the others are spelled the same
.ret:
    ret

jsd_g_title:
    test eax, eax
    jnz jsd_g_attr
    ; the window title without the "CyberSurf - " in front
    lea rsi, [browser_page_title]
    lea rdi, [STR_TITLE_PREFIX]
    call str_has_prefix
    jne .whole
    push rax
    lea rsi, [STR_TITLE_PREFIX]
    call strlen
    lea rsi, [browser_page_title + rax]
    pop rax
.whole:
    jmp jsb_cstr

jsd_g_value:
    ; a form control: what the user typed (forms.asm)
    push rcx
    push rdx
    push rsi
    call form_kind
    test ecx, ecx
    jz .attr
    cmp ecx, FK_SELECT
    jne .control
    call form_option
    xor ecx, ecx
    test edx, edx
    jz .string
    mov eax, edx
    call form_option_value
    jmp .string
.control:
    call form_value
.string:
    call jsstr_new
    pop rsi
    pop rdx
    pop rcx
    jmp jsb_box_string
.attr:
    pop rsi
    pop rdx
    pop rcx
    lea rsi, [jsd_str_value]
    call jsd_get_attr
    jnc .ret
    mov rax, [atom_empty]
    jmp jsb_box_string
.ret:
    ret

; checked: ticked by the user or a script (forms.asm), else checked=""
jsd_g_checked:
    push rcx
    call form_kind
    cmp ecx, FK_CHECKBOX
    je .control
    cmp ecx, FK_RADIO
    pop rcx
    jne jsd_g_bool_attr
    push rcx
.control:
    pop rcx
    call form_checked
    jmp js_bool

jsd_g_bool_attr:
    lea rsi, [rdx + JSTR_DATA]
    push rdi
    mov rdi, rsi
    call dom_attr
    pop rdi
    cmc
    jmp js_bool

jsd_g_parent_node:
    test eax, eax
    jz .null
    call dom_connected
    mov eax, [rbx + N_PARENT]
    jc jsd_wrap                     ; connected: parent 0 is the document
    test eax, eax
    jnz jsd_wrap
.null:
    mov rax, JS_NULL
    ret

jsd_g_parent_element:
    mov eax, [rbx + N_PARENT]
    test eax, eax
    jz .null
    jmp jsd_wrap
.null:
    mov rax, JS_NULL
    ret

; jsd_wrap_nz: EAX = node or 0 (none) -> its object or null
jsd_wrap_nz:
    test eax, eax
    jnz jsd_wrap
    mov rax, JS_NULL
    ret

jsd_g_first_child:
    mov eax, [rbx + N_FIRST]
    jmp jsd_wrap_nz

jsd_g_last_child:
    mov eax, [rbx + N_LAST]
    jmp jsd_wrap_nz

jsd_g_next_sibling:
    mov eax, [rbx + N_NEXT]
    jmp jsd_wrap_nz

jsd_g_previous_sibling:
    call jsd_previous
    jmp jsd_wrap_nz

; jsd_previous: EAX = node -> EAX = its previous sibling, 0 if none
jsd_previous:
    push rbx
    push rdx
    mov edx, eax
    call dom_node
    mov eax, [rbx + N_PARENT]
    call dom_node
    mov eax, [rbx + N_FIRST]
    xor ecx, ecx
.scan:
    test eax, eax
    jz .none
    cmp eax, edx
    je .found
    mov ecx, eax
    call dom_node
    mov eax, [rbx + N_NEXT]
    jmp .scan
.found:
    mov eax, ecx
    jmp .out
.none:
    xor eax, eax
.out:
    pop rdx
    pop rbx
    ret

; jsd_element_from: EAX = node or 0 -> EAX = it or the next element sibling
jsd_element_from:
    push rbx
.check:
    test eax, eax
    jz .out
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    je .out
    mov eax, [rbx + N_NEXT]
    jmp .check
.out:
    pop rbx
    ret

jsd_g_first_element_child:
    mov eax, [rbx + N_FIRST]
    call jsd_element_from
    jmp jsd_wrap_nz

jsd_g_next_element_sibling:
    mov eax, [rbx + N_NEXT]
    call jsd_element_from
    jmp jsd_wrap_nz

jsd_g_last_element_child:
    mov eax, [rbx + N_FIRST]
    xor ecx, ecx
.scan:
    call jsd_element_from
    test eax, eax
    jz .done
    mov ecx, eax
    call dom_node
    mov eax, [rbx + N_NEXT]
    jmp .scan
.done:
    mov eax, ecx
    jmp jsd_wrap_nz

jsd_g_previous_element_sibling:
    push rcx
.back:
    call jsd_previous
    test eax, eax
    jz .done
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    jne .back
.done:
    pop rcx
    jmp jsd_wrap_nz

jsd_g_children:
    mov cl, 1
    jmp jsd_child_array
jsd_g_child_nodes:
    xor ecx, ecx
; jsd_child_array: EAX = node, CL = 1 for elements only -> RAX = array
jsd_child_array:
    push rcx
    push r8
    mov r8d, ecx
    push rcx
    xor ecx, ecx
    call jsarr_new
    pop rcx
    xchg rax, r8                    ; R8 = array, EAX = node
    mov eax, [rbx + N_FIRST]
.child:
    test eax, eax
    jz .done
    call dom_node
    test cl, cl
    jz .take
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    jne .next
.take:
    call jsd_collect
.next:
    mov eax, [rbx + N_NEXT]
    jmp .child
.done:
    mov rax, r8
    BOX rax, rcx, JS_OBJ_BITS
    pop r8
    pop rcx
    ret

jsd_g_child_element_count:
    xor ecx, ecx
    mov eax, [rbx + N_FIRST]
.count:
    call jsd_element_from
    test eax, eax
    jz .done
    inc ecx
    call dom_node
    mov eax, [rbx + N_NEXT]
    jmp .count
.done:
    mov eax, ecx
    jmp jsb_from_int

; style / classList: one object each, kept on the node's object
jsd_g_style:
    mov ecx, JC_STYLE
    mov r8, [jsd_style_proto]
    mov r9, [atom_d_style_obj]
    jmp jsd_sub_object
jsd_g_class_list:
    mov ecx, JC_CLASSLIST
    mov r8, [jsd_classlist_proto]
    mov r9, [atom_d_classlist_obj]
; jsd_sub_object: EAX = node, RDI = its object, ECX = class, R8 = prototype,
; R9 = hidden atom to keep it in -> RAX = the object
jsd_sub_object:
    push rax
    mov rax, rdi
    mov edx, r9d
    push rbx
    call jsobj_find_own
    jc .make
    mov rax, [rbx + JPE_VAL]
    pop rbx
    add rsp, 8
    ret
.make:
    pop rbx
    pop rax
    mov rdx, r8
    call jsd_host_new
    BOX rax, rdx, JS_OBJ_BITS
    push rcx
    mov rcx, rax
    push rax
    mov rax, rdi
    mov edx, r9d
    call jsobj_define_hidden
    pop rax
    pop rcx
    ret

jsd_g_is_connected:
    call dom_connected
    jmp js_bool

jsd_g_owner_document:
    xor eax, eax
    jmp jsd_wrap

jsd_g_body:
    mov edx, TAGID_BODY
    jmp jsd_document_part
jsd_g_head:
    mov edx, TAGID_HEAD
    jmp jsd_document_part
jsd_g_document_element:
    mov edx, TAGID_HTML
; jsd_document_part: EAX = node (the document), EDX = tag -> the first such
; element, or null
jsd_document_part:
    test eax, eax
    jnz .undefined
    call jsd_find_tag
    jc .null
    ; while the page loads, a script before <body> does not see it yet
    ; (parsed nodes are numbered in document order)
    cmp byte [jsd_loading], 0
    je .wrap
    cmp edx, TAGID_BODY
    jne .wrap
    cmp eax, [jsd_script_node]
    ja .null
.wrap:
    jmp jsd_wrap
.null:
    mov rax, JS_NULL
    ret
.undefined:
    mov rax, JS_UNDEF
    ret

jsd_g_ready_state:
    lea rsi, [jsd_str_complete]
    cmp byte [jsd_loading], 0
    je .str
    lea rsi, [jsd_str_loading]
.str:
    jmp jsb_cstr

; document.cookie: the page's cookies (cookie.asm), not the HttpOnly ones
jsd_g_cookie:
    push rcx
    push rsi
    call cookie_page_get
    call jsstr_new
    pop rsi
    pop rcx
    jmp jsb_box_string

; document.cookie = "name=value; path=/": one cookie set (or deleted)
jsd_s_cookie:
    push rax
    push rcx
    push rsi
    mov rax, rcx
    call js_to_string
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    call cookie_page_set
    pop rsi
    pop rcx
    pop rax
    ret

jsd_g_url:
    lea rsi, [browser_page_url]
    jmp jsb_cstr

jsd_g_location:
    mov rax, [js_global]
    mov rdx, [atom_d_location]
    push rbx
    call jsobj_find_own
    mov rax, JS_UNDEF
    jc .out
    mov rax, [rbx + JPE_VAL]
.out:
    pop rbx
    ret

; --- setters: EAX = node, RBX = record, RCX = value, RDX = atom ------------------

jsd_s_node_value:
    cmp byte [rbx + N_TYPE], NODE_TEXT
    jne .ret
    jmp jsd_set_text
.ret:
    ret

jsd_s_text_content:
    test eax, eax
    jz .ret
    jmp jsd_set_text
.ret:
    ret

jsd_s_inner_html:
    call jsd_clear_children
    push rax
    mov rax, rcx
    call js_to_string
    lea rsi, [rax + JSTR_DATA]
    pop rax
    call dom_parse_into
    mov byte [jsd_dirty], 1
    ret

jsd_s_attr:
    call jsd_attr_name_of
    jmp jsd_set_attr_value

jsd_s_title:
    test eax, eax
    jnz jsd_s_attr
    mov rax, rcx
    call js_to_string
    call jsd_bld_reset
    lea rsi, [STR_TITLE_PREFIX]
    call jsd_bld_cstr
    call jsd_bld_str
    xor eax, eax
    call jsd_bld_byte
    mov rsi, JSD_BLD
    lea rdi, [browser_page_title]
    mov ecx, 64
    call strlcpy
    lea rsi, [klog_browser]
    call klog2
    mov byte [gui_dirty], 1
    ret

jsd_s_value:
    ; a field you type into keeps it like typed text (forms.asm)
    push rax
    push rcx
    push rdx
    push rsi
    mov rdx, rcx                    ; RDX = the value
    call form_kind
    call form_is_text
    jne .attr
    push rax
    mov rax, rdx
    call js_to_string
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    pop rax
    call form_set_value
    jc .attr
    mov byte [jsd_dirty], 1
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
.attr:
    pop rsi
    pop rdx
    pop rcx
    pop rax
    cmp byte [rbx + N_TAG], TAGID_TEXTAREA
    je jsd_set_text
    lea rsi, [jsd_str_value]
    jmp jsd_set_attr_value

jsd_s_checked:
    push rcx
    push rdx
    push rcx
    call form_kind
    mov edx, ecx                    ; EDX = kind
    pop rcx                         ; RCX = the value
    cmp edx, FK_CHECKBOX
    je .control
    cmp edx, FK_RADIO
    je .control
    pop rdx
    pop rcx
    jmp jsd_s_bool_attr
.control:
    push rax
    mov rax, rcx
    call js_truthy
    pop rax
    setc cl                         ; CL = ticked
    cmp edx, FK_RADIO
    jne .set
    test cl, cl
    jz .set                         ; unticking a radio button touches no other
    call form_radio_pick
    jmp .done
.set:
    mov dl, cl
    call form_set_checked
.done:
    mov byte [jsd_dirty], 1
    pop rdx
    pop rcx
    ret

jsd_s_bool_attr:
    lea rsi, [rdx + JSTR_DATA]
    push rax
    mov rax, rcx
    call js_truthy
    pop rax
    jnc jsd_remove_attr_named
    mov rcx, [atom_empty]
    BOX rcx, rdx, JS_STR_BITS
    jmp jsd_set_attr_value

jsd_s_style:
    lea rsi, [jsd_str_style]
    jmp jsd_set_attr_value

jsd_s_location:
    mov rax, rcx
    jmp jsd_navigate

jsd_s_ignore:
    ret

; ==============================================================================
; element.style
; ==============================================================================

; jsd_style_name: RDX = atom (backgroundColor) -> RSI = jsd_name_buf with the
; CSS name (background-color), ECX = its length
jsd_style_name:
    push rax
    push rdi
    push r8
    mov ecx, [rdx + JSTR_LEN]
    lea rsi, [rdx + JSTR_DATA]
    lea rdi, [jsd_name_buf]
    lea r8, [rdi + 120]
.char:
    test ecx, ecx
    jz .done
    cmp rdi, r8
    jae .done
    lodsb
    cmp al, 'A'
    jb .put
    cmp al, 'Z'
    ja .put
    push rax
    mov al, '-'
    stosb
    pop rax
    or al, 0x20
.put:
    stosb
    dec ecx
    jmp .char
.done:
    mov byte [rdi], 0
    lea rsi, [jsd_name_buf]
    mov rcx, rdi
    sub rcx, rsi
    ; cssFloat -> float
    cmp ecx, 9
    jne .out
    cmp dword [rsi], 'css-'
    jne .out
    add rsi, 4
    sub ecx, 4
.out:
    pop r8
    pop rdi
    pop rax
    ret

; jsd_style_decls: EAX = element -> R10 = inline style text, R11 = its end
jsd_style_decls:
    push rbx
    call dom_node
    mov r10, [rbx + N_STYLE]
    mov r11d, [rbx + N_STYLE_LEN]
    add r11, r10
    pop rbx
    ret

; jsd_decl_next: R10 = in style text, R11 = end -> RDI/R8D = property name,
; R9/EDX = value (trimmed), R10 after the declaration; CF=1 at the end
jsd_decl_next:
    push rax
.skip:
    cmp r10, r11
    jae .none
    mov al, [r10]
    cmp al, ' '
    jbe .skip_one
    cmp al, ';'
    jne .name
.skip_one:
    inc r10
    jmp .skip
.name:
    mov rdi, r10
.name_char:
    cmp r10, r11
    jae .no_value
    mov al, [r10]
    cmp al, ':'
    je .name_end
    cmp al, ';'
    je .no_value
    inc r10
    jmp .name_char
.no_value:
    mov r8, r10
    sub r8, rdi
    mov r9, r10
    xor edx, edx
    jmp .trim_name
.name_end:
    mov r8, r10
    sub r8, rdi
    inc r10
.value_lead:
    cmp r10, r11
    jae .value_start
    cmp byte [r10], ' '
    ja .value_start
    inc r10
    jmp .value_lead
.value_start:
    mov r9, r10
.value_char:
    cmp r10, r11
    jae .value_end
    cmp byte [r10], ';'
    je .value_end
    inc r10
    jmp .value_char
.value_end:
    mov rdx, r10
    sub rdx, r9
.value_trim:
    test edx, edx
    jz .trim_name
    cmp byte [r9 + rdx - 1], ' '
    ja .trim_name
    dec edx
    jmp .value_trim
.trim_name:
    test r8d, r8d
    jz .ok
    cmp byte [rdi + r8 - 1], ' '
    ja .ok
    dec r8d
    jmp .trim_name
.ok:
    pop rax
    clc
    ret
.none:
    pop rax
    stc
    ret

; jsd_name_equal: RDI/R8D vs RSI/ECX, ignoring case -> ZF=1 if equal
jsd_name_equal:
    cmp r8d, ecx
    jne .ret
    push rax
    push rcx
    push rsi
    push rdi
.char:
    test ecx, ecx
    jz .equal
    mov al, [rdi]
    or al, 0x20
    mov ah, [rsi]
    or ah, 0x20
    cmp al, ah
    jne .differ
    inc rsi
    inc rdi
    dec ecx
    jmp .char
.equal:
    xor eax, eax                    ; ZF=1
.differ:
    pop rdi
    pop rsi
    pop rcx
    pop rax
.ret:
    ret

; jsd_style_value: EAX = element, RSI/ECX = CSS property name -> RAX = its
; value in style="" as a string value ("" if not set)
jsd_style_value:
    push rdx
    push rdi
    push r8
    push r9
    push r10
    push r11
    call jsd_style_decls
.decl:
    call jsd_decl_next
    jc .none
    call jsd_name_equal
    jne .decl
    push rsi
    push rcx
    mov rsi, r9
    mov ecx, edx
    call jsstr_new
    pop rcx
    pop rsi
    jmp .out
.none:
    mov rax, [atom_empty]
.out:
    call jsb_box_string
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    ret

; jsd_style_put: EAX = element, RSI/ECX = CSS property name, RBX = the value
; (any JS value; "" or null removes it) -> style="" rewritten
jsd_style_put:
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
    push r12
    push rax
    mov rax, rbx
    mov rbx, JS_NULL
    cmp rax, rbx
    jne .string
    mov rax, [atom_empty]
    jmp .have
.string:
    call js_to_string
.have:
    mov r12, rax                    ; the new value (heap string)
    pop rax
    call jsd_bld_reset
    call jsd_style_decls
.decl:
    call jsd_decl_next
    jc .others_done
    call jsd_name_equal
    je .decl
    push rsi
    push rcx
    mov rsi, rdi
    mov ecx, r8d
    call jsd_bld_bytes
    push rax
    mov al, ':'
    call jsd_bld_byte
    mov al, ' '
    call jsd_bld_byte
    pop rax
    mov rsi, r9
    mov ecx, edx
    call jsd_bld_bytes
    push rax
    mov al, ';'
    call jsd_bld_byte
    mov al, ' '
    call jsd_bld_byte
    pop rax
    pop rcx
    pop rsi
    jmp .decl
.others_done:
    cmp dword [r12 + JSTR_LEN], 0
    je .store
    call jsd_bld_bytes              ; name
    push rax
    mov al, ':'
    call jsd_bld_byte
    mov al, ' '
    call jsd_bld_byte
    mov rax, r12
    call jsd_bld_str
    pop rax
.store:
    push rax
    call jsd_bld_take
    mov rdx, rax
    pop rax
    lea rsi, [jsd_str_style]
    mov ecx, 5
    call jsd_set_attr
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
    pop rax
    ret

; style.getPropertyValue(name)
jsd_style_get_property:
    push rcx
    push rsi
    call jsd_this_host
    push rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    call jsd_lower_name
    pop rax
    call jsd_style_value
    pop rsi
    pop rcx
    ret

; style.setProperty(name, value)
jsd_style_set_property:
    push rbx
    push rcx
    push rsi
    call jsd_this_host
    push rax
    mov eax, 1
    call jsb_arg
    mov rbx, rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    call jsd_lower_name
    pop rax
    call jsd_style_put
    mov rax, JS_UNDEF
    pop rsi
    pop rcx
    pop rbx
    ret

; style.removeProperty(name)
jsd_style_remove_property:
    push rbx
    push rcx
    push rsi
    call jsd_this_host
    push rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    call jsd_lower_name
    pop rax
    mov rbx, JS_NULL
    call jsd_style_put
    mov rax, JS_UNDEF
    pop rsi
    pop rcx
    pop rbx
    ret

; ==============================================================================
; element.classList
; ==============================================================================

; jsd_class_text: EAX = element -> RSI/ECX = its class attribute (ECX = 0 if none)
jsd_class_text:
    push rdi
    lea rdi, [jsd_str_class]
    call dom_attr
    jnc .ret
    xor ecx, ecx
.ret:
    pop rdi
    ret

; jsd_class_has: RSI/ECX = class list text, RAX = token (heap string)
; -> CF=1 if the token is in it
jsd_class_has:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    lea r8, [rsi + rcx]
.token:
    cmp rsi, r8
    jae .no
    cmp byte [rsi], ' '
    ja .word
    inc rsi
    jmp .token
.word:
    mov rdi, rsi
.word_char:
    cmp rsi, r8
    jae .word_end
    cmp byte [rsi], ' '
    jbe .word_end
    inc rsi
    jmp .word_char
.word_end:
    mov rcx, rsi
    sub rcx, rdi
    cmp ecx, [rax + JSTR_LEN]
    jne .token
    push rsi
    lea rsi, [rax + JSTR_DATA]
    repe cmpsb
    pop rsi
    jne .token
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    stc
    ret
.no:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    clc
    ret

; jsd_class_edit: EAX = element, RDX = token to drop (heap string, or 0),
; R8 = token to add (heap string, or 0) -> class="" rewritten
jsd_class_edit:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    mov r9, rax
    call jsd_bld_reset
    call jsd_class_text
    lea rbx, [rsi + rcx]            ; end
.token:
    cmp rsi, rbx
    jae .tokens_done
    cmp byte [rsi], ' '
    ja .word
    inc rsi
    jmp .token
.word:
    mov rdi, rsi
.word_char:
    cmp rsi, rbx
    jae .word_end
    cmp byte [rsi], ' '
    jbe .word_end
    inc rsi
    jmp .word_char
.word_end:
    mov rcx, rsi
    sub rcx, rdi
    ; dropped?
    test rdx, rdx
    jz .keep
    cmp ecx, [rdx + JSTR_LEN]
    jne .keep
    push rsi
    push rdi
    push rcx
    lea rsi, [rdx + JSTR_DATA]
    repe cmpsb
    pop rcx
    pop rdi
    pop rsi
    je .token
.keep:
    cmp dword [jsd_bld_len], 0
    je .first
    mov al, ' '
    call jsd_bld_byte
.first:
    push rsi
    mov rsi, rdi
    call jsd_bld_bytes
    pop rsi
    jmp .token
.tokens_done:
    test r8, r8
    jz .store
    cmp dword [jsd_bld_len], 0
    je .add
    mov al, ' '
    call jsd_bld_byte
.add:
    mov rax, r8
    call jsd_bld_str
.store:
    call jsd_bld_take
    mov rdx, rax
    mov rax, r9
    lea rsi, [jsd_str_class]
    mov ecx, 5
    call jsd_set_attr
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; classList.contains(token)
jsd_classlist_contains:
    push rcx
    push rsi
    call jsd_this_host
    push rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov rdx, rax
    pop rax
    call jsd_class_text
    mov rax, rdx
    call jsd_class_has
    call js_bool
    pop rsi
    pop rcx
    ret

; classList.add(...tokens)
jsd_classlist_add:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r9d, ecx
    mov rbx, rdi
    call jsd_this_host
    mov edi, eax                    ; the element
.token:
    test r9d, r9d
    jz .done
    mov rax, [rbx]
    call js_to_string
    mov r8, rax
    mov eax, edi
    call jsd_class_text
    mov rax, r8
    call jsd_class_has
    jc .next
    mov eax, edi
    xor edx, edx
    call jsd_class_edit
.next:
    add rbx, 8
    dec r9d
    jmp .token
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

; classList.remove(...tokens)
jsd_classlist_remove:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r9d, ecx
    mov rbx, rdi
    call jsd_this_host
    mov edi, eax
.token:
    test r9d, r9d
    jz .done
    mov rax, [rbx]
    call js_to_string
    mov rdx, rax
    mov eax, edi
    xor r8d, r8d
    call jsd_class_edit
    add rbx, 8
    dec r9d
    jmp .token
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

; classList.toggle(token [, force]) -> whether it is there afterwards
jsd_classlist_toggle:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    call jsd_this_host
    mov r9d, eax                    ; the element
    mov ebx, ecx                    ; argument count
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov r8, rax                     ; the token
    mov eax, r9d
    call jsd_class_text
    mov rax, r8
    call jsd_class_has
    setc dl                         ; DL = there now
    ; force?
    cmp ebx, 2
    jb .flip
    mov ecx, ebx
    mov eax, 1
    call jsb_arg
    call js_truthy
    setc al
    cmp al, dl
    je .same
    mov dl, al
    xor dl, 1                       ; so that .flip makes it AL
.flip:
    test dl, dl
    jz .add
    ; remove
    mov eax, r9d
    mov rdx, r8
    xor r8d, r8d
    call jsd_class_edit
    clc
    jmp .result
.add:
    mov eax, r9d
    xor edx, edx
    call jsd_class_edit
    stc
    jmp .result
.same:
    mov al, dl
    shr al, 1                       ; CF = DL
.result:
    call js_bool
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ==============================================================================
; location
; ==============================================================================

; jsd_url_split: browser_page_url -> the jsd_url_* offsets
jsd_url_split:
    push rax
    push rcx
    push rdx
    push rsi
    lea rsi, [browser_page_url]
    call strlen
    mov [jsd_url_len], eax
    mov ecx, eax
    ; protocol: up to the first ':'
    xor eax, eax
.proto:
    cmp eax, ecx
    jae .no_proto
    cmp byte [rsi + rax], ':'
    je .proto_found
    inc eax
    jmp .proto
.no_proto:
    xor eax, eax
    mov [jsd_url_proto_end], eax
    jmp .host
.proto_found:
    inc eax
    mov [jsd_url_proto_end], eax
.host:
    ; "//host"
    lea edx, [eax + 2]
    cmp edx, ecx
    ja .no_host
    cmp word [rsi + rax], '//'
    jne .no_host
    add eax, 2
    mov [jsd_url_host_start], eax
.host_char:
    cmp eax, ecx
    jae .host_end
    mov dl, [rsi + rax]
    cmp dl, '/'
    je .host_end
    cmp dl, '?'
    je .host_end
    cmp dl, '#'
    je .host_end
    inc eax
    jmp .host_char
.no_host:
    mov [jsd_url_host_start], eax
.host_end:
    mov [jsd_url_host_end], eax
.path:
    cmp eax, ecx
    jae .path_end
    mov dl, [rsi + rax]
    cmp dl, '?'
    je .path_end
    cmp dl, '#'
    je .path_end
    inc eax
    jmp .path
.path_end:
    mov [jsd_url_path_end], eax
.search:
    cmp eax, ecx
    jae .search_end
    cmp byte [rsi + rax], '#'
    je .search_end
    inc eax
    jmp .search
.search_end:
    mov [jsd_url_search_end], eax
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsd_url_piece: EAX = start, ECX = end -> RAX = that part of the URL
jsd_url_piece:
    push rcx
    push rsi
    sub ecx, eax
    jg .piece
    xor ecx, ecx
.piece:
    lea rsi, [browser_page_url]
    add rsi, rax
    call jsstr_new
    call jsb_box_string
    pop rsi
    pop rcx
    ret

; jsd_location_get: RDX = atom -> RAX = value, CF=1 if not a location part
jsd_location_get:
    call jsd_url_split
    xor eax, eax
    mov ecx, [jsd_url_len]
    cmp rdx, [atom_d_href]
    je .piece
    mov ecx, [jsd_url_proto_end]
    cmp rdx, [atom_d_protocol]
    je .piece
    mov eax, [jsd_url_host_start]
    mov ecx, [jsd_url_host_end]
    cmp rdx, [atom_d_host]
    je .piece
    cmp rdx, [atom_d_hostname]
    je .hostname
    mov eax, [jsd_url_host_end]
    mov ecx, [jsd_url_path_end]
    cmp rdx, [atom_d_pathname]
    je .pathname
    mov eax, [jsd_url_path_end]
    mov ecx, [jsd_url_search_end]
    cmp rdx, [atom_d_search]
    je .piece
    mov eax, [jsd_url_search_end]
    mov ecx, [jsd_url_len]
    cmp rdx, [atom_d_hash]
    je .piece
    xor eax, eax
    mov ecx, [jsd_url_host_end]
    cmp rdx, [atom_d_origin]
    je .piece
    stc
    ret
.hostname:
    ; without :port
    push rsi
    lea rsi, [browser_page_url]
    push rax
.colon:
    cmp eax, ecx
    jae .colon_done
    cmp byte [rsi + rax], ':'
    je .colon_found
    inc eax
    jmp .colon
.colon_found:
    mov ecx, eax
.colon_done:
    pop rax
    pop rsi
    jmp .piece
.pathname:
    cmp eax, ecx
    jne .piece
    push rsi                        ; no path: "/"
    lea rsi, [jsd_str_slash]
    call jsb_cstr
    pop rsi
    clc
    ret
.piece:
    call jsd_url_piece
    clc
    ret

; jsd_navigate: RAX = URL value -> resolved against the page and loaded after
; the script (jsd_nav_pending)
jsd_navigate:
    push rax
    push rcx
    push rsi
    push rdi
    call js_to_string
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    call browser_resolve_link
    jc .done
    mov rsi, [browser_resolved]
    lea rdi, [browser_url_buf]
    mov ecx, BROWSER_URL_MAX
    call strlcpy
    mov byte [jsd_nav_pending], 1
    mov byte [form_post_pending], 0 ; (after form.submit(): this one wins)
    push rsi
    lea rsi, [jsd_klog_nav]
    lea rdi, [browser_url_buf]
    call klog2
    pop rsi
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; location.reload()
jsd_location_reload:
    push rcx
    push rsi
    push rdi
    lea rsi, [browser_page_url]
    lea rdi, [browser_url_buf]
    mov ecx, BROWSER_URL_MAX
    call strlcpy
    mov byte [jsd_nav_pending], 1
    mov rax, JS_UNDEF
    pop rdi
    pop rsi
    pop rcx
    ret

; location.assign(url) / location.replace(url)
jsd_location_assign:
    xor eax, eax
    call jsb_arg
    call jsd_navigate
    mov rax, JS_UNDEF
    ret

; location.toString()
jsd_location_to_string:
    push rsi
    lea rsi, [browser_page_url]
    call jsb_cstr
    pop rsi
    ret

; ==============================================================================
; Methods
; ==============================================================================

; document.getElementById(id)
jsd_get_element_by_id:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    xor eax, eax
    call jsb_arg
    call js_to_string
    mov r8, rax                     ; the id
    mov ecx, [r8 + JSTR_LEN]
    lea rsi, [r8 + JSTR_DATA]
    call dom_hash
    mov r9d, eax
    xor eax, eax
    xor edx, edx                    ; the whole document
.next:
    call jsd_next
    test eax, eax
    jz .none
    call dom_node
    cmp [rbx + N_IDH], r9d
    jne .next
    ; the hash matches: compare the text too (ids are case-sensitive)
    push rax
    lea rsi, [jsd_str_id]
    call jsd_get_attr
    mov rdx, rax
    mov rax, r8
    BOX rax, rcx, JS_STR_BITS
    call js_strict_equal
    pop rax
    mov edx, 0
    jnc .next
    call jsd_wrap
    jmp .out
.none:
    mov rax, JS_NULL
.out:
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; querySelector(selectors) / querySelectorAll(selectors)
jsd_query_selector:
    push r9
    xor r9d, r9d
    jmp jsd_query
jsd_query_selector_all:
    push r9
    mov r9d, 1
; jsd_query: R9D = 1 for all matches (array), 0 for the first (or null)
jsd_query:
    push rbx
    push rcx
    push rdx
    push r8
    call jsd_this_node
    push rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    call jsd_compile_selectors
    cmp byte [jsd_sel_bad], 0
    jne jsd_bad_selector
    xor ecx, ecx
    call jsarr_new
    mov r8, rax
    pop rax
    mov edx, eax                    ; root
.next:
    call jsd_next
    test eax, eax
    jz .done
    call jsd_selector_match
    jc .next
    call jsd_collect
    test r9d, r9d
    jnz .next
.done:
    test r9d, r9d
    jnz .array
    cmp dword [r8 + JARR_LEN], 0
    je .null
    mov rax, [r8 + JARR_ELEMS]
    mov rax, [rax]
    jmp .out
.null:
    mov rax, JS_NULL
    jmp .out
.array:
    mov rax, r8
    BOX rax, rdx, JS_OBJ_BITS
.out:
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop r9
    ret

; getElementsByTagName(name)
jsd_get_by_tag:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    call jsd_this_node
    push rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    xor r9d, r9d                    ; 0 = any ("*")
    cmp dword [rax + JSTR_LEN], 1
    jne .hash
    cmp byte [rax + JSTR_DATA], '*'
    je .hashed
.hash:
    mov ecx, [rax + JSTR_LEN]
    lea rsi, [rax + JSTR_DATA]
    call dom_hash
    mov r9d, eax
.hashed:
    xor ecx, ecx
    call jsarr_new
    mov r8, rax
    pop rax
    mov edx, eax
.next:
    call jsd_next
    test eax, eax
    jz .done
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    jne .next
    test r9d, r9d
    jz .take
    cmp [rbx + N_TAGH], r9d
    jne .next
.take:
    call jsd_collect
    jmp .next
.done:
    mov rax, r8
    BOX rax, rdx, JS_OBJ_BITS
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; getElementsByClassName(names): elements with every one of the classes
jsd_get_by_class:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    call jsd_this_node
    push rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    ; the class names' hashes, up to 6, at jsd_name_buf
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    lea r10, [rsi + rcx]
    xor r9d, r9d                    ; count
    lea rdi, [jsd_name_buf]
.word:
    cmp rsi, r10
    jae .words_done
    cmp byte [rsi], ' '
    ja .word_start
    inc rsi
    jmp .word
.word_start:
    mov rdx, rsi
.word_char:
    cmp rsi, r10
    jae .word_end
    cmp byte [rsi], ' '
    jbe .word_end
    inc rsi
    jmp .word_char
.word_end:
    cmp r9d, 6
    jae .word
    push rsi
    mov rcx, rsi
    sub rcx, rdx
    mov rsi, rdx
    call dom_hash
    pop rsi
    mov [rdi + r9*4], eax
    inc r9d
    jmp .word
.words_done:
    xor ecx, ecx
    call jsarr_new
    mov r8, rax
    pop rax
    mov edx, eax
    test r9d, r9d
    jz .done                        ; no names: nothing
.next:
    call jsd_next
    test eax, eax
    jz .done
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    jne .next
    xor ecx, ecx
.want:
    cmp ecx, r9d
    jae .take
    mov esi, [rdi + rcx*4]
    push rcx
    xor ecx, ecx
.have:
    cmp cl, [rbx + N_NCLS]
    jae .missing
    cmp esi, [rbx + N_CLSH + rcx*4]
    je .found
    inc ecx
    jmp .have
.missing:
    pop rcx
    jmp .next
.found:
    pop rcx
    inc ecx
    jmp .want
.take:
    call jsd_collect
    jmp .next
.done:
    mov rax, r8
    BOX rax, rdx, JS_OBJ_BITS
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; document.createElement(tag)
jsd_create_element:
    push rbx
    push rcx
    push rsi
    xor eax, eax
    call jsb_arg
    call js_to_string
    call jsd_lower_name
    call jsstr_atom                 ; kept for as long as the node
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    call dom_new_element
    jc .full
    call jsd_wrap
    jmp .out
.full:
    mov rax, JS_NULL
.out:
    pop rsi
    pop rcx
    pop rbx
    ret

; element.getAttributeNames(): the names of its attributes (lower case)
jsd_get_attribute_names:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r12
    push r13
    call jsd_this_node
    push rax
    xor ecx, ecx
    call jsarr_new
    mov r13, rax
    pop rax
    cmp rbx, DOM_ADDR
    je .done
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    jne .done
    mov r12, [rbx + N_ATTRS]
    mov r8d, [rbx + N_ATTRS_LEN]
    add r8, r12
.attr:
    call jsd_attr_next              ; RDI/ECX = its name
    jc .done
    cmp ecx, 120
    ja .attr
    ; in lower case
    push rcx
    mov rsi, rdi
    lea rdi, [jsd_name_buf]
.lower:
    test ecx, ecx
    jz .lowered
    lodsb
    cmp al, 'A'
    jb .put
    cmp al, 'Z'
    ja .put
    or al, 0x20
.put:
    stosb
    dec ecx
    jmp .lower
.lowered:
    pop rcx
    lea rsi, [jsd_name_buf]
    call jsstr_new
    mov rcx, rax
    BOX rcx, rdx, JS_STR_BITS
    mov rax, r13
    call jsarr_push
    jmp .attr
.done:
    mov rax, r13
    BOX rax, rdx, JS_OBJ_BITS
    pop r13
    pop r12
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; target.dispatchEvent(event): an event made by a script, delivered to the
; target's listeners, then (when event.bubbles) its ancestors, the document
; and window -> false if a listener called preventDefault
jsd_dispatch_event:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov rsi, rdx                    ; the target
    xor eax, eax
    call jsb_arg
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .not_event
    mov r8d, eax                    ; the event (raw)
    mov r11, rax                    ; (boxed)
    mov rdx, [atom_d_type]
    call js_get
    call js_to_key
    mov r10, rax                    ; the type atom
    mov rax, r11
    mov rdx, [atom_d_bubbles]
    call js_get
    call js_truthy
    setc bl                         ; BL = 1: bubbles
    ; (a stop from an earlier dispatch of the same event is forgotten)
    mov rax, r8
    mov rdx, [atom_d_stop]
    call jsobj_delete
    mov rax, rsi
    call jsd_node_of
    jc .window
    mov r9d, eax                    ; the target node
    mov rax, r8
    mov rcx, rsi
    mov rdx, [atom_d_target]
    call jsobj_define
    mov eax, r9d
.node:
    push rax
    call jsd_wrap
    call jsd_deliver
    pop rax
    jc .done
    test bl, bl
    jz .done
    test eax, eax
    jz .at_window                   ; the document was last
    push rbx
    call dom_node
    mov eax, [rbx + N_PARENT]
    pop rbx
    test eax, eax
    jnz .node
    ; a top-level node: the document next, if it is in it
    mov eax, r9d
    call dom_connected
    mov eax, 0
    jc .node
    jmp .done
.window:
    mov rax, [js_global]
    BOX rax, rdx, JS_OBJ_BITS
    mov rcx, rax
    mov rax, r8
    mov rdx, [atom_d_target]
    call jsobj_define
.at_window:
    mov rax, [js_global]
    BOX rax, rdx, JS_OBJ_BITS
    call jsd_deliver
.done:
    mov rax, r11
    mov rdx, [atom_d_defaultPrevented]
    call js_get
    call js_truthy
    cmc
    call js_bool
    jmp .out
.not_event:
    mov rax, JS_TRUE
.out:
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

; __currentScript(): the page's <script> running now, or null (the page
; prelude's document.currentScript)
jsd_current_script:
    mov rax, JS_NULL
    cmp byte [jsd_in_script], 0
    je .ret
    mov eax, [jsd_script_node]
    jmp jsd_wrap
.ret:
    ret

; document.createComment(text): a comment (an empty text node that says so)
jsd_create_comment:
    push rbx
    push rcx
    push rsi
    xor eax, eax
    call jsb_arg
    call jsd_encoded_string
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    call dom_new_text
    jc .full
    or byte [rbx + N_FLAGS], NF_COMMENT
    call jsd_wrap
    jmp .out
.full:
    mov rax, JS_NULL
.out:
    pop rsi
    pop rcx
    pop rbx
    ret

; document.createDocumentFragment(): an element that holds nodes until they
; are inserted somewhere (the page prelude moves its children)
jsd_create_fragment:
    push rbx
    push rcx
    push rsi
    lea rsi, [jsd_str_fragment_name]
    mov ecx, jsd_str_fragment_name_len
    call dom_new_element
    jc .full
    or byte [rbx + N_FLAGS], NF_FRAGMENT
    call jsd_wrap
    jmp .out
.full:
    mov rax, JS_NULL
.out:
    pop rsi
    pop rcx
    pop rbx
    ret

; document.createTextNode(text)
jsd_create_text_node:
    push rbx
    push rcx
    push rsi
    xor eax, eax
    call jsb_arg
    call jsd_encoded_string
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    call dom_new_text
    jc .full
    call jsd_wrap
    jmp .out
.full:
    mov rax, JS_NULL
.out:
    pop rsi
    pop rcx
    pop rbx
    ret

; document.write(...html) / writeln(...html): while the page loads, the HTML
; goes in after the running <script>; later, at the end of <body>
jsd_writeln:
    push rbx
    mov bl, 1
    jmp jsd_write_common
jsd_write:
    push rbx
    xor ebx, ebx
jsd_write_common:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    ; the text: every argument, then a newline for writeln
    push rbx
    call jsd_bld_reset
    mov r8d, ecx
    mov rbx, rdi
.arg:
    test r8d, r8d
    jz .args_done
    mov rax, [rbx]
    call js_to_string
    call jsd_bld_str
    add rbx, 8
    dec r8d
    jmp .arg
.args_done:
    pop rbx
    test bl, bl
    jz .text
    mov al, 10
    call jsd_bld_byte
.text:
    call jsd_bld_take
    lea rsi, [rax + JSTR_DATA]
    ; parse it into a scratch <div>, then move the nodes to their place
    push rsi
    lea rsi, [jsd_str_div]
    mov ecx, 3
    call dom_new_element
    pop rsi
    jc .done
    mov r8d, eax                    ; the scratch element
    call dom_parse_into
    ; where to
    mov edx, [jsd_write_parent]
    mov ecx, [jsd_write_before]
    cmp byte [jsd_loading], 0
    jne .move
    xor eax, eax
    mov edx, TAGID_BODY
    call jsd_find_tag
    mov edx, eax
    jnc .at_end
    xor edx, edx
.at_end:
    xor ecx, ecx
.move:
    mov eax, r8d
    call dom_node
    mov eax, [rbx + N_FIRST]
    test eax, eax
    jz .moved
    call dom_insert
    jmp .move
.moved:
    mov byte [jsd_dirty], 1
.done:
    mov rax, JS_UNDEF
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; getAttribute(name)
jsd_get_attribute:
    push rbx
    push rcx
    push rsi
    call jsd_this_node
    push rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    call jsd_lower_name
    pop rax
    call jsd_get_attr
    pop rsi
    pop rcx
    pop rbx
    ret

; setAttribute(name, value)
jsd_set_attribute:
    push rbx
    push rcx
    push rdx
    push rsi
    call jsd_this_node
    cmp byte [rbx + N_TYPE], NODE_ELEMENT
    jne .done
    push rax
    mov eax, 1
    call jsb_arg
    call js_to_string
    mov rdx, rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    call jsd_lower_name
    pop rax
    call jsd_set_attr
.done:
    mov rax, JS_UNDEF
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; removeAttribute(name)
jsd_remove_attribute:
    push rbx
    push rcx
    push rdx
    push rsi
    call jsd_this_node
    push rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    call jsd_lower_name
    pop rax
    xor edx, edx
    call jsd_set_attr
    mov rax, JS_UNDEF
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; hasAttribute(name)
jsd_has_attribute:
    push rbx
    push rcx
    push rsi
    push rdi
    call jsd_this_node
    push rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    call jsd_lower_name
    pop rax
    mov rdi, rsi
    call dom_attr
    cmc
    call js_bool
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; jsd_adopt: EAX = new child, EDX = parent, RSI = method name -> TypeError if
; the child contains the parent
jsd_adopt:
    push rax
    call dom_contains
    pop rax
    jc .bad
    ret
.bad:
    call jsstr_from_cstr
    mov rdi, rax
    lea rsi, [jsmsg_hierarchy]
    jmp js_throw_type

; appendChild(child) -> child
jsd_append_child:
    push rbx
    push rcx
    push rdx
    push rsi
    call jsd_this_node
    mov edx, eax
    xor eax, eax
    lea rsi, [jsd_name_append]
    call jsd_arg_node
    call jsd_adopt
    xor ecx, ecx
    call dom_insert
    mov byte [jsd_dirty], 1
    call jsd_wrap
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; insertBefore(child, reference) -> child (a null reference appends)
jsd_insert_before:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    call jsd_this_node
    mov edx, eax                    ; the parent
    lea rsi, [jsd_name_insert]
    xor r8d, r8d                    ; the reference (0 = none)
    mov eax, 1
    call jsb_arg
    push rdx
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_SPECIAL
    pop rdx
    je .have_ref                    ; null / undefined
    mov eax, 1
    call jsd_arg_node
    mov r8d, eax
.have_ref:
    xor eax, eax
    call jsd_arg_node
    call jsd_adopt
    mov ecx, r8d
    call dom_insert
    mov byte [jsd_dirty], 1
    call jsd_wrap
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; removeChild(child) -> child
jsd_remove_child:
    push rbx
    push rcx
    push rdx
    push rsi
    call jsd_this_node
    mov edx, eax
    xor eax, eax
    lea rsi, [jsd_name_remove]
    call jsd_arg_node
    push rax
    call dom_node
    cmp [rbx + N_PARENT], edx
    pop rax
    jne .not_child
    call dom_detach
    mov byte [jsd_dirty], 1
    call jsd_wrap
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.not_child:
    lea rsi, [jsd_name_remove]
jsd_not_child_error:
    call jsstr_from_cstr
    mov rdi, rax
    lea rsi, [jsmsg_not_child]
    jmp js_throw_type

; replaceChild(new, old) -> old
jsd_replace_child:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    call jsd_this_node
    mov edx, eax
    mov eax, 1
    lea rsi, [jsd_name_replace]
    call jsd_arg_node
    mov r8d, eax                    ; old
    push rax
    call dom_node
    cmp [rbx + N_PARENT], edx
    pop rax
    jne .not_child
    xor eax, eax
    call jsd_arg_node               ; new
    call jsd_adopt
    mov ecx, r8d
    call dom_insert                 ; before the old one
    mov eax, r8d
    call dom_detach
    mov byte [jsd_dirty], 1
    call jsd_wrap
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.not_child:
    lea rsi, [jsd_name_replace]
    jmp jsd_not_child_error

; remove()
jsd_remove:
    push rbx
    call jsd_this_node
    test eax, eax
    jz .done
    call dom_detach
    mov byte [jsd_dirty], 1
.done:
    mov rax, JS_UNDEF
    pop rbx
    ret

; append(...nodes or strings)
jsd_append:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    mov r9, rdi
    mov r8d, ecx
    call jsd_this_node
    mov edx, eax
.arg:
    test r8d, r8d
    jz .done
    mov rax, [r9]
    call jsd_node_of
    jnc .node
    ; a string: a text node
    mov rax, [r9]
    call jsd_encoded_string
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    call dom_new_text
    jc .next
.node:
    lea rsi, [jsd_name_append]
    call jsd_adopt
    xor ecx, ecx
    call dom_insert
.next:
    add r9, 8
    dec r8d
    jmp .arg
.done:
    mov byte [jsd_dirty], 1
    mov rax, JS_UNDEF
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; contains(other)
jsd_contains:
    push rbx
    push rdx
    call jsd_this_node
    push rax
    xor eax, eax
    call jsb_arg
    call jsd_node_of
    mov edx, eax
    pop rax
    jc .no
    call dom_contains
    jmp .out
.no:
    clc
.out:
    call js_bool
    pop rdx
    pop rbx
    ret

; matches(selectors)
jsd_matches:
    push rbx
    call jsd_this_node
    push rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    call jsd_compile_selectors
    cmp byte [jsd_sel_bad], 0
    jne jsd_bad_selector
    pop rax
    call jsd_selector_match
    cmc
    call js_bool
    pop rbx
    ret

; closest(selectors): the element or its nearest ancestor that matches
jsd_closest:
    push rbx
    call jsd_this_node
    push rax
    xor eax, eax
    call jsb_arg
    call js_to_string
    call jsd_compile_selectors
    cmp byte [jsd_sel_bad], 0
    jne jsd_bad_selector
    pop rax
.up:
    test eax, eax
    jz .null
    call jsd_selector_match
    jnc .found
    call dom_node
    mov eax, [rbx + N_PARENT]
    jmp .up
.found:
    call jsd_wrap
    pop rbx
    ret
.null:
    mov rax, JS_NULL
    pop rbx
    ret

; cloneNode(deep)
jsd_clone_node:
    push rbx
    push rdx
    call jsd_this_node
    push rax
    xor eax, eax
    call jsb_arg
    call js_truthy
    setc dl
    pop rax
    call jsd_clone
    jc .full
    call jsd_wrap
    jmp .out
.full:
    mov rax, JS_NULL
.out:
    pop rdx
    pop rbx
    ret

; jsd_clone: EAX = node, DL = 1 for its children too -> EAX = the copy
; (detached), CF=1 if the DOM is full
jsd_clone:
    push rbx
    push rcx
    push rsi
    push rdi
    push r8
    mov r8d, eax
    call dom_new
    jc .out
    mov rdi, rbx
    push rax
    mov eax, r8d
    call dom_node
    mov rsi, rbx
    push rdi
    mov ecx, 88 / 8                 ; everything but the computed style
    rep movsq
    pop rdi
    pop rax
    xor ecx, ecx
    mov [rdi + N_PARENT], ecx
    mov [rdi + N_FIRST], ecx
    mov [rdi + N_LAST], ecx
    mov [rdi + N_NEXT], ecx
    mov [rdi + N_JSOBJ], ecx
    test dl, dl
    jz .done
    ; the children
    mov ecx, eax                    ; the copy
    mov eax, r8d
    call dom_node
    mov eax, [rbx + N_FIRST]
.child:
    test eax, eax
    jz .done_copy
    push rax
    call jsd_clone
    jc .child_full
    push rdx
    mov edx, ecx
    push rcx
    xor ecx, ecx
    call dom_insert
    pop rcx
    pop rdx
.child_full:
    pop rax
    call dom_node
    mov eax, [rbx + N_NEXT]
    jmp .child
.done_copy:
    mov eax, ecx
.done:
    clc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; hasChildNodes()
jsd_has_child_nodes:
    push rbx
    call jsd_this_node
    cmp dword [rbx + N_FIRST], 0
    setne al
    shr al, 1
    call js_bool
    pop rbx
    ret

jsd_nothing:
    mov rax, JS_UNDEF
    ret

; focus(): a field you type into gets the keyboard (forms.asm)
jsd_focus:
    push rbx
    push rcx
    call jsd_this_node
    call form_kind
    call form_is_text
    jne .done
    call form_focus_on
.done:
    mov rax, JS_UNDEF
    pop rcx
    pop rbx
    ret

; blur(): the focused field lets go of it
jsd_blur:
    push rbx
    call jsd_this_node
    cmp eax, [form_focus]
    jne .done
    xor eax, eax
    call form_focus_on
.done:
    mov rax, JS_UNDEF
    pop rbx
    ret

; __formSubmit(form, submitter): form.submit() (dom.js): no submit event;
; the browser goes to the form's URL once the script is done
jsd_form_submit:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    xor eax, eax
    lea rsi, [jsd_name_submit]
    call jsd_arg_node
    mov ebx, eax                    ; EBX = the form
    mov eax, 1
    call jsb_arg
    call jsd_node_of
    mov edx, eax                    ; EDX = the button, 0 = none
    jnc .build
    xor edx, edx
.build:
    mov eax, ebx
    call form_build_url
    mov al, [form_post]
    mov [form_post_pending], al     ; (a POST: its body goes with it)
    lea rsi, [form_url]
    lea rdi, [browser_url_buf]
    mov ecx, BROWSER_URL_MAX
    call strlcpy
    mov byte [jsd_nav_pending], 1
.done:
    mov rax, JS_UNDEF
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; click(): a click event on it
jsd_click:
    push rbx
    push rsi
    call jsd_this_node
    lea rsi, [jsd_str_click]
    call jsd_fire
    mov rax, JS_UNDEF
    pop rsi
    pop rbx
    ret

; ==============================================================================
; window: alert, confirm, prompt
; ==============================================================================

; alert(message): the serial log and the status bar
jsd_alert:
    push rcx
    push rsi
    push rdi
    xor eax, eax
    call jsb_arg
    call js_to_string
    lea rdi, [rax + JSTR_DATA]
    lea rsi, [jsd_klog_alert]
    call klog2
    mov rsi, rdi
    call jsd_bld_reset
    push rsi
    lea rsi, [jsd_str_alert]
    call jsd_bld_cstr
    pop rsi
    call jsd_bld_cstr
    xor eax, eax
    call jsd_bld_byte
    mov rsi, JSD_BLD
    lea rdi, [browser_status_text]
    mov ecx, 96
    call strlcpy
    mov byte [gui_dirty], 1
    mov rax, JS_UNDEF
    pop rdi
    pop rsi
    pop rcx
    ret

jsd_confirm:
    call jsd_alert
    mov rax, JS_TRUE
    ret

jsd_prompt:
    call jsd_alert
    mov rax, JS_NULL
    ret

; ==============================================================================
; Events
; ==============================================================================

; jsd_listener_target: RDX = this -> RAX = the object whose listeners these are
; (a node's object, or the global object for window / a plain call)
jsd_listener_target:
    mov rax, rdx
    call jsd_node_of
    jnc .node
    mov rax, [js_global]
    BOX rax, rdx, JS_OBJ_BITS       ; (RDX is restored by the callers)
    ret
.node:
    mov rax, rdx
    ret

; jsd_listeners: RAX = target object, RDX = type atom, CL = 1 to create
; -> RAX = its listener array (raw), CF=1 if none
jsd_listeners:
    push rbx
    push rcx
    push rdx
    push rdi
    mov rdi, rdx                    ; type
    mov eax, eax
    mov rdx, [atom_d_listeners]
    push rax
    call jsobj_find_own
    pop rax
    jnc .map
    test cl, cl
    jz .none
    push rax
    xor eax, eax
    call jsobj_new                  ; a map with no prototype
    mov rbx, rax
    pop rax
    push rcx
    mov rcx, rbx
    BOX rcx, rdx, JS_OBJ_BITS
    mov rdx, [atom_d_listeners]
    call jsobj_define_hidden
    pop rcx
    mov rax, rbx
    jmp .type
.map:
    mov eax, [rbx + JPE_VAL]
.type:
    mov edx, edi
    push rax
    call jsobj_find_own
    pop rax
    jnc .array
    test cl, cl
    jz .none
    push rcx
    push rax
    xor ecx, ecx
    call jsarr_new
    mov rbx, rax
    pop rax
    mov rcx, rbx
    BOX rcx, rdx, JS_OBJ_BITS
    mov edx, edi
    call jsobj_define
    pop rcx
    mov rax, rbx
    jmp .out
.array:
    mov eax, [rbx + JPE_VAL]
.out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    clc
    ret
.none:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    stc
    ret

; addEventListener(type, listener)
jsd_add_listener:
    push rbx
    push rcx
    push rdx
    push rsi
    mov eax, 1
    call jsb_arg
    call js_is_callable
    jnc .done
    mov rsi, rax                    ; the listener
    xor eax, eax
    call jsb_arg
    call js_to_key
    push rax
    call jsd_listener_target
    pop rdx
    mov cl, 1
    call jsd_listeners
    ; already there?
    mov ecx, [rax + JARR_LEN]
    mov rbx, [rax + JARR_ELEMS]
.dup:
    test ecx, ecx
    jz .add
    cmp [rbx], rsi
    je .done
    add rbx, 8
    dec ecx
    jmp .dup
.add:
    mov rcx, rsi
    call jsarr_push
.done:
    mov rax, JS_UNDEF
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; removeEventListener(type, listener)
jsd_remove_listener:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov eax, 1
    call jsb_arg
    mov rsi, rax
    xor eax, eax
    call jsb_arg
    call js_to_key
    push rax
    call jsd_listener_target
    pop rdx
    xor ecx, ecx
    call jsd_listeners
    jc .done
    ; close the gap
    mov ecx, [rax + JARR_LEN]
    mov rbx, [rax + JARR_ELEMS]
    xor edx, edx
.find:
    cmp edx, ecx
    jae .done
    cmp [rbx + rdx*8], rsi
    je .found
    inc edx
    jmp .find
.found:
    lea edi, [rdx + 1]
.shift:
    cmp edi, ecx
    jae .shrink
    mov rsi, [rbx + rdi*8]
    mov [rbx + rdi*8 - 8], rsi
    inc edi
    jmp .shift
.shrink:
    dec dword [rax + JARR_LEN]
.done:
    mov rax, JS_UNDEF
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; event.preventDefault()
jsd_prevent_default:
    push rcx
    push rdx
    mov rax, rdx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .done
    mov eax, eax
    mov rdx, [atom_d_defaultPrevented]
    mov rcx, JS_TRUE
    call jsobj_define
.done:
    mov rax, JS_UNDEF
    pop rdx
    pop rcx
    ret

; event.stopPropagation()
jsd_stop_propagation:
    push rcx
    push rdx
    mov rax, rdx
    mov rcx, rax
    shr rcx, 48
    cmp ecx, JS_TAG_OBJECT
    jne .done
    mov eax, eax
    mov edx, [atom_d_stop]
    mov rcx, JS_TRUE
    call jsobj_define_hidden
.done:
    mov rax, JS_UNDEF
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------------------------
; jsd_fire: EAX = target node, RSI = event type (NUL-terminated) -> the event
; dispatched: listeners and on<type> handlers of the node, then of each
; ancestor, the document and window (bubbling). CF=1 if the default action
; was prevented.
; ------------------------------------------------------------------------------
jsd_fire:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r9d, eax                    ; the target
    call jsstr_from_cstr
    mov r10, rax                    ; the type atom
    ; the event object
    mov rax, [jsd_event_proto]
    call jsobj_new
    mov r8, rax
    mov rcx, r10
    BOX rcx, rdx, JS_STR_BITS
    mov rdx, [atom_d_type]
    call jsobj_define
    mov eax, r9d
    call jsd_wrap
    mov rcx, rax
    mov rax, r8
    mov rdx, [atom_d_target]
    call jsobj_define
    mov rcx, JS_TRUE
    mov rdx, [atom_d_bubbles]
    call jsobj_define
    mov rcx, JS_FALSE
    mov rdx, [atom_d_defaultPrevented]
    call jsobj_define
    mov eax, [jsd_click_x]
    call jsb_from_int
    mov rcx, rax
    mov rax, r8
    mov rdx, [atom_d_clientX]
    call jsobj_define
    mov eax, [jsd_click_y]
    call jsb_from_int
    mov rcx, rax
    mov rax, r8
    mov rdx, [atom_d_clientY]
    call jsobj_define
    xor ecx, ecx
    mov rdx, [atom_d_button]
    call jsobj_define               ; 0 (a number)
    ; up the tree
    mov eax, r9d
.node:
    push rax
    call jsd_wrap
    call jsd_deliver
    pop rax
    jc .stopped
    test eax, eax
    jz .window                      ; the document was last
    call dom_node
    mov eax, [rbx + N_PARENT]
    test eax, eax
    jnz .node
    ; a top-level node: the document next, if it is in it
    mov eax, r9d
    call dom_connected
    mov eax, 0
    jc .node
    jmp .done
.window:
    mov rax, [js_global]
    BOX rax, rdx, JS_OBJ_BITS
    call jsd_deliver
.stopped:
.done:
    ; prevented?
    mov rax, r8
    mov rdx, [atom_d_defaultPrevented]
    call jsobj_find_own
    mov rax, [rbx + JPE_VAL]
    mov rdx, JS_TRUE
    cmp rax, rdx
    je .prevented
    clc
    jmp .out
.prevented:
    stc
.out:
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

; jsd_fire_plain: RAX = target object value (window / document object),
; RSI = type -> listeners of just that target (load, DOMContentLoaded)
jsd_fire_at:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r10
    push rax
    call jsstr_from_cstr
    mov r10, rax
    mov rax, [jsd_event_proto]
    call jsobj_new
    mov r8, rax
    mov rcx, r10
    BOX rcx, rdx, JS_STR_BITS
    mov rdx, [atom_d_type]
    call jsobj_define
    mov rcx, [rsp]
    mov rdx, [atom_d_target]
    call jsobj_define
    mov rcx, JS_FALSE
    mov rdx, [atom_d_defaultPrevented]
    call jsobj_define
    pop rax
    call jsd_deliver
    pop r10
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsd_deliver: RAX = current target (object value), R8 = event (raw), R10 =
; type atom -> its listeners and on<type> handler called; CF=1 if one
; stopped propagation
; ------------------------------------------------------------------------------
jsd_deliver:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    mov r9, rax                     ; the current target
    mov rcx, r9
    mov rax, r8
    mov rdx, [atom_d_currentTarget]
    call jsobj_define
    ; addEventListener listeners (a copy of the count: new ones wait)
    mov rax, r9
    mov rdx, r10
    xor ecx, ecx
    call jsd_listeners
    jc .handler
    mov rsi, rax                    ; the array
    xor ebx, ebx
    mov edi, [rsi + JARR_LEN]
.listener:
    cmp ebx, edi
    jae .handler
    cmp ebx, [rsi + JARR_LEN]
    jae .handler                    ; some were removed
    mov rax, [rsi + JARR_ELEMS]
    mov rax, [rax + rbx*8]
    call jsd_call_handler
    inc ebx
    jmp .listener
.handler:
    ; the on<type> property, or the on<type>="..." attribute
    call jsd_on_handler             ; RAX = function, CF=1 if none
    jc .stop_check
    call jsd_call_handler
    mov rdx, JS_FALSE
    cmp rax, rdx
    jne .stop_check
    ; returning false cancels the default action
    mov rax, r8
    mov rdx, [atom_d_defaultPrevented]
    mov rcx, JS_TRUE
    call jsobj_define
.stop_check:
    mov rax, r8
    mov rdx, [atom_d_stop]
    call jsobj_find_own
    cmc                             ; CF=1 when stopped
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsd_call_handler: RAX = function, R9 = this, R8 = event -> RAX = its result
; (errors are reported and give undefined)
jsd_call_handler:
    push rcx
    push rdx
    push rdi
    mov rdx, r8
    BOX rdx, rcx, JS_OBJ_BITS
    push rdx
    mov rdi, rsp
    mov rdx, r9
    mov ecx, 1
    call js_call_safe
    jnc .ok
    call js_print_error
    mov rax, JS_UNDEF
.ok:
    add rsp, 8
    pop rdi
    pop rdx
    pop rcx
    ret

; jsd_on_handler: R9 = current target, R10 = type atom -> RAX = its on<type>
; handler, CF=1 if none. An on<type>="code" attribute is compiled once and
; kept as the on<type> property.
jsd_on_handler:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    ; "on" + type
    call jsd_bld_reset
    mov al, 'o'
    call jsd_bld_byte
    mov al, 'n'
    call jsd_bld_byte
    mov rax, r10
    call jsd_bld_str
    mov rsi, JSD_BLD
    mov ecx, [jsd_bld_len]
    call jsstr_atom
    mov rdx, rax                    ; the property name
    mov eax, r9d
    call jsobj_find_own
    jc .attribute
    mov rax, [rbx + JPE_VAL]
    call js_is_callable
    jnc .none
    jmp .found
.attribute:
    mov rax, r9
    call jsd_node_of
    jc .none
    push rdx
    lea rdi, [rdx + JSTR_DATA]
    call dom_attr                   ; RSI/ECX = the code
    pop rdx
    jc .none
    ; (function (event) { code })
    push rax
    call jsd_bld_reset
    push rsi
    lea rsi, [jsd_str_handler_open]
    call jsd_bld_cstr
    pop rsi
    call jsd_decode
    lea rsi, [jsd_str_handler_close]
    call jsd_bld_cstr
    call jsd_bld_take
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    call js_eval
    pop rbx
    jc .error
    call js_is_callable
    jnc .none
    ; keep it as the property
    mov rcx, rax
    mov eax, r9d
    call jsobj_define
    mov rax, rcx
.found:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    clc
    ret
.error:
    call js_print_error
.none:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    stc
    ret

; ==============================================================================
; The page's lifecycle (called by browser.asm)
; ==============================================================================

; jsd_live: CF=1 if the page's scripts can run (its realm is still the
; engine's: the `js` shell command has not reset it since)
jsd_live:
    cmp byte [jsd_enabled], 0
    je .no
    push rax
    mov eax, [jsd_realm]
    cmp eax, [js_realm]
    pop rax
    jne .no
    stc
    ret
.no:
    clc
    ret

; jsd_enter / jsd_leave: console.log goes to the serial log meanwhile
jsd_enter:
    push rax
    mov rax, [js_print_hook]
    mov [jsd_saved_hook], rax
    lea rax, [jsd_print]
    mov [js_print_hook], rax
    pop rax
    ret

jsd_leave:
    push rax
    mov rax, [jsd_saved_hook]
    mov [js_print_hook], rax
    pop rax
    ret

; jsd_print: RSI = text, RCX = length -> "[klog] js: text"
jsd_print:
    push rcx
    push rsi
    push rdi
    cmp rcx, 230
    jbe .len
    mov ecx, 230
.len:
    lea rdi, [jsd_log_buf]
    rep movsb
    mov byte [rdi], 0
    lea rsi, [jsd_klog_js]
    lea rdi, [jsd_log_buf]
    call klog2
    pop rdi
    pop rsi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; jsd_page_load: the page's DOM and styles are ready (browser_prepare_page)
; -> a fresh realm with window and document, then its <script>s in document
; order (inline, or fetched with src=), then DOMContentLoaded and load
; ------------------------------------------------------------------------------
jsd_page_load:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    mov byte [jsd_enabled], 0
    mov byte [jsd_nav_pending], 0
    mov byte [jsd_dirty], 0
    cmp byte [browser_page_plain], 0
    jne .done
    cmp qword [mem_total_bytes], JS_MIN_RAM
    jb .done
    call js_reset
    call jsd_init
    mov eax, [js_realm]
    mov [jsd_realm], eax
    mov byte [jsd_enabled], 1
    call jsd_enter
    ; the scripts, in document order (collected first: scripts change the tree)
    mov dword [jsd_script_count], 0
    mov dword [jsd_external], 0
    xor eax, eax
    xor edx, edx
.collect:
    call jsd_next
    test eax, eax
    jz .collected
    call dom_node
    cmp byte [rbx + N_TAG], TAGID_SCRIPT
    jne .collect
    mov ecx, [jsd_script_count]
    cmp ecx, JSD_MAX_SCRIPTS
    jae .collected
    lea rsi, [jsd_scripts]
    mov [rsi + rcx*4], eax
    inc dword [jsd_script_count]
    jmp .collect
.collected:
    mov byte [jsd_loading], 1
    xor r12d, r12d
.script:
    cmp r12d, [jsd_script_count]
    jae .scripts_done
    lea rsi, [jsd_scripts]
    mov eax, [rsi + r12*4]
    inc r12d
    call dom_connected
    jnc .script                     ; a script removed it
    call jsd_run_script
    jmp .script
.scripts_done:
    mov byte [jsd_loading], 0
    mov dword [jsd_script_node], 0
    ; DOMContentLoaded (document, then window), load (window)
    xor eax, eax
    call jsd_wrap
    lea rsi, [jsd_str_dom_loaded]
    call jsd_fire_at
    mov rax, [js_global]
    BOX rax, rdx, JS_OBJ_BITS
    call jsd_fire_at
    lea rsi, [jsd_str_load]
    call jsd_fire_at
    call jsev_drain
    call jsd_leave
    call jsd_after
.done:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsd_run_script: EAX = <script> element -> run (errors reported)
jsd_run_script:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov edx, eax
    ; type="": only JavaScript
    lea rdi, [jsd_str_type]
    call dom_attr
    jc .javascript
    test ecx, ecx
    jz .javascript
    lea rdi, [jsd_str_javascript]
    call css_contains_ci
    je .javascript
    lea rdi, [jsd_str_ecmascript]
    call css_contains_ci
    jne .done
.javascript:
    ; where document.write puts its HTML
    mov eax, edx
    mov [jsd_script_node], eax
    call dom_node
    mov eax, [rbx + N_PARENT]
    mov [jsd_write_parent], eax
    mov eax, [rbx + N_NEXT]
    mov [jsd_write_before], eax
    ; src="" or the text inside
    mov eax, edx
    lea rdi, [jsd_str_src]
    call dom_attr
    jnc .external
    mov eax, [rbx + N_FIRST]
    test eax, eax
    jz .done
    call dom_node
    mov rsi, [rbx + N_NAME]
    mov ecx, [rbx + N_NAME_LEN]
    jmp .run
.external:
    cmp dword [jsd_external], JSD_MAX_EXTERNAL
    jae .done
    inc dword [jsd_external]
    call browser_fetch_quiet        ; RSI/RCX = the script
    jc .done
.run:
    mov byte [jsd_in_script], 1
    call js_eval
    mov byte [jsd_in_script], 0
    jnc .drain
    call js_print_error
.drain:
    call jsev_drain                 ; its promise jobs
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsd_page_click: EAX = node under the pointer, ECX/EDX = pointer in the
; viewport -> the click event; CF=1 if a handler prevented the default action
; (following a link)
; ------------------------------------------------------------------------------
jsd_page_click:
    push rax
    push rbx
    push rsi
    call jsd_live
    jnc .no
    mov [jsd_click_x], ecx
    mov [jsd_click_y], edx
    ; text belongs to its element
    call dom_node
    cmp byte [rbx + N_TYPE], NODE_TEXT
    jne .element
    mov eax, [rbx + N_PARENT]
.element:
    call jsd_enter
    lea rsi, [jsd_str_click]
    call jsd_fire
    pushf
    call jsev_drain
    call jsd_leave
    call jsd_after
    popf
    jmp .out
.no:
    clc
.out:
    pop rsi
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; jsd_page_event: EAX = element, RSI = event type (NUL-terminated) -> the
; event for the page's scripts (if it has any); CF=1 if a handler prevented
; the default action
; ------------------------------------------------------------------------------
jsd_page_event:
    call jsd_live
    jnc .ret
    call jsd_enter
    call jsd_fire
    pushf
    call jsev_drain
    call jsd_leave
    call jsd_after
    popf
.ret:
    ret

; ------------------------------------------------------------------------------
; jsd_tick: (desktop loop, ~1000 times a second) the page's timers and
; animation frames that are due -> CF=1 if any ran (a navigation they asked
; for is up to the browser)
; ------------------------------------------------------------------------------
jsd_tick:
    call jsd_live
    jnc .ret
    push rax
    call jsev_next_due
    cmp rax, [timer_ticks]
    ja .none                        ; (-1: nothing waits)
    call jsd_enter
    call jsev_run_due
    call jsd_leave
    call jsd_after
    pop rax
    stc
    ret
.none:
    pop rax
    clc
.ret:
    ret

; jsd_after: after scripts ran: restyle and lay out again if the DOM changed
jsd_after:
    cmp byte [jsd_dirty], 0
    je .ret
    mov byte [jsd_dirty], 0
    call css_compute
    mov dword [lay_width], -1
    mov byte [gui_dirty], 1
    mov byte [browser_log_text], 1  ; tests: log the text as it is now
    mov dword [browser_log_len], 0
    mov byte [browser_log_buf], 0
.ret:
    ret

; ------------------------------------------------------------------------------
; jsd_inspect: RBX = host object -> a short description in jsout_buf
; (console.log): <tag id="...">, #text, #document
; ------------------------------------------------------------------------------
jsd_inspect:
    push rax
    push rbx
    push rcx
    push rsi
    mov ecx, [rbx + JOBJ_CLASS]
    lea rsi, [jsd_str_style_class]
    cmp ecx, JC_STYLE
    je .cstr
    lea rsi, [jsd_str_list_class]
    cmp ecx, JC_CLASSLIST
    je .cstr
    cmp ecx, JC_LOCATION
    je .location
    mov eax, [rbx + JSD_NODE]
    lea rsi, [jsd_str_document_name]
    test eax, eax
    jz .cstr
    call dom_node
    lea rsi, [jsd_str_text_name]
    cmp byte [rbx + N_TYPE], NODE_TEXT
    je .cstr
    mov al, '<'
    call jsout_byte
    mov rsi, [rbx + N_NAME]
    mov ecx, [rbx + N_NAME_LEN]
    call jsout_bytes
    mov al, '>'
    call jsout_byte
    jmp .out
.location:
    lea rsi, [browser_page_url]
.cstr:
    call jsout_cstr
.out:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

section .bss
jsd_click_x:            resd 1
jsd_click_y:            resd 1

section .rodata
jsd_str_id:             db "id", 0
jsd_str_slash:          db "/", 0
