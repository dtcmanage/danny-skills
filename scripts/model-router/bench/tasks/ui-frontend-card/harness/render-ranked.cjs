// Screenshot-only companion to the existing DOM grader. Reuse installed
// Playwright/Chromium from this harness or the workstation browser-smoke harness.
const fs = require('node:fs');
const path = require('node:path');
const {createRequire} = require('node:module');

function chromium() {
  try { return require('playwright').chromium; } catch (error) {
    if (error.code !== 'MODULE_NOT_FOUND') throw error;
  }
  for (let root = __dirname; ; root = path.dirname(root)) {
    const smoke = path.join(root, '00_Resources', 'tools', 'browser-smoke', 'smoke.mjs');
    if (fs.existsSync(smoke)) return createRequire(smoke)('playwright').chromium;
    if (path.dirname(root) === root) throw new Error('Installed browser-smoke Chromium unavailable');
  }
}

async function main() {
  const [source, png, format, keysJson = '[]'] = process.argv.slice(2);
  if (!['svg', 'html'].includes(format)) throw new Error('Unsupported render format');
  const content = fs.readFileSync(source, 'utf8');
  const keys = JSON.parse(keysJson);
  if (!Array.isArray(keys) || keys.some(key => typeof key !== 'string')) throw new Error('Invalid key presses');
  const browser = await chromium().launch({headless: true});
  const timer = setTimeout(() => { browser.close().finally(() => process.exit(1)); }, 20000);
  try {
    const context = await browser.newContext({viewport: {width: 1000, height: 800},
      serviceWorkers: 'block', acceptDownloads: false});
    await context.route('**/*', route => route.abort());
    await context.setOffline(true);
    await context.addInitScript(() => {
      const deny = () => { throw new Error('network disabled'); };
      window.WebSocket = deny;
      window.EventSource = deny;
      navigator.sendBeacon = deny;
    });
    const page = await context.newPage();
    page.setDefaultTimeout(5000);
    // No file URL or server: candidate markup sees no local files or network.
    await page.setContent(format === 'svg' ? '<!doctype html><body>' + content + '</body>' : content,
                          {waitUntil: 'load', timeout: 5000});
    if (format === 'svg' && !await page.locator('svg').count()) throw new Error('No SVG output');
    if (format === 'html' && !content.trim()) throw new Error('Empty HTML output');
    const shot = format === 'svg' ? page.locator('svg').first() : page;
    const frames = [];
    for (const key of keys) {
      let keyTimer;
      try {
        await Promise.race([
          (async () => {
            await page.keyboard.press(key);
            await page.waitForTimeout(100);
            frames.push(await page.screenshot({timeout: 3000}));
          })(),
          new Promise((_, reject) => {
            keyTimer = setTimeout(() => reject(new Error('Key press render timed out')), 3000);
          }),
        ]);
      } finally {
        clearTimeout(keyTimer);
      }
    }
    if (frames.length) {
      // One PNG per side: a contact sheet retains each scripted game state.
      await page.setContent('<!doctype html><body style="margin:0;display:flex;flex-wrap:wrap">'
        + frames.map(frame => '<img width="500" height="400" src="data:image/png;base64,'
          + frame.toString('base64') + '">').join('') + '</body>');
      await page.screenshot({path: png, fullPage: true});
    } else {
      await shot.screenshot({path: png});
    }
  } finally {
    clearTimeout(timer);
    await browser.close();
  }
}
main().catch(error => { console.error(String(error)); process.exitCode = 1; });
