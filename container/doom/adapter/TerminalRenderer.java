import doom.DoomMain;

import java.awt.image.BufferedImage;
import java.awt.image.DataBufferInt;

/**
 * TerminalRenderer — Renders Doom framebuffer to terminal using ANSI escape codes.
 *
 * Converts the 320x200 game screen to 80x50 terminal cells using Unicode
 * half-block characters. Each cell represents a 4x4 pixel area: the upper
 * half-block uses fg color (top 2 rows averaged) and bg color (bottom 2 rows).
 *
 * Uses 24-bit ANSI color: \033[38;2;R;G;Bm (fg) + \033[48;2;R;G;Bm (bg)
 * Delta rendering: only emits changed cells.
 */
public class TerminalRenderer {

    private static final int TERM_COLS = 80;
    private static final int TERM_ROWS = 50;
    private static final int SRC_WIDTH = 320;
    private static final int SRC_HEIGHT = 200;
    private static final int CELL_W = SRC_WIDTH / TERM_COLS;   // 4
    private static final int CELL_H = SRC_HEIGHT / TERM_ROWS;  // 4

    // Unicode upper half block: top half is fg color, bottom half is bg color
    private static final String HALF_BLOCK = "\u2580";

    // Frame rate limiting
    private static final long MIN_FRAME_INTERVAL_MS = 66; // ~15 FPS
    private long lastFrameTime = 0;

    // Previous frame for delta rendering (packed RGB: upper 3 bytes fg, lower 3 bytes bg per cell)
    private final long[] prevFrame = new long[TERM_COLS * TERM_ROWS];
    private boolean firstFrame = true;

    private final DoomMain<?, ?> doom;

    public TerminalRenderer(DoomMain<?, ?> doom) {
        this.doom = doom;
    }

    private int frameCount = 0;

    public void renderFrame() {
        long now = System.currentTimeMillis();
        if (now - lastFrameTime < MIN_FRAME_INTERVAL_MS) {
            return;
        }
        lastFrameTime = now;
        frameCount++;

        try {
            BufferedImage img = (BufferedImage) doom.graphicSystem.getScreenImage();
            if (img == null) {
                if (frameCount <= 3) {
                    System.out.println("[RENDER] frame " + frameCount + ": screen image is null");
                }
                return;
            }
            if (frameCount <= 3) {
                System.out.println("[RENDER] frame " + frameCount + ": " + img.getWidth() + "x" + img.getHeight() + " type=" + img.getType());
            }

            int imgW = img.getWidth();
            int imgH = img.getHeight();

            // Read pixel data directly — no Graphics2D needed for terminal rendering.
            // Use DataBufferInt for INT_RGB/INT_ARGB (zero-copy), getRGB for other types.
            int[] pixels;
            int pixW = imgW, pixH = imgH;
            if (img.getType() == BufferedImage.TYPE_INT_RGB || img.getType() == BufferedImage.TYPE_INT_ARGB) {
                pixels = ((DataBufferInt) img.getRaster().getDataBuffer()).getData();
            } else {
                pixels = img.getRGB(0, 0, imgW, imgH, null, 0, imgW);
            }

            // Calculate cell dimensions based on actual image size
            int cellW = pixW / TERM_COLS;
            int cellH = pixH / TERM_ROWS;
            if (cellW < 1) cellW = 1;
            if (cellH < 1) cellH = 1;
            int halfCellH = cellH / 2;
            if (halfCellH < 1) halfCellH = 1;

            StringBuilder sb = new StringBuilder(4096);

            // Hide cursor during rendering
            sb.append("\033[?25l");

            int changedCells = 0;

            for (int row = 0; row < TERM_ROWS; row++) {
                for (int col = 0; col < TERM_COLS; col++) {
                    // Average colors for top half (fg) and bottom half (bg) of cell
                    int fgR = 0, fgG = 0, fgB = 0;
                    int bgR = 0, bgG = 0, bgB = 0;
                    int fgCount = 0, bgCount = 0;

                    int startX = col * cellW;
                    int startY = row * cellH;

                    // Top half of cell -> fg color
                    for (int py = startY; py < startY + halfCellH && py < pixH; py++) {
                        for (int px = startX; px < startX + cellW && px < pixW; px++) {
                            int rgb = pixels[py * pixW + px];
                            fgR += (rgb >> 16) & 0xFF;
                            fgG += (rgb >> 8) & 0xFF;
                            fgB += rgb & 0xFF;
                            fgCount++;
                        }
                    }

                    // Bottom half of cell -> bg color
                    for (int py = startY + halfCellH; py < startY + cellH && py < pixH; py++) {
                        for (int px = startX; px < startX + cellW && px < pixW; px++) {
                            int rgb = pixels[py * pixW + px];
                            bgR += (rgb >> 16) & 0xFF;
                            bgG += (rgb >> 8) & 0xFF;
                            bgB += rgb & 0xFF;
                            bgCount++;
                        }
                    }

                    if (fgCount > 0) { fgR /= fgCount; fgG /= fgCount; fgB /= fgCount; }
                    if (bgCount > 0) { bgR /= bgCount; bgG /= bgCount; bgB /= bgCount; }

                    // Pack into long for delta comparison
                    long packed = ((long)(fgR & 0xFF) << 40) | ((long)(fgG & 0xFF) << 32) |
                                  ((long)(fgB & 0xFF) << 24) | ((long)(bgR & 0xFF) << 16) |
                                  ((long)(bgG & 0xFF) << 8)  | (bgB & 0xFF);

                    int idx = row * TERM_COLS + col;
                    if (!firstFrame && prevFrame[idx] == packed) {
                        continue; // No change, skip
                    }
                    prevFrame[idx] = packed;
                    changedCells++;

                    // Move cursor to position (1-indexed)
                    sb.append("\033[").append(row + 1).append(';').append(col + 1).append('H');

                    // Set fg color (top half) and bg color (bottom half)
                    sb.append("\033[38;2;").append(fgR).append(';').append(fgG).append(';').append(fgB).append('m');
                    sb.append("\033[48;2;").append(bgR).append(';').append(bgG).append(';').append(bgB).append('m');
                    sb.append(HALF_BLOCK);
                }
            }

            // Reset colors and show cursor
            sb.append("\033[0m\033[?25h");

            firstFrame = false;

            if (changedCells > 0) {
                // Append newline to flush Emscripten's line-buffered stdout
                // (cursor position is set explicitly per cell, so the newline is harmless)
                sb.append('\n');
                System.out.print(sb.toString());
                System.out.flush();
            }

        } catch (Exception e) {
            // Print rendering errors for debugging (but keep running)
            System.out.println("[RENDER] " + e.getClass().getName() + ": " + e.getMessage());
            e.printStackTrace(System.out);
        }
    }
}
