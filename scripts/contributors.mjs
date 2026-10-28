// Regenerate .github/contributors.svg (the avatar wall in README's
// 「参与贡献」 section) from GitHub's contributor list for this repo.
//
// Usage: node scripts/contributors.mjs
// Run it manually when a new contributor shows up, then commit the SVG.
// GitHub's contributor list is cached for a few hours upstream.
// Set GH_TOKEN if you hit the unauthenticated rate limit.

import { writeFileSync } from 'node:fs';

const OWNER = 'ch6vip';
const REPO = 'fqapp';
const OUT = new URL('../.github/contributors.svg', import.meta.url);
const SIZE = 64; // avatar edge, px
const GAP = 4;

const headers = { 'User-Agent': 'fqapp-contributors-script' };
if (process.env.GH_TOKEN) headers.Authorization = `Bearer ${process.env.GH_TOKEN}`;

const res = await fetch(
  `https://api.github.com/repos/${OWNER}/${REPO}/contributors?per_page=100`,
  { headers },
);
if (!res.ok) throw new Error(`contributors API: ${res.status} ${await res.text()}`);
const list = (await res.json()).filter((c) => c.type === 'User');

let cells = '';
for (let i = 0; i < list.length; i++) {
  const c = list[i];
  const avatar = await fetch(`https://avatars.githubusercontent.com/u/${c.id}?s=128&v=4`);
  if (!avatar.ok) throw new Error(`avatar ${c.login}: ${avatar.status}`);
  const b64 = Buffer.from(await avatar.arrayBuffer()).toString('base64');
  cells +=
    `<g transform="translate(${i * (SIZE + GAP)} 0)"><title>${c.login}</title>\n` +
    `<image width="${SIZE}" height="${SIZE}" clip-path="url(#avatar)" ` +
    `xlink:href="data:image/png;base64,${b64}"/></g>\n`;
}

const width = list.length * SIZE + (list.length - 1) * GAP;
const svg =
  `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" ` +
  `width="${width}" height="${SIZE}" viewBox="0 0 ${width} ${SIZE}">\n` +
  `<defs><clipPath id="avatar"><circle cx="32" cy="32" r="32"/></clipPath></defs>\n` +
  `${cells}</svg>\n`;

writeFileSync(OUT, svg);
console.log(`wrote ${OUT.pathname}: ${list.length} contributors (${list.map((c) => c.login).join(', ')})`);
