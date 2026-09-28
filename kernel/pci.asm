; ==============================================================================
; Antigravity OS - 64-bit PCI Bus Scanner & Configuration Manager
; Reads and writes PCI Configuration Space via I/O Ports 0xCF8 / 0xCFC
; ==============================================================================

[bits 64]

PCI_CONFIG_ADDR equ 0x0CF8
PCI_CONFIG_DATA equ 0x0CFC

; ------------------------------------------------------------------------------
; pci_read_dword: Reads a 32-bit dword from PCI configuration space
; Input:  EAX = bus (0-255), EBX = slot/device (0-31), ECX = func (0-7), EDX = offset (0-255)
; Output: EAX = 32-bit register value
; ------------------------------------------------------------------------------
pci_read_dword:
    push rdx
    push rbx
    push rcx

    ; Format: bit 31=1, bits 23-16=bus, bits 15-11=device, bits 10-8=func, bits 7-2=offset
    and eax, 0xFF
    shl eax, 16

    and ebx, 0x1F
    shl ebx, 11
    or eax, ebx

    and ecx, 0x07
    shl ecx, 8
    or eax, ecx

    and edx, 0xFC
    or eax, edx

    or eax, 0x80000000          ; Enable configuration bit

    ; Write address to 0xCF8
    mov dx, PCI_CONFIG_ADDR
    out dx, eax

    ; Read dword from 0xCFC
    mov dx, PCI_CONFIG_DATA
    in eax, dx

    pop rcx
    pop rbx
    pop rdx
    ret

; ------------------------------------------------------------------------------
; pci_write_dword: Writes a 32-bit dword to PCI configuration space
; Input:  EAX = bus, EBX = slot, ECX = func, EDX = offset, R8D = value to write
; ------------------------------------------------------------------------------
pci_write_dword:
    push rax
    push rbx
    push rcx
    push rdx

    and eax, 0xFF
    shl eax, 16

    and ebx, 0x1F
    shl ebx, 11
    or eax, ebx

    and ecx, 0x07
    shl ecx, 8
    or eax, ecx

    and edx, 0xFC
    or eax, edx
    or eax, 0x80000000

    mov dx, PCI_CONFIG_ADDR
    out dx, eax

    mov eax, r8d
    mov dx, PCI_CONFIG_DATA
    out dx, eax

    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; pci_find_device: Scans PCI bus for matching VendorID and DeviceID
; Input:  SI = VendorID (16-bit), DI = DeviceID (16-bit)
; Output: ZF=1 if found, with:
;         EAX = bus, EBX = slot, ECX = func
;         ZF=0 if not found
; ------------------------------------------------------------------------------
pci_find_device:
    push r8
    push r9
    push r10
    push r11

    mov r8w, si                 ; R8W = Target VendorID
    mov r9w, di                 ; R9W = Target DeviceID

    xor r10d, r10d              ; R10D = bus (0 .. 7)
.bus_loop:
    xor r11d, r11d              ; R11D = slot (0 .. 31)
.slot_loop:
    xor ecx, ecx                ; ECX = func (0 .. 7)
.func_loop:
    mov eax, r10d               ; bus
    mov ebx, r11d               ; slot
    xor edx, edx                ; offset 0x00 (Vendor & Device ID)
    call pci_read_dword

    cmp ax, 0xFFFF              ; Vendor 0xFFFF = No device present
    je .next_slot               ; If func 0 is missing, skip remaining funcs for this slot

    ; Check if VendorID and DeviceID match
    cmp ax, r8w
    jne .check_next_func
    shr eax, 16
    cmp ax, r9w
    jne .check_next_func

    ; MATCH FOUND!
    mov eax, r10d               ; Return bus
    mov ebx, r11d               ; Return slot
    ; ECX already holds func
    pop r11
    pop r10
    pop r9
    pop r8
    cmp eax, eax                ; Set ZF=1
    ret

.check_next_func:
    inc ecx
    cmp ecx, 8
    jl .func_loop

.next_slot:
    inc r11d
    cmp r11d, 32
    jl .slot_loop

    inc r10d
    cmp r10d, 8
    jl .bus_loop

    ; Not found
    pop r11
    pop r10
    pop r9
    pop r8
    test esp, esp               ; Set ZF=0
    ret

; ------------------------------------------------------------------------------
; pci_enable_bus_master: Enables Bus Mastering and I/O Space on a PCI device
; Input:  EAX = bus, EBX = slot, ECX = func
; ------------------------------------------------------------------------------
pci_enable_bus_master:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11

    mov r9d, eax                ; R9D = bus
    mov r10d, ebx               ; R10D = slot
    mov r11d, ecx               ; R11D = func

    ; Read current Command register (offset 0x04)
    mov eax, r9d
    mov ebx, r10d
    mov ecx, r11d
    mov edx, 0x04
    call pci_read_dword

    ; Set bit 0 (I/O Space), bit 1 (Memory Space), bit 2 (Bus Master Enable) = 0x0007
    or eax, 0x0007
    mov r8d, eax                ; R8D = value to write

    ; Write back to Command register (offset 0x04)
    mov eax, r9d                ; EAX = bus
    mov ebx, r10d               ; EBX = slot
    mov ecx, r11d               ; ECX = func
    mov edx, 0x04               ; EDX = offset
    call pci_write_dword

    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; pci_get_bar0_io: Reads BAR0 and returns base I/O port address
; Input:  EAX = bus, EBX = slot, ECX = func
; Output: RAX = Base I/O port (16-bit port number, e.g. 0xC000)
; ------------------------------------------------------------------------------
pci_get_bar0_io:
    push rbx
    push rcx
    push rdx

    mov edx, 0x10               ; BAR0 offset
    call pci_read_dword
    and eax, 0xFFFFFFFC         ; Mask off lowest 2 bits (I/O indicator)

    pop rdx
    pop rcx
    pop rbx
    ret
