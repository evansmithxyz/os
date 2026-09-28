; ==============================================================================
; Antigravity OS - Physical Memory Map
; ------------------------------------------------------------------------------
; Single source of truth for fixed physical addresses. The whole first 4 GB is
; identity-mapped with 2 MB pages, so every address here is also its virtual
; address. Included by boot/stage1.asm, boot/stage2.asm and the kernel.
;
;   0x00000500  BOOTINFO        boot info block written by stage 2
;   0x00000600  E820_MAP        BIOS memory map (up to E820_MAX entries)
;   0x00001000  page tables     PML4, PDPT, 4 x PD (identity map 0-4 GB)
;   0x00007C00  stage 1         MBR (BIOS loads it here)
;   0x00007E00  stage 2         loader
;   0x00010000  kernel image    up to KERNEL_MAX_SECTORS * 512 = 512 KB
;   0x000A0000  VGA memory / BIOS (hands off)
;   0x00100000  kernel .bss     zeroed by kernel_entry, up to 1 MB
;   0x00200000  kernel stack    grows down from KERNEL_STACK_TOP (1 MB)
;   0x00300000  NIC DMA         RTL8139 RX ring + TX buffers
;   0x00400000  HTTP response   the last HTTP(S) response (1 MB)
;   0x00500000  browser page    the page the browser shows (1 MB)
;   0x01000000  GUI buffers     back buffer, wallpaper cache, canvas
; ==============================================================================

; --- Boot handoff -------------------------------------------------------------
BOOTINFO_ADDR           equ 0x00000500
BOOTINFO_MAGIC          equ 0x4F464E49  ; "INFO"
BI_MAGIC                equ 0           ; dd BOOTINFO_MAGIC
BI_BOOT_DRIVE           equ 4           ; db BIOS drive number
BI_E820_COUNT           equ 6           ; dw number of E820 entries
BI_KERNEL_SECTORS       equ 8           ; dw kernel sectors loaded

E820_MAP_ADDR           equ 0x00000600
E820_ENTRY_SIZE         equ 24
E820_MAX                equ 64          ; 64 * 24 = 1536 bytes (0x600 - 0xBFF)

; --- Paging -------------------------------------------------------------------
PML4_ADDR               equ 0x00001000
PDPT_ADDR               equ 0x00002000
PD_ADDR                 equ 0x00003000  ; 4 consecutive page directories

; --- Code ---------------------------------------------------------------------
STAGE1_ADDR             equ 0x00007C00
STAGE2_ADDR             equ 0x00007E00
KERNEL_ADDR             equ 0x00010000

; --- Kernel RAM ---------------------------------------------------------------
KERNEL_BSS_ADDR         equ 0x00100000
KERNEL_BSS_MAX          equ 0x00100000  ; 1 MB
KERNEL_STACK_TOP        equ 0x00300000  ; stack occupies 0x200000 - 0x2FFFFF

; --- Device buffers -----------------------------------------------------------
NIC_RX_RING_ADDR        equ 0x00300000  ; 8 KB + 16 + 1500 (WRAP mode overflow)
NIC_TX_BUF_ADDR         equ 0x00304000  ; 4 x 2 KB transmit buffers

; --- Web ----------------------------------------------------------------------
; Too big for .bss; use them as [abs HTTP_RESP_ADDR]
HTTP_RESP_ADDR          equ 0x00400000  ; response of the last GET (headers + body)
HTTP_RESP_SIZE          equ 0x00100000
BROWSER_PAGE_ADDR       equ 0x00500000  ; the browser's current page (HTML or text)
BROWSER_PAGE_SIZE       equ 0x00100000

; --- GUI (each 1024 x 768 x 4 bytes = 3 MB) -----------------------------------
GUI_BACKBUFFER_ADDR     equ 0x01000000  ; everything is composed here, then copied to the LFB
GUI_WALLPAPER_ADDR      equ 0x01400000  ; pre-rendered desktop gradient
GUI_CANVAS_ADDR         equ 0x01800000  ; Cyber Canvas drawing surface (persists)
GUI_MIN_RAM             equ 0x02000000  ; GUI refuses to start below 32 MB RAM
