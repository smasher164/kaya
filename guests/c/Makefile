# The C guests, on the function floor. One binary per scene;
# TARGET_DIR points at the platform's libkaya build (target/debug,
# target-linux/debug, ...), OUT at where the binaries land.
CC ?= clang
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
TARGET_DIR ?= $(ROOT)/target/debug
OUT ?= $(ROOT)/target/c-guests

CFLAGS += -I$(ROOT)/crates/kaya/include -I$(ROOT)/bindings/c
LDFLAGS += -L$(TARGET_DIR) -lkaya -Wl,-rpath,$(TARGET_DIR)

SCENES := milestone2 entry gallery todos reorder feed

all: $(SCENES:%=$(OUT)/%)

$(OUT)/%: %.c
	@mkdir -p $(OUT)
	$(CC) $< $(CFLAGS) -o $@ $(LDFLAGS)

.PHONY: all
