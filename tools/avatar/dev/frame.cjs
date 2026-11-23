// Frames for checking: the panel's stage sizes over glass, and a morph filmstrip.
//   node dev/frame.cjs <out-dir>
const path = require('path'), fs = require('fs');
const { chromium } = require(process.env.PLAYWRIGHT || 'playwright');
const out = path.resolve(process.argv[2] || 'shots');
(async () => {
  fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--use-angle=swiftshader'] });
  const errors = [];
  async function stage(w, h, bg, query, setup) {
    const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 2 });
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto('file://' + path.resolve(__dirname, 'harness.html') + '?' + (query.includes('transparent=') ? '' : 'transparent=1&') + query);
    await page.addStyleTag({ content: `html,body{background:${bg}!important}` });
    await page.waitForFunction(() => window.relayAvatar && window.events.some((e) => e.type === 'ready'));
    await page.evaluate(setup || (() => window.relayAvatar.settle()));
    return page;
  }
  // Floating panel: hero over dark glass, compact strip, docked column, light-mode docked column.
  const shots = [
    ['panel-hero', 640, 210, '#1b2130', 'state=idle'],
    ['panel-compact', 640, 96, '#1b2130', 'state=thinking'],
    ['column-hero', 340, 200, '#16181d', 'state=working'],
    ['column-compact', 340, 92, '#16181d', 'state=speaking'],
  ];
  for (const [name, w, h, bg, q] of shots) {
    const page = await stage(w, h, bg, q, () => { const a = window.relayAvatar; a.setJobs([{ id: 'a', state: 'running' }, { id: 'b', state: 'running' }]); a.settle(); for (let i = 0; i < 20; i++) a.step(1 / 60); a.render(); });
    await page.screenshot({ path: path.join(out, name + '.png') });
    console.log(name, JSON.stringify(await page.evaluate(() => window.relayAvatar.info())));
    await page.close();
  }
  // Morph filmstrip idle → thinking, every 0.15 s, stitched in the page.
  const page = await stage(420, 300, '#02040b', 'state=idle&transparent=0');
  const strip = await page.evaluate(async () => {
    const a = window.relayAvatar, frames = [];
    a.settle();
    a.setState('thinking');
    for (let i = 0; i < 10; i++) { frames.push(a.snapshot()); for (let j = 0; j < 9; j++) a.step(1 / 60); }
    const c = document.createElement('canvas'), W = 420 * 2, H = 300 * 2; c.width = W * 5; c.height = H * 2;
    const g = c.getContext('2d');
    g.fillStyle = '#02040b'; g.fillRect(0, 0, c.width, c.height);
    for (let i = 0; i < frames.length; i++) { const im = new Image(); im.src = frames[i]; await im.decode(); g.drawImage(im, (i % 5) * W, Math.floor(i / 5) * H, W, H); g.fillStyle = '#9fb4e6'; g.font = '500 26px Menlo'; g.fillText((i * 0.15).toFixed(2) + ' s', (i % 5) * W + 16, Math.floor(i / 5) * H + 36); }
    return c.toDataURL('image/png');
  });
  fs.writeFileSync(path.join(out, 'morph-idle-thinking.png'), Buffer.from(strip.split(',')[1], 'base64'));
  console.log(errors.length ? 'ERRORS:\n' + errors.join('\n') : 'no page errors');
  await browser.close();
})();
