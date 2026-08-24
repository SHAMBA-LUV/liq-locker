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
    resultEl.replaceChildren();
    resultEl.append("sent ");
    const a = el("a", "lk-link", hash.slice(0, 18) + "…");
    a.href = `${cfg.explorer}/tx/${hash}`; a.target = "_blank"; a.rel = "noopener";
    resultEl.append(a);
    resultEl.className = "iv ok";
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
    resultEl.replaceChildren("sent ");
    const a = el("a", "lk-link", hash.slice(0, 18) + "…");
    a.href = `${cfg.explorer}/tx/${hash}`; a.target = "_blank"; a.rel = "noopener";
    resultEl.append(a);
    resultEl.className = "iv ok";
  } catch (e) { resultEl.textContent = `✗ ${e.message}`; resultEl.className = "iv bad"; }
}

// ── the guided path: status → approve → lock → view ────────────────────────
const SEL = { balanceOf: "0x70a08231", allowance: "0xdd62ed3e" };
const padAddr = (a) => a.toLowerCase().replace(/^0x/, "").padStart(64, "0");

async function pairRead(selector, addrs) {
  const data = selector + addrs.map(padAddr).join("");
  const out = await reader.rpc("eth_call", [{ to: PAIR, data }, "latest"]);
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
    const [locked] = await reader.call("total_locked", [PAIR]);
    let mine = "connect to see your LP balance";
    if (signer) {
      const bal = await pairRead(SEL.balanceOf, [signer.account]);
      const allo = await pairRead(SEL.allowance, [signer.account, cfg.locker]);
      mine = `your LP: ${bal}  ·  approved to locker: ${allo}`;
    }
    s.textContent = `locks: ${count}  ·  LP held by locker: ${locked}  ·  ${mine}`;
    s.className = "iv ok";
  } catch (e) { s.textContent = `✗ ${e.message}`; s.className = "iv bad"; }
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
      const amount = BigInt($("gAmount").value.trim());
      const data = "0x095ea7b3" + padAddr(cfg.locker) + amount.toString(16).padStart(64, "0");
      r.textContent = "sign the approve in your wallet…"; r.className = "iv muted";
      const hash = await signer.provider.request({
        method: "eth_sendTransaction",
        params: [{ from: signer.account, to: PAIR, data }],
      });
      if (await waitMined(hash, r, "approve")) { await refreshStatus(); r.textContent += " — proceed to ②"; }
    } catch (e) { r.textContent = `✗ ${e.message}`; r.className = "iv bad"; }
  };
  $("gLock").onclick = async () => {
    const r = $("gr2");
    if (!signer) { r.textContent = "connect a wallet first"; r.className = "iv bad"; return; }
    try {
      const amount = BigInt($("gAmount").value.trim());
      const allo = await pairRead(SEL.allowance, [signer.account, cfg.locker]);
      if (allo < amount) { r.textContent = `✗ approved ${allo} < amount ${amount} — run ① first`; r.className = "iv bad"; return; }
      r.textContent = "sign the lock in your wallet…"; r.className = "iv muted";
      const hash = await signer.send("lock_default", [PAIR, amount, "0x0000000000000000000000000000000000000000"]);
      if (await waitMined(hash, r, "lock_default")) {
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

  $("apToken").value = PAIR;
  $("apGo").onclick = () => approve($("apResult"), $("apAmount").value);

  $("connect").onclick = async () => {
    try {
      signer = await Signer.connect(cfg);
      $("who").textContent = `${signer.account.slice(0, 8)}…${signer.account.slice(-4)} · writes armed`;
      $("who").className = "iv ok";
      $("gr1").textContent = "armed — set the amount and sign ①";
      refreshStatus();
    } catch (e) {
      $("who").textContent = `✗ ${e.message}`;
      $("who").className = "iv bad";
    }
  };
  mountGuided();
}
mount();
