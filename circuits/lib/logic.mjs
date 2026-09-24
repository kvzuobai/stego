// Optimising NAND builder: constant folding, double-negation folding, structural hashing
// and dead-gate elimination. Every gate we save is one transistor less to burn and ~2.4k gas
// less per eval.
import { Builder } from "./netlist.mjs";

export class Logic {
  constructor(nIn) {
    this.nIn = nIn;
    this.gates = []; // {a, b} with ids >= 2 + nIn
    this.hash = new Map();
    this.invOf = new Map(); // id -> x when id == NOT x
  }
  get ZERO() { return 0; }
  get ONE() { return 1; }
  input(i) { return 2 + i; }

  nand(a, b) {
    if (a > b) [a, b] = [b, a];
    if (a === 0) return 1;                        // nand(0, x) = 1
    if (a === 1 && b === 1) return 0;             // nand(1, 1) = 0
    if (a === 1) return this.not(b);              // nand(1, x) = !x
    if (a === b) return this.not(a);
    if (this.invOf.get(a) === b || this.invOf.get(b) === a) return 1; // nand(x, !x) = 1
    return this.#raw(a, b);
  }
  not(x) {
    if (x === 0) return 1;
    if (x === 1) return 0;
    if (this.invOf.has(x)) return this.invOf.get(x); // !!x = x
    const y = this.#raw(x, x);
    this.invOf.set(y, x);
    return y;
  }
  #raw(a, b) {
    const key = `${a},${b}`;
    if (this.hash.has(key)) return this.hash.get(key);
    const id = 2 + this.nIn + this.gates.length;
    this.gates.push({ a, b });
    this.hash.set(key, id);
    return id;
  }

  and(a, b) { return this.not(this.nand(a, b)); }
  or(a, b) { return this.nand(this.not(a), this.not(b)); }
  xor(a, b) { const n = this.nand(a, b); return this.nand(this.nand(a, n), this.nand(b, n)); }
  mux(sel, whenTrue, whenFalse) { return this.nand(this.nand(sel, whenTrue), this.nand(this.not(sel), whenFalse)); }

  // Unsigned n-bit words, LSB first.
  word(offset, n) { return Array.from({ length: n }, (_, i) => this.input(offset + i)); }
  constWord(v, n) { return Array.from({ length: n }, (_, i) => ((v >> i) & 1 ? 1 : 0)); }

  add(x, y) {
    const n = Math.max(x.length, y.length);
    const sum = [];
    let c = 0;
    for (let i = 0; i < n; i++) {
      const a = x[i] ?? 0, b = y[i] ?? 0;
      const axb = this.xor(a, b);
      sum.push(this.xor(axb, c));
      c = this.or(this.and(a, b), this.and(axb, c));
    }
    sum.push(c);
    return sum;
  }
  // x >= y for equal-width unsigned words (borrow chain of x - y).
  gte(x, y) {
    let borrow = 0;
    for (let i = 0; i < x.length; i++) {
      const a = x[i], b = y[i] ?? 0;
      const axb = this.xor(a, b);
      borrow = this.or(this.and(this.not(a), b), this.and(this.not(axb), borrow));
    }
    return this.not(borrow);
  }
  // x <= K (constant), via !(x >= K + 1).
  lteConst(x, k) {
    if (k >= 2 ** x.length - 1) return 1;
    return this.not(this.gte(x, this.constWord(k + 1, x.length)));
  }
  gtConst(x, k) { return this.not(this.lteConst(x, k)); }
  ltConst(x, k) { return k <= 0 ? 0 : this.not(this.gte(x, this.constWord(k, x.length))); }
  // |x - y| for equal-width words.
  absDiff(x, y) {
    const xGeY = this.gte(x, y);
    const hi = x.map((_, i) => this.mux(xGeY, x[i], y[i]));
    const lo = x.map((_, i) => this.mux(xGeY, y[i], x[i]));
    return this.sub(hi, lo);
  }
  // x - y assuming x >= y.
  sub(x, y) {
    const out = [];
    let borrow = 0;
    for (let i = 0; i < x.length; i++) {
      const a = x[i], b = y[i] ?? 0;
      const axb = this.xor(a, b);
      out.push(this.xor(axb, borrow));
      borrow = this.or(this.and(this.not(a), b), this.and(this.not(axb), borrow));
    }
    return out;
  }
  // max(x - y, 0)
  subSat(x, y) {
    const d = this.sub(x, y);
    const ok = this.gte(x, y);
    return d.map((bit) => this.and(ok, bit));
  }

  // Drops unreachable gates, renumbers, and emits a TapeOut netlist with canvas-style output buffers.
  compile(outputs) {
    const base = 2 + this.nIn;
    const live = new Uint8Array(this.gates.length);
    const stack = outputs.filter((s) => s >= base);
    while (stack.length) {
      const s = stack.pop();
      const g = s - base;
      if (live[g]) continue;
      live[g] = 1;
      for (const x of [this.gates[g].a, this.gates[g].b]) if (x >= base) stack.push(x);
    }
    const b = new Builder(this.nIn);
    const remap = new Map();
    const sig = (s) => (s < base ? s : remap.get(s));
    this.gates.forEach((g, i) => {
      if (live[i]) remap.set(base + i, b.nand(sig(g.a), sig(g.b)));
    });
    return b.finish(outputs.map(sig));
  }
}
