; ==============================================================================
; Antigravity OS - Desktop colour theme (0x00RRGGBB)
; ------------------------------------------------------------------------------
; The one place to change GUI colours. Text-console colours are VGA attributes
; (COLOR_* in drivers/vga_text.asm); term_palette in apps/terminal.asm maps
; those to RGB for the GUI terminal. Alphas run 0 (invisible) to 256 (solid).
; ==============================================================================

; Wallpaper: a night-sky gradient lit by three soft glows
THEME_WALL_TOP          equ 0x000A0E1F
THEME_WALL_BOTTOM       equ 0x0014102A
THEME_GLOW_1            equ 0x006D5DF6  ; violet, lower left
THEME_GLOW_2            equ 0x0012A4C8  ; teal, upper right
THEME_GLOW_3            equ 0x00D9468F  ; rose, lower right

; Top bar and dock: translucent glass over the wallpaper
THEME_BAR               equ 0x00080B14
THEME_BAR_ALPHA         equ 170
THEME_DOCK              equ 0x00111624
THEME_DOCK_ALPHA        equ 190
THEME_DOCK_EDGE         equ 0x00343D55
THEME_HOVER             equ 0x00FFFFFF  ; blended in lightly for selected items
THEME_HOVER_ALPHA       equ 28

; Windows
THEME_WIN_BODY          equ 0x00141925
THEME_TITLE             equ 0x001C2231  ; focused title bar
THEME_TITLE_IDLE        equ 0x00171C29
THEME_WIN_EDGE          equ 0x002B3345
THEME_WIN_EDGE_FOCUS    equ 0x00475681
THEME_SEPARATOR         equ 0x00252C3C
THEME_SHADOW            equ 0x00000000
THEME_SHADOW_ALPHA      equ 150         ; focused window (idle ones get less)
THEME_LIGHT_RED         equ 0x00FF5F57  ; close / minimize / maximize
THEME_LIGHT_YELLOW      equ 0x00FEBC2E
THEME_LIGHT_GREEN       equ 0x0028C840
THEME_LIGHT_IDLE        equ 0x00394155

; Controls inside windows
THEME_SURFACE           equ 0x001D2334  ; buttons, cards
THEME_SURFACE_HI        equ 0x00283048
THEME_FIELD             equ 0x000E121B  ; text fields, page backgrounds
THEME_TERM_BG           equ 0x00111520
THEME_CANVAS_BG         equ 0x000E121B

; Accents
THEME_ACCENT            equ 0x007AA2F7  ; focus, selection, links
THEME_ACCENT_DIM        equ 0x00334A7D
THEME_CYAN              equ 0x007DCFFF
THEME_TEAL              equ 0x0073DACA
THEME_GREEN             equ 0x009ECE6A
THEME_YELLOW            equ 0x00E0AF68
THEME_ORANGE            equ 0x00FF9E64
THEME_RED               equ 0x00F7768E
THEME_MAGENTA           equ 0x00BB9AF7
THEME_BLUE              equ 0x003D8BFD

; Text
THEME_TEXT              equ 0x00E6E9F2
THEME_TEXT_SOFT         equ 0x00C0C6D6
THEME_TEXT_MUTED        equ 0x007D869C
THEME_TEXT_FAINT        equ 0x0050586C

; Mouse pointer
THEME_CURSOR            equ 0x00FFFFFF
THEME_CURSOR_EDGE       equ 0x000A0D16
