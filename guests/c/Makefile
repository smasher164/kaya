# The C guests, on the function floor. One binary per scene;
# TARGET_DIR points at the platform's libkaya build (target/debug,
# target-linux/debug, ...), OUT at where the binaries land.
CC ?= clang
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
TARGET_DIR ?= $(ROOT)/target/debug
OUT ?= $(ROOT)/target/c-guests

CFLAGS += -I$(ROOT)/crates/kaya/include -I$(ROOT)/bindings/c
LDFLAGS += -L$(TARGET_DIR) -lkaya -Wl,-rpath,$(TARGET_DIR)

# THE HEADERS ARE PREREQUISITES, and that is a guard rather than
# tidiness. Every guest compiles KAYA_SPEC_HASH in and refuses at
# startup if the loaded library speaks a different protocol — the
# stale-artifact guard the floor has always had. Without these, make
# cannot SEE a spec move: the .c is older than the binary, nothing
# recompiles, and the guard fires at RUN time instead, on a lane whose
# author never touched C.
#
# Measured 2026-08-06: the dirty slice regenerated kaya_wire.h at 09:38
# (spec hash 0x69c07d52... -> 0x5b3d760b...) and target/c-guests/undo
# from the previous day was still on disk. `make` was a no-op and the
# mac lane's undo-c leg died with "library/binding spec mismatch" for a
# change three arms away. The floor is the one guest family with no
# package manager and no compiler-driven dependency file, so the
# dependency has to be written down.
HEADERS := $(ROOT)/crates/kaya/include/kaya.h $(ROOT)/bindings/c/kaya_wire.h

SCENES := background milestone2 a11y entry gallery todos reorder feed menus commands undo dirty

all: $(SCENES:%=$(OUT)/%)

$(OUT)/%: %.c $(HEADERS)
	@mkdir -p $(OUT)
	$(CC) $< $(CFLAGS) -o $@ $(LDFLAGS)

.PHONY: all
