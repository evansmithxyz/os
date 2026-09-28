; ==============================================================================
; Antigravity OS - Disk Layout
; ------------------------------------------------------------------------------
; Single source of truth for where everything lives on the disk image.
; Included by boot/stage1.asm, boot/stage2.asm and the kernel, and parsed by
; tools/mkimage.py (simple "NAME equ <expr>" lines only - keep it that way).
; All values are LBA sector numbers (512-byte sectors) unless noted.
; ==============================================================================

SECTOR_SIZE             equ 512

; --- Boot ---------------------------------------------------------------------
STAGE1_LBA              equ 0           ; MBR boot sector
STAGE2_LBA              equ 1           ; Stage 2 loader (real mode -> long mode)
STAGE2_SECTORS          equ 31          ; 15.5 KB reserved for stage 2

; --- Kernel -------------------------------------------------------------------
KERNEL_LBA              equ 32
KERNEL_MAX_SECTORS      equ 1024        ; 512 KB kernel slot (loaded at KERNEL_ADDR)

; --- AntigravityFS (AFS1) -----------------------------------------------------
FS_SUPERBLOCK_LBA       equ 1056        ; KERNEL_LBA + KERNEL_MAX_SECTORS
FS_INODE_LBA            equ 1057        ; 2 sectors: 32 inodes x 32 bytes
FS_INODE_SECTORS        equ 2
FS_DATA_LBA             equ 1059        ; First data sector

; --- Whole image --------------------------------------------------------------
DISK_SECTORS            equ 4096        ; 2 MB disk image
