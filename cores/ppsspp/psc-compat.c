/* Linked into ppsspp_libretro.so (hidden): calls of upstream's prebuilt FFmpeg
 * (ffmpeg/linux/armv7, built against glibc >= 2.28) that the console's glibc 2.24 lacks.
 * fcntl64 (glibc 2.28) is fcntl with a 64-bit off_t struct flock; FFmpeg only uses it
 * for F_SETFD / FD_CLOEXEC (libavutil/file_open.c), an int argument. */
#include <fcntl.h>
#include <stdarg.h>

__attribute__((visibility("hidden"))) int fcntl64(int fd, int cmd, ...)
{
   va_list ap;
   void *arg;
   va_start(ap, cmd);
   arg = va_arg(ap, void *);
   va_end(ap);
   return fcntl(fd, cmd, arg);
}
