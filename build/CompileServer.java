import javax.tools.*;
import java.io.*;
import java.lang.reflect.*;
import java.net.*;
import java.util.*;

/**
 * CompileServer — Persistent Java compilation daemon for JavaBox Direct WASM mode.
 *
 * Uses in-memory compilation (ForwardingJavaFileManager) to bypass NIO filesystem
 * writes which fail on Emscripten MEMFS. Source and class bytes stay entirely in memory.
 *
 * Protocol:
 *   Input:  "JBOX_COMPILE <ClassName>\n<source lines>\nJBOX_END\n"
 *   Input:  "JBOX_PING\n"
 *   Output: "<compile errors or program output>\nJBOX_EXIT:<code>\n"
 *   Output: "JBOX_PONG\n"
 */
public class CompileServer {
    private static JavaCompiler compiler;

    /** In-memory source file for the compiler. */
    static class MemorySource extends SimpleJavaFileObject {
        private final String code;
        MemorySource(String name, String code) {
            super(URI.create("string:///" + name.replace('.', '/') + Kind.SOURCE.extension), Kind.SOURCE);
            this.code = code;
        }
        @Override
        public CharSequence getCharContent(boolean ignoreEncodingErrors) {
            return code;
        }
    }

    /** In-memory class file that captures compiler output bytes. */
    static class MemoryClassFile extends SimpleJavaFileObject {
        final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        MemoryClassFile(String name) {
            super(URI.create("mem:///" + name.replace('.', '/') + Kind.CLASS.extension), Kind.CLASS);
        }
        @Override
        public OutputStream openOutputStream() {
            return bytes;
        }
        byte[] getBytes() { return bytes.toByteArray(); }
    }

    /** File manager that intercepts .class output and stores it in memory. */
    static class MemoryFileManager extends ForwardingJavaFileManager<StandardJavaFileManager> {
        final Map<String, MemoryClassFile> outputs = new HashMap<>();

        MemoryFileManager(StandardJavaFileManager fm) { super(fm); }

        @Override
        public JavaFileObject getJavaFileForOutput(Location location, String className,
                JavaFileObject.Kind kind, FileObject sibling) {
            MemoryClassFile mcf = new MemoryClassFile(className);
            outputs.put(className, mcf);
            return mcf;
        }
    }

    /** ClassLoader that loads classes from in-memory byte arrays. */
    static class MemoryClassLoader extends ClassLoader {
        private final Map<String, byte[]> classes;
        MemoryClassLoader(Map<String, byte[]> classes, ClassLoader parent) {
            super(parent);
            this.classes = classes;
        }
        @Override
        protected Class<?> findClass(String name) throws ClassNotFoundException {
            byte[] b = classes.get(name);
            if (b != null) return defineClass(name, b, 0, b.length);
            throw new ClassNotFoundException(name);
        }
    }

    public static void main(String[] args) throws Exception {
        compiler = ToolProvider.getSystemJavaCompiler();
        if (compiler == null) {
            System.err.println("[CompileServer] ERROR: No Java compiler available");
            System.exit(1);
        }

        warmup();

        System.out.println("JBOX_PONG");
        System.out.flush();

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
        }
    }

    private static void warmup() {
        try {
            String code = "class _W { public static void main(String[] a) {} }";
            StandardJavaFileManager sfm = compiler.getStandardFileManager(null, null, null);
            MemoryFileManager mfm = new MemoryFileManager(sfm);
            JavaCompiler.CompilationTask task = compiler.getTask(
                null, mfm, null, null, null,
                Collections.singletonList(new MemorySource("_W", code)));
            task.call();

            Map<String, byte[]> classBytes = new HashMap<>();
            for (Map.Entry<String, MemoryClassFile> entry : mfm.outputs.entrySet()) {
                classBytes.put(entry.getKey(), entry.getValue().getBytes());
            }
            MemoryClassLoader loader = new MemoryClassLoader(classBytes, CompileServer.class.getClassLoader());
            Class<?> cls = loader.loadClass("_W");
            Method m = cls.getMethod("main", String[].class);
            m.setAccessible(true);
            m.invoke(null, (Object) new String[0]);
            mfm.close();
        } catch (Exception e) {
            System.err.println("[CompileServer] WARN: warmup failed: " + e.getMessage());
        }

        // Skip Doom warmup in direct WASM mode — let runDoom() initialize on demand
        // (warmup created a preloaded DoomMain that caused DoomLoop NPE)
    }

    private static void handleDoom(BufferedReader in) {
        try {
            // Load TerminalEngine from doom.jar (on classpath) via reflection
            Class<?> te = Class.forName("TerminalEngine");
            // TerminalEngine.runDoom(String[] args, BufferedReader in)
            Method runDoom = te.getMethod("runDoom", String[].class, BufferedReader.class);
            String[] doomArgs = new String[] {
                "-iwad", "/opt/javabox/freedoom1.wad",
                "-config", "/opt/javabox/doom.cfg"
            };
            runDoom.invoke(null, doomArgs, in);
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
            StringBuilder src = new StringBuilder();
            String line;
            while ((line = in.readLine()) != null) {
                if (line.trim().equals("JBOX_END")) break;
                src.append(line).append('\n');
            }

            StandardJavaFileManager sfm = compiler.getStandardFileManager(null, null, null);
            MemoryFileManager mfm = new MemoryFileManager(sfm);
            DiagnosticCollector<JavaFileObject> diag = new DiagnosticCollector<>();

            JavaCompiler.CompilationTask task = compiler.getTask(
                null, mfm, diag, null, null,
                Collections.singletonList(new MemorySource(className, src.toString())));
            boolean success = task.call();

            for (Diagnostic<? extends JavaFileObject> d : diag.getDiagnostics()) {
                System.out.println(d.toString());
            }

            if (!success) {
                System.out.println("JBOX_EXIT:1");
                System.out.flush();
                mfm.close();
                return;
            }

            Map<String, byte[]> classBytes = new HashMap<>();
            for (Map.Entry<String, MemoryClassFile> entry : mfm.outputs.entrySet()) {
                classBytes.put(entry.getKey(), entry.getValue().getBytes());
            }

            MemoryClassLoader loader = new MemoryClassLoader(classBytes, CompileServer.class.getClassLoader());
            Class<?> cls = loader.loadClass(className);
            Method mainMethod = cls.getMethod("main", String[].class);
            mainMethod.setAccessible(true);
            mainMethod.invoke(null, (Object) new String[0]);
            System.out.flush();
            System.out.println("JBOX_EXIT:0");
            mfm.close();

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
