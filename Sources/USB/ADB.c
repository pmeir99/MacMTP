#include "USB.h"
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <poll.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <string.h>

// ADB's standard local server socket. No server is started, and no installed
// executable is run. All reads and writes have a one-second bound.
static int adb_connect(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    struct timeval timeout = { .tv_sec = 1, .tv_usec = 0 };
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) ||
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) ||
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout))) {
        close(fd);
        return -1;
    }
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(fd);
        return -1;
    }
    int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (result < 0 && errno == EINPROGRESS) {
        struct pollfd wait = { .fd = fd, .events = POLLOUT };
        result = poll(&wait, 1, 1000);
        int error = 0;
        socklen_t length = sizeof(error);
        if (result > 0 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0) {
            result = 0;
        } else {
            result = -1;
        }
    }
    if (result != 0 || fcntl(fd, F_SETFL, flags) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int send_all(int fd, const char *bytes, size_t length) {
    while (length > 0) {
        ssize_t written = send(fd, bytes, length, 0);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return 0;
        bytes += written;
        length -= (size_t)written;
    }
    return 1;
}

static int receive_all(int fd, char *bytes, size_t length) {
    while (length > 0) {
        ssize_t count = recv(fd, bytes, length, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return 0;
        bytes += count;
        length -= (size_t)count;
    }
    return 1;
}

int mac_adb_stop_server_on_port(uint16_t port) {
    int fd = adb_connect(port);
    if (fd < 0) return 0;
    char reply[4];
    // Verify the ADB protocol before sending a shutdown request.
    int verified = send_all(fd, "000chost:version", 16) &&
                   receive_all(fd, reply, 4) && memcmp(reply, "OKAY", 4) == 0 &&
                   receive_all(fd, reply, 4) && memcmp(reply, "0004", 4) == 0 &&
                   receive_all(fd, reply, 4);
    if (verified) {
        for (size_t i = 0; i < sizeof(reply); i++) {
            if (!isxdigit((unsigned char)reply[i])) verified = 0;
        }
    }
    close(fd);
    if (!verified) return -1;
    fd = adb_connect(port);
    if (fd < 0) return 0;
    int sent = send_all(fd, "0009host:kill", 13);
    ssize_t count;
    do {
        count = recv(fd, reply, 4, MSG_WAITALL);
    } while (count < 0 && errno == EINTR);
    close(fd);
    // ADB versions either acknowledge the request or close the socket at shutdown.
    if (sent && (count == 0 || (count == 4 && memcmp(reply, "OKAY", 4) == 0))) return 1;
    return -1;
}

int mac_adb_stop_server(void) { return mac_adb_stop_server_on_port(5037); }
