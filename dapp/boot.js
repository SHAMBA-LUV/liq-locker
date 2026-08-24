// SPDX-License-Identifier: Apache-2.0
// boot.js — the page bootstrap, in a file rather than inline: the page's own CSP
// (default-src 'self') forbids inline script, and the CSP is not negotiable.
import { mountPanel } from "./dapp.js";
import "./modules/augmented.js"; // module layer: added by import, never by core edit

const params = new URLSearchParams(location.search);
mountPanel(document.getElementById("app"), {
  lockId: BigInt(params.get("id") ?? 0),
});
