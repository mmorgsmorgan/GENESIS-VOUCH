#!/usr/bin/env node
// Pull the LIVE Genesis roster from the source site and normalize it into
// data/holders.json — the exact shape build-members.js consumes.
//
// The source API (siggy) returns members in canonical Genesis order (join order);
// the site numbers them 1-based by array position, so memberId = index + 1. That is
// the *same* numbering the source website shows, so our cards match it exactly.
//
//   node scripts/fetch-roster.js         # fetch + write data/holders.json
//
// Avatars: downloads any <userId>.png not already in data/avatars/.

const fs = require('fs');
const path = require('path');
const https = require('https');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.join(ROOT, 'data');
const AV = path.join(DATA, 'avatars');
const API = 'https://siggy.decka.my.id/api/badge/genesis-1000';

const getJSON = (url) => new Promise((res, rej) => {
  https.get(url, (r) => {
    let b = ''; r.on('data', (d) => (b += d));
    r.on('end', () => { try { res(JSON.parse(b)); } catch (e) { rej(e); } });
  }).on('error', rej);
});

const download = (url, dst) => new Promise((res) => {
  const f = fs.createWriteStream(dst);
  https.get(url, (r) => {
    if (r.statusCode !== 200) { f.close(); fs.rmSync(dst, { force: true }); return res(false); }
    r.pipe(f); f.on('finish', () => f.close(() => res(true)));
  }).on('error', () => { fs.rmSync(dst, { force: true }); res(false); });
});

// The live API's avatarUrl is a proxy path (/api/proxy-avatar?url=<encoded discord cdn>).
// Recover the real Discord CDN url so we can persist a stable avatarCdn + download the png.
function discordCdn(h) {
  const u = h.avatarUrl || '';
  const m = u.match(/url=([^&]+)/);
  if (m) return decodeURIComponent(m[1]);
  return u.startsWith('http') ? u : null;
}

(async () => {
  console.log('fetching', API);
  const raw = await getJSON(API);
  const live = raw.holders;
  console.log('live roster:', live.length, 'members');

  fs.mkdirSync(AV, { recursive: true });

  const holders = [];
  let dl = 0, have = 0, miss = 0;
  for (let i = 0; i < live.length; i++) {
    const h = live[i];
    const role = h.topRole || h.contributorRole || h.fallbackRole || null;
    const cdn = discordCdn(h);
    const file = path.join(AV, `${h.userId}.png`);
    if (!fs.existsSync(file)) {
      if (cdn && (await download(cdn, file))) dl++; else miss++;
    } else have++;

    holders.push({
      rank: i + 1,                 // 1-based Genesis number == source site numbering
      userId: h.userId,
      username: h.username,
      displayName: h.displayName || h.username,
      role,
      joinedAt: h.joinedAt,
      avatarCdn: cdn,
      avatarFile: `avatars/${h.userId}.png`,
      wallet: null,
      xHandle: h.xHandle || null,
      genesisSlot: h.genesisSlot ?? null, // sparse on-chain gallery slot (not the display #)
      cardImg: null,
    });
  }

  const out = {
    badge: raw.badge || 'Genesis 1000',
    count: holders.length,
    updatedAt: new Date().toISOString(),
    source: API,
    holders,
  };
  fs.writeFileSync(path.join(DATA, 'holders.json'), JSON.stringify(out, null, 2));
  console.log(`data/holders.json written: ${holders.length} members (rank 1..${holders.length})`);
  console.log(`avatars: ${have} already present, ${dl} downloaded, ${miss} missing`);
})();
