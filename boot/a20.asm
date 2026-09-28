; ==============================================================================
; Antigravity OS - A20 Line Enabler
; Uses BIOS INT 0x15 followed by Fast A20 Gate fallback
; ==============================================================================

[bits 16]

enable_a20:
    ; Method 1: BIOS INT 0x15 AX=0x2401
    mov ax, 0x2401
    int 0x15
    jnc .done

    ; Method 2: Fast A20 Gate (Port 0x92)
    in al, 0x92
    test al, 2
    jnz .done
    or al, 2
    and al, 0xFE            ; Prevent accidental fast reset
    out 0x92, al

.done:
    ret
