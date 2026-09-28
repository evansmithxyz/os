; ==============================================================================
; Antigravity OS - CMOS real-time clock
; ------------------------------------------------------------------------------
; Reads the date and time from the CMOS RTC (ports 0x70/0x71). QEMU sets the
; clock to the host's UTC time, which is what certificate validity uses.
; Handles BCD and binary mode and the 12-hour format.
; ==============================================================================

[bits 64]

RTC_INDEX               equ 0x70
RTC_DATA                equ 0x71

section .bss
rtc_year:               resw 1
rtc_month:              resb 1
rtc_day:                resb 1
rtc_hour:               resb 1
rtc_minute:             resb 1
rtc_second:             resb 1
rtc_raw:                resb 8      ; sec, min, hour, day, month, year, century
rtc_raw2:               resb 8

section .text
; rtc_reg: AL = register -> AL = value
rtc_reg:
    out RTC_INDEX, al
    in al, RTC_DATA
    ret

; rtc_snapshot: RDI = 7-byte buffer <- sec, min, hour, day, month, year, century
rtc_snapshot:
    push rax
.wait:
    mov al, 0x0A
    call rtc_reg
    test al, 0x80                   ; update in progress
    jnz .wait
    mov al, 0x00
    call rtc_reg
    mov [rdi + 0], al
    mov al, 0x02
    call rtc_reg
    mov [rdi + 1], al
    mov al, 0x04
    call rtc_reg
    mov [rdi + 2], al
    mov al, 0x07
    call rtc_reg
    mov [rdi + 3], al
    mov al, 0x08
    call rtc_reg
    mov [rdi + 4], al
    mov al, 0x09
    call rtc_reg
    mov [rdi + 5], al
    mov al, 0x32
    call rtc_reg
    mov [rdi + 6], al
    pop rax
    ret

; ------------------------------------------------------------------------------
; rtc_read: fill rtc_year .. rtc_second (UTC as kept by the CMOS clock)
; ------------------------------------------------------------------------------
rtc_read:
    push rax
    push rbx
    push rcx
    push rdi
    push rsi
    ; read until two snapshots agree (an update can land between registers)
.again:
    lea rdi, [rtc_raw]
    call rtc_snapshot
    lea rdi, [rtc_raw2]
    call rtc_snapshot
    lea rsi, [rtc_raw]
    mov ecx, 7
    repe cmpsb
    jne .again

    mov al, 0x0B
    call rtc_reg
    mov bl, al                      ; BL = status B
    lea rsi, [rtc_raw]
    ; hour: bit 7 is PM in 12-hour mode
    mov al, [rsi + 2]
    mov bh, al
    and al, 0x7F
    mov [rsi + 2], al
    test bl, 0x04                   ; binary mode?
    jnz .binary
    xor ecx, ecx
.bcd:
    mov al, [rsi + rcx]
    call rtc_from_bcd
    mov [rsi + rcx], al
    inc ecx
    cmp ecx, 7
    jb .bcd
.binary:
    test bl, 0x02                   ; 24-hour mode?
    jnz .h24
    mov al, [rsi + 2]
    cmp al, 12
    jne .not_12
    xor al, al                      ; 12 AM = 0, 12 PM = 12 below
.not_12:
    test bh, 0x80
    jz .am
    add al, 12
.am:
    mov [rsi + 2], al
.h24:
    mov al, [rsi + 0]
    mov [rtc_second], al
    mov al, [rsi + 1]
    mov [rtc_minute], al
    mov al, [rsi + 2]
    mov [rtc_hour], al
    mov al, [rsi + 3]
    mov [rtc_day], al
    mov al, [rsi + 4]
    mov [rtc_month], al
    ; year = century * 100 + year, assuming 20xx without a century register
    movzx eax, byte [rsi + 6]
    cmp eax, 19
    jb .no_century
    cmp eax, 30
    jbe .have_century
.no_century:
    mov eax, 20
.have_century:
    imul eax, eax, 100
    movzx ecx, byte [rsi + 5]
    add eax, ecx
    mov [rtc_year], ax
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; rtc_from_bcd: AL = BCD byte -> AL = binary
rtc_from_bcd:
    push rcx
    movzx ecx, al
    shr ecx, 4
    and al, 0x0F
    imul ecx, ecx, 10
    add al, cl
    pop rcx
    ret

; ------------------------------------------------------------------------------
; rtc_stamp: RDI = 15-byte buffer <- "YYYYMMDDHHMMSS" + NUL (reads the clock).
; The same form x509 turns certificate times into, so they compare as strings.
; ------------------------------------------------------------------------------
rtc_stamp:
    push rax
    push rcx
    push rdx
    push rdi
    call rtc_read
    movzx eax, word [rtc_year]
    push rax
    xor edx, edx
    mov ecx, 100
    div ecx                         ; EAX = century, EDX = year in century
    call fmt_dec2
    mov eax, edx
    call fmt_dec2
    pop rax
    movzx eax, byte [rtc_month]
    call fmt_dec2
    movzx eax, byte [rtc_day]
    call fmt_dec2
    movzx eax, byte [rtc_hour]
    call fmt_dec2
    movzx eax, byte [rtc_minute]
    call fmt_dec2
    movzx eax, byte [rtc_second]
    call fmt_dec2
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret
