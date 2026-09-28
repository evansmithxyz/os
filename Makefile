# Antigravity OS - convenience targets. Everything is done by tools/build.py,
# which also works directly on Windows: python tools/build.py [run|test|...]

PYTHON ?= python3

.PHONY: all fresh run headless test debug size clean

all:            ## build build/os.img (keeps files on the disk)
	$(PYTHON) tools/build.py

fresh:          ## rebuild and reformat the disk from rootfs/
	$(PYTHON) tools/build.py --fresh

run:            ## boot in QEMU with a window (serial console in this terminal)
	$(PYTHON) tools/build.py run

headless:       ## boot without a window; the serial console is the terminal
	$(PYTHON) tools/build.py run --headless

test:           ## run the automated QEMU test suite
	$(PYTHON) tools/build.py test

debug:          ## boot paused, wait for gdb on localhost:1234
	$(PYTHON) tools/build.py debug

size:           ## kernel image / .bss usage
	$(PYTHON) tools/build.py size

clean:
	$(PYTHON) tools/build.py clean
