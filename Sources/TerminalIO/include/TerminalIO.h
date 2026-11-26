#ifndef SCALE_TERMINAL_IO_H
#define SCALE_TERMINAL_IO_H
// Returns 1 for readable, 0 for timeout, -1 for error (errno set).
int scale_wait_readable(int fd, int timeout_ms);
#endif
