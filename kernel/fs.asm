; ==============================================================================
; Antigravity OS - 64-Bit AntigravityFS (AFS) Storage Subsystem
; Superblock, Inode Table, and Persistent File Management via ATA PIO
; ==============================================================================

[bits 64]

; Disk Layout Constants
FS_SUPERBLOCK_LBA   equ 129     ; LBA sector for AFS Superblock
FS_INODE_LBA        equ 130     ; Starting LBA for Inode Table (2 sectors = 130, 131)
FS_DATA_LBA         equ 132     ; Starting LBA for Data Blocks
FS_TOTAL_SECTORS    equ 512     ; Disk size in sectors (256 KB)
FS_MAX_INODES       equ 32      ; Maximum files supported
FS_INODE_SIZE       equ 32      ; 32 bytes per inode (32 * 32 = 1024 bytes)

FS_MAGIC            equ 0x31534641 ; "AFS1" in little-endian ASCII

; Inode Flags
FS_FLAG_ALLOC       equ 0x01    ; Entry is in-use
FS_FLAG_RO          equ 0x02    ; Read-only file

; In-Memory Data Buffers
fs_mounted:         db 0
align 16
fs_inode_table:     times 1024 db 0     ; Cached 32 inodes in RAM
align 16
fs_sector_buf:      times 512 db 0      ; Scratch sector buffer

; Messages
MSG_FS_MOUNTED:     db "[FS] AntigravityFS mounted successfully (LBA 129-511).", 0x0A, 0
MSG_FS_FORMAT:      db "[FS] Formatting new AntigravityFS volume on disk...", 0x0A, 0
MSG_FS_READY:       db "[FS] Volume format complete.", 0x0A, 0
MSG_FS_ERR:         db "[FS] Hard drive I/O failure!", 0x0A, 0

; ------------------------------------------------------------------------------
; fs_init: Mounts AFS filesystem or formats disk if magic is absent
; ------------------------------------------------------------------------------
fs_init:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; Read Superblock at LBA 33
    mov rax, FS_SUPERBLOCK_LBA
    lea rdi, [fs_sector_buf]
    call ata_read_sector
    test rax, rax
    jnz .io_error

    ; Validate Superblock Magic ("AFS1")
    cmp dword [fs_sector_buf], FS_MAGIC
    je .load_inodes

    ; Volume not formatted -> Format new filesystem
    call fs_format

.load_inodes:
    ; Read Inode Table (Sectors 34 and 35) into RAM cache
    mov rax, FS_INODE_LBA
    lea rdi, [fs_inode_table]
    call ata_read_sector
    test rax, rax
    jnz .io_error

    mov rax, FS_INODE_LBA + 1
    lea rdi, [fs_inode_table + 512]
    call ata_read_sector
    test rax, rax
    jnz .io_error

    mov byte [fs_mounted], 1
    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [MSG_FS_MOUNTED]
    call vga_print_string_color
    jmp .done

.io_error:
    mov bl, COLOR_LIGHT_RED
    lea rsi, [MSG_FS_ERR]
    call vga_print_string_color

.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------------------------
; fs_format: Initializes Superblock and zeroed Inode Table on disk
; ------------------------------------------------------------------------------
fs_format:
    push rax
    push rcx
    push rdi
    push rsi

    mov bl, COLOR_YELLOW
    lea rsi, [MSG_FS_FORMAT]
    call vga_print_string_color

    ; Zero out sector buffer
    lea rdi, [fs_sector_buf]
    xor eax, eax
    mov rcx, 128
    rep stosd

    ; Construct Superblock
    mov dword [fs_sector_buf], FS_MAGIC         ; Magic "AFS1"
    mov dword [fs_sector_buf + 4], FS_TOTAL_SECTORS
    mov dword [fs_sector_buf + 8], FS_INODE_LBA
    mov dword [fs_sector_buf + 12], FS_DATA_LBA
    mov dword [fs_sector_buf + 16], FS_MAX_INODES

    ; Write Superblock to LBA 33
    mov rax, FS_SUPERBLOCK_LBA
    lea rsi, [fs_sector_buf]
    call ata_write_sector

    ; Clear Inode Table cache in RAM
    lea rdi, [fs_inode_table]
    xor eax, eax
    mov rcx, 256
    rep stosd

    ; Write empty Inode Table to Sectors 34 & 35
    mov rax, FS_INODE_LBA
    lea rsi, [fs_inode_table]
    call ata_write_sector

    mov rax, FS_INODE_LBA + 1
    lea rsi, [fs_inode_table + 512]
    call ata_write_sector

    mov bl, COLOR_LIGHT_GREEN
    lea rsi, [MSG_FS_READY]
    call vga_print_string_color

    pop rsi
    pop rdi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; fs_sync: Commits in-memory Inode Table to physical disk
; ------------------------------------------------------------------------------
fs_sync:
    push rax
    push rsi

    mov rax, FS_INODE_LBA
    lea rsi, [fs_inode_table]
    call ata_write_sector

    mov rax, FS_INODE_LBA + 1
    lea rsi, [fs_inode_table + 512]
    call ata_write_sector

    pop rsi
    pop rax
    ret

; ------------------------------------------------------------------------------
; fs_find_file: Looks up file by name in Inode Table
; Input:  RSI = Pointer to null-terminated filename string
; Output: RAX = Pointer to Inode (32 bytes) or 0 if not found
; ------------------------------------------------------------------------------
fs_find_file:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rdx, rsi                ; RDX = search name
    xor rbx, rbx                ; RBX = inode index (0 .. 31)

.scan_loop:
    mov rax, rbx
    shl rax, 5                  ; Multiply index by 32 bytes
    lea rax, [fs_inode_table + rax]
    test byte [rax + 24], FS_FLAG_ALLOC
    jz .next

    ; Compare filename (null-terminated)
    mov rsi, rdx
    mov rdi, rax
    call strcmp
    jz .found

.next:
    inc rbx
    cmp rbx, FS_MAX_INODES
    jl .scan_loop

    xor rax, rax                ; Not found
    jmp .done

.found:
    mov rax, rbx
    shl rax, 5
    lea rax, [fs_inode_table + rax]

.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; fs_alloc_data_block: Finds an unused LBA data block on disk
; Returns: RAX = Available LBA sector (or 0 if disk full)
; ------------------------------------------------------------------------------
fs_alloc_data_block:
    push rbx
    push rcx
    push r8
    push r9

    ; Search from FS_DATA_LBA to FS_TOTAL_SECTORS - 1
    mov rax, FS_DATA_LBA

.check_sector:
    ; Check if any active inode uses this sector
    xor rbx, rbx
.inode_check:
    mov rcx, rbx
    shl rcx, 5
    lea rcx, [fs_inode_table + rcx]
    test byte [rcx + 24], FS_FLAG_ALLOC
    jz .next_inode

    ; If sector is within [start_lba, start_lba + sector_count - 1]
    movzx r8d, word [rcx + 20]  ; start_lba
    movzx r9d, word [rcx + 22]  ; sector_count
    add r9d, r8d                ; r9d = end_lba

    cmp eax, r8d
    jb .next_inode
    cmp eax, r9d
    jb .sector_in_use           ; Sector is taken!

.next_inode:
    inc rbx
    cmp rbx, FS_MAX_INODES
    jl .inode_check

    ; Found a free sector!
    jmp .done

.sector_in_use:
    inc rax
    cmp rax, FS_TOTAL_SECTORS
    jl .check_sector

    xor rax, rax                ; Disk full

.done:
    pop r9
    pop r8
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; fs_create_file: Allocates new inode and sector for a file
; Input:  RSI = Pointer to null-terminated filename
; Returns: RAX = Pointer to created Inode or 0 on failure
; ------------------------------------------------------------------------------
fs_create_file:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    mov rdx, rsi                ; RDX = filename

    ; First check if file already exists
    call fs_find_file
    test rax, rax
    jnz .already_exists

    ; Find free inode slot
    xor rbx, rbx
.find_free_slot:
    mov rax, rbx
    shl rax, 5
    lea rax, [fs_inode_table + rax]
    test byte [rax + 24], FS_FLAG_ALLOC
    jz .found_slot
    inc rbx
    cmp rbx, FS_MAX_INODES
    jl .find_free_slot

    xor rax, rax                ; Table full
    jmp .done

.found_slot:
    mov rdi, rax                ; RDI = target inode

    ; Clear inode entry (32 bytes)
    push rdi
    xor eax, eax
    mov rcx, 8
    rep stosd
    pop rdi

    ; Copy filename (up to 15 chars + null)
    push rdi
    mov rsi, rdx
    mov rcx, 15
.copy_name:
    lodsb
    stosb
    test al, al
    jz .pad_zeros
    loop .copy_name
.pad_zeros:
    xor al, al
    stosb
    pop rdi

    ; Allocate initial data sector
    call fs_alloc_data_block
    test rax, rax
    jz .fail_no_space

    ; Fill inode fields
    mov dword [rdi + 16], 0      ; Size = 0 bytes
    mov word [rdi + 20], ax      ; Start LBA
    mov word [rdi + 22], 1       ; 1 sector allocated
    mov byte [rdi + 24], FS_FLAG_ALLOC ; Active flag

    ; Zero out the physical sector on disk
    push rdi
    push rax
    lea rdi, [fs_sector_buf]
    xor eax, eax
    mov rcx, 128
    rep stosd
    pop rax
    lea rsi, [fs_sector_buf]
    call ata_write_sector
    pop rdi

    ; Sync inode table to disk
    call fs_sync

    mov rax, rdi                ; Return inode pointer
    jmp .done

.already_exists:
    ; RAX already has existing inode pointer
    jmp .done

.fail_no_space:
    xor rax, rax

.done:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; fs_write_content: Writes string content into a file
; Input:
;   RSI = Filename
;   RDX = Pointer to text data
;   RCX = Length in bytes (max 512 for single sector)
; Returns: RAX = 0 on success, 1 on failure
; ------------------------------------------------------------------------------
fs_write_content:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13

    mov r12, rdx                ; R12 = data pointer
    mov r13, rcx                ; R13 = byte count

    ; Ensure file exists or create it
    call fs_create_file
    test rax, rax
    jz .error

    mov rbx, rax                ; RBX = inode pointer

    ; Prepare sector buffer with zero padding
    lea rdi, [fs_sector_buf]
    xor eax, eax
    mov rcx, 128
    rep stosd

    ; Copy data into sector buffer
    lea rdi, [fs_sector_buf]
    mov rsi, r12
    mov rcx, r13
    cmp rcx, 512
    jbe .do_copy
    mov rcx, 512                ; Clamp to 512 bytes
.do_copy:
    rep movsb

    ; Write sector to disk
    movzx rax, word [rbx + 20]  ; LBA sector from inode
    lea rsi, [fs_sector_buf]
    call ata_write_sector
    test rax, rax
    jnz .error

    ; Update file size in inode
    mov dword [rbx + 16], r13d
    call fs_sync

    xor rax, rax                ; Success
    jmp .done

.error:
    mov rax, 1

.done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; fs_delete_file: Removes a file entry and marks its inode inactive
; Input: RSI = Filename to delete
; Returns: RAX = 0 on success, 1 if not found
; ------------------------------------------------------------------------------
fs_delete_file:
    push rbx
    push rcx
    push rdi

    call fs_find_file
    test rax, rax
    jz .not_found

    ; Clear inode flags and name
    mov rdi, rax
    xor eax, eax
    mov rcx, 8
    rep stosd

    call fs_sync
    xor rax, rax
    jmp .done

.not_found:
    mov rax, 1

.done:
    pop rdi
    pop rcx
    pop rbx
    ret
