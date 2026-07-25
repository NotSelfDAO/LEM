/*
 * lem_fs.c - Filesystem operations module for LEM
 * Provides stat/mkdir/symlink/readdir/exists using POSIX APIs.
 */

#include "lem_common.h"
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <errno.h>

/* fs.stat(path) -> {size, mode, mtime, is_dir, is_file} */
static int l_stat(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    struct stat st;

    if (stat(path, &st) != 0) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    lua_newtable(L);
    LEM_SET_FIELD_INT(L, "size", (lua_Integer)st.st_size);
    LEM_SET_FIELD_INT(L, "mode", (lua_Integer)st.st_mode);
    LEM_SET_FIELD_INT(L, "mtime", (lua_Integer)st.st_mtime);
    LEM_SET_FIELD_BOOL(L, "is_dir", S_ISDIR(st.st_mode));
    LEM_SET_FIELD_BOOL(L, "is_file", S_ISREG(st.st_mode));

    return 1;
}

/* fs.mkdir(path [, recursive]) -> success [, errmsg] */
static int l_mkdir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int recursive = 0;

    if (lua_gettop(L) >= 2) {
        recursive = lua_toboolean(L, 2);
    }

    if (!recursive) {
        if (mkdir(path, 0755) != 0) {
            lua_pushboolean(L, 0);
            lua_pushstring(L, strerror(errno));
            return 2;
        }
        lua_pushboolean(L, 1);
        return 1;
    }

    /* Recursive mkdir: create each component of the path */
    char *tmp = strdup(path);
    if (!tmp) {
        luaL_error(L, "out of memory");
    }

    size_t len = strlen(tmp);
    /* Remove trailing slash */
    if (len > 0 && tmp[len - 1] == '/') {
        tmp[len - 1] = '\0';
    }

    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
                lua_pushboolean(L, 0);
                lua_pushstring(L, strerror(errno));
                free(tmp);
                return 2;
            }
            *p = '/';
        }
    }
    /* Create the final directory */
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, strerror(errno));
        free(tmp);
        return 2;
    }

    free(tmp);
    lua_pushboolean(L, 1);
    return 1;
}

/* fs.symlink(target, linkpath) -> success [, errmsg] */
static int l_symlink(lua_State *L) {
    const char *target = luaL_checkstring(L, 1);
    const char *linkpath = luaL_checkstring(L, 2);

    if (symlink(target, linkpath) != 0) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    lua_pushboolean(L, 1);
    return 1;
}

/* fs.readdir(path) -> table of filenames (array) */
static int l_readdir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    DIR *dir = opendir(path);
    if (!dir) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    lua_newtable(L);
    struct dirent *entry;
    int idx = 1;

    while ((entry = readdir(dir)) != NULL) {
        /* Skip . and .. */
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        lua_pushstring(L, entry->d_name);
        lua_rawseti(L, -2, idx++);
    }

    closedir(dir);
    return 1;
}

/* fs.exists(path) -> boolean */
static int l_exists(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_pushboolean(L, access(path, F_OK) == 0);
    return 1;
}

static const luaL_Reg fs_funcs[] = {
    {"stat", l_stat},
    {"mkdir", l_mkdir},
    {"symlink", l_symlink},
    {"readdir", l_readdir},
    {"exists", l_exists},
    {NULL, NULL}
};

int luaopen_native_lem_fs(lua_State *L) {
    luaL_newlib(L, fs_funcs);
    return 1;
}
