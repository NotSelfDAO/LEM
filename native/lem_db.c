/*
 * lem_db.c - SQLite3 native binding for LEM
 * Provides db.open/exec/query/close with WAL mode and __gc support.
 */

#include "lem_common.h"
#include <sqlite3.h>

#define LEM_DB_METATABLE "lem.db"

typedef struct {
    sqlite3 *db;
} LemDB;

static LemDB* check_db(lua_State *L, int idx) {
    return (LemDB*)luaL_checkudata(L, idx, LEM_DB_METATABLE);
}

/* db.open(path) -> userdata */
static int l_open(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    LemDB *ldb = (LemDB*)lua_newuserdata(L, sizeof(LemDB));
    luaL_setmetatable(L, LEM_DB_METATABLE);

    int rc = sqlite3_open(path, &ldb->db);
    if (rc != SQLITE_OK) {
        const char *msg = sqlite3_errmsg(ldb->db);
        sqlite3_close(ldb->db);
        ldb->db = NULL;
        luaL_error(L, "cannot open database: %s", msg);
    }

    /* Enable WAL mode for better concurrency */
    sqlite3_exec(ldb->db, "PRAGMA journal_mode=WAL", NULL, NULL, NULL);

    return 1;
}

/* db.exec(conn, sql) -> success [, errmsg] */
static int l_exec(lua_State *L) {
    LemDB *ldb = check_db(L, 1);
    if (!ldb->db) {
        luaL_error(L, "database connection is closed");
    }
    const char *sql = luaL_checkstring(L, 2);
    char *errmsg = NULL;

    int rc = sqlite3_exec(ldb->db, sql, NULL, NULL, &errmsg);
    if (rc != SQLITE_OK) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, errmsg ? errmsg : "unknown error");
        sqlite3_free(errmsg);
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

/* db.query(conn, sql) -> results table (array of row tables) */
static int l_query(lua_State *L) {
    LemDB *ldb = check_db(L, 1);
    if (!ldb->db) {
        luaL_error(L, "database connection is closed");
    }
    const char *sql = luaL_checkstring(L, 2);
    sqlite3_stmt *stmt;

    int rc = sqlite3_prepare_v2(ldb->db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        luaL_error(L, "SQL error: %s", sqlite3_errmsg(ldb->db));
    }

    lua_newtable(L);  /* results array */
    int row = 1;
    int cols = sqlite3_column_count(stmt);

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        lua_newtable(L);  /* row table */
        for (int i = 0; i < cols; i++) {
            const char *col_name = sqlite3_column_name(stmt, i);
            int col_type = sqlite3_column_type(stmt, i);
            switch (col_type) {
                case SQLITE_NULL:
                    lua_pushnil(L);
                    break;
                case SQLITE_INTEGER:
                    lua_pushinteger(L, sqlite3_column_int64(stmt, i));
                    break;
                case SQLITE_FLOAT:
                    lua_pushnumber(L, sqlite3_column_double(stmt, i));
                    break;
                default:
                    lua_pushstring(L, (const char*)sqlite3_column_text(stmt, i));
                    break;
            }
            lua_setfield(L, -2, col_name);
        }
        lua_rawseti(L, -2, row++);
    }

    sqlite3_finalize(stmt);
    return 1;
}

/* db.close(conn) */
static int l_close(lua_State *L) {
    LemDB *ldb = check_db(L, 1);
    if (ldb->db) {
        sqlite3_close(ldb->db);
        ldb->db = NULL;
    }
    return 0;
}

/* __gc metamethod - auto close on garbage collection */
static int l_gc(lua_State *L) {
    LemDB *ldb = check_db(L, 1);
    if (ldb->db) {
        sqlite3_close(ldb->db);
        ldb->db = NULL;
    }
    return 0;
}

static const luaL_Reg db_methods[] = {
    {"__gc", l_gc},
    {"__close", l_gc},  /* for to-be-closed variables in Lua 5.4 */
    {NULL, NULL}
};

static const luaL_Reg db_funcs[] = {
    {"open", l_open},
    {"exec", l_exec},
    {"query", l_query},
    {"close", l_close},
    {NULL, NULL}
};

int luaopen_native_lem_db(lua_State *L) {
    /* Create metatable */
    luaL_newmetatable(L, LEM_DB_METATABLE);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, db_methods, 0);
    lua_pop(L, 1);

    /* Create module table */
    luaL_newlib(L, db_funcs);
    return 1;
}
