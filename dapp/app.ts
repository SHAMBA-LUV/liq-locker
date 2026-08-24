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

export type Address = `0x${string}`;

export interface ChainConfig {
  chainId: number;
  name: string;
  rpc: string;
  explorer: string;
  locker: Address;
}

/** Mainnet by default; the panel works against anvil by swapping this object. */
export const ETHEREUM: ChainConfig = {
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

const selectorCache = new Map<string, string>();

async function keccakSelector(signature: string): Promise<string> {
  const cached = selectorCache.get(signature);
  if (cached) return cached;
  // Selectors are precomputed in abi.js at build time in production; this path exists
  // so the panel still works when opened straight from disk.
  const { keccak256 } = await import("./modules/keccak.js");
  const sel = "0x" + keccak256(new TextEncoder().encode(signature)).slice(0, 8);
  selectorCache.set(signature, sel);
  return sel;
}

const pad = (hex: string) => hex.replace(/^0x/, "").padStart(64, "0");
const encUint = (v: bigint | number) => pad(BigInt(v).toString(16));
const encAddr = (a: string) => pad(a.toLowerCase());

function abiFor(name: string) {
  const f = (LIQUIDITY_LOCKER_ABI as any[]).find((x) => x.type === "function" && x.name === name);
  if (!f) throw new Error(`no such function in ABI: ${name} — regenerate abi.js`);
  return f;
}

function signatureOf(name: string): string {
  const f = abiFor(name);
  return `${name}(${f.inputs.map((i: any) => i.type).join(",")})`;
}

export async function encodeCall(name: string, args: (string | bigint | number)[]): Promise<string> {
  const f = abiFor(name);
  if (args.length !== f.inputs.length) {
    throw new Error(`${name} expects ${f.inputs.length} args, got ${args.length}`);
  }
  const body = f.inputs
    .map((input: any, i: number) =>
      input.type === "address" ? encAddr(String(args[i])) : encUint(args[i] as bigint),
    )
    .join("");
  return (await keccakSelector(signatureOf(name))) + body;
}

/** Decode a return blob against the ABI's declared outputs. */
export function decodeReturn(name: string, data: string): any[] {
  const f = abiFor(name);
  const raw = data.replace(/^0x/, "");
  return f.outputs.map((out: any, i: number) => {
    const word = raw.slice(i * 64, (i + 1) * 64);
    if (out.type === "address") return ("0x" + word.slice(24)) as Address;
    if (out.type === "bool") return BigInt("0x" + word) !== 0n;
    return BigInt("0x" + (word || "0"));
  });
}

// ── read path: no wallet, ever ─────────────────────────────────────────────

export class Reader {
  constructor(private cfg: ChainConfig) {}

  private async rpc(method: string, params: unknown[]): Promise<any> {
    const res = await fetch(this.cfg.rpc, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
    const json = await res.json();
    if (json.error) throw new Error(json.error.message ?? "rpc error");
    return json.result;
  }

  async call(name: string, args: (string | bigint | number)[] = []): Promise<any[]> {
    if (this.cfg.locker === "0x0000000000000000000000000000000000000000") {
      throw new Error("locker address not configured — set ChainConfig.locker");
    }
    const data = await encodeCall(name, args);
    const out = await this.rpc("eth_call", [{ to: this.cfg.locker, data }, "latest"]);
    return decodeReturn(name, out);
  }

  /** Everything the panel shows for one lock, in a single shape. */
  async lockView(id: bigint): Promise<LockView> {
    const [token, beneficiary, amount, unlockAt, withdrawn] = await this.call("lock_at", [id]);
    const [collectable] = await this.call("collectable", [id]);
    const [isLocked] = await this.call("is_locked", [id]);
    return { id, token, beneficiary, amount, unlockAt: Number(unlockAt), withdrawn, collectable, isLocked };
  }

  async locksOf(owner: Address): Promise<bigint[]> {
    const data = await encodeCall("locks_of", [owner]);
    const raw: string = await this.rpc("eth_call", [{ to: this.cfg.locker, data }, "latest"]);
    const body = raw.replace(/^0x/, "");
    const len = Number(BigInt("0x" + body.slice(64, 128)));
    return Array.from({ length: len }, (_, i) => BigInt("0x" + body.slice(128 + i * 64, 192 + i * 64)));
  }
}

export interface LockView {
  id: bigint;
  token: Address;
  beneficiary: Address;
  amount: bigint;
  unlockAt: number;
  withdrawn: boolean;
  collectable: bigint;
  isLocked: boolean;
}

// ── write path: only after an explicit connect ─────────────────────────────

export class Signer {
  private constructor(
    private provider: any,
    private cfg: ChainConfig,
    readonly account: Address,
  ) {}

  /** Never called on load. Only from a click — see dapp.tsx. */
  static async connect(cfg: ChainConfig): Promise<Signer> {
    const injected = (globalThis as any).ethereum;
    if (!injected) throw new Error("no wallet found — the panel still reads without one");
    const accounts: Address[] = await injected.request({ method: "eth_requestAccounts" });
    const chainId = Number(await injected.request({ method: "eth_chainId" }));
    if (chainId !== cfg.chainId) {
      throw new Error(`wrong network: connected to ${chainId}, expected ${cfg.chainId} (${cfg.name})`);
    }
    return new Signer(injected, cfg, accounts[0]);
  }

  async send(name: string, args: (string | bigint | number)[] = []): Promise<string> {
    const data = await encodeCall(name, args);
    return this.provider.request({
      method: "eth_sendTransaction",
      params: [{ from: this.account, to: this.cfg.locker, data }],
    });
  }

  /** COLLECT. The growth, without the principal. */
  collect(id: bigint) {
    return this.send("collect", [id]);
  }
  collectTo(id: bigint, to: Address) {
    return this.send("collect_to", [id, to]);
  }
  withdraw(id: bigint) {
    return this.send("withdraw", [id]);
  }
  extend(id: bigint, until: number) {
    return this.send("extend", [id, BigInt(until)]);
  }
}

// ── module layer ───────────────────────────────────────────────────────────
/**
 * The panel is a host, not a monolith. A module receives the reader, the signer (or
 * null, because a visitor may have neither), and the lock in view, and returns
 * something to render. Nothing in the core imports a module, so a module can be added
 * or removed without touching the files above.
 *
 * `augmented` is the intended first tenant: a layer that annotates a raw lock with
 * meaning the chain does not carry — what the maturity is in calendar terms, what the
 * collectable growth is worth in dollars, whether the pair behind an LP token is the
 * one it claims to be. The core deliberately knows none of that, because every one of
 * those answers comes from somewhere that can be wrong, and the core must stay the part
 * that cannot.
 */
export interface PanelModule {
  id: string;
  title: string;
  /** Return null to render nothing for this lock. */
  render(ctx: ModuleContext): Promise<ModuleOutput | null>;
}

export interface ModuleContext {
  reader: Reader;
  signer: Signer | null;
  lock: LockView;
  cfg: ChainConfig;
}

export interface ModuleOutput {
  rows?: { label: string; value: string; href?: string }[];
  note?: string;
}

const registry: PanelModule[] = [];

export function registerModule(m: PanelModule): void {
  if (registry.some((x) => x.id === m.id)) throw new Error(`duplicate module id: ${m.id}`);
  registry.push(m);
}

export function modules(): readonly PanelModule[] {
  return registry;
}

// ── formatting ─────────────────────────────────────────────────────────────

export function formatUnits(value: bigint, decimals = 18, places = 6): string {
  const scale = 10n ** BigInt(decimals);
  const whole = value / scale;
  const frac = (value % scale).toString().padStart(decimals, "0").slice(0, places);
  return `${whole.toLocaleString("en-US")}.${frac}`;
}

/** Maturity in words. A unix timestamp is not an answer to "when does this open?". */
export function untilWords(unlockAt: number, now = Math.floor(Date.now() / 1000)): string {
  const secs = unlockAt - now;
  if (secs <= 0) return "matured";
  const days = Math.floor(secs / 86400);
  if (days >= 365) {
    const years = (days / 365.25).toFixed(days >= 3650 ? 0 : 1);
    return `${years} years`;
  }
  if (days >= 1) return `${days} days`;
  return `${Math.floor(secs / 3600)} hours`;
}
