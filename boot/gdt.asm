; ==============================================================================
; Antigravity OS - Global Descriptor Table (GDT)
; Unified GDT supporting 32-bit Protected Mode and 64-bit Long Mode
; ==============================================================================

[bits 16]

gdt_start:
    ; 0x00: Null Descriptor (8 bytes)
    dq 0x0000000000000000

gdt_code32:
    ; 0x08: 32-bit Kernel Code Segment Descriptor
    dw 0xFFFF                   ; Limit (bits 0-15)
    dw 0x0000                   ; Base (bits 0-15)
    db 0x00                     ; Base (bits 16-23)
    db 10011010b                ; Access: Present, Ring 0, Code, Exec/Read (0x9A)
    db 11001111b                ; Flags: 4KB Granularity, 32-bit (0xCF)
    db 0x00                     ; Base (bits 24-31)

gdt_data32:
    ; 0x10: 32-bit Kernel Data Segment Descriptor
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b                ; Access: Present, Ring 0, Data, Read/Write (0x92)
    db 11001111b                ; Flags: 4KB Granularity, 32-bit (0xCF)
    db 0x00

gdt_code64:
    ; 0x18: 64-bit Kernel Code Segment Descriptor (L=1, D=0)
    dw 0x0000                   ; Limit (ignored in 64-bit mode)
    dw 0x0000                   ; Base (ignored in 64-bit mode)
    db 0x00
    db 10011010b                ; Access: Present, Ring 0, Code, Exec/Read (0x9A)
    db 00100000b                ; Flags: Long Mode (L=1, D=0) (0x20)
    db 0x00

gdt_data64:
    ; 0x20: 64-bit Kernel Data Segment Descriptor
    dw 0x0000
    dw 0x0000
    db 0x00
    db 10010010b                ; Access: Present, Ring 0, Data, Read/Write (0x92)
    db 00000000b                ; Flags: (0x00)
    db 0x00

gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1  ; GDT Limit
    dd gdt_start                ; GDT Base Address

; Segment Selectors
CODE_SEG32 equ gdt_code32 - gdt_start   ; 0x08
DATA_SEG32 equ gdt_data32 - gdt_start   ; 0x10
CODE_SEG64 equ gdt_code64 - gdt_start   ; 0x18
DATA_SEG64 equ gdt_data64 - gdt_start   ; 0x20
