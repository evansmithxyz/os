; ==============================================================================
; Antigravity OS - AntigravityFS (AFS1)
; ------------------------------------------------------------------------------
; On-disk format (sector numbers come from include/layout.inc; tools/mkimage.py
; writes the same format when it builds an image):
;
;   Superblock @ FS_SUPERBLOCK_LBA
;     +0  "AFS1"   +4 total sectors   +8 inode LBA   +12 data LBA   +16 max inodes
;   Inode table @ FS_INODE_LBA, FS_MAX_INODES entries of FS_INODE_SIZE bytes:
;     +0  name (15 chars + NUL)
;     +16 size in bytes (dd)
;     +20 first data sector (dw)
;     +22 sector count (dw)      each file is one contiguous run of sectors
;     +24 flags (db)             FS_FLAG_ALLOC = in use
;
; The inode table is cached in RAM (fs_inode_table) and written back by fs_sync.
; ==============================================================================

[bits 64]

FS_MAX_INODES           equ 32
FS_INODE_SIZE           equ 32
FS_NAME_MAX             equ 15
FS_MAGIC                equ 0x31534641  ; "AFS1"
FS_TOTAL_SECTORS        equ DISK_SECTORS
FS_FLAG_ALLOC           equ 0x01

INODE_NAME              equ 0
INODE_SIZE              equ 16
INODE_LBA               equ 20
INODE_SECTORS           equ 22
INODE_FLAGS             equ 24

section .data
fs_mounted:             db 0

section .bss
alignb 16
fs_inode_table:         resb FS_MAX_INODES * FS_INODE_SIZE
fs_sector_buf:          resb SECTOR_SIZE

section .text
; ------------------------------------------------------------------------------
; fs_init: mount the volume, formatting it if the superblock is missing
; ------------------------------------------------------------------------------
fs_init:
    push rax
    push rbx
    push rsi
    push rdi

    mov rax, FS_SUPERBLOCK_LBA
    lea rdi, [fs_sector_buf]
    call ata_read_sector
    test rax, rax
    jnz .io_error
    cmp dword [fs_sector_buf], FS_MAGIC
    je .load
    call fs_format
.load:
    call fs_load_inodes
    test rax, rax
    jnz .io_error
    mov byte [fs_mounted], 1
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [msg_fs_mounted]
    call con_puts_color
    jmp .done
.io_error:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [msg_fs_io]
    call con_puts_color
.done:
    pop rdi
    pop rsi
    pop rbx
    pop rax
    ret

; fs_load_inodes: read the inode table into RAM -> RAX = 0 ok / 1 error
fs_load_inodes:
    push rdi
    mov rax, FS_INODE_LBA
    lea rdi, [fs_inode_table]
    call ata_read_sector
    test rax, rax
    jnz .done
    mov rax, FS_INODE_LBA + 1
    lea rdi, [fs_inode_table + SECTOR_SIZE]
    call ata_read_sector
.done:
    pop rdi
    ret

; ------------------------------------------------------------------------------
; fs_format: write a fresh superblock and an empty inode table
; ------------------------------------------------------------------------------
fs_format:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi

    mov bl, COLOR_YELLOW
    lea rsi, [msg_fs_format]
    call con_puts_color

    lea rdi, [fs_sector_buf]
    xor eax, eax
    mov ecx, SECTOR_SIZE
    rep stosb
    mov dword [fs_sector_buf + 0], FS_MAGIC
    mov dword [fs_sector_buf + 4], FS_TOTAL_SECTORS
    mov dword [fs_sector_buf + 8], FS_INODE_LBA
    mov dword [fs_sector_buf + 12], FS_DATA_LBA
    mov dword [fs_sector_buf + 16], FS_MAX_INODES
    mov rax, FS_SUPERBLOCK_LBA
    lea rsi, [fs_sector_buf]
    call ata_write_sector

    lea rdi, [fs_inode_table]
    xor eax, eax
    mov ecx, FS_MAX_INODES * FS_INODE_SIZE
    rep stosb
    call fs_sync

    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; fs_sync: write the cached inode table back to disk
; ------------------------------------------------------------------------------
fs_sync:
    push rax
    push rsi
    mov rax, FS_INODE_LBA
    lea rsi, [fs_inode_table]
    call ata_write_sector
    mov rax, FS_INODE_LBA + 1
    lea rsi, [fs_inode_table + SECTOR_SIZE]
    call ata_write_sector
    pop rsi
    pop rax
    ret

; ------------------------------------------------------------------------------
; fs_inode_ptr: RCX = inode index -> RAX = pointer to the cached inode
; ------------------------------------------------------------------------------
fs_inode_ptr:
    mov rax, rcx
    shl rax, 5                      ; * FS_INODE_SIZE
    push rbx
    lea rbx, [fs_inode_table]
    add rax, rbx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; fs_find_file: RSI = file name -> RAX = inode pointer, or 0 if not found
; ------------------------------------------------------------------------------
fs_find_file:
    push rcx
    push rdi
    xor ecx, ecx
.loop:
    call fs_inode_ptr
    test byte [rax + INODE_FLAGS], FS_FLAG_ALLOC
    jz .next
    mov rdi, rax
    call strcmp
    je .found
.next:
    inc ecx
    cmp ecx, FS_MAX_INODES
    jb .loop
    xor eax, eax
.found:
    pop rdi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; fs_read_file: RAX = inode, RDI = buffer, RCX = buffer size
;   -> RAX = bytes copied (file size clamped to RCX), 0 on I/O error
; ------------------------------------------------------------------------------
fs_read_file:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8

    mov rbx, rax
    mov r8d, [rbx + INODE_SIZE]     ; bytes remaining
    cmp r8, rcx
    jbe .size_ok
    mov r8, rcx
.size_ok:
    mov rdx, r8                     ; result
    movzx eax, word [rbx + INODE_LBA]
.sector_loop:
    test r8, r8
    jz .done
    push rax
    push rdi
    lea rdi, [fs_sector_buf]
    call ata_read_sector
    pop rdi
    test rax, rax
    pop rax
    jnz .error
    mov ecx, SECTOR_SIZE
    cmp r8, rcx
    jae .copy
    mov rcx, r8
.copy:
    sub r8, rcx
    lea rsi, [fs_sector_buf]
    rep movsb
    inc rax
    jmp .sector_loop
.error:
    xor edx, edx
.done:
    mov rax, rdx
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; fs_alloc_data_block: -> RAX = first free data sector, or 0 if the disk is full
; ------------------------------------------------------------------------------
fs_alloc_data_block:
    push rbx
    push rcx
    push r8
    push r9
    mov rbx, FS_DATA_LBA
.check_sector:
    xor ecx, ecx
.inode_loop:
    call fs_inode_ptr
    test byte [rax + INODE_FLAGS], FS_FLAG_ALLOC
    jz .next_inode
    movzx r8d, word [rax + INODE_LBA]
    movzx r9d, word [rax + INODE_SECTORS]
    add r9d, r8d
    cmp rbx, r8
    jb .next_inode
    cmp rbx, r9
    jb .in_use
.next_inode:
    inc ecx
    cmp ecx, FS_MAX_INODES
    jb .inode_loop
    mov rax, rbx                    ; free
    jmp .done
.in_use:
    inc rbx
    cmp rbx, FS_TOTAL_SECTORS
    jb .check_sector
    xor eax, eax
.done:
    pop r9
    pop r8
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; fs_create_file: RSI = file name -> RAX = inode pointer (existing file is
; returned as is), or 0 if the name is invalid or the table/disk is full
; ------------------------------------------------------------------------------
fs_create_file:
    push rbx
    push rcx
    push rsi
    push rdi

    call strlen
    test rax, rax
    jz .fail
    cmp rax, FS_NAME_MAX
    ja .fail

    call fs_find_file
    test rax, rax
    jnz .done

    xor ecx, ecx
.find_slot:
    call fs_inode_ptr
    test byte [rax + INODE_FLAGS], FS_FLAG_ALLOC
    jz .have_slot
    inc ecx
    cmp ecx, FS_MAX_INODES
    jb .find_slot
    jmp .fail
.have_slot:
    mov rbx, rax
    call fs_alloc_data_block
    test rax, rax
    jz .fail

    mov rdi, rbx                    ; clear the inode, then fill it in
    push rax
    xor eax, eax
    mov ecx, FS_INODE_SIZE
    rep stosb
    pop rax
    mov rdi, rbx
    mov ecx, FS_NAME_MAX + 1
    call strlcpy
    mov dword [rbx + INODE_SIZE], 0
    mov [rbx + INODE_LBA], ax
    mov word [rbx + INODE_SECTORS], 1
    mov byte [rbx + INODE_FLAGS], FS_FLAG_ALLOC

    lea rdi, [fs_sector_buf]        ; zero the data sector on disk
    push rax
    xor eax, eax
    mov ecx, SECTOR_SIZE
    rep stosb
    pop rax
    lea rsi, [fs_sector_buf]
    call ata_write_sector
    call fs_sync
    mov rax, rbx
    jmp .done
.fail:
    xor eax, eax
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; fs_write_content: RSI = file name, RDX = data, RCX = length (clamped to one
; sector) -> RAX = 0 ok / 1 error. Creates the file if needed.
; ------------------------------------------------------------------------------
fs_write_content:
    push rbx
    push rcx
    push rsi
    push rdi

    cmp rcx, SECTOR_SIZE
    jbe .len_ok
    mov ecx, SECTOR_SIZE
.len_ok:
    call fs_create_file
    test rax, rax
    jz .error
    mov rbx, rax

    lea rdi, [fs_sector_buf]
    push rcx
    xor eax, eax
    mov ecx, SECTOR_SIZE
    rep stosb
    pop rcx
    lea rdi, [fs_sector_buf]
    mov rsi, rdx
    push rcx
    rep movsb
    pop rcx

    movzx eax, word [rbx + INODE_LBA]
    lea rsi, [fs_sector_buf]
    call ata_write_sector
    test rax, rax
    jnz .error
    mov [rbx + INODE_SIZE], ecx
    call fs_sync
    xor eax, eax
    jmp .done
.error:
    mov eax, 1
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; fs_delete_file: RSI = file name -> RAX = 0 ok / 1 not found
; ------------------------------------------------------------------------------
fs_delete_file:
    push rcx
    push rdi
    call fs_find_file
    test rax, rax
    jz .not_found
    mov rdi, rax
    xor eax, eax
    mov ecx, FS_INODE_SIZE
    rep stosb
    call fs_sync
    xor eax, eax
    jmp .done
.not_found:
    mov eax, 1
.done:
    pop rdi
    pop rcx
    ret

; ------------------------------------------------------------------------------
; fs_stats: -> RAX = files in use, RDX = data sectors in use
; ------------------------------------------------------------------------------
fs_stats:
    push rbx
    push rcx
    xor ebx, ebx
    xor edx, edx
    xor ecx, ecx
.loop:
    call fs_inode_ptr
    test byte [rax + INODE_FLAGS], FS_FLAG_ALLOC
    jz .next
    inc ebx
    push rax
    movzx eax, word [rax + INODE_SECTORS]
    add rdx, rax
    pop rax
.next:
    inc ecx
    cmp ecx, FS_MAX_INODES
    jb .loop
    mov rax, rbx
    pop rcx
    pop rbx
    ret

section .rodata
msg_fs_mounted:     db "[FS] AntigravityFS mounted.", 0x0A, 0
msg_fs_format:      db "[FS] No AFS volume found - formatting...", 0x0A, 0
msg_fs_io:          db "[FS] Disk I/O error while mounting AFS!", 0x0A, 0
