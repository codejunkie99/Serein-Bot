// Renders every state of a look in headless Chromium and writes a contact sheet:
//   node dev/capture.cjs <out-dir> [preset ...]
// Playwright is not a dependency of Serein; point PLAYWRIGHT at any install of it.
const path = require('path');
const { chromium } = require(process.env.PLAYWRIGHT || 'playwright');
const out = path.resolve(process.argv[2] || 'shots');
const presets = process.argv.slice(3).length ? process.argv.slice(3) : ['Serein'];
const states = ['idle', 'listening', 'thinking', 'speaking', 'working', 'alert', 'error', 'dormant'];
(async () => {
  require('fs').mkdirSync(out, { recursive: true });
  const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--use-angle=swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 640, height: 400 }, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  for (const preset of presets) {
    await page.goto('file://' + path.resolve(__dirname, 'harness.html') + '?preset=' + encodeURIComponent(preset));
    await page.waitForFunction(() => window.relayAvatar && window.events.some((e) => e.type === 'ready'), null, { timeout: 15000 });
    await page.evaluate(() => window.relayAvatar.setJobs([{ id: 'a', state: 'running' }, { id: 'b', state: 'running' }, { id: 'c', state: 'running' }]));
    const shots = [];
    for (const s of states) {
      shots.push(await page.evaluate((s) => { const a = window.relayAvatar; a.setState(s); a.settle(); for (let i = 0; i < 30; i++) a.step(1 / 60); return { s, url: a.snapshot(), info: a.info() }; }, s));
    }
    const sheet = await page.evaluate(async ({ shots, preset }) => {
      const W = 640, H = 400, cols = 4, c = document.createElement('canvas');
      c.width = W * cols; c.height = H * Math.ceil(shots.length / cols) + 40;
      const g = c.getContext('2d');
      g.fillStyle = '#02040b'; g.fillRect(0, 0, c.width, c.height);
      g.font = '500 22px Menlo, monospace'; g.fillStyle = '#d3e0ff'; g.fillText('Relay · ' + preset, 16, 28);
      for (let i = 0; i < shots.length; i++) {
        const img = new Image(); img.src = shots[i].url; await img.decode();
        const x = (i % cols) * W, y = 40 + Math.floor(i / cols) * H;
        g.drawImage(img, x, y, W, H);
        g.fillStyle = '#9fb4e6'; g.font = '500 18px Menlo, monospace';
        g.fillText(shots[i].s + ' · ' + shots[i].info.formation + ' + ' + shots[i].info.core, x + 14, y + 26);
      }
      return c.toDataURL('image/png');
    }, { shots, preset });
    require('fs').writeFileSync(path.join(out, preset.toLowerCase() + '-states.png'), Buffer.from(sheet.split(',')[1], 'base64'));
    console.log(preset, JSON.stringify(shots.map((x) => [x.s, x.info.formation, x.info.core, x.info.jobs])));
  }
  console.log(errors.length ? 'ERRORS:\n' + errors.join('\n') : 'no page errors');
  await browser.close();
})();
