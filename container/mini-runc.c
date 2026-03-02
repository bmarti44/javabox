/* mini-runc.c — Minimal OCI bundle runner for JavaBox/QEMU-WASM
 *
 * Replaces the 15 MB Go runc binary inside rootfs.bin.  Under QEMU TCG
 * (TCI slow-path interpreter), Go's runtime cold-start takes many minutes.
 * This ~50 KB static C binary does the same essential work in seconds:
 *
 *   1. Parse -b BUNDLE from argv  →  read BUNDLE/config.json
 *   2. Extract root.path, process.{cwd,args,env}
 *   3. Bind-mount /proc /sys /dev into the container rootfs
 *   4. chroot into the container rootfs
 *   5. Set environment from config
 *   6. execv the container process
 *
 * Intentionally SKIPPED (irrelevant in the QEMU-sandbox context):
 *   cgroups, seccomp, user/pid/net/uts namespaces, rootfs pivoting,
 *   signal proxying, container lifecycle management.
 *
 * Build (x86_64 Linux static, requires Alpine or musl-cross toolchain):
 *   gcc -O2 -static -o mini-runc mini-runc.c && strip mini-runc
 *
 * See build/compile-mini-runc.sh for the Docker-based cross-compile helper.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>

/* ── tunables ────────────────────────────────────────────────────────────── */
#define CFG_MAX   (512 * 1024)   /* 512 KB – ample for any OCI config.json   */
#define STR_MAX   4096
#define ARG_CAP   128
#define ENV_CAP   512

static char cfg_buf[CFG_MAX];

/* ── minimal JSON helpers ────────────────────────────────────────────────── */

/*
 * jstr – find the first occurrence of  "key":"value"  at or after *buf,
 * copy the value (with backslash-escapes honoured) into dst[0..n-1].
 * Returns a pointer to the character after the closing '"', or NULL.
 */
static const char *jstr(const char *buf,
                         const char *key,
                         char *dst, size_t n)
{
    char pat[256];
    snprintf(pat, sizeof pat, "\"%s\":\"", key);
    const char *p = strstr(buf, pat);
    if (!p) return NULL;
    p += strlen(pat);
    size_t i = 0;
    while (*p && *p != '"' && i < n - 1) {
        if (*p == '\\' && p[1]) p++;   /* skip escape char, copy next */
        dst[i++] = *p++;
    }
    dst[i] = '\0';
    return (*p == '"') ? p + 1 : NULL;
}

/*
 * jarr_str – find "key":[ at or after *buf and extract every quoted string
 * element into out[0..maxn-1] (strdup'd).  Returns element count.
 */
static int jarr_str(const char *buf,
                    const char *key,
                    char **out, int maxn)
{
    char pat[256];
    snprintf(pat, sizeof pat, "\"%s\":[", key);
    const char *p = strstr(buf, pat);
    if (!p) return 0;
    p += strlen(pat);   /* now points at first char inside '[' */
    int n = 0;
    while (n < maxn && *p) {
        /* skip to next '"' or end-of-array */
        while (*p && *p != '"' && *p != ']') p++;
        if (!*p || *p == ']') break;
        p++;   /* skip opening '"' */
        char tmp[STR_MAX];
        size_t i = 0;
        while (*p && i < STR_MAX - 1) {
            if (*p == '\\' && p[1]) { p++; tmp[i++] = *p++; continue; }
            if (*p == '"') { p++; break; }
            tmp[i++] = *p++;
        }
        tmp[i] = '\0';
        out[n++] = strdup(tmp);
        /* advance past optional ',' separator */
        while (*p && *p != '"' && *p != ']' && *p != ',') p++;
        if (*p == ',') p++;
    }
    return n;
}

/* ── mount helper ────────────────────────────────────────────────────────── */

/*
 * try_bind – bind-mount src to "<rootfs><rel>".
 * Failures are non-fatal: logged to stderr and ignored.
 */
static void try_bind(const char *src,
                     const char *rootfs,
                     const char *rel)
{
    char dst[STR_MAX];
    snprintf(dst, sizeof dst, "%s%s", rootfs, rel);
    if (mount(src, dst, NULL, MS_BIND | MS_REC, NULL) != 0)
        fprintf(stderr,
                "mini-runc: bind %s → %s: %s (ignored)\n",
                src, dst, strerror(errno));
}

/* ── main ────────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    /* ── 1. Parse arguments ────────────────────────────────────────────── */
    /* Accept the runc sub-command form: run [-b BUNDLE] [-d] [--] ID      */
    const char *bundle = "/run/bundle";
    for (int i = 1; i < argc - 1; i++) {
        if (strcmp(argv[i], "-b") == 0 ||
            strcmp(argv[i], "--bundle") == 0) {
            bundle = argv[++i];
        }
    }

    /* ── 2. Read config.json ───────────────────────────────────────────── */
    char cfgpath[STR_MAX];
    snprintf(cfgpath, sizeof cfgpath, "%s/config.json", bundle);

    int fd = open(cfgpath, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "mini-runc: open %s: %s\n",
                cfgpath, strerror(errno));
        return 1;
    }
    ssize_t nr = read(fd, cfg_buf, sizeof cfg_buf - 1);
    close(fd);
    if (nr <= 0) {
        fprintf(stderr, "mini-runc: read %s: %s\n",
                cfgpath, strerror(errno));
        return 1;
    }
    cfg_buf[nr] = '\0';

    /* ── 3. Extract rootfs path ────────────────────────────────────────── */
    char rootfs[STR_MAX] = "/oci/rootfs";
    {
        const char *root_sec = strstr(cfg_buf, "\"root\":{");
        if (root_sec)
            jstr(root_sec, "path", rootfs, sizeof rootfs);
    }

    /* ── 4. Extract process fields ─────────────────────────────────────── */
    const char *proc_sec = strstr(cfg_buf, "\"process\":{");

    char cwd[STR_MAX] = "/";
    if (proc_sec)
        jstr(proc_sec, "cwd", cwd, sizeof cwd);

    char *args[ARG_CAP + 1];
    int nargs = 0;
    if (proc_sec) {
        const char *a = strstr(proc_sec, "\"args\":[");
        if (a) nargs = jarr_str(a, "args", args, ARG_CAP);
    }
    args[nargs] = NULL;

    if (nargs == 0) {
        fprintf(stderr, "mini-runc: no args found in %s\n", cfgpath);
        return 1;
    }

    char *envp[ENV_CAP + 1];
    int nenv = 0;
    if (proc_sec) {
        const char *e = strstr(proc_sec, "\"env\":[");
        if (e) nenv = jarr_str(e, "env", envp, ENV_CAP);
    }
    envp[nenv] = NULL;

    /* ── 5. Bind-mount essential filesystems into the container rootfs ─── */
    try_bind("/proc", rootfs, "/proc");
    try_bind("/sys",  rootfs, "/sys");
    try_bind("/dev",  rootfs, "/dev");

    /* ── 6. chroot into the container rootfs ──────────────────────────── */
    if (chroot(rootfs) != 0) {
        fprintf(stderr, "mini-runc: chroot(%s): %s\n",
                rootfs, strerror(errno));
        return 1;
    }

    /* ── 7. Set working directory ──────────────────────────────────────── */
    if (chdir(cwd) != 0) {
        fprintf(stderr,
                "mini-runc: chdir(%s): %s — falling back to /\n",
                cwd, strerror(errno));
        chdir("/");
    }

    /* ── 8. Replace the process environment ───────────────────────────── */
    clearenv();
    for (int i = 0; i < nenv; i++) {
        char *eq = strchr(envp[i], '=');
        if (eq) {
            char name[STR_MAX];
            size_t nlen = (size_t)(eq - envp[i]);
            if (nlen < sizeof name) {
                memcpy(name, envp[i], nlen);
                name[nlen] = '\0';
                setenv(name, eq + 1, 1);
            }
        }
        free(envp[i]);
    }

    /* ── 9. Execute the container process ─────────────────────────────── */
    execv(args[0], args);

    /* execv only returns on failure */
    fprintf(stderr, "mini-runc: execv(%s): %s\n",
            args[0], strerror(errno));
    return 127;
}
