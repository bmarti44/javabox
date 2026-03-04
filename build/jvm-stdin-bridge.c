/**
 * jvm-stdin-bridge.c — SharedArrayBuffer ring buffer for stdin (browser → JVM worker)
 *
 * When the JVM runs in a Web Worker via PROXY_TO_PTHREAD, the main browser
 * thread cannot directly write to the worker's stdin. This bridge provides:
 *
 *   1. jvm_stdin_write(data, len) — called from main thread (JavaScript)
 *      Writes bytes into a SharedArrayBuffer ring buffer.
 *
 *   2. Custom read() override — called by JVM's BufferedReader.readLine()
 *      Blocks the worker thread via Atomics.wait until data is available.
 *
 * The ring buffer is 64KB, which is plenty for CompileServer protocol messages.
 *
 * This file is compiled with emcc and linked into the final WASM module.
 */

#include <emscripten.h>
#include <emscripten/threading.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>

// Ring buffer size — must be power of 2
#define RING_SIZE (64 * 1024)
#define RING_MASK (RING_SIZE - 1)

// Ring buffer state — all in shared memory
static uint8_t ring_buffer[RING_SIZE] __attribute__((aligned(4)));
static volatile int32_t ring_write_pos = 0;  // Written by main thread
static volatile int32_t ring_read_pos = 0;   // Read by JVM worker thread

// Mutex/condvar for blocking read
static pthread_mutex_t ring_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ring_cond = PTHREAD_COND_INITIALIZER;

/**
 * Write data to the stdin ring buffer.
 * Called from JavaScript via Module.ccall('jvm_stdin_write', ...).
 * Thread-safe: called from main thread, read from worker thread.
 */
EMSCRIPTEN_KEEPALIVE
int jvm_stdin_write(const char* data, int len) {
  if (len <= 0 || data == NULL) return 0;

  pthread_mutex_lock(&ring_mutex);

  int written = 0;
  for (int i = 0; i < len; i++) {
    int next_write = (ring_write_pos + 1) & RING_MASK;

    // Check if buffer is full
    if (next_write == ring_read_pos) {
      // Buffer full — drop remaining data
      break;
    }

    ring_buffer[ring_write_pos] = (uint8_t)data[i];
    ring_write_pos = next_write;
    written++;
  }

  // Wake the reader if it's waiting
  pthread_cond_signal(&ring_cond);
  pthread_mutex_unlock(&ring_mutex);

  return written;
}

/**
 * Write a null-terminated string to stdin.
 * Convenience wrapper for JavaScript.
 */
EMSCRIPTEN_KEEPALIVE
int jvm_stdin_write_string(const char* str) {
  if (str == NULL) return 0;
  return jvm_stdin_write(str, strlen(str));
}

/**
 * Read up to `count` bytes from the ring buffer.
 * Blocks if no data is available (called from JVM worker thread).
 * Returns number of bytes read, or 0 on timeout.
 */
static int ring_read(char* buf, int count) {
  if (count <= 0) return 0;

  pthread_mutex_lock(&ring_mutex);

  // Wait for data
  while (ring_read_pos == ring_write_pos) {
    pthread_cond_wait(&ring_cond, &ring_mutex);
  }

  // Read available data
  int read_count = 0;
  while (read_count < count && ring_read_pos != ring_write_pos) {
    buf[read_count++] = (char)ring_buffer[ring_read_pos];
    ring_read_pos = (ring_read_pos + 1) & RING_MASK;
  }

  pthread_mutex_unlock(&ring_mutex);
  return read_count;
}

/**
 * Query how many bytes are available in the ring buffer (non-blocking).
 */
EMSCRIPTEN_KEEPALIVE
int jvm_stdin_available(void) {
  int avail = (ring_write_pos - ring_read_pos) & RING_MASK;
  return avail;
}

/**
 * Override for stdin read — Emscripten's FS will call this.
 * We install this as the read handler for fd 0 (stdin).
 */
EMSCRIPTEN_KEEPALIVE
int jvm_stdin_read(int fd, char* buf, int count) {
  if (fd != 0) {
    // Not stdin — shouldn't happen, but fall through
    return -1;
  }
  return ring_read(buf, count);
}
