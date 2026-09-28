# ==============================================================================
# Antigravity OS - Makefile
# ==============================================================================

NASM      ?= nasm
QEMU      ?= qemu-system-x86_64
BIN_DIR   := bin
BOOT_DIR  := boot
KERNEL_DIR:= kernel

BOOT_SRC  := $(BOOT_DIR)/bootloader.asm $(BOOT_DIR)/disk.asm $(BOOT_DIR)/gdt.asm $(BOOT_DIR)/a20.asm
KERNEL_SRC:= $(KERNEL_DIR)/kernel.asm $(KERNEL_DIR)/vga.asm $(KERNEL_DIR)/idt.asm $(KERNEL_DIR)/isr.asm $(KERNEL_DIR)/keyboard.asm $(KERNEL_DIR)/shell.asm

BOOT_BIN  := $(BIN_DIR)/bootloader.bin
KERNEL_BIN:= $(BIN_DIR)/kernel.bin
OS_IMAGE  := $(BIN_DIR)/os-image.bin

.PHONY: all run clean

all: $(OS_IMAGE)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

$(BOOT_BIN): $(BOOT_SRC) | $(BIN_DIR)
	$(NASM) -f bin -i $(BOOT_DIR)/ $(BOOT_DIR)/bootloader.asm -o $@

$(KERNEL_BIN): $(KERNEL_SRC) | $(BIN_DIR)
	$(NASM) -f bin -i $(KERNEL_DIR)/ $(KERNEL_DIR)/kernel.asm -o $@

$(OS_IMAGE): $(BOOT_BIN) $(KERNEL_BIN)
	cat $(BOOT_BIN) $(KERNEL_BIN) > $@

run: $(OS_IMAGE)
	$(QEMU) -drive format=raw,file=$(OS_IMAGE)

clean:
	rm -rf $(BIN_DIR)
