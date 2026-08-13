// SPDX-License-Identifier: Apache-2.0
// keccak.js — Keccak-256, in-house.
//
// Selectors must be computed somewhere, and pulling a hashing library from a registry
// to compute four bytes contradicts the contract's own stance: liquidity_locker imports
// nothing it cannot read. ~60 lines is cheaper than a supply chain.
const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];
const R = [
  [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56], [27, 20, 39, 8, 14],
];
const M = (1n << 64n) - 1n;
const rotl = (x, n) => n === 0n ? x : ((x << n) | (x >> (64n - n))) & M;

function keccakF(A) {
  for (let round = 0; round < 24; round++) {
    const C = [];
    for (let x = 0; x < 5; x++) C[x] = A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4];
    for (let x = 0; x < 5; x++) {
      const D = C[(x + 4) % 5] ^ rotl(C[(x + 1) % 5], 1n);
      for (let y = 0; y < 5; y++) A[x][y] ^= D;
    }
    const B = [[], [], [], [], []];
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) B[y][(2 * x + 3 * y) % 5] = rotl(A[x][y], BigInt(R[x][y]));
    }
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) A[x][y] = B[x][y] ^ (~B[(x + 1) % 5][y] & B[(x + 2) % 5][y]) & M;
    }
    A[0][0] ^= RC[round];
  }
  return A;
}

export function keccak256(bytes) {
  const rate = 136;
  const padded = new Uint8Array(Math.ceil((bytes.length + 1) / rate) * rate);
  padded.set(bytes);
  padded[bytes.length] = 0x01;
  padded[padded.length - 1] |= 0x80;

  const A = Array.from({ length: 5 }, () => new Array(5).fill(0n));
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; i++) {
      let lane = 0n;
      for (let b = 7; b >= 0; b--) lane = (lane << 8n) | BigInt(padded[off + i * 8 + b]);
      A[i % 5][(i / 5) | 0] ^= lane;
    }
    keccakF(A);
  }
  let out = "";
  for (let i = 0; i < 4; i++) {
    let lane = A[i % 5][(i / 5) | 0];
    for (let b = 0; b < 8; b++) {
      out += Number((lane >> BigInt(8 * b)) & 0xffn).toString(16).padStart(2, "0");
    }
  }
  return out;
}
