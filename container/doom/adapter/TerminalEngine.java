import doom.DoomMain;
import mochadoom.Engine;
import mochadoom.Loggers;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * TerminalEngine — Headless entry point for Doom in a terminal.
 *
 * Supports snapshot warmup: call warmup() during c2w snapshot capture to
 * pre-initialize DoomMain, TerminalRenderer, frame callback, and doom thread.
 * All LambdaMetafactory/class-generation happens at build time (near-native speed).
 * At runtime, runDoom() just releases the latch to start the game loop.
 */
public class TerminalEngine {

    private static final Logger LOGGER = Loggers.getLogger(TerminalEngine.class.getName());

    // Pre-initialized state (set during snapshot warmup, consumed by runDoom)
    private static volatile DoomMain<?, ?> preloadedDoom = null;
    private static volatile CanvasRenderer preloadedRenderer = null;
    private static volatile Runnable preloadedCallback = null;
    private static volatile Thread preloadedDoomThread = null;
    private static volatile CountDownLatch startLatch = null;

    /**
     * Pre-initialize DoomMain and all runtime objects during c2w snapshot capture.
     * Heavy WAD/BSP/texture loading AND lambda/class generation happen here.
     * The initialized state is saved in the QEMU snapshot and restored at runtime.
     */
    public static void warmup() throws Exception {
        System.setProperty("java.awt.headless", "true");
        List<String> args = new ArrayList<>(Arrays.asList(
            "-iwad", "/opt/javabox/freedoom1.wad",
            "-config", "/opt/javabox/doom.cfg",
            "-nomusic",
            "-multiply", "1"
        ));
        LOGGER.log(Level.INFO, "Pre-initializing DoomMain (snapshot warmup)...");
        new Engine(args);
        DoomMain<?, ?> doom = new DoomMain<>();
        preloadedDoom = doom;

        // Pre-create renderer and callback (triggers LambdaMetafactory at build time)
        CanvasRenderer renderer = new CanvasRenderer(doom);
        preloadedRenderer = renderer;
        preloadedCallback = new Runnable() {
            public void run() { renderer.renderFrame(); }
        };

        // Note: do NOT create the DoomLoop thread here.
        // In QEMU snapshot mode, the thread + latch approach worked because
        // snapshot/restore preserved thread state. In direct WASM mode,
        // there's no snapshot — runDoom() creates the thread fresh.

        LOGGER.log(Level.INFO, "DoomMain pre-initialized successfully");
    }

    /**
     * Run Doom in-process. Blocks until the user sends quit command (\x01Q).
     *
     * Uses pre-initialized objects from warmup() if available (instant start).
     * Falls back to on-the-fly initialization if warmup() was not called.
     */
    public static void runDoom(String[] argv, BufferedReader stdin) {
        DoomMain<?, ?> doom = preloadedDoom;
        Runnable callback = preloadedCallback;
        preloadedDoom = null;
        preloadedRenderer = null;
        preloadedCallback = null;
        preloadedDoomThread = null;
        startLatch = null;

        if (doom == null) {
            // Fallback: initialize on the fly (slow under WASM Zero)
            System.setProperty("java.awt.headless", "true");
            List<String> args = new ArrayList<>(Arrays.asList(argv));
            if (!args.contains("-nomusic")) args.add("-nomusic");
            if (!args.contains("-multiply")) {
                args.add("-multiply");
                args.add("1");
            }
            try {
                new Engine(args);
                doom = new DoomMain<>();
            } catch (java.io.IOException e) {
                throw new RuntimeException("Failed to initialize DoomMain", e);
            }
            CanvasRenderer renderer = new CanvasRenderer(doom);
            callback = new Runnable() {
                public void run() { renderer.renderFrame(); }
            };
        }

        // Set frame callback and start the game loop.
        // Run setupLoop() on the current thread (CompileServer's pthread),
        // which is already a fully-initialized Emscripten worker.
        // Keyboard input is handled by CanvasRenderer.nativePollKeyEvents()
        // (C-side queue populated by browser via jvm_doom_key_event export),
        // so no separate input thread is needed.
        Engine.setFrameCallback(callback);

        try {
            System.out.println("JBOX_DOOM_START");
            System.out.flush();

            // Run game loop on current thread (reliable — already a working pthread)
            doom.setupLoop();

        } catch (Throwable t) {
            System.err.println("[DoomLoop] CRASHED: " + t.getClass().getName() + ": " + t.getMessage());
            t.printStackTrace(System.err);
        } finally {
            Engine.setFrameCallback(null);
            System.out.print("\033[2J\033[H\033[0m");
            System.out.flush();
        }
    }

    public static void main(String[] argv) {
        BufferedReader stdin = new BufferedReader(new InputStreamReader(System.in));
        runDoom(argv, stdin);
    }
}
