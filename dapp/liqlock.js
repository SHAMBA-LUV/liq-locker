// SPDX-License-Identifier: Apache-2.0
// liqlock.js — the public proof page. READ-ONLY: no wallet, no writes, no consent asked,
// because none is needed — every number on this page is an eth_call anyone can repeat.
// The claim "the liquidity is locked" should be checkable, not believable.
import { ETHEREUM, Reader, formatUnits } from "./app.js";

const cfg = ETHEREUM;
const reader = new Reader(cfg);
const PAIR = "0x57D2085Aa859a145cB107845AD03c0eAAFBD8a31";
const LUV = "0x2711111111683B8708cb9a48cBf36a51315F8254";
const TREASURY = "0x10f7Ee226B16bea7f365Dc1eDEF159Fc1957D169";

// The paper trail — transaction hashes are facts, not claims.
const TRAIL = [
  { label: "deploy — Create3d → the locker, at a deterministic every-chain address",
    hash: "0x113ba138d140f7ec0ca75c8697d69b7e8a931d508515ded6cee1523c5627f38d", block: 25822914 },
  { label: "approve — the pair permits the locker to pull LP",
    hash: "0xf2ab3e27efd82cee3cc57c17397119a57d2d6b8615304405f12d1451a963c422", block: 25827621 },
  { label: "lock #0 — 0.001 LP, the dust rehearsal, 90 days",
    hash: "0x30748af283c482f0bc8746e53f9f40ce1496ed4c6e64c46d5839a25f03670b72", block: 25827695 },
];

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
};
const link = (href, text) => {
  const a = el("a", "lk-link", text);
  a.href = href; a.target = "_blank"; a.rel = "noopener";
  return a;
};
const pad = (a) => a.toLowerCase().replace(/^0x/, "").padStart(64, "0");

async function erc20(token, selector, addrs = []) {
  const out = await reader.rpc("eth_call", [{ to: token, data: selector + addrs.map(pad).join("") }, "latest"]);
  return BigInt(out);
}

async function refresh() {
  try {
    const [count] = await reader.call("lock_count");
    const [locked] = await reader.call("total_locked", [PAIR]);
    const supply = await erc20(PAIR, "0x18160ddd");           // pair totalSupply
    const treasuryLP = await erc20(PAIR, "0x70a08231", [TREASURY]);
    const circulating = supply - 1000n;                        // MINIMUM_LIQUIDITY is burned
    const pct = circulating > 0n ? Number(locked * 1_000_000n / circulating) / 10_000 : 0;

    $("s-locks").textContent = count.toString();
    $("s-locked").textContent = `${locked} LP wei  (≈ ${formatUnits(locked)} LP)`;
    $("s-pct").textContent = `${pct.toFixed(4)} % of all circulating LUV/WETH liquidity`;
    $("s-treasury").textContent = `${treasuryLP} LP wei  (≈ ${formatUnits(treasuryLP)} LP) still unlocked in the treasury`;
    $("s-read").textContent = `read live at ${new Date().toISOString()} — refresh the page to re-ask the chain`;

    const box = $("locks");
    box.replaceChildren();
    if (count === 0n) { box.append(el("p", "iv muted", "no locks yet")); return; }
    const now = Math.floor(Date.now() / 1000);
    for (let id = 0n; id < count; id++) {
      const [token, beneficiary, amount, unlockAt, withdrawn] = await reader.call("lock_at", [id]);
      const [secsLeft, blocksLeft] = await reader.call("time_remaining", [id]);
      const [isLocked] = await reader.call("is_locked", [id]);
      const ua = Number(unlockAt);
      const leftDays = Number(secsLeft) / 86400;
      const row = el("div", "irow");
      const head = el("div", "isig");
      head.append(el("code", null, `lock #${id} — ${formatUnits(amount)} LP (${amount} wei)`));
      row.append(head);
      const meta = el("div", isLocked ? "iv ok" : "iv muted");
      meta.append(
        `${withdrawn ? "withdrawn" : isLocked ? "🔒 LOCKED" : "matured, unclaimed"}  ·  `
        + `opens ${new Date(ua * 1000).toISOString()}  ·  ${leftDays.toFixed(1)} days left`
        + (blocksLeft > 0n ? `  ·  block gate: ${blocksLeft} blocks` : "  ·  time gate only")
        + `  ·  token ${token.slice(0, 10)}…  ·  beneficiary ${beneficiary.slice(0, 10)}…`);
      row.append(meta);
      box.append(row);
    }
  } catch (e) {
    $("s-read").textContent = `read failed: ${e.message} — the chain is the source; try again`;
  }
}

function mountStatic() {
  $("c-locker").replaceChildren(link(`${cfg.explorer}/address/${cfg.locker}#code`, cfg.locker));
  $("c-pair").replaceChildren(link(`${cfg.explorer}/address/${PAIR}`, PAIR));
  $("c-luv").replaceChildren(link(`${cfg.explorer}/token/${LUV}`, LUV));
  const trail = $("trail");
  for (const t of TRAIL) {
    const row = el("div", "irow");
    row.append(el("div", "isig"));
    row.firstChild.append(el("code", null, t.label));
    const meta = el("div", "iv ok");
    meta.append(`block ${t.block} · `);
    meta.append(link(`${cfg.explorer}/tx/${t.hash}`, t.hash.slice(0, 22) + "… ↗"));
    row.append(meta);
    trail.append(row);
  }
}

mountStatic();
refresh();
setInterval(refresh, 60_000);
