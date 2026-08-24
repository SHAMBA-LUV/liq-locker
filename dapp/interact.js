// SPDX-License-Identifier: Apache-2.0
// interact.js — the WHOLE surface. Every function in the ABI, generated from the ABI:
// reads run against the public RPC with no wallet; writes arm only after an explicit
// connect. A function this page cannot show is a function the contract does not have.
import { ETHEREUM, Reader, Signer, encodeCall, formatUnits } from "./app.js";
import { LIQUIDITY_LOCKER_ABI } from "./abi.js";

const cfg = ETHEREUM;
const reader = new Reader(cfg);
let signer = null;

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
};

const fns = LIQUIDITY_LOCKER_ABI.filter((e) => e.type === "function");
const reads = fns.filter((f) => f.stateMutability === "view" || f.stateMutability === "pure");
const writes = fns.filter((f) => f.stateMutability === "nonpayable" || f.stateMutability === "payable");
const events = LIQUIDITY_LOCKER_ABI.filter((e) => e.type === "event");

const sigOf = (f) => `${f.name}(${f.inputs.map((i) => `${i.type} ${i.name}`).join(", ")})`;

function parseArg(input, value) {
  const v = value.trim();
  if (input.type === "address") {
    if (!/^0x[0-9a-fA-F]{40}$/.test(v)) throw new Error(`${input.name}: not an address`);
    return v;
  }
  if (!/^\d+$/.test(v)) throw new Error(`${input.name}: expected an unsigned integer`);
  return BigInt(v);
}

function renderValue(out, v) {
  if (typeof v === "bigint") {
    let s = v.toString();
    if (out.type === "uint256" && v >= 10n ** 15n) s += `  (${formatUnits(v)} × 1e18)`;
    if ((out.type === "uint48" || out.name.includes("unlock_at")) && v > 1_500_000_000n && v < 10_000_000_000n) {
      s += `  (${new Date(Number(v) * 1000).toISOString()})`;
    }
    return s;
  }
  return String(v);
}

async function callRead(f, args, resultEl) {
  resultEl.textContent = "calling…";
  resultEl.className = "iv muted";
  try {
    let values;
    if (f.name === "locks_of") {
      values = [await reader.locksOf(args[0])];
      resultEl.textContent = `ids: [${values[0].join(", ")}]  (${values[0].length} lock${values[0].length === 1 ? "" : "s"})`;
      resultEl.className = "iv ok";
      return;
    }
    values = await reader.call(f.name, args);
    resultEl.textContent = f.outputs
      .map((o, i) => `${o.name || "→"}: ${renderValue(o, values[i])}`)
      .join("   ·   ");
    resultEl.className = "iv ok";
  } catch (e) {
    resultEl.textContent = `✗ ${e.message}`;
    resultEl.className = "iv bad";
  }
}

async function sendWrite(f, args, resultEl) {
  if (!signer) { resultEl.textContent = "connect a wallet first — writes need a signature"; resultEl.className = "iv bad"; return; }
  resultEl.textContent = "sign in your wallet…";
  resultEl.className = "iv muted";
  try {
    const hash = await signer.send(f.name, args);
    histRecord(signer.account, { label: `${f.name}(${args.join(", ")})`, hash });
    resultEl.replaceChildren();
    resultEl.append("sent ");
    const a = el("a", "lk-link", hash.slice(0, 18) + "…");
    a.href = `${cfg.explorer}/tx/${hash}`; a.target = "_blank"; a.rel = "noopener";
    resultEl.append(a);
    resultEl.className = "iv ok";
    waitMined(hash, resultEl, f.name).then((ok) =>
      histUpdate(signer.account, hash, ok === true ? { status: "confirmed" } : ok === false ? { status: "reverted" } : {}));
  } catch (e) {
    resultEl.textContent = `✗ ${e.message}`;
    resultEl.className = "iv bad";
  }
}

function row(f, isWrite) {
  const r = el("div", "irow");
  const head = el("div", "isig");
  head.append(el("code", null, sigOf(f)));
  r.append(head);
  const controls = el("div", "ictrl");
  const inputs = f.inputs.map((input) => {
    const box = el("input", "iarg");
    box.placeholder = `${input.name || "arg"} · ${input.type}`;
    if (input.type === "address" && /token|pair/.test(input.name || "")) box.value = PAIR;
    controls.append(box);
    return { input, box };
  });
  const btn = el("button", isWrite ? "ibtn write" : "ibtn", isWrite ? "SIGN" : "CALL");
  controls.append(btn);
  r.append(controls);
  const result = el("div", "iv muted", isWrite ? "wallet-gated" : "");
  r.append(result);
  btn.onclick = () => {
    let args;
    try { args = inputs.map(({ input, box }) => parseArg(input, box.value)); }
    catch (e) { result.textContent = `✗ ${e.message}`; result.className = "iv bad"; return; }
    return isWrite ? sendWrite(f, args, result) : callRead(f, args, result);
  };
  if (!isWrite && f.inputs.length === 0) callRead(f, [], result); // constants: read on load
  return r;
}

// The pair the locker exists to hold; prefilled wherever a token address is asked for.
const PAIR = "0x57D2085Aa859a145cB107845AD03c0eAAFBD8a31";

// ── approve helper: the one call that lives on the TOKEN, not the locker ──
// lock_* pulls via transferFrom, so the pair must approve the locker first.
async function approve(resultEl, amountRaw) {
  if (!signer) { resultEl.textContent = "connect a wallet first"; resultEl.className = "iv bad"; return; }
  try {
    const amount = BigInt(amountRaw.trim());
    const data = "0x095ea7b3" // approve(address,uint256)
      + cfg.locker.toLowerCase().replace(/^0x/, "").padStart(64, "0")
      + amount.toString(16).padStart(64, "0");
    resultEl.textContent = "sign in your wallet…"; resultEl.className = "iv muted";
    const hash = await signer.provider.request({
      method: "eth_sendTransaction",
      params: [{ from: signer.account, to: $("apToken").value.trim(), data }],
    });
    histRecord(signer.account, { label: `approve(locker, ${amount}) on ${$("apToken").value.trim().slice(0, 10)}…`, hash });
    waitMined(hash, resultEl, "approve").then((ok) =>
      histUpdate(signer.account, hash, { status: ok ? "confirmed" : "reverted" }));
    resultEl.replaceChildren("sent ");
    const a = el("a", "lk-link", hash.slice(0, 18) + "…");
    a.href = `${cfg.explorer}/tx/${hash}`; a.target = "_blank"; a.rel = "noopener";
    resultEl.append(a);
    resultEl.className = "iv ok";
  } catch (e) { resultEl.textContent = `✗ ${e.message}`; resultEl.className = "iv bad"; }
}

// ── .history — the per-address transaction ledger ──────────────────────────
// Every transaction this page sends is recorded when it leaves the wallet and
// updated when it mines, keyed by the sending address, persisted in the
// browser's localStorage. Reloads, other tabs, next week: the ledger holds.
const HIST_PREFIX = "liq-locker.history.";
const histKey = (addr) => HIST_PREFIX + addr.toLowerCase();

function histLoad(addr) {
  try { return JSON.parse(localStorage.getItem(histKey(addr)) || "[]"); }
  catch { return []; }
}
function histSave(addr, rows) {
  try { localStorage.setItem(histKey(addr), JSON.stringify(rows)); } catch { /* private window etc. */ }
}
function histRecord(addr, entry) {
  const rows = histLoad(addr);
  rows.push({ at: new Date().toISOString(), status: "sent", ...entry });
  histSave(addr, rows);
  renderHistory();
}
function histUpdate(addr, hash, patch) {
  const rows = histLoad(addr);
  const row = rows.find((r) => r.hash === hash);
  if (row) Object.assign(row, patch);
  histSave(addr, rows);
  renderHistory();
}

// Transactions that predate the ledger, seeded once per address so the record is
// complete from the contract's first breath.
const HIST_SEED = {
  "0x10f7ee226b16bea7f365dc1edef159fc1957d169": [
    { at: "2026-08-24T04:57:00Z", label: "Create3d.deploy → liquidity_locker", status: "confirmed", block: 25822914,
      hash: "0x113ba138d140f7ec0ca75c8697d69b7e8a931d508515ded6cee1523c5627f38d" },
    { at: "2026-08-24T20:40:00Z", label: "approve(locker, unlimited) on the LUV/WETH pair", status: "confirmed", block: 25827621,
      hash: "0xf2ab3e27efd82cee3cc57c17397119a57d2d6b8615304405f12d1451a963c422" },
  ],
};
function histSeed(addr) {
  const seed = HIST_SEED[addr.toLowerCase()];
  if (!seed) return;
  const rows = histLoad(addr);
  let added = false;
  for (const s of seed) if (!rows.some((r) => r.hash === s.hash)) { rows.push(s); added = true; }
  if (added) { rows.sort((a, b) => a.at.localeCompare(b.at)); histSave(addr, rows); }
}

function renderHistory() {
  const box = $("history");
  if (!box) return;
  box.replaceChildren();
  if (!signer) {
    box.append(el("p", "iv muted", "connect a wallet — the ledger is kept per address, in this browser, and survives reloads"));
    return;
  }
  const rows = histLoad(signer.account);
  $("histwho").textContent = `${signer.account} · ${rows.length} transaction${rows.length === 1 ? "" : "s"} recorded`;
  if (!rows.length) {
    box.append(el("p", "iv muted", "no transactions recorded yet for this address — they will appear here the moment one is sent"));
    return;
  }
  for (const r of [...rows].reverse()) {
    const line = el("div", "irow");
    const head = el("div", "isig");
    head.append(el("code", null, `${r.label}`));
    line.append(head);
    const meta = el("div", r.status === "confirmed" ? "iv ok" : r.status === "reverted" ? "iv bad" : "iv muted");
    meta.append(`${r.at} · ${r.status}${r.block ? ` in block ${r.block}` : ""} · `);
    const a = el("a", "lk-link", r.hash.slice(0, 18) + "…");
    a.href = `${cfg.explorer}/tx/${r.hash}`; a.target = "_blank"; a.rel = "noopener";
    meta.append(a);
    line.append(meta);
    box.append(line);
  }
}

// ── LP pairs in the wallet ─────────────────────────────────────────────────
// No indexer, no API key, no third party: Uniswap V2 pair addresses are CREATE2 —
// pair = keccak(0xff ++ factory ++ keccak(token0 ++ token1) ++ initCodeHash) — so the
// page COMPUTES the pair address for every combination of a known token basket and
// asks the chain two things: does code live there, and what is your balance.
const V2_FACTORY = "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f";
const V2_INIT = "96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f";
const BASKET = {
  LUV: "0x2711111111683B8708cb9a48cBf36a51315F8254",
  WETH: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  USDT: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
  DAI: "0x6B175474E89094C44Da98b954EedeAC495271d0F",
  WBTC: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
};
let activePair = PAIR; // the LUV/WETH default; the pair scanner can re-point it

const unhex = (h) => {
  const s = h.replace(/^0x/, "");
  const a = new Uint8Array(s.length / 2);
  for (let i = 0; i < a.length; i++) a[i] = parseInt(s.substr(i * 2, 2), 16);
  return a;
};

async function pairFor(a, b) {
  const { keccak256 } = await import("./modules/keccak.js");
  const [t0, t1] = a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
  const salt = keccak256(unhex(t0.slice(2) + t1.slice(2)));
  const addr = keccak256(unhex("ff" + V2_FACTORY.slice(2) + salt + V2_INIT));
  return "0x" + addr.slice(-40);
}

async function scanPairs() {
  const box = $("pairlist");
  box.replaceChildren(el("p", "iv muted", "computing pair addresses and asking the chain…"));
  const who = signer ? signer.account : null;
  const names = Object.keys(BASKET);
  const combos = [];
  for (let i = 0; i < names.length; i++)
    for (let j = i + 1; j < names.length; j++) combos.push([names[i], names[j]]);
  const rows = [];
  await Promise.all(combos.map(async ([na, nb]) => {
    const p = await pairFor(BASKET[na], BASKET[nb]);
    const code = await reader.rpc("eth_getCode", [p, "latest"]);
    if (!code || code === "0x") return; // this pair was never created
    const bal = who ? await pairRead2(p, SEL.balanceOf, [who]) : null;
    rows.push({ name: `${na}/${nb}`, pair: p, bal });
  }));
  rows.sort((a, b) => (b.bal ?? 0n) > (a.bal ?? 0n) ? 1 : -1);
  box.replaceChildren();
  if (!rows.length) { box.append(el("p", "iv muted", "no pairs from the basket exist on-chain")); return; }
  for (const r of rows) {
    const line = el("div", "irow");
    const head = el("div", "isig");
    head.append(el("code", null, `${r.name} · ${r.pair}${r.pair.toLowerCase() === activePair.toLowerCase() ? "  ← active" : ""}`));
    line.append(head);
    const meta = el("div", r.bal && r.bal > 0n ? "iv ok" : "iv muted");
    meta.append(r.bal === null ? "connect to see your balance"
      : r.bal === 0n ? "your balance: 0"
      : `your balance: ${r.bal} LP wei (≈ ${formatUnits(r.bal)} LP)`);
    line.append(meta);
    const ctl = el("div", "ictrl");
    const use = el("button", "ibtn", "use this pair in the guided path");
    use.onclick = () => { activePair = r.pair; refreshStatus(); scanPairs(); };
    const a = el("a", "lk-link", "etherscan ↗");
    a.href = `${cfg.explorer}/address/${r.pair}`; a.target = "_blank"; a.rel = "noopener";
    ctl.append(use, a);
    line.append(ctl);
    box.append(line);
  }
}

// balanceOf/allowance against an arbitrary token (the pair-scan needs per-pair reads)
async function pairRead2(token, selector, addrs) {
  const data = selector + addrs.map((a) => a.toLowerCase().replace(/^0x/, "").padStart(64, "0")).join("");
  const out = await reader.rpc("eth_call", [{ to: token, data }, "latest"]);
  return BigInt(out);
}

// ── the guided path: status → approve → lock → view ────────────────────────
const SEL = { balanceOf: "0x70a08231", allowance: "0xdd62ed3e" };
const padAddr = (a) => a.toLowerCase().replace(/^0x/, "").padStart(64, "0");

async function pairRead(selector, addrs) {
  const data = selector + addrs.map(padAddr).join("");
  const out = await reader.rpc("eth_call", [{ to: activePair, data }, "latest"]);
  return BigInt(out);
}

async function waitMined(hash, resultEl, label) {
  for (let i = 0; i < 60; i++) {
    const rc = await reader.rpc("eth_getTransactionReceipt", [hash]);
    if (rc) {
      const ok = BigInt(rc.status) === 1n;
      resultEl.textContent = `${label} ${ok ? "✓ confirmed" : "✗ REVERTED"} in block ${Number(BigInt(rc.blockNumber))}`;
      resultEl.className = ok ? "iv ok" : "iv bad";
      return ok;
    }
    resultEl.textContent = `${label} sent — waiting for the chain… (${2 * (i + 1)}s)`;
    await new Promise((r) => setTimeout(r, 2000));
  }
  resultEl.textContent = `${label} sent but not yet mined — check the tx on Etherscan`;
  return false;
}

async function refreshStatus() {
  const s = $("gstat");
  try {
    const [count] = await reader.call("lock_count");
    const [locked] = await reader.call("total_locked", [activePair]);
    let mine = "connect to see your LP balance";
    if (signer) {
      const bal = await pairRead(SEL.balanceOf, [signer.account]);
      const allo = await pairRead(SEL.allowance, [signer.account, cfg.locker]);
      mine = `your LP: ${bal}  ·  approved to locker: ${allo}`;
    }
    s.textContent = `active pair: ${activePair}  ·  locks: ${count}  ·  LP held by locker: ${locked}  ·  ${mine}`;
    s.className = "iv ok";
  } catch (e) { s.textContent = `✗ ${e.message}`; s.className = "iv bad"; }
}

// The amount field takes LP wei — a decimal integer. An address pasted here parses as a
// huge hex number and produces transfer_from_failed() at the wallet (seen live, once).
function readAmount(resultEl) {
  const v = $("gAmount").value.trim();
  if (/^0x/i.test(v) || /[a-fA-F]/.test(v)) {
    resultEl.textContent = "✗ that looks like an ADDRESS — the amount field takes LP wei (a decimal number). Press 'set 0.001 LP' or 'set FULL balance'.";
    resultEl.className = "iv bad";
    return null;
  }
  if (!/^\d+$/.test(v) || BigInt(v) === 0n) {
    resultEl.textContent = "✗ amount must be a positive decimal integer, in LP wei";
    resultEl.className = "iv bad";
    return null;
  }
  return BigInt(v);
}

function mountGuided() {
  $("gRefresh").onclick = refreshStatus;
  $("gDust").onclick = () => { $("gAmount").value = "1000000000000000"; };
  $("gFull").onclick = async () => {
    if (!signer) { $("gr1").textContent = "connect a wallet first — the full balance is read from your account"; $("gr1").className = "iv bad"; return; }
    const bal = await pairRead(SEL.balanceOf, [signer.account]);
    $("gAmount").value = bal.toString();
    $("gr1").textContent = `amount set to your full balance, read at click time: ${bal} LP wei`;
    $("gr1").className = "iv ok";
  };
  $("gApprove").onclick = async () => {
    const r = $("gr1");
    if (!signer) { r.textContent = "connect a wallet first"; r.className = "iv bad"; return; }
    try {
      const amount = readAmount(r);
      if (amount === null) return;
      const data = "0x095ea7b3" + padAddr(cfg.locker) + amount.toString(16).padStart(64, "0");
      r.textContent = "sign the approve in your wallet…"; r.className = "iv muted";
      const hash = await signer.provider.request({
        method: "eth_sendTransaction",
        params: [{ from: signer.account, to: activePair, data }],
      });
      histRecord(signer.account, { label: `approve(locker, ${amount})`, hash });
      const ok = await waitMined(hash, r, "approve");
      histUpdate(signer.account, hash, { status: ok ? "confirmed" : "reverted" });
      if (ok) { await refreshStatus(); r.textContent += " — proceed to ②"; }
    } catch (e) { r.textContent = `✗ ${e.message}`; r.className = "iv bad"; }
  };
  $("gLock").onclick = async () => {
    const r = $("gr2");
    if (!signer) { r.textContent = "connect a wallet first"; r.className = "iv bad"; return; }
    try {
      const amount = readAmount(r);
      if (amount === null) return;
      const bal = await pairRead(SEL.balanceOf, [signer.account]);
      if (amount > bal) { r.textContent = `✗ amount ${amount} exceeds your LP balance ${bal} — the pull would revert (transfer_from_failed)`; r.className = "iv bad"; return; }
      const allo = await pairRead(SEL.allowance, [signer.account, cfg.locker]);
      if (allo < amount) { r.textContent = `✗ approved ${allo} < amount ${amount} — run ① first`; r.className = "iv bad"; return; }
      r.textContent = "sign the lock in your wallet…"; r.className = "iv muted";
      const hash = await signer.send("lock_default", [activePair, amount, "0x0000000000000000000000000000000000000000"]);
      histRecord(signer.account, { label: `lock_default(pair, ${amount}, self)`, hash });
      const ok = await waitMined(hash, r, "lock_default");
      histUpdate(signer.account, hash, { status: ok ? "confirmed" : "reverted" });
      if (ok) {
        await refreshStatus();
        const [count] = await reader.call("lock_count");
        r.textContent += ` — lock #${count - 1n} created. Press ③ to read it back.`;
      }
    } catch (e) { r.textContent = `✗ ${e.message}`; r.className = "iv bad"; }
  };
  $("gView").onclick = async () => {
    const r = $("gr3");
    try {
      const [count] = await reader.call("lock_count");
      if (count === 0n) { r.textContent = "no locks exist yet — run ① and ② first"; r.className = "iv muted"; return; }
      const id = count - 1n;
      const v = await reader.lockView(id);
      r.replaceChildren();
      r.append(`lock #${id}  ·  token ${v.token}  ·  principal ${v.amount} LP wei  ·  `
        + `beneficiary ${v.beneficiary}  ·  opens ${new Date(v.unlockAt * 1000).toISOString()}  ·  `
        + `${v.isLocked ? "🔒 LOCKED" : "matured"}  ·  `);
      const a = el("a", "lk-link", `open the lock panel (?id=${id})`);
      a.href = `./index.html?id=${id}`;
      r.append(a);
      r.className = "iv ok";
    } catch (e) { r.textContent = `✗ ${e.message}`; r.className = "iv bad"; }
  };
  refreshStatus();
}

function mount() {
  $("addr").textContent = cfg.locker;
  $("addr").href = `${cfg.explorer}/address/${cfg.locker}#code`;
  $("evlink").href = `${cfg.explorer}/address/${cfg.locker}#events`;
  $("evlist").textContent = events.map((e) => `${e.name}(${e.inputs.map((i) => i.type).join(",")})`).join(" · ");

  const readBox = $("reads"), writeBox = $("writes");
  reads.forEach((f) => readBox.append(row(f, false)));
  writes.forEach((f) => writeBox.append(row(f, true)));

  $("pairScan").onclick = scanPairs;
  $("pairCheck").onclick = async () => {
    const box = $("pairlist");
    const p = $("pairManual").value.trim();
    if (!/^0x[0-9a-fA-F]{40}$/.test(p)) { box.replaceChildren(el("p", "iv bad", "✗ not an address")); return; }
    try {
      // a V2 pair answers token0()/token1(); anything else reverts or returns nothing
      const t0 = "0x" + (await reader.rpc("eth_call", [{ to: p, data: "0x0dfe1681" }, "latest"])).slice(-40);
      const t1 = "0x" + (await reader.rpc("eth_call", [{ to: p, data: "0xd21220a7" }, "latest"])).slice(-40);
      const bal = signer ? await pairRead2(p, SEL.balanceOf, [signer.account]) : null;
      const line = el("div", "irow");
      line.append(el("div", "isig"));
      line.firstChild.append(el("code", null, `pair ${p} · token0 ${t0} · token1 ${t1}`));
      const meta = el("div", bal && bal > 0n ? "iv ok" : "iv muted");
      meta.append(bal === null ? "connect to see your balance" : `your balance: ${bal} LP wei (≈ ${formatUnits(bal ?? 0n)} LP)`);
      line.append(meta);
      const ctl = el("div", "ictrl");
      const use = el("button", "ibtn", "use this pair in the guided path");
      use.onclick = () => { activePair = p; refreshStatus(); };
      ctl.append(use);
      line.append(ctl);
      box.replaceChildren(line);
    } catch (e) { box.replaceChildren(el("p", "iv bad", `✗ not a readable V2 pair: ${e.message}`)); }
  };

  $("apToken").value = PAIR;
  $("apGo").onclick = () => approve($("apResult"), $("apAmount").value);

  $("connect").onclick = async () => {
    try {
      signer = await Signer.connect(cfg);
      $("who").textContent = `${signer.account.slice(0, 8)}…${signer.account.slice(-4)} · writes armed`;
      $("who").className = "iv ok";
      $("gr1").textContent = "armed — set the amount and sign ①";
      histSeed(signer.account);
      renderHistory();
      refreshStatus();
      scanPairs(); // balances per pair fill in once we know who you are
    } catch (e) {
      $("who").textContent = `✗ ${e.message}`;
      $("who").className = "iv bad";
    }
  };
  mountGuided();
}
mount();
