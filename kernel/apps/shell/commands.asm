; ==============================================================================
; Antigravity OS - Shell Command Table
; ------------------------------------------------------------------------------
; To add a command:
;   1. write a handler (any cmd_*.asm file). It is called with RSI = the
;      argument string (leading spaces skipped, NUL-terminated) and may clobber
;      every register except RSP.
;   2. add one COMMAND line below. That is all: `help`, Tab completion and
;      dispatch pick it up automatically.
;
;   COMMAND "name", handler, flags, "help text shown by `help`"
;   ALIAS   "name", handler, flags                 (not listed in `help`)
;   HEADING "Title"                                (section title in `help`)
;
; Flags: CMDF_FILEARG (Tab completes file names), CMDF_DESKTOP (only inside the
; GUI terminal), CMDF_HIDDEN (not listed, not completed). See shell.asm.
;
; Register convention: handlers AND the cmd_* helper routines in cmd_*.asm may
; clobber any register except RSP (shell_execute saves everything). Only call
; cmd_* helpers from handlers.
; ==============================================================================

[bits 64]

%macro COMMAND 4
    [section .rodata]
    %%name: db %1, 0
    %%help: db %4, 0
    [section .cmdtab]
    dq %%name, %2, %%help, %3
    __SECT__
%endmacro

%macro ALIAS 3
    [section .rodata]
    %%name: db %1, 0
    [section .cmdtab]
    dq %%name, %2, shell_empty_help, %3
    __SECT__
%endmacro

%macro HEADING 1
    [section .rodata]
    %%name: db %1, 0
    [section .cmdtab]
    dq %%name, 0, shell_empty_help, CMDF_HEADING
    __SECT__
%endmacro

section .rodata
shell_empty_help:       db 0

section .cmdtab
align 8
shell_commands:

HEADING "Files (AntigravityFS)"
COMMAND "ls",        cmd_ls,        0,            "ls                  List files on the disk"
ALIAS   "dir",       cmd_ls,        0
COMMAND "cat",       cmd_cat,       CMDF_FILEARG, "cat <file>          Show a file"
COMMAND "touch",     cmd_touch,     CMDF_FILEARG, "touch <file>        Create an empty file"
COMMAND "write",     cmd_write,     CMDF_FILEARG, "write <file> <text> Write text into a file (created if needed)"
COMMAND "rm",        cmd_rm,        CMDF_FILEARG, "rm <file>           Delete a file"
COMMAND "df",        cmd_df,        0,            "df                  Disk usage"

HEADING "Network (RTL8139, TCP/IP)"
COMMAND "ifconfig",  cmd_ifconfig,  0,            "ifconfig            NIC, addresses and packet counters"
ALIAS   "net",       cmd_ifconfig,  0
COMMAND "arp",       cmd_arp,       0,            "arp                 ARP cache"
COMMAND "ping",      cmd_ping,      0,            "ping <host>         ICMP echo (IP address or domain name)"
COMMAND "dns",       cmd_dns,       0,            "dns <domain>        Resolve a name with DNS"
ALIAS   "nslookup",  cmd_dns,       0
COMMAND "curl",      cmd_curl,      0,            "curl <url> [port]   HTTP(S) GET, e.g. curl https://example.com/"
ALIAS   "http",      cmd_curl,      0
COMMAND "tcplisten", cmd_tcplisten, 0,            "tcplisten [port]    Serve a web page (host: http://localhost:8888)"

HEADING "System"
COMMAND "help",      cmd_help,      0,            "help                This list"
COMMAND "clear",     cmd_clear,     0,            "clear               Clear the screen"
COMMAND "echo",      cmd_echo,      0,            "echo <text>         Print text"
COMMAND "sysinfo",   cmd_sysinfo,   0,            "sysinfo             Live system summary"
COMMAND "about",     cmd_about,     0,            "about               About Antigravity OS"
COMMAND "cpu",       cmd_cpu,       0,            "cpu                 CPUID vendor, brand and signature"
COMMAND "mem",       cmd_mem,       0,            "mem                 Memory map (E820) and kernel layout"
COMMAND "regs",      cmd_regs,      0,            "regs                Register snapshot"
COMMAND "uptime",    cmd_uptime,    0,            "uptime              Time since boot"
ALIAS   "ticks",     cmd_uptime,    0
COMMAND "reboot",    cmd_reboot,    0,            "reboot              Restart the machine"
COMMAND "halt",      cmd_halt,      0,            "halt                Stop the CPU"
COMMAND "cryptotest", cmd_cryptotest, 0,           "cryptotest          Run the TLS crypto self-test (hex output)"
ALIAS   "crash",     cmd_crash,     CMDF_HIDDEN   ; crash [ud|gp|pf|de] - tests the panic handler

HEADING "Desktop"
COMMAND "gui",       cmd_gui,       0,            "gui                 Start the desktop (Esc returns here)"
ALIAS   "desktop",   cmd_gui,       0
COMMAND "browser",   cmd_browser,   0,            "browser [url]       Open the CyberSurf web browser"
ALIAS   "web",       cmd_browser,   0
COMMAND "ws",        cmd_ws,        CMDF_DESKTOP, "ws [n | move n]     Show/switch workspace, or move this window"
ALIAS   "workspace", cmd_ws,        CMDF_DESKTOP
COMMAND "exit",      cmd_exit,      CMDF_DESKTOP, "exit                Close the terminal window"

shell_commands_end:

section .text
%include "apps/shell/cmd_fs.asm"
%include "apps/shell/cmd_net.asm"
%include "apps/shell/cmd_sys.asm"
%include "apps/shell/cmd_desktop.asm"
%include "apps/shell/cmd_crypto.asm"
