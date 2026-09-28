; ==============================================================================
; Antigravity OS - 64-bit Bochs Graphics Adaptor (BGA) & Framebuffer Driver
; High-Resolution 1024x768x32bpp TrueColor Linear Framebuffer (LFB)
; ==============================================================================

[bits 64]

; BGA I/O Ports
BGA_INDEX_PORT          equ 0x01CE
BGA_DATA_PORT           equ 0x01CF

; BGA Register Indexes
VBE_DISPI_INDEX_ID      equ 0x0
VBE_DISPI_INDEX_XRES    equ 0x1
VBE_DISPI_INDEX_YRES    equ 0x2
VBE_DISPI_INDEX_BPP     equ 0x3
VBE_DISPI_INDEX_ENABLE  equ 0x4
VBE_DISPI_INDEX_BANK    equ 0x5
VBE_DISPI_INDEX_VIRT_W  equ 0x6
VBE_DISPI_INDEX_VIRT_H  equ 0x7
VBE_DISPI_INDEX_X_OFF   equ 0x8
VBE_DISPI_INDEX_Y_OFF   equ 0x9

; BGA Enable Flags
VBE_DISPI_DISABLED      equ 0x00
VBE_DISPI_ENABLED       equ 0x01
VBE_DISPI_LFB_ENABLED   equ 0x40
VBE_DISPI_NOCLEARMEM    equ 0x80

; Default Resolution: 1024 x 768 x 32bpp
GUI_SCREEN_WIDTH        equ 1024
GUI_SCREEN_HEIGHT       equ 768
GUI_SCREEN_BPP          equ 32
GUI_SCREEN_PITCH        equ (GUI_SCREEN_WIDTH * 4)

; Driver State Variables
bga_available:          db 0
bga_active:             db 0
bga_base_lfb:           dq 0x00000000FD000000   ; 64-bit Linear Framebuffer physical base
bga_lfb_ptr:            dq 0x00000000FD000000   ; Active Framebuffer drawing pointer
bga_front_page:         db 0                    ; Currently displayed page (0 or 1)
bga_width:              dd GUI_SCREEN_WIDTH
bga_height:             dd GUI_SCREEN_HEIGHT
bga_pitch:              dd GUI_SCREEN_PITCH

; ------------------------------------------------------------------------------
; bga_write_register: Writes a 16-bit value to a BGA register index
; Input: CX = Register Index, AX = Data Value
; ------------------------------------------------------------------------------
bga_write_register:
    push rdx
    mov dx, BGA_INDEX_PORT
    xchg ax, cx
    out dx, ax                  ; Write Index
    mov dx, BGA_DATA_PORT
    mov ax, cx
    out dx, ax                  ; Write Data
    pop rdx
    ret

; ------------------------------------------------------------------------------
; bga_read_register: Reads a 16-bit value from a BGA register index
; Input: CX = Register Index
; Output: AX = Data Value
; ------------------------------------------------------------------------------
bga_read_register:
    push rdx
    mov dx, BGA_INDEX_PORT
    mov ax, cx
    out dx, ax                  ; Write Index
    mov dx, BGA_DATA_PORT
    in ax, dx                   ; Read Data
    pop rdx
    ret

; ------------------------------------------------------------------------------
; bga_init: Probes PCI bus for Bochs/QEMU VGA card (1234:1111) and initializes BGA
; Output: RAX = 0 on Success, 1 on Error
; ------------------------------------------------------------------------------
bga_init:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; 1. Query BGA Version via Port I/O (Index 0)
    mov cx, VBE_DISPI_INDEX_ID
    call bga_read_register
    cmp ax, 0xB0C0
    jb .probe_pci               ; If version < 0xB0C0, still check PCI
    cmp ax, 0xB0C6
    ja .probe_pci

.probe_pci:
    ; 2. Probe PCI Bus for QEMU Standard VGA (Vendor 0x1234, Device 0x1111)
    mov si, 0x1234
    mov di, 0x1111
    call pci_find_device
    jnz .pci_fallback           ; If not found, use default 0xFD000000

    ; EAX = bus, EBX = slot, ECX = func
    ; Also enable memory space decoding in command register
    call pci_enable_bus_master

    ; Read BAR0 (offset 0x10) to obtain physical framebuffer address
    mov edx, 0x10
    call pci_read_dword
    and eax, 0xFFFFFFF0         ; Mask memory space indicator bits
    test eax, eax
    jz .pci_fallback
    mov [bga_base_lfb], rax     ; Store 64-bit LFB base address
    mov [bga_lfb_ptr], rax

.pci_fallback:
    mov byte [bga_available], 1
    xor rax, rax                ; Success
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; bga_set_graphics_mode: Switches BGA to 1024x768x32bpp TrueColor Mode
; Output: RAX = 0 on Success
; ------------------------------------------------------------------------------
bga_set_graphics_mode:
    push rax
    push rcx
    push rdx

    ; 1. Disable BGA extensions during mode switch
    mov cx, VBE_DISPI_INDEX_ENABLE
    mov ax, VBE_DISPI_DISABLED
    call bga_write_register

    ; 2. Set X Resolution (1024)
    mov cx, VBE_DISPI_INDEX_XRES
    mov ax, GUI_SCREEN_WIDTH
    call bga_write_register

    ; 3. Set Y Resolution (768)
    mov cx, VBE_DISPI_INDEX_YRES
    mov ax, GUI_SCREEN_HEIGHT
    call bga_write_register

    ; 4. Set Virtual Width (1024)
    mov cx, VBE_DISPI_INDEX_VIRT_W
    mov ax, GUI_SCREEN_WIDTH
    call bga_write_register

    ; 5. Set Virtual Height (1536 = 2 * 768) for double-buffering
    mov cx, VBE_DISPI_INDEX_VIRT_H
    mov ax, (GUI_SCREEN_HEIGHT * 2)
    call bga_write_register

    ; 6. Set X and Y Offsets to 0 (Page 0 initially visible)
    mov cx, VBE_DISPI_INDEX_X_OFF
    xor ax, ax
    call bga_write_register

    mov cx, VBE_DISPI_INDEX_Y_OFF
    xor ax, ax
    call bga_write_register

    ; 7. Set Bits Per Pixel (32bpp)
    mov cx, VBE_DISPI_INDEX_BPP
    mov ax, GUI_SCREEN_BPP
    call bga_write_register

    ; 8. Enable BGA with Linear Framebuffer (0x41 = ENABLED | LFB_ENABLED)
    mov cx, VBE_DISPI_INDEX_ENABLE
    mov ax, VBE_DISPI_ENABLED | VBE_DISPI_LFB_ENABLED
    call bga_write_register

    mov byte [bga_front_page], 0
    mov rax, [bga_base_lfb]
    mov [bga_lfb_ptr], rax
    mov byte [bga_active], 1
    xor rax, rax
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; bga_prepare_backbuffer: Points bga_lfb_ptr to the hidden backbuffer page
; ------------------------------------------------------------------------------
bga_prepare_backbuffer:
    push rax
    mov rax, [bga_base_lfb]
    cmp byte [bga_front_page], 0
    jne .use_p0
    ; Front page is 0, so backbuffer is Page 1 (offset 0x300000 = 3,145,728)
    add rax, (GUI_SCREEN_WIDTH * GUI_SCREEN_HEIGHT * 4)
.use_p0:
    mov [bga_lfb_ptr], rax
    pop rax
    ret

; ------------------------------------------------------------------------------
; bga_flip_page: Flips display hardware register to the page that was just drawn,
; and updates bga_lfb_ptr to point to this newly visible front page.
; ------------------------------------------------------------------------------
bga_flip_page:
    push rax
    push rcx
    push rdx

    cmp byte [bga_front_page], 0
    jne .flip_to_0

    ; Page 0 was visible -> flip to Page 1
    mov cx, VBE_DISPI_INDEX_Y_OFF
    mov ax, GUI_SCREEN_HEIGHT   ; 768
    call bga_write_register
    mov byte [bga_front_page], 1

    ; Visible page is now Page 1:
    mov rax, [bga_base_lfb]
    add rax, (GUI_SCREEN_WIDTH * GUI_SCREEN_HEIGHT * 4)
    mov [bga_lfb_ptr], rax
    jmp .flip_done

.flip_to_0:
    ; Page 1 was visible -> flip to Page 0
    mov cx, VBE_DISPI_INDEX_Y_OFF
    xor ax, ax                  ; 0
    call bga_write_register
    mov byte [bga_front_page], 0

    ; Visible page is now Page 0:
    mov rax, [bga_base_lfb]
    mov [bga_lfb_ptr], rax

.flip_done:
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; bga_set_text_mode: Restores standard 80x25 VGA color text mode (Mode 03h)
; ------------------------------------------------------------------------------
bga_set_text_mode:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; 1. Disable BGA extensions
    mov cx, VBE_DISPI_INDEX_ENABLE
    mov ax, VBE_DISPI_DISABLED
    call bga_write_register

    ; 2. Restore VGA Miscellaneous Output Register (0x3C2 = 0x67)
    ; Sets 28.322 MHz clock, 400 lines, color CRTC at 0x3D4/0x3D5
    mov dx, 0x03C2
    mov al, 0x67
    out dx, al

    ; 3. Restore Sequencer Registers (Index 0x00 .. 0x04)
    mov dx, 0x03C4
    xor ecx, ecx
.seq_loop:
    mov al, cl
    mov ah, [vga_m3_seq + rcx]
    out dx, ax                  ; Write index to 0x3C4 and data to 0x3C5
    inc ecx
    cmp ecx, 5
    jl .seq_loop

    ; 4. Unlock CRTC registers (clear protect bit 7 on Index 0x11)
    mov dx, 0x03D4
    mov al, 0x11
    out dx, al
    inc dx
    in al, dx
    and al, 0x7F
    out dx, al
    dec dx

    ; Write CRTC Registers (Index 0x00 .. 0x18)
    xor ecx, ecx
.crtc_loop:
    mov al, cl
    mov ah, [vga_m3_crtc + rcx]
    out dx, ax                  ; Write index to 0x3D4 and data to 0x3D5
    inc ecx
    cmp ecx, 25
    jl .crtc_loop

    ; 5. Restore Graphics Controller Registers (Index 0x00 .. 0x08)
    mov dx, 0x03CE
    xor ecx, ecx
.gc_loop:
    mov al, cl
    mov ah, [vga_m3_gc + rcx]
    out dx, ax                  ; Write index to 0x3CE and data to 0x3CF
    inc ecx
    cmp ecx, 9
    jl .gc_loop

    ; 6. Restore Attribute Controller Registers (Index 0x00 .. 0x14)
    ; Read 0x3DA to reset AC flip-flop to index state
    mov dx, 0x03DA
    in al, dx

    mov dx, 0x03C0
    xor ecx, ecx
.ac_loop:
    mov al, cl
    out dx, al                  ; Write Index
    mov al, [vga_m3_ac + rcx]
    out dx, al                  ; Write Data
    inc ecx
    cmp ecx, 21
    jl .ac_loop

    ; Enable Video output on Attribute Controller (Bit 5 = 1)
    mov al, 0x20
    out dx, al

    ; 7. Upload 8x8 Bitmap Font into VGA Plane 2 at 0xA0000
    call vga_load_plane2_font

    mov byte [bga_active], 0

    ; Redraw VGA text screen
    call vga_clear_screen

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; vga_load_plane2_font: Loads 8x8 bitmap font into VGA Plane 2 at 0xA0000
; ------------------------------------------------------------------------------
vga_load_plane2_font:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; 1. Set Sequencer to write to Plane 2
    mov dx, 0x03C4
    mov ax, 0x0402              ; Index 02h (Map Mask) = 0x04 (Plane 2)
    out dx, ax
    mov ax, 0x0604              ; Index 04h (Memory Mode) = 0x06 (Sequential)
    out dx, ax

    ; 2. Set Graphics Controller to map 0xA0000 - 0xAFFFF
    mov dx, 0x03CE
    mov ax, 0x0005              ; Index 05h (Mode) = 0x00 (Write mode 0)
    out dx, ax
    mov ax, 0x0006              ; Index 06h (Misc) = 0x00 (Map 0xA0000 - 0xAFFFF)
    out dx, ax

    ; 3. Clear all 256 font glyph slots at 0xA0000 (256 * 32 = 8192 bytes)
    mov rdi, 0x00000000000A0000
    xor eax, eax
    mov ecx, 2048
    rep stosd

    ; 4. Copy font_8x8_data (95 glyphs for ASCII 32 .. 126)
    xor ebx, ebx                ; Glyph index 0 .. 94
.glyph_loop:
    lea rsi, [font_8x8_data + rbx * 8]
    mov eax, ebx
    add eax, 32                 ; ASCII code
    shl eax, 5                  ; * 32 bytes per font slot
    mov rdi, 0x00000000000A0000
    add rdi, rax

    ; Copy 8 bytes of glyph to character slot
    mov ecx, 8
.copy_row:
    movsb
    loop .copy_row

    inc ebx
    cmp ebx, 95
    jl .glyph_loop

    ; 5. Restore Sequencer to text mode (Planes 0 and 1, Odd/Even)
    mov dx, 0x03C4
    mov ax, 0x0302              ; Index 02h = 0x03 (Planes 0 & 1)
    out dx, ax
    mov ax, 0x0204              ; Index 04h = 0x02 (Odd/Even)
    out dx, ax

    ; 6. Restore Graphics Controller to 0xB8000
    mov dx, 0x03CE
    mov ax, 0x1005              ; Index 05h = 0x10 (Odd/Even)
    out dx, ax
    mov ax, 0x0E06              ; Index 06h = 0x0E (Map 0xB8000 - 0xBFFFF)
    out dx, ax

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Standard VGA Mode 3 (80x25 Color Text Mode) Hardware Register Tables
vga_m3_seq:
    db 0x03, 0x00, 0x03, 0x00, 0x02

vga_m3_crtc:
    db 0x5F, 0x4F, 0x50, 0x82, 0x55, 0x81, 0xBF, 0x1F
    db 0x00, 0x4F, 0x0D, 0x0E, 0x00, 0x00, 0x00, 0x00
    db 0x9C, 0x8E, 0x8F, 0x28, 0x1F, 0x96, 0xB9, 0xA3, 0xFF

vga_m3_gc:
    db 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0E, 0x00, 0xFF

vga_m3_ac:
    db 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07
    db 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F
    db 0x0C, 0x00, 0x0F, 0x08, 0x00
