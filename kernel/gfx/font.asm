; ==============================================================================
; Antigravity OS - 8x16 bitmap font (ASCII 32 - 126, 95 characters)
; ------------------------------------------------------------------------------
; The glyphs are drawn as ASCII art in gfx/font.txt; tools/build.py converts
; them to build/font.inc:
;   font_data   16 bytes per glyph, one per row, bit 7 = leftmost pixel
;   font_prop   2 bytes per glyph: first inked column, proportional advance
; Monospace text (terminal, web pages) steps FONT_W pixels per character;
; proportional UI text (gfx_print_ui) uses font_prop.
; ==============================================================================

[bits 64]

FONT_W                  equ 8
FONT_H                  equ 16
FONT_FIRST_CHAR         equ 32
FONT_GLYPHS             equ 95      ; ASCII 32 - 126

section .rodata
align 16
%include "font.inc"
