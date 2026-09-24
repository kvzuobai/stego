// Stego policy circuits. Every policy uses the same pin interface so any compliant circuit can
// occupy any slot:
//   inputs  (16): A = byte 0 (pins 0-7), B = byte 1 (pins 8-15), unsigned 8-bit
//   outputs (2):  verdict = pin0 + 2*pin1  ->  0 ALLOW, 1 THROTTLE, 2 HALT (3 is treated as HALT)
//
// Two layers:
//   ENVELOPES[slot]   what ANY circuit in that slot must and must never do (mirrored in
//                     contracts/src/specs/PolicySpecs.sol, judged by PolicyRegistry). Authors are free
//                     to design anything inside the envelope, so circuits genuinely differ and compete.
//   POLICIES[name]    one concrete design. `spec` is that design's own intended function, used to prove
//                     the netlist bit-for-bit; the envelope is what it is held to on-chain.
import { Logic } from "./lib/logic.mjs";

export const ALLOW = 0, THROTTLE = 1, HALT = 2;

// `allowed(a, b, v)`: is verdict v acceptable at input (a, b)?
// `risk`: direction in which each input makes things riskier (+1 up, -1 down, 0 none). Moving toward
// more risk may never produce a softer verdict (checked exhaustively off-chain, challengeable on-chain).
export const ENVELOPES = {
  WITHDRAW: {
    // s = A + B = share of epoch-start TVL leaving this epoch, in /256 units
    allowed(a, b, v) {
      const s = a + b;
      if (s <= 12 && v !== ALLOW) return false; // small exits (<= ~4.7%) are never blocked or charged
      if (s <= 38 && v === HALT) return false; // exits up to ~15% are never refused
      if (s > 64 && v === ALLOW) return false; // above ~25% there must be a brake
      return true;
    },
    risk: { a: +1, b: +1 },
  },
  DRAWDOWN: {
    // A = price vs high-water mark, B = epoch-start price vs HWM (255 = at HWM)
    allowed(a, b, v) {
      const drop = b > a ? b - a : 0;
      if (a >= 250 && drop <= 2 && v !== ALLOW) return false; // no false alarms near the HWM
      if (a < 230 && v === ALLOW) return false; // > ~10% drawdown needs a brake
      if (a < 204 && v !== HALT) return false; // > ~20% drawdown must stop deposits
      return true;
    },
    risk: { a: -1, b: +1 },
  },
  ALLOCATION: {
    // A = deployed share after the move, B = before (255 = 100%)
    allowed(a, b, v) {
      const d = a > b ? a - b : b - a;
      if (a > 230 && v !== HALT) return false; // never deploy > ~90%
      if (d > 51 && v !== HALT) return false; // never move > ~20% of TVL at once
      if (a <= 128 && d <= 13 && v !== ALLOW) return false; // small moves under 50% are always allowed
      return true;
    },
    risk: { a: 0, b: 0 },
  },
};

function verdictBits(L, throttle, halt) {
  // halt dominates throttle: pin0 = throttle & !halt, pin1 = halt
  return [L.and(throttle, L.not(halt)), halt];
}

function withdrawGuard(freeMax, throttleMax) {
  return {
    slot: "WITHDRAW",
    params: { freeMax, throttleMax },
    spec(a, b) {
      const s = a + b;
      return s <= freeMax ? ALLOW : s <= throttleMax ? THROTTLE : HALT;
    },
    build() {
      const L = new Logic(16);
      const s = L.add(L.word(0, 8), L.word(8, 8)); // 9 bits
      // halt before throttle: gate order must stay byte-identical to the live circuit #1
      const halt = L.gtConst(s, throttleMax);
      const throttle = L.gtConst(s, freeMax);
      return L.compile(verdictBits(L, throttle, halt));
    },
  };
}

export const POLICIES = {
  // Up to ~10% of TVL per epoch exits freely, up to 25% pays a throttle fee, beyond that waits.
  // LIVE on mainnet as circuit #1.
  WITHDRAW_GUARD_V1: withdrawGuard(25, 64),

  // HALT when drawdown > ~10%; THROTTLE when drawdown > ~4% or price fell > ~3% within an epoch.
  DRAWDOWN_BREAKER_V1: {
    slot: "DRAWDOWN",
    params: { haltBelow: 230, throttleBelow: 245, maxDrop: 8 },
    spec(a, b, p = this.params) {
      const drop = b > a ? b - a : 0;
      if (a < p.haltBelow) return HALT;
      if (a < p.throttleBelow || drop > p.maxDrop) return THROTTLE;
      return ALLOW;
    },
    build(p = this.params) {
      const L = new Logic(16);
      const A = L.word(0, 8), B = L.word(8, 8);
      const halt = L.ltConst(A, p.haltBelow);
      const throttle = L.or(L.ltConst(A, p.throttleBelow), L.gtConst(L.subSat(B, A), p.maxDrop));
      return L.compile(verdictBits(L, throttle, halt));
    },
  },

  // Keep >= 20% idle and shift at most ~10% of TVL per rebalance.
  ALLOCATION_BAND_V1: {
    slot: "ALLOCATION",
    params: { maxDeployed: 204, maxStep: 26 },
    spec(a, b, p = this.params) {
      const d = a > b ? a - b : b - a;
      return a > p.maxDeployed || d > p.maxStep ? HALT : ALLOW;
    },
    build(p = this.params) {
      const L = new Logic(16);
      const A = L.word(0, 8), B = L.word(8, 8);
      const halt = L.or(L.gtConst(A, p.maxDeployed), L.gtConst(L.absDiff(A, B), p.maxStep));
      return L.compile([0, halt]);
    },
  },

  // A genuinely different, stricter design for the same slot: ~4.7% free, up to 15% throttled.
  // Shows that authors can compete inside the envelope.
  WITHDRAW_GUARD_STRICT: withdrawGuard(12, 38),
};

export const verdictOf = (outByte) => outByte & 3;

// Test fixtures only (never taped out).
export const FIXTURES = {
  // Pointwise envelope violation hidden at (200, 7): ALLOWs a ~81% exit. Boundary probes miss it.
  WITHDRAW_GUARD_BUGGY: {
    slot: "WITHDRAW",
    params: POLICIES.WITHDRAW_GUARD_V1.params,
    spec(a, b) {
      return a === 200 && b === 7 ? ALLOW : POLICIES.WITHDRAW_GUARD_V1.spec(a, b);
    },
    build(p = this.params) {
      const L = new Logic(16);
      const A = L.word(0, 8), B = L.word(8, 8);
      const s = L.add(A, B);
      const eqBits = (w, k) => w.map((bit, i) => ((k >> i) & 1 ? bit : L.not(bit))).reduce((x, y) => L.and(x, y));
      const bug = L.and(eqBits(A, 200), eqBits(B, 7));
      const halt = L.and(L.gtConst(s, p.throttleMax), L.not(bug));
      const throttle = L.and(L.gtConst(s, p.freeMax), L.not(bug));
      return L.compile(verdictBits(L, throttle, halt));
    },
  },
  // Every single point is inside the envelope, but a bigger exit can get a softer verdict:
  // HALT for 41..50, THROTTLE again for 51..64. Only a monotonicity challenge catches it.
  WITHDRAW_GUARD_NONMONO: {
    slot: "WITHDRAW",
    params: {},
    spec(a, b) {
      const s = a + b;
      if (s <= 25) return ALLOW;
      if (s > 40 && s <= 50) return HALT;
      return s <= 64 ? THROTTLE : HALT;
    },
    build() {
      const L = new Logic(16);
      const s = L.add(L.word(0, 8), L.word(8, 8));
      const halt = L.or(L.and(L.gtConst(s, 40), L.lteConst(s, 50)), L.gtConst(s, 64));
      return L.compile(verdictBits(L, L.gtConst(s, 25), halt));
    },
  },
};

// Exhaustive envelope check: returns { pointViolations, monotoneViolations, firstPoint, firstMono }.
export function checkEnvelope(slot, verdictAt) {
  const env = ENVELOPES[slot];
  let pointViolations = 0, monotoneViolations = 0, firstPoint = null, firstMono = null;
  for (let a = 0; a < 256; a++) {
    for (let b = 0; b < 256; b++) {
      const v = verdictAt(a, b);
      if (!env.allowed(a, b, v)) { pointViolations++; firstPoint ??= [a, b, v]; }
      // one step toward more risk on each axis must not soften the verdict
      for (const [axis, dir] of [["a", env.risk.a], ["b", env.risk.b]]) {
        if (!dir) continue;
        const a2 = axis === "a" ? a + dir : a, b2 = axis === "b" ? b + dir : b;
        if (a2 < 0 || a2 > 255 || b2 < 0 || b2 > 255) continue;
        if (verdictAt(a2, b2) < v) { monotoneViolations++; firstMono ??= [a, b, a2, b2]; }
      }
    }
  }
  return { pointViolations, monotoneViolations, firstPoint, firstMono };
}
