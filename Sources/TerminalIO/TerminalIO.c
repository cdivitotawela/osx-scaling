#include "TerminalIO.h"
#include <errno.h>
#include <stddef.h>
#include <sys/select.h>

int scale_wait_readable(int fd, int timeout_ms) {
    if (fd < 0 || fd >= FD_SETSIZE || timeout_ms < 0) {
        errno = EINVAL;
        return -1;
    }
    fd_set readers;
    FD_ZERO(&readers);
    FD_SET(fd, &readers);
    struct timeval timeout = {
        .tv_sec = timeout_ms / 1000,
        .tv_usec = (timeout_ms % 1000) * 1000
    };
    // macOS poll(/dev/tty) can return POLLNVAL immediately. select supports it.
    return select(fd + 1, &readers, NULL, NULL, &timeout);
}
