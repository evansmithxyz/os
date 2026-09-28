; ==============================================================================
; Antigravity OS - 64-bit PS/2 Mouse Controller Driver
; 8042 Auxiliary Device Communication, 3-Byte Packet Decoder & Position Clamping
; ==============================================================================

[bits 64]

section .data
mouse_x:            dd 512              ; Cursor X (0 .. GFX_WIDTH-1)
mouse_y:            dd 384              ; Cursor Y (0 .. GFX_HEIGHT-1)
mouse_buttons:      db 0                ; Bit 0: Left, Bit 1: Right, Bit 2: Middle
mouse_prev_buttons: db 0

mouse_cycle:        db 0                ; Packet Cycle (0 .. 2)
mouse_byte0:        db 0                ; Flags / Buttons
mouse_byte1:        db 0                ; Delta X
mouse_byte2:        db 0                ; Delta Y
mouse_active:       db 0

section .text

; ------------------------------------------------------------------------------
; mouse_wait_write: Waits until 8042 controller input buffer is empty
; ------------------------------------------------------------------------------
mouse_wait_write:
    push rcx
    push rax
    mov ecx, 100000
.loop:
    in al, 0x64
    test al, 0x02               ; Bit 1: Input buffer status (1 = full)
    jz .ready
    pause
    dec ecx
    jnz .loop
.ready:
    pop rax
    pop rcx
    ret

; ------------------------------------------------------------------------------
; mouse_wait_read: Waits until 8042 controller output buffer has data
; ------------------------------------------------------------------------------
mouse_wait_read:
    push rcx
    push rax
    mov ecx, 100000
.loop:
    in al, 0x64
    test al, 0x01               ; Bit 0: Output buffer status (1 = data ready)
    jnz .ready
    pause
    dec ecx
    jnz .loop
.ready:
    pop rax
    pop rcx
    ret

; ------------------------------------------------------------------------------
; mouse_write_cmd: Sends a command byte directly to the mouse device
; Input: AL = Command byte
; ------------------------------------------------------------------------------
mouse_write_cmd:
    push rax
    call mouse_wait_write
    mov al, 0xD4                ; Tell 8042 next byte is for mouse
    out 0x64, al
    call mouse_wait_write
    pop rax
    out 0x60, al                ; Send command to mouse
    ret

; ------------------------------------------------------------------------------
; mouse_read_data: Reads response byte from mouse
; Output: AL = Data byte
; ------------------------------------------------------------------------------
mouse_read_data:
    call mouse_wait_read
    in al, 0x60
    ret

; ------------------------------------------------------------------------------
; mouse_init: Configures 8042 controller for auxiliary PS/2 mouse
; ------------------------------------------------------------------------------
mouse_init:
    push rax
    push rbx
    push rcx
    push rdx

    pushfq
    cli                         ; Critical section: disable interrupts during 8042 setup

    ; 1. Enable Auxiliary PS/2 Port (Command 0xA8)
    call mouse_wait_write
    mov al, 0xA8
    out 0x64, al

    ; 2. Read Controller Command Byte (Command 0x20)
    call mouse_wait_write
    mov al, 0x20
    out 0x64, al
    call mouse_wait_read
    in al, 0x60

    ; Ensure IRQ1 (bit 0 = 1), IRQ12 (bit 1 = 1), Translation (bit 6 = 1)
    ; and enable clocks (bits 4, 5 = 0)
    or al, 0x47
    and al, ~0x30

    ; Write modified Controller Command Byte back (Command 0x60)
    mov bl, al
    call mouse_wait_write
    mov al, 0x60
    out 0x64, al
    call mouse_wait_write
    mov al, bl
    out 0x60, al

    ; 3. Set Mouse Defaults (Command 0xF6)
    mov al, 0xF6
    call mouse_write_cmd
    call mouse_read_data        ; Read 0xFA ACK

    ; 4. Enable Mouse Data Reporting (Command 0xF4)
    mov al, 0xF4
    call mouse_write_cmd
    call mouse_read_data        ; Read 0xFA ACK

    ; 5. Keep IRQ12 masked on Slave PIC so mouse_poll reads port 0x60 synchronously
    in al, 0xA1
    or al, 0x10                 ; Set IRQ12 mask (bit 4)
    out 0xA1, al

    ; Reset mouse state
    mov dword [mouse_x], GFX_WIDTH / 2
    mov dword [mouse_y], GFX_HEIGHT / 2
    mov byte [mouse_buttons], 0
    mov byte [mouse_cycle], 0
    mov byte [mouse_active], 1

    popfq                       ; Restore previous interrupt flag
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; mouse_disable: stop mouse reporting and turn the aux port off again (called
; when the desktop exits, so stray mouse bytes cannot block the keyboard in
; the text console on a real 8042)
; ------------------------------------------------------------------------------
mouse_disable:
    push rax
    pushfq
    cli
    mov al, 0xF5                ; disable data reporting
    call mouse_write_cmd
    call mouse_wait_write
    mov al, 0xA7                ; disable the auxiliary port
    out 0x64, al
.drain:
    in al, 0x64                 ; throw away anything still buffered
    test al, 0x01
    jz .drained
    in al, 0x60
    jmp .drain
.drained:
    mov byte [mouse_active], 0
    popfq
    pop rax
    ret

; ------------------------------------------------------------------------------
; mouse_poll: Checks 8042 buffer for mouse packets and updates cursor state
; Called continuously during GUI event loop
; ------------------------------------------------------------------------------
mouse_poll:
    push rax
    push rbx
    push rcx
    push rdx

.poll_again:
    ; Read 8042 status register
    in al, 0x64
    test al, 0x01               ; Output buffer full?
    jz .done

    test al, 0x20               ; Is it mouse data (Bit 5 == 1)?
    jz .done                    ; No, keyboard data -> leave for keyboard driver

    ; Read byte from mouse
    in al, 0x60
    mov bl, al                  ; BL = raw byte

    ; State machine based on mouse_cycle
    movzx ecx, byte [mouse_cycle]
    cmp ecx, 0
    je .handle_byte0
    cmp ecx, 1
    je .handle_byte1
    cmp ecx, 2
    je .handle_byte2
    mov byte [mouse_cycle], 0
    jmp .done

.handle_byte0:
    ; Byte 0: Bit 3 must ALWAYS be 1 in standard PS/2 packet!
    test bl, 0x08
    jz .sync_error              ; If bit 3 == 0, packet is out of sync!
    mov [mouse_byte0], bl
    mov byte [mouse_cycle], 1
    jmp .poll_again

.handle_byte1:
    mov [mouse_byte1], bl
    mov byte [mouse_cycle], 2
    jmp .poll_again

.handle_byte2:
    mov [mouse_byte2], bl
    mov byte [mouse_cycle], 0   ; Reset cycle for next packet

    ; --------------------------------------------------------------------------
    ; Process Complete 3-Byte Packet
    ; --------------------------------------------------------------------------
    ; 1. Buttons
    mov al, [mouse_buttons]
    mov [mouse_prev_buttons], al
    mov al, [mouse_byte0]
    and al, 0x07                ; Bits 0=Left, 1=Right, 2=Middle
    mov [mouse_buttons], al

    ; 2. Delta X (signed 9-bit)
    movzx eax, byte [mouse_byte1]
    mov cl, [mouse_byte0]
    test cl, 0x10               ; X sign bit?
    jz .x_positive
    or eax, 0xFFFFFF00          ; Sign extend negative
.x_positive:
    ; Add delta X to mouse_x
    mov ebx, [mouse_x]
    add ebx, eax

    ; Clamp X to [0 .. 1023]
    cmp ebx, 0
    jge .x_not_min
    xor ebx, ebx
.x_not_min:
    cmp ebx, GFX_WIDTH - 1
    jle .x_not_max
    mov ebx, GFX_WIDTH - 1
.x_not_max:
    mov [mouse_x], ebx

    ; 3. Delta Y (signed 9-bit)
    ; PS/2 mouse positive Y is UPwards, while screen Y is DOWNwards -> Subtract!
    movzx eax, byte [mouse_byte2]
    test cl, 0x20               ; Y sign bit?
    jz .y_positive
    or eax, 0xFFFFFF00          ; Sign extend negative
.y_positive:
    ; Subtract delta Y from mouse_y
    mov ebx, [mouse_y]
    sub ebx, eax

    ; Clamp Y to [0 .. 767]
    cmp ebx, 0
    jge .y_not_min
    xor ebx, ebx
.y_not_min:
    cmp ebx, GFX_HEIGHT - 1
    jle .y_not_max
    mov ebx, GFX_HEIGHT - 1
.y_not_max:
    mov [mouse_y], ebx

    jmp .poll_again

.sync_error:
    ; Discard byte and reset cycle
    mov byte [mouse_cycle], 0
    jmp .done

.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
