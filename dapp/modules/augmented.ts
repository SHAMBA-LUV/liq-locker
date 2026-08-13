// SPDX-License-Identifier: Apache-2.0
//
// augmented.ts — the first module layer.
//
// The core panel shows only what the chain says. This layer adds what the chain does
// NOT carry: a maturity as a calendar date, a link to the record, and the century-scale
// framing the lock was actually built for. Every statement here is derived or fetched,
// which is exactly why it lives outside the core — the core must remain the part that
// cannot be wrong.

import { registerModule, untilWords, type ModuleContext, type ModuleOutput } from "../app.js";

registerModule({
  id: "augmented",
  title: "AUGMENTED",
  async render(ctx: ModuleContext): Promise<ModuleOutput | null> {
    const { lock, cfg } = ctx;
    if (lock.withdrawn) return null;

    const opens = new Date(lock.unlockAt * 1000);
    const years = (lock.unlockAt - Math.floor(Date.now() / 1000)) / (365.25 * 86400);

    const horizon =
      years >= 200 ? "beyond the Arweave 200-year storage standard"
      : years >= 140 ? "past the 140-year Uniswap horizon this design presumes"
      : years >= 100 ? "past the 100-year mandate"
      : years >= 1 ? "within a normal commitment window"
      : "closing soon";

    return {
      rows: [
        { label: "opens", value: opens.toISOString().slice(0, 10) },
        { label: "that is", value: untilWords(lock.unlockAt) },
        { label: "token", value: `${lock.token.slice(0, 10)}…${lock.token.slice(-6)}`,
          href: `${cfg.explorer}/token/${lock.token}` },
        { label: "beneficiary", value: `${lock.beneficiary.slice(0, 8)}…${lock.beneficiary.slice(-4)}`,
          href: `${cfg.explorer}/address/${lock.beneficiary}` },
      ],
      note: `Maturity is ${horizon}. Extending is possible at any time; shortening is not, on any path.`,
    };
  },
});
