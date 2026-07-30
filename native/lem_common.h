#ifndef LEM_COMMON_H
#define LEM_COMMON_H

/* Lua version compatibility */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

/* Lua 5.1 / LuaJIT compatibility (both report LUA_VERSION_NUM < 502) */
#if LUA_VERSION_NUM < 502
#ifndef luaL_newlib
#define luaL_newlib(L, l) (lua_newtable(L), luaL_register(L, NULL, l))
#endif
/*
 * luaL_setfuncs does not exist in Lua 5.1 or LuaJIT.
 * Provide a static function that correctly handles upvalues:
 * - Stack layout on entry: ... [table] [upval_1] ... [upval_n]
 * - For each function: push nup copies of upvalues, create closure, set field
 * - Finally pop the original nup upvalues
 */
static void lem_setfuncs_compat(lua_State *L, const luaL_Reg *l, int nup) {
    int i;
    for (; l->name != NULL; l++) {
        /* Stack: ... [table] [upval_1] ... [upval_n] */
        for (i = 0; i < nup; i++) {
            lua_pushvalue(L, -(nup + 1));
        }
        /* lua_pushcclosure pops nup values, pushes 1 closure.
         * Net stack change: -(nup) + 1 = -(nup-1)
         * Table was at -(nup+1), now at -(nup+1)-(nup-1) ... simplified: -(nup+2)
         * For nup=0: table at -2 (closure on top). Correct. */
        lua_pushcclosure(L, l->func, nup);
        lua_setfield(L, -(nup + 2), l->name);
    }
    lua_pop(L, nup);  /* remove original upvalues */
}
#ifndef luaL_setfuncs
#define luaL_setfuncs(L, l, n) lem_setfuncs_compat(L, l, n)
#endif
#ifndef lua_rawlen
#define lua_rawlen lua_objlen
#endif
#ifndef luaL_newlibtable
#define luaL_newlibtable(L, l) lua_newtable(L)
#endif
/* lua_absindex for 5.1 */
static int lua_absindex_compat(lua_State *L, int idx) {
    return (idx > 0 || idx <= LUA_REGISTRYINDEX) ? idx : lua_gettop(L) + 1 + idx;
}
#ifndef lua_absindex
#define lua_absindex lua_absindex_compat
#endif
#endif

/* Lua 5.2 compatibility */
#if LUA_VERSION_NUM == 502
#ifndef luaL_newlib
#define luaL_newlib(L, l) (lua_newtable(L), luaL_setfuncs(L, l, 0))
#endif
#endif

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
