# JavaBox Relay Server

The relay server enables full TCP/UDP networking for Java code running inside the browser container. Without it, only HTTP/S (via the browser Fetch API) is available.

## How It Works

`c2w-net` (from [container2wasm](https://github.com/container2wasm/container2wasm)) listens on a WebSocket port. The browser's WASM guest connects to it and forwards all network packets over that WebSocket. `c2w-net` then makes the real TCP/UDP connections on behalf of the guest.

```
Java code (in browser QEMU guest)
  └─ QEMU virtio-net
      └─ container2wasm WASM layer
          └─ WebSocket → ws://relay-host:8888
                              └─ c2w-net (relay server)
                                    └─ Real TCP/UDP on the internet
```

## Quick Start

### With Rancher Desktop (nerdctl)

```bash
# Build and start the relay
cd packages/relay
nerdctl compose up -d

# Check it's running
nerdctl compose ps
nerdctl compose logs
```

### Without compose

```bash
# Build
nerdctl build -t javabox-relay .

# Run
nerdctl run -d -p 8888:8888 --name javabox-relay javabox-relay

# Logs
nerdctl logs -f javabox-relay
```

### Alternative: Use the pre-built binary directly

```bash
# Download c2w-net for Linux
wget https://github.com/container2wasm/container2wasm/releases/download/v0.8.3/container2wasm-v0.8.3-linux-amd64.tar.gz
tar xzf container2wasm-v0.8.3-linux-amd64.tar.gz
./c2w-net --listen 0.0.0.0:8888
```

## SDK Configuration

Once the relay is running, configure the SDK to use it:

```typescript
const container = await JavaContainer.boot({
  wasmBaseUrl: '/wasm/',
  networking: {
    mode: 'delegate',
    relayUrl: 'ws://localhost:8888',  // or wss:// for TLS
  },
});
```

## Production Deployment

### Security Checklist

The relay forwards arbitrary TCP/UDP traffic. Before deploying publicly:

- [ ] Place behind a reverse proxy (nginx/caddy) with TLS (`wss://`)
- [ ] Add authentication (API key in query param or WebSocket header)
- [ ] Set up rate limiting (connections per IP, bytes per minute)
- [ ] Restrict destination ports to only what your users need
- [ ] Block access to internal/private IP ranges
- [ ] Monitor connections and set up alerts for unusual traffic

### systemd (Linux production)

```bash
sudo cp /path/to/c2w-net /usr/local/bin/
sudo tee /etc/systemd/system/javabox-relay.service <<'EOF'
[Unit]
Description=JavaBox Network Relay
After=network.target

[Service]
ExecStart=/usr/local/bin/c2w-net --listen 0.0.0.0:8888
Restart=always
User=nobody
LimitNOFILE=65535

[Install]
WantedBy=multi-use.target
EOF

sudo systemctl enable --now javabox-relay
sudo systemctl status javabox-relay
```

### TLS with nginx

```nginx
server {
    listen 443 ssl;
    server_name relay.example.com;

    ssl_certificate /etc/ssl/certs/relay.crt;
    ssl_certificate_key /etc/ssl/private/relay.key;

    location / {
        proxy_pass http://127.0.0.1:8888;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
    }
}
```

Then use `relayUrl: 'wss://relay.example.com'` in the SDK config.
