import doom.DoomMain;

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
 * The Doom framebuffer is 320x200 pixels (256KB as RGBA).
 */
public class CanvasRenderer {

    private static final long MIN_FRAME_INTERVAL_MS = 33; // ~30 FPS
    private long lastFrameTime = 0;
    private int frameCount = 0;

    private final DoomMain<?, ?> doom;

    public CanvasRenderer(DoomMain<?, ?> doom) {
        this.doom = doom;
    }

    /**
     * Native method: copies pixel data to Emscripten shared heap for Canvas rendering.
     * @param pixels ARGB pixel array from BufferedImage
     * @param width  framebuffer width (typically 320)
     * @param height framebuffer height (typically 200)
     */
    private static native void nativeRenderFrame(int[] pixels, int width, int height);

    public void renderFrame() {
        long now = System.currentTimeMillis();
        if (now - lastFrameTime < MIN_FRAME_INTERVAL_MS) {
            return;
        }
        lastFrameTime = now;
        frameCount++;

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

        } catch (Exception e) {
            if (frameCount <= 3) {
                System.out.println("[CanvasRenderer] Error: " + e.getMessage());
            }
        }
    }
}
