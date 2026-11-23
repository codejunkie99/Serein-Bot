// The hologram on clear backgrounds: every state over dark glass and over a light window.
//   node dev/themes.cjs <out-dir> [preset]
const path = require('path'), fs = require('fs');
const { chromium } = require(process.env.PLAYWRIGHT || 'playwright');
const out = path.resolve(process.argv[2] || 'shots'), preset = process.argv[3] || 'Serein';
const states = ['idle', 'listening', 'thinking', 'speaking', 'working', 'alert', 'error', 'dormant'];
(async () => {
  fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--use-angle=swiftshader'] });
  const errors = [];
  for (const [theme, bg] of [['dark', '#1b1f2a'], ['light', '#f6f7f9']]) {
    for (const [name, w, h] of [['hero', 640, 190], ['strip', 640, 96]]) {
      const page = await browser.newPage({ viewport: { width: w, height: h * states.length }, deviceScaleFactor: 2 });
      page.on('pageerror', (e) => errors.push(String(e)));
      await page.setContent(`<html><body style="margin:0;background:${bg}">` + states.map((s) => `<div class="s" data-s="${s}" style="position:relative;width:${w}px;height:${h}px"><span style="position:absolute;left:10px;top:6px;font:12px Menlo;color:${theme === 'dark' ? '#8da0c8' : '#4a5568'}">${s}</span></div>`).join('') + '</body></html>');
      await page.addScriptTag({ path: path.resolve(__dirname, '../../../Sources/Serein/Avatar/avatar.bundle.js') });
      await page.evaluate(({ theme, preset }) => {
        const look = RelayAvatar.presets.find((p) => p.name === preset);
        window.avatars = [...document.querySelectorAll('.s')].map((el) => {
          const a = RelayAvatar.create(el, { look, state: el.dataset.s, transparent: true, theme, still: true });
          if (el.dataset.s === 'working') a.setJobs([{ id: 'a', state: 'running' }, { id: 'b', state: 'running' }]);
          return a;
        });
      }, { theme, preset });
      await page.waitForTimeout(400);
      await page.evaluate(() => window.avatars.forEach((a) => a.settle()));
      await page.screenshot({ path: path.join(out, `${preset.toLowerCase()}-${theme}-${name}.png`) });
      await page.close();
    }
  }
  console.log(errors.length ? 'ERRORS:\n' + errors.join('\n') : 'no page errors');
  await browser.close();
})();
