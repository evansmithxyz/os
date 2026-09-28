; ==============================================================================
; Antigravity OS - Bochs Graphics Adaptor (BGA / QEMU "std" VGA)
; ------------------------------------------------------------------------------
; Switches the card into a GFX_WIDTH x GFX_HEIGHT x 32bpp linear framebuffer.
; The GUI never draws into the framebuffer directly: it composes frames in RAM
; (GUI_BACKBUFFER_ADDR) and copies them over (gfx/gfx.asm, gfx_present).
; ==============================================================================

[bits 64]

BGA_INDEX_PORT          equ 0x01CE
BGA_DATA_PORT           equ 0x01CF
VBE_DISPI_INDEX_ID      equ 0x0
VBE_DISPI_INDEX_XRES    equ 0x1
VBE_DISPI_INDEX_YRES    equ 0x2
VBE_DISPI_INDEX_BPP     equ 0x3
VBE_DISPI_INDEX_ENABLE  equ 0x4
VBE_DISPI_INDEX_VIRT_W  equ 0x6
VBE_DISPI_INDEX_VIRT_H  equ 0x7
VBE_DISPI_INDEX_X_OFF   equ 0x8
VBE_DISPI_INDEX_Y_OFF   equ 0x9
VBE_DISPI_DISABLED      equ 0x00
VBE_DISPI_ENABLED       equ 0x01
VBE_DISPI_LFB_ENABLED   equ 0x40
BGA_ID_MIN              equ 0xB0C0

GFX_WIDTH               equ 1024
GFX_HEIGHT              equ 768
GFX_BPP                 equ 32
GFX_PITCH               equ GFX_WIDTH * 4
GFX_FRAME_BYTES         equ GFX_WIDTH * GFX_HEIGHT * 4

section .data
bga_available:          db 0        ; card found and responds
bga_active:             db 0        ; 1 while the framebuffer mode is on
align 8
bga_lfb:                dq 0xFD000000   ; overwritten from PCI BAR0

section .text
; ------------------------------------------------------------------------------
; bga_write: CX = register index, AX = value
; bga_read:  CX = register index -> AX
; ------------------------------------------------------------------------------
bga_write:
    push rdx
    push rax
    mov dx, BGA_INDEX_PORT
    mov ax, cx
    out dx, ax
    mov dx, BGA_DATA_PORT
    pop rax
    out dx, ax
    pop rdx
    ret

bga_read:
    push rdx
    mov dx, BGA_INDEX_PORT
    mov ax, cx
    out dx, ax
    mov dx, BGA_DATA_PORT
    in ax, dx
    pop rdx
    ret

; ------------------------------------------------------------------------------
; bga_init: detect the adaptor and find the framebuffer address
; ------------------------------------------------------------------------------
bga_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov cx, VBE_DISPI_INDEX_ID
    call bga_read
    cmp ax, BGA_ID_MIN
    jb .done                        ; not a Bochs/QEMU adaptor

    mov si, 0x1234                  ; QEMU/Bochs std VGA
    mov di, 0x1111
    call pci_find_device
    jnz .use_default
    call pci_enable_bus_master
    mov edx, 0x10                   ; BAR0 = framebuffer
    call pci_read_dword
    and eax, 0xFFFFFFF0
    jz .use_default
    mov [bga_lfb], rax
.use_default:
    mov byte [bga_available], 1
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; bga_enable: switch to GFX_WIDTH x GFX_HEIGHT x 32bpp -> CF=1 if unavailable
; ------------------------------------------------------------------------------
bga_enable:
    cmp byte [bga_available], 1
    jne .fail
    push rax
    push rcx
    mov cx, VBE_DISPI_INDEX_ENABLE
    mov ax, VBE_DISPI_DISABLED
    call bga_write
    mov cx, VBE_DISPI_INDEX_XRES
    mov ax, GFX_WIDTH
    call bga_write
    mov cx, VBE_DISPI_INDEX_YRES
    mov ax, GFX_HEIGHT
    call bga_write
    mov cx, VBE_DISPI_INDEX_VIRT_W
    mov ax, GFX_WIDTH
    call bga_write
    mov cx, VBE_DISPI_INDEX_VIRT_H
    mov ax, GFX_HEIGHT
    call bga_write
    mov cx, VBE_DISPI_INDEX_X_OFF
    xor ax, ax
    call bga_write
    mov cx, VBE_DISPI_INDEX_Y_OFF
    xor ax, ax
    call bga_write
    mov cx, VBE_DISPI_INDEX_BPP
    mov ax, GFX_BPP
    call bga_write
    mov cx, VBE_DISPI_INDEX_ENABLE
    mov ax, VBE_DISPI_ENABLED | VBE_DISPI_LFB_ENABLED
    call bga_write
    mov byte [bga_active], 1
    pop rcx
    pop rax
    clc
    ret
.fail:
    stc
    ret

; ------------------------------------------------------------------------------
; bga_disable: turn the framebuffer mode off (vga_restore_text_mode calls this)
; ------------------------------------------------------------------------------
bga_disable:
    push rax
    push rcx
    mov cx, VBE_DISPI_INDEX_ENABLE
    mov ax, VBE_DISPI_DISABLED
    call bga_write
    mov byte [bga_active], 0
    pop rcx
    pop rax
    ret
