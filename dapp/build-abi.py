#!/usr/bin/env python3
"""Regenerate dapp/abi.js from the compiled artifact. Run after every `forge build`."""
import json, subprocess, sys
from pathlib import Path
root = Path(__file__).resolve().parent.parent
art = json.load(open(root / "out/liquidity_locker.sol/liquidity_locker.json"))
abi = art["abi"]
rev = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
                     cwd=root).stdout.strip() or "uncommitted"
out = root / "dapp/abi.js"
src = out.read_text()
head, _, _ = src.partition("export const LIQUIDITY_LOCKER_ABI")
tail = src[src.index("/** Every mutating verb"):]
out.write_text(f"{head}export const LIQUIDITY_LOCKER_ABI = {json.dumps(abi, indent=2)};\n\n{tail}")
print(f"regenerated {out} ({len(abi)} entries, rev {rev})")
