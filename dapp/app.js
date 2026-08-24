// SPDX-License-Identifier: Apache-2.0
// (c) 2026 BANKON / cypherpunk2048
//
// app.ts — the chain layer. Everything that knows what a transaction is lives here;
// nothing above this file imports a wallet library.
//
// WEB2 / WEB3 CROSSOVER. The panel must render, and be useful, for a visitor with no
// wallet at all. A locker's state is public — reserves, maturity, collectable growth —
// so the read path runs over a plain JSON-RPC endpoint and needs no signer, no
// extension, no prompt. Connecting a wallet adds the ability to SIGN; it is not the
// price of admission to LOOK. That split is the whole shape of this file:
//
//     read  →  a public RPC, always available, no consent required
//     write →  an injected EIP-1193 provider, only after an explicit click
//
// A dapp that greets a stranger with a wallet prompt has asked for a commitment before
// showing them anything worth committing to.
import { LIQUIDITY_LOCKER_ABI } from "./abi.js";
/** Mainnet by default; the panel works against anvil by swapping this object. */
export const ETHEREUM = {
    chainId: 1,
    name: "Ethereum",
    rpc: "https://ethereum-rpc.publicnode.com",
    explorer: "https://etherscan.io",
    // The live deployment (2026-08-24): deployed via Create3d at salt "liq-locker.piscixoq"
    // — deployer-namespaced, so this address is reproducible on EVERY chain by the treasury
    // alone. Etherscan-verified. Record: deploy/mainnet.json.
    locker: "0x111111f70cb3469B5285862d7a4e7Cb53d04f502",
};
// ── minimal ABI coder ──────────────────────────────────────────────────────
// No ethers, no viem, no build step. The whole surface this panel needs is uint256,
// address, bool, uint48 and one dynamic array — small enough to encode honestly and
// small enough to audit, which matters more here than saving thirty lines.
const selectorCache = new Map();
async function keccakSelector(signature) {
    const cached = selectorCache.get(signature);
    if (cached)
        return cached;
    // Selectors are precomputed in abi.js at build time in production; this path exists
    // so the panel still works when opened straight from disk.
    const { keccak256 } = await import("./modules/keccak.js");
    const sel = "0x" + keccak256(new TextEncoder().encode(signature)).slice(0, 8);
    selectorCache.set(signature, sel);
    return sel;
}
const pad = (hex) => hex.replace(/^0x/, "").padStart(64, "0");
const encUint = (v) => pad(BigInt(v).toString(16));
const encAddr = (a) => pad(a.toLowerCase());
function abiFor(name) {
    const f = LIQUIDITY_LOCKER_ABI.find((x) => x.type === "function" && x.name === name);
    if (!f)
        throw new Error(`no such function in ABI: ${name} — regenerate abi.js`);
    return f;
}
function signatureOf(name) {
    const f = abiFor(name);
    return `${name}(${f.inputs.map((i) => i.type).join(",")})`;
}
export async function encodeCall(name, args) {
    const f = abiFor(name);
    if (args.length !== f.inputs.length) {
        throw new Error(`${name} expects ${f.inputs.length} args, got ${args.length}`);
    }
    const body = f.inputs
        .map((input, i) => input.type === "address" ? encAddr(String(args[i])) : encUint(args[i]))
        .join("");
    return (await keccakSelector(signatureOf(name))) + body;
}
/** Decode a return blob against the ABI's declared outputs. */
export function decodeReturn(name, data) {
    const f = abiFor(name);
    const raw = data.replace(/^0x/, "");
    return f.outputs.map((out, i) => {
        const word = raw.slice(i * 64, (i + 1) * 64);
        if (out.type === "address")
            return ("0x" + word.slice(24));
        if (out.type === "bool")
            return BigInt("0x" + word) !== 0n;
        return BigInt("0x" + (word || "0"));
    });
}
// ── read path: no wallet, ever ─────────────────────────────────────────────
export class Reader {
    cfg;
    constructor(cfg) {
        this.cfg = cfg;
    }
    async rpc(method, params) {
        const res = await fetch(this.cfg.rpc, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
        });
        const json = await res.json();
        if (json.error)
            throw new Error(json.error.message ?? "rpc error");
        return json.result;
    }
    async call(name, args = []) {
        if (this.cfg.locker === "0x0000000000000000000000000000000000000000") {
            throw new Error("locker address not configured — set ChainConfig.locker");
        }
        const data = await encodeCall(name, args);
        const out = await this.rpc("eth_call", [{ to: this.cfg.locker, data }, "latest"]);
        return decodeReturn(name, out);
    }
    /** Everything the panel shows for one lock, in a single shape. */
    async lockView(id) {
        const [token, beneficiary, amount, unlockAt, withdrawn] = await this.call("lock_at", [id]);
        const [collectable] = await this.call("collectable", [id]);
        const [isLocked] = await this.call("is_locked", [id]);
        return { id, token, beneficiary, amount, unlockAt: Number(unlockAt), withdrawn, collectable, isLocked };
    }
    async locksOf(owner) {
        const data = await encodeCall("locks_of", [owner]);
        const raw = await this.rpc("eth_call", [{ to: this.cfg.locker, data }, "latest"]);
        const body = raw.replace(/^0x/, "");
        const len = Number(BigInt("0x" + body.slice(64, 128)));
        return Array.from({ length: len }, (_, i) => BigInt("0x" + body.slice(128 + i * 64, 192 + i * 64)));
    }
}
// ── write path: only after an explicit connect ─────────────────────────────
export class Signer {
    provider;
    cfg;
    account;
    constructor(provider, cfg, account) {
        this.provider = provider;
        this.cfg = cfg;
        this.account = account;
    }
    /** Never called on load. Only from a click — see dapp.tsx. */
    static async connect(cfg) {
        const injected = globalThis.ethereum;
        if (!injected)
            throw new Error("no wallet found — the panel still reads without one");
        const accounts = await injected.request({ method: "eth_requestAccounts" });
        const chainId = Number(await injected.request({ method: "eth_chainId" }));
        if (chainId !== cfg.chainId) {
            throw new Error(`wrong network: connected to ${chainId}, expected ${cfg.chainId} (${cfg.name})`);
        }
        return new Signer(injected, cfg, accounts[0]);
    }
    async send(name, args = []) {
        const data = await encodeCall(name, args);
        return this.provider.request({
            method: "eth_sendTransaction",
            params: [{ from: this.account, to: this.cfg.locker, data }],
        });
    }
    /** COLLECT. The growth, without the principal. */
    collect(id) {
        return this.send("collect", [id]);
    }
    collectTo(id, to) {
        return this.send("collect_to", [id, to]);
    }
    withdraw(id) {
        return this.send("withdraw", [id]);
    }
    extend(id, until) {
        return this.send("extend", [id, BigInt(until)]);
    }
}
const registry = [];
export function registerModule(m) {
    if (registry.some((x) => x.id === m.id))
        throw new Error(`duplicate module id: ${m.id}`);
    registry.push(m);
}
export function modules() {
    return registry;
}
// ── formatting ─────────────────────────────────────────────────────────────
export function formatUnits(value, decimals = 18, places = 6) {
    const scale = 10n ** BigInt(decimals);
    const whole = value / scale;
    const frac = (value % scale).toString().padStart(decimals, "0").slice(0, places);
    return `${whole.toLocaleString("en-US")}.${frac}`;
}
/** Maturity in words. A unix timestamp is not an answer to "when does this open?". */
export function untilWords(unlockAt, now = Math.floor(Date.now() / 1000)) {
    const secs = unlockAt - now;
    if (secs <= 0)
        return "matured";
    const days = Math.floor(secs / 86400);
    if (days >= 365) {
        const years = (days / 365.25).toFixed(days >= 3650 ? 0 : 1);
        return `${years} years`;
    }
    if (days >= 1)
        return `${days} days`;
    return `${Math.floor(secs / 3600)} hours`;
}
