// TapeOut netlist format (mirrors tapeout.net's netlist module):
//   signal 0 = const0, 1 = const1, 2..2+nIn-1 = inputs, then one new signal per element in order.
//   NAND  = 0x00 a:u24 b:u24   (7 bytes)
//   LATCH = 0x01 d:u24         (4 bytes)
// The canvas compiler appends two inverting NANDs per output; outputs are the last nOut signals.
// Input/output bytes are packed little-endian: pin i = bit (i % 8) of byte (i / 8).

export const OP = { NAND: 0, LATCH: 1, REF: 2 };

export class Builder {
  constructor(nIn) {
    this.nIn = nIn;
    this.elements = [];
    this.next = 2 + nIn;
  }
  get ZERO() { return 0; }
  get ONE() { return 1; }
  input(i) {
    if (i < 0 || i >= this.nIn) throw new RangeError(`input ${i} out of range`);
    return 2 + i;
  }
  nand(a, b) {
    const out = this.next++;
    this.elements.push({ op: OP.NAND, a, b, out });
    return out;
  }
  // Seal outputs the same way the canvas compiler does, so on-chain gate counts match.
  finish(outputs) {
    const inv = outputs.map((s) => this.nand(s, s));
    const buf = inv.map((s) => this.nand(s, s));
    return { netlist: encode(this.elements), nIn: this.nIn, nOut: outputs.length, gateCount: this.elements.length, outSignals: buf };
  }
}

function u24(bytes, v) {
  if (!Number.isInteger(v) || v < 0 || v > 0xffffff) throw new RangeError(`bad signal ${v}`);
  bytes.push((v >>> 16) & 255, (v >>> 8) & 255, v & 255);
}

export function encode(elements) {
  const out = [];
  for (const e of elements) {
    if (e.op === OP.NAND) { out.push(OP.NAND); u24(out, e.a); u24(out, e.b); }
    else if (e.op === OP.LATCH) { out.push(OP.LATCH); u24(out, e.d); }
    else throw new Error(`unsupported op ${e.op}`);
  }
  return Uint8Array.from(out);
}

export function decode(bytes, nIn) {
  const els = [];
  let p = 0, next = 2 + nIn;
  const r24 = () => { const v = (bytes[p] << 16) | (bytes[p + 1] << 8) | bytes[p + 2]; p += 3; return v; };
  while (p < bytes.length) {
    const op = bytes[p++];
    if (op === OP.NAND) { const a = r24(), b = r24(); els.push({ op, a, b, out: next++ }); }
    else if (op === OP.LATCH) { const d = r24(); els.push({ op, d, out: next++ }); }
    else throw new Error(`unsupported opcode ${op} at ${p - 1} (REF not supported on X Layer)`);
  }
  return els;
}

// Combinational evaluation. Inputs/outputs as little-endian packed bytes.
export function simulate(elements, nIn, nOut, inputBytes) {
  const total = 2 + nIn + elements.length;
  const v = new Uint8Array(total);
  v[1] = 1;
  for (let i = 0; i < nIn; i++) v[2 + i] = (inputBytes[i >> 3] >> (i & 7)) & 1;
  for (const e of elements) {
    if (e.op === OP.NAND) v[e.out] = 1 - (v[e.a] & v[e.b]);
    else throw new Error("LATCH circuits need multi-cycle simulation");
  }
  const out = new Uint8Array(Math.ceil(nOut / 8));
  for (let i = 0; i < nOut; i++) if (v[total - nOut + i]) out[i >> 3] |= 1 << (i & 7);
  return out;
}

export const packBits = (bits) => {
  const out = new Uint8Array(Math.ceil(bits.length / 8));
  bits.forEach((b, i) => { if (b) out[i >> 3] |= 1 << (i & 7); });
  return out;
};
export const toHex = (u8) => "0x" + Buffer.from(u8).toString("hex");
export const fromHex = (h) => Uint8Array.from(Buffer.from(h.replace(/^0x/, ""), "hex"));
