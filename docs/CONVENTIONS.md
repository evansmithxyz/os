# Code conventions

These are the rules the kernel follows. Keep them when adding code; the test
suite and the reviewers (human or not) assume them.

## Registers

- **Normal routines preserve every general-purpose register** except the ones
  documented as outputs (usually `RAX`). Save what you touch with `push`/`pop`.
  Flags are *not* preserved.
- **Status comes back in `CF`** when a routine can fail or "has/has not"
  something: `key_get`, `serial_getc`, `url_parse`, `net_resolve_host`,
  `bga_enable` and others. Set it with `stc`/`clc` as the last flag-changing
  instruction; `pop` is fine after it, `add`/`cmp`/`test` are not.
  Older routines that return 0/1 in `RAX` say so in their header.
- **Two exceptions may clobber anything but `RSP`**, because their callers
  save everything:
  - shell command handlers and the `cmd_*` helpers in `kernel/apps/shell/cmd_*.asm`
    (called from `shell_execute`)
  - window callbacks: `WIN_DRAW`, `WIN_KEY`, `WIN_MOUSE`, `WIN_OPEN`,
    `WIN_TICK` (called through the `wm_call_*` trampolines in `gui/wm.asm`)
- Every routine starts with a comment block saying what it does, its inputs
  and its outputs.
- **XMM registers and the x87 stack are scratch** everywhere: nothing keeps
  a value in them across a call, and interrupt handlers never touch them
  (`fpu_init` turns them on; the JavaScript engine uses them for doubles).
- **JavaScript** (`kernel/js/`) has seven more rules:
  - opcode handlers in `vm.asm` keep the interpreter's registers (RSI = pc,
    R12 = value stack, R13 = frame base, R14 = environment, R15 = function,
    RBP = opcode table) and store R12 in `vm_sp` before calling anything
    that can run JavaScript (`VMCALL`);
  - native functions take RDI = arguments, ECX = count, RDX = `this`,
    R8D = 1 under `new`, R10 = the function object itself (a bound
    function finds its target there) and return the result in RAX,
    preserving everything else. Errors call `js_throw`, which does not
    return;
  - heap blocks come from `js_alloc` and are never freed by hand: the
    collector (`gc.asm`) frees what nothing points to. Keep heap pointers
    in registers, on the stacks, in `.bss` qwords, in heap blocks or in the
    DOM node fields it scans; a pointer kept anywhere else (a dword, another
    memory region) does not keep its block alive. Mark blocks that hold no
    pointers `GCF_LEAF`, and allocate what must live forever with
    `js_alloc_perm`;
  - host code that runs JavaScript (a script, an event handler) calls
    `jsev_drain` afterwards, so promise jobs run before anything else
    happens; work that waits (a network request) goes on the event loop as
    a task (`jsev_add_timer`) instead of inside the native that asked for
    it (a synchronous XMLHttpRequest is the exception, as in browsers);
  - a property key is an atom or a symbol (both are permanent heap blocks,
    compared as pointers): check `JH_KIND` for `JK_SYMBOL` before treating
    a key as a string;
  - the parser decides which variables closures capture from the names
    each function uses: new syntax that reads or writes a variable by name
    calls `jsp_note_use` for it. A missed name stops the compiler with
    "internal: 'x' is used by an inner function but was not captured";
  - library code that needs nothing native is JavaScript: `prelude.js`
    (every realm) or `dom.js` (pages). The build strips their comment lines
    and indentation, so only whole-line `//` comments, and no multi-line
    strings or template literals. Natives meant only for them start with
    `__` and are deleted from the global object once the prelude has them.

## Sections and memory

`kernel/kernel.asm` defines four sections; every file switches between them:

| Section   | Use for                                   | In the image? |
|-----------|-------------------------------------------|---------------|
| `.text`   | code                                      | yes           |
| `.rodata` | strings, tables, fonts                    | yes           |
| `.cmdtab` | the shell command table only              | yes           |
| `.data`   | variables with a non-zero initial value   | yes           |
| `.bss`    | anything that starts as zero (`resb`)     | **no**, zeroed at boot |

- **Never write `times N db 0` for a buffer**: put it in `.bss` with
  `resb N`. That is what freed the kernel slot in the first place.
- Fixed physical addresses (DMA rings, GUI buffers, stack, page tables) are
  defined only in `include/memmap.inc`. Disk sector numbers only in
  `include/layout.inc`. Nothing else hardcodes an address or an LBA.
- `default rel` is on. Absolute addresses in memory operands need `abs`,
  e.g. `[abs BOOTINFO_ADDR + BI_E820_COUNT]`.
- Everything below 4 GB is identity mapped, so physical = virtual.

## Output and input

- Print with the console layer (`con_puts`, `con_puts_color`, `con_dec`,
  `con_hex64`, `con_ip`, ...), never directly to VGA memory. The console
  mirrors to the serial port and routes to the GUI terminal while the
  desktop runs, so the same command works in both places.
- Colours in console output are VGA attributes (`COLOR_*`); GUI colours are
  `THEME_*` in `kernel/gui/theme.inc`.
- `klog`, `klog2`, `klog_dec` write debug lines to the serial port only
  (`[klog] ...`). Tests wait for them, so log anything a test might check.
- Input arrives as key events (`AL` = ASCII or 0, `AH` = scancode) from
  `key_get`. Interrupt handlers only decode and queue; they never print.
- Long-running work must call `net_wait_step` or `con_idle` inside its loop
  so the desktop keeps redrawing, and `con_check_cancel` if the user should be
  able to stop it.
- Timeouts use `TICKS(ms)` (the PIT runs at 1000 Hz).

## Naming

Routines are prefixed with their module: `con_`, `key_`, `serial_`, `vga_`,
`kbd_`, `mouse_`, `ata_`, `pci_`, `net_`/`rtl_`, `bga_`, `fs_`, `eth_`/`arp_`,
`ipv4_`/`icmp_`, `udp_`/`dns_`, `tcp_`/`http_`, `url_`, `tls_`, `x509_`/`der_`,
`sha256_`/`sha512_`/`hmac_`/`hash_`, `chacha20_`/`poly1305_`/`aead_`,
`fe_`/`x25519_`, `bn_`/`mont_`, `rsa_`/`sig_`, `ec_`/`ecdsa_`, `rand_`, `rtc_`,
`dom_`, `css_`, `lay_`/`layout_`/`paint_`,
`js_` (engine API and runtime helpers), `jsnum_`/`jsbig_` (numbers),
`jsstr_` (strings, atoms), `jsobj_`/`jsarr_`/`jsfn_` (objects), `jslex_`,
`jsp_` (parser), `jsc_` (compiler), `vm_`/`vmop_` (interpreter), `jsb_`
(built-ins), `jsi_`/`jsout_` (printing values), `jsd_` (the DOM in
JavaScript),
`gfx_`, `wm_`, `gui_`,
`desktop_`, `term_`, `canvas_`, `sysmon_`, `browser_`, `shell_`, `cmd_`,
`fmt_`, and plain names (`strlen`, `memcpy`) for `lib/string.asm`. Local
labels use NASM's `.name` form.

## Adding things

- **A shell command:** write a handler in the right `kernel/apps/shell/cmd_*.asm`
  and add one `COMMAND` line to `kernel/apps/shell/commands.asm`. Help and Tab
  completion pick it up automatically.
- **A window/app:** add a `WINDOW` line to `wm_windows` in `kernel/gui/wm.asm`
  and a `WIN_*` id, write the callbacks in `kernel/apps/`, add an app pill in
  `kernel/gui/desktop.asm` if it should have one.
- **A file on the default disk:** drop it in `rootfs/` and build with `--fresh`.
- **More kernel space:** raise `KERNEL_MAX_SECTORS` in `include/layout.inc`
  and move the `FS_*` numbers (and `DISK_SECTORS`) up by the same amount.
  The kernel is loaded at 1 MB and its slot ends at `KERNEL_BSS_ADDR`, so
  past 1 MB also move `.bss`, the stack and what follows up in
  `include/memmap.inc` (the build stops with an error if they overlap).

## Tests

Every user-visible feature gets a test in `tests/` (see `tests/harness.py`).
Prefer asserting on serial output or `[klog]` lines; use screenshots and
pixel checks only for things that can't be seen any other way.
