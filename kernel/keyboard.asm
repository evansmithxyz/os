; ==============================================================================
; Antigravity OS - 64-bit PS/2 Keyboard Driver & Scancode Decoder
; Translates Set-1 scancodes into ASCII characters and manages input buffer
; ==============================================================================

[bits 64]

INPUT_BUFFER_MAX equ 128

shift_state:        db 0
alt_state:          db 0
ctrl_state:         db 0
line_ready:         db 0
tab_requested:      db 0
gui_last_scancode:  db 0
gui_last_key:       db 0
input_len:          dq 0
input_buffer:       times INPUT_BUFFER_MAX db 0

; Scancode Set 1 Lowercase Translation Table (Index = Scancode, 0x00 - 0x39)
scancode_table:
    db 0, 27, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 0x08, 0x09
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 0x0D, 0
    db 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', "'", '`', 0, '\'
    db 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0, '*', 0, ' '

; Scancode Set 1 Uppercase / Shift Translation Table
scancode_table_shift:
    db 0, 27, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 0x08, 0x09
    db 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 0x0D, 0
    db 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0, '|'
    db 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0, '*', 0, ' '

; ------------------------------------------------------------------------------
; keyboard_process_scancode: Called by 64-bit ISR when a key is pressed/released
; Input: AL = raw scancode from port 0x60
; ------------------------------------------------------------------------------
keyboard_process_scancode:
    push rax
    push rbx
    push rcx
    push rdx

    ; Handle Shift Key Press (Make code: 0x2A = LShift, 0x36 = RShift)
    cmp al, 0x2A
    je .shift_down
    cmp al, 0x36
    je .shift_down

    ; Handle Shift Key Release (Break code: 0xAA = LShift, 0xB6 = RShift)
    cmp al, 0xAA
    je .shift_up
    cmp al, 0xB6
    je .shift_up

    ; Handle Alt Key Press / Release (0x38 = Make, 0xB8 = Break)
    cmp al, 0x38
    je .alt_down
    cmp al, 0xB8
    je .alt_up

    ; Handle Ctrl Key Press / Release (0x1D = Make, 0x9D = Break)
    cmp al, 0x1D
    je .ctrl_down
    cmp al, 0x9D
    je .ctrl_up

    ; If GUI / BGA is active, handle keyboard without echoing to text mode
    cmp byte [bga_active], 1
    jne .text_mode_keyboard

    ; GUI Mode Keyboard Input:
    test al, 0x80               ; Ignore key release
    jnz .done
    mov [gui_last_scancode], al
    cmp al, 0x3E                ; Support scancodes up to F4 (0x3E)
    ja .done
    cmp al, 0x39
    ja .f_keys
    movzx rbx, al
    cmp byte [shift_state], 1
    je .gui_shift
    mov bl, [scancode_table + rbx]
    mov [gui_last_key], bl
    jmp .done
.gui_shift:
    mov bl, [scancode_table_shift + rbx]
    mov [gui_last_key], bl
    jmp .done
.f_keys:
    mov [gui_last_key], al      ; F1..F4 key
    jmp .done

.text_mode_keyboard:

    ; Handle Shift Key Release (Break code: 0xAA = LShift, 0xB6 = RShift)
    cmp al, 0xAA
    je .shift_up
    cmp al, 0xB6
    je .shift_up

    ; Ignore other break codes (bit 7 set = key release)
    test al, 0x80
    jnz .done

    ; Validate scancode within table range (< 0x3A)
    cmp al, 0x39
    ja .done

    ; Convert scancode to ASCII
    movzx rbx, al
    cmp byte [shift_state], 1
    je .use_shift_table
    mov al, [scancode_table + rbx]
    jmp .handle_ascii

.use_shift_table:
    mov al, [scancode_table_shift + rbx]

.handle_ascii:
    test al, al
    jz .done

    ; Check for Enter (0x0D)
    cmp al, 0x0D
    je .handle_enter

    ; Check for Backspace (0x08)
    cmp al, 0x08
    je .handle_backspace

    ; Check for Tab (0x09)
    cmp al, 0x09
    je .handle_tab

    ; Regular printable character
    mov rcx, [input_len]
    cmp rcx, INPUT_BUFFER_MAX - 2
    jae .done

    ; Append to buffer
    mov [input_buffer + rcx], al
    inc qword [input_len]
    mov byte [input_buffer + rcx + 1], 0

    ; Echo character to screen
    call vga_print_char
    jmp .done

.handle_tab:
    mov byte [tab_requested], 1
    jmp .done

.handle_backspace:
    mov rcx, [input_len]
    test rcx, rcx
    jz .done
    dec qword [input_len]
    dec rcx
    mov byte [input_buffer + rcx], 0
    call vga_print_char
    jmp .done

.handle_enter:
    mov rcx, [input_len]
    mov byte [input_buffer + rcx], 0
    mov byte [line_ready], 1
    call vga_print_char
    mov al, 0x0A
    call vga_print_char
    jmp .done

.shift_down:
    mov byte [shift_state], 1
    jmp .done

.shift_up:
    mov byte [shift_state], 0
    jmp .done

.alt_down:
    mov byte [alt_state], 1
    jmp .done

.alt_up:
    mov byte [alt_state], 0
    jmp .done

.ctrl_down:
    mov byte [ctrl_state], 1
    jmp .done

.ctrl_up:
    mov byte [ctrl_state], 0
    jmp .done

.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; keyboard_clear_buffer: Resets line input buffer for next command
; ------------------------------------------------------------------------------
keyboard_clear_buffer:
    push rax
    mov qword [input_len], 0
    mov byte [line_ready], 0
    mov byte [tab_requested], 0
    mov byte [input_buffer], 0
    pop rax
    ret
