# Genesis Vouch — Handoff (state as of 2026-07-08, post-redeploy v2)

**LIVE on Ritual chain 1979 (v2, ms-aware):** `0xef99d6BDAF725A54166AA961A4F5165CdF7d5418`
Deployer / owner / platform wallet: `0xa328965678467d9C039Ec9eafA9362E488469200`
Fee 2500 bps (25%), maxMemberId 988, `roundDuration = 604800000` ms (= real 7 days), round 1 active from deploy (2026-07-08).
Explorer: https://explorer.ritualfoundation.org/address/0xef99d6BDAF725A54166AA961A4F5165CdF7d5418

> ⚠️ **Ritual `block.timestamp` is in MILLISECONDS.** The first deploy (`0xb21B…3b11`, now DEAD)
> used `ROUND_DURATION = 7 days` (604800), which on Ritual's ms clock settled in ~10 minutes.
> v2 makes round length a constructor param in ms. Any future time math on Ritual must use ms.
> Old contract had 0 stake, so it was safely abandoned.


Weekly popularity **vouching game** over the Ritual **Genesis 1000** roster. Stake native
RITUAL on a member you know; every 7 days the most-vouched member wins and the wallets that
vouched for the winner split the pool: `(winnerPool − platformFee) + 100% of all losing stakes`,
pro-rata. Members are *subjects*, not payees — no member wallets, no escrow, no seeding.

Location: `/home/chief/genesis-vouch` (lives inside the `/home/chief` git repo — **not its own repo**).

## What exists and is DONE
- `contracts/src/GenesisVouch.sol` (313 lines) — native RITUAL, `uint16 memberId`, O(1)
  running-leader pointer, pull-based claims, permissionless `settle()` after 7 days.
  Fee: constructor + `setPlatformFeeBps`, default 2500 bps (25%), hard cap 3000 (30%).
- `contracts/test/GenesisVouch.t.sol` (303 lines) — full test suite (not yet run here; forge-std missing).
- `contracts/script/Deploy.s.sol` — reads `PRIVATE_KEY`, `PLATFORM_WALLET`, `MAX_MEMBER_ID`(988), `PLATFORM_FEE_BPS`(2500).
- `contracts/foundry.toml` — solc 0.8.24, optimizer 200, `ritual` rpc endpoint defined.
- `frontend/index.html` + `frontend/app.js` — static ethers 6.10 UMD dApp, cosmic violet/indigo
  theme, reads live totals via `getActiveTotals()` (one RPC call, not 988).
- `data/holders.json` (988 holders), `data/genesis-live.json`, `data/onchain-gallery.json`.
- `data/avatars/` — 988 Discord PFPs (`<userId>.png`).
- `scripts/build-members.js` — `holders.json` → `frontend/members.json` (+ copies avatars).

## What is DONE (this session, 2026-07-08)
1. forge-std installed via direct clone into `contracts/lib/forge-std` (forge submodule install failed on unrelated `.gitmodules` for `risk-intelligence-platform/riskscan`).
2. Test bugs fixed and **18/18 forge tests pass**:
   - `address(0xP1a7)` was an invalid hex literal → `0xF1a7`.
   - `test_pendingBackerReward_view`: stakes were swapped so the tested backer was on the loser; flipped to backer-on-winner (60/40).
   - `test_reentrancy_claimBlocked`: expected balance formula assumed the attacker's post-vouch balance was `100`; corrected to snapshot `balBefore` post-vouch.
3. `frontend/members.json` (988 members) + `frontend/avatars/` (988 PFPs) built.
4. Deployed on Ritual (see banner above) and `frontend/app.js:5` patched with the live address.

## What is DONE (session 2, 2026-07-08 — ms-timestamp fix)
1. **Found + fixed the millisecond bug** (see banner). `ROUND_DURATION` constant → `roundDuration`
   immutable constructor param. `vouch`/`settle`/`currentRound` use it. `_roundDuration == 0`
   reverts `BadDuration`.
2. `Deploy.s.sol`: new `ROUND_DURATION_MS` env, default `604_800_000` (7 days in ms).
3. Frontend timer (`app.js`) fixed to treat `endsAt` as ms (`Date.now()` directly; ms delta ÷ 1000).
4. Tests **20/20 pass** — added `test_ctorZeroDuration_reverts` + `test_msRoundDuration`
   (drives a 13-digit ms clock, asserts settle only after full 7-day-in-ms window).
5. **Redeployed as v2** `0xef99…5418`; `frontend/app.js` CONTRACT_ADDRESS updated. Old `0xb21B…` dead.
6. Added `contracts/.gitignore` (out/, cache/, dry-run/, .env) — forge writes the deploy key into
   `cache/`, so it must never be committed. Verified project has no lingering copy of the key.

## What is DONE (session 3, 2026-07-08 — Genesis numbering + roster re-pull)
1. **Genesis # display fixes** (`app.js`/`index.html`): zero-pad to `#001`…`#987` (`gid()` helper);
   added `Genesis #NNN` line to the vouch modal (clicking a member now shows the number);
   removed a hidden `list.slice(0,300)` cap so the **full roster renders**, not just the first 300.
2. **Numbering audit:** memberId = 1-based join order, which is exactly how the source site numbers
   (`_idx+1`). Verified against live API: our old 988-snapshot was off-by-one from #872 because
   member #871 `shamsyn` had left the Discord since the scrape.
3. **Reproducible pipeline:** wrote `scripts/fetch-roster.js` (live siggy API → normalized
   `data/holders.json`, downloads any missing avatars). Re-pulled: roster now **987** members,
   `frontend/members.json` rebuilt, **0 position mismatches vs the live site** (`walirt` correctly
   at #871). Old snapshot backed up to `data/holders.pre-repull.json`.
4. **On-chain aligned:** `setMaxMemberId(987)` sent to `0xef99…5418` (tx `0x9f1ad2…`), confirmed 987.
   Refresh pipeline: `node scripts/fetch-roster.js && node scripts/build-members.js`.

## What is NOT done
1. **Not committed.** These files are untracked in the `/home/chief` repo.
2. **No live vouches yet.** Roster is loaded but round 1 has zero stake — first vouch will trigger the frontend's live totals path.
3. **No scheduler wiring** for auto-`settle()` (still permissionless manual).

## Deploy sequence (Ritual testnet first — real funds)
```bash
cd /home/chief/genesis-vouch/contracts
export PRIVATE_KEY=0x...          # deployer = default platform wallet
export PLATFORM_WALLET=0x...      # optional fee recipient
export MAX_MEMBER_ID=988
export PLATFORM_FEE_BPS=2500      # optional, cap 3000
forge script script/Deploy.s.sol --rpc-url https://rpc.ritualfoundation.org --broadcast
# then paste deployed address -> frontend/app.js CONTRACT_ADDRESS
```
Chain: Ritual, chainId **1979** (0x7bb), RPC `https://rpc.ritualfoundation.org`,
explorer `https://explorer.ritualfoundation.org`, symbol RITUAL.

## Serve frontend
```bash
cd /home/chief/genesis-vouch/frontend && python3 -m http.server 8080   # http://localhost:8080
```

## Data refresh
Live roster (grows toward 1000): `curl -s https://siggy.decka.my.id/api/badge/genesis-1000 -o data/genesis-live.json`
then re-normalize + `node scripts/build-members.js`. On-chain showcase gallery (separate):
contract `0x914d309524dC235D75FfAf14427bC353eCee0f48`, `getAllGallery()` → 1000 slots, ~78 claimed.

## Contract ABI (as wired in frontend/app.js)
`vouch(uint16) payable`, `settle()`, `claimBackerReward(uint256 r)`, `claimWinnerShare(uint256 r)`,
`roundId()`, `currentRound()`, `getActiveTotals()`, `getActiveTotalsAt(uint256)`,
`getRound(uint256)`, `myStake(uint256,uint16,address)`, `pendingBackerReward(uint256,address)`,
`backerClaimed(uint256,address)`.

## Roadmap
- Optional: wire Ritual Scheduler precompile to auto-settle weekly (currently permissionless manual `settle()`).
- Drive a full round on testnet before mainnet.
