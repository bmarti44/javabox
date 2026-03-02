# packages/relay/Dockerfile
#
# Builds the c2w-net relay server for JavaBox's "delegate" networking mode.
# c2w-net forwards TCP/UDP packets from the browser's WASM guest to the real network.
#
# Build & run:
#   nerdctl build -t javabox-relay .
#   nerdctl run -d -p 8888:8888 --name javabox-relay javabox-relay
#
# Or via docker-compose:
#   nerdctl compose up -d

FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates

# Clone container2wasm and build only c2w-net
# Pin to the same version as convert.sh for consistency
ARG C2W_VERSION=v0.8.3
RUN git clone --depth=1 --branch ${C2W_VERSION} \
    https://github.com/container2wasm/container2wasm.git /src

WORKDIR /src

# Build c2w-net binary
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.version=${C2W_VERSION}" \
    -o /c2w-net \
    ./cmd/c2w-net/

# ─── Runtime image ────────────────────────────────────────────────────────────
FROM alpine:3.19

# Add CA certificates for outbound TLS connections
RUN apk add --no-cache ca-certificates

COPY --from=builder /c2w-net /usr/local/bin/c2w-net

# Default listen port — override with CMD or environment
EXPOSE 8888

# Run as non-root
RUN addgroup -S relay && adduser -S relay -G relay
USER relay

ENTRYPOINT ["/usr/local/bin/c2w-net"]
CMD ["--listen", "0.0.0.0:8888"]
