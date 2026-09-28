; ==============================================================================
; Antigravity OS - X.509 certificates: parsing and chain verification
; ------------------------------------------------------------------------------
; Enough of RFC 5280 for TLS server certificates:
;   - DER parsing of the fields that matter: to-be-signed bytes, signature
;     algorithm and value, issuer and subject names, validity, public key
;     (RSA, EC P-256, EC P-384), subjectAltName and basicConstraints
;   - chain building from the server's certificates to a trusted root, checking
;     each signature, each validity period and the CA flag of intermediates
;   - host name matching against DNS names (with a leftmost "*." wildcard) and
;     IP addresses in subjectAltName
; Trusted roots: the Mozilla set compiled in (kernel/data/roots.der, made by
; tools/mkroots.py) plus any DER certificates in the AFS file localca.der.
;
; Not implemented: revocation (OCSP/CRL), name constraints, policy
; constraints, path length limits and critical-extension enforcement.
; ==============================================================================

[bits 64]

; parsed certificate
CERT_TBS                equ 0       ; dq to-be-signed TLV (what the signature covers)
CERT_TBS_LEN            equ 8       ; dd
CERT_SIG                equ 16      ; dq signature (BIT STRING contents)
CERT_SIG_LEN            equ 24      ; dd
CERT_ISSUER             equ 32      ; dq issuer Name TLV
CERT_ISSUER_LEN         equ 40      ; dd
CERT_SUBJECT            equ 48      ; dq subject Name TLV
CERT_SUBJECT_LEN        equ 56      ; dd
CERT_SAN                equ 64      ; dq GeneralNames contents
CERT_SAN_LEN            equ 72      ; dd
CERT_SIG_HASH           equ 76      ; db HASH_*, 0 = unsupported
CERT_SIG_KIND           equ 77      ; db SIG_KIND_*
CERT_IS_CA              equ 78      ; db basicConstraints cA
CERT_HAS_SAN            equ 79      ; db
CERT_NOT_BEFORE         equ 80      ; "YYYYMMDDHHMMSS" + NUL
CERT_NOT_AFTER          equ 96
CERT_PK                 equ 112     ; public key record (PK_SIZE)
CERT_SIZE               equ 160

SIG_KIND_RSA            equ 1
SIG_KIND_ECDSA          equ 2

X509_MAX_CHAIN          equ 8       ; certificates we keep from the server
X509_MAX_DEPTH          equ 6
X509_LOCAL_MAX          equ 16384   ; localca.der

section .data
align 8
x509_error:             dq 0        ; why the last verification failed

section .bss
alignb 16
x509_chain:             resb CERT_SIZE * X509_MAX_CHAIN
x509_chain_count:       resd 1
x509_root_cert:         resb CERT_SIZE
x509_now:               resb 16     ; current time, "YYYYMMDDHHMMSS"
x509_ip:                resb 4
x509_name:              resb 64     ; a common name for the log
x509_local_len:         resd 1
x509_local:             resb X509_LOCAL_MAX

section .rodata
x509_roots:             incbin "data/roots.der"
x509_roots_end:
; OIDs, each prefixed by its length
oid_rsa_key:            db 9, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01
oid_ec_key:             db 7, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01
oid_p256:               db 8, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07
oid_p384:               db 5, 0x2B, 0x81, 0x04, 0x00, 0x22
oid_san:                db 3, 0x55, 0x1D, 0x11
oid_basic:              db 3, 0x55, 0x1D, 0x13
oid_cn:                 db 3, 0x55, 0x04, 0x03
x509_rsa_sig_prefix:    db 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01   ; then 0B/0C/0D
x509_ecdsa_sig_prefix:  db 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03         ; then 02/03/04
x509_localca_name:      db "localca.der", 0

x509_err_malformed:     db "certificate is malformed", 0
x509_err_unsupported:   db "certificate uses an unsupported key or signature type", 0
x509_err_expired:       db "certificate has expired", 0
x509_err_not_yet:       db "certificate is not valid yet", 0
x509_err_host:          db "certificate is not for this host name", 0
x509_err_signature:     db "certificate signature is invalid", 0
x509_err_untrusted:     db "certificate is not from a trusted authority", 0
x509_err_not_ca:        db "intermediate certificate is not a CA", 0
x509_err_too_long:      db "certificate chain is too long", 0
x509_err_none:          db "server sent no certificate", 0

klog_x509_leaf:         db "x509: server certificate ", 0
klog_x509_issuer:       db "x509: signed by ", 0
klog_x509_root:         db "x509: trusted root ", 0
klog_x509_error:        db "x509: error: ", 0

section .text
; ==============================================================================
; DER
; ==============================================================================

; ------------------------------------------------------------------------------
; der_next: RSI = element, R9 = end of the enclosing data
; Output: AL = tag, RDX = contents, RCX = contents length, R8 = next element;
;         CF=1 if it overruns R9 or uses a length form longer than 3 bytes
; ------------------------------------------------------------------------------
der_next:
    push rbx
    lea rbx, [rsi + 2]
    cmp rbx, r9
    ja .bad
    mov al, [rsi]
    movzx ecx, byte [rsi + 1]
    lea rdx, [rsi + 2]
    cmp ecx, 0x80
    jb .have
    sub ecx, 0x80                   ; number of length bytes
    jz .bad
    cmp ecx, 3
    ja .bad
    lea rbx, [rdx + rcx]
    cmp rbx, r9
    ja .bad
    push rax
    xor eax, eax
.len_byte:
    shl eax, 8
    mov al, [rdx]
    inc rdx
    dec ecx
    jnz .len_byte
    mov ecx, eax
    pop rax
.have:
    lea r8, [rdx + rcx]
    cmp r8, r9
    ja .bad
    pop rbx
    clc
    ret
.bad:
    pop rbx
    stc
    ret

; x509_oid_is: RDX = OID contents, ECX = length, RSI = length-prefixed OID
; -> ZF=1 if equal
x509_oid_is:
    push rcx
    push rsi
    push rdi
    cmp cl, [rsi]
    jne .done
    inc rsi
    mov rdi, rdx
    repe cmpsb
.done:
    pop rdi
    pop rsi
    pop rcx
    ret

; ==============================================================================
; Parsing
; ==============================================================================

; ------------------------------------------------------------------------------
; x509_parse: RSI = DER certificate, RCX = length, RDI = CERT record
; Output: CF=1 if it is not a certificate we can read
; ------------------------------------------------------------------------------
x509_parse:
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
    mov rbx, rdi
    push rcx
    xor eax, eax
    mov ecx, CERT_SIZE
    rep stosb
    pop rcx

    ; Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
    lea r9, [rsi + rcx]
    call der_next
    jc .bad
    cmp al, 0x30
    jne .bad
    mov r9, r8
    mov rsi, rdx
    call der_next                   ; tbsCertificate
    jc .bad
    cmp al, 0x30
    jne .bad
    mov [rbx + CERT_TBS], rsi
    mov rax, r8
    sub rax, rsi
    mov [rbx + CERT_TBS_LEN], eax
    mov r10, rdx                    ; R10 = tbs contents
    lea r11, [rdx + rcx]            ; R11 = tbs end
    mov rsi, r8
    call der_next                   ; signatureAlgorithm
    jc .bad
    push r8
    push r9
    mov r9, r8
    mov rsi, rdx
    call der_next                   ; its OID
    pop r9
    pop rsi                         ; RSI = signature BIT STRING
    jc .bad
    call x509_sig_alg
    call der_next
    jc .bad
    cmp al, 0x03
    jne .bad
    test ecx, ecx
    jz .bad
    inc rdx                         ; skip the unused-bits byte
    dec ecx
    mov [rbx + CERT_SIG], rdx
    mov [rbx + CERT_SIG_LEN], ecx

    ; TBSCertificate: [0] version, serial, signature, issuer, validity,
    ; subject, subjectPublicKeyInfo, [1], [2], [3] extensions
    mov rsi, r10
    mov r9, r11
    call der_next
    jc .bad
    cmp al, 0xA0
    jne .serial
    mov rsi, r8
    call der_next
    jc .bad
.serial:
    mov rsi, r8
    call der_next                   ; signature algorithm (again)
    jc .bad
    mov rsi, r8
    call der_next                   ; issuer
    jc .bad
    cmp al, 0x30
    jne .bad
    mov [rbx + CERT_ISSUER], rsi
    mov rax, r8
    sub rax, rsi
    mov [rbx + CERT_ISSUER_LEN], eax
    mov rsi, r8
    call der_next                   ; validity
    jc .bad
    cmp al, 0x30
    jne .bad
    push r8
    push r9
    mov r9, r8
    mov rsi, rdx
    call der_next
    jc .bad_validity
    lea rdi, [rbx + CERT_NOT_BEFORE]
    call x509_time
    jc .bad_validity
    mov rsi, r8
    call der_next
    jc .bad_validity
    lea rdi, [rbx + CERT_NOT_AFTER]
    call x509_time
    jc .bad_validity
    pop r9
    pop r8
    mov rsi, r8
    call der_next                   ; subject
    jc .bad
    cmp al, 0x30
    jne .bad
    mov [rbx + CERT_SUBJECT], rsi
    mov rax, r8
    sub rax, rsi
    mov [rbx + CERT_SUBJECT_LEN], eax
    mov rsi, r8
    call der_next                   ; subjectPublicKeyInfo
    jc .bad
    cmp al, 0x30
    jne .bad
    push r8
    call x509_spki
    pop r8
    jc .bad
    ; optional fields; [3] holds the extensions
.optional:
    cmp r8, r11
    jae .good
    mov rsi, r8
    call der_next
    jc .bad
    cmp al, 0xA3
    jne .optional
    push r8
    call x509_extensions
    pop r8
    jc .bad
    jmp .optional
.good:
    clc
    jmp .out
.bad_validity:
    pop r9
    pop r8
.bad:
    stc
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
    pop rax
    ret

; x509_sig_alg: RDX = signature algorithm OID, ECX = length, RBX = cert
; -> CERT_SIG_HASH / CERT_SIG_KIND (left 0 when unsupported)
x509_sig_alg:
    push rax
    push rcx
    push rsi
    push rdi
    cmp ecx, 9
    jne .ecdsa
    lea rsi, [x509_rsa_sig_prefix]
    mov rdi, rdx
    mov ecx, 8
    repe cmpsb
    jne .done
    mov al, [rdx + 8]
    sub al, 0x0B - HASH_SHA256      ; 0B, 0C, 0D -> 1, 2, 3
    mov ah, SIG_KIND_RSA
    jmp .check_hash
.ecdsa:
    cmp ecx, 8
    jne .done
    lea rsi, [x509_ecdsa_sig_prefix]
    mov rdi, rdx
    mov ecx, 7
    repe cmpsb
    jne .done
    mov al, [rdx + 7]
    sub al, 0x02 - HASH_SHA256      ; 02, 03, 04 -> 1, 2, 3
    mov ah, SIG_KIND_ECDSA
.check_hash:
    cmp al, HASH_SHA256
    jb .done
    cmp al, HASH_SHA512
    ja .done
    mov [rbx + CERT_SIG_HASH], al
    mov [rbx + CERT_SIG_KIND], ah
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; x509_time: AL = tag, RDX = contents, ECX = length, RDI = 15-byte output
; UTCTime YYMMDDHHMMSSZ (YY < 50 is 20YY) or GeneralizedTime YYYYMMDDHHMMSSZ
; become "YYYYMMDDHHMMSS". CF=1 for any other form.
; ------------------------------------------------------------------------------
x509_time:
    push rax
    push rcx
    push rsi
    push rdi
    mov rsi, rdx
    cmp al, 0x17
    je .utc
    cmp al, 0x18
    jne .bad
    cmp ecx, 15
    jne .bad
    mov ecx, 14
    jmp .copy
.utc:
    cmp ecx, 13
    jne .bad
    mov ax, '20'
    cmp byte [rsi], '5'
    jb .century
    mov ax, '19'
.century:
    mov [rdi], ax
    add rdi, 2
    mov ecx, 12
.copy:
    rep movsb
    cmp byte [rsi], 'Z'
    jne .bad
    mov byte [rdi], 0
    pop rdi
    pop rsi
    pop rcx
    pop rax
    clc
    ret
.bad:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    stc
    ret

; ------------------------------------------------------------------------------
; x509_spki: RDX = SubjectPublicKeyInfo contents, ECX = length, RBX = cert
; -> CERT_PK (PK_TYPE left 0 for key types we do not support). CF=1 if malformed.
; ------------------------------------------------------------------------------
x509_spki:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r11
    lea r9, [rdx + rcx]
    mov rsi, rdx
    call der_next                   ; AlgorithmIdentifier
    jc .bad
    cmp al, 0x30
    jne .bad
    mov r10, r8                     ; R10 = the BIT STRING
    push r9
    mov r9, r8
    mov rsi, rdx
    call der_next                   ; algorithm OID
    jc .bad_pop
    mov r11, r8                     ; R11 = parameters
    lea rsi, [oid_rsa_key]
    call x509_oid_is
    je .rsa
    lea rsi, [oid_ec_key]
    call x509_oid_is
    jne .other
    mov rsi, r11
    call der_next                   ; named curve
    jc .bad_pop
    lea rsi, [oid_p256]
    mov r11b, PK_TYPE_P256
    call x509_oid_is
    je .curve
    lea rsi, [oid_p384]
    mov r11b, PK_TYPE_P384
    call x509_oid_is
    jne .other
.curve:
    pop r9
    mov [rbx + CERT_PK + PK_TYPE], r11b
    call .key_bits
    jc .bad
    mov [rbx + CERT_PK + PK_A], rdx
    mov [rbx + CERT_PK + PK_A_LEN], ecx
    jmp .good
.rsa:
    pop r9
    call .key_bits
    jc .bad
    ; RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    mov r9, r8
    mov rsi, rdx
    call der_next
    jc .bad
    cmp al, 0x30
    jne .bad
    mov r9, r8
    mov rsi, rdx
    call der_next
    jc .bad
    cmp al, 0x02
    jne .bad
    mov [rbx + CERT_PK + PK_A], rdx
    mov [rbx + CERT_PK + PK_A_LEN], ecx
    mov rsi, r8
    call der_next
    jc .bad
    cmp al, 0x02
    jne .bad
    mov [rbx + CERT_PK + PK_B], rdx
    mov [rbx + CERT_PK + PK_B_LEN], ecx
    mov byte [rbx + CERT_PK + PK_TYPE], PK_TYPE_RSA
    jmp .good
.other:
    pop r9                          ; unsupported key: parsed, but unusable
.good:
    clc
    jmp .out
.bad_pop:
    pop r9
.bad:
    stc
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
; .key_bits: the BIT STRING at R10 (end R9) -> RDX = key bytes, ECX = length,
; R8 = end of the key
.key_bits:
    mov rsi, r10
    call der_next
    jc .kb_ret
    cmp al, 0x03
    jne .kb_bad
    test ecx, ecx
    jz .kb_bad
    cmp byte [rdx], 0               ; no unused bits
    jne .kb_bad
    inc rdx
    dec ecx
    clc
.kb_ret:
    ret
.kb_bad:
    stc
    ret

; ------------------------------------------------------------------------------
; x509_extensions: RDX = [3] contents, ECX = length, RBX = cert
; -> CERT_SAN / CERT_HAS_SAN, CERT_IS_CA. CF=1 if malformed.
; ------------------------------------------------------------------------------
x509_extensions:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    lea r9, [rdx + rcx]
    mov rsi, rdx
    call der_next                   ; Extensions ::= SEQUENCE OF Extension
    jc .bad
    cmp al, 0x30
    jne .bad
    mov r9, r8
    mov rsi, rdx
.extension:
    cmp rsi, r9
    jae .good
    call der_next                   ; Extension ::= SEQUENCE { id, critical?, value }
    jc .bad
    cmp al, 0x30
    jne .bad
    mov r10, r8                     ; next extension
    push r9
    mov r9, r8
    mov rsi, rdx
    call der_next                   ; extnID
    jc .bad_pop
    push rdx
    push rcx
    mov rsi, r8
    call der_next
    jc .bad_pop3
    cmp al, 0x01                    ; critical flag: skip it
    jne .value
    mov rsi, r8
    call der_next
    jc .bad_pop3
.value:
    cmp al, 0x04                    ; OCTET STRING holding the value
    jne .bad_pop3
    mov r8, rdx                     ; R8 = value, ECX = its length
    mov eax, ecx
    pop rcx
    pop rdx                         ; the OID again
    lea rsi, [oid_san]
    call x509_oid_is
    je .san
    lea rsi, [oid_basic]
    call x509_oid_is
    je .basic
    jmp .next
.san:
    ; GeneralNames ::= SEQUENCE OF GeneralName
    mov rsi, r8
    lea r9, [r8 + rax]
    call der_next
    jc .bad_pop
    cmp al, 0x30
    jne .bad_pop
    mov [rbx + CERT_SAN], rdx
    mov [rbx + CERT_SAN_LEN], ecx
    mov byte [rbx + CERT_HAS_SAN], 1
    jmp .next
.basic:
    ; BasicConstraints ::= SEQUENCE { cA BOOLEAN DEFAULT FALSE, ... }
    mov rsi, r8
    lea r9, [r8 + rax]
    call der_next
    jc .bad_pop
    test ecx, ecx
    jz .next
    mov rsi, rdx
    call der_next
    jc .bad_pop
    cmp al, 0x01
    jne .next
    cmp byte [rdx], 0
    je .next
    mov byte [rbx + CERT_IS_CA], 1
.next:
    pop r9
    mov rsi, r10
    jmp .extension
.good:
    clc
    jmp .out
.bad_pop3:
    pop rcx
    pop rdx
.bad_pop:
    pop r9
.bad:
    stc
.out:
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; x509_cn: RSI = Name TLV, ECX = its length -> x509_name = the common name (or
; "?"), for log lines
; ------------------------------------------------------------------------------
x509_cn:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    lea rdi, [x509_name]
    mov word [rdi], '?'
    lea r9, [rsi + rcx]
.scan:
    lea rax, [rsi + 5]
    cmp rax, r9
    ja .done
    cmp dword [rsi], 0x04550306     ; 06 03 55 04 03 = OID commonName
    jne .step
    cmp byte [rsi + 4], 0x03
    jne .step
    add rsi, 5
    call der_next
    jc .done
    cmp ecx, 63
    jbe .copy
    mov ecx, 63
.copy:
    mov rsi, rdx
    rep movsb
    mov byte [rdi], 0
    jmp .done
.step:
    inc rsi
    jmp .scan
.done:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; x509_log_name: RSI = klog prefix, RDI = CERT, AL = 0 subject / 1 issuer
x509_log_name:
    push rcx
    push rsi
    push rdi
    push rsi
    mov rsi, [rdi + CERT_SUBJECT]
    mov ecx, [rdi + CERT_SUBJECT_LEN]
    test al, al
    jz .name
    mov rsi, [rdi + CERT_ISSUER]
    mov ecx, [rdi + CERT_ISSUER_LEN]
.name:
    call x509_cn
    pop rsi
    lea rdi, [x509_name]
    call klog2
    pop rdi
    pop rsi
    pop rcx
    ret

; ==============================================================================
; Checks
; ==============================================================================

; x509_fail: RSI = reason -> x509_error, CF=1
x509_fail:
    mov [x509_error], rsi
    stc
    ret

; ------------------------------------------------------------------------------
; x509_check_time: RDI = cert -> CF=1 (x509_error set) outside its validity
; (x509_now must be filled in)
; ------------------------------------------------------------------------------
x509_check_time:
    push rcx
    push rsi
    push rdi
    push rdi
    lea rsi, [x509_now]
    lea rdi, [rdi + CERT_NOT_BEFORE]
    mov ecx, 14
    repe cmpsb
    pop rdi
    jb .not_yet                     ; now < notBefore
    lea rsi, [x509_now]
    lea rdi, [rdi + CERT_NOT_AFTER]
    mov ecx, 14
    repe cmpsb
    ja .expired                     ; now > notAfter
    pop rdi
    pop rsi
    pop rcx
    clc
    ret
.not_yet:
    lea rsi, [x509_err_not_yet]
    jmp .fail
.expired:
    lea rsi, [x509_err_expired]
.fail:
    call x509_fail
    pop rdi
    pop rsi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; x509_same_name: RSI = cert whose issuer, RDI = cert whose subject -> ZF=1 if equal
; ------------------------------------------------------------------------------
x509_same_name:
    push rcx
    push rsi
    push rdi
    mov ecx, [rsi + CERT_ISSUER_LEN]
    cmp ecx, [rdi + CERT_SUBJECT_LEN]
    jne .done
    mov rsi, [rsi + CERT_ISSUER]
    mov rdi, [rdi + CERT_SUBJECT]
    repe cmpsb
.done:
    pop rdi
    pop rsi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; x509_check_sig: RSI = cert, RDI = issuer cert -> CF=1 if the issuer's key
; does not verify the cert's signature (x509_error set)
; ------------------------------------------------------------------------------
x509_check_sig:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov al, [rsi + CERT_SIG_HASH]
    test al, al
    jz .unsupported
    lea rbx, [rdi + CERT_PK]
    mov ah, [rbx + PK_TYPE]
    test ah, ah
    jz .unsupported
    ; the signature kind must match the issuer's key type
    cmp byte [rsi + CERT_SIG_KIND], SIG_KIND_RSA
    jne .ecdsa
    cmp ah, PK_TYPE_RSA
    jne .bad
    jmp .verify
.ecdsa:
    cmp ah, PK_TYPE_RSA
    je .bad
.verify:
    mov ah, RSA_SCHEME_PKCS1
    mov rdx, [rsi + CERT_SIG]
    mov r8d, [rsi + CERT_SIG_LEN]
    mov ecx, [rsi + CERT_TBS_LEN]
    mov rsi, [rsi + CERT_TBS]
    call sig_verify
    jc .bad
    clc
    jmp .out
.unsupported:
    lea rsi, [x509_err_unsupported]
    call x509_fail
    jmp .out
.bad:
    lea rsi, [x509_err_signature]
    call x509_fail
.out:
    pop r8
    pop rdx
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; x509_find_root: RSI = cert -> CF=0 if a trusted root (compiled in or in
; localca.der) is its issuer and verifies its signature
; ------------------------------------------------------------------------------
x509_find_root:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r10, rsi                    ; R10 = the cert
    lea rsi, [x509_roots]
    lea r9, [x509_roots_end]
    call .search
    jnc .found
    mov ecx, [x509_local_len]
    test ecx, ecx
    jz .none
    lea rsi, [x509_local]
    lea r9, [rsi + rcx]
    call .search
    jnc .found
.none:
    stc
    jmp .out
.found:
    lea rsi, [klog_x509_root]
    lea rdi, [x509_root_cert]
    xor eax, eax
    call x509_log_name
    clc
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
; .search: certificates from RSI to R9 -> CF=0 with x509_root_cert = the issuer
.search:
    cmp rsi, r9
    jae .search_none
    call der_next
    jc .search_none
    mov rcx, r8
    sub rcx, rsi
    push r8
    lea rdi, [x509_root_cert]
    call x509_parse
    jc .search_next
    xchg rsi, r10
    call x509_same_name             ; cert's issuer vs root's subject
    jne .search_restore
    push qword [x509_error]
    call x509_check_sig
    pop qword [x509_error]          ; a root that does not verify is just not it
    jnc .search_hit
.search_restore:
    xchg rsi, r10
.search_next:
    pop rsi
    jmp .search
.search_hit:
    xchg rsi, r10
    pop rsi
    clc
    ret
.search_none:
    stc
    ret

; ------------------------------------------------------------------------------
; x509_load_local: localca.der (DER certificates back to back) from the disk
; ------------------------------------------------------------------------------
x509_load_local:
    push rax
    push rcx
    push rsi
    push rdi
    mov dword [x509_local_len], 0
    lea rsi, [x509_localca_name]
    call fs_find_file
    test rax, rax
    jz .done
    lea rdi, [x509_local]
    mov ecx, X509_LOCAL_MAX
    call fs_read_file
    mov [x509_local_len], eax
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; x509_check_host: RDI = cert, RSI = host name -> CF=1 unless a subjectAltName
; matches it (dNSName, "*." wildcard for one label, or iPAddress)
; ------------------------------------------------------------------------------
x509_check_host:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov r10, rsi                    ; R10 = host
    cmp byte [rdi + CERT_HAS_SAN], 0
    je .no
    ; an IP literal matches iPAddress entries only
    xor r11d, r11d
    call tls_is_ip_literal
    jnc .names
    push rdi
    lea rdi, [x509_ip]
    call net_parse_ip
    pop rdi
    test rax, rax
    jnz .no
    mov r11d, 1
.names:
    mov rsi, [rdi + CERT_SAN]
    mov ecx, [rdi + CERT_SAN_LEN]
    lea r9, [rsi + rcx]
.entry:
    cmp rsi, r9
    jae .no
    call der_next
    jc .no
    test r11d, r11d
    jnz .ip_entry
    cmp al, 0x82                    ; dNSName
    jne .next
    mov rsi, r10
    call x509_dns_match
    je .yes
    jmp .next
.ip_entry:
    cmp al, 0x87                    ; iPAddress
    jne .next
    cmp ecx, 4
    jne .next
    mov eax, [rdx]
    cmp eax, [x509_ip]
    je .yes
.next:
    mov rsi, r8
    jmp .entry
.yes:
    clc
    jmp .out
.no:
    lea rsi, [x509_err_host]
    call x509_fail
.out:
    pop r11
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
; x509_dns_match: RDX = DNS name from the certificate, ECX = its length,
; RSI = host name -> ZF=1 on a match (case-insensitive; "*.rest" matches one
; non-empty label followed by ".rest")
; ------------------------------------------------------------------------------
x509_dns_match:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    cmp ecx, 2
    jb .exact
    cmp word [rdx], '*.'
    jne .exact
    ; skip the host's first label (at least one character, no dot)
    cmp byte [rsi], '.'
    je .no
    cmp byte [rsi], 0
    je .no
.label:
    lodsb
    test al, al
    jz .no
    cmp al, '.'
    jne .label
    dec rsi                         ; at the dot
    inc rdx                         ; pattern from its dot
    dec ecx
.exact:
    ; the host from RSI must be exactly ECX characters equal to RDX
    push rsi
    call strlen
    pop rsi
    cmp eax, ecx
    jne .no
    mov rdi, rdx
.char:
    test ecx, ecx
    jz .yes
    mov al, [rsi]
    mov ah, [rdi]
    or ax, 0x2020                   ; letters to lower case (digits, '.', '-' unchanged)
    cmp al, ah
    jne .no
    inc rsi
    inc rdi
    dec ecx
    jmp .char
.yes:
    xor eax, eax                    ; ZF=1
    jmp .out
.no:
    or eax, 1                       ; ZF=0
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; x509_verify_chain: the server's certificates (x509_chain, x509_chain_count;
; the first is the server's own) against RSI = host name.
; Output: CF=1 with x509_error set if the chain is not trusted for that host
; ------------------------------------------------------------------------------
x509_verify_chain:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    mov r12, rsi                    ; R12 = host
    lea rsi, [x509_err_none]
    cmp dword [x509_chain_count], 0
    je .fail
    push rdi
    lea rdi, [x509_now]
    call rtc_stamp
    pop rdi
    call x509_load_local

    lea r13, [x509_chain]           ; R13 = current certificate
    mov rdi, r13
    lea rsi, [klog_x509_leaf]
    xor eax, eax
    call x509_log_name
    call x509_check_time
    jc .out
    mov rsi, r12
    call x509_check_host
    jc .out

    xor r14d, r14d                  ; R14 = depth
.step:
    mov rsi, r13
    call x509_find_root
    jnc .trusted
    ; the issuer among the certificates the server sent
    inc r14d
    lea rsi, [x509_err_too_long]
    cmp r14d, X509_MAX_DEPTH
    ja .fail
    xor ecx, ecx
    lea rdi, [x509_chain]
.candidate:
    cmp ecx, [x509_chain_count]
    jae .untrusted
    cmp rdi, r13
    je .next_candidate
    mov rsi, r13
    call x509_same_name
    jne .next_candidate
    ; it must be a CA, currently valid, and must have signed the current one
    lea rsi, [x509_err_not_ca]
    cmp byte [rdi + CERT_IS_CA], 1
    jne .fail
    call x509_check_time
    jc .out
    mov rsi, r13
    call x509_check_sig
    jc .out
    lea rsi, [klog_x509_issuer]
    xor eax, eax
    call x509_log_name
    mov r13, rdi
    jmp .step
.next_candidate:
    add rdi, CERT_SIZE
    inc ecx
    jmp .candidate
.untrusted:
    lea rsi, [x509_err_untrusted]
.fail:
    call x509_fail
    jmp .out
.trusted:
    clc
.out:
    jnc .done
    mov rdi, [x509_error]
    lea rsi, [klog_x509_error]
    call klog2
    stc
.done:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
