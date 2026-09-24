// Renders hero.html frame by frame in headless Chromium (WebGL2).
//   node render.cjs <outDir> <frames> [W H oy radius SS] [only-frame]
// Needs: playwright, Chromium (CHROMIUM=path), GEIST=path/to/geist/dist/fonts, wordmark_sdf.f16 (make_sdf.py).
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');

(async () => {
  const [out, frames = '240', W = '1280', H = '440', oy = '0', radius = '28', SS = '2', only] = process.argv.slice(2);
  fs.mkdirSync(out, { recursive: true });
  const b = await chromium.launch({ executablePath: process.env.CHROMIUM,
    args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--allow-file-access-from-files'] });
  const p = await b.newPage();
  p.on('console', m => console.log('page:', m.text()));
  p.on('pageerror', e => console.log('pageerror:', e.message));
  await p.goto('file://' + path.join(__dirname, 'hero.html'));
  const sdf = fs.readFileSync(path.join(__dirname, 'wordmark_sdf.f16')).toString('base64');
  console.log(await p.evaluate(o => window.init(o), { W: +W, H: +H, SS: +SS, oy: +oy, radius: +radius, sdf, fonts: process.env.GEIST }));
  const N = +frames;
  const list = only !== undefined ? [+only] : [...Array(N).keys()];
  for (const i of list) {
    const t0 = Date.now();
    const url = await p.evaluate(t => window.frame(t), i / N);
    fs.writeFileSync(path.join(out, `f${String(i).padStart(4, '0')}.png`), Buffer.from(url.split(',')[1], 'base64'));
    if (i % 20 === 0 || only !== undefined) console.log(`frame ${i}/${N} ${Date.now() - t0} ms`);
  }
  await b.close();
})();
