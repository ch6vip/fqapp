// Regenerate .github/contributors.svg (the avatar wall in README's
// 「参与贡献」 section) from the checked-out commit's actual history.
//
// Usage: GH_TOKEN=... node scripts/contributors.mjs
// Run it manually when a new contributor shows up, then commit the SVG.
// Reading an exact revision avoids stale repository contributor statistics.

import { writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const OWNER = 'ch6vip';
const REPO = 'novel-sound';
const OUT = new URL('../.github/contributors.svg', import.meta.url);
const SIZE = 64; // avatar edge, px
const GAP = 4;

if (!process.env.GH_TOKEN) throw new Error('GH_TOKEN is required');
const headers = {
  'User-Agent': 'novel-sound-contributors-script',
  Authorization: `Bearer ${process.env.GH_TOKEN}`,
  'Content-Type': 'application/json',
};
const revision = execFileSync('git', ['rev-parse', 'HEAD'], {
  cwd: new URL('../', import.meta.url), encoding: 'utf8',
}).trim();
const query = `query($owner: String!, $repo: String!, $revision: GitObjectID!, $after: String) {
  repository(owner: $owner, name: $repo) {
    object(oid: $revision) {
      ... on Commit {
        history(first: 100, after: $after) {
          nodes { author { user { login databaseId } } }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}`;
const contributors = new Map();
let after = null;
while (true) {
  const res = await fetch('https://api.github.com/graphql', {
    method: 'POST', headers,
    body: JSON.stringify({ query, variables: { owner: OWNER, repo: REPO, revision, after } }),
  });
  if (!res.ok) throw new Error(`commit history API: ${res.status} ${await res.text()}`);
  const result = await res.json();
  if (result.errors) throw new Error(JSON.stringify(result.errors));
  const history = result.data?.repository?.object?.history;
  if (!history) throw new Error(`Commit history not found for ${revision}`);
  for (const commit of history.nodes) {
    const user = commit.author?.user;
    if (!user?.databaseId || user.login.endsWith('[bot]')) continue;
    const entry = contributors.get(user.databaseId) ?? {
      id: user.databaseId, login: user.login, contributions: 0,
    };
    entry.contributions++;
    contributors.set(entry.id, entry);
  }
  if (!history.pageInfo.hasNextPage) break;
  const next = history.pageInfo.endCursor;
  if (!next || next === after) throw new Error('Commit history pagination did not advance');
  after = next;
}
const list = [...contributors.values()].sort(
  (a, b) => b.contributions - a.contributions || a.login.localeCompare(b.login),
);

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

const width = Math.max(SIZE, list.length * SIZE + (list.length - 1) * GAP);
const svg =
  `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" ` +
  `width="${width}" height="${SIZE}" viewBox="0 0 ${width} ${SIZE}">\n` +
  `<defs><clipPath id="avatar"><circle cx="32" cy="32" r="32"/></clipPath></defs>\n` +
  `${cells}</svg>\n`;

writeFileSync(OUT, svg);
console.log(`wrote ${OUT.pathname}: ${list.length} contributors (${list.map((c) => c.login).join(', ')})`);
