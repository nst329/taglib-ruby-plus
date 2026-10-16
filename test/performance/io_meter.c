// macOSのRuby/native双方の論理I/Oを同じ境界で計測する。ディスク実転送量ではない。
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <copyfile.h>
#include <stdio.h>
#include <unistd.h>
#include <stdint.h>
#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

static uint64_t reads, writes, peak;
static int enabled;
static _Thread_local int nested;

// 作業ディレクトリ直下の一時ファイルを観測する。sourceと最終outputは除外する。
static void observe(void) {
  const char *path = getenv("PLUS_IO_DIRECTORY");
  if (!path) return;
  DIR *dir = opendir(path);
  if (!dir) return;
  uint64_t total = 0;
  struct dirent *entry;
  while ((entry = readdir(dir))) {
    if (entry->d_name[0] == '.' || !strcmp(entry->d_name, "source.mp4") ||
        !strcmp(entry->d_name, "output.mp4")) continue;
    char name[PATH_MAX];
    snprintf(name, sizeof(name), "%s/%s", path, entry->d_name);
    struct stat st;
    if (!stat(name, &st) && S_ISREG(st.st_mode)) total += st.st_size;
  }
  closedir(dir);
  if (total > peak) peak = total;
}

void plus_meter_start(void) { reads = writes = peak = 0; enabled = 1; }
void plus_meter_stop(void) { enabled = 0; }
uint64_t plus_meter_read(void) { return reads; }
uint64_t plus_meter_write(void) { return writes; }
uint64_t plus_meter_peak(void) { return peak; }

#define INTERPOSE(replacement, original) \
  __attribute__((used)) static struct { const void *a; const void *b; } pair_##original \
  __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&original };

#define WRAP_RW(name, args, call, counter, after) \
  static ssize_t measured_##name args { \
    int active = enabled && nested == 0; ++nested; \
    ssize_t result = name call; \
    if (active && result > 0) { counter += result; after; } \
    --nested; return result; \
  } \
  INTERPOSE(measured_##name, name)

WRAP_RW(read, (int fd, void *b, size_t n), (fd, b, n), reads, (void)0)
WRAP_RW(pread, (int fd, void *b, size_t n, off_t o), (fd, b, n, o), reads, (void)0)
WRAP_RW(write, (int fd, const void *b, size_t n), (fd, b, n), writes, observe())
WRAP_RW(pwrite, (int fd, const void *b, size_t n, off_t o), (fd, b, n, o), writes, observe())
WRAP_RW(readv, (int fd, const struct iovec *v, int n), (fd, v, n), reads, (void)0)
WRAP_RW(writev, (int fd, const struct iovec *v, int n), (fd, v, n), writes, observe())

static size_t measured_fread(void *b, size_t s, size_t n, FILE *f) {
  int active = enabled && nested == 0; ++nested;
  size_t result = fread(b, s, n, f);
  if (active) reads += result * s;
  --nested; return result;
}
INTERPOSE(measured_fread, fread)
static size_t measured_fwrite(const void *b, size_t s, size_t n, FILE *f) {
  int active = enabled && nested == 0; ++nested;
  size_t result = fwrite(b, s, n, f);
  if (active) { writes += result * s; observe(); }
  --nested; return result;
}
INTERPOSE(measured_fwrite, fwrite)
static int measured_fclose(FILE *f) {
  int active = enabled && nested == 0; ++nested;
  int result = fclose(f);
  if (active) observe();
  --nested; return result;
}
INTERPOSE(measured_fclose, fclose)
static int measured_fcopyfile(int from, int to, copyfile_state_t state, copyfile_flags_t flags) {
  int active = enabled && nested == 0; ++nested;
  int result = fcopyfile(from, to, state, flags);
  struct stat st;
  if (active && !result && (flags & COPYFILE_DATA) && !fstat(from, &st)) {
    reads += st.st_size; writes += st.st_size; observe();
  }
  --nested; return result;
}
INTERPOSE(measured_fcopyfile, fcopyfile)
