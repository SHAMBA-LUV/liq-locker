// SPDX-License-Identifier: Apache-2.0
// (c) 2026 BANKON / cypherpunk2048
//
// dapp.tsx — the panel. Renders a lock and offers COLLECT.
//
// The collect button is the whole point of the interface, so it is the one thing on
// screen that states its own precondition: it shows what is collectable BEFORE it is
// pressed, and it disables itself with a reason rather than failing in a wallet popup.
// A button that can only be understood by clicking it is a trap with rounded corners.

import {
  ETHEREUM, Reader, Signer, formatUnits, untilWords, modules,
  type ChainConfig, type LockView, type ModuleOutput,
} from "./app.js";
import { VERBS } from "./abi.js";

type Status = { kind: "idle" | "busy" | "ok" | "err"; text?: string; hash?: string };

export interface PanelProps {
  cfg?: ChainConfig;
  lockId: bigint;
}

/**
 * Framework-free on purpose. A dapp that must be transpiled before it can be read is
 * one a user cannot audit at the moment they are deciding to trust it — and this ships
 * inside Tauri, where the whole bundle is the security boundary. `.tsx` for the
 * toolchain's benefit; the render is explicit DOM.
 */
export function mountPanel(root: HTMLElement, props: PanelProps): () => void {
  const cfg = props.cfg ?? ETHEREUM;
  const reader = new Reader(cfg);
  let signer: Signer | null = null;
  let view: LockView | null = null;
  let status: Status = { kind: "idle" };
  let timer: number | undefined;

  const el = (tag: string, cls?: string, text?: string) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined) n.textContent = text;
    return n;
  };

  let count: bigint | null = null;

  async function refresh() {
    try { count = (await reader.call("lock_count"))[0] as bigint; } catch { /* context only */ }
    try {
      view = await reader.lockView(props.lockId);
      if (status.kind === "err") status = { kind: "idle" };
    } catch (e) {
      status = { kind: "err", text: (e as Error).message };
    }
    render();
  }

  async function onCollect() {
    if (!signer || !view) return;
    status = { kind: "busy", text: "confirm in your wallet…" };
    render();
    try {
      const hash = await signer.collect(view.id);
      status = { kind: "ok", text: "collected", hash };
      await refresh();
    } catch (e) {
      status = { kind: "err", text: (e as Error).message };
      render();
    }
  }

  async function onConnect() {
    try {
      signer = await Signer.connect(cfg);
      status = { kind: "ok", text: `connected ${signer.account.slice(0, 6)}…${signer.account.slice(-4)}` };
    } catch (e) {
      status = { kind: "err", text: (e as Error).message };
    }
    render();
  }

  function render() {
    root.replaceChildren();
    const card = el("div", "lk-card");

    // ── header
    const head = el("div", "lk-head");
    head.append(el("span", "lk-dot"), el("span", "lk-title", "LIQUIDITY LOCKER"));
    head.append(el("span", "lk-net", `${cfg.name} · lock #${props.lockId}`));
    card.append(head);

    if (!view) {
      // A failed read must never hide behind the loading line: say what the chain said.
      if (status.kind === "err") {
        card.append(el("p", "lk-muted",
          count !== null && props.lockId >= count
            ? `lock #${props.lockId} does not exist yet — this locker holds ${count} lock${count === 1n ? "" : "s"}.`
            : `could not read lock #${props.lockId}: ${status.text}`));
        const a = el("a", "lk-link", "view the verified contract") as HTMLAnchorElement;
        a.href = `${cfg.explorer}/address/${cfg.locker}#code`;
        a.target = "_blank";
        a.rel = "noopener";
        card.append(a);
      } else {
        card.append(el("p", "lk-muted", "reading the chain…"));
      }
      root.append(card);
      return;
    }

    // ── the numbers. Read path: no wallet was required to see any of this.
    const grid = el("div", "lk-grid");
    const cell = (label: string, value: string, accent = false) => {
      const c = el("div", "lk-cell");
      c.append(el("span", "lk-label", label), el("b", accent ? "lk-value lk-accent" : "lk-value", value));
      return c;
    };
    grid.append(
      cell("principal", formatUnits(view.amount)),
      cell("collectable", formatUnits(view.collectable), view.collectable > 0n),
      cell("opens in", untilWords(view.unlockAt)),
      cell("state", view.withdrawn ? "withdrawn" : view.isLocked ? "locked" : "matured"),
    );
    card.append(grid);

    // ── COLLECT
    const why =
      view.withdrawn ? "this lock has been withdrawn"
      : view.collectable === 0n ? "nothing has accrued yet"
      : !signer ? "connect a wallet to sign"
      : signer.account.toLowerCase() !== view.beneficiary.toLowerCase() ? "only the beneficiary may collect"
      : null;

    const btn = el("button", "lk-collect") as HTMLButtonElement;
    btn.append(el("span", "lk-collect-main", VERBS.collect.label));
    btn.append(el("span", "lk-collect-sub",
      why ?? `${formatUnits(view.collectable)} — ${VERBS.collect.hint}`));
    btn.disabled = why !== null || status.kind === "busy";
    btn.onclick = onCollect;
    card.append(btn);

    // Principal is never the button. Stated, so nobody wonders where it went.
    card.append(el("p", "lk-fine",
      "Collect takes the reflection growth only. The principal stays locked until maturity."));

    // ── wallet, offered rather than demanded
    if (!signer) {
      const connect = el("button", "lk-connect", "Connect wallet to sign") as HTMLButtonElement;
      connect.onclick = onConnect;
      card.append(connect);
      card.append(el("p", "lk-fine", "Everything above is public and was read without one."));
    }

    if (status.text) {
      const s = el("p", `lk-status lk-${status.kind}`, status.text);
      if (status.hash) {
        const a = el("a", "lk-link", "view transaction") as HTMLAnchorElement;
        a.href = `${cfg.explorer}/tx/${status.hash}`;
        a.target = "_blank";
        a.rel = "noopener";
        s.append(" · ", a);
      }
      card.append(s);
    }

    // ── module layer. Core knows nothing about what these add.
    for (const m of modules()) {
      const slot = el("div", "lk-module");
      slot.append(el("span", "lk-label", m.title));
      card.append(slot);
      m.render({ reader, signer, lock: view, cfg })
        .then((out: ModuleOutput | null) => {
          if (!out) { slot.remove(); return; }
          for (const row of out.rows ?? []) {
            const r = el("div", "lk-row");
            r.append(el("span", "lk-label", row.label));
            if (row.href) {
              const a = el("a", "lk-link", row.value) as HTMLAnchorElement;
              a.href = row.href; a.target = "_blank"; a.rel = "noopener";
              r.append(a);
            } else r.append(el("b", "lk-value", row.value));
            slot.append(r);
          }
          if (out.note) slot.append(el("p", "lk-fine", out.note));
        })
        .catch(() => slot.remove()); // a module may never break the panel
    }

    root.append(card);
  }

  render();
  refresh();
  timer = setInterval(refresh, 30_000) as unknown as number;
  return () => clearInterval(timer);
}
