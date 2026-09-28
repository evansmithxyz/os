; ==============================================================================
; Antigravity OS - PS/2 Keyboard Driver (IRQ1, scancode set 1)
; ------------------------------------------------------------------------------
; The ISR only decodes scancodes and pushes key events into the console key
; queue (key_push). Nothing is echoed or executed in interrupt context; the
; text-mode shell and the GUI both consume events with key_get.
;
; Key event format (AX):
;   AL = ASCII code, or 0 for keys without one (F1-F12, arrows)
;   AH = make scancode (e.g. 0x3B = F1, 0x48 = Up, 0x01 = Esc)
; Modifier state is available in kbd_shift / kbd_ctrl / kbd_alt.
; ==============================================================================

[bits 64]

SC_ESC          equ 0x01
SC_BACKSPACE    equ 0x0E
SC_TAB          equ 0x0F
SC_ENTER        equ 0x1C
SC_LCTRL        equ 0x1D
SC_LSHIFT       equ 0x2A
SC_RSHIFT       equ 0x36
SC_LALT         equ 0x38
SC_CAPSLOCK     equ 0x3A
SC_F1           equ 0x3B
SC_F4           equ 0x3E
SC_F10          equ 0x44
SC_UP           equ 0x48
SC_LEFT         equ 0x4B
SC_RIGHT        equ 0x4D
SC_DOWN         equ 0x50
SC_EXTENDED     equ 0xE0

section .data
kbd_shift:      db 0
kbd_ctrl:       db 0
kbd_alt:        db 0
kbd_capslock:   db 0
kbd_extended:   db 0

section .text
; ------------------------------------------------------------------------------
; isr_keyboard: IRQ1
; ------------------------------------------------------------------------------
isr_keyboard:
    push rax
    in al, 0x64
    test al, 0x01                   ; output buffer full?
    jz .eoi
    test al, 0x20                   ; byte from the mouse?
    jz .keyboard_byte
    cmp byte [gui_running], 0       ; the desktop polls the mouse itself;
    jne .eoi                        ; otherwise drop it so it can't block keys
    in al, 0x60
    jmp .eoi
.keyboard_byte:
    in al, 0x60
    call kbd_decode
.eoi:
    mov al, PIC_EOI
    out PIC1_COMMAND, al
    pop rax
    iretq

; ------------------------------------------------------------------------------
; kbd_decode: AL = raw scancode byte
; ------------------------------------------------------------------------------
kbd_decode:
    push rax
    push rbx

    cmp al, SC_EXTENDED
    jne .not_prefix
    mov byte [kbd_extended], 1
    jmp .done
.not_prefix:
    mov bl, al
    and bl, 0x7F                    ; make code
    mov bh, al
    and bh, 0x80                    ; BH != 0 -> key released

    cmp byte [kbd_extended], 0
    je .normal
    mov byte [kbd_extended], 0
    ; Extended keys: right ctrl/alt, arrows, keypad enter and slash
    cmp bl, SC_LCTRL
    je .ctrl
    cmp bl, SC_LALT
    je .alt
    test bh, bh
    jnz .done
    cmp bl, SC_ENTER
    je .push_enter
    cmp bl, 0x35                    ; keypad '/'
    je .push_slash
    cmp bl, SC_UP
    je .push_special
    cmp bl, SC_DOWN
    je .push_special
    cmp bl, SC_LEFT
    je .push_special
    cmp bl, SC_RIGHT
    je .push_special
    jmp .done

.normal:
    cmp bl, SC_LSHIFT
    je .shift
    cmp bl, SC_RSHIFT
    je .shift
    cmp bl, SC_LCTRL
    je .ctrl
    cmp bl, SC_LALT
    je .alt
    test bh, bh
    jnz .done                       ; ignore other releases
    cmp bl, SC_CAPSLOCK
    je .capslock
    cmp bl, SC_F1
    jae .special_range

    ; Printable / control keys from the translation tables (0x00 - 0x39)
    movzx eax, bl
    cmp byte [kbd_shift], 0
    jne .shifted
    mov al, [scancode_table + rax]
    jmp .have_ascii
.shifted:
    mov al, [scancode_table_shift + rax]
.have_ascii:
    test al, al
    jz .done
    ; Caps Lock flips the case of letters
    cmp byte [kbd_capslock], 0
    je .ctrl_check
    mov ah, al
    or ah, 0x20
    cmp ah, 'a'
    jb .ctrl_check
    cmp ah, 'z'
    ja .ctrl_check
    xor al, 0x20
.ctrl_check:
    ; Ctrl + letter -> control code (Ctrl+C = 3)
    cmp byte [kbd_ctrl], 0
    je .push
    mov ah, al
    or ah, 0x20
    cmp ah, 'a'
    jb .push
    cmp ah, 'z'
    ja .push
    mov al, ah
    sub al, 'a' - 1
.push:
    mov ah, bl
    call key_push
    jmp .done

.special_range:
    ; F1-F10 and the non-extended keypad arrows (numpad 8/2/4/6 with NumLock off)
    cmp bl, SC_F10
    jbe .push_special
    cmp bl, SC_UP
    je .push_special
    cmp bl, SC_DOWN
    je .push_special
    cmp bl, SC_LEFT
    je .push_special
    cmp bl, SC_RIGHT
    je .push_special
    jmp .done
.push_special:
    xor al, al
    mov ah, bl
    call key_push
    jmp .done
.push_enter:
    mov al, 0x0D
    mov ah, SC_ENTER
    call key_push
    jmp .done
.push_slash:
    mov al, '/'
    mov ah, 0x35
    call key_push
    jmp .done

.shift:
    test bh, bh
    setz byte [kbd_shift]
    jmp .done
.ctrl:
    test bh, bh
    setz byte [kbd_ctrl]
    jmp .done
.alt:
    test bh, bh
    setz byte [kbd_alt]
    jmp .done
.capslock:
    xor byte [kbd_capslock], 1
.done:
    pop rbx
    pop rax
    ret

section .rodata
; Scancode set 1 -> ASCII (index = make code 0x00 - 0x39)
scancode_table:
    db 0, 27, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 0x08, 0x09
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 0x0D, 0
    db 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', "'", '`', 0, '\'
    db 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0, '*', 0, ' '
scancode_table_shift:
    db 0, 27, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 0x08, 0x09
    db 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 0x0D, 0
    db 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0, '|'
    db 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0, '*', 0, ' '
