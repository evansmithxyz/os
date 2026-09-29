; ==============================================================================
; Antigravity OS - hashing by algorithm id, and RSA signature verification
; ------------------------------------------------------------------------------
; A public key (PK_*) is a small record filled in by the X.509 parser:
;   RSA: modulus and exponent (big-endian bytes, pointing into the certificate)
;   EC:  the curve and the uncompressed point 04 | X | Y
; rsa_verify handles RSASSA-PKCS1-v1_5 (certificate signatures) and
; RSASSA-PSS with MGF1 and salt length = hash length (TLS 1.3 CertificateVerify).
; ==============================================================================

[bits 64]

HASH_SHA256             equ 1
HASH_SHA384             equ 2
HASH_SHA512             equ 3
HASH_MAX_LEN            equ 64

PK_TYPE_RSA             equ 1
PK_TYPE_P256            equ 2
PK_TYPE_P384            equ 3

PK_TYPE                 equ 0       ; db PK_TYPE_*
PK_A                    equ 8       ; dq RSA modulus / EC point
PK_A_LEN                equ 16      ; dd
PK_B                    equ 24      ; dq RSA exponent
PK_B_LEN                equ 32      ; dd
PK_SIZE                 equ 40

RSA_SCHEME_PKCS1        equ 0
RSA_SCHEME_PSS          equ 1
RSA_MAX_BYTES           equ BN_MAX_LIMBS * 8

section .bss
alignb 16
rsa_ctx:                resb MONT_SIZE
rsa_s:                  resq BN_MAX_LIMBS
rsa_m:                  resq BN_MAX_LIMBS
rsa_em:                 resb RSA_MAX_BYTES
rsa_hash:               resb HASH_MAX_LEN
rsa_hash2:              resb HASH_MAX_LEN
rsa_mgf_in:             resb HASH_MAX_LEN + 4
rsa_mprime:             resb 8 + 2 * HASH_MAX_LEN
rsa_nbytes:             resd 1
rsa_embits:             resd 1

section .rodata
; DigestInfo DER prefixes for PKCS#1 v1.5 (all 19 bytes)
rsa_di_sha256:  db 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20
rsa_di_sha384:  db 0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30
rsa_di_sha512:  db 0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40
RSA_DI_LEN              equ 19

section .text
; ------------------------------------------------------------------------------
; hash_len: AL = HASH_* -> ECX = digest length (0 for an unknown id)
; hash_compute: AL = HASH_*, RSI = data, RCX = length, RDI = digest output
; ------------------------------------------------------------------------------
hash_len:
    mov ecx, 32
    cmp al, HASH_SHA256
    je .ret
    mov ecx, 48
    cmp al, HASH_SHA384
    je .ret
    mov ecx, 64
    cmp al, HASH_SHA512
    je .ret
    xor ecx, ecx
.ret:
    ret

hash_compute:
    cmp al, HASH_SHA256
    je sha256
    cmp al, HASH_SHA384
    je sha384
    jmp sha512

; ------------------------------------------------------------------------------
; sig_verify: any public key. RBX = key, AL = HASH_*, AH = RSA_SCHEME_* (RSA
; keys only), RSI = message, RCX = length, RDX = signature, R8 = its length
; Output: CF=1 if the signature is not valid
; ------------------------------------------------------------------------------
sig_verify:
    cmp byte [rbx + PK_TYPE], PK_TYPE_RSA
    je rsa_verify
    jmp ecdsa_verify

; ------------------------------------------------------------------------------
; rsa_verify: RBX = public key (PK_TYPE_RSA), AL = HASH_*, AH = RSA_SCHEME_*,
;             RSI = signed message, RCX = its length,
;             RDX = signature, R8 = signature length
; Output: CF=1 if the signature is not valid
; ------------------------------------------------------------------------------
rsa_verify:
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
    mov r12, rbx                    ; R12 = public key
    mov r11d, eax                   ; R11B = hash, bits 8-15 = scheme

    ; mHash
    lea rdi, [rsa_hash]
    call hash_compute
    call hash_len
    mov r10d, ecx                   ; R10 = hLen
    test ecx, ecx
    jz .bad

    ; modulus -> Montgomery context; its size in bytes and bits
    push rdx
    mov rsi, [r12 + PK_A]
    mov ecx, [r12 + PK_A_LEN]
    lea rbx, [rsa_ctx]
    call mont_setup
    pop rdx
    jc .bad
    call rsa_modulus_size           ; rsa_nbytes, rsa_embits

    ; s = signature as a number below n
    cmp r8d, [rsa_nbytes]
    ja .bad
    mov ecx, [rbx + MONT_K]
    lea rdi, [rsa_s]
    mov rsi, rdx
    mov rdx, r8
    call bn_from_bytes
    jc .bad
    lea rsi, [rsa_s]
    lea rdi, [rbx + MONT_N]
    call bn_cmp
    jae .bad

    ; m = s^e mod n, then EM = m as nbytes big-endian bytes
    lea rsi, [rsa_s]
    mov rdx, [r12 + PK_B]
    mov ecx, [r12 + PK_B_LEN]
    lea rdi, [rsa_m]
    call bn_modexp
    lea rsi, [rsa_m]
    lea rdi, [rsa_em]
    mov ecx, [rsa_nbytes]
    call bn_to_bytes

    mov eax, r11d
    cmp ah, RSA_SCHEME_PSS
    je .pss

    ; --- PKCS#1 v1.5: EM = 00 01 FF..FF 00 | DigestInfo | H -------------------
    lea rsi, [rsa_di_sha256]
    cmp al, HASH_SHA256
    je .have_di
    lea rsi, [rsa_di_sha384]
    cmp al, HASH_SHA384
    je .have_di
    lea rsi, [rsa_di_sha512]
.have_di:
    lea rdi, [rsa_em]
    mov ecx, [rsa_nbytes]
    ; padding length = nbytes - 3 - 19 - hLen, at least 8
    mov edx, ecx
    sub edx, 3 + RSA_DI_LEN
    sub edx, r10d
    cmp edx, 8
    jl .bad
    cmp word [rdi], 0x0100          ; 00 01
    jne .bad
    add rdi, 2
.ff:
    cmp byte [rdi], 0xFF
    jne .bad
    inc rdi
    dec edx
    jnz .ff
    cmp byte [rdi], 0
    jne .bad
    inc rdi
    mov ecx, RSA_DI_LEN
    repe cmpsb
    jne .bad
    lea rsi, [rsa_hash]
    mov ecx, r10d
    repe cmpsb
    jne .bad
    jmp .good

    ; --- PSS -------------------------------------------------------------------
.pss:
    ; emLen = ceil(emBits / 8); EM is the last emLen bytes of the nbytes
    mov ecx, [rsa_embits]
    add ecx, 7
    shr ecx, 3                      ; ECX = emLen
    lea r9, [rsa_em]
    mov edx, [rsa_nbytes]
    sub edx, ecx
    jz .em_ready
    cmp byte [r9], 0                ; the extra leading byte must be zero
    jne .bad
    inc r9
.em_ready:
    ; R9 = EM, ECX = emLen. Needs emLen >= 2*hLen + 2 and EM ends in 0xBC.
    lea eax, [r10d * 2 + 2]
    cmp ecx, eax
    jb .bad
    cmp byte [r9 + rcx - 1], 0xBC
    jne .bad
    ; dbLen = emLen - hLen - 1; H follows maskedDB
    mov edx, ecx
    sub edx, r10d
    dec edx                         ; EDX = dbLen
    ; the bits above emBits in EM[0] must be zero
    mov eax, ecx
    shl eax, 3
    sub eax, [rsa_embits]           ; EAX = 8*emLen - emBits (0..7)
    push rcx
    mov ecx, eax
    mov al, 0xFF
    shr al, cl                      ; mask of the allowed bits
    not al
    test [r9], al
    pop rcx
    jnz .bad
    ; DB = maskedDB xor MGF1(H, dbLen)
    lea rsi, [r9 + rdx]             ; H
    mov rdi, r9
    call rsa_mgf1_xor               ; AL = hash (from R11), in place
    ; clear the bits above emBits again
    mov eax, ecx
    shl eax, 3
    sub eax, [rsa_embits]
    push rcx
    mov ecx, eax
    mov al, 0xFF
    shr al, cl
    and [r9], al
    pop rcx
    ; DB = 00..00 01 salt, with salt length = hLen
    mov eax, edx
    sub eax, r10d
    dec eax                         ; EAX = number of leading zero bytes
    js .bad
    xor ecx, ecx
.zeros:
    cmp ecx, eax
    jae .one
    cmp byte [r9 + rcx], 0
    jne .bad
    inc ecx
    jmp .zeros
.one:
    cmp byte [r9 + rcx], 1
    jne .bad
    inc ecx                         ; salt at R9 + RCX, hLen bytes
    ; H' = Hash(00 x 8 | mHash | salt)
    lea rdi, [rsa_mprime]
    mov qword [rdi], 0
    add rdi, 8
    push rcx
    lea rsi, [rsa_hash]
    mov ecx, r10d
    rep movsb
    pop rcx
    lea rsi, [r9 + rcx]
    mov ecx, r10d
    rep movsb
    lea rsi, [rsa_mprime]
    lea ecx, [r10d * 2 + 8]
    lea rdi, [rsa_hash2]
    mov eax, r11d
    call hash_compute
    ; compare with H
    lea rsi, [r9 + rdx]
    mov ecx, r10d
    repe cmpsb
    jne .bad

.good:
    clc
    jmp .out
.bad:
    stc
.out:
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

; rsa_modulus_size: RBX = context -> rsa_nbytes (bytes of n), rsa_embits (bits - 1)
rsa_modulus_size:
    push rax
    push rcx
    push rdx
    mov ecx, [rbx + MONT_K]
    shl ecx, 3
.top_byte:
    dec ecx
    movzx eax, byte [rbx + MONT_N + rcx]
    test eax, eax
    jz .top_byte
    lea edx, [ecx + 1]
    mov [rsa_nbytes], edx
    ; bits = 8 * (nbytes - 1) + bit length of the top byte
    shl ecx, 3
    bsr eax, eax
    lea ecx, [ecx + eax]            ; bits - 1
    mov [rsa_embits], ecx
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; rsa_mgf1_xor: RDI = data (EDX bytes), RSI = seed (R10 bytes), R11B = hash
; data ^= MGF1(seed, EDX)
; ------------------------------------------------------------------------------
rsa_mgf1_xor:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    ; rsa_mgf_in = seed | counter
    push rdi
    lea rdi, [rsa_mgf_in]
    mov ecx, r10d
    rep movsb
    pop rdi
    xor r8d, r8d                    ; counter
.block:
    test edx, edx
    jz .done
    mov eax, r8d
    bswap eax
    lea rsi, [rsa_mgf_in]
    mov [rsi + r10], eax
    push rdi
    lea rdi, [rsa_hash2]
    lea ecx, [r10d + 4]
    mov eax, r11d
    call hash_compute
    pop rdi
    inc r8d
    xor ebx, ebx
.byte:
    lea rsi, [rsa_hash2]
    mov al, [rsi + rbx]
    xor [rdi], al
    inc rdi
    dec edx
    jz .done
    inc ebx
    cmp ebx, r10d
    jb .byte
    jmp .block
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
