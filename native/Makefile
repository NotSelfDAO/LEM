# Auto-detect Lua version and flags (including LuaJIT)
# Priority: lua5.4 > lua5.3 > lua5.2 > lua5.1 > luajit > lua

# Check for LuaJIT explicitly (its pkg-config name is "luajit")
LUAJIT_AVAILABLE := $(shell pkg-config --exists luajit 2>/dev/null && echo yes)

LUA_VERSION ?= $(shell pkg-config --variable=V lua5.4 2>/dev/null || \
                 pkg-config --variable=V lua5.3 2>/dev/null || \
                 pkg-config --variable=V lua5.2 2>/dev/null || \
                 pkg-config --variable=V lua5.1 2>/dev/null || \
                 (pkg-config --exists luajit 2>/dev/null && echo "LuaJIT") || \
                 pkg-config --variable=V lua 2>/dev/null || \
                 echo "5.4")

# Try pkg-config first, then manual paths
LUA_CFLAGS ?= $(shell pkg-config --cflags lua5.4 2>/dev/null || \
                pkg-config --cflags lua5.3 2>/dev/null || \
                pkg-config --cflags lua5.2 2>/dev/null || \
                pkg-config --cflags lua5.1 2>/dev/null || \
                pkg-config --cflags luajit 2>/dev/null || \
                pkg-config --cflags lua 2>/dev/null || \
                echo "-I/usr/include/lua5.4")

LUA_LIBS ?= $(shell pkg-config --libs lua5.4 2>/dev/null || \
              pkg-config --libs lua5.3 2>/dev/null || \
              pkg-config --libs lua5.2 2>/dev/null || \
              pkg-config --libs lua5.1 2>/dev/null || \
              pkg-config --libs luajit 2>/dev/null || \
              pkg-config --libs lua 2>/dev/null || \
              echo "-llua5.4")

CC = gcc
CFLAGS = -Wall -Wextra -O2 -fPIC $(LUA_CFLAGS)
LDFLAGS = -shared $(LUA_LIBS)

# Include common header
CFLAGS += -I.

# LuaJIT compatibility: enable all compatibility flags
CFLAGS += -DLUA_COMPAT_ALL

SQLITE_LIB = -lsqlite3

SRCS = lem_executor.c lem_db.c lem_fs.c
OBJS = $(SRCS:.c=.so)

.PHONY: all clean info

all: $(OBJS)
	@echo "Built native modules for Lua $(LUA_VERSION)"

lem_executor.so: lem_executor.c lem_common.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

lem_db.so: lem_db.c lem_common.h
	$(CC) $(CFLAGS) $(LDFLAGS) $(SQLITE_LIB) -o $@ $<

lem_fs.so: lem_fs.c lem_common.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f *.so

info:
	@echo "Lua version: $(LUA_VERSION)"
	@echo "LuaJIT available: $(LUAJIT_AVAILABLE)"
	@echo "CFLAGS: $(CFLAGS)"
	@echo "LDFLAGS: $(LDFLAGS)"
