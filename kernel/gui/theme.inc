; ==============================================================================
; Antigravity OS - Desktop colour theme (0x00RRGGBB)
; ------------------------------------------------------------------------------
; The one place to change GUI colours. Text-console colours are VGA attributes
; (COLOR_* in drivers/vga_text.asm); term_palette in apps/terminal.asm maps
; those to RGB for the GUI terminal.
; ==============================================================================

; Surfaces
THEME_DESK_TOP          equ 0x000F172A  ; wallpaper gradient
THEME_DESK_BOTTOM       equ 0x00020617
THEME_PANEL             equ 0x001E293B  ; taskbar, inactive title bars, buttons
THEME_PANEL_DARK        equ 0x000F172A  ; empty pills, window bodies
THEME_FOOTER            equ 0x000B1120
THEME_BORDER            equ 0x00334155
THEME_BORDER_MUTED      equ 0x00475569
THEME_TITLE_ACTIVE      equ 0x0024344D
THEME_SHADOW            equ 0x00050811
THEME_WIN_BODY          equ 0x000F172A
THEME_TERM_BG           equ 0x000A0E17
THEME_CANVAS_BG         equ 0x000D1117
THEME_CANVAS_BORDER     equ 0x001F2937
THEME_BADGE_BG          equ 0x00131D2E

; Accents
THEME_ACCENT            equ 0x000284C7  ; active workspace, focused border
THEME_CYAN              equ 0x0000F0FF
THEME_SKY               equ 0x0038BDF8
THEME_GREEN             equ 0x0010B981
THEME_GREEN_LIGHT       equ 0x0034D399
THEME_GREEN_DARK        equ 0x00064E3B
THEME_GREEN_MID         equ 0x00047857
THEME_GREEN_PALE        equ 0x00A7F3D0
THEME_YELLOW            equ 0x00F59E0B
THEME_RED               equ 0x00EF4444
THEME_RED_DARK          equ 0x007F1D1D
THEME_NAVY              equ 0x001E3A8A
THEME_SKY_PALE          equ 0x00BAE6FD
THEME_MAGENTA           equ 0x00EC4899
THEME_BLUE              equ 0x003B82F6

; Text
THEME_TEXT              equ 0x00FFFFFF
THEME_TEXT_SOFT         equ 0x00E2E8F0
THEME_TEXT_BODY         equ 0x00CBD5E1
THEME_TEXT_MUTED        equ 0x0094A3B8
