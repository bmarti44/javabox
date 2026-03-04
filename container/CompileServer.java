import javax.tools.*;
import java.io.*;
import java.lang.reflect.*;
import java.net.*;

/**
 * CompileServer — Persistent Java compilation daemon for JavaBox.
 *
 * Runs as the main process after boot. The JVM loads once during c2w snapshot
 * capture (takes minutes under WASM TCG), then survives QEMU snapshot restore
 * for instant compilation.
 *
 * Protocol:
 *   Input:  "JBOX_COMPILE <ClassName>\n<source lines>\nJBOX_END\n"
 *   Input:  "JBOX_PING\n"  (liveness check)
 *   Output: "<compile errors or program output>\nJBOX_EXIT:<code>\n"
 *   Output: "JBOX_PONG\n"  (liveness response)
 *
 * Uses simple BufferedReader (no JLine/threads) to survive snapshot restore.
 * Compiles with javax.tools (in-process) and runs via URLClassLoader (in-process)
 * to avoid JVM startup overhead for each compilation.
 */
public class CompileServer {
    private static JavaCompiler compiler;

    public static void main(String[] args) throws Exception {
        compiler = ToolProvider.getSystemJavaCompiler();
        if (compiler == null) {
            System.err.println("[CompileServer] ERROR: No Java compiler available");
            System.exit(1);
        }

        // Warmup: compile + run a dummy class to pre-load all compiler/classloader classes
        warmup();

        // Signal ready for c2w snapshot capture
        System.out.print("==========");
        System.out.flush();

        // Main loop: read commands from stdin (survives QEMU snapshot restore)
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
        String line;
        while ((line = in.readLine()) != null) {
            line = line.trim();
            if (line.startsWith("JBOX_COMPILE ")) {
                handleCompile(in, line.substring(13).trim());
            } else if (line.equals("JBOX_DOOM")) {
                handleDoom(in);
            } else if (line.equals("JBOX_PING")) {
                System.out.println("JBOX_PONG");
                System.out.flush();
            }
            // Ignore other input (flush newlines, blank lines, terminal echo, etc.)
        }
    }

    private static void warmup() {
        try {
            File f = new File("/tmp/_W.java");
            try (FileWriter w = new FileWriter(f)) {
                w.write("class _W { public static void main(String[] a) {} }");
            }
            compiler.run(null, OutputStream.nullOutputStream(), OutputStream.nullOutputStream(), "-d", "/tmp", f.getPath());
            URLClassLoader loader = new URLClassLoader(new URL[] { new File("/tmp/").toURI().toURL() });
            Class<?> cls = loader.loadClass("_W");
            Method m = cls.getMethod("main", String[].class);
            m.setAccessible(true);
            m.invoke(null, (Object) new String[0]);
            loader.close();
            new File("/tmp/_W.class").delete();
            f.delete();
        } catch (Exception e) {
            System.err.println("[CompileServer] WARN: warmup failed: " + e.getMessage());
        }

        // Pre-initialize Doom (heavy WAD/BSP/texture loading at snapshot time).
        // This runs during c2w snapshot capture at near-native speed (~3s).
        // The initialized DoomMain is saved in the snapshot and restored at runtime,
        // making JBOX_DOOM -> JBOX_DOOM_START near-instant.
        try {
            TerminalEngine.warmup();
        } catch (Exception e) {
            System.err.println("[CompileServer] WARN: doom warmup failed: " + e.getMessage());
            e.printStackTrace(System.err);
        }
    }

    private static void handleDoom(BufferedReader in) {
        try {
            // Run Doom in-process using TerminalEngine.
            // TerminalEngine.runDoom blocks reading stdin for input events
            // until the user sends \x01Q (quit). The Doom game loop runs
            // in a daemon thread and dies when runDoom returns.
            String[] args = new String[] {
                "-iwad", "/opt/javabox/freedoom1.wad",
                "-config", "/opt/javabox/doom.cfg"
            };
            TerminalEngine.runDoom(args, in);
            System.out.println("JBOX_EXIT:0");
        } catch (Exception e) {
            System.err.println("[CompileServer] Doom error: " + e.getMessage());
            e.printStackTrace(System.err);
            System.out.println("JBOX_EXIT:1");
        }
        System.out.flush();
    }

    private static void handleCompile(BufferedReader in, String className) {
        try {
            // Read source until JBOX_END
            StringBuilder src = new StringBuilder();
            String line;
            while ((line = in.readLine()) != null) {
                if (line.trim().equals("JBOX_END")) break;
                src.append(line).append('\n');
            }

            // Write source to /tmp
            File srcFile = new File("/tmp/" + className + ".java");
            try (FileWriter w = new FileWriter(srcFile)) { w.write(src.toString()); }

            // Compile in-process (use -d /tmp to explicitly set output dir,
            // works around NIO Files.newOutputStream issues on Emscripten MEMFS)
            ByteArrayOutputStream compileOut = new ByteArrayOutputStream();
            int rc = compiler.run(null, compileOut, compileOut, "-d", "/tmp", srcFile.getPath());
            String compileOutput = compileOut.toString().trim();
            if (!compileOutput.isEmpty()) {
                System.out.println(compileOutput);
            }

            if (rc != 0) {
                System.out.println("JBOX_EXIT:" + rc);
                System.out.flush();
                return;
            }

            // Run in-process via URLClassLoader (avoids new JVM startup)
            URLClassLoader loader = new URLClassLoader(
                new URL[] { new File("/tmp/").toURI().toURL() },
                CompileServer.class.getClassLoader()
            );
            Class<?> cls = loader.loadClass(className);
            Method mainMethod = cls.getMethod("main", String[].class);
            mainMethod.setAccessible(true);
            mainMethod.invoke(null, (Object) new String[0]);
            System.out.flush();
            System.out.println("JBOX_EXIT:0");
            loader.close();

        } catch (InvocationTargetException e) {
            Throwable cause = e.getCause();
            if (cause != null) {
                cause.printStackTrace(System.err);
            }
            System.err.flush();
            System.out.println("JBOX_EXIT:1");
        } catch (Exception e) {
            System.err.println("ERROR: " + e.getMessage());
            System.err.flush();
            System.out.println("JBOX_EXIT:1");
        }
        System.out.flush();
    }
}
