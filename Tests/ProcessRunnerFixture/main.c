// Test-only child processes. Avoid interpreter cold starts inside short deadlines.
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void write_all(int fd, const void *bytes, size_t count) {
    const char *cursor = bytes;
    while (count > 0) {
        ssize_t written = write(fd, cursor, count);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) _exit(70);
        cursor += written;
        count -= (size_t)written;
    }
}

static void emit(int fd, char byte, size_t count) {
    char buffer[4096];
    memset(buffer, byte, sizeof(buffer));
    while (count > 0) {
        size_t chunk = count < sizeof(buffer) ? count : sizeof(buffer);
        write_all(fd, buffer, chunk);
        count -= chunk;
    }
}

static void *emit_stdout(void *unused) {
    (void)unused;
    emit(STDOUT_FILENO, 'o', 200000);
    return NULL;
}

static void *emit_stderr(void *unused) {
    (void)unused;
    emit(STDERR_FILENO, 'e', 200000);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) return 64;
    const char *mode = argv[1];
    if (!strcmp(mode, "ignore-term") || !strcmp(mode, "ordinary-timeout")) {
        if (argc != 3) return 64;
        if (!strcmp(mode, "ignore-term") && signal(SIGTERM, SIG_IGN) == SIG_ERR) return 70;
        // Publish the PID only after the signal disposition is installed.
        FILE *pid_file = fopen(argv[2], "w");
        if (!pid_file) return 70;
        if (fprintf(pid_file, "%d", getpid()) < 0 || fclose(pid_file) != 0) return 70;
        sleep(10);
    } else if (!strcmp(mode, "stderr")) {
        emit(STDERR_FILENO, 'x', 100000);
    } else if (!strcmp(mode, "stdout")) {
        emit(STDOUT_FILENO, 'x', 100000);
    } else if (!strcmp(mode, "detached-timeout") || !strcmp(mode, "detached-exit")
               || !strcmp(mode, "inherited-stdin")) {
        // Synchronize the fork/setsid setup so a normal parent exit cannot race it.
        int ready[2];
        if (pipe(ready) != 0) return 70;
        pid_t child = fork();
        if (child < 0) return 70;
        if (child == 0) {
            close(ready[0]);
            if (setsid() < 0) _exit(70);
            if (!strcmp(mode, "inherited-stdin")) {
                int null_fd = open("/dev/null", O_WRONLY);
                if (null_fd < 0 || dup2(null_fd, 1) < 0 || dup2(null_fd, 2) < 0) _exit(70);
                close(null_fd);
            }
            write_all(ready[1], "r", 1);
            close(ready[1]);
            sleep(2);
            _exit(0);
        }
        close(ready[1]);
        char byte;
        ssize_t received;
        do { received = read(ready[0], &byte, 1); } while (received < 0 && errno == EINTR);
        close(ready[0]);
        if (received != 1 || byte != 'r') return 70;
        if (!strcmp(mode, "detached-timeout")) sleep(2);
        if (!strcmp(mode, "inherited-stdin")) usleep(100000);
    } else if (!strcmp(mode, "both") || !strcmp(mode, "stdin-and-both")) {
        pthread_t out, err;
        if (pthread_create(&out, NULL, emit_stdout, NULL) != 0) return 70;
        if (pthread_create(&err, NULL, emit_stderr, NULL) != 0) return 70;
        size_t count = 0;
        if (!strcmp(mode, "stdin-and-both")) {
            char buffer[4096];
            for (;;) {
                ssize_t received = read(STDIN_FILENO, buffer, sizeof(buffer));
                if (received < 0 && errno == EINTR) continue;
                if (received < 0) return 70;
                if (received == 0) break;
                count += (size_t)received;
            }
        }
        if (pthread_join(out, NULL) != 0 || pthread_join(err, NULL) != 0) return 70;
        if (!strcmp(mode, "stdin-and-both")) printf("\n%zu", count);
    } else {
        return 64;
    }
    return 0;
}
