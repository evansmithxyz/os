; ==============================================================================
; Antigravity OS - DEFLATE decompression (gzip / zlib / raw), RFC 1951/1950/1952
; ------------------------------------------------------------------------------
; inflate turns compressed data into the original bytes. It decodes Huffman
; codes a bit at a time from canonical tables (the way zlib's puff.c does):
; small, and fast enough for web pages. http_decode_body uses it on a
; response whose Content-Encoding is gzip or deflate (servers send that even
; when not asked).
; ==============================================================================

[bits 64]

INF_MAXBITS             equ 15

section .bss
alignb 8
inf_rsp:                resq 1          ; RSP to go back to on bad data
inf_in:                 resq 1          ; next input byte
inf_in_end:             resq 1
inf_out:                resq 1          ; next output byte
inf_out_start:          resq 1
inf_out_end:            resq 1
inf_bitbuf:             resd 1          ; bits not used yet (the next is bit 0)
inf_bitcnt:             resd 1
; Huffman tables: 16 counts (codes of each length), then the symbols in
; code order
inf_lencode:            resw 16 + 288
inf_distcode:           resw 16 + 288
inf_offs:               resw 16
inf_lengths:            resb 320        ; code lengths being read

section .rodata
inf_lbase:              dw 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31
                        dw 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
inf_lext:               db 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2
                        db 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
inf_dbase:              dw 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193
                        dw 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145
                        dw 8193, 12289, 16385, 24577
inf_dext:               db 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6
                        db 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
inf_order:              db 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
str_content_encoding:   db "content-encoding:", 0
str_transfer_encoding:  db "transfer-encoding:", 0

section .text

; ------------------------------------------------------------------------------
; inflate: RSI = compressed data, RCX = its length, RDI = output, RDX = room
; there -> RAX = bytes written, CF=0; CF=1 if the data is not valid (or does
; not fit). A gzip (1f 8b) or zlib wrapper is skipped; else raw DEFLATE.
; ------------------------------------------------------------------------------
inflate:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r15
    mov [inf_rsp], rsp
    mov [inf_in], rsi
    lea rax, [rsi + rcx]
    mov [inf_in_end], rax
    mov [inf_out], rdi
    mov [inf_out_start], rdi
    lea rax, [rdi + rdx]
    mov [inf_out_end], rax
    mov dword [inf_bitbuf], 0
    mov dword [inf_bitcnt], 0
    cmp rcx, 18
    jb .blocks
    cmp word [rsi], 0x8B1F
    jne .zlib
    ; gzip: 10 bytes, then the optional fields its flags say are there
    cmp byte [rsi + 2], 8
    jne inf_fail
    mov bl, [rsi + 3]
    lea r8, [rsi + 10]
    test bl, 4                      ; FEXTRA
    jz .no_extra
    movzx eax, word [r8]
    lea r8, [r8 + rax + 2]
.no_extra:
    test bl, 8                      ; FNAME
    jz .no_name
    call .skip_string
.no_name:
    test bl, 16                     ; FCOMMENT
    jz .no_comment
    call .skip_string
.no_comment:
    test bl, 2                      ; FHCRC
    jz .no_crc
    add r8, 2
.no_crc:
    cmp r8, [inf_in_end]
    jae inf_fail
    mov [inf_in], r8
    jmp .blocks
.zlib:
    ; zlib: method 8, (CMF * 256 + FLG) a multiple of 31, no dictionary
    movzx eax, byte [rsi]
    and al, 0x0F
    cmp al, 8
    jne .blocks
    movzx eax, byte [rsi]
    shl eax, 8
    mov al, [rsi + 1]
    xor edx, edx
    mov ecx, 31
    div ecx
    test edx, edx
    jnz .blocks
    test byte [rsi + 1], 0x20
    jnz inf_fail
    add qword [inf_in], 2
.blocks:
    mov ecx, 1
    call inf_bits
    mov r15d, eax                   ; the last block?
    mov ecx, 2
    call inf_bits
    cmp eax, 0
    je .stored
    cmp eax, 1
    je .fixed
    cmp eax, 2
    je .dynamic
    jmp inf_fail
.next:
    test r15d, r15d
    jz .blocks
    mov rax, [inf_out]
    sub rax, [inf_out_start]
    clc
    jmp inf_out_return
.stored:
    ; to the next byte; LEN, NLEN (its complement), LEN bytes
    mov dword [inf_bitbuf], 0
    mov dword [inf_bitcnt], 0
    mov rsi, [inf_in]
    lea rax, [rsi + 4]
    cmp rax, [inf_in_end]
    ja inf_fail
    movzx ecx, word [rsi]
    movzx eax, word [rsi + 2]
    not ax
    cmp ax, cx
    jne inf_fail
    add rsi, 4
    lea rax, [rsi + rcx]
    cmp rax, [inf_in_end]
    ja inf_fail
    mov rdi, [inf_out]
    lea rax, [rdi + rcx]
    cmp rax, [inf_out_end]
    ja inf_fail
    rep movsb
    mov [inf_in], rsi
    mov [inf_out], rdi
    jmp .next
.fixed:
    ; fixed codes: literal/length 0-143: 8 bits, 144-255: 9, 256-279: 7,
    ; 280-287: 8; distances: 5 bits
    lea rdi, [inf_lengths]
    mov ecx, 144
    mov al, 8
    rep stosb
    mov ecx, 112
    mov al, 9
    rep stosb
    mov ecx, 24
    mov al, 7
    rep stosb
    mov ecx, 8
    mov al, 8
    rep stosb
    lea rbx, [inf_lencode]
    lea rsi, [inf_lengths]
    mov ecx, 288
    call inf_construct
    lea rdi, [inf_lengths]
    mov ecx, 30
    mov al, 5
    rep stosb
    lea rbx, [inf_distcode]
    lea rsi, [inf_lengths]
    mov ecx, 30
    call inf_construct
    call inf_codes
    jmp .next
.dynamic:
    call inf_dynamic
    call inf_codes
    jmp .next
; .skip_string: R8 = a NUL-terminated field -> R8 past it
.skip_string:
    cmp r8, [inf_in_end]
    jae inf_fail
    inc r8
    cmp byte [r8 - 1], 0
    jne .skip_string
    ret

; inf_fail: bad (or too big) data: back out of inflate with CF=1
inf_fail:
    mov rsp, [inf_rsp]
    stc
inf_out_return:
    pop r15
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; inf_bits: ECX = n (0-16) -> EAX = the next n bits, first bit lowest
inf_bits:
    push rcx
    push rdx
    push r8
    push r9
    mov r8d, [inf_bitbuf]
    mov r9d, [inf_bitcnt]
.more:
    cmp r9d, ecx
    jae .enough
    mov rax, [inf_in]
    cmp rax, [inf_in_end]
    jae inf_fail
    movzx edx, byte [rax]
    inc rax
    mov [inf_in], rax
    push rcx
    mov ecx, r9d
    shl edx, cl
    pop rcx
    or r8d, edx
    add r9d, 8
    jmp .more
.enough:
    mov eax, 1
    shl eax, cl
    dec eax
    and eax, r8d
    shr r8d, cl
    sub r9d, ecx
    mov [inf_bitbuf], r8d
    mov [inf_bitcnt], r9d
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret

; inf_decode: RBX = a Huffman table -> EAX = the next symbol
inf_decode:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    xor ecx, ecx                    ; the code so far
    xor edx, edx                    ; the first code of this length
    xor esi, esi                    ; the index of its first symbol
    mov edi, 1                      ; length
    mov r8d, [inf_bitbuf]
    mov r9d, [inf_bitcnt]
.bit:
    test r9d, r9d
    jnz .have_bit
    mov rax, [inf_in]
    cmp rax, [inf_in_end]
    jae inf_fail
    movzx r8d, byte [rax]
    inc rax
    mov [inf_in], rax
    mov r9d, 8
.have_bit:
    mov eax, r8d
    and eax, 1
    or ecx, eax
    shr r8d, 1
    dec r9d
    movzx eax, word [rbx + rdi*2]   ; codes of this length
    mov r10d, ecx
    sub r10d, eax
    cmp r10d, edx
    jl .found
    add esi, eax
    add edx, eax
    shl edx, 1
    shl ecx, 1
    inc edi
    cmp edi, INF_MAXBITS
    jbe .bit
    jmp inf_fail
.found:
    mov eax, ecx
    sub eax, edx
    add eax, esi
    movzx eax, word [rbx + 32 + rax*2]
    mov [inf_bitbuf], r8d
    mov [inf_bitcnt], r9d
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; inf_construct: RBX = table, RSI = code lengths (bytes), ECX = how many ->
; the table built; EAX < 0 if the lengths are over-subscribed (bad data)
inf_construct:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    ; counts
    xor eax, eax
    mov rdi, rbx
    push rcx
    mov ecx, 16
    rep stosw
    pop rcx
    xor edx, edx
.count:
    cmp edx, ecx
    jae .counted
    movzx eax, byte [rsi + rdx]
    inc word [rbx + rax*2]
    inc edx
    jmp .count
.counted:
    movzx eax, word [rbx]
    cmp eax, ecx
    je .none                        ; no codes at all
    mov r8d, 1                      ; codes left
    mov edx, 1
.left:
    shl r8d, 1
    movzx eax, word [rbx + rdx*2]
    sub r8d, eax
    js .over
    inc edx
    cmp edx, INF_MAXBITS
    jbe .left
    ; where each length's symbols start
    mov word [inf_offs + 2], 0
    mov edx, 1
.offs:
    movzx eax, word [inf_offs + rdx*2]
    add ax, [rbx + rdx*2]
    mov [inf_offs + rdx*2 + 2], ax
    inc edx
    cmp edx, INF_MAXBITS
    jb .offs
    ; the symbols, in code order
    xor edx, edx
.symbol:
    cmp edx, ecx
    jae .built
    movzx eax, byte [rsi + rdx]
    test eax, eax
    jz .next_symbol
    movzx r9d, word [inf_offs + rax*2]
    mov [rbx + 32 + r9*2], dx
    inc word [inf_offs + rax*2]
.next_symbol:
    inc edx
    jmp .symbol
.built:
    mov eax, r8d
    jmp .out
.none:
    xor eax, eax
    jmp .out
.over:
    mov eax, -1
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; inf_dynamic: a dynamic block's code lengths -> inf_lencode / inf_distcode
inf_dynamic:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov ecx, 5
    call inf_bits
    lea r8d, [rax + 257]            ; literal/length codes
    mov ecx, 5
    call inf_bits
    lea r9d, [rax + 1]              ; distance codes
    mov ecx, 4
    call inf_bits
    lea r10d, [rax + 4]             ; code length codes
    cmp r8d, 286
    ja inf_fail
    cmp r9d, 30
    ja inf_fail
    ; the code length code
    xor edx, edx
.order:
    cmp edx, 19
    jae .ordered
    xor eax, eax
    cmp edx, r10d
    jae .zero
    mov ecx, 3
    call inf_bits
.zero:
    movzx ecx, byte [inf_order + rdx]
    mov [inf_lengths + rcx], al
    inc edx
    jmp .order
.ordered:
    lea rbx, [inf_lencode]
    lea rsi, [inf_lengths]
    mov ecx, 19
    call inf_construct
    test eax, eax
    js inf_fail
    ; the lengths of both codes, with their repeat codes
    lea r10d, [r8 + r9]             ; how many
    xor edx, edx                    ; index
.length:
    cmp edx, r10d
    jae .lengths_done
    call inf_decode
    cmp eax, 16
    jae .repeat
    mov [inf_lengths + rdx], al
    inc edx
    jmp .length
.repeat:
    xor edi, edi                    ; the length repeated
    cmp eax, 16
    jne .zeros
    test edx, edx
    jz inf_fail
    movzx edi, byte [inf_lengths + rdx - 1]
    mov ecx, 2
    call inf_bits
    add eax, 3
    jmp .fill
.zeros:
    cmp eax, 17
    jne .long_zeros
    mov ecx, 3
    call inf_bits
    add eax, 3
    jmp .fill
.long_zeros:
    mov ecx, 7
    call inf_bits
    add eax, 11
.fill:
    lea ecx, [rdx + rax]
    cmp ecx, r10d
    ja inf_fail
.fill_one:
    mov [inf_lengths + rdx], dil
    inc edx
    dec eax
    jnz .fill_one
    jmp .length
.lengths_done:
    cmp byte [inf_lengths + 256], 0
    je inf_fail                     ; no end-of-block code
    lea rbx, [inf_lencode]
    lea rsi, [inf_lengths]
    mov ecx, r8d
    call inf_construct
    test eax, eax
    js inf_fail
    lea rbx, [inf_distcode]
    lea rsi, [inf_lengths + r8]
    mov ecx, r9d
    call inf_construct
    test eax, eax
    js inf_fail
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; inf_codes: a block's literals and (length, distance) copies, up to its end
inf_codes:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
.symbol:
    lea rbx, [inf_lencode]
    call inf_decode
    cmp eax, 256
    jb .literal
    je .end
    ; a copy: its length
    sub eax, 257
    cmp eax, 29
    jae inf_fail
    movzx edx, word [inf_lbase + rax*2]
    movzx ecx, byte [inf_lext + rax]
    call inf_bits
    add edx, eax                    ; length
    ; its distance
    lea rbx, [inf_distcode]
    call inf_decode
    cmp eax, 30
    jae inf_fail
    movzx esi, word [inf_dbase + rax*2]
    movzx ecx, byte [inf_dext + rax]
    call inf_bits
    add esi, eax                    ; distance
    mov rdi, [inf_out]
    mov rax, rdi
    sub rax, [inf_out_start]
    cmp rsi, rax
    ja inf_fail                     ; before the start
    lea rax, [rdi + rdx]
    cmp rax, [inf_out_end]
    ja inf_fail
    mov rcx, rdx
    neg rsi
    add rsi, rdi
    rep movsb                       ; (byte by byte: the copy may overlap itself)
    mov [inf_out], rdi
    jmp .symbol
.literal:
    mov rdi, [inf_out]
    cmp rdi, [inf_out_end]
    jae inf_fail
    mov [rdi], al
    inc rdi
    mov [inf_out], rdi
    jmp .symbol
.end:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; http_decode_body: http_resp_buf / http_resp_len -> the body as the page sent
; it: a chunked one (Transfer-Encoding: chunked, which some servers use even
; for HTTP/1.0) joined up, then a gzip / deflate one (Content-Encoding)
; decompressed if it fits (else it is left as it came)
; ------------------------------------------------------------------------------
http_decode_body:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    ; the end of the headers
    lea rsi, [abs http_resp_buf]
    mov ecx, [http_resp_len]
    lea r8, [rsi + rcx]             ; the end
    mov rbx, rsi
.find_end:
    lea rax, [rbx + 4]
    cmp rax, r8
    ja .done
    cmp dword [rbx], 0x0A0D0A0D     ; CR LF CR LF
    je .headers_end
    inc rbx
    jmp .find_end
.headers_end:
    add rbx, 4                      ; RBX = the body
    lea rsi, [str_transfer_encoding]
    call http_header_value
    jc .encoding
    mov eax, [rdi]
    or eax, 0x20202020
    cmp eax, 'chun'
    jne .encoding
    call http_dechunk               ; R8 = the new end
.encoding:
    lea rsi, [str_content_encoding]
    call http_header_value
    jc .done
    ; gzip / x-gzip / deflate (not br or anything else)
    mov eax, [rdi]
    or eax, 0x20202020
    cmp eax, 'gzip'
    je .decode
    cmp eax, 'x-gz'
    je .decode
    cmp eax, 'defl'
    jne .done
.decode:
    ; inflate into its own space, then over the old body
    mov rsi, rbx
    mov rcx, r8
    sub rcx, rbx
    mov rdi, INFLATE_ADDR
    lea rdx, [abs http_resp_buf + HTTP_RESP_MAX]
    sub rdx, rbx                    ; the room behind the headers
    cmp rdx, INFLATE_SIZE
    jbe .room
    mov edx, INFLATE_SIZE
.room:
    call inflate
    jc .done
    mov rcx, rax
    mov rsi, INFLATE_ADDR
    mov rdi, rbx
    rep movsb
    mov r8, rdi
.done:
    ; (the length follows the body's end, whatever happened)
    mov byte [r8], 0
    lea rax, [abs http_resp_buf]
    sub r8, rax
    mov [http_resp_len], r8d
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; http_header_value: RSI = header name ("name:", lower case), http_resp_buf
; up to RBX = the body -> RDI = its value (spaces skipped), CF=1 if absent
http_header_value:
    push rax
    push rdx
    push rsi
    lea rdi, [abs http_resp_buf]
.header:
    cmp rdi, rbx
    jae .absent
    mov rdx, rsi
    push rdi
.compare:
    mov al, [rdx]
    test al, al
    jz .matched
    mov ah, [rdi]
    cmp ah, 'A'
    jb .cmp
    cmp ah, 'Z'
    ja .cmp
    or ah, 0x20
.cmp:
    cmp al, ah
    jne .not_it
    inc rdx
    inc rdi
    jmp .compare
.not_it:
    pop rdi
.line_end:
    cmp rdi, rbx
    jae .absent
    inc rdi
    cmp byte [rdi - 1], 10
    jne .line_end
    jmp .header
.matched:
    add rsp, 8
.space:
    cmp byte [rdi], ' '
    jne .found
    inc rdi
    jmp .space
.found:
    pop rsi
    pop rdx
    pop rax
    clc
    ret
.absent:
    pop rsi
    pop rdx
    pop rax
    stc
    ret

; http_dechunk: RBX = a chunked body, R8 = its end -> the chunks' data joined
; in place, R8 = its new end (a cut-off body keeps what arrived)
http_dechunk:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov rsi, rbx                    ; reading
    mov rdi, rbx                    ; writing
.chunk:
    ; a hex size, maybe ";extensions", then CRLF
    xor ecx, ecx
    xor edx, edx                    ; digits seen
.digit:
    cmp rsi, r8
    jae .end
    movzx eax, byte [rsi]
    sub al, '0'
    cmp al, 9
    jbe .add
    movzx eax, byte [rsi]
    or al, 0x20
    sub al, 'a'
    cmp al, 5
    ja .size_done
    add al, 10
.add:
    shl rcx, 4
    add rcx, rax
    inc rsi
    inc edx
    jmp .digit
.size_done:
    test edx, edx
    jz .end                         ; not a chunk size: stop
.line:
    cmp rsi, r8
    jae .end
    inc rsi
    cmp byte [rsi - 1], 10
    jne .line
    test rcx, rcx
    jz .end                         ; the last chunk
    ; the data (what arrived of it)
    mov rax, r8
    sub rax, rsi
    cmp rcx, rax
    jbe .copy
    mov rcx, rax
.copy:
    rep movsb
    ; its CRLF
    cmp rsi, r8
    jae .end
    cmp byte [rsi], 13
    jne .no_cr
    inc rsi
.no_cr:
    cmp rsi, r8
    jae .end
    cmp byte [rsi], 10
    jne .chunk
    inc rsi
    jmp .chunk
.end:
    mov r8, rdi
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
