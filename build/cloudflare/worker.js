// JavaBox Cloudflare Worker — serves all files from R2 with COOP/COEP headers.
// Required for SharedArrayBuffer (QEMU WASM pthread workers).

const CONTENT_TYPES = {
  html: 'text/html; charset=utf-8',
  js:   'application/javascript',
  css:  'text/css',
  wasm: 'application/wasm',
  data: 'application/octet-stream',
  json: 'application/json',
  bin:  'application/octet-stream',
};

function contentType(path) {
  const ext = path.split('.').pop();
  return CONTENT_TYPES[ext] || 'application/octet-stream';
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    let path = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);

    // Reject directory traversal
    if (path.includes('..')) {
      return new Response('Bad request', { status: 400 });
    }

    const object = await env.BUCKET.get(path);
    if (!object) {
      return new Response('Not found', { status: 404 });
    }

    const headers = new Headers();
    headers.set('Content-Type', contentType(path));

    // COOP/COEP — required for SharedArrayBuffer
    headers.set('Cross-Origin-Opener-Policy', 'same-origin');
    headers.set('Cross-Origin-Embedder-Policy', 'require-corp');

    // Cache: immutable for large assets, no-cache for HTML
    if (path.endsWith('.html')) {
      headers.set('Cache-Control', 'no-cache');
    } else {
      headers.set('Cache-Control', 'public, max-age=604800');
    }

    return new Response(object.body, { headers });
  },
};
