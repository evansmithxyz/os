; ==============================================================================
; Antigravity OS - TLS 1.3 client (RFC 8446)
; ------------------------------------------------------------------------------
; One cipher suite, TLS_CHACHA20_POLY1305_SHA256, with an X25519 key share.
; The server proves who it is with its certificate chain (checked by x509.asm
; against the trusted roots, the clock and the host name) and a
; CertificateVerify signature over the transcript. With tls_insecure set
; (curl -k) those checks are skipped and callers say so.
;
; Data flow: TCP puts every received segment into tls_in_buf (tcp_rx_to_tls),
; tls_read_record takes whole records out of it, handshake messages are
; reassembled in tls_hs_buf, and application data goes to http_resp_buf just
; like a plain HTTP response.
; ==============================================================================

[bits 64]

TLS_IN_MAX              equ 65536   ; received, not yet processed ciphertext
TLS_HS_MAX              equ 32768   ; one handshake message (certificate chains)
TLS_OUT_MAX             equ 1536    ; one outgoing record
TLS_RECORD_MAX          equ 16384 + 256
TLS_IDLE_MS             equ 10000   ; give up after this long without data

TLS_CT_CCS              equ 20      ; record content types
TLS_CT_ALERT            equ 21
TLS_CT_HANDSHAKE        equ 22
TLS_CT_APPDATA          equ 23

TLS_HS_SERVER_HELLO     equ 2       ; handshake message types
TLS_HS_ENC_EXTENSIONS   equ 8
TLS_HS_CERTIFICATE      equ 11
TLS_HS_CERT_REQUEST     equ 13
TLS_HS_CERT_VERIFY      equ 15
TLS_HS_FINISHED         equ 20
TLS_HS_KEY_UPDATE       equ 24

; A traffic direction: key, IV and record sequence number
TLS_DIR_KEY             equ 0
TLS_DIR_IV              equ 32
TLS_DIR_SEQ             equ 48
TLS_DIR_SIZE            equ 56

section .data
align 8
tls_error_msg:          dq 0        ; why the last tls_https_get failed
tls_host:               dq 0        ; host name being verified
tls_insecure:           db 0        ; 1 = skip certificate checks (curl -k); set by the caller
tls_verified:           db 0        ; 1 = the last connection's certificate was verified
tls_got_cert:           db 0
tls_got_cv:             db 0

section .bss
alignb 16
tls_in_buf:             resb TLS_IN_MAX
tls_in_len:             resd 1
tls_in_pos:             resd 1
tls_hs_len:             resd 1
tls_got_version:        resb 1
tls_got_key:            resb 1
alignb 16
tls_hs_buf:             resb TLS_HS_MAX
tls_cert_buf:           resb TLS_HS_MAX ; the Certificate message (x509_chain points into it)
tls_cv_content:         resb 64 + 34 + 32
tls_out_buf:            resb TLS_OUT_MAX + 32
tls_th_ctx:             resb SHA256_CTX_SIZE    ; running transcript hash
tls_th_tmp:             resb SHA256_CTX_SIZE
tls_th:                 resb 32                 ; transcript hash snapshot
tls_priv:               resb 32
tls_pub:                resb 32
tls_server_pub:         resb 32
tls_shared:             resb 32
tls_empty_hash:         resb 32
tls_secret:             resb 32                 ; early / derived / master
tls_hs_secret:          resb 32
tls_c_hs:               resb 32
tls_s_hs:               resb 32
tls_s_ap:               resb 32                 ; kept for KeyUpdate
tls_c_ap:               resb 32
tls_fin_key:            resb 32
tls_verify:             resb 32
tls_okm:                resb 32
tls_label_buf:          resb 128
tls_msg:                resb 64
tls_nonce:              resb 12
alignb 8
tls_client_dir:         resb TLS_DIR_SIZE
tls_server_dir:         resb TLS_DIR_SIZE
tls_err_buf:            resb 64

section .rodata
tls_zero32:             times 32 db 0
tls_label_prefix:       db "tls13 "
tls_lbl_derived:        db "derived", 0
tls_lbl_c_hs:           db "c hs traffic", 0
tls_lbl_s_hs:           db "s hs traffic", 0
tls_lbl_c_ap:           db "c ap traffic", 0
tls_lbl_s_ap:           db "s ap traffic", 0
tls_lbl_key:            db "key", 0
tls_lbl_iv:             db "iv", 0
tls_lbl_finished:       db "finished", 0
tls_lbl_update:         db "traffic upd", 0

; ServerHello.random of a HelloRetryRequest: SHA-256("HelloRetryRequest")
tls_hrr_random:
    db 0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91
    db 0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C

; ClientHello extensions after server_name. key_share is last: the 32-byte
; public key is appended right after this template.
tls_ch_extensions:
    db 0x00, 0x0a, 0x00, 0x04, 0x00, 0x02, 0x00, 0x1d               ; supported_groups: x25519
    db 0x00, 0x0d, 0x00, 0x12, 0x00, 0x10                           ; signature_algorithms:
    db 0x04, 0x03, 0x08, 0x04, 0x04, 0x01, 0x05, 0x03               ;   ecdsa p256, rsa-pss, pkcs1 ...
    db 0x08, 0x05, 0x05, 0x01, 0x08, 0x06, 0x06, 0x01
    db 0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x04                     ; supported_versions: TLS 1.3
    db 0x00, 0x2d, 0x00, 0x02, 0x01, 0x01                           ; psk_key_exchange_modes: psk_dhe_ke
    db 0x00, 0x33, 0x00, 0x26, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20   ; key_share: x25519, 32 bytes
TLS_CH_EXTENSIONS_LEN   equ $ - tls_ch_extensions

tls_err_connect:        db "could not connect", 0
tls_err_closed:         db "connection closed during the handshake", 0
tls_err_alert:          db "server sent alert ", 0
tls_err_hrr:            db "server wants another key share (HelloRetryRequest)", 0
tls_err_version:        db "server does not support TLS 1.3", 0
tls_err_cipher:         db "server did not pick ChaCha20-Poly1305", 0
tls_err_key:            db "no X25519 key share from the server", 0
tls_err_ecdh:           db "bad X25519 key share", 0
tls_err_mac:            db "record failed authentication", 0
tls_err_finished:       db "server Finished did not verify", 0
tls_err_unexpected:     db "unexpected handshake message", 0
tls_err_certreq:        db "server requires a client certificate", 0
tls_err_big:            db "handshake message too large", 0
tls_err_record:         db "malformed record", 0
tls_err_cv_alg:         db "unsupported CertificateVerify algorithm", 0
tls_err_cv_bad:         db "server's CertificateVerify signature is invalid", 0
tls_err_no_auth:        db "server did not prove its identity", 0
tls_err_cert_msg:       db "malformed Certificate message", 0
tls_cv_context:         db "TLS 1.3, server CertificateVerify", 0   ; 33 bytes + the 0
klog_tls_insecure:      db "tls: certificate NOT verified (insecure mode)", 0

klog_tls_error:         db "tls: error: ", 0
klog_tls_alert:         db "tls: alert ", 0
klog_tls_done:          db "tls: handshake done (TLS 1.3, CHACHA20_POLY1305_SHA256)", 0
klog_tls_verified:      db "tls: certificate verified for ", 0
klog_tls_bytes:         db "tls: response bytes ", 0

section .text
; ==============================================================================
; Key schedule helpers
; ==============================================================================

; ------------------------------------------------------------------------------
; tls_expand_label: HKDF-Expand-Label(secret, label, context, length)
; RSI = 32-byte secret, RDX = label (NUL-terminated, without "tls13 "),
; R8 = context, R9 = context length (0-32), RDI = output, RCX = length (1-32).
; One HMAC block covers every length TLS 1.3 needs with SHA-256.
; ------------------------------------------------------------------------------
tls_expand_label:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rbx, rdi                    ; RBX = output

    ; HkdfLabel = uint16 length | uint8 len | "tls13 " label | uint8 len | context
    lea rdi, [tls_label_buf]
    mov byte [rdi], 0
    mov [rdi + 1], cl
    push rsi
    mov rsi, rdx
    call strlen
    add al, 6
    mov [rdi + 2], al
    add rdi, 3
    push rcx
    lea rsi, [tls_label_prefix]
    mov ecx, 6
    rep movsb
    mov rsi, rdx
.label:
    lodsb
    test al, al
    jz .label_done
    stosb
    jmp .label
.label_done:
    mov [rdi], r9b
    inc rdi
    mov rsi, r8
    mov rcx, r9
    rep movsb
    mov byte [rdi], 1               ; T(1) counter
    inc rdi
    pop rcx
    pop rsi

    ; okm = HMAC(secret, info | 0x01)
    push rcx
    lea rdx, [tls_label_buf]
    mov r8, rdi
    sub r8, rdx
    mov ecx, 32
    lea rdi, [tls_okm]
    call hmac_sha256
    pop rcx
    lea rsi, [tls_okm]
    mov rdi, rbx
    rep movsb

    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; tls_derive: RSI = secret, RDX = label, RDI = 32-byte output; the context is
; the transcript hash snapshot in tls_th
tls_derive:
    push rcx
    push r8
    push r9
    lea r8, [tls_th]
    mov r9d, 32
    mov ecx, 32
    call tls_expand_label
    pop r9
    pop r8
    pop rcx
    ret

; tls_set_keys: RSI = traffic secret, RBX = direction -> key, IV, sequence 0
tls_set_keys:
    push rcx
    push rdx
    push rdi
    push r9
    xor r9d, r9d                    ; empty context
    lea rdx, [tls_lbl_key]
    lea rdi, [rbx + TLS_DIR_KEY]
    mov ecx, 32
    call tls_expand_label
    lea rdx, [tls_lbl_iv]
    lea rdi, [rbx + TLS_DIR_IV]
    mov ecx, 12
    call tls_expand_label
    mov qword [rbx + TLS_DIR_SEQ], 0
    pop r9
    pop rdi
    pop rdx
    pop rcx
    ret

; tls_make_nonce: RBX = direction -> tls_nonce = IV xor big-endian sequence
tls_make_nonce:
    push rax
    mov rax, [rbx + TLS_DIR_IV]
    mov [tls_nonce], rax
    mov eax, [rbx + TLS_DIR_IV + 8]
    mov [tls_nonce + 8], eax
    mov rax, [rbx + TLS_DIR_SEQ]
    bswap rax
    xor [tls_nonce + 4], rax
    pop rax
    ret

; tls_th_update: RSI = handshake message, RCX = length -> into the transcript
tls_th_update:
    push rdi
    lea rdi, [tls_th_ctx]
    call sha256_update
    pop rdi
    ret

; tls_th_snapshot: tls_th = hash of the transcript so far (it keeps running)
tls_th_snapshot:
    push rcx
    push rsi
    push rdi
    lea rsi, [tls_th_ctx]
    lea rdi, [tls_th_tmp]
    mov ecx, SHA256_CTX_SIZE
    rep movsb
    lea rdi, [tls_th_tmp]
    lea rsi, [tls_th]
    call sha256_final
    pop rdi
    pop rsi
    pop rcx
    ret

; tls_fail: RSI = reason -> tls_error_msg, CF=1
tls_fail:
    mov [tls_error_msg], rsi
    stc
    ret

; ==============================================================================
; Records
; ==============================================================================

; ------------------------------------------------------------------------------
; tls_rx_append: called by TCP for each in-order segment (tcp_rx_buf,
; tcp_data_rx_len bytes). CF=1 if it does not fit; TCP then drops it unACKed.
; ------------------------------------------------------------------------------
tls_rx_append:
    push rax
    push rcx
    push rsi
    push rdi
    movzx ecx, word [tcp_data_rx_len]
    cmp ecx, TCP_RX_BUF_SIZE
    ja .full                        ; was truncated when copied: have it resent
    mov eax, TLS_IN_MAX
    sub eax, [tls_in_len]
    cmp ecx, eax
    ja .full
    lea rdi, [tls_in_buf]
    mov eax, [tls_in_len]
    add rdi, rax
    add [tls_in_len], ecx
    lea rsi, [tcp_rx_buf]
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    pop rax
    clc
    ret
.full:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; tls_wait: ECX = bytes needed from tls_in_pos on. Polls the network until they
; are there. CF=1 if the connection ended or stayed silent for TLS_IDLE_MS.
; Moves unread data to the start of tls_in_buf, so earlier pointers into it
; are no longer valid afterwards.
; ------------------------------------------------------------------------------
tls_wait:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8d, [tls_in_len]           ; R8 = length at the last progress
.deadline:
    mov rdx, [timer_ticks]
    add rdx, TICKS(TLS_IDLE_MS)
.check:
    mov eax, [tls_in_len]
    sub eax, [tls_in_pos]
    cmp eax, ecx
    jae .ok
    cmp byte [tcp_fin_received], 1
    je .ended
    cmp byte [tcp_connection_closed], 1
    je .ended
    cmp byte [tcp_active_state], TCP_STATE_CLOSED
    je .ended
    ; compact: move the unread bytes to the front
    mov eax, [tls_in_pos]
    test eax, eax
    jz .poll
    push rcx
    lea rdi, [tls_in_buf]
    lea rsi, [rdi + rax]
    mov ecx, [tls_in_len]
    sub ecx, eax
    mov [tls_in_len], ecx
    sub r8d, eax
    mov dword [tls_in_pos], 0
    rep movsb
    pop rcx
    ; the window we advertised had (nearly) closed: tell the sender there is
    ; room again rather than wait for its window probe
    cmp dword [tcp_last_window], TLS_RECORD_MAX
    jae .poll
    cmp byte [tcp_active_state], TCP_STATE_ESTABLISHED
    jne .poll
    push rax
    push rcx
    mov al, TCP_FLAG_ACK
    xor ecx, ecx
    call tcp_send_segment
    pop rcx
    pop rax
.poll:
    call net_wait_step
    cmp [tls_in_len], r8d
    je .no_progress
    mov r8d, [tls_in_len]
    jmp .deadline
.no_progress:
    cmp [timer_ticks], rdx
    jb .check
.ended:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    stc
    ret
.ok:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    clc
    ret

; ------------------------------------------------------------------------------
; tls_read_record: the next whole record
; Output: AL = content type, RSI = fragment (the 5-byte header is at RSI - 5),
;         ECX = fragment length; CF=1 at the end of the connection or on a
;         malformed length (then tls_error_msg is set)
; ------------------------------------------------------------------------------
tls_read_record:
    push rdx
    mov ecx, 5
    call tls_wait
    jc .end
    lea rsi, [tls_in_buf]
    mov edx, [tls_in_pos]
    add rsi, rdx
    movzx ecx, byte [rsi + 3]
    shl ecx, 8
    mov cl, [rsi + 4]
    cmp ecx, TLS_RECORD_MAX
    ja .bad
    add ecx, 5
    call tls_wait                   ; may move the data: recompute RSI
    jc .end
    lea rsi, [tls_in_buf]
    mov edx, [tls_in_pos]
    add rsi, rdx
    add [tls_in_pos], ecx
    sub ecx, 5
    mov al, [rsi]
    add rsi, 5
    pop rdx
    clc
    ret
.bad:
    lea rsi, [tls_err_record]
    mov [tls_error_msg], rsi
.end:
    pop rdx
    stc
    ret

; ------------------------------------------------------------------------------
; tls_decrypt: RSI = protected record fragment, ECX = its length. Decrypted in
; place with the server key. Output: AL = real content type, ECX = content
; length (padding removed); CF=1 if it fails authentication (tls_error_msg set)
; ------------------------------------------------------------------------------
tls_decrypt:
    push rbx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    cmp ecx, 17                     ; at least the type byte and the tag
    jb .bad
    lea rbx, [tls_server_dir]
    call tls_make_nonce
    lea r9, [rsi - 5]               ; AAD = record header
    mov r10d, 5
    mov rdi, rsi
    lea r8d, [ecx - 16]
    push rsi
    lea rsi, [rbx + TLS_DIR_KEY]
    lea rdx, [tls_nonce]
    call aead_open
    pop rsi
    jc .bad
    inc qword [rbx + TLS_DIR_SEQ]
    ; TLSInnerPlaintext = content | type | zero padding
    mov rcx, r8
.strip:
    test rcx, rcx
    jz .bad
    dec rcx
    mov al, [rsi + rcx]
    test al, al
    jz .strip
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rbx
    clc
    ret
.bad:
    lea rdi, [tls_err_mac]
    mov [tls_error_msg], rdi
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rbx
    stc
    ret

; ------------------------------------------------------------------------------
; tls_send_record: AL = content type, RSI = content, ECX = length
; (at most TLS_OUT_MAX - 32). Encrypted with the client key and sent.
; ------------------------------------------------------------------------------
tls_send_record:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov ecx, ecx                    ; the length is 32-bit
    lea rdi, [tls_out_buf]
    mov byte [rdi], TLS_CT_APPDATA  ; every protected record looks like app data
    mov word [rdi + 1], 0x0303
    lea r8d, [ecx + 1]              ; R8 = content + type byte
    lea edx, [ecx + 17]
    mov [rdi + 3], dh
    mov [rdi + 4], dl
    add rdi, 5
    rep movsb
    mov [rdi], al
    lea rbx, [tls_client_dir]
    call tls_make_nonce
    lea r9, [tls_out_buf]
    mov r10d, 5
    lea rdi, [tls_out_buf + 5]
    lea rsi, [rbx + TLS_DIR_KEY]
    lea rdx, [tls_nonce]
    call aead_seal
    inc qword [rbx + TLS_DIR_SEQ]
    lea rsi, [tls_out_buf]
    lea rcx, [r8 + 5 + 16]
    call tcp_send_data
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

; ------------------------------------------------------------------------------
; tls_alert: RSI = alert content (level, description) -> error "server sent
; alert <n>", CF=1
; ------------------------------------------------------------------------------
tls_alert:
    push rax
    push rdi
    movzx eax, byte [rsi + 1]
    push rsi
    lea rsi, [klog_tls_alert]
    call klog_dec
    lea rdi, [tls_err_buf]
    lea rsi, [tls_err_alert]
    call fmt_str
    call fmt_dec
    pop rsi
    pop rdi
    pop rax
    push rsi
    lea rsi, [tls_err_buf]
    mov [tls_error_msg], rsi
    pop rsi
    stc
    ret

; ==============================================================================
; Handshake messages (reassembled in tls_hs_buf)
; ==============================================================================

; tls_hs_append: RSI = data, ECX = length -> CF=1 if the buffer would overflow
tls_hs_append:
    push rax
    push rcx
    push rsi
    push rdi
    mov eax, TLS_HS_MAX
    sub eax, [tls_hs_len]
    cmp ecx, eax
    ja .big
    lea rdi, [tls_hs_buf]
    mov eax, [tls_hs_len]
    add rdi, rax
    add [tls_hs_len], ecx
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    pop rax
    clc
    ret
.big:
    lea rdi, [tls_err_big]
    mov [tls_error_msg], rdi
    pop rdi
    pop rsi
    pop rcx
    pop rax
    stc
    ret

; tls_hs_peek: CF=1 if no whole message is buffered; otherwise AL = type,
; RSI = message (4-byte header included), ECX = its total length
tls_hs_peek:
    push rdx
    mov edx, [tls_hs_len]
    cmp edx, 4
    jb .none
    lea rsi, [tls_hs_buf]
    movzx ecx, byte [rsi + 1]
    shl ecx, 8
    mov cl, [rsi + 2]
    shl ecx, 8
    mov cl, [rsi + 3]
    add ecx, 4
    cmp ecx, edx
    ja .none
    mov al, [rsi]
    pop rdx
    clc
    ret
.none:
    pop rdx
    stc
    ret

; tls_hs_consume: ECX = bytes to drop from the front of tls_hs_buf
tls_hs_consume:
    push rcx
    push rsi
    push rdi
    lea rdi, [tls_hs_buf]
    lea rsi, [rdi + rcx]
    sub [tls_hs_len], ecx
    mov ecx, [tls_hs_len]
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; tls_send_client_hello: RDI = server name (SNI is left out for an IP address)
; ------------------------------------------------------------------------------
tls_send_client_hello:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rdx, rdi                    ; RDX = host name

    lea rdi, [tls_out_buf]
    mov byte [rdi], TLS_CT_HANDSHAKE
    mov word [rdi + 1], 0x0103      ; legacy record version 3.1
    mov byte [rdi + 5], 1           ; ClientHello
    mov word [rdi + 9], 0x0303      ; legacy_version 1.2
    push rdi
    add rdi, 11
    mov ecx, 32
    call rand_bytes                 ; random
    pop rdi
    mov byte [rdi + 43], 0          ; no legacy session id
    mov dword [rdi + 44], 0x03130200 ; cipher_suites: 00 02 | 13 03
    mov word [rdi + 48], 0x0001     ; compression_methods: 01 | 00
    lea rbx, [rdi + 50]             ; RBX = extensions length field
    add rdi, 52

    ; server_name, unless the host is an IP address
    mov rsi, rdx
    call tls_is_ip_literal
    jc .no_sni
    call strlen                     ; RAX = name length
    mov word [rdi], 0               ; type server_name
    lea ecx, [eax + 5]
    xchg cl, ch
    mov [rdi + 2], cx
    lea ecx, [eax + 3]
    xchg cl, ch
    mov [rdi + 4], cx
    mov byte [rdi + 6], 0           ; host_name
    mov ecx, eax
    xchg cl, ch
    mov [rdi + 7], cx
    add rdi, 9
    mov ecx, eax
    rep movsb
.no_sni:
    lea rsi, [tls_ch_extensions]
    mov ecx, TLS_CH_EXTENSIONS_LEN
    rep movsb
    lea rsi, [tls_pub]
    mov ecx, 32
    rep movsb

    ; fill in the three lengths
    lea rsi, [tls_out_buf]
    mov rcx, rdi
    sub rcx, rbx
    sub ecx, 2
    xchg cl, ch
    mov [rbx], cx                   ; extensions
    mov rcx, rdi
    sub rcx, rsi
    sub ecx, 9                      ; handshake body (24-bit)
    mov byte [rsi + 6], 0
    mov [rsi + 8], cl
    mov [rsi + 7], ch
    add ecx, 4                      ; record fragment = whole handshake message
    mov [rsi + 4], cl
    mov [rsi + 3], ch

    ; transcript gets the handshake message; the wire gets the record
    add rsi, 5
    call tls_th_update
    sub rsi, 5
    add ecx, 5
    call tcp_send_data

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; tls_is_ip_literal: RSI = host -> CF=1 if it is only digits and dots
tls_is_ip_literal:
    push rax
    push rsi
.char:
    lodsb
    test al, al
    jz .yes
    cmp al, '.'
    je .char
    cmp al, '0'
    jb .no
    cmp al, '9'
    jbe .char
.no:
    pop rsi
    pop rax
    clc
    ret
.yes:
    pop rsi
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; tls_read_server_hello: CF=1 on failure (tls_error_msg set)
; ------------------------------------------------------------------------------
tls_read_server_hello:
    push rax
    push rcx
    push rsi
.record:
    call tls_read_record
    jc .closed
    cmp al, TLS_CT_HANDSHAKE
    je .handshake
    cmp al, TLS_CT_ALERT
    jne .unexpected
    call tls_alert
    jmp .out
.handshake:
    call tls_hs_append
    jc .out
    call tls_hs_peek
    jc .record
    cmp al, TLS_HS_SERVER_HELLO
    jne .unexpected
    call tls_process_server_hello
    jc .out
    call tls_th_update
    call tls_hs_consume
    clc
    jmp .out
.closed:
    cmp qword [tls_error_msg], 0
    jne .fail
    lea rsi, [tls_err_closed]
    call tls_fail
    jmp .out
.unexpected:
    lea rsi, [tls_err_unexpected]
    call tls_fail
    jmp .out
.fail:
    stc
.out:
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; tls_process_server_hello: RSI = ServerHello message, ECX = its length
; -> tls_server_pub; CF=1 if it is not a TLS 1.3 ChaCha20 / X25519 answer
; ------------------------------------------------------------------------------
tls_process_server_hello:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    lea r8, [rsi + rcx]             ; R8 = end of message
    lea rdi, [rsi + 4]              ; RDI = body
    lea rax, [rdi + 35]
    cmp rax, r8
    ja .malformed
    ; random == HelloRetryRequest magic?
    push rdi
    lea rsi, [rdi + 2]
    lea rdi, [tls_hrr_random]
    mov ecx, 32
    repe cmpsb
    pop rdi
    je .hrr
    add rdi, 34
    movzx eax, byte [rdi]           ; legacy_session_id_echo
    lea rdi, [rdi + rax + 1]
    lea rax, [rdi + 5]
    cmp rax, r8
    ja .malformed
    cmp word [rdi], 0x0313          ; TLS_CHACHA20_POLY1305_SHA256
    jne .cipher
    add rdi, 3                      ; cipher suite, compression method
    movzx edx, word [rdi]
    xchg dl, dh
    add rdi, 2
    lea r9, [rdi + rdx]             ; R9 = end of extensions
    cmp r9, r8
    ja .malformed
    mov byte [tls_got_version], 0
    mov byte [tls_got_key], 0
.ext:
    lea rax, [rdi + 4]
    cmp rax, r9
    ja .ext_done
    movzx eax, word [rdi]
    xchg al, ah
    movzx edx, word [rdi + 2]
    xchg dl, dh
    add rdi, 4
    lea r10, [rdi + rdx]
    cmp r10, r9
    ja .malformed
    cmp eax, 0x002b                 ; supported_versions
    jne .not_version
    cmp edx, 2
    jne .next
    cmp word [rdi], 0x0403          ; 03 04 = TLS 1.3
    jne .next
    mov byte [tls_got_version], 1
    jmp .next
.not_version:
    cmp eax, 0x0033                 ; key_share
    jne .next
    cmp edx, 36
    jne .next
    cmp dword [rdi], 0x20001d00     ; x25519, 32-byte key
    jne .next
    lea rsi, [rdi + 4]
    push rdi
    lea rdi, [tls_server_pub]
    mov ecx, 32
    rep movsb
    pop rdi
    mov byte [tls_got_key], 1
.next:
    mov rdi, r10
    jmp .ext
.ext_done:
    cmp byte [tls_got_version], 1
    jne .version
    cmp byte [tls_got_key], 1
    jne .no_key
    clc
    jmp .out
.malformed:
    lea rsi, [tls_err_record]
    jmp .fail
.hrr:
    lea rsi, [tls_err_hrr]
    jmp .fail
.cipher:
    lea rsi, [tls_err_cipher]
    jmp .fail
.version:
    lea rsi, [tls_err_version]
    jmp .fail
.no_key:
    lea rsi, [tls_err_key]
.fail:
    call tls_fail
.out:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; tls_handshake_keys: ECDHE and the handshake traffic keys. CF=1 on a bad share
; ------------------------------------------------------------------------------
tls_handshake_keys:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push rbx

    lea rsi, [tls_priv]
    lea rdx, [tls_server_pub]
    lea rdi, [tls_shared]
    call x25519
    ; an all-zero result means a low-order point
    xor eax, eax
    or rax, [tls_shared]
    or rax, [tls_shared + 8]
    or rax, [tls_shared + 16]
    or rax, [tls_shared + 24]
    jz .bad_share

    ; Hash("") for the "derived" steps
    lea rsi, [tls_zero32]
    xor ecx, ecx
    lea rdi, [tls_empty_hash]
    call sha256
    ; early secret = HKDF-Extract(0, 0)
    lea rsi, [tls_zero32]
    mov ecx, 32
    lea rdx, [tls_zero32]
    mov r8d, 32
    lea rdi, [tls_secret]
    call hmac_sha256
    ; handshake secret = HKDF-Extract(Derive-Secret(early, "derived", ""), ECDHE)
    lea rsi, [tls_secret]
    lea rdx, [tls_lbl_derived]
    lea r8, [tls_empty_hash]
    mov r9d, 32
    mov ecx, 32
    lea rdi, [tls_secret]
    call tls_expand_label
    lea rsi, [tls_secret]
    mov ecx, 32
    lea rdx, [tls_shared]
    mov r8d, 32
    lea rdi, [tls_hs_secret]
    call hmac_sha256
    ; traffic secrets over ClientHello..ServerHello
    call tls_th_snapshot
    lea rsi, [tls_hs_secret]
    lea rdx, [tls_lbl_c_hs]
    lea rdi, [tls_c_hs]
    call tls_derive
    lea rdx, [tls_lbl_s_hs]
    lea rdi, [tls_s_hs]
    call tls_derive
    lea rsi, [tls_c_hs]
    lea rbx, [tls_client_dir]
    call tls_set_keys
    lea rsi, [tls_s_hs]
    lea rbx, [tls_server_dir]
    call tls_set_keys
    clc
    jmp .out
.bad_share:
    lea rsi, [tls_err_ecdh]
    call tls_fail
.out:
    pop rbx
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; tls_read_server_flight: EncryptedExtensions, Certificate, CertificateVerify
; and Finished. Only Finished is checked. CF=1 on failure.
; ------------------------------------------------------------------------------
tls_read_server_flight:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
.record:
    call tls_read_record
    jc .closed
    cmp al, TLS_CT_CCS              ; middlebox compatibility: ignore
    je .record
    cmp al, TLS_CT_ALERT
    je .alert
    cmp al, TLS_CT_APPDATA
    jne .unexpected
    call tls_decrypt
    jc .out
    cmp al, TLS_CT_ALERT
    je .alert
    cmp al, TLS_CT_HANDSHAKE
    jne .unexpected
    call tls_hs_append
    jc .out
.message:
    call tls_hs_peek
    jc .record
    cmp al, TLS_HS_FINISHED
    je .finished
    cmp al, TLS_HS_CERT_REQUEST
    je .cert_request
    cmp al, TLS_HS_ENC_EXTENSIONS
    je .hash_it
    cmp al, TLS_HS_CERTIFICATE
    jne .not_certificate
    call tls_process_certificate    ; chain, dates and host name
    jc .out
    jmp .hash_it
.not_certificate:
    cmp al, TLS_HS_CERT_VERIFY
    jne .unexpected
    call tls_process_cert_verify    ; before it joins the transcript
    jc .out
.hash_it:
    call tls_th_update
    call tls_hs_consume
    jmp .message

.finished:
    ; the server must have proved its identity first (unless told not to check)
    cmp byte [tls_insecure], 0
    jne .auth_ok
    cmp byte [tls_got_cert], 1
    jne .no_auth
    cmp byte [tls_got_cv], 1
    jne .no_auth
.auth_ok:
    ; verify_data = HMAC(finished_key, Hash(ClientHello..CertificateVerify))
    cmp ecx, 4 + 32
    jne .bad_finished
    call tls_th_snapshot
    push rsi
    push rcx
    lea rsi, [tls_s_hs]
    lea rdx, [tls_lbl_finished]
    xor r9d, r9d
    mov ecx, 32
    lea rdi, [tls_fin_key]
    call tls_expand_label
    lea rsi, [tls_fin_key]
    mov ecx, 32
    lea rdx, [tls_th]
    mov r8d, 32
    lea rdi, [tls_verify]
    call hmac_sha256
    pop rcx
    pop rsi
    push rsi
    push rcx
    add rsi, 4
    mov ecx, 32
    repe cmpsb
    pop rcx
    pop rsi
    jne .bad_finished
    call tls_th_update
    call tls_hs_consume
    clc
    jmp .out

.alert:
    call tls_alert
    jmp .out
.closed:
    cmp qword [tls_error_msg], 0
    jne .fail
    lea rsi, [tls_err_closed]
    call tls_fail
    jmp .out
.unexpected:
    lea rsi, [tls_err_unexpected]
    call tls_fail
    jmp .out
.cert_request:
    lea rsi, [tls_err_certreq]
    call tls_fail
    jmp .out
.bad_finished:
    lea rsi, [tls_err_finished]
    call tls_fail
    jmp .out
.no_auth:
    lea rsi, [tls_err_no_auth]
    call tls_fail
    jmp .out
.fail:
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; tls_process_certificate: RSI = Certificate message, ECX = its length.
; Keeps a copy, parses up to X509_MAX_CHAIN certificates into x509_chain and,
; unless tls_insecure, verifies them for tls_host. CF=1 on failure.
; ------------------------------------------------------------------------------
tls_process_certificate:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    cmp byte [tls_insecure], 0
    jne .ok
    ; copy: x509_chain will point into it after tls_hs_buf moves on
    lea rdi, [tls_cert_buf]
    push rdi
    rep movsb
    pop rsi
    mov r9, rdi                     ; R9 = end
    add rsi, 4                      ; handshake header
    ; certificate_request_context<0..255>
    lea rax, [rsi + 4]
    cmp rax, r9
    ja .malformed
    movzx eax, byte [rsi]
    lea rsi, [rsi + rax + 1]
    ; certificate_list<0..2^24-1>
    lea rax, [rsi + 3]
    cmp rax, r9
    ja .malformed
    call .u24
    add rsi, 3
    lea r10, [rsi + rax]            ; R10 = end of the list
    cmp r10, r9
    ja .malformed
    xor r8d, r8d                    ; R8 = certificates kept
    lea rdi, [x509_chain]
.entry:
    lea rax, [rsi + 3]
    cmp rax, r10
    ja .list_done
    cmp r8d, X509_MAX_CHAIN
    jae .list_done
    call .u24                       ; cert_data<1..2^24-1>
    add rsi, 3
    lea rdx, [rsi + rax]
    cmp rdx, r10
    ja .malformed
    mov ecx, eax
    call x509_parse
    jnc .kept
    test r8d, r8d                   ; an unreadable extra certificate is skipped,
    jz .malformed                   ; an unreadable server certificate is fatal
    jmp .extensions
.kept:
    inc r8d
    add rdi, CERT_SIZE
.extensions:
    mov rsi, rdx
    lea rax, [rsi + 2]              ; extensions<0..2^16-1>
    cmp rax, r10
    ja .malformed
    movzx eax, word [rsi]
    xchg al, ah
    lea rsi, [rsi + rax + 2]
    jmp .entry
.list_done:
    mov [x509_chain_count], r8d
    mov rsi, [tls_host]
    call x509_verify_chain
    jc .x509_failed
    mov byte [tls_got_cert], 1
.ok:
    clc
    jmp .out
.x509_failed:
    mov rsi, [x509_error]
    call tls_fail
    jmp .out
.malformed:
    lea rsi, [tls_err_cert_msg]
    call tls_fail
.out:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
; .u24: RSI = 24-bit big-endian length -> EAX
.u24:
    movzx eax, byte [rsi]
    shl eax, 8
    mov al, [rsi + 1]
    shl eax, 8
    mov al, [rsi + 2]
    ret

; ------------------------------------------------------------------------------
; tls_process_cert_verify: RSI = CertificateVerify message, ECX = its length.
; Checks the signature over 64 spaces | context string | 0 | transcript hash
; with the server certificate's key. CF=1 on failure.
; ------------------------------------------------------------------------------
tls_process_cert_verify:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    cmp byte [tls_insecure], 0
    jne .ok
    cmp byte [tls_got_cert], 1
    jne .no_auth
    ; body: SignatureScheme algorithm, signature<0..2^16-1>
    cmp ecx, 4 + 4
    jb .bad
    movzx eax, word [rsi + 4]
    xchg al, ah                     ; AX = SignatureScheme
    movzx r8d, byte [rsi + 6]
    shl r8d, 8
    mov r8b, [rsi + 7]              ; R8 = signature length
    lea edx, [r8d + 8]
    cmp edx, ecx
    ja .bad
    lea rdx, [rsi + 8]              ; RDX = signature
    ; scheme -> hash (| RSA scheme << 8) and the key type it needs
    lea rbx, [x509_chain + CERT_PK]
    mov cl, [rbx + PK_TYPE]
    mov ch, PK_TYPE_P256
    cmp ax, 0x0403                  ; ecdsa_secp256r1_sha256
    mov eax, HASH_SHA256
    je .check_key
    movzx eax, word [rsi + 4]
    xchg al, ah
    mov ch, PK_TYPE_P384
    cmp ax, 0x0503                  ; ecdsa_secp384r1_sha384
    mov eax, HASH_SHA384
    je .check_key
    movzx eax, word [rsi + 4]
    xchg al, ah
    mov ch, PK_TYPE_RSA
    cmp ax, 0x0804                  ; rsa_pss_rsae_sha256
    mov eax, HASH_SHA256 | (RSA_SCHEME_PSS << 8)
    je .check_key
    movzx eax, word [rsi + 4]
    xchg al, ah
    cmp ax, 0x0805                  ; rsa_pss_rsae_sha384
    mov eax, HASH_SHA384 | (RSA_SCHEME_PSS << 8)
    je .check_key
    movzx eax, word [rsi + 4]
    xchg al, ah
    cmp ax, 0x0806                  ; rsa_pss_rsae_sha512
    mov eax, HASH_SHA512 | (RSA_SCHEME_PSS << 8)
    jne .alg
.check_key:
    cmp cl, ch
    jne .alg
.content:
    ; 64 spaces | "TLS 1.3, server CertificateVerify" | 0 | Hash(ClientHello..Certificate)
    push rax
    push rsi
    lea rdi, [tls_cv_content]
    mov al, ' '
    mov ecx, 64
    rep stosb
    lea rsi, [tls_cv_context]
    mov ecx, 34
    rep movsb
    call tls_th_snapshot
    lea rsi, [tls_th]
    mov ecx, 32
    rep movsb
    pop rsi
    pop rax
    lea rsi, [tls_cv_content]
    mov ecx, 64 + 34 + 32
    call sig_verify
    jc .bad_sig
    mov byte [tls_got_cv], 1
.ok:
    clc
    jmp .out
.alg:
    lea rsi, [tls_err_cv_alg]
    call tls_fail
    jmp .out
.bad_sig:
    lea rsi, [tls_err_cv_bad]
    call tls_fail
    jmp .out
.no_auth:
    lea rsi, [tls_err_no_auth]
    call tls_fail
    jmp .out
.bad:
    lea rsi, [tls_err_cert_msg]
    call tls_fail
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; tls_finish_handshake: send our Finished and switch both directions to the
; application traffic keys
; ------------------------------------------------------------------------------
tls_finish_handshake:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9

    call tls_th_snapshot            ; Hash(ClientHello..server Finished)

    ; client Finished
    lea rsi, [tls_c_hs]
    lea rdx, [tls_lbl_finished]
    xor r9d, r9d
    mov ecx, 32
    lea rdi, [tls_fin_key]
    call tls_expand_label
    lea rsi, [tls_fin_key]
    mov ecx, 32
    lea rdx, [tls_th]
    mov r8d, 32
    lea rdi, [tls_msg + 4]
    call hmac_sha256
    mov dword [tls_msg], 0x20000014 ; Finished, length 32
    mov al, TLS_CT_HANDSHAKE
    lea rsi, [tls_msg]
    mov ecx, 36
    call tls_send_record

    ; master secret = HKDF-Extract(Derive-Secret(handshake, "derived", ""), 0)
    lea rsi, [tls_hs_secret]
    lea rdx, [tls_lbl_derived]
    lea r8, [tls_empty_hash]
    mov r9d, 32
    mov ecx, 32
    lea rdi, [tls_secret]
    call tls_expand_label
    lea rsi, [tls_secret]
    mov ecx, 32
    lea rdx, [tls_zero32]
    mov r8d, 32
    lea rdi, [tls_secret]
    call hmac_sha256
    ; application traffic secrets over ClientHello..server Finished
    lea rsi, [tls_secret]
    lea rdx, [tls_lbl_c_ap]
    lea rdi, [tls_c_ap]
    call tls_derive
    lea rdx, [tls_lbl_s_ap]
    lea rdi, [tls_s_ap]
    call tls_derive
    lea rsi, [tls_c_ap]
    lea rbx, [tls_client_dir]
    call tls_set_keys
    lea rsi, [tls_s_ap]
    lea rbx, [tls_server_dir]
    call tls_set_keys

    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; tls_read_response: application data into http_resp_buf until close_notify,
; the end of the connection, a failed record or TLS_IDLE_MS of silence.
; NewSessionTicket is ignored; KeyUpdate from the server is followed.
; ------------------------------------------------------------------------------
tls_read_response:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    mov dword [tls_hs_len], 0
.record:
    call tls_read_record
    jc .done
    cmp al, TLS_CT_CCS
    je .record
    cmp al, TLS_CT_APPDATA
    jne .done                       ; a plaintext alert (or junk) ends it
    call tls_decrypt
    jc .failed
    cmp al, TLS_CT_APPDATA
    je .data
    cmp al, TLS_CT_HANDSHAKE
    je .post_handshake
    cmp al, TLS_CT_ALERT
    jne .record
    movzx eax, byte [rsi + 1]       ; close_notify (0) or an error
    lea rsi, [klog_tls_alert]
    call klog_dec
    jmp .done
.data:
    call tls_resp_append
    cmp dword [http_resp_len], HTTP_RESP_MAX
    jb .record                      ; full: the rest would be thrown away anyway
    jmp .done
.post_handshake:
    call tls_hs_append
    jc .failed
.message:
    call tls_hs_peek
    jc .record
    cmp al, TLS_HS_KEY_UPDATE
    jne .skip
    ; new server secret = HKDF-Expand-Label(secret, "traffic upd", "", 32)
    push rcx
    lea rsi, [tls_s_ap]
    lea rdx, [tls_lbl_update]
    xor r9d, r9d
    mov ecx, 32
    lea rdi, [tls_s_ap]
    call tls_expand_label
    lea rbx, [tls_server_dir]
    call tls_set_keys
    pop rcx
.skip:
    call tls_hs_consume
    jmp .message
.failed:
    mov rsi, [tls_error_msg]
    test rsi, rsi
    jz .done
    mov rdi, rsi
    lea rsi, [klog_tls_error]
    call klog2
.done:
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; tls_resp_append: RSI = data, ECX = length -> end of http_resp_buf (clamped)
tls_resp_append:
    push rax
    push rcx
    push rsi
    push rdi
    mov eax, HTTP_RESP_MAX
    sub eax, [http_resp_len]
    cmp ecx, eax
    jbe .fits
    mov ecx, eax
.fits:
    lea rdi, [abs http_resp_buf]
    mov eax, [http_resp_len]
    add rdi, rax
    add [http_resp_len], ecx
    rep movsb
    mov byte [rdi], 0
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ==============================================================================
; tls_https_get: HTTPS GET, the TLS twin of tcp_http_client
; Input:  RSI = server IP (4 bytes), RDI = host name (SNI and Host header),
;         DX = port, R8 = path (0 = "/")
; Output: RAX = 0 on success (http_resp_buf / http_resp_len hold the response),
;         1 on failure (tls_error_msg says why)
; The certificate is verified unless tls_insecure is set; tls_verified says
; whether it was.
; ==============================================================================
tls_https_get:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r12
    push r13
    push r15
    mov r12, rsi                    ; R12 = IP
    mov r15, rdi                    ; R15 = host
    mov r13, r8                     ; R13 = path

    mov qword [tls_error_msg], 0
    mov [tls_host], r15
    mov byte [tls_verified], 0
    mov byte [tls_got_cert], 0
    mov byte [tls_got_cv], 0
    mov dword [x509_chain_count], 0
    mov dword [http_resp_len], 0
    mov byte [abs http_resp_buf], 0
    mov dword [tls_in_len], 0
    mov dword [tls_in_pos], 0
    mov dword [tls_hs_len], 0
    lea rdi, [tls_th_ctx]
    call sha256_init

    ; ephemeral X25519 key pair
    lea rdi, [tls_priv]
    mov ecx, 32
    call rand_bytes
    lea rsi, [tls_priv]
    lea rdi, [tls_pub]
    call x25519_base

    mov byte [tcp_rx_to_tls], 1
    mov rsi, r12
    call tcp_connect
    jc .no_connect

    mov rdi, r15
    call tls_send_client_hello
    call tls_read_server_hello
    jc .fail
    call tls_handshake_keys
    jc .fail
    call tls_read_server_flight
    jc .fail
    call tls_finish_handshake
    lea rsi, [klog_tls_done]
    call klog
    lea rsi, [klog_tls_insecure]
    cmp byte [tls_insecure], 0
    jne .say_trust
    mov byte [tls_verified], 1
    lea rsi, [klog_tls_verified]
    mov rdi, r15
    call klog2
    jmp .trust_said
.say_trust:
    call klog
.trust_said:

    mov rdi, r15
    mov r8, r13
    call http_build_request
    lea rsi, [http_req_buf]
    mov al, TLS_CT_APPDATA
    call tls_send_record
    call tls_read_response
    mov eax, [http_resp_len]
    lea rsi, [klog_tls_bytes]
    call klog_dec
    xor eax, eax
    jmp .out

.no_connect:
    lea rsi, [tls_err_connect]
    mov [tls_error_msg], rsi
.fail:
    mov rdi, [tls_error_msg]
    lea rsi, [klog_tls_error]
    call klog2
    mov eax, 1
.out:
    call tcp_abort                  ; still open (big page, error): reset it
    mov byte [tcp_rx_to_tls], 0
    pop r15
    pop r13
    pop r12
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
