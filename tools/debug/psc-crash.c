/* psc-crash: LD_PRELOAD crash reporter for the PlayStation Classic.
 *
 *   LD_PRELOAD=/media/lumen/debug/psc-crash.so PSC_CRASH_LOG=/media/lumen/logs/crash.log prog
 *
 * On SIGSEGV / SIGBUS / SIGILL / SIGFPE / SIGABRT it appends to PSC_CRASH_LOG (default
 * /tmp/psc-crash.log): the signal, fault address, the ARM registers, a scan of the stack
 * for words that point into executable mappings (a poor man's backtrace: resolve them
 * with addr2line against unstripped binaries), and /proc/self/maps. Each write is
 * fsync'ed: the USB stick is exFAT over FUSE and a file's size is only committed when it
 * is closed, so the log is opened and closed per report. Async-signal-safe calls only.
 * Then the default action runs (the exit status stays 139 etc.). */
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

#define MAXMAP 256
static struct { uintptr_t lo, hi; } g_x[MAXMAP];
static int g_nx;
static char g_path[256] = "/tmp/psc-crash.log";
static char g_altstack[64 * 1024];

static void put(int fd, const char *s) { if (write(fd, s, strlen(s)) < 0) {} }
static void hex(int fd, uintptr_t v)
{
   char b[11]; int i;
   b[0] = '0'; b[1] = 'x';
   for (i = 0; i < 8; i++) b[2 + i] = "0123456789abcdef"[(v >> (28 - 4 * i)) & 15];
   b[10] = 0; put(fd, b);
}
static void dec(int fd, long v)
{
   char b[24]; int i = 23; int neg = v < 0; unsigned long u = neg ? -v : v;
   b[i] = 0;
   do { b[--i] = '0' + u % 10; u /= 10; } while (u);
   if (neg) b[--i] = '-';
   put(fd, b + i);
}
static uintptr_t parse_hex(const char **p)
{
   uintptr_t v = 0;
   for (;; (*p)++) {
      char c = **p;
      if (c >= '0' && c <= '9') v = v * 16 + c - '0';
      else if (c >= 'a' && c <= 'f') v = v * 16 + c - 'a' + 10;
      else return v;
   }
}

/* executable mappings, re-read at crash time (libraries loaded later count too) */
static void load_maps(int out)
{
   static char buf[64 * 1024];
   int fd = open("/proc/self/maps", O_RDONLY), n, len = 0;
   if (fd < 0) return;
   while (len < (int)sizeof(buf) - 1 && (n = read(fd, buf + len, sizeof(buf) - 1 - len)) > 0) len += n;
   close(fd);
   buf[len] = 0;
   put(out, "--- maps\n");
   if (write(out, buf, len) < 0) {}
   g_nx = 0;
   {
      const char *p = buf;
      while (*p && g_nx < MAXMAP) {
         const char *q = p; uintptr_t lo, hi;
         lo = parse_hex(&q); if (*q == '-') q++; hi = parse_hex(&q);
         if (*q == ' ' && q[3] == 'x') { g_x[g_nx].lo = lo; g_x[g_nx].hi = hi; g_nx++; }
         while (*p && *p != '\n') p++;
         if (*p) p++;
      }
   }
}
static int is_code(uintptr_t a)
{
   int i;
   for (i = 0; i < g_nx; i++) if (a >= g_x[i].lo && a < g_x[i].hi) return 1;
   return 0;
}

static void handler(int sig, siginfo_t *si, void *ctx)
{
   ucontext_t *uc = (ucontext_t *)ctx;
   int fd = open(g_path, O_WRONLY | O_CREAT | O_APPEND, 0644), i, n = 0;
   if (fd >= 0) {
      const mcontext_t *m = &uc->uc_mcontext;
      const unsigned long *r = &m->arm_r0;
      uintptr_t *sp = (uintptr_t *)m->arm_sp;
      put(fd, "=== psc-crash: signal "); dec(fd, sig);
      put(fd, " code "); dec(fd, si->si_code);
      put(fd, " pid "); dec(fd, getpid());
      put(fd, " addr "); hex(fd, (uintptr_t)si->si_addr);
      put(fd, "\npc "); hex(fd, m->arm_pc);
      put(fd, " lr "); hex(fd, m->arm_lr);
      put(fd, " sp "); hex(fd, m->arm_sp);
      put(fd, " fp "); hex(fd, m->arm_fp);
      put(fd, "\n");
      for (i = 0; i <= 10; i++) { put(fd, "r"); dec(fd, i); put(fd, " "); hex(fd, r[i]); put(fd, i % 4 == 3 ? "\n" : " "); }
      put(fd, "\n");
      load_maps(fd);
      put(fd, "--- stack words pointing into code (newest first)\n");
      for (i = 0; i < 4096 && n < 48; i++) {
         uintptr_t w = sp[i];
         if (is_code(w)) { put(fd, "sp+"); dec(fd, i * 4); put(fd, " "); hex(fd, w); put(fd, "\n"); n++; }
      }
      put(fd, "=== end\n");
      fsync(fd); close(fd);
   }
   signal(sig, SIG_DFL);
   raise(sig);
}

__attribute__((constructor)) static void psc_crash_init(void)
{
   static const int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT };
   const char *p = getenv("PSC_CRASH_LOG");
   stack_t ss; struct sigaction sa; unsigned i;
   if (p && *p) { strncpy(g_path, p, sizeof(g_path) - 1); g_path[sizeof(g_path) - 1] = 0; }
   ss.ss_sp = g_altstack; ss.ss_size = sizeof(g_altstack); ss.ss_flags = 0;
   sigaltstack(&ss, NULL);
   memset(&sa, 0, sizeof(sa));
   sa.sa_sigaction = handler;
   sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
   sigemptyset(&sa.sa_mask);
   for (i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) sigaction(sigs[i], &sa, NULL);
}
