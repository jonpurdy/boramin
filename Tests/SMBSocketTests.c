/* Exercise production libsmb2 sockets/writev with a reset loopback peer. */
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <unistd.h>
#include "smb2.h"
#include "libsmb2.h"
#include "libsmb2-private.h"

static int did_connect;

static void connected(struct smb2_context *smb2, int status, void *data, void *private_data)
{
        (void)smb2; (void)data; (void)private_data;
        assert(status == 0);
        did_connect = 1;
}

static void completed(struct smb2_context *smb2, int status, void *data, void *private_data)
{
        (void)smb2; (void)status; (void)data; (void)private_data;
}

static void reset_peer_write(void)
{
        signal(SIGPIPE, SIG_DFL);
        alarm(10);
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        assert(listener >= 0);
        struct sockaddr_in address = { .sin_family = AF_INET,
                                      .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
        assert(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0);
        assert(listen(listener, 1) == 0);
        socklen_t length = sizeof(address);
        assert(getsockname(listener, (struct sockaddr *)&address, &length) == 0);
        char server[64];
        snprintf(server, sizeof(server), "127.0.0.1:%u", ntohs(address.sin_port));
        struct smb2_context *smb2 = smb2_init_context();
        assert(smb2);
        assert(smb2_connect_async(smb2, server, connected, NULL) == 0);
        int fd = smb2_get_fd(smb2);
        assert(fd >= 0);
        struct pollfd ready = { .fd = fd, .events = POLLOUT };
        assert(poll(&ready, 1, 2000) == 1);
        assert(smb2_service(smb2, ready.revents) == 0);
        assert(did_connect);
        int peer = accept(listener, NULL, NULL);
        assert(peer >= 0);
        struct linger reset = { .l_onoff = 1, .l_linger = 0 };
        assert(setsockopt(peer, SOL_SOCKET, SO_LINGER, &reset, sizeof(reset)) == 0);
        close(peer);
        close(listener);
        ready.events = POLLIN;
        assert(poll(&ready, 1, 2000) == 1);
        char byte;
        assert(recv(fd, &byte, 1, 0) == -1 && errno == ECONNRESET);

        /* No SMB server/handshake needed: send a real queued SMB echo after
         * TCP reset. The unprotected production writev dies with SIGPIPE. */
        smb2->credits = 1;
        assert(smb2_echo_async(smb2, completed, NULL) == 0);
        errno = 0;
        assert(smb2_write_to_socket(smb2) == -1);
        assert(errno == EPIPE);
        assert(strstr(smb2_get_error(smb2), "Error when writing to socket"));
        smb2_destroy_context(smb2);
}

int main(void)
{
        pid_t child = fork();
        assert(child >= 0);
        if (child == 0) {
                reset_peer_write();
                _exit(0);
        }
        int status;
        assert(waitpid(child, &status, 0) == child);
        if (WIFSIGNALED(status)) {
                fprintf(stderr, "FAIL: production SMB write terminated with signal %d\n", WTERMSIG(status));
                return 1;
        }
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
        puts("PASS: reset SMB peer returns EPIPE through production writev without SIGPIPE termination");
        return 0;
}
