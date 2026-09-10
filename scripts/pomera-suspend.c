/*
 * pomera-suspend.c - Hardware Suspend Trigger Utility for Pomera DM250 (OpenBSD)
 *
 * Copyright (c) 2026 Masahiko OHKUBO and Pomera DM250 OpenBSD Project Contributors
 * SPDX-License-Identifier: MIT
 *
 * Communicates with /dev/apm using APM_IOC_SUSPEND to enter Rockchip RK3128 deep idle suspend.
 * Wakes up on interrupt (Power key, Lid switch, or Keyboard event).
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <machine/apmvar.h>
#include <errno.h>
#include <string.h>

static void usage(const char *progname) {
    fprintf(stderr, "Usage: %s [-f] [-h]\n", progname);
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  -f    Force immediate suspend without countdown\n");
    fprintf(stderr, "  -h    Show this help message\n");
}

int main(int argc, char *argv[]) {
    int force = 0;
    int opt;
    int fd;

    while ((opt = getopt(argc, argv, "fh")) != -1) {
        switch (opt) {
            case 'f':
                force = 1;
                break;
            case 'h':
            default:
                usage(argv[0]);
                return (opt == 'h') ? 0 : 1;
        }
    }

    /* Check root privileges */
    if (geteuid() != 0) {
        fprintf(stderr, "❌ Error: Root privilege is required to access /dev/apm.\n");
        fprintf(stderr, "   Please run with doas:\n");
        fprintf(stderr, "     doas %s\n", argv[0]);
        return 1;
    }

    printf(">> Flushing filesystem caches (sync)...\n");
    sync();
    sync();

    if (!force) {
        printf(">> Entering suspend in 1 second (Press Power button or open/close lid to wake)...\n");
        sleep(1);
    } else {
        printf(">> Entering suspend immediately...\n");
    }

    /* Open APM device */
    fd = open("/dev/apm", O_WRONLY);
    if (fd < 0) {
        fd = open("/dev/apmctl", O_WRONLY);
    }

    if (fd < 0) {
        fprintf(stderr, "❌ Failed to open /dev/apm or /dev/apmctl: %s\n", strerror(errno));
        return 1;
    }

    /* Trigger hardware suspend ioctl */
    if (ioctl(fd, APM_IOC_SUSPEND, NULL) < 0) {
        fprintf(stderr, "❌ ioctl(APM_IOC_SUSPEND) failed: %s\n", strerror(errno));
        close(fd);
        return 1;
    }

    close(fd);

    printf(">> ☀️ Woke up from suspend successfully!\n");
    return 0;
}
