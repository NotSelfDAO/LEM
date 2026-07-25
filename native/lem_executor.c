/*
 * lem_executor.c - Process execution module for LEM
 * Provides fork/execvp/waitpid based command execution with pipe output capture and timeout support.
 */

#include "lem_common.h"
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/select.h>
#include <time.h>

#define DEFAULT_TIMEOUT 300
#define OUTPUT_BUF_SIZE 65536

/*
 * Read all available data from a file descriptor into a buffer.
 * Uses select() to avoid blocking indefinitely.
 * Returns total bytes read.
 */
static size_t read_pipe_nonblock(int fd, char *buf, size_t buf_size, double timeout_sec) {
    size_t total = 0;
    struct timeval tv;
    fd_set rfds;

    while (total < buf_size - 1) {
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);

        /* Calculate remaining time */
        double elapsed = (double)(clock() - (clock_t)0) / CLOCKS_PER_SEC;
        double remaining = timeout_sec - elapsed;
        if (remaining <= 0) break;

        tv.tv_sec = (long)remaining;
        tv.tv_usec = (long)((remaining - (long)remaining) * 1000000);

        int ret = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (ret <= 0) break; /* timeout or error */

        ssize_t n = read(fd, buf + total, buf_size - 1 - total);
        if (n <= 0) break; /* EOF or error */
        total += (size_t)n;
    }
    buf[total] = '\0';
    return total;
}

/*
 * Lua interface: executor.exec(cmd_table [, opts_table])
 * cmd_table: {"apt", "install", "-y", "git"}
 * opts_table: {timeout = 60} (optional)
 * Returns: {success = true/false, output = "...", exit_code = 0}
 */
static int l_exec(lua_State *L) {
    int timeout = DEFAULT_TIMEOUT;
    char *output_buf = NULL;
    char **argv = NULL;
    int stdout_pipe[2] = {-1, -1};
    int stderr_pipe[2] = {-1, -1};
    pid_t pid;
    int status;
    int exit_code = -1;
    int success = 0;

    /* 1. Validate cmd_table argument */
    luaL_checktype(L, 1, LUA_TTABLE);

    /* 2. Read optional opts_table for timeout */
    if (lua_gettop(L) >= 2 && lua_istable(L, 2)) {
        lua_getfield(L, 2, "timeout");
        if (lua_isinteger(L, -1)) {
            timeout = (int)lua_tointeger(L, -1);
        } else if (lua_isnumber(L, -1)) {
            timeout = (int)lua_tonumber(L, -1);
        }
        lua_pop(L, 1);
    }

    /* 3. Convert cmd_table to char *argv[] */
    int argc = (int)lua_rawlen(L, 1);
    if (argc < 1) {
        luaL_error(L, "cmd_table must contain at least one element");
    }

    argv = (char **)malloc(sizeof(char *) * (argc + 1));
    if (!argv) {
        luaL_error(L, "out of memory");
    }

    for (int i = 0; i < argc; i++) {
        lua_rawgeti(L, 1, i + 1);
        const char *arg = luaL_checkstring(L, -1);
        argv[i] = strdup(arg);
        lua_pop(L, 1);
    }
    argv[argc] = NULL;

    /* 4. Create pipes for stdout and stderr (merge stderr into stdout) */
    if (pipe(stdout_pipe) < 0) {
        luaL_error(L, "failed to create pipe: %s", strerror(errno));
    }

    /* 5. fork() */
    pid = fork();
    if (pid < 0) {
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        for (int i = 0; i < argc; i++) free(argv[i]);
        free(argv);
        luaL_error(L, "fork failed: %s", strerror(errno));
    }

    if (pid == 0) {
        /* Child process */
        close(stdout_pipe[0]); /* close read end */

        /* Redirect stdout to pipe write end */
        dup2(stdout_pipe[1], STDOUT_FILENO);
        /* Redirect stderr to stdout (merge) */
        dup2(stdout_pipe[1], STDERR_FILENO);
        close(stdout_pipe[1]);

        /* Execute the command */
        execvp(argv[0], argv);

        /* If execvp returns, it failed */
        fprintf(stderr, "execvp failed: %s\n", strerror(errno));
        _exit(127);
    }

    /* Parent process */
    close(stdout_pipe[1]); /* close write end */

    /* Free argv in parent */
    for (int i = 0; i < argc; i++) free(argv[i]);
    free(argv);
    argv = NULL;

    /* 6. Allocate output buffer and read from pipe with timeout */
    output_buf = (char *)malloc(OUTPUT_BUF_SIZE);
    if (!output_buf) {
        close(stdout_pipe[0]);
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        luaL_error(L, "out of memory");
    }

    /* Set read end to non-blocking for select-based reading */
    read_pipe_nonblock(stdout_pipe[0], output_buf, OUTPUT_BUF_SIZE, (double)timeout);
    close(stdout_pipe[0]);

    /* 7. Wait for child with timeout handling */
    /* Use alarm + waitpid approach */
    struct timespec start_time, now_time;
    clock_gettime(CLOCK_MONOTONIC, &start_time);

    int wait_result;
    int timed_out = 0;
    while (1) {
        wait_result = waitpid(pid, &status, WNOHANG);
        if (wait_result > 0) break; /* child exited */
        if (wait_result < 0) {
            if (errno == EINTR) continue;
            break; /* unexpected error */
        }

        /* Child still running, check timeout */
        clock_gettime(CLOCK_MONOTONIC, &now_time);
        double elapsed = (now_time.tv_sec - start_time.tv_sec) +
                         (now_time.tv_nsec - start_time.tv_nsec) / 1e9;
        if (elapsed >= (double)timeout) {
            timed_out = 1;
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            break;
        }

        /* Brief sleep to avoid busy-waiting */
        struct timespec sleep_ts = {0, 10000000}; /* 10ms */
        nanosleep(&sleep_ts, NULL);
    }

    /* 8. Determine success and exit code */
    if (timed_out) {
        success = 0;
        exit_code = -1;
        /* Append timeout message to output */
        size_t len = strlen(output_buf);
        if (len < OUTPUT_BUF_SIZE - 64) {
            snprintf(output_buf + len, OUTPUT_BUF_SIZE - len,
                     "\n[LEM: process timed out after %d seconds]", timeout);
        }
    } else if (WIFEXITED(status)) {
        exit_code = WEXITSTATUS(status);
        success = (exit_code == 0) ? 1 : 0;
    } else if (WIFSIGNALED(status)) {
        exit_code = -WTERMSIG(status);
        success = 0;
    } else {
        exit_code = -1;
        success = 0;
    }

    /* 9. Build result table */
    lem_push_result(L, success, output_buf, exit_code);

    /* 10. Cleanup */
    free(output_buf);

    return 1;
}

static const luaL_Reg executor_funcs[] = {
    {"exec", l_exec},
    {NULL, NULL}
};

int luaopen_native_lem_executor(lua_State *L) {
    luaL_newlib(L, executor_funcs);
    return 1;
}
