; ==============================================================================
; Antigravity OS - JavaScript Date
; ------------------------------------------------------------------------------
; A Date (class JC_DATE) holds a time value: milliseconds since 1970-01-01
; UTC as a double (NaN for an invalid date). The clock is the CMOS clock
; (read once per realm) plus the millisecond timer. The local time zone is
; UTC, so getHours() and getUTCHours() agree and the offset is 0. Calendar
; arithmetic uses Howard Hinnant's days <-> civil date algorithms on
; integers. Date.parse reads ISO 8601 strings and the usual English forms
; ("Jan 15, 2024 10:30", "Mon, 15 Jan 2024 10:30:00 GMT", "1/15/2024").
; ==============================================================================

[bits 64]

JDATE_TIME              equ 32          ; the time value (double bits)
JDATE_SIZE              equ 40
JSDATE_MS_DAY           equ 86400000
; the fields jsdate_split fills and jsdate_join reads (qwords)
DF_YEAR                 equ 0
DF_MONTH                equ 8           ; 0 .. 11
DF_DATE                 equ 16          ; 1 .. 31
DF_HOURS                equ 24
DF_MINUTES              equ 32
DF_SECONDS              equ 40
DF_MS                   equ 48
DF_DAY                  equ 56          ; weekday, 0 = Sunday

section .bss
alignb 8
js_date_proto:          resq 1
jsdate_ctor:            resq 1
jsdate_base_ms:         resq 1          ; the clock when first read (this realm)
jsdate_base_tick:       resq 1
jsdate_realm:           resd 1
jsdate_f:               resq 8          ; DF_* fields
jsdate_buf:             resb 96         ; text being made

section .rodata
jsdate_ctors:
JSCTOR jsdate_ctor, jsdate_date, 7, js_date_proto, "Date"
    dq 0

jsdate_natives:
JSNATIVE jsdate_ctor, "now", jsdate_now_method, 0
JSNATIVE jsdate_ctor, "parse", jsdate_parse_method, 1
JSNATIVE jsdate_ctor, "UTC", jsdate_utc_method, 7
JSNATIVE js_date_proto, "getTime", jsdate_get_time, 0
JSNATIVE js_date_proto, "valueOf", jsdate_get_time, 0
JSNATIVE js_date_proto, "getTimezoneOffset", jsdate_get_offset, 0
JSNATIVE js_date_proto, "setTime", jsdate_set_time, 1
JSNATIVE js_date_proto, "toISOString", jsdate_to_iso, 0
JSNATIVE js_date_proto, "toJSON", jsdate_to_json, 1
JSNATIVE js_date_proto, "toString", jsdate_to_string, 0
JSNATIVE js_date_proto, "toDateString", jsdate_to_date_string, 0
JSNATIVE js_date_proto, "toTimeString", jsdate_to_time_string, 0
JSNATIVE js_date_proto, "toUTCString", jsdate_to_utc_string, 0
JSNATIVE js_date_proto, "toGMTString", jsdate_to_utc_string, 0
JSNATIVE js_date_proto, "toLocaleString", jsdate_to_locale_string, 0
JSNATIVE js_date_proto, "toLocaleDateString", jsdate_to_locale_date, 0
JSNATIVE js_date_proto, "toLocaleTimeString", jsdate_to_locale_time, 0
JSNATIVE js_date_proto, "getYear", jsdate_get_year, 0
    dq 0

; getters: name, field (the DF_* offset); both the local and the UTC name
jsdate_getters:
    dq jsdate_str_get_full_year, DF_YEAR
    dq jsdate_str_get_month, DF_MONTH
    dq jsdate_str_get_date, DF_DATE
    dq jsdate_str_get_day, DF_DAY
    dq jsdate_str_get_hours, DF_HOURS
    dq jsdate_str_get_minutes, DF_MINUTES
    dq jsdate_str_get_seconds, DF_SECONDS
    dq jsdate_str_get_ms, DF_MS
    dq 0
; setters: name, the first field it sets, how many it can take
jsdate_setters:
    dq jsdate_str_set_full_year, DF_YEAR, 3
    dq jsdate_str_set_month, DF_MONTH, 2
    dq jsdate_str_set_date, DF_DATE, 1
    dq jsdate_str_set_hours, DF_HOURS, 4
    dq jsdate_str_set_minutes, DF_MINUTES, 3
    dq jsdate_str_set_seconds, DF_SECONDS, 2
    dq jsdate_str_set_ms, DF_MS, 1
    dq 0
jsdate_str_get_full_year: db "FullYear", 0
jsdate_str_get_month:   db "Month", 0
jsdate_str_get_date:    db "Date", 0
jsdate_str_get_day:     db "Day", 0
jsdate_str_get_hours:   db "Hours", 0
jsdate_str_get_minutes: db "Minutes", 0
jsdate_str_get_seconds: db "Seconds", 0
jsdate_str_get_ms:      db "Milliseconds", 0
jsdate_str_set_full_year: db "FullYear", 0
jsdate_str_set_month:   db "Month", 0
jsdate_str_set_date:    db "Date", 0
jsdate_str_set_hours:   db "Hours", 0
jsdate_str_set_minutes: db "Minutes", 0
jsdate_str_set_seconds: db "Seconds", 0
jsdate_str_set_ms:      db "Milliseconds", 0
jsdate_str_get:         db "get", 0
jsdate_str_get_utc:     db "getUTC", 0
jsdate_str_set:         db "set", 0
jsdate_str_set_utc:     db "setUTC", 0
jsdate_days:            db "SunMonTueWedThuFriSat"
jsdate_months:          db "JanFebMarAprMayJunJulAugSepOctNovDec"
jsdate_str_invalid:     db "Invalid Date", 0
jsdate_str_zone:        db " GMT+0000 (Coordinated Universal Time)", 0
jsdate_str_gmt:         db " GMT", 0
jsmsg_date_invalid:     db "Invalid time value", 0
align 8
jsdate_max_time:        dq 8.64e15

section .text

; ------------------------------------------------------------------------------
; jsdate_init: Date (js_init_builtins)
; ------------------------------------------------------------------------------
jsdate_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rax, [js_object_proto]
    call jsobj_new
    mov [js_date_proto], rax
    lea r8, [jsdate_ctors]
    call jsb_define_ctors
    lea r8, [jsdate_natives]
    call jsb_define_natives
    ; getFullYear / getUTCFullYear ...: closures with the field
    lea rbx, [jsdate_getters]
.getter:
    mov rsi, [rbx]
    test rsi, rsi
    jz .setters
    mov rdx, [rbx + 8]
    lea rax, [jsdate_getter]
    lea rdi, [jsdate_str_get]
    call jsdate_define_pair
    add rbx, 16
    jmp .getter
.setters:
    lea rbx, [jsdate_setters]
.setter:
    mov rsi, [rbx]
    test rsi, rsi
    jz .done
    ; data: field * 16 + how many
    mov rdx, [rbx + 8]
    shl rdx, 4
    or rdx, [rbx + 16]
    lea rax, [jsdate_setter]
    lea rdi, [jsdate_str_set]
    call jsdate_define_pair
    add rbx, 24
    jmp .setter
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsdate_define_pair: RAX = routine, RDX = its data, RDI = "get" / "set", RSI
; = the rest of the name -> Date.prototype.getX and getUTCX (both the same)
jsdate_define_pair:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    call jsa_closure
    mov r8, rax                     ; the function
    mov rcx, rsi
    mov rsi, rdi
    call .define                    ; get + name
    lea rsi, [jsdate_str_get_utc]
    cmp byte [rdi], 'g'
    je .utc
    lea rsi, [jsdate_str_set_utc]
.utc:
    call .define                    ; getUTC + name
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
; .define: RSI = prefix, RCX = name -> js_date_proto[prefix + name] = R8
.define:
    push rcx
    push rdx
    push rsi
    call jsstr_from_cstr
    push rax
    mov rsi, rcx
    call jsstr_from_cstr
    mov rdx, rax
    pop rax
    call jsstr_concat
    call jsstr_intern
    mov edx, eax
    bts rdx, 32
    mov rcx, r8
    mov rax, [js_date_proto]
    call jsobj_define
    pop rsi
    pop rdx
    pop rcx
    ret

; ==============================================================================
; Time and calendar
; ==============================================================================

; jsdate_now: -> RAX = milliseconds since 1970 (integer)
jsdate_now:
    push rbx
    push rcx
    push rdx
    mov eax, [js_realm]
    cmp eax, [jsdate_realm]
    je .have_base
    mov [jsdate_realm], eax
    call rtc_read
    movzx eax, word [rtc_year]
    movzx ecx, byte [rtc_month]
    movzx edx, byte [rtc_day]
    call jsdate_days_from_civil     ; RAX = days
    imul rax, rax, JSDATE_MS_DAY
    movzx ecx, byte [rtc_hour]
    imul rcx, rcx, 3600000
    add rax, rcx
    movzx ecx, byte [rtc_minute]
    imul rcx, rcx, 60000
    add rax, rcx
    movzx ecx, byte [rtc_second]
    imul rcx, rcx, 1000
    add rax, rcx
    mov [jsdate_base_ms], rax
    mov rax, [timer_ticks]
    mov [jsdate_base_tick], rax
.have_base:
    mov rax, [timer_ticks]
    sub rax, [jsdate_base_tick]
    add rax, [jsdate_base_ms]
    pop rdx
    pop rcx
    pop rbx
    ret

; jsdate_days_from_civil: EAX = year (signed), ECX = month 1-12, EDX = day ->
; RAX = days since 1970-01-01 (signed)
jsdate_days_from_civil:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    movsxd rax, eax
    mov rsi, rcx                    ; month
    mov rdi, rdx                    ; day
    cmp rsi, 2
    ja .year
    dec rax                         ; January and February count with the year before
.year:
    ; era = (y >= 0 ? y : y - 399) / 400
    mov rbx, rax
    test rax, rax
    jns .era
    sub rax, 399
.era:
    cqo
    mov rcx, 400
    idiv rcx
    mov rcx, rax                    ; era
    imul rax, rax, 400
    sub rbx, rax                    ; yoe = y - era * 400
    ; doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
    lea rax, [rsi - 3]
    cmp rsi, 2
    ja .mp
    lea rax, [rsi + 9]
.mp:
    imul rax, rax, 153
    add rax, 2
    cqo
    push rcx
    mov rcx, 5
    idiv rcx
    pop rcx
    lea rsi, [rax + rdi - 1]        ; doy
    ; doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    imul rax, rbx, 365
    mov rdx, rbx
    shr rdx, 2
    add rax, rdx
    push rax
    mov rax, rbx
    xor edx, edx
    mov rdi, 100
    div rdi
    mov rdx, rax
    pop rax
    sub rax, rdx
    add rax, rsi
    ; era * 146097 + doe - 719468
    imul rcx, rcx, 146097
    add rax, rcx
    sub rax, 719468
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; jsdate_split: RAX = time (integer ms) -> jsdate_f's fields
jsdate_split:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    ; days, and the milliseconds within the day (floor division)
    mov rcx, JSDATE_MS_DAY
    cqo
    idiv rcx
    test rdx, rdx
    jns .day_ok
    dec rax
    add rdx, rcx
.day_ok:
    mov rbx, rax                    ; days
    ; the time of day
    mov rax, rdx
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [jsdate_f + DF_MS], rdx
    xor edx, edx
    mov ecx, 60
    div rcx
    mov [jsdate_f + DF_SECONDS], rdx
    xor edx, edx
    div rcx
    mov [jsdate_f + DF_MINUTES], rdx
    mov [jsdate_f + DF_HOURS], rax
    ; the weekday: (days + 4) mod 7, 1970-01-01 was a Thursday
    lea rax, [rbx + 4]
    cqo
    mov ecx, 7
    idiv rcx
    test rdx, rdx
    jns .weekday
    add rdx, 7
.weekday:
    mov [jsdate_f + DF_DAY], rdx
    ; the date (civil_from_days)
    lea rax, [rbx + 719468]
    mov rsi, rax
    test rax, rax
    jns .era
    sub rax, 146096
.era:
    cqo
    mov rcx, 146097
    idiv rcx
    mov rdi, rax                    ; era
    imul rax, rax, 146097
    sub rsi, rax                    ; doe
    ; yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    mov rax, rsi
    xor edx, edx
    mov ecx, 1460
    div rcx
    mov rbx, rsi
    sub rbx, rax
    mov rax, rsi
    xor edx, edx
    mov ecx, 36524
    div rcx
    add rbx, rax
    mov rax, rsi
    xor edx, edx
    mov ecx, 146096
    div rcx
    sub rbx, rax
    mov rax, rbx
    xor edx, edx
    mov ecx, 365
    div rcx
    mov rbx, rax                    ; yoe
    ; y = yoe + era * 400
    imul rdi, rdi, 400
    add rdi, rbx
    ; doy = doe - (365 * yoe + yoe/4 - yoe/100)
    imul rax, rbx, 365
    mov rdx, rbx
    shr rdx, 2
    add rax, rdx
    push rax
    mov rax, rbx
    xor edx, edx
    mov ecx, 100
    div rcx
    mov rdx, rax
    pop rax
    sub rax, rdx
    sub rsi, rax                    ; doy
    ; mp = (5 * doy + 2) / 153
    lea rax, [rsi + rsi*4 + 2]
    xor edx, edx
    mov ecx, 153
    div rcx
    mov rbx, rax                    ; mp
    ; d = doy - (153 * mp + 2) / 5 + 1
    imul rax, rbx, 153
    add rax, 2
    xor edx, edx
    mov ecx, 5
    div rcx
    sub rsi, rax
    inc rsi
    mov [jsdate_f + DF_DATE], rsi
    ; m = mp < 10 ? mp + 3 : mp - 9 (1-based)
    lea rax, [rbx + 3]
    cmp rbx, 10
    jb .month
    lea rax, [rbx - 9]
.month:
    cmp rax, 2
    ja .year
    inc rdi
.year:
    dec rax
    mov [jsdate_f + DF_MONTH], rax
    mov [jsdate_f + DF_YEAR], rdi
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; jsdate_join: jsdate_f's fields (any integers: months past 11 roll over)
; -> RAX = the time value (double bits, NaN if out of range)
jsdate_join:
    push rbx
    push rcx
    push rdx
    ; (years this far out are past any valid time)
    mov rax, [jsdate_f + DF_YEAR]
    add rax, 400000
    cmp rax, 800000
    ja .nan
    mov rax, [jsdate_f + DF_MONTH]
    add rax, 10000000
    cmp rax, 20000000
    ja .nan
    ; year and month: the month into 0 .. 11
    mov rax, [jsdate_f + DF_MONTH]
    cqo
    mov rcx, 12
    idiv rcx
    test rdx, rdx
    jns .month_ok
    dec rax
    add rdx, 12
.month_ok:
    add rax, [jsdate_f + DF_YEAR]
    lea ecx, [edx + 1]
    mov edx, 1
    call jsdate_days_from_civil
    add rax, [jsdate_f + DF_DATE]
    dec rax                         ; days
    ; days * ms-per-day + the time, as doubles (it may be far out of range)
    cvtsi2sd xmm0, rax
    mov rax, JSDATE_MS_DAY
    cvtsi2sd xmm1, rax
    mulsd xmm0, xmm1
    mov rax, [jsdate_f + DF_HOURS]
    imul rax, rax, 3600000
    mov rcx, [jsdate_f + DF_MINUTES]
    imul rcx, rcx, 60000
    add rax, rcx
    mov rcx, [jsdate_f + DF_SECONDS]
    imul rcx, rcx, 1000
    add rax, rcx
    add rax, [jsdate_f + DF_MS]
    cvtsi2sd xmm1, rax
    addsd xmm0, xmm1
    movq rax, xmm0
    call jsdate_clip
    pop rdx
    pop rcx
    pop rbx
    ret
.nan:
    mov rax, JS_NAN
    pop rdx
    pop rcx
    pop rbx
    ret

; jsdate_clip: RAX = a time (double bits) -> RAX = it as an integer number,
; or NaN if it is not within +-8.64e15 (TimeClip)
jsdate_clip:
    movq xmm0, rax
    ucomisd xmm0, xmm0
    jp .nan
    push rax
    btr rax, 63
    movq xmm1, rax
    pop rax
    ucomisd xmm1, [jsdate_max_time]
    ja .nan
    call jsb_trunc
    addsd xmm0, [jsdate_zero]       ; (-0 becomes +0)
    movq rax, xmm0
    ret
.nan:
    mov rax, JS_NAN
    ret

section .rodata
align 8
jsdate_zero:            dq 0.0
section .text

; jsdate_int: RAX = a number -> RAX = it as an integer (clamped), CF=1 if
; it was NaN or infinite
jsdate_int:
    push rdx
    mov rdx, rax
    btr rdx, 63
    push rax
    mov rax, JS_INF
    cmp rdx, rax
    pop rax
    jae .bad
    movq xmm0, rax
    mov rdx, 0x42D0000000000000     ; 2^46: far past any date
    movq xmm1, rdx
    ucomisd xmm0, xmm1
    jae .big
    mov rdx, 0xC2D0000000000000
    movq xmm1, rdx
    ucomisd xmm0, xmm1
    jbe .small
    cvttsd2si rax, xmm0
    pop rdx
    clc
    ret
.big:
    mov rax, 0x400000000000
    pop rdx
    clc
    ret
.small:
    mov rax, -0x400000000000
    pop rdx
    clc
    ret
.bad:
    pop rdx
    stc
    ret

; ==============================================================================
; The Date object
; ==============================================================================

; jsdate_new: RAX = time value (double bits) -> RAX = a new Date (value)
jsdate_new:
    push rcx
    push rdx
    mov rdx, rax
    mov ecx, JDATE_SIZE
    call js_alloc
    mov byte [rax + JH_KIND], JK_OBJECT
    mov dword [rax + JOBJ_CLASS], JC_DATE
    mov rcx, [js_date_proto]
    mov [rax + JOBJ_PROTO], rcx
    mov [rax + JDATE_TIME], rdx
    BOX rax, rcx, JS_OBJ_BITS
    pop rdx
    pop rcx
    ret

; jsdate_this: RDX = this -> RBX = the Date (raw); TypeError otherwise
jsdate_this:
    mov rbx, rdx
    shr rbx, 48
    cmp ebx, JS_TAG_OBJECT
    jne .bad
    mov ebx, edx
    cmp dword [rbx + JOBJ_CLASS], JC_DATE
    jne .bad
    ret
.bad:
    lea rsi, [jsmsg_illegal]
    xor edi, edi
    jmp js_throw_type

; jsdate_value_now: -> RAX = the current time value (double bits)
jsdate_value_now:
    call jsdate_now
    jmp jsb_from_int

; ------------------------------------------------------------------------------
; Date(...): new Date(), new Date(ms), new Date(string), new Date(date),
; new Date(year, month, day, h, m, s, ms); Date() without new: a string
; ------------------------------------------------------------------------------
jsdate_date:
    push rcx
    push rdx
    push rsi
    push rdi
    test r8d, r8d
    jz .string
    test ecx, ecx
    jz .now
    cmp ecx, 1
    ja .fields
    mov rax, [rdi]
    ; a Date: its time
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_OBJECT
    jne .primitive
    mov edx, eax
    cmp dword [rdx + JOBJ_CLASS], JC_DATE
    jne .to_primitive
    mov rax, [rdx + JDATE_TIME]
    jmp .make
.to_primitive:
    mov edx, 1
    call js_to_primitive
.primitive:
    mov rdx, rax
    shr rdx, 48
    cmp edx, JS_TAG_STRING
    jne .number
    mov eax, eax
    call jsdate_parse
    jmp .make
.number:
    call js_to_number
    call jsdate_clip
    jmp .make
.fields:
    call jsdate_from_args           ; year, month, ...
    jmp .make
.now:
    call jsdate_value_now
.make:
    call jsdate_new
    jmp .out
.string:
    call jsdate_value_now
    call jsdate_new
    mov rdx, rax
    call jsdate_to_string
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; jsdate_from_args: RDI / ECX = year, month[, day, hours, minutes, seconds,
; ms] -> RAX = the time value (years 0 .. 99 mean 1900 ..)
jsdate_from_args:
    push rbx
    push rcx
    push rdx
    ; the defaults: day 1, the rest 0
    xor eax, eax
    mov [jsdate_f + DF_HOURS], rax
    mov [jsdate_f + DF_MINUTES], rax
    mov [jsdate_f + DF_SECONDS], rax
    mov [jsdate_f + DF_MS], rax
    mov [jsdate_f + DF_MONTH], rax
    mov qword [jsdate_f + DF_DATE], 1
    ; each argument into its field
    xor ebx, ebx
.arg:
    cmp ebx, ecx
    jae .args_done
    cmp ebx, 7
    jae .args_done
    mov eax, ebx
    call jsb_arg_number
    call jsdate_int
    jc .nan
    lea rdx, [jsdate_arg_fields]
    movzx edx, byte [rdx + rbx]
    mov [jsdate_f + rdx], rax
    inc ebx
    jmp .arg
.args_done:
    mov rax, [jsdate_f + DF_YEAR]
    cmp rax, 99
    ja .join
    add qword [jsdate_f + DF_YEAR], 1900
.join:
    call jsdate_join
    pop rdx
    pop rcx
    pop rbx
    ret
.nan:
    mov rax, JS_NAN
    pop rdx
    pop rcx
    pop rbx
    ret

section .rodata
jsdate_arg_fields:      db DF_YEAR, DF_MONTH, DF_DATE, DF_HOURS, DF_MINUTES, DF_SECONDS, DF_MS
section .text

; Date.now()
jsdate_now_method:
    jmp jsdate_value_now

; Date.parse(string)
jsdate_parse_method:
    xor eax, eax
    call jsb_arg
    call js_to_string
    jmp jsdate_parse

; Date.UTC(year, month, ...)
jsdate_utc_method:
    test ecx, ecx
    jz .nan
    jmp jsdate_from_args
.nan:
    mov rax, JS_NAN
    ret

; date.getTime() / valueOf()
jsdate_get_time:
    push rbx
    call jsdate_this
    mov rax, [rbx + JDATE_TIME]
    pop rbx
    ret

; date.getTimezoneOffset(): UTC here
jsdate_get_offset:
    push rbx
    call jsdate_this
    mov rax, [rbx + JDATE_TIME]
    movq xmm0, rax
    ucomisd xmm0, xmm0
    jp .out
    xor eax, eax
.out:
    pop rbx
    ret

; date.setTime(ms)
jsdate_set_time:
    push rbx
    call jsdate_this
    xor eax, eax
    call jsb_arg_number
    call jsdate_clip
    mov [rbx + JDATE_TIME], rax
    pop rbx
    ret

; jsdate_fields: RBX = a Date -> jsdate_f filled; CF=1 if it is invalid
jsdate_fields:
    push rax
    mov rax, [rbx + JDATE_TIME]
    movq xmm0, rax
    ucomisd xmm0, xmm0
    jp .invalid
    cvttsd2si rax, xmm0
    call jsdate_split
    pop rax
    clc
    ret
.invalid:
    pop rax
    stc
    ret

; the getters: R10 data = the field
jsdate_getter:
    push rbx
    push rcx
    call jsdate_this
    call jsdate_fields
    mov rax, JS_NAN
    jc .out
    mov rcx, [r10 + JFN_DATA]
    mov rax, [jsdate_f + rcx]
    call jsb_from_int
.out:
    pop rcx
    pop rbx
    ret

; date.getYear(): the year - 1900
jsdate_get_year:
    push rbx
    call jsdate_this
    call jsdate_fields
    mov rax, JS_NAN
    jc .out
    mov rax, [jsdate_f + DF_YEAR]
    sub rax, 1900
    call jsb_from_int
.out:
    pop rbx
    ret

; the setters: R10 data = field * 16 + how many fields it may set
jsdate_setter:
    push rbx
    push rcx
    push rdx
    push rsi
    call jsdate_this
    call jsdate_fields
    jnc .valid
    ; an invalid date: only setFullYear makes it valid again (from 1970-01-01)
    mov rax, [r10 + JFN_DATA]
    shr rax, 4
    test eax, eax
    jnz .nan
    xor eax, eax
    call jsdate_split
.valid:
    mov rsi, [r10 + JFN_DATA]
    mov edx, esi
    and edx, 15                     ; at most this many
    shr esi, 4                      ; from this field
    cmp ecx, edx
    jbe .count
    mov ecx, edx
.count:
    test ecx, ecx
    jz .nan
    xor edx, edx
.arg:
    cmp edx, ecx
    jae .join
    mov eax, edx
    call jsb_arg_number
    call jsdate_int
    jc .nan
    mov [jsdate_f + rsi], rax
    add esi, 8
    inc edx
    jmp .arg
.join:
    call jsdate_join
    jmp .store
.nan:
    mov rax, JS_NAN
.store:
    mov [rbx + JDATE_TIME], rax
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ==============================================================================
; Text
; ==============================================================================

; jsdate_put_num: EAX = a number, ECX = at least this many digits, RDI = where
; -> written (a minus sign first if negative), RDI past it
jsdate_put_num:
    push rax
    push rcx
    push rdx
    push rsi
    movsxd rax, eax
    test rax, rax
    jns .positive
    mov byte [rdi], '-'
    inc rdi
    neg rax
.positive:
    sub rsp, 24
    mov rsi, rsp
    xor edx, edx                    ; digits
.digit:
    push rdx
    xor edx, edx
    push rcx
    mov ecx, 10
    div rcx
    pop rcx
    add dl, '0'
    mov [rsi], dl
    inc rsi
    pop rdx
    inc edx
    test rax, rax
    jnz .digit
.pad:
    cmp edx, ecx
    jae .out_digits
    mov byte [rsi], '0'
    inc rsi
    inc edx
    jmp .pad
.out_digits:
    dec rsi
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    dec edx
    jnz .out_digits
    add rsp, 24
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; jsdate_put: RSI = text (NUL-terminated), RDI = where -> copied, RDI past it
jsdate_put:
    push rax
    push rsi
.byte:
    lodsb
    test al, al
    jz .done
    stosb
    jmp .byte
.done:
    pop rsi
    pop rax
    ret

; jsdate_put3: RSI = a table of 3-letter names, EAX = which -> copied
jsdate_put3:
    push rax
    push rcx
    push rsi
    lea eax, [rax + rax*2]
    add rsi, rax
    mov ecx, 3
    rep movsb
    pop rsi
    pop rcx
    pop rax
    ret

; jsdate_take: RDI = past the text in jsdate_buf -> RAX = it as a string value
jsdate_take:
    push rcx
    push rsi
    lea rsi, [jsdate_buf]
    mov rcx, rdi
    sub rcx, rsi
    call jsstr_new
    call jsb_box_string
    pop rsi
    pop rcx
    ret

; jsdate_put_ymd: -> "2024-01-15" (years outside 0 .. 9999: +/-YYYYYY)
jsdate_put_ymd:
    push rax
    push rcx
    mov rax, [jsdate_f + DF_YEAR]
    mov ecx, 4
    cmp rax, 9999
    jg .wide
    test rax, rax
    jns .year
.wide:
    mov ecx, 6
    test rax, rax
    js .year
    mov byte [rdi], '+'
    inc rdi
.year:
    call jsdate_put_num
    mov byte [rdi], '-'
    inc rdi
    mov rax, [jsdate_f + DF_MONTH]
    inc eax
    mov ecx, 2
    call jsdate_put_num
    mov byte [rdi], '-'
    inc rdi
    mov rax, [jsdate_f + DF_DATE]
    call jsdate_put_num
    pop rcx
    pop rax
    ret

; jsdate_put_hms: -> "10:30:00"
jsdate_put_hms:
    push rax
    push rcx
    mov ecx, 2
    mov rax, [jsdate_f + DF_HOURS]
    call jsdate_put_num
    mov byte [rdi], ':'
    inc rdi
    mov rax, [jsdate_f + DF_MINUTES]
    call jsdate_put_num
    mov byte [rdi], ':'
    inc rdi
    mov rax, [jsdate_f + DF_SECONDS]
    call jsdate_put_num
    pop rcx
    pop rax
    ret

; jsdate_put_date_text: -> "Mon Jan 15 2024"
jsdate_put_date_text:
    push rax
    push rcx
    push rsi
    lea rsi, [jsdate_days]
    mov rax, [jsdate_f + DF_DAY]
    call jsdate_put3
    mov byte [rdi], ' '
    inc rdi
    lea rsi, [jsdate_months]
    mov rax, [jsdate_f + DF_MONTH]
    call jsdate_put3
    mov byte [rdi], ' '
    inc rdi
    mov rax, [jsdate_f + DF_DATE]
    mov ecx, 2
    call jsdate_put_num
    mov byte [rdi], ' '
    inc rdi
    mov rax, [jsdate_f + DF_YEAR]
    mov ecx, 4
    call jsdate_put_num
    pop rsi
    pop rcx
    pop rax
    ret

; jsdate_iso: RBX = a Date -> RAX = "2024-01-15T10:30:00.000Z" (value); CF=1
; if it is invalid
jsdate_iso:
    push rcx
    push rdi
    call jsdate_fields
    jc .out
    lea rdi, [jsdate_buf]
    call jsdate_put_ymd
    mov byte [rdi], 'T'
    inc rdi
    call jsdate_put_hms
    mov byte [rdi], '.'
    inc rdi
    mov rax, [jsdate_f + DF_MS]
    mov ecx, 3
    call jsdate_put_num
    mov byte [rdi], 'Z'
    inc rdi
    call jsdate_take
    clc
.out:
    pop rdi
    pop rcx
    ret

; date.toISOString()
jsdate_to_iso:
    push rbx
    call jsdate_this
    call jsdate_iso
    jc .invalid
    pop rbx
    ret
.invalid:
    mov edx, JE_RANGE
    lea rsi, [jsmsg_date_invalid]
    xor edi, edi
    jmp js_throw

; date.toJSON(): the ISO text, null if invalid
jsdate_to_json:
    push rbx
    call jsdate_this
    call jsdate_iso
    jnc .out
    mov rax, JS_NULL
.out:
    pop rbx
    ret

; jsdate_text_start: RDX = this -> RBX = the Date, RDI = jsdate_buf, fields
; filled; CF=1 (RAX = "Invalid Date") if invalid
jsdate_text_start:
    call jsdate_this
    lea rdi, [jsdate_buf]
    call jsdate_fields
    jnc .ret
    push rsi
    lea rsi, [jsdate_str_invalid]
    call jsb_cstr
    pop rsi
    stc
.ret:
    ret

; date.toString(): "Mon Jan 15 2024 10:30:00 GMT+0000 (Coordinated Universal Time)"
jsdate_to_string:
    push rbx
    push rsi
    push rdi
    call jsdate_text_start
    jc .out
    call jsdate_put_date_text
    mov byte [rdi], ' '
    inc rdi
    call jsdate_put_hms
    lea rsi, [jsdate_str_zone]
    call jsdate_put
    call jsdate_take
.out:
    pop rdi
    pop rsi
    pop rbx
    ret

; date.toDateString(): "Mon Jan 15 2024"
jsdate_to_date_string:
    push rbx
    push rsi
    push rdi
    call jsdate_text_start
    jc .out
    call jsdate_put_date_text
    call jsdate_take
.out:
    pop rdi
    pop rsi
    pop rbx
    ret

; date.toTimeString(): "10:30:00 GMT+0000 (Coordinated Universal Time)"
jsdate_to_time_string:
    push rbx
    push rsi
    push rdi
    call jsdate_text_start
    jc .out
    call jsdate_put_hms
    lea rsi, [jsdate_str_zone]
    call jsdate_put
    call jsdate_take
.out:
    pop rdi
    pop rsi
    pop rbx
    ret

; date.toUTCString(): "Mon, 15 Jan 2024 10:30:00 GMT"
jsdate_to_utc_string:
    push rbx
    push rcx
    push rsi
    push rdi
    call jsdate_text_start
    jc .out
    lea rsi, [jsdate_days]
    mov rax, [jsdate_f + DF_DAY]
    call jsdate_put3
    mov byte [rdi], ','
    mov byte [rdi + 1], ' '
    add rdi, 2
    mov rax, [jsdate_f + DF_DATE]
    mov ecx, 2
    call jsdate_put_num
    mov byte [rdi], ' '
    inc rdi
    lea rsi, [jsdate_months]
    mov rax, [jsdate_f + DF_MONTH]
    call jsdate_put3
    mov byte [rdi], ' '
    inc rdi
    mov rax, [jsdate_f + DF_YEAR]
    mov ecx, 4
    call jsdate_put_num
    mov byte [rdi], ' '
    inc rdi
    call jsdate_put_hms
    lea rsi, [jsdate_str_gmt]
    call jsdate_put
    call jsdate_take
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; jsdate_put_us_date: -> "1/15/2024" (en-US)
jsdate_put_us_date:
    push rax
    push rcx
    mov ecx, 1
    mov rax, [jsdate_f + DF_MONTH]
    inc eax
    call jsdate_put_num
    mov byte [rdi], '/'
    inc rdi
    mov rax, [jsdate_f + DF_DATE]
    call jsdate_put_num
    mov byte [rdi], '/'
    inc rdi
    mov rax, [jsdate_f + DF_YEAR]
    call jsdate_put_num
    pop rcx
    pop rax
    ret

; jsdate_put_us_time: -> "10:30:00 AM" (en-US)
jsdate_put_us_time:
    push rax
    push rcx
    push rdx
    mov rax, [jsdate_f + DF_HOURS]
    mov dl, 'A'
    cmp eax, 12
    jb .am
    mov dl, 'P'
    sub eax, 12
.am:
    test eax, eax
    jnz .hour
    mov eax, 12
.hour:
    mov ecx, 1
    call jsdate_put_num
    mov byte [rdi], ':'
    inc rdi
    mov ecx, 2
    mov rax, [jsdate_f + DF_MINUTES]
    call jsdate_put_num
    mov byte [rdi], ':'
    inc rdi
    mov rax, [jsdate_f + DF_SECONDS]
    call jsdate_put_num
    mov byte [rdi], ' '
    mov [rdi + 1], dl
    mov byte [rdi + 2], 'M'
    add rdi, 3
    pop rdx
    pop rcx
    pop rax
    ret

; date.toLocaleString() / toLocaleDateString() / toLocaleTimeString() (en-US)
jsdate_to_locale_string:
    push rbx
    push rsi
    push rdi
    call jsdate_text_start
    jc .out
    call jsdate_put_us_date
    mov byte [rdi], ','
    mov byte [rdi + 1], ' '
    add rdi, 2
    call jsdate_put_us_time
    call jsdate_take
.out:
    pop rdi
    pop rsi
    pop rbx
    ret
jsdate_to_locale_date:
    push rbx
    push rsi
    push rdi
    call jsdate_text_start
    jc .out
    call jsdate_put_us_date
    call jsdate_take
.out:
    pop rdi
    pop rsi
    pop rbx
    ret
jsdate_to_locale_time:
    push rbx
    push rsi
    push rdi
    call jsdate_text_start
    jc .out
    call jsdate_put_us_time
    call jsdate_take
.out:
    pop rdi
    pop rsi
    pop rbx
    ret

; jsdate_inspect: RDI = a Date -> its ISO text (or "Invalid Date") into
; jsout_buf (console.log)
jsdate_inspect:
    push rax
    push rbx
    push rsi
    mov rbx, rdi
    call jsdate_iso
    jc .invalid
    mov eax, eax
    call jsout_str
    jmp .out
.invalid:
    lea rsi, [jsdate_str_invalid]
    call jsout_cstr
.out:
    pop rsi
    pop rbx
    pop rax
    ret

; ==============================================================================
; Parsing
; ==============================================================================

; ------------------------------------------------------------------------------
; jsdate_parse: RAX = a string (heap) -> RAX = its time value (double bits,
; NaN if it is not a date): ISO 8601, else the usual English forms
; ------------------------------------------------------------------------------
jsdate_parse:
    push rcx
    push rsi
    push r8
    lea rsi, [rax + JSTR_DATA]
    mov ecx, [rax + JSTR_LEN]
    lea r8, [rsi + rcx]             ; the end
    call jsdate_parse_iso
    jnc .out
    lea rsi, [rax + JSTR_DATA]
    call jsdate_parse_text
.out:
    pop r8
    pop rsi
    pop rcx
    ret

; jsdate_digits: RSI = text, ECX = exactly this many digits -> EAX = their
; value, RSI past them; CF=1 if they are not there
jsdate_digits:
    push rdx
    push rcx
    xor eax, eax
.digit:
    cmp rsi, r8
    jae .no
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .no
    imul eax, eax, 10
    add eax, edx
    inc rsi
    dec ecx
    jnz .digit
    pop rcx
    pop rdx
    clc
    ret
.no:
    pop rcx
    pop rdx
    stc
    ret

; jsdate_expect: RSI = text, AL = a character -> CF=1 unless it is next (then
; RSI past it)
jsdate_expect:
    cmp rsi, r8
    jae .no
    cmp [rsi], al
    jne .no
    inc rsi
    clc
    ret
.no:
    stc
    ret

; jsdate_parse_iso: RSI .. R8 = text -> RAX = the time, CF=1 if it is not
; ISO 8601 (YYYY[-MM[-DD]][THH:mm[:ss[.sss]][Z|+HH:MM]], +/-YYYYYY years)
jsdate_parse_iso:
    push rbx
    push rcx
    push rdx
    push rdi
    push rax
    xor eax, eax
    mov [jsdate_f + DF_HOURS], rax
    mov [jsdate_f + DF_MINUTES], rax
    mov [jsdate_f + DF_SECONDS], rax
    mov [jsdate_f + DF_MS], rax
    mov [jsdate_f + DF_MONTH], rax
    mov qword [jsdate_f + DF_DATE], 1
    xor edi, edi                    ; the offset in minutes
    ; the year
    cmp rsi, r8
    jae .no
    mov bl, [rsi]
    cmp bl, '+'
    je .wide
    cmp bl, '-'
    je .wide
    mov ecx, 4
    call jsdate_digits
    jc .no
    jmp .year
.wide:
    inc rsi
    mov ecx, 6
    call jsdate_digits
    jc .no
    cmp bl, '-'
    jne .year
    neg eax
.year:
    movsxd rax, eax
    mov [jsdate_f + DF_YEAR], rax
    mov al, '-'
    call jsdate_expect
    jc .time
    mov ecx, 2
    call jsdate_digits
    jc .no
    dec eax
    mov [jsdate_f + DF_MONTH], rax
    mov al, '-'
    call jsdate_expect
    jc .time
    mov ecx, 2
    call jsdate_digits
    jc .no
    mov [jsdate_f + DF_DATE], rax
.time:
    cmp rsi, r8
    jae .done
    mov al, [rsi]
    cmp al, 'T'
    je .t
    cmp al, 't'
    je .t
    cmp al, ' '
    jne .no
.t:
    inc rsi
    mov ecx, 2
    call jsdate_digits
    jc .no
    mov [jsdate_f + DF_HOURS], rax
    mov al, ':'
    call jsdate_expect
    jc .no
    call jsdate_digits
    jc .no
    mov [jsdate_f + DF_MINUTES], rax
    mov al, ':'
    call jsdate_expect
    jc .zone
    call jsdate_digits
    jc .no
    mov [jsdate_f + DF_SECONDS], rax
    mov al, '.'
    call jsdate_expect
    jc .zone
    ; milliseconds: 1 .. 3 digits count, more are ignored
    xor eax, eax
    mov ecx, 100
.ms:
    cmp rsi, r8
    jae .ms_done
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .ms_done
    imul edx, ecx
    add eax, edx
    push rax
    mov eax, ecx
    xor edx, edx
    mov ecx, 10
    div ecx
    mov ecx, eax
    pop rax
    inc rsi
    jmp .ms
.ms_done:
    mov [jsdate_f + DF_MS], rax
.zone:
    cmp rsi, r8
    jae .done
    mov al, [rsi]
    cmp al, 'Z'
    je .utc
    cmp al, 'z'
    je .utc
    cmp al, '+'
    je .offset
    cmp al, '-'
    jne .no
.offset:
    mov bl, al
    inc rsi
    mov ecx, 2
    call jsdate_digits
    jc .no
    imul edi, eax, 60
    mov al, ':'
    call jsdate_expect
    call jsdate_digits
    jc .no
    add edi, eax
    cmp bl, '-'
    jne .done
    neg edi
    jmp .done
.utc:
    inc rsi
.done:
    cmp rsi, r8
    jne .no
    ; the local time minus the offset
    movsxd rdi, edi
    sub [jsdate_f + DF_MINUTES], rdi
    call jsdate_join
    add rsp, 8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    clc
    ret
.no:
    pop rax
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    stc
    ret

; ------------------------------------------------------------------------------
; jsdate_parse_text: RSI .. R8 = text -> RAX = the time (NaN if it makes no
; sense): words, numbers and h:m[:s], in the usual English orders
; ("Mon Jan 15 2024 10:30:00 GMT+0000", "Jan 15, 2024", "15 January 2024",
; "1/15/2024", "2024/01/15 10:30 PM")
; ------------------------------------------------------------------------------
jsdate_parse_text:
    push rbx
    push rcx
    push rdx
    push rdi
    push r9
    push r10
    push r11
    push r12
    xor eax, eax
    mov [jsdate_f + DF_HOURS], rax
    mov [jsdate_f + DF_MINUTES], rax
    mov [jsdate_f + DF_SECONDS], rax
    mov [jsdate_f + DF_MS], rax
    mov r9, -1                      ; year
    mov r10, -1                     ; month (0 ..)
    mov r11, -1                     ; day
    xor r12d, r12d                  ; bit 0: PM, bit 1: AM, bit 2: an offset seen
    xor edi, edi                    ; the offset in minutes
.token:
    cmp rsi, r8
    jae .end
    movzx eax, byte [rsi]
    mov dl, al
    sub dl, '0'
    cmp dl, 9
    jbe .number
    mov dl, al
    or dl, 0x20
    sub dl, 'a'
    cmp dl, 25
    jbe .word
    cmp al, '+'
    je .offset
    cmp al, '-'
    je .minus
    inc rsi                         ; spaces, commas, dots, parentheses...
    jmp .token
.minus:
    ; "-0500" after a time, or a date separator
    test r12d, 8                    ; a time was seen
    jz .skip
    jmp .offset
.skip:
    inc rsi
    jmp .token
.word:
    ; a month name, a weekday, AM / PM, GMT / UTC / Z, or (...) text
    mov rbx, rsi
.word_end:
    cmp rsi, r8
    jae .word_done
    mov dl, [rsi]
    or dl, 0x20
    sub dl, 'a'
    cmp dl, 25
    ja .word_done
    inc rsi
    jmp .word_end
.word_done:
    mov rcx, rsi
    sub rcx, rbx
    cmp rcx, 2
    jne .not_ampm
    mov ax, [rbx]
    or ax, 0x2020
    cmp ax, 'am'
    jne .pm
    or r12d, 2
    jmp .token
.pm:
    cmp ax, 'pm'
    jne .not_ampm
    or r12d, 1
    jmp .token
.not_ampm:
    cmp rcx, 3
    jb .token
    ; the first three letters against the month names
    mov eax, [rbx]
    and eax, 0x00FFFFFF
    or eax, 0x00202020
    lea rdx, [jsdate_months]
    xor ecx, ecx
.month:
    cmp ecx, 12
    jae .token                      ; (weekday names and the rest: ignored)
    push rax
    mov eax, [rdx]
    and eax, 0x00FFFFFF
    or eax, 0x00202020
    cmp eax, [rsp]
    pop rax
    je .month_found
    add rdx, 3
    inc ecx
    jmp .month
.month_found:
    mov r10d, ecx
    jmp .token
.number:
    ; digits: a time (h:m[:s]) or a number
    mov rbx, rsi
    xor eax, eax
.digits:
    cmp rsi, r8
    jae .number_done
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .number_done
    imul eax, eax, 10
    add eax, edx
    cmp eax, 1000000
    ja .nan
    inc rsi
    jmp .digits
.number_done:
    mov rcx, rsi
    sub rcx, rbx                    ; how many digits
    cmp rsi, r8
    jae .plain
    cmp byte [rsi], ':'
    je .clock
    cmp byte [rsi], '/'
    je .slashes
.plain:
    ; a year (4 digits or > 31), else the day (or the month then the day)
    cmp ecx, 3
    jae .is_year
    cmp eax, 31
    ja .is_year
    cmp r11, -1
    jne .is_year
    mov r11d, eax
    jmp .token
.is_year:
    mov r9d, eax
    jmp .token
.clock:
    or r12d, 8
    mov [jsdate_f + DF_HOURS], rax
    inc rsi
    call .two
    jc .nan
    mov [jsdate_f + DF_MINUTES], rax
    cmp rsi, r8
    jae .token
    cmp byte [rsi], ':'
    jne .token
    inc rsi
    call .two
    jc .nan
    mov [jsdate_f + DF_SECONDS], rax
    jmp .token
.slashes:
    ; a/b/c: year/month/day if a has 4 digits, else month/day/year
    inc rsi
    push rax
    push rcx
    call .number_at
    mov edx, eax
    pop rcx
    pop rax
    jc .nan
    cmp rsi, r8
    jae .nan
    cmp byte [rsi], '/'
    jne .nan
    inc rsi
    push rax
    push rdx
    call .number_at
    mov ebx, eax
    pop rdx
    pop rax
    jc .nan
    cmp ecx, 4
    jb .mdy
    mov r9d, eax
    lea r10d, [edx - 1]
    mov r11d, ebx
    jmp .token
.mdy:
    lea r10d, [eax - 1]
    mov r11d, edx
    mov r9d, ebx
    jmp .token
.offset:
    ; +HHMM / -HHMM (GMT+0000)
    mov bl, al
    inc rsi
    call .number_at
    jc .nan
    mov ecx, eax
    xor edx, edx
    mov eax, ecx
    push rcx
    mov ecx, 100
    div ecx
    pop rcx
    imul eax, eax, 60
    add eax, edx
    mov edi, eax
    cmp bl, '-'
    jne .offset_sign
    neg edi
.offset_sign:
    or r12d, 4
    jmp .token
.end:
    ; a date needs a month, a day and a year
    cmp r9, -1
    je .nan
    cmp r10, -1
    je .nan
    cmp r11, -1
    je .nan
    mov [jsdate_f + DF_YEAR], r9
    mov [jsdate_f + DF_MONTH], r10
    mov [jsdate_f + DF_DATE], r11
    cmp r9, 100
    jae .ampm
    add qword [jsdate_f + DF_YEAR], 1900
    cmp r9, 50
    jae .ampm
    add qword [jsdate_f + DF_YEAR], 100
.ampm:
    mov rax, [jsdate_f + DF_HOURS]
    test r12d, 1
    jz .am
    cmp rax, 12
    jae .zone
    add qword [jsdate_f + DF_HOURS], 12
    jmp .zone
.am:
    test r12d, 2
    jz .zone
    cmp rax, 12
    jne .zone
    mov qword [jsdate_f + DF_HOURS], 0
.zone:
    movsxd rdi, edi
    sub [jsdate_f + DF_MINUTES], rdi
    call jsdate_join
    jmp .out
.nan:
    mov rax, JS_NAN
.out:
    pop r12
    pop r11
    pop r10
    pop r9
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
; .two: 1 or 2 digits at RSI -> EAX
.two:
    push rcx
    push rdx
    xor eax, eax
    xor ecx, ecx
.two_digit:
    cmp ecx, 2
    jae .two_done
    cmp rsi, r8
    jae .two_done
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .two_done
    imul eax, eax, 10
    add eax, edx
    inc rsi
    inc ecx
    jmp .two_digit
.two_done:
    cmp ecx, 1
    pop rdx
    pop rcx
    jb .two_bad
    clc
    ret
.two_bad:
    stc
    ret
; .number_at: digits at RSI -> EAX, CF=1 if there are none
.number_at:
    push rcx
    push rdx
    xor eax, eax
    xor ecx, ecx
.nd:
    cmp rsi, r8
    jae .nd_done
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .nd_done
    imul eax, eax, 10
    add eax, edx
    inc rsi
    inc ecx
    cmp ecx, 7
    jb .nd
.nd_done:
    test ecx, ecx
    pop rdx
    pop rcx
    jz .nd_bad
    clc
    ret
.nd_bad:
    stc
    ret
