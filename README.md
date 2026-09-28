# Antigravity OS — 64-Bit Long Mode Bootloader, Kernel, Filesystem & Bare-Metal TCP/IP Stack

A pure x86_64 NASM assembly operating system demonstrating the complete bare-metal journey: from 16-bit Real Mode MBR, to 32-bit Protected Mode, to 64-bit Long Mode with 4-level paging, hardware ATA PIO disk drivers, an on-disk filesystem (**AntigravityFS - AFS1**), and a complete **RFC-compliant TCP/IP network stack** with Realtek RTL8139 PCI Fast Ethernet drivers, DNS resolver, HTTP client (`curl`), and bare-metal web server (`tcplisten 80`).

Zero C libraries. Zero runtime dependencies. 100% written in pure x86_64 assembly.

---

## Architecture & Boot Progression

```
+--------------------------------------------------------------------------+
| 1. BIOS POST & Boot Sector Detection                                    |
|    - BIOS loads Sector 1 (512 bytes) from boot drive into RAM at 0x7C00  |
|    - DL register holds the BIOS boot drive identifier                     |
+--------------------------------------------------------------------------+
                                    |
                                    v
+--------------------------------------------------------------------------+
| 2. MBR Bootloader (boot/bootloader.asm) [16-bit Real Mode]              |
|    - Sets canonical segments and stack at 0x7C00                         |
|    - Reads 128 sectors of Kernel (64 KB) from disk into RAM at 0x8000    |
|    - Activates A20 address line via Fast A20 / BIOS INT 0x15             |
|    - Loads unified GDT (32-bit & 64-bit selectors)                       |
|    - Sets CR0.PE = 1 to enter 32-bit Protected Mode                      |
|    - Far jumps to 0x08:pm_entry (pipeline flush)                         |
+--------------------------------------------------------------------------+
                                    |
                                    v
+--------------------------------------------------------------------------+
| 3. Long Mode Switch (boot/bootloader.asm) [32-bit Protected Mode]        |
|    - Validates 64-bit Long Mode capability via CPUID 0x80000001 (bit 29) |
|    - Builds 4-Level Identity Paging tables (PML4, PDPT, Page Directory)   |
|      mapping 0 - 8 MB using four 2 MB huge pages                         |
|    - Loads CR3 with PML4 root address (0x00001000)                       |
|    - Enables Physical Address Extension (PAE) in CR4 (bit 5)             |
|    - Sets Long Mode Enable (LME) bit in EFER MSR (0xC0000080, bit 8)     |
|    - Sets Paging Enable (PG) in CR0 (bit 31)                             |
|    - Far jumps to 0x18:long_mode_entry (64-bit Code Segment)             |
+--------------------------------------------------------------------------+
                                    |
                                    v
+--------------------------------------------------------------------------+
| 4. 64-bit Kernel (kernel/kernel.asm) [64-bit Long Mode]                  |
|    - Sets 64-bit Data Selectors (0x20) and 64-bit Stack Pointer (RSP)    |
|    - Initializes 64-bit VGA 80x25 text driver at 0x000B8000              |
|    - Remaps 8259 PIC (IRQ 0-7 -> 0x20-0x27, IRQ 8-15 -> 0x28-0x2F)      |
|    - Populates 256-entry 64-bit IDT (16-byte gates) & executes LIDT      |
|    - Enables interrupts with STI (IRQ0 Timer, IRQ1 PS/2 Keyboard)        |
|    - Mounts AntigravityFS (AFS1) volume from ATA primary bus             |
|    - Scans PCI bus & enables bus mastering for Realtek RTL8139 NIC       |
|    - Pre-seeds ARP cache and starts network subsystem                    |
|    - Enters interactive 64-bit shell event loop with Tab completion      |
+--------------------------------------------------------------------------+
```

---

## Pure x86_64 Bare-Metal TCP/IP Stack

Antigravity OS implements a fully featured, custom network stack written from the metal up:

```
+-------------------------------------------------------------------------+
| Application Layer  | HTTP Client (curl), Bare-Metal HTTP Web Server     |
+--------------------+----------------------------------------------------+
| Transport Layer    | TCP (RFC 793, 3-Way Handshake, Sequence Tracking)  |
|                    | UDP (RFC 768, RFC 1035 DNS Domain Name Resolver)   |
+--------------------+----------------------------------------------------+
| Network Layer      | IPv4 (RFC 791, 1's Complement Checksum, Routing)   |
|                    | ICMP (RFC 792, Echo Request Client & Echo Reply)   |
+--------------------+----------------------------------------------------+
| Link Layer         | Ethernet II Framing (RFC 894, Min 60-byte padding) |
|                    | ARP (RFC 826, Dynamic Resolution & Cache Engine)   |
+--------------------+----------------------------------------------------+
| Driver / Hardware  | Realtek RTL8139 Fast Ethernet PCI (BAR0 0xC000)    |
|                    | DMA Ring Buffers, Bus Mastering, Port I/O          |
+-------------------------------------------------------------------------+
```

### Network Capabilities
1. **PCI Bus Scanner & Driver (`kernel/pci.asm`, `kernel/net.asm`):**
   - Automatically probes PCI configuration space (`0xCF8`/`0xCFC`) for Realtek RTL8139 controller (`0x10EC:0x8139`).
   - Enables PCI Bus Mastering, I/O Space, and Memory Space in the PCI Command Register.
   - Allocates identity-mapped physical DMA buffers: 8KB + 16 bytes RX ring (`0x00030000`) and 1.5KB TX buffer (`0x00034000`).
   - Reads hardware MAC address (`52:54:00:12:34:56`) from IDR registers.
   - Configures `CAPR` read pointer, `RCR` (0x8F wrap mode), and manages transmit descriptors `TSAD0..3` / `TSD0..3`.

2. **Ethernet II & ARP Engine (`kernel/eth.asm`):**
   - Encapsulates frames with 14-byte Ethernet headers, calculates Big-Endian EtherTypes (`0x0800` IPv4, `0x0806` ARP), and pads short frames to the 60-byte Ethernet minimum.
   - Implements dynamic Address Resolution Protocol (RFC 826): sends broadcast ARP requests, parses incoming replies, and manages an 8-entry ARP cache.
   - Pre-seeds Gateway (`10.0.2.2`) and DNS (`10.0.2.3`) entries.

3. **IPv4 & ICMP Engine (`kernel/ipv4.asm`):**
   - Assembles 20-byte IPv4 headers, calculates RFC 1071 16-bit 1's complement Internet Checksums, and handles fragmentation flags (DF).
   - Resolves dotted-decimal IP strings (`net_parse_ip`).
   - ICMP Echo Client (`ping`): sends 64-byte echo requests with timestamps, measures round-trip time (RTT in ms) via PIT timer ticks, and formats standard ping statistics.
   - ICMP Echo Responder: automatically mirrors echo requests back to senders with zeroed checksum recalculation.

4. **UDP & DNS Resolver (`kernel/udp.asm`):**
   - Generates 8-byte UDP datagram headers.
   - Full RFC 1035 DNS Client (`dns` / `nslookup`): converts dotted domain names (e.g. `google.com`) into length-prefixed QNAME labels, transmits standard recursive queries (Type A, Class IN) to `10.0.2.3:53`, parses answer records, and extracts 32-bit resolved IPv4 addresses.

5. **TCP State Machine & HTTP (`kernel/tcp.asm`):**
   - RFC 793 Transmission Control Protocol with 20-byte TCP header and 12-byte IPv4 pseudo-header checksum calculation.
   - State machine: `CLOSED`, `LISTEN`, `SYN_SENT`, `SYN_RCVD`, `ESTABLISHED`, `FIN_WAIT_1`, `LAST_ACK`.
   - **HTTP Client (`curl`):** Connects to remote hosts over TCP port 80, sends standard HTTP/1.0 GET requests with `Host:` and `User-Agent:` headers, receives live HTML payloads, and displays formatted web content.
   - **Bare-Metal HTTP Web Server (`tcplisten 80`):** Listens on port 80 (accessible from host browser via `http://localhost:8888`), accepts incoming TCP handshakes, serves an interactive HTML webpage with styled CSS dark mode and status cards, and closes connections cleanly with FIN-ACK.

---

## AntigravityFS (AFS1) & Disk Layout

Antigravity OS features an on-disk filesystem with persistent storage powered by a hardware ATA PIO controller driver (`kernel/ata.asm`).

### Disk Layout (256 KB Volume / 512 Sectors)

| LBA Sector | Byte Offset | Purpose | Description |
|---|---|---|---|
| **0** | `0x00000` | **MBR Bootloader** | 512-byte boot sector (`0xAA55` signature) |
| **1 – 128** | `0x00200` – `0x101FF` | **64-Bit Kernel** | 64 KB kernel binary (128 sectors) |
| **129** | `0x10200` – `0x103FF` | **Superblock** | Magic (`"AFS1"`), volume size, inode/data block boundaries |
| **130 – 131** | `0x10400` – `0x107FF` | **Inode Table** | 32 inode entries (32 bytes each $\times$ 32 = 1,024 bytes) |
| **132 – 511** | `0x10800` – `0x3FFFF` | **Data Blocks** | 380 direct 512-byte data sectors for file contents |

---

## Memory Map

| Physical Address | Size | Description |
|---|---|---|
| `0x0000000000000000` - `0x00000000000003FF` | 1 KB | Real Mode Interrupt Vector Table (IVT) |
| `0x0000000000000400` - `0x00000000000004FF` | 256 B | BIOS Data Area (BDA) |
| `0x0000000000001000` - `0x0000000000001FFF` | 4 KB | **PML4 Page Table** (CR3 root) |
| `0x0000000000002000` - `0x0000000000002FFF` | 4 KB | **PDPT Page Directory Pointer Table** |
| `0x0000000000003000` - `0x0000000000003FFF` | 4 KB | **PDT Page Directory Table** (2MB huge pages) |
| `0x0000000000007C00` - `0x0000000000007DFF` | 512 B | **MBR Bootloader** (loaded by BIOS) |
| `0x0000000000008000` - `0x0000000000017FFF` | 64 KB | **64-bit Kernel Code & Data** |
| `0x0000000000030000` - `0x0000000000032010` | 8 KB | **RTL8139 RX DMA Ring Buffer** |
| `0x0000000000034000` - `0x0000000000034FFF` | 1.5 KB | **RTL8139 TX DMA Buffer** |
| `0x0000000000090000` | — | **64-bit Kernel Stack Pointer (RSP)** |
| `0x00000000000B8000` - `0x00000000000BFFFF` | 32 KB | **VGA Color Text Buffer** (80 columns x 25 rows) |

---

## Directory Structure

```
asm/
├── boot/
│   ├── bootloader.asm    # 512-byte MBR bootloader with 64-bit Long Mode switch
│   ├── disk.asm          # BIOS INT 0x13 AH=0x02 disk loader
│   ├── gdt.asm           # Unified 32-bit & 64-bit Global Descriptor Table
│   └── a20.asm           # A20 address line enabler
├── kernel/
│   ├── kernel.asm        # 64-bit Kernel entry, banner, and main event loop
│   ├── vga.asm           # 64-bit VGA 80x25 driver, color formatting, hex/dec
│   ├── idt.asm           # 64-bit IDT (16-byte descriptors) & 8259 PIC remapping
│   ├── isr.asm           # 64-bit ISR stubs with iretq, timer IRQ0, keyboard IRQ1
│   ├── keyboard.asm      # PS/2 scancode decoder (Set 1), shift tracking, buffer
│   ├── ata.asm           # 64-bit ATA PIO disk driver (ports 0x1F0-0x1F7)
│   ├── fs.asm            # AntigravityFS (AFS1) filesystem implementation
│   ├── pci.asm           # PCI configuration space scanner & bus master enabler
│   ├── net.asm           # Realtek RTL8139 Fast Ethernet PCI controller driver
│   ├── eth.asm           # Ethernet II framing & Address Resolution Protocol (ARP)
│   ├── ipv4.asm          # IPv4 packet assembly/parsing & ICMP ping engine
│   ├── udp.asm           # RFC 768 UDP transport & RFC 1035 DNS client
│   ├── tcp.asm           # RFC 793 TCP state machine, HTTP client & web server
│   └── shell.asm         # 64-bit CLI shell with filesystem & network commands
├── build.ps1             # PowerShell automated build & run script
├── test_boot.ps1         # Automated QEMU QMP test runner & screen capture
└── README.md             # Technical documentation
```

---

## Built-In 64-Bit Shell Commands (26 Total)

### Network Commands
- **`ifconfig`** / **`net`**: Displays link status, hardware MAC address, IPv4 address (`10.0.2.15`), netmask, gateway, DNS server, and live RX/TX packet & byte counters.
- **`arp`**: Dumps the Address Resolution Protocol (ARP) table showing IP-to-MAC associations.
- **`ping <ip/domain>`**: Transmits ICMP echo requests to target host (with automatic DNS resolution) and reports round-trip times (RTT in ms).
- **`dns <domain>`** / **`nslookup`**: Resolves domain names to IPv4 addresses using UDP port 53.
- **`curl <target> [port]`** / **`http`**: HTTP client that connects via TCP, sends GET request, and prints HTML response.
- **`tcplisten [port]`**: Launches bare-metal HTTP web server on port 80 (accessible from host at `http://localhost:8888`).
- **`gui`** / **`desktop`**: Launches the 1024x768x32bpp TrueColor graphical desktop and interactive window manager. Return to CLI anytime with <kbd>Esc</kbd> or <kbd>q</kbd>.

---

## 1024x768x32bpp Bare-Metal Graphical User Interface (GUI)

Antigravity OS features a high-resolution, hardware-accelerated desktop environment written from scratch in pure x86_64 assembly:

```
+----------------------------------------------------------------------------------------------------+
| [ AGY OS 64 ]   [System]  [Terminal]  [Cyber Canvas]             [IP: 10.0.2.15]  [RAM: 4GB] [Exit] |  <- Taskbar
+----------------------------------------------------------------------------------------------------+
|  +------------------------------+  +------------------------------+                                |
|  | [*][*][*] System Monitor     |  | [*][*][*] Antigravity Term   |                                |
|  |------------------------------|  |------------------------------|                                |
|  | CPU Arch: x86_64 Long Mode   |  | antigravity> sysinfo         |                                |
|  | Memory:   4096 MB RAM        |  | antigravity> ping 10.0.2.2   |                                |
|  | Paging:   4-Level PML4 Huge  |  | antigravity> dns google.com  |                                |
|  | Display:  BGA 1024x768 32bpp |  | antigravity> curl google.com |                                |
|  | Storage:  AFS1 Primary ATA   |  | antigravity> gui             |                                |
|  | Network:  RTL8139 PCI (LAN)  |  | antigravity> _               |                                |
|  +------------------------------+  +------------------------------+                                |
|                                                                                                    |
|  +----------------------------------------------------------------------------------------------+  |
|  | [*][*][*] Cyber Canvas & Interactive Vector Visualizer                                       |  |
|  |----------------------------------------------------------------------------------------------|  |
|  | [1][2][3][4][5][6][7][8]  [ Clear Canvas ]  [ Draw Cyber Art ]  Mouse/Space: Draw | Esc: Exit|  |
|  | +------------------------------------------------------------------------------------------+ |  |
|  | |                               < Concentric Cyber Diamonds >                              | |  |
|  | |                                 [ ANTIGRAVITY OS 64-BIT ]                                | |  |
|  | +------------------------------------------------------------------------------------------+ |  |
|  +----------------------------------------------------------------------------------------------+  |
+----------------------------------------------------------------------------------------------------+
| Antigravity OS v1.0 | Press [ESC] or [Q] to return to CLI | Mouse: Active | Net: Online   [4GB RAM] |
+----------------------------------------------------------------------------------------------------+
```

### GUI Hardware Architecture & Components
1. **Bochs Graphics Adaptor (BGA) Driver (`kernel/bga.asm`):**
   - Automatically probes PCI configuration space (`0xCF8`/`0xCFC`) for QEMU/Bochs standard VGA card (`0x1234:0x1111`).
   - Reads BAR0 to dynamically map the 32-bit Linear FrameBuffer (LFB) at `0xFD000000`.
   - Programs BGA registers via I/O ports `0x01CE` and `0x01CF` to switch into **1024 x 768 x 32bpp TrueColor** mode (`VBE_DISPI_LFB_ENABLED`).
   - Includes complete VGA Mode 03h hardware register restoration (Sequencer, CRTC, Graphics Controller, Attribute Controller, and Plane 2 font memory loader) to seamlessly revert back to 80x25 text mode upon pressing <kbd>Esc</kbd>.

2. **PS/2 Mouse Controller Driver (`kernel/mouse.asm`):**
   - Communicates with 8042 auxiliary PS/2 mouse device (`0x64`/`0x60`).
   - Enables mouse reporting command (`0xF4`) and decodes continuous 3-byte packets (`mouse_poll`).
   - Parses signed 9-bit delta X and inverted delta Y, clamping coordinates strictly within `[0..1023, 0..767]`.
   - Tracks left, right, and middle mouse button state machines.

3. **2D Graphics Primitives Engine (`kernel/gfx.asm`):**
   - Direct 32-bit ARGB pixel writing with screen bounds clipping (`gfx_putpixel`, `gfx_getpixel`).
   - Solid and outlined rectangles (`gfx_fill_rect`, `gfx_draw_rect`).
   - Smooth 32-bit linear vertical color gradients (`gfx_draw_gradient_v`) with direct scanline DMA blitting.
   - 95-character printable ASCII 8x8 raster bitmap font renderer (`gfx_draw_char`, `gfx_print_string`).
   - Double-buffered arrow mouse cursor (`gfx_draw_cursor`, `gfx_restore_cursor`) with 16x18 mask, black outline, electric cyan core, and background restoration to prevent ghosting or screen tearing.

4. **Desktop Environment & Window Manager (`kernel/gui.asm`):**
   - **Taskbar:** Slate top panel with `[ AGY OS 64 ]` cyan pill, active menu buttons, and real-time status badges (`IP: 10.0.2.15`, `RAM: 4 GB`, `Exit (Esc)`).
   - **Window 1 (System Monitor):** Shows hardware architecture, identity-mapped physical memory, 4-level huge paging, AFS storage, RTL8139 NIC, and network status.
   - **Window 2 (Antigravity Terminal):** Framed terminal shell showing command history (`sysinfo`, `ls`, `ping`, `dns`, `curl`, `gui`) and active prompt cursor.
   - **Window 3 (Cyber Canvas):** Interactive painting surface with 8 color palette swatches, selection highlights, `[ Clear Canvas ]`, `[ Draw Cyber Art ]`, and live drawing via mouse dragging or keyboard.
   - **Background Multitasking:** Continues to poll the RTL8139 network card (`net_poll`) during GUI rendering so ICMP pings and HTTP web requests continue to be served in real time!
   - **Seamless Mode Switching:** Pressing <kbd>Esc</kbd>, <kbd>q</kbd>, or clicking `[Exit]` restores VGA hardware registers and text font, instantly returning to the interactive shell.

### Filesystem Commands
- **`ls`** / **`dir`**: Lists all active files on disk with filename, byte size, and assigned LBA sector.
- **`cat <file>`**: Reads the file directly from its disk LBA sector and prints its content to screen.
- **`touch <file>`**: Allocates a free inode and empty sector on disk.
- **`write <file> <text>`**: Writes text content into the file and commits it permanently to disk via ATA PIO.
- **`rm <file>`**: Deletes the file and frees its inode table entry.
- **`df`**: Displays volume capacity, total sectors, and inode allocation statistics.

### System & Diagnostic Commands
- **`regs`**: Dumps all 64-bit General Purpose Registers (`RAX` through `R15`) in hexadecimal.
- **`cpu`**: Executes `cpuid` to display CPU vendor ID (`AuthenticAMD`, `GenuineIntel`), family signature, and confirms Long Mode activation.
- **`mem`**: Displays 64-bit memory layout, CR3 PML4 table location, kernel base address, and current 64-bit stack pointer (`RSP`).
- **`ticks`**: Displays the 64-bit hardware timer tick counter driven by PIT IRQ0.
- **`help`**: Displays reference manual of all built-in commands.
- **`echo <text>`**: Echos input text back to the terminal.
- **`clear`**: Clears the VGA text buffer and redraws the 64-bit OS header.
- **`about`**: Displays 64-bit Long Mode architecture specifications.
- **`reboot`**: Resets the machine using the 8042 keyboard controller reset pulse.
- **`halt`**: Safely parks the 64-bit CPU with `cli; hlt`.

---

## Tab Auto-Completion Engine

Antigravity OS features a bash-style Tab auto-completion engine covering all 28 commands:

- **Command Completion:**
  - Type `g` + <kbd>Tab</kbd> $\to$ Auto-completes to `gui `.
  - Type `des` + <kbd>Tab</kbd> $\to$ Auto-completes to `desktop `.
  - Type `cu` + <kbd>Tab</kbd> $\to$ Auto-completes to `curl `.
  - Type `if` + <kbd>Tab</kbd> $\to$ Auto-completes to `ifconfig `.
  - Type `tcp` + <kbd>Tab</kbd> $\to$ Auto-completes to `tcplisten `.
  - Press <kbd>Tab</kbd> on a blank line $\to$ Lists all 28 available OS commands in alphabetical order.

- **Filesystem Dynamic Completion:**
  - Type `cat w` + <kbd>Tab</kbd> $\to$ Scans on-disk `fs_inode_table` and auto-completes to `cat welcome.txt `.
  - Type `cat ` + <kbd>Tab</kbd> $\to$ Lists all active files stored on the AntigravityFS volume.

---

## How to Build & Run

### Using PowerShell (Windows)
```powershell
# Build and automatically boot in QEMU:
.\build.ps1 -Run

# Rebuild kernel while preserving existing files and disk data:
.\build.ps1

# Clean and reformat disk image from scratch:
.\build.ps1 -Clean
.\build.ps1 -Run
```

### Accessing the Bare-Metal Web Server
1. Inside Antigravity OS, start the server:
   ```
   antigravity64> tcplisten 80
   ```
2. On your Windows host, open your browser or PowerShell:
   ```powershell
   Invoke-WebRequest -Uri http://localhost:8888
   ```
   or visit `http://localhost:8888` in Chrome / Edge to view the web page served directly from pure x86_64 assembly!
