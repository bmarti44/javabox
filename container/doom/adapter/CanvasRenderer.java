import doom.DoomMain;
import doom.event_t;
import doom.evtype_t;
import g.Signals.ScanCode;

import java.awt.image.BufferedImage;
import java.awt.image.DataBufferInt;

/**
 * CanvasRenderer — Renders Doom framebuffer to browser Canvas via native method.
 *
 * Instead of converting pixels to ANSI terminal escape codes (TerminalRenderer),
 * this passes the raw pixel array to a JNI native function which copies it to
 * Emscripten's shared heap. The browser's requestAnimationFrame loop reads from
 * the shared heap and draws to an HTML Canvas using putImageData.
 *
 * Also handles keyboard input by polling a C-side key event queue (populated
 * by the browser via jvm_doom_key_event WASM export). This avoids creating
 * a Java thread for input, which is unreliable under Emscripten pthreads.
 *
 * The Doom framebuffer is 320x200 pixels (256KB as RGBA).
 */
public class CanvasRenderer {

    private static final long MIN_FRAME_INTERVAL_MS = 33; // ~30 FPS
    private long lastFrameTime = 0;
    private int frameCount = 0;

    private final DoomMain<?, ?> doom;
    private final ScanCode[] scanCodes;

    public CanvasRenderer(DoomMain<?, ?> doom) {
        this.doom = doom;
        this.scanCodes = ScanCode.values();
    }

    /**
     * Native method: copies pixel data to Emscripten shared heap for Canvas rendering.
     */
    private static native void nativeRenderFrame(int[] pixels, int width, int height);

    /**
     * Native method: polls key events from C-side queue.
     * Returns int[] of [type0, scancode0, type1, scancode1, ...] or null.
     * type: 1=keydown, 0=keyup. scancode: ScanCode ordinal.
     */
    private static native int[] nativePollKeyEvents();

    public void renderFrame() {
        long now = System.currentTimeMillis();
        if (now - lastFrameTime < MIN_FRAME_INTERVAL_MS) {
            return;
        }
        lastFrameTime = now;
        frameCount++;

        if (frameCount == 1) {
            System.out.println("[CanvasRenderer] First renderFrame() call");
        }

        // Poll and dispatch key events from C-side queue
        try {
            int[] events = nativePollKeyEvents();
            if (events != null) {
                for (int i = 0; i + 1 < events.length; i += 2) {
                    int type = events[i];
                    int scOrdinal = events[i + 1];
                    if (scOrdinal >= 0 && scOrdinal < scanCodes.length) {
                        ScanCode sc = scanCodes[scOrdinal];
                        if (sc != ScanCode.SC_NULL) {
                            evtype_t evType = (type == 1) ? evtype_t.ev_keydown : evtype_t.ev_keyup;
                            doom.PostEvent(new event_t.keyevent_t(evType, sc));
                        }
                    }
                }
            }
        } catch (Throwable e) {
            // Don't let input errors break rendering
        }

        try {
            BufferedImage img = (BufferedImage) doom.graphicSystem.getScreenImage();
            if (img == null) return;

            int w = img.getWidth();
            int h = img.getHeight();

            // Read pixel data directly — no Graphics2D needed.
            // Use DataBufferInt for INT_RGB/INT_ARGB (zero-copy), getRGB for other types.
            int[] pixels;
            if (img.getType() == BufferedImage.TYPE_INT_RGB || img.getType() == BufferedImage.TYPE_INT_ARGB) {
                pixels = ((DataBufferInt) img.getRaster().getDataBuffer()).getData();
            } else {
                pixels = img.getRGB(0, 0, w, h, null, 0, w);
            }

            nativeRenderFrame(pixels, w, h);

        } catch (Throwable e) {
            System.out.println("[CanvasRenderer] Error (frame " + frameCount + "): " + e.getClass().getName() + ": " + e.getMessage());
        }
    }
}
