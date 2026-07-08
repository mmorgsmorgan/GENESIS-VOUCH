# Genesis Vouch

A weekly **popularity vouching game** over the Ritual **Genesis 1000** roster. Vouch native
RITUAL on the member you know from the community. Every 7 days the most-vouched member wins,
and the **wallets that vouched for the winner** split the entire pool — the winner's remaining
pool **plus 100% of every losing member's stake**. The Genesis members are the *subjects* being
vouched on; they are not participants and receive nothing, so **no member wallets are needed**.

Built from the scraped Genesis registry (988 members, avatars, roles) — the old Three.js
"Human Galaxy" was stripped away; only the data remained.

## Economics (per round)

Let `P` = total staked on the winning member, `L` = total staked on everyone else.

| Bucket | Amount |
|---|---|
| Platform | `platformFeeBps of P` (default 25%) |
| Winner's backers (pro-rata) | `(P − fee)  +  L` |
| Losing backers | `0` (stake forfeited) |

**Example** — 100 R on the winner, 60 R on everyone else, 25% fee:
platform 25 · backer pot = 75 + 60 = **135 R**. A backer who staked 40 R on the winner
(40% of P) claims **54 R**.

The platform fee is configurable (constructor + `setPlatformFeeBps`, hard-capped at 30%).
The roster grows toward 1000 via `setMaxMemberId`.

## Layout

```
data/                     scraped dataset (holders.json, 988 avatars)
contracts/                Foundry — GenesisVouch.sol + tests + deploy script
frontend/                 static dApp (index.html + app.js + members.json + avatars/)
scripts/build-members.js  holders.json -> frontend/members.json (+ copies avatars)
```

## Data

`node scripts/build-members.js` regenerates `frontend/members.json` and `data/wallet-seeds.json`
from `data/holders.json`, and copies avatars into the frontend. Re-pull the live roster with:

```bash
curl -s https://siggy.decka.my.id/api/badge/genesis-1000 -o data/genesis-live.json
# then re-run the normalize step (see repo history) and build-members.js
```

## Contract

Native RITUAL, no ERC-20. Members are `uint16 memberId` (== `rank` in members.json). Winner
is tracked with an O(1) running-leader pointer, so `settle()` never scans the roster. Claims
are pull-based; `settle()` is permissionless once the 7-day round elapses.

```bash
cd contracts
forge install foundry-rs/forge-std --no-commit   # first time
forge test -vvv
```

### Deploy to Ritual (chainId 1979)

```bash
cd contracts
export PRIVATE_KEY=0x...            # deployer (also default platform wallet)
export PLATFORM_WALLET=0x...        # optional; fee recipient
export MAX_MEMBER_ID=988
export PLATFORM_FEE_BPS=2500        # optional; 25% default, cap 3000
forge script script/Deploy.s.sol --rpc-url https://rpc.ritualfoundation.org --broadcast
```

Then paste the deployed address into `frontend/app.js` (`CONTRACT_ADDRESS`). No wallet
seeding needed — members are subjects, not payees.

## Frontend

Pure static — open `frontend/index.html` (or serve the folder). Uses ethers 6.10 (UMD CDN),
the Ritual chain-switch flow, and reads live per-member totals via `getActiveTotals()` (one
RPC call, not 988). Cosmic violet/indigo theme carried over from the galaxy.

```bash
cd frontend && python3 -m http.server 8080   # http://localhost:8080
```

## Status / roadmap

- v1: permissionless weekly `settle()`. Optional: wire the Ritual Scheduler precompile to
  auto-settle each week (hands-off).
- **Testnet first** — real funds; drive a full round on testnet before mainnet.
