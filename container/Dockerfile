# JavaBox container image — Alpine Linux + jlinked OpenJDK 21
# Target: linux/amd64 (required for container2wasm --to-js QEMU Wasm emulation)
# Build with: ~/.rd/bin/docker build --platform linux/amd64 -t javabox:latest ./container/

# ── Stage 1: jlink minimal JDK + CDS archive ────────────────────────────────
FROM --platform=linux/amd64 alpine:3.21 AS builder
RUN apk add --no-cache openjdk21-jdk binutils bash

# jlink: jdk.jshell + useful extras + java.desktop (needed for Doom's BufferedImage)
RUN /usr/lib/jvm/java-21-openjdk/bin/jlink \
    --module-path /usr/lib/jvm/java-21-openjdk/jmods \
    --add-modules jdk.jshell,java.net.http,jdk.crypto.ec,java.sql,\
jdk.unsupported,java.instrument,jdk.httpserver,jdk.net,java.desktop \
    --output /opt/jdk \
    --no-man-pages --no-header-files \
    --strip-debug --compress=zip-6

# CDS: generate classlist from jshell with a warmup compile (loads compiler
# classes too), then dump shared archive.
# classes.jsa at default location is auto-detected by JVM (-Xshare:auto).
RUN printf 'class _W{public static void main(String[] a){System.out.println("w");}}\n_W.main(null);\n/exit\n' \
    | /opt/jdk/bin/jshell --execution local \
    -J-XX:DumpLoadedClassList=/tmp/jshell.classlist \
    -J-Xms8m -J-Xmx64m -J-XX:+UseSerialGC \
    2>/dev/null \
  && /opt/jdk/bin/java -Xshare:dump \
    -XX:SharedClassListFile=/tmp/jshell.classlist \
    -XX:SharedArchiveFile=/opt/jdk/lib/server/classes.jsa \
  || echo "WARN: CDS failed (non-fatal)"

# ── Stage 2: Build Doom ──────────────────────────────────────────────────────
FROM --platform=linux/amd64 alpine:3.21 AS doom-builder
RUN apk add --no-cache openjdk21-jdk curl unzip

# Copy mocha-doom source + adapter
COPY doom/src/ /tmp/doom-src/
COPY doom/adapter/ /tmp/doom-adapter/
COPY doom/doom.cfg /tmp/doom.cfg

# Download Freedoom WAD (open-source Doom content, ~17MB)
RUN curl -fsSL https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip \
    -o /tmp/freedoom.zip \
  && unzip -j /tmp/freedoom.zip 'freedoom-0.13.0/freedoom1.wad' -d /tmp/ \
  && rm /tmp/freedoom.zip

# Compile all mocha-doom + adapter sources into doom.jar
# -J-Xint: interpreter mode avoids JIT crashes under QEMU emulation (Apple Silicon)
RUN mkdir -p /tmp/doom-classes \
  && find /tmp/doom-src /tmp/doom-adapter -name '*.java' > /tmp/doom-sources.txt \
  && javac -J-Xint -J-Xms8m -J-Xmx128m -J-XX:+UseSerialGC \
    -d /tmp/doom-classes \
    -sourcepath /tmp/doom-src:/tmp/doom-adapter \
    -Xlint:none \
    @/tmp/doom-sources.txt \
  && cd /tmp/doom-classes \
  && jar -J-Xint cf /tmp/doom.jar . \
  && echo "doom.jar built: $(du -h /tmp/doom.jar | cut -f1)"

# ── Stage 3: minimal runtime ────────────────────────────────────────────────
FROM --platform=linux/amd64 alpine:3.21
RUN apk add --no-cache bash
COPY --from=builder /opt/jdk /opt/jdk

ENV JAVA_HOME=/opt/jdk
ENV PATH="$JAVA_HOME/bin:$PATH"
ENV JAVA_TOOL_OPTIONS="-Xms8m -Xmx64m -XX:+UseSerialGC -Xint"

RUN java -version && javac -version
RUN mkdir -p /workspace/.javabox /opt/javabox

# Install Doom assets first (CompileServer depends on doom.jar for TerminalEngine)
COPY --from=doom-builder /tmp/doom.jar /opt/javabox/doom.jar
COPY --from=doom-builder /tmp/freedoom1.wad /opt/javabox/freedoom1.wad
COPY --from=doom-builder /tmp/doom.cfg /opt/javabox/doom.cfg

# Compile CompileServer — persistent compilation daemon.
# JVM loads once during c2w snapshot, survives restore for instant compilation.
# Needs doom.jar on classpath for TerminalEngine reference.
COPY CompileServer.java /opt/javabox/CompileServer.java
RUN javac -cp /opt/javabox/doom.jar -d /opt/javabox /opt/javabox/CompileServer.java \
    && rm /opt/javabox/CompileServer.java

# Login profile: starts CompileServer which prints "==========" sentinel after
# warming up the compiler. c2w captures snapshot with JVM already loaded.
# After restore, CompileServer reads commands from stdin (no JLine = survives restore).
RUN printf '#!/bin/bash\nexport JAVA_HOME=/opt/jdk\nexport PATH="$JAVA_HOME/bin:$PATH"\nexport JAVA_TOOL_OPTIONS="-Xms8m -Xmx64m -XX:+UseSerialGC -Xint"\ntouch /workspace/.javabox/.ready\nexec java -cp /opt/javabox:/opt/javabox/doom.jar CompileServer\n' \
    > /etc/profile.d/zz-javabox.sh \
    && chmod +x /etc/profile.d/zz-javabox.sh

WORKDIR /workspace
CMD ["/bin/bash", "--login"]
