// Builds every policy circuit, proves it bit-for-bit against its own spec on all 65,536 inputs,
// checks it against its slot's safety envelope (every point + monotonicity), and writes
// out/<NAME>.json (netlist bytes + metadata) ready for tape-out.
import fs from "fs";
import { ethers } from "ethers";
import { POLICIES, FIXTURES, verdictOf, checkEnvelope } from "../policies.mjs";
import { decode, simulate, toHex } from "../lib/netlist.mjs";

fs.mkdirSync(new URL("../out/fixtures/", import.meta.url), { recursive: true });
let failed = false;

const entries = [
  ...Object.entries(POLICIES).map(([n, p]) => [n, p, ""]),
  ...Object.entries(FIXTURES).map(([n, p]) => [n, p, "fixtures/"]),
];
for (const [name, pol, dir] of entries) {
  const c = pol.build();
  const els = decode(c.netlist, c.nIn);
  const inp = new Uint8Array(2);
  let bad = 0;
  const hist = [0, 0, 0, 0];
  for (let a = 0; a < 256; a++) {
    for (let b = 0; b < 256; b++) {
      inp[0] = a; inp[1] = b;
      const got = verdictOf(simulate(els, c.nIn, c.nOut, inp)[0]);
      const want = pol.spec(a, b);
      hist[got]++;
      if (got !== want) { if (bad++ < 3) console.log(`  ${name} a=${a} b=${b} got=${got} want=${want}`); }
    }
  }
  const table = new Uint8Array(65536);
  for (let a = 0; a < 256; a++) for (let b = 0; b < 256; b++) { inp[0] = a; inp[1] = b; table[a * 256 + b] = Math.min(2, verdictOf(simulate(els, c.nIn, c.nOut, inp)[0])); }
  const env = checkEnvelope(pol.slot, (a, b) => table[a * 256 + b]);
  const envOk = env.pointViolations === 0 && env.monotoneViolations === 0;
  const netlistHex = toHex(c.netlist);
  const summary = {
    name, slot: pol.slot, params: pol.params, nIn: c.nIn, nOut: c.nOut,
    gateCount: c.gateCount, transistorsToBurn: c.gateCount, netlistBytes: c.netlist.length,
    netlistHash: ethers.keccak256(netlistHex), exhaustive: { cases: 65536, mismatches: bad, verdictHistogram: hist },
    envelope: env,
    netlist: netlistHex,
  };
  fs.writeFileSync(new URL(`../out/${dir}${name}.json`, import.meta.url), JSON.stringify(summary, null, 1));
  console.log(`${name.padEnd(22)} gates=${String(c.gateCount).padStart(4)} bytes=${String(c.netlist.length).padStart(5)} ` +
    `spec ${bad ? `FAIL (${bad})` : "PASS"}  envelope ${envOk ? "PASS" : `VIOLATES (points=${env.pointViolations} e.g. ${env.firstPoint}, monotone=${env.monotoneViolations} e.g. ${env.firstMono})`}`);
  if (bad || (!dir && !envOk)) failed = true;
}
process.exit(failed ? 1 : 0);
