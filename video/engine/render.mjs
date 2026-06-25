// Deterministic frame renderer: drives headless Chrome over CDP (zero deps, node v26 built-in WebSocket).
// The target HTML must expose window.__seek(t) (seconds) and set window.__ready = true once assets are loaded.
import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { createServer } from 'node:net';

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const [k, v] = a.replace(/^--/, '').split('=');
  return [k, v ?? true];
}));

const URL_ARG  = args.url    || 'http://127.0.0.1:8123/projects/launch/body.html';
const OUT       = args.out    || 'projects/launch/.video-build/frames';
const FPS        = +(args.fps || 30);
const DURATION   = +(args.duration || 25);
const WIDTH      = +(args.width || 1920);
const HEIGHT     = +(args.height || 1080);
const SCALE      = +(args.scale || 2);
// Each render gets its OWN free CDP port + isolated Chrome profile, so overlapping renders (or a
// pre-existing Chrome already listening on a fixed port) can't cross-drive each other's pages.
const freePort = () => new Promise((resolve, reject) => {
  const srv = createServer().unref();
  srv.on('error', reject);
  srv.listen(0, '127.0.0.1', () => { const { port } = srv.address(); srv.close(() => resolve(port)); });
});
const PORT       = args.port ? +args.port : await freePort();
const START      = +(args.start || 0);            // start frame (for resuming)
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// This driver speaks CDP over the global WebSocket (stable since Node 22; zero npm deps by design).
// Fail fast with a clear message instead of a cryptic ReferenceError after Chrome has already started.
if (typeof WebSocket === 'undefined') {
  console.error(`render.mjs needs a global WebSocket (Node 22+); running ${process.version}. Upgrade Node.`);
  process.exit(1);
}

rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });

const profile = `/tmp/cctop-video-chrome-${PORT}`;
rmSync(profile, { recursive: true, force: true });

const chrome = spawn(CHROME, [
  '--headless=new',
  `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${profile}`,
  `--window-size=${WIDTH},${HEIGHT}`,
  '--hide-scrollbars',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-extensions',
  '--force-color-profile=srgb',
  '--disable-features=CalculateNativeWinOcclusion',
  URL_ARG,
], { stdio: ['ignore', 'inherit', 'inherit'] });

function cleanup() { try { chrome.kill('SIGKILL'); } catch {} }
process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });

// --- find the page target ---
async function getPageWS() {
  for (let i = 0; i < 80; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/json`);
      const list = await res.json();
      // match OUR page by exact URL (defense-in-depth beyond the per-render port), not just the
      // first .html target, so we never attach to an unrelated Chrome page on the same port.
      const page = list.find(t => t.type === 'page' && t.url === URL_ARG)
                || list.find(t => t.type === 'page' && /127\.0\.0\.1:\d+\/.+\.html/.test(t.url));
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch {}
    await sleep(150);
  }
  throw new Error('Could not find page target');
}

// --- minimal CDP client over WebSocket ---
function makeCDP(ws) {
  let id = 0;
  const pending = new Map();
  ws.addEventListener('message', ev => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    }
  });
  return (method, params = {}) => new Promise((resolve, reject) => {
    const mid = ++id;
    pending.set(mid, { resolve, reject });
    ws.send(JSON.stringify({ id: mid, method, params }));
    setTimeout(() => { if (pending.has(mid)) { pending.delete(mid); reject(new Error('timeout ' + method)); } }, 30000);
  });
}

const wsUrl = await getPageWS();
const ws = new WebSocket(wsUrl);
await new Promise((res, rej) => { ws.addEventListener('open', res); ws.addEventListener('error', rej); });
const send = makeCDP(ws);

await send('Page.enable');
await send('Runtime.enable');
await send('Emulation.setDeviceMetricsOverride', {
  width: WIDTH, height: HEIGHT, deviceScaleFactor: SCALE, mobile: false,
});

// wait for the page to signal asset readiness
async function evalJS(expression, awaitPromise = false) {
  const r = await send('Runtime.evaluate', { expression, awaitPromise, returnByValue: true });
  if (r.exceptionDetails) throw new Error('eval error: ' + JSON.stringify(r.exceptionDetails));
  return r.result?.value;
}

process.stdout.write('waiting for __ready');
for (let i = 0; i < 120; i++) {
  const ready = await evalJS('window.__ready === true').catch(() => false);
  if (ready) break;
  process.stdout.write('.');
  await sleep(100);
}
process.stdout.write('\n');

// fail loudly if the page reported a broken/missing image — don't capture a cut with missing visuals
const renderErr = await evalJS('window.__error || null').catch(() => null);
if (renderErr) { console.error('render aborted:', renderErr); ws.close(); cleanup(); process.exit(1); }

const t0 = Date.now();
if (args.times) {
  // keyframe sampling mode: render specific timestamps to keyframe_<t>.png
  const times = String(args.times).split(',').map(Number);
  for (const t of times) {
    await evalJS(`window.__seek(${t})`, true);
    const shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false, fromSurface: true });
    writeFileSync(`${OUT}/key_${t.toFixed(2).replace('.', '_')}.png`, Buffer.from(shot.data, 'base64'));
    console.log('  key', t.toFixed(2));
  }
  console.log(`Keyframes done in ${((Date.now() - t0) / 1000).toFixed(1)}s -> ${OUT}`);
  ws.close(); cleanup(); process.exit(0);
}
const totalFrames = Math.round(DURATION * FPS);
console.log(`Rendering ${totalFrames} frames @ ${FPS}fps (${WIDTH}x${HEIGHT} x${SCALE}) from frame ${START}`);
for (let f = START; f < totalFrames; f++) {
  const t = f / FPS;
  await evalJS(`window.__seek(${t})`, true);
  const shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false, fromSurface: true });
  writeFileSync(`${OUT}/frame_${String(f).padStart(5, '0')}.png`, Buffer.from(shot.data, 'base64'));
  if (f % 30 === 0) {
    const pct = ((f - START) / (totalFrames - START) * 100).toFixed(0);
    const eta = ((Date.now() - t0) / Math.max(1, f - START + 1) * (totalFrames - f) / 1000).toFixed(0);
    process.stdout.write(`\r  frame ${f}/${totalFrames} (${pct}%) eta ${eta}s   `);
  }
}
console.log(`\nDone in ${((Date.now() - t0) / 1000).toFixed(1)}s -> ${OUT}`);
ws.close();
cleanup();
process.exit(0);
