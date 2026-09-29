; ==============================================================================
; Antigravity OS - GUI Terminal window
; ------------------------------------------------------------------------------
; A real terminal for the shell: while the desktop runs, console output
; (con_putc) lands here via term_putc, and key presses in this window go to
; shell_key - the same shell as the text console, so every command works.
;
; The text lives in a grid of TERM_ROWS lines x TERM_COLS cells (character +
; VGA colour attribute). Lines wrap at the window's current width; the newest
; lines are shown at the bottom of the window.
; ==============================================================================

[bits 64]

TERM_COLS               equ 128
TERM_ROWS               equ 200     ; scrollback
TERM_LINE_H             equ 16
TERM_PAD_X              equ 14
TERM_PAD_Y              equ 10
TERM_DEFAULT_COLS       equ 110

section .data
term_row:               dd 0        ; cursor line in the grid
term_col:               dd 0
term_wrap_cols:         dd TERM_DEFAULT_COLS    ; updated from the window width

section .bss
alignb 16
term_chars:             resb TERM_ROWS * TERM_COLS
term_attrs:             resb TERM_ROWS * TERM_COLS

section .rodata
term_title:             db "Terminal", 0
term_label:             db "Terminal", 0
term_welcome:           db "Antigravity OS terminal. Every shell command works here - try 'help', 'ls' or 'ping 10.0.2.2'.", 0x0A
                        db "Keys: F1-F4 switch workspace, Up/Down history, Tab completes, Esc returns to the text console.", 0x0A, 0x0A, 0

; VGA text attribute (low nibble) -> RGB, soft colours for the dark background
align 4
term_palette:
    dd 0x00565F77, THEME_ACCENT, THEME_GREEN, THEME_CYAN    ; black->slate, blue, green, cyan
    dd THEME_RED, THEME_MAGENTA, THEME_YELLOW, THEME_TEXT_SOFT  ; red, magenta, brown, light gray
    dd 0x006B7390, 0x009CB8FA, 0x00B9E08A, 0x00A4DDFF       ; dark gray, light blue, light green, light cyan
    dd 0x00FF95A8, 0x00CDB2FA, 0x00F2CA8A, THEME_TEXT       ; light red, light magenta, yellow, white

section .text
; ------------------------------------------------------------------------------
; term_reset: clear the terminal and show the welcome text and a prompt
; ------------------------------------------------------------------------------
term_reset:
    push rbx
    push rsi
    call term_clear
    mov bl, COLOR_LIGHT_GRAY
    lea rsi, [term_welcome]
    call con_puts_color
    call shell_print_prompt
    pop rsi
    pop rbx
    ret

; term_clear
term_clear:
    push rax
    push rcx
    push rdi
    lea rdi, [term_chars]
    xor eax, eax
    mov ecx, TERM_ROWS * TERM_COLS
    rep stosb
    mov dword [term_row], 0
    mov dword [term_col], 0
    mov byte [gui_dirty], 1
    pop rdi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; term_putc: AL = character, BL = VGA attribute. Handles \n, \r and \b.
; ------------------------------------------------------------------------------
term_putc:
    push rax
    push rcx
    push rdx
    mov byte [gui_dirty], 1
    cmp al, 0x0A
    je .newline
    cmp al, 0x0D
    je .cr
    cmp al, 0x08
    je .backspace
    cmp al, 32
    jb .done
    call .cell_offset               ; RCX = offset of the cursor cell
    lea rdx, [term_chars]
    mov [rdx + rcx], al
    lea rdx, [term_attrs]
    mov [rdx + rcx], bl
    inc dword [term_col]
    mov eax, [term_col]
    cmp eax, [term_wrap_cols]
    jb .done
.newline:
    mov dword [term_col], 0
    inc dword [term_row]
    cmp dword [term_row], TERM_ROWS
    jb .done
    call term_scroll
    jmp .done
.cr:
    mov dword [term_col], 0
    jmp .done
.backspace:
    cmp dword [term_col], 0
    je .done
    dec dword [term_col]
    call .cell_offset
    lea rdx, [term_chars]
    mov byte [rdx + rcx], 0
.done:
    pop rdx
    pop rcx
    pop rax
    ret
.cell_offset:
    mov ecx, [term_row]
    imul ecx, TERM_COLS
    add ecx, [term_col]
    ret

; term_scroll: drop the oldest line
term_scroll:
    push rax
    push rcx
    push rsi
    push rdi
    lea rdi, [term_chars]
    lea rsi, [rdi + TERM_COLS]
    mov ecx, (TERM_ROWS - 1) * TERM_COLS
    rep movsb
    xor eax, eax
    mov ecx, TERM_COLS
    rep stosb
    lea rdi, [term_attrs]
    lea rsi, [rdi + TERM_COLS]
    mov ecx, (TERM_ROWS - 1) * TERM_COLS
    rep movsb
    mov dword [term_row], TERM_ROWS - 1
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------------------------
; term_draw: WIN_DRAW callback (ECX,EDX = client x,y  ESI,R8D = client w,h)
; ------------------------------------------------------------------------------
term_draw:
    mov r12d, ecx                   ; client origin
    mov r13d, edx
    mov eax, THEME_TERM_BG
    call gfx_fill_rect

    ; Wrap future output at the current width
    lea eax, [esi - 2 * TERM_PAD_X]
    shr eax, 3
    cmp eax, 20
    jge .min_ok
    mov eax, 20
.min_ok:
    cmp eax, TERM_COLS
    jle .max_ok
    mov eax, TERM_COLS
.max_ok:
    mov [term_wrap_cols], eax
    mov r15d, eax                   ; visible columns

    ; Visible rows, newest at the bottom
    lea eax, [r8d - 2 * TERM_PAD_Y]
    xor edx, edx
    mov ecx, TERM_LINE_H
    div ecx
    test eax, eax
    jz .done
    mov r14d, eax                   ; visible rows
    mov eax, [term_row]
    inc eax
    sub eax, r14d
    jns .first_ok
    xor eax, eax
.first_ok:
    mov r11d, eax                   ; first grid row to draw
    xor r10d, r10d                  ; screen row
.row_loop:
    mov eax, r11d
    add eax, r10d
    cmp eax, [term_row]
    ja .cursor
    imul eax, TERM_COLS
    mov r9d, eax                    ; grid offset of the line
    xor edi, edi                    ; column
.col_loop:
    cmp edi, r15d
    jae .next_row
    lea eax, [r9d + edi]
    lea rbx, [term_chars]
    mov al, [rbx + rax]
    test al, al
    jz .next_col
    lea ebx, [r9d + edi]
    lea rcx, [term_attrs]
    movzx ebx, byte [rcx + rbx]
    and ebx, 0x0F
    lea rcx, [term_palette]
    mov esi, [rcx + rbx * 4]        ; foreground
    lea ecx, [edi * 8]
    add ecx, r12d
    add ecx, TERM_PAD_X
    mov edx, r10d
    imul edx, TERM_LINE_H
    add edx, r13d
    add edx, TERM_PAD_Y
    mov r8d, -1
    call gfx_draw_char
.next_col:
    inc edi
    jmp .col_loop
.next_row:
    inc r10d
    cmp r10d, r14d
    jb .row_loop

.cursor:
    ; Block cursor (bright when this window has focus)
    mov eax, [term_row]
    sub eax, r11d
    cmp eax, r14d
    jae .done
    imul eax, TERM_LINE_H
    lea edx, [eax + r13d + TERM_PAD_Y]
    mov ecx, [term_col]
    shl ecx, 3
    add ecx, r12d
    add ecx, TERM_PAD_X
    add edx, 2                      ; over the glyph rows that have ink
    mov esi, FONT_W
    mov r8d, FONT_H - 3
    mov eax, THEME_TEXT_FAINT
    cmp byte [wm_focus], WIN_TERM
    jne .draw_cursor
    mov eax, THEME_ACCENT
.draw_cursor:
    call gfx_fill_rect
.done:
    ret

; ------------------------------------------------------------------------------
; term_key: WIN_KEY callback. Everything the shell understands goes to it.
; ------------------------------------------------------------------------------
term_key:
    test al, al
    jnz .shell
    cmp ah, SC_UP                   ; history
    je .shell
    cmp ah, SC_DOWN
    je .shell
    clc                             ; other special keys: not ours
    ret
.shell:
    call shell_key
    stc
    ret
