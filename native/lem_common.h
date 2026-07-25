#ifndef LEM_COMMON_H
#define LEM_COMMON_H

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Helper macro: check argument stack space */
#define LEM_CHECK_ARGS(L, n) \
    luaL_checkstack(L, n, "too many arguments")

/* Helper macro: set table string field */
#define LEM_SET_FIELD_STR(L, key, val) \
    lua_pushstring(L, val); \
    lua_setfield(L, -2, key);

/* Helper macro: set table int field */
#define LEM_SET_FIELD_INT(L, key, val) \
    lua_pushinteger(L, val); \
    lua_setfield(L, -2, key);

/* Helper macro: set table bool field */
#define LEM_SET_FIELD_BOOL(L, key, val) \
    lua_pushboolean(L, val); \
    lua_setfield(L, -2, key);

/* Helper: create result table {success, output, exit_code} */
static inline void lem_push_result(lua_State *L, int success, const char *output, int exit_code) {
    lua_newtable(L);
    LEM_SET_FIELD_BOOL(L, "success", success);
    LEM_SET_FIELD_STR(L, "output", output ? output : "");
    LEM_SET_FIELD_INT(L, "exit_code", exit_code);
}

#endif /* LEM_COMMON_H */
