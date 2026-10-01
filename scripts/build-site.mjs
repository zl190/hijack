import { copyFileSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Contract: explicit public inputs → dist. No native binaries, docs or draft pages.
// Idempotent and local only; rejects stale CSS/JS fingerprints before replacing dist.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const files = ['index.html', 'precise.html', 'precise-zh.html', 'home.css', 'home.js', 'locales.js',
  'assets/Hijack-1024.png', 'assets/hijack-want-it-all-face.png', 'assets/hijack-why-not-both-en.png',
  'assets/og.png', 'assets/brand/hijack-wordmark.svg', 'assets/brand/hijack-wordmark-inverse.svg'];
const html = readFileSync(resolve(root, 'site/index.html'), 'utf8');
for (const file of ['home.css', 'home.js', 'locales.js']) {
  const hash = createHash('sha256').update(readFileSync(resolve(root, 'site', file))).digest('hex').slice(0, 12);
  if (!html.includes(`${file}?v=${hash}`)) throw new Error(`Stale fingerprint: ${file}`);
}
for (const file of files) readFileSync(resolve(root, 'site', file));
rmSync(resolve(root, 'dist'), { recursive: true, force: true });
for (const file of files) {
  const destination = resolve(root, 'dist', file);
  mkdirSync(dirname(destination), { recursive: true });
  copyFileSync(resolve(root, 'site', file), destination);
}
console.log(`Built ${files.length} public assets in dist/`);
