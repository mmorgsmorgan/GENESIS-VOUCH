/* Genesis Vouch — frontend logic (ethers 6.10 UMD -> window.ethers) */

// ---- config ----------------------------------------------------------
const CONTRACT_ADDRESS = "0xef99d6BDAF725A54166AA961A4F5165CdF7d5418"; // v2 (ms-aware 7d rounds), Ritual 1979, 2026-07-08
const RITUAL = {
  chainIdHex: "0x7bb", // 1979
  chainId: 1979,
  chainName: "Ritual",
  rpc: "https://rpc.ritualfoundation.org",
  explorer: "https://explorer.ritualfoundation.org",
  symbol: "RITUAL",
};
const ABI = [
  "function vouch(uint16 memberId) external payable",
  "function settle() external",
  "function claimBackerReward(uint256 r) external",
  "function claimWinnerShare(uint256 r) external",
  "function roundId() view returns (uint256)",
  "function currentRound() view returns (uint256 id,uint256 startsAt,uint256 endsAt,uint256 totalStaked,uint16 leaderId,uint256 leaderTotal)",
  "function getActiveTotals() view returns (uint16[] ids,uint256[] amounts)",
  "function getActiveTotalsAt(uint256 r) view returns (uint16[] ids,uint256[] amounts)",
  "function getRound(uint256 r) view returns (tuple(uint256 totalStaked,uint256 leaderTotal,uint256 winnerPool,uint256 backerPot,uint16 leaderId,uint16 winnerId,bool settled))",
  "function myStake(uint256 r,uint16 memberId,address who) view returns (uint256)",
  "function pendingBackerReward(uint256 r,address who) view returns (uint256)",
  "function backerClaimed(uint256 r,address who) view returns (bool)",
];

// role -> color (from human-galaxy ROLES[])
const ROLE_COLORS = {
  "Radiant Ritualist": "#faf0d0", "Mage": "#c084fc", "Zealot": "#f472b6",
  "Forerunner": "#60a5fa", "Harmonic": "#67e8f9", "Cursed": "#9d4edd",
  "Ritualist": "#818cf8", "ritty": "#f0abfc", "bitty": "#38bdf8",
  "Blessed": "#c0c0ff", "Initiate": "#7c8aa8",
};
// Display order for the role sections (user-specified rarity/prestige order).
// Anything not listed falls under "others" in the trailing bucket, rarity-ish.
const ROLE_ORDER = [
  "Radiant Ritualist", "Zealot", "Ritualist", "Mage", "ritty", "bitty", "Forerunner",
  "Harmonic", "Cursed", "Blessed", "Initiate",
];
const roleRank = (r) => { const i = ROLE_ORDER.indexOf(r); return i === -1 ? 999 : i; };
const roleColor = (r) => ROLE_COLORS[r] || "#9a9bc7";

const deployed = CONTRACT_ADDRESS && !/^0x0+$/.test(CONTRACT_ADDRESS);

// ---- state -----------------------------------------------------------
let members = [];              // from members.json
let byId = new Map();          // memberId -> member
let liveTotals = new Map();    // memberId -> bigint wei staked this round
let roundInfo = null;          // {id,startsAt,endsAt,totalStaked,leaderId,leaderTotal}
let sortKey = "role";
let searchQ = "";
let signer = null, account = null, wc = null; // wallet contract
let ro = null;                 // read-only contract
let timerHandle = null;

const $ = (id) => document.getElementById(id);
const fmt = (wei) => {
  try { return (+ethers.formatEther(wei)).toLocaleString(undefined,{maximumFractionDigits:3}); }
  catch { return "0"; }
};
const short = (a) => a ? a.slice(0,6)+"…"+a.slice(-4) : "";
// Genesis # — zero-padded to 3 digits (001..988, and 1000 as the roster fills).
const gid = (id) => "#" + String(id).padStart(3, "0");

function toast(msg, kind="") {
  const t = $("toast"); t.textContent = msg; t.className = "toast show " + kind;
  clearTimeout(t._h); t._h = setTimeout(()=>{ t.className="toast"; }, 4200);
}

// ---- boot ------------------------------------------------------------
(async function boot() {
  const res = await fetch("./members.json");
  const data = await res.json();
  members = data.members;
  byId = new Map(members.map(m => [m.memberId, m]));

  ro = deployed ? new ethers.Contract(CONTRACT_ADDRESS, ABI, new ethers.JsonRpcProvider(RITUAL.rpc)) : null;

  render();
  await refreshChain();
  setInterval(refreshChain, 15000);
  startTimer();
  wireUI();
})();

// ---- chain reads -----------------------------------------------------
async function refreshChain() {
  if (!ro) return;
  try {
    const cr = await ro.currentRound();
    roundInfo = { id: cr[0], startsAt: cr[1], endsAt: cr[2], totalStaked: cr[3], leaderId: Number(cr[4]), leaderTotal: cr[5] };
    const [ids, amts] = await ro.getActiveTotals();
    liveTotals = new Map(ids.map((id,i)=>[Number(id), amts[i]]));
    paintHero();
    render();
    if (account) refreshWallet();
  } catch (e) { /* rpc hiccup */ }
}

function paintHero() {
  if (!roundInfo) return;
  $("sRound").textContent = "#" + roundInfo.id.toString();
  $("sPot").innerHTML = `${fmt(roundInfo.totalStaked)} <small>R</small>`;
  const lead = byId.get(roundInfo.leaderId);
  if (lead && roundInfo.leaderTotal > 0n) {
    $("sLeaderImg").src = lead.avatar; $("sLeaderImg").style.visibility = "visible";
    $("sLeaderName").textContent = lead.name;
    $("sLeaderAmt").textContent = fmt(roundInfo.leaderTotal) + " R vouched";
  } else {
    $("sLeaderName").textContent = "no vouches yet";
    $("sLeaderAmt").textContent = ""; $("sLeaderImg").style.visibility = "hidden";
  }
  // Ritual block.timestamp (and thus endsAt) is in MILLISECONDS — compare against Date.now() directly.
  const over = Date.now() >= Number(roundInfo.endsAt);
  $("settleBanner").classList.toggle("show", over && deployed);
}

function startTimer() {
  clearInterval(timerHandle);
  timerHandle = setInterval(() => {
    if (!roundInfo) { $("sTimer").textContent = "—"; return; }
    // endsAt is a ms timestamp (Ritual clock); take the ms delta, then work in seconds.
    let s = Math.floor((Number(roundInfo.endsAt) - Date.now()) / 1000);
    if (s <= 0) { $("sTimer").textContent = "ended"; return; }
    const d = Math.floor(s/86400); s%=86400;
    const h = Math.floor(s/3600); s%=3600;
    const m = Math.floor(s/60);
    $("sTimer").textContent = `${d}d ${h}h ${m}m`;
  }, 1000);
}

// ---- render grid -----------------------------------------------------
const amt = (m) => liveTotals.get(m.memberId) || 0n;

function cardHTML(m) {
  const staked = amt(m);
  const rc = roleColor(m.role);
  const isW = deployed && roundInfo?.leaderId === m.memberId && staked > 0n;
  const fallback = `https://api.dicebear.com/7.x/identicon/svg?seed=${m.userId}&backgroundColor=1a0d3a`;
  return `<div class="card${isW ? " iswinner" : ""}" style="--rc:${rc}" data-open="${m.memberId}">
      ${isW ? '<div class="crown">👑</div>' : ''}
      <img class="bg" loading="lazy" src="${m.avatar}" onerror="this.onerror=null;this.src='${fallback}'"/>
      <div class="scrim"></div>
      <div class="rolepill">${m.role}</div>
      <div class="info">
        <div class="name" title="${m.name}">${m.name}</div>
        <div class="handle">@${m.handle}</div>
        <div class="vouched"><span class="lab">Vouched</span><span class="num">${fmt(staked)} R</span></div>
        <button class="vbtn" data-vouch="${m.memberId}">Vouch</button>
      </div>
    </div>`;
}

function sectionHTML(role, cards) {
  const rc = roleColor(role);
  return `<div class="rolesec" style="color:${rc}">
      <span class="dot"></span><h3>${role}</h3><span class="rule"></span><span class="cnt">${cards.length}</span>
    </div>
    <div class="grid">${cards.map(cardHTML).join("")}</div>`;
}

function render() {
  const q = searchQ.trim().toLowerCase();
  let list = members.filter(m =>
    !q || (m.name||"").toLowerCase().includes(q) || (m.handle||"").toLowerCase().includes(q));

  const g = $("grid");
  if (!list.length) { g.innerHTML = '<div class="empty">No members match that search.</div>'; return; }

  if (sortKey === "role") {
    // Group into role sections in the user-specified order; within a role, most-vouched first.
    const groups = new Map();
    for (const m of list) { if (!groups.has(m.role)) groups.set(m.role, []); groups.get(m.role).push(m); }
    const roles = [...groups.keys()].sort((a,b)=> roleRank(a)-roleRank(b) || a.localeCompare(b));
    g.innerHTML = roles.map(role => {
      const cards = groups.get(role).sort((a,b)=> (amt(b)>amt(a)?1:amt(b)<amt(a)?-1:a.memberId-b.memberId));
      return sectionHTML(role, cards);
    }).join("");
  } else {
    if (sortKey === "vouched") list.sort((a,b)=> (amt(b)>amt(a)?1:amt(b)<amt(a)?-1:a.memberId-b.memberId));
    else if (sortKey === "rank") list.sort((a,b)=> a.memberId-b.memberId);
    else list.sort((a,b)=> (a.name||"").localeCompare(b.name||""));
    g.innerHTML = `<div class="grid">${list.map(cardHTML).join("")}</div>`;
  }
}

// ---- wallet ----------------------------------------------------------
async function connect() {
  if (!window.ethereum) { toast("No wallet found. Install MetaMask.", "err"); return; }
  try {
    const raw = window.ethereum;
    try {
      await raw.request({ method:"wallet_switchEthereumChain", params:[{chainId:RITUAL.chainIdHex}] });
    } catch (sw) {
      if (sw.code === 4902) {
        await raw.request({ method:"wallet_addEthereumChain", params:[{
          chainId:RITUAL.chainIdHex, chainName:RITUAL.chainName, rpcUrls:[RITUAL.rpc],
          nativeCurrency:{name:RITUAL.symbol,symbol:RITUAL.symbol,decimals:18}, blockExplorerUrls:[RITUAL.explorer] }]});
      } else if (sw.code !== 4001) { throw sw; }
    }
    const provider = new ethers.BrowserProvider(raw);
    await provider.send("eth_requestAccounts", []);
    signer = await provider.getSigner();
    account = await signer.getAddress();
    wc = new ethers.Contract(CONTRACT_ADDRESS, ABI, signer);

    $("connectBtn").textContent = short(account);
    $("myBtn").style.display = "inline-block";
    $("net").classList.add("ok"); $("netLabel").textContent = "Ritual";
    raw.on?.("accountsChanged", () => location.reload());
    raw.on?.("chainChanged", () => location.reload());
    toast("Connected to Ritual", "ok");
    refreshWallet();
  } catch (e) { toast(err(e), "err"); }
}

function err(e){ return (e?.info?.error?.message || e?.shortMessage || e?.reason || e?.message || "Transaction failed").slice(0,120); }

// ---- vouch flow ------------------------------------------------------
let vouchTarget = null;
function openVouch(id) {
  if (!deployed) { toast("Contract not deployed yet.", "err"); return; }
  if (!account) { toast("Connect your wallet first.", "err"); connect(); return; }
  const m = byId.get(id); if (!m) return;
  vouchTarget = m;
  $("vImg").src = m.avatar;
  $("vName").textContent = m.name;
  $("vHandle").textContent = "@" + m.handle;
  const rc = ROLE_COLORS[m.role] || "#9a9bc7";
  const r = $("vRole"); r.textContent = m.role; r.style.color = rc;
  $("vAmt").value = "";
  $("vouchScrim").classList.add("show");
}
async function confirmVouch() {
  const v = parseFloat($("vAmt").value);
  if (!v || v < 0.001) { toast("Minimum vouch is 0.001 R", "err"); return; }
  try {
    $("vConfirm").disabled = true; $("vConfirm").textContent = "Confirming…";
    const tx = await wc.vouch(vouchTarget.memberId, { value: ethers.parseEther(String(v)) });
    toast("Vouch submitted…");
    await tx.wait();
    toast(`Vouched ${v} R on ${vouchTarget.name}`, "ok");
    $("vouchScrim").classList.remove("show");
    refreshChain();
  } catch (e) { toast(err(e), "err"); }
  finally { $("vConfirm").disabled = false; $("vConfirm").textContent = "Confirm vouch"; }
}

// ---- settle ----------------------------------------------------------
async function settle() {
  if (!account) { connect(); return; }
  try {
    $("settleBtn").disabled = true; $("settleBtn").textContent = "Settling…";
    const tx = await wc.settle(); await tx.wait();
    toast("Round settled. New round started.", "ok");
    refreshChain();
  } catch (e) { toast(err(e), "err"); }
  finally { $("settleBtn").disabled = false; $("settleBtn").textContent = "Settle round"; }
}

// ---- wallet drawer ---------------------------------------------------
async function refreshWallet() {
  if (!account || !ro) return;
  $("dAddr").textContent = account;
  $("dRound").textContent = "#" + roundInfo.id.toString();

  // active vouches this round: check members with live stake
  const active = [];
  for (const [id] of liveTotals) {
    const s = await ro.myStake(roundInfo.id, id, account);
    if (s > 0n) active.push({ m: byId.get(id), s });
  }
  $("dActive").innerHTML = active.length ? active.map(a => `
    <div class="row"><img src="${a.m.avatar}"/><div><div class="rn">${a.m.name}</div><div class="rs">@${a.m.handle}</div></div>
    <div class="right"><div class="rn" style="color:var(--violet-soft)">${fmt(a.s)} R</div><div class="rs">staked</div></div></div>`).join("")
    : '<div class="empty">No vouches this round yet.</div>';

  // claimable backer rewards from previous settled rounds (scan back up to 12)
  const claims = [];
  const cur = Number(roundInfo.id);
  for (let r = cur - 1; r >= Math.max(1, cur - 12); r--) {
    try {
      const pending = await ro.pendingBackerReward(r, account);
      if (pending > 0n) {
        const rd = await ro.getRound(r);
        claims.push({ round: r, amount: pending, winner: byId.get(Number(rd.winnerId)) });
      }
    } catch {}
  }
  $("dClaims").innerHTML = claims.length ? claims.map(c => `
    <div class="row">
      <img src="${c.winner?.avatar||''}"/>
      <div><div class="rn">Round #${c.round}</div><div class="rs">backed ${c.winner?.name||'winner'} 🏆</div></div>
      <div class="right"><div class="rn" style="color:var(--green)">${fmt(c.amount)} R</div>
      <button class="claim" data-claim="${c.round}">Claim</button></div>
    </div>`).join("")
    : '<div class="empty">Nothing to claim.</div>';
}

async function claim(round) {
  if (!wc) return;
  try {
    const tx = await wc.claimBackerReward(round);
    toast("Claiming…"); await tx.wait();
    toast("Claimed!", "ok"); refreshWallet();
  } catch (e) { toast(err(e), "err"); }
}

// ---- UI wiring -------------------------------------------------------
function wireUI() {
  $("connectBtn").onclick = () => account ? $("drawer").classList.add("show") : connect();
  $("myBtn").onclick = () => { $("drawer").classList.add("show"); refreshWallet(); };
  $("drawerClose").onclick = () => $("drawer").classList.remove("show");
  $("settleBtn").onclick = settle;

  $("grid").addEventListener("click", (e) => {
    // Whole card opens the vouch modal; the explicit button does too.
    const b = e.target.closest("[data-vouch]");
    const c = e.target.closest("[data-open]");
    if (b) openVouch(+b.dataset.vouch);
    else if (c) openVouch(+c.dataset.open);
  });
  $("vCancel").onclick = () => $("vouchScrim").classList.remove("show");
  $("vConfirm").onclick = confirmVouch;
  $("vouchScrim").addEventListener("click", (e)=>{ if(e.target.id==="vouchScrim") e.currentTarget.classList.remove("show"); });
  document.querySelectorAll(".chips button").forEach(c => c.onclick = () => $("vAmt").value = c.dataset.a);

  $("search").addEventListener("input", (e) => { searchQ = e.target.value; render(); });
  $("sortSeg").addEventListener("click", (e) => {
    const b = e.target.closest("[data-sort]"); if (!b) return;
    document.querySelectorAll("#sortSeg button").forEach(x=>x.classList.remove("active"));
    b.classList.add("active"); sortKey = b.dataset.sort; render();
  });
  $("dClaims").addEventListener("click", (e) => {
    const b = e.target.closest("[data-claim]"); if (b) claim(+b.dataset.claim);
  });
}
