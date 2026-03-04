# JavaBox — Claude Code Guidance

See [AGENTS.md](./AGENTS.md) for detailed agent guidance including architecture, platform constraints, key decisions, and what not to do.

## Quick Reference

**Container build** (macOS with Rancher Desktop):
```sh
~/.rd/bin/docker build --platform linux/amd64 -t javabox:latest ./container/
```

**WASM conversion** — run once per Dockerfile change; output is reused:
```sh
./build/convert.sh ~/javabox-wasm          # auto-detects platform
./build/convert.sh --mode arm-mac ~/javabox-wasm  # Apple Silicon: Colima x86_64 VM (slow, local)
./build/convert.sh --mode linux /tmp/javabox-wasm  # Linux x86_64: native c2w (fast, CI)
```

**Serve locally**:
```sh
npx serve <output-dir> --config build/serve-config.json
```

**SDK type-check**:
```sh
cd packages/sdk && npx tsc --noEmit
```

## Direct WASM Build (OpenJDK Zero to Emscripten)

This is the fast path — compiles OpenJDK Zero interpreter directly to WASM, bypassing QEMU.

**Prerequisites**: Emscripten SDK (`emsdk`), host JDK 21

**Full build**:
```sh
./build/build-direct.sh ~/javabox-direct-wasm --with-doom
```

**Individual steps**:
```sh
./build/build-jvm-wasm.sh           # Compile OpenJDK HotSpot Zero → libjvm.a
./build/build-jdk-modules.sh        # jlink JDK class library on host
./build/build-doom-jar.sh           # Compile Doom Java sources on host
./build/link-direct-wasm.sh ~/out --with-doom  # Final emcc link → .js + .wasm + .data
```

**Serve and test**:
```sh
npx serve ~/javabox-direct-wasm --config build/serve-config.json
# Open http://localhost:3000/index.html?mode=direct
# Open http://localhost:3000/doom.html?mode=direct
```

## QEMU Build (Container2WASM — legacy)

**Container build** (macOS with Rancher Desktop):
```sh
~/.rd/bin/docker build --platform linux/amd64 -t javabox:latest ./container/
```

**WASM conversion** — run once per Dockerfile change; output is reused:
```sh
./build/convert.sh ~/javabox-wasm          # auto-detects platform
./build/convert.sh --mode arm-mac ~/javabox-wasm  # Apple Silicon: Colima x86_64 VM (slow, local)
./build/convert.sh --mode linux /tmp/javabox-wasm  # Linux x86_64: native c2w (fast, CI)
```

## Important Constraints

- Container (QEMU mode) must build with `--platform linux/amd64`
- c2w on Apple Silicon: use `--mode arm-mac` (Colima x86_64 VM); Go 1.24 GC crashes under QEMU user-mode emulation but works under full system emulation via Colima
- Use `~/.rd/bin/docker` (Rancher Desktop dockerd engine), not `nerdctl` or system docker
- WASM serving requires `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` headers
- Direct WASM mode uses `?mode=direct` URL parameter; default is QEMU mode
