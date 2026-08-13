#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# autotauribuild — dapp/ → a signed desktop binary, one command.
#
# The panel is plain ES modules with no bundler, which is deliberate: the thing a user
# is asked to trust should be the thing a user can read. Tauri suits that exactly — it
# ships the same files inside a Rust shell rather than transpiling them into something
# unreadable first.
#
# ORDER IS LOAD-BEARING. The ABI is regenerated from the compiled artifact BEFORE the
# bundle is assembled. Shipping a desktop binary carrying a stale ABI is the worst
# version of the drift problem: a web page can be corrected by a redeploy, an installed
# binary cannot be corrected at all.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

say() { printf '\033[1;35m▸\033[0m %s\n' "$*"; }

say "1/5  contracts — build and test (a dapp for a failing contract ships nothing)"
forge build
forge test

say "2/5  abi — regenerate from the artifact"
python3 dapp/build-abi.py

say "3/5  scaffold — src-tauri if absent"
if [ ! -d src-tauri ]; then
  command -v cargo >/dev/null || { echo "cargo not found — install Rust to build the desktop app"; exit 1; }
  cargo install tauri-cli --version '^2' --locked 2>/dev/null || true
  cargo tauri init --app-name "liquidity-locker" --window-title "Liquidity Locker" \
    --frontend-dist ../dapp --dev-url "" --before-dev-command "" --before-build-command ""
fi

say "4/5  typescript — emit dapp/*.js beside the sources"
if command -v npx >/dev/null; then
  npx --yes typescript@5 tsc dapp/app.ts dapp/dapp.tsx dapp/modules/augmented.ts \
    --target es2022 --module es2022 --moduleResolution bundler --jsx preserve \
    --allowJs --skipLibCheck --outDir dapp
else
  echo "  npx unavailable — emit dapp/*.js by hand before bundling"
fi

say "5/5  bundle"
cargo tauri build

say "done — installers under src-tauri/target/release/bundle/"
