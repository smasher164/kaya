# The C guests, on the function floor. One binary per scene;
# TARGET_DIR points at the platform's libkaya build (target/debug,
# target-linux/debug, ...), OUT at where the binaries land.
CC ?= clang
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
TARGET_DIR ?= $(ROOT)/target/debug
OUT ?= $(ROOT)/target/c-guests

CFLAGS += -I$(ROOT)/crates/kaya/include -I$(ROOT)/bindings/c
# A KayaTx written `{buf, 0}` compiles with cap 0 and refuses its first
# record at RUN time. This makes it fail the BUILD instead, naming `cap`
# — the wall on the path nobody can avoid (tools/check-c-bounds.sh).
CFLAGS += -Werror=missing-field-initializers
LDFLAGS += -L$(TARGET_DIR) -lkaya -Wl,-rpath,$(TARGET_DIR)

# THE HEADERS ARE PREREQUISITES, and that is the guard: without them
# make cannot see a spec-hash move, the binary goes stale, and the
# compiled-in KAYA_SPEC_HASH check fires at RUN time instead, on a lane
# whose author never touched C. Measured 2026-08-06 (a regenerated
# kaya_wire.h, a no-op `make`, the mac undo-c leg dying with
# "library/binding spec mismatch"). The floor has no package manager and
# no compiler-driven dependency file, so this is written by hand.
HEADERS := $(ROOT)/crates/kaya/include/kaya.h $(ROOT)/bindings/c/kaya_wire.h

SCENES := background milestone2 a11y entry gallery todos reorder feed menus commands undo dirty ranges save a11yrows styling assets

all: $(SCENES:%=$(OUT)/%)

$(OUT)/%: %.c $(HEADERS)
	@mkdir -p $(OUT)
	$(CC) $< $(CFLAGS) -o $@ $(LDFLAGS)

.PHONY: all
