/*
 * jvm-main.c — Entry point for JavaBox direct WASM mode.
 *
 * Boots JVM, runs CompileServer.main() which blocks on stdin.
 * Provides jvm_stdin_write() for browser→JVM stdin communication via
 * a SharedArrayBuffer ring buffer with Atomics.wait/notify blocking.
 *
 * The JVM runs in a Web Worker (via PROXY_TO_PTHREAD), so blocking
 * reads on stdin are fine. The browser main thread calls jvm_stdin_write()
 * which writes to the ring buffer and wakes the worker.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <jni.h>
#include <sys/stat.h>
#include <emscripten.h>
#include <emscripten/threading.h>

/*
 * Stub native methods for java.desktop AWT classes.
 * In headless WASM mode, we don't have real AWT natives. These stubs
 * prevent UnsatisfiedLinkError when AWT class static initializers
 * call initIDs() or other native methods after loading libawt.
 *
 * Doom uses BufferedImage + DataBufferInt for in-memory rendering,
 * so we need stubs for the entire image class hierarchy.
 */

/* java.awt core classes */
JNIEXPORT void JNICALL Java_java_awt_AWTEvent_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_Color_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_Component_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_Container_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_Cursor_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_Dimension_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_Event_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_Font_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_FontMetrics_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_Frame_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_Insets_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_KeyboardFocusManager_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_Rectangle_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_Toolkit_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_Window_initIDs(JNIEnv *e, jclass c) {}

/* java.awt.event classes */
JNIEXPORT void JNICALL Java_java_awt_event_InputEvent_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_event_KeyEvent_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_event_MouseEvent_initIDs(JNIEnv *e, jclass c) {}

/* java.awt.image classes */
JNIEXPORT void JNICALL Java_java_awt_image_BufferedImage_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_image_ColorModel_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_image_IndexColorModel_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_image_Kernel_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_image_Raster_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_image_SampleModel_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_java_awt_image_SinglePixelPackedSampleModel_initIDs(JNIEnv *e, jclass c) {}

/* sun.awt.image classes */
JNIEXPORT void JNICALL Java_sun_awt_image_BufImgSurfaceData_initIDs(JNIEnv *e, jclass c, jclass icm, jclass icmcd) {}
JNIEXPORT void JNICALL Java_sun_awt_image_ByteComponentRaster_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_sun_awt_image_BytePackedRaster_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_sun_awt_image_GifImageDecoder_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_sun_awt_image_ImageRepresentation_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_sun_awt_image_IntegerComponentRaster_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_sun_awt_image_ShortComponentRaster_initIDs(JNIEnv *e, jclass c) {}

/* sun.java2d classes (SurfaceData used by BufImgSurfaceData) */
JNIEXPORT void JNICALL Java_sun_java2d_Disposer_initIDs(JNIEnv *e, jclass c) {}
JNIEXPORT void JNICALL Java_sun_java2d_SurfaceData_initIDs(JNIEnv *e, jclass c) {}

/*
 * Ring buffer for stdin communication.
 *
 * Layout in SharedArrayBuffer (4096 bytes):
 *   [0]    write_pos (int32, used with Atomics)
 *   [1]    read_pos  (int32)
 *   [2]    signal    (int32, used with Atomics.wait/notify)
 *   [3..1023] reserved
 *   [1024..4095] data ring buffer (3072 bytes)
 *
 * Writer (browser main thread): writes data, updates write_pos, notifies signal.
 * Reader (JVM worker thread): reads data, updates read_pos, waits on signal.
 */

#define RING_BUF_OFFSET 1024
#define RING_BUF_SIZE   3072
#define WRITE_POS_IDX   0
#define READ_POS_IDX    1
#define SIGNAL_IDX      2

static volatile int32_t* stdin_buf = NULL;
/* Set to 1 by browser JS to enable ring buffer stdin (bypasses Emscripten FS).
 * In Node.js, stays 0 so stdin goes through process.stdin normally. */
static int use_ring_buffer_stdin = 0;

/* Initialize the stdin ring buffer (called once at startup) */
static void init_stdin_buffer(void) {
    stdin_buf = (volatile int32_t*)aligned_alloc(4, 4096);
    memset((void*)stdin_buf, 0, 4096);
}

/*
 * Read one byte from the stdin ring buffer, blocking if empty.
 * Called from the JVM worker thread (handleRead in io_util_md.c for fd 0).
 * Non-static so it can be linked from libjava.a.
 */
int stdin_read_byte(void) {
    if (!stdin_buf) return EOF;

    for (;;) {
        int32_t wp = __atomic_load_n(&stdin_buf[WRITE_POS_IDX], __ATOMIC_ACQUIRE);
        int32_t rp = __atomic_load_n(&stdin_buf[READ_POS_IDX], __ATOMIC_RELAXED);

        if (rp != wp) {
            /* Data available */
            int offset = RING_BUF_OFFSET + (rp % RING_BUF_SIZE);
            unsigned char byte = ((volatile unsigned char*)stdin_buf)[offset];
            int32_t new_rp = (rp + 1) % RING_BUF_SIZE;
            __atomic_store_n(&stdin_buf[READ_POS_IDX], new_rp, __ATOMIC_RELEASE);
            return byte;
        }

        /* Buffer empty — wait for signal from writer */
        emscripten_futex_wait((volatile void*)&stdin_buf[SIGNAL_IDX], 0, INFINITY);
    }
}

/*
 * Exported function: write data to the JVM's stdin.
 * Called from browser JavaScript: Module.ccall('jvm_stdin_write', null, ['string'], ['text\n'])
 */
EMSCRIPTEN_KEEPALIVE
void jvm_stdin_write(const char* data, int len) {
    if (!stdin_buf || !data || len <= 0) return;

    for (int i = 0; i < len; i++) {
        /* Spin-wait if buffer is full (very unlikely with 3KB buffer) */
        for (;;) {
            int32_t wp = __atomic_load_n(&stdin_buf[WRITE_POS_IDX], __ATOMIC_RELAXED);
            int32_t rp = __atomic_load_n(&stdin_buf[READ_POS_IDX], __ATOMIC_ACQUIRE);
            int32_t used = (wp - rp + RING_BUF_SIZE) % RING_BUF_SIZE;
            if (used < RING_BUF_SIZE - 1) {
                int offset = RING_BUF_OFFSET + (wp % RING_BUF_SIZE);
                ((volatile unsigned char*)stdin_buf)[offset] = (unsigned char)data[i];
                int32_t new_wp = (wp + 1) % RING_BUF_SIZE;
                __atomic_store_n(&stdin_buf[WRITE_POS_IDX], new_wp, __ATOMIC_RELEASE);
                break;
            }
            /* Buffer full — yield and retry */
            emscripten_thread_sleep(1);
        }
    }

    /* Wake the reader thread */
    __atomic_store_n(&stdin_buf[SIGNAL_IDX], 1, __ATOMIC_RELEASE);
    emscripten_futex_wake((volatile void*)&stdin_buf[SIGNAL_IDX], 1);
    __atomic_store_n(&stdin_buf[SIGNAL_IDX], 0, __ATOMIC_RELAXED);
}

/*
 * Convenience wrapper: write a null-terminated string to the JVM's stdin.
 * Called from browser: Module.ccall('jvm_stdin_write_string', null, ['string'], ['text\n'])
 */
EMSCRIPTEN_KEEPALIVE
void jvm_stdin_write_string(const char* data) {
    if (!data) return;
    jvm_stdin_write(data, strlen(data));
}

/* Enable ring buffer stdin (called from browser JS before sending data) */
EMSCRIPTEN_KEEPALIVE
void jvm_enable_ring_buffer_stdin(void) {
    use_ring_buffer_stdin = 1;
}

/* Check if ring buffer stdin is enabled (for handleRead in io_util_md.c) */
int jvm_use_ring_buffer_stdin(void) {
    return use_ring_buffer_stdin;
}

/* Debug helpers — check ring buffer state from JavaScript */
EMSCRIPTEN_KEEPALIVE
int jvm_debug_stdin_state(void) {
    /* Returns: -1 if stdin_buf is NULL, otherwise write_pos * 10000 + read_pos */
    if (!stdin_buf) return -1;
    int32_t wp = __atomic_load_n(&stdin_buf[WRITE_POS_IDX], __ATOMIC_ACQUIRE);
    int32_t rp = __atomic_load_n(&stdin_buf[READ_POS_IDX], __ATOMIC_ACQUIRE);
    return wp * 10000 + rp;
}

/* Simple counter to verify ccall works */
static int debug_counter = 0;
EMSCRIPTEN_KEEPALIVE
int jvm_debug_ping(void) {
    return ++debug_counter;
}

/*
 * Custom stdin for Emscripten's FS.
 * Called when the JVM reads from fd 0 (stdin).
 */
EM_JS(void, setup_stdin_hook, (void* buf_ptr), {
    if (typeof Module === 'undefined') return;

    /* Store buffer pointer for stdin_get */
    Module._stdin_buf_ptr = buf_ptr;

    /* Override stdin to read from our ring buffer */
    var RING_BUF_OFFSET = 1024;
    var RING_BUF_SIZE = 3072;

    Module['stdin'] = function() {
        var buf = Module._stdin_buf_ptr;
        if (!buf) return null;

        /* Spin with futex wait until data is available */
        for (;;) {
            var wp = Atomics.load(HEAP32, (buf >> 2) + 0);
            var rp = Atomics.load(HEAP32, (buf >> 2) + 1);

            if (rp !== wp) {
                /* Data available — read one byte */
                var offset = RING_BUF_OFFSET + (rp % RING_BUF_SIZE);
                var byte = HEAPU8[buf + offset];
                var new_rp = (rp + 1) % RING_BUF_SIZE;
                Atomics.store(HEAP32, (buf >> 2) + 1, new_rp);
                return byte;
            }

            /* Wait for signal from writer */
            Atomics.wait(HEAP32, (buf >> 2) + 2, 0);
        }
    };
});

/*
 * Doom Canvas Rendering — shared frame buffer for JVM → Browser pixel transfer.
 *
 * The JVM (running in a Web Worker via PROXY_TO_PTHREAD) writes pixel data here.
 * The browser's requestAnimationFrame loop reads it and draws to an HTML Canvas.
 * Since Emscripten pthreads share heap memory (backed by SharedArrayBuffer),
 * both threads access the same memory. A simple atomic flag synchronizes access.
 */
static uint8_t* doom_framebuf = NULL;
static int doom_frame_width = 0;
static int doom_frame_height = 0;
static volatile int32_t doom_frame_seq = 0;  /* Frame sequence number */

/*
 * JNI native method: CanvasRenderer.nativeRenderFrame(int[] pixels, int width, int height)
 * Called from the DoomLoop thread. Copies ARGB pixel data to shared heap as RGBA.
 */
JNIEXPORT void JNICALL
Java_CanvasRenderer_nativeRenderFrame(JNIEnv *env, jclass cls,
                                       jintArray pixels, jint width, jint height) {
    int total = width * height;
    int buf_size = total * 4;

    /* Allocate frame buffer on first call */
    if (doom_framebuf == NULL || doom_frame_width != width || doom_frame_height != height) {
        if (doom_framebuf) free(doom_framebuf);
        doom_framebuf = (uint8_t*)malloc(buf_size);
        doom_frame_width = width;
        doom_frame_height = height;
    }

    jint *src = (*env)->GetIntArrayElements(env, pixels, NULL);
    if (!src) return;

    /* Convert ARGB (Java BufferedImage format) to RGBA (Canvas ImageData format) */
    for (int i = 0; i < total; i++) {
        jint argb = src[i];
        doom_framebuf[i*4+0] = (argb >> 16) & 0xFF; /* R */
        doom_framebuf[i*4+1] = (argb >> 8)  & 0xFF; /* G */
        doom_framebuf[i*4+2] =  argb        & 0xFF; /* B */
        doom_framebuf[i*4+3] = 0xFF;                 /* A (fully opaque) */
    }

    (*env)->ReleaseIntArrayElements(env, pixels, src, JNI_ABORT);

    /* Increment frame sequence to signal new frame */
    __atomic_add_fetch(&doom_frame_seq, 1, __ATOMIC_RELEASE);
}

/*
 * Exported functions for JavaScript to access frame data.
 * Called from the browser main thread in requestAnimationFrame.
 */
EMSCRIPTEN_KEEPALIVE
int jvm_doom_frame_ptr(void) {
    return (int)(intptr_t)doom_framebuf;
}

EMSCRIPTEN_KEEPALIVE
int jvm_doom_frame_width(void) {
    return doom_frame_width;
}

EMSCRIPTEN_KEEPALIVE
int jvm_doom_frame_height(void) {
    return doom_frame_height;
}

EMSCRIPTEN_KEEPALIVE
int jvm_doom_frame_seq(void) {
    return __atomic_load_n(&doom_frame_seq, __ATOMIC_ACQUIRE);
}

/* Create essential directories in MEMFS before JVM starts.
 * Uses EM_JS to run on the main thread to avoid PROXY_TO_PTHREAD issues. */
EM_JS(void, create_fs_dirs, (void), {
    try { FS.mkdir('/tmp'); } catch(e) {}
    try { FS.mkdir('/tmp/hsperfdata_root'); } catch(e) {}
    try { FS.mkdir('/root'); } catch(e) {}

});

int main(int argc, char** argv) {
    /* Create /tmp and other directories the JVM needs */
    create_fs_dirs();

    /* Set environment variables (Doom ConfigManager needs HOME) */
    setenv("HOME", "/root", 1);
    setenv("USER", "root", 1);

    /* Initialize stdin ring buffer before JVM starts */
    init_stdin_buffer();
    setup_stdin_hook((void*)stdin_buf);

    JavaVMInitArgs vm_args;
    JavaVMOption options[20];
    int nOptions = 0;

    options[nOptions++].optionString = "-Djava.home=/opt/jdk";
    options[nOptions++].optionString = "-Xint";
    options[nOptions++].optionString = "-Xmx128m";
    options[nOptions++].optionString = "-Xss512k";
    options[nOptions++].optionString = "-Xshare:off";
    options[nOptions++].optionString = "-XX:+UseSerialGC";
    options[nOptions++].optionString = "-Djava.awt.headless=true";
    options[nOptions++].optionString = "-XX:-UsePerfData";
    options[nOptions++].optionString = "-XX:+ReduceSignalUsage";
    options[nOptions++].optionString = "-Xlog:all=off";
    options[nOptions++].optionString = "-XX:-OmitStackTraceInFastThrow";
    options[nOptions++].optionString = "-Djava.class.path=/opt/javabox:/opt/javabox/doom.jar";
    options[nOptions++].optionString = "-Duser.home=/root";
    options[nOptions++].optionString = "-Duser.dir=/root";

    vm_args.version = JNI_VERSION_21;
    vm_args.nOptions = nOptions;
    vm_args.options = options;
    vm_args.ignoreUnrecognized = JNI_FALSE;

    JavaVM* vm;
    JNIEnv* env;

    jint res = JNI_CreateJavaVM(&vm, (void**)&env, &vm_args);
    if (res != JNI_OK) {
        fprintf(stderr, "ERROR: JNI_CreateJavaVM failed with code %d\n", (int)res);
        return 1;
    }

    /*
     * Register CanvasRenderer native methods via JNI RegisterNatives.
     *
     * CanvasRenderer is loaded from doom.jar by the application classloader.
     * OpenJDK's native method resolution for app classes only searches libraries
     * loaded via System.loadLibrary() — which doesn't apply in a statically-linked
     * WASM binary. Additionally, WASM enforces strict function pointer type checking
     * on indirect calls, so going through the static symbol table (which declares
     * all functions as void(void)) can cause type mismatches.
     *
     * RegisterNatives bypasses both issues: it stores the correctly-typed function
     * pointer directly in the Method's native_function field, so the JVM calls
     * the C function directly with the right signature.
     *
     * We register early (before CompileServer.main) but CanvasRenderer hasn't been
     * loaded yet. That's fine — FindClass will fail harmlessly, and we'll retry
     * via a JNI callback when Doom actually starts (see doom_register_natives below).
     */
    {
        jclass canvasRendererClass = (*env)->FindClass(env, "CanvasRenderer");
        if (canvasRendererClass != NULL) {
            JNINativeMethod methods[] = {
                {"nativeRenderFrame", "([III)V",
                 (void*)Java_CanvasRenderer_nativeRenderFrame}
            };
            (*env)->RegisterNatives(env, canvasRendererClass, methods, 1);
        }
        /* Clear any ClassNotFoundException — CanvasRenderer may not be loaded yet */
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
        }
    }

    /* Find and run CompileServer.main() */
    jclass cls = (*env)->FindClass(env, "CompileServer");
    if (cls == NULL) {
        fprintf(stderr, "ERROR: Could not find CompileServer class\n");
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionDescribe(env);
        }
        (*vm)->DestroyJavaVM(vm);
        return 1;
    }

    jmethodID mainMethod = (*env)->GetStaticMethodID(env, cls, "main", "([Ljava/lang/String;)V");
    if (mainMethod == NULL) {
        fprintf(stderr, "ERROR: Could not find CompileServer.main()\n");
        (*vm)->DestroyJavaVM(vm);
        return 1;
    }

    /* Create empty String[] args */
    jclass stringClass = (*env)->FindClass(env, "java/lang/String");
    jobjectArray args_array = (*env)->NewObjectArray(env, 0, stringClass, NULL);

    /* This call blocks — CompileServer.main() loops on stdin */
    (*env)->CallStaticVoidMethod(env, cls, mainMethod, args_array);

    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
    }

    (*vm)->DestroyJavaVM(vm);
    return 0;
}
