#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static int receive_all(int descriptor, unsigned char *buffer, size_t size)
{
    while (size > 0) {
        ssize_t count = recv(descriptor, buffer, size, 0);
        if (count <= 0) {
            fprintf(stderr, "receive: %s\n", count == 0 ? "peer closed" : strerror(errno));
            return -1;
        }
        buffer += count;
        size -= (size_t)count;
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 3 && argc != 4) {
        fprintf(stderr, "usage: socks_probe IPv4 PORT [interface]\n");
        return 1;
    }
    int port = atoi(argv[2]);
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons((unsigned short)port);
    if (port < 1 || port > 65535 || inet_pton(AF_INET, argv[1], &address.sin_addr) != 1) {
        return 1;
    }
    int descriptor = socket(AF_INET, SOCK_STREAM, 0);
    if (descriptor < 0) {
        perror("socket");
        return 1;
    }
    if (argc == 4) {
#ifdef SO_BINDTODEVICE
        if (setsockopt(descriptor, SOL_SOCKET, SO_BINDTODEVICE, argv[3], strlen(argv[3]) + 1) < 0) {
            perror("SO_BINDTODEVICE");
            close(descriptor);
            return 1;
        }
        printf("Interface: %s\n", argv[3]);
#else
        fprintf(stderr, "Interface binding unavailable on this platform\n");
        close(descriptor);
        return 1;
#endif
    }
    fcntl(descriptor, F_SETFL, O_NONBLOCK);
    int result = connect(descriptor, (struct sockaddr *)&address, sizeof(address));
    if (result < 0 && errno == EINPROGRESS) {
        struct pollfd pending = { .fd = descriptor, .events = POLLOUT };
        result = poll(&pending, 1, 5000);
        if (result > 0) {
            int error = 0;
            socklen_t length = sizeof(error);
            if (getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) < 0) {
                result = -1;
            } else {
                errno = error;
                result = error == 0 ? 0 : -1;
            }
        } else {
            if (result == 0) {
                errno = ETIMEDOUT;
            }
            result = -1;
        }
    }
    if (result < 0) {
        fprintf(stderr, "TCP %s:%d failed: %s (errno=%d)\n", argv[1], port, strerror(errno), errno);
        close(descriptor);
        return 2;
    }
    puts("TCP connected");
    fcntl(descriptor, F_SETFL, 0);
    struct timeval timeout = { .tv_sec = 5 };
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    const unsigned char greeting[] = {5, 1, 0};
    unsigned char reply[4];
    if (send(descriptor, greeting, sizeof(greeting), 0) != sizeof(greeting) ||
        receive_all(descriptor, reply, 2) < 0) {
        close(descriptor);
        return 3;
    }
    printf("SOCKS5 greeting: version=%u method=%u\n", reply[0], reply[1]);
    if (reply[0] != 5 || reply[1] != 0) {
        close(descriptor);
        return 4;
    }
    const unsigned char associate[] = {5, 3, 0, 1, 0, 0, 0, 0, 0, 0};
    if (send(descriptor, associate, sizeof(associate), 0) != sizeof(associate) ||
        receive_all(descriptor, reply, sizeof(reply)) < 0) {
        close(descriptor);
        return 5;
    }
    printf("UDP ASSOCIATE: version=%u reply=%u address_type=%u\n", reply[0], reply[1], reply[3]);
    close(descriptor);
    return reply[0] == 5 && reply[1] == 0 ? 0 : 6;
}