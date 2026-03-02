/**
 * networking.ts — Network mode configuration for JavaBox containers.
 *
 * container2wasm supports two networking modes, selected via URL query parameter
 * when the page is loaded (or when the WASM module is initialized):
 *
 *   ?net=browser         — HTTP/S via browser Fetch API (c2w-net-proxy.wasm)
 *   ?net=delegate=ws://  — Full TCP/UDP via c2w-net relay server
 *
 * This module validates config and handles relay connectivity checks.
 */

export type NetworkingConfig =
  | { mode: 'browser' }
  | { mode: 'delegate'; relayUrl: string }
  | { mode: 'none' };

/**
 * Validate the networking configuration at SDK init time.
 * Throws with a descriptive message if the config is invalid.
 */
export function validateNetworkConfig(config: NetworkingConfig): void {
  if (config.mode === 'delegate') {
    if (!config.relayUrl) {
      throw new Error('Delegate networking requires relayUrl');
    }
    if (!config.relayUrl.startsWith('ws://') && !config.relayUrl.startsWith('wss://')) {
      throw new Error(
        `relayUrl must start with ws:// or wss:// (got: ${config.relayUrl})`,
      );
    }
  }
}

/**
 * Build the ?net=... query parameter value for the given networking config.
 * This is appended to the URL or passed to the Emscripten Module config.
 *
 * container2wasm reads window.location.search to determine network mode.
 */
export function buildNetQueryParam(config: NetworkingConfig): string | null {
  switch (config.mode) {
    case 'browser':
      return 'browser';
    case 'delegate':
      return `delegate=${config.relayUrl}`;
    case 'none':
      return null;
  }
}

/**
 * Test whether the relay server is reachable by attempting a WebSocket connection.
 * Returns true if the WebSocket handshake succeeds within 5 seconds.
 *
 * NOTE: A successful handshake means the relay is listening; it does not
 * guarantee the relay is authenticated or will forward all protocols.
 */
export async function checkRelayConnectivity(relayUrl: string): Promise<boolean> {
  return new Promise((resolve) => {
    let settled = false;
    const settle = (result: boolean) => {
      if (!settled) {
        settled = true;
        resolve(result);
      }
    };

    const timeout = setTimeout(() => {
      ws.close();
      settle(false);
    }, 5000);

    let ws: WebSocket;
    try {
      ws = new WebSocket(relayUrl);
      ws.onopen = () => {
        clearTimeout(timeout);
        ws.close();
        settle(true);
      };
      ws.onerror = () => {
        clearTimeout(timeout);
        settle(false);
      };
      ws.onclose = (e) => {
        clearTimeout(timeout);
        // A close code of 1000/1001 from a fresh connection means it connected
        settle(e.code === 1000 || e.code === 1001);
      };
    } catch {
      clearTimeout(timeout);
      settle(false);
    }
  });
}
