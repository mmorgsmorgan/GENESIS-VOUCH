#!/usr/bin/env node
// Build frontend/members.json from data/holders.json and copy avatars.
// memberId is the stable on-chain identity (1..N). It equals `rank` in holders.json
// (the order the Siggy registry returns, roughly join order). The contract only ever
// sees memberId; names/pfps live here in members.json.

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.join(ROOT, 'data');
const FRONT = path.join(ROOT, 'frontend');

const holders = JSON.parse(fs.readFileSync(path.join(DATA, 'holders.json'), 'utf8'));
const list = holders.holders;

const members = list.map((h) => ({
  memberId: h.rank, // stable id used on-chain
  userId: h.userId,
  name: h.displayName || h.username,
  handle: h.username,
  x: h.xHandle || null,
  role: h.role,
  joinedAt: h.joinedAt,
  avatar: `avatars/${h.userId}.png`,
}));

// --- write members.json ---
const out = {
  badge: holders.badge,
  count: members.length,
  updatedAt: holders.updatedAt,
  source: holders.source,
  members,
};
fs.writeFileSync(path.join(FRONT, 'members.json'), JSON.stringify(out, null, 2));

// --- copy avatars -> frontend/avatars ---
const srcAv = path.join(DATA, 'avatars');
const dstAv = path.join(FRONT, 'avatars');
fs.mkdirSync(dstAv, { recursive: true });
let copied = 0, missing = 0;
for (const m of members) {
  const src = path.join(srcAv, `${m.userId}.png`);
  const dst = path.join(dstAv, `${m.userId}.png`);
  if (fs.existsSync(src)) {
    if (!fs.existsSync(dst)) fs.copyFileSync(src, dst);
    copied++;
  } else {
    missing++;
    console.warn('  ! missing avatar for', m.memberId, m.handle);
  }
}

console.log(`members.json written: ${members.length} members`);
console.log(`avatars: ${copied} present, ${missing} missing`);
