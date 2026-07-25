CC = gcc
CFLAGS = -shared -fPIC -Wall -O2
LUA_INC = $(shell pkg-config --cflags lua5.4 2>/dev/null || echo "-I/usr/include/lua5.4")
SQLITE_LIB = -lsqlite3

TARGETS = lem_executor.so lem_db.so lem_fs.so

all: $(TARGETS)

lem_executor.so: lem_executor.c lem_common.h
	$(CC) $(CFLAGS) $(LUA_INC) -o $@ $<

lem_db.so: lem_db.c lem_common.h
	$(CC) $(CFLAGS) $(LUA_INC) $(SQLITE_LIB) -o $@ $<

lem_fs.so: lem_fs.c lem_common.h
	$(CC) $(CFLAGS) $(LUA_INC) -o $@ $<

clean:
	rm -f $(TARGETS)

.PHONY: all clean
