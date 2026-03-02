/* mini-init.c — Minimal init for JavaBox c2w snapshot.
 *
 * Runs as PID 2 under tini (PID 1). Mounts filesystems, brings up loopback,
 * sets up terminal, chroots into /oci/rootfs (container filesystem with
 * Alpine + jlinked JDK), then execs bash --login which starts JShell.
 *
 * Does NOT print "==========" — JShell's startup snippet does that AFTER
 * the JVM is loaded, so get-qemu-state captures a JShell-ready snapshot.
 *
 * Compiled inline in build/c2w-custom.Dockerfile during c2w conversion.
 * This file is kept in sync for reference/documentation.
 *
 * Build (standalone): x86_64-linux-gnu-gcc -O2 -static -o mini-init mini-init.c && strip mini-init
 */

#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <sys/socket.h>
#include <linux/if.h>
#include <errno.h>

#ifndef TIOCSCTTY
#define TIOCSCTTY 0x540E
#endif

/* UART diagnostics — polled I/O to port 0x3F8.
 * Unlike the kernel serial driver (interrupt-driven), polled I/O always works
 * because it doesn't depend on UART TX interrupt delivery. */
static inline int do_iopl(int level) { return syscall(SYS_iopl, level); }
static inline void outb(unsigned char val, unsigned short port) {
    __asm__ volatile("outb %0, %1" : : "a"(val), "Nd"(port));
}
static inline unsigned char inb(unsigned short port) {
    unsigned char val;
    __asm__ volatile("inb %1, %0" : "=a"(val) : "Nd"(port));
    return val;
}
static void uart_putc(char c) {
    while (!(inb(0x3FD) & 0x20)) ;
    outb((unsigned char)c, 0x3F8);
}
static void uart_puts(const char *s) {
    while (*s) { if (*s == '\n') uart_putc('\r'); uart_putc(*s++); }
}

static void do_mount(const char *src, const char *dst, const char *fstype,
                     unsigned long flags, const char *opts) {
    mkdir(dst, 0755);
    if (mount(src, dst, fstype, flags, opts) != 0) {
        uart_puts("[init] mount fail: ");
        uart_puts(dst);
        uart_puts("\n");
    }
}

int main(void)
{
    do_iopl(3);
    uart_puts("\n[init] JavaBox mini-init starting\n");

    /* 1. Mount base filesystems */
    do_mount("proc",     "/proc",    "proc",     0x0E, NULL);
    do_mount("sysfs",    "/sys",     "sysfs",    0x0E, NULL);
    do_mount("devtmpfs", "/dev",     "devtmpfs", 0x02, NULL);
    mkdir("/dev/pts", 0755);
    do_mount("devpts",   "/dev/pts", "devpts",   0, NULL);
    uart_puts("[init] base mounts done\n");

    /* 2. Bring up loopback — needed for JShell JDI execution provider */
    {
        int sock = socket(AF_INET, SOCK_DGRAM, 0);
        if (sock >= 0) {
            struct ifreq ifr;
            memset(&ifr, 0, sizeof(ifr));
            strcpy(ifr.ifr_name, "lo");
            ifr.ifr_flags = IFF_UP | IFF_LOOPBACK | IFF_RUNNING;
            ioctl(sock, SIOCSIFFLAGS, &ifr);
            close(sock);
        }
    }
    uart_puts("[init] loopback up\n");

    /* 3. Set up controlling terminal via /dev/console (= ttyS0) */
    setsid();
    int fd = open("/dev/console", O_RDWR);
    if (fd >= 0) {
        ioctl(fd, TIOCSCTTY, 1);
        dup2(fd, 0);
        dup2(fd, 1);
        dup2(fd, 2);
        if (fd > 2) close(fd);
    }
    uart_puts("[init] terminal ready\n");

    /* 4. Mount filesystems inside container rootfs (/oci/rootfs) */
    do_mount("proc",     "/oci/rootfs/proc",    "proc",     0x0E, NULL);
    do_mount("sysfs",    "/oci/rootfs/sys",     "sysfs",    0x0E, NULL);
    do_mount("devtmpfs", "/oci/rootfs/dev",     "devtmpfs", 0x02, NULL);
    mkdir("/oci/rootfs/dev/pts", 0755);
    do_mount("devpts",   "/oci/rootfs/dev/pts", "devpts",   0, NULL);
    do_mount("tmpfs",    "/oci/rootfs/tmp",     "tmpfs",    0x06, NULL);
    do_mount("tmpfs",    "/oci/rootfs/run",     "tmpfs",    0x06, NULL);
    /* Writable overlay for /workspace (ISO rootfs is read-only) */
    do_mount("tmpfs",    "/oci/rootfs/workspace", "tmpfs",  0x06, NULL);
    mkdir("/oci/rootfs/workspace/.javabox", 0755);
    /* .javabox dir for runtime metadata */
    /* /root writable for Java prefs */
    do_mount("tmpfs",    "/oci/rootfs/root",    "tmpfs",    0x06, NULL);
    uart_puts("[init] container mounts done\n");

    /* 5. chroot into container filesystem */
    if (chroot("/oci/rootfs") != 0) {
        uart_puts("[init] chroot FAILED\n");
        for (;;) pause();
    }
    chdir("/workspace");
    uart_puts("[init] chrooted to /oci/rootfs\n");

    /* 6. Set environment */
    clearenv();
    setenv("PATH", "/opt/jdk/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    setenv("JAVA_HOME", "/opt/jdk", 1);
    setenv("JAVA_TOOL_OPTIONS", "-Xms8m -Xmx64m -XX:+UseSerialGC -Xint", 1);
    setenv("TERM", "xterm", 1);
    setenv("HOME", "/root", 1);

    /* 7. exec bash — profile starts JShell, sentinel.jsh prints "==========" */
    uart_puts("[init] exec /bin/bash --login\n");
    char *argv[] = { "/bin/bash", "--login", NULL };
    execv("/bin/bash", argv);

    uart_puts("[init] bash failed, trying /bin/sh\n");
    argv[0] = "/bin/sh"; argv[1] = NULL;
    execv("/bin/sh", argv);

    uart_puts("[init] ALL EXEC FAILED\n");
    for (;;) pause();
}
