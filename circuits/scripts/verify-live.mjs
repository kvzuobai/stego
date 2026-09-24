// Checks a live circuit's on-chain eval() against its policy spec.
// Usage: node scripts/verify-live.mjs <processor> <circuitId> <POLICY_NAME> [samples]
import { POLICIES, verdictOf } from "../policies.mjs";
import { multiEval } from "../lib/chain.mjs";

const [proc, id, name, samplesArg] = process.argv.slice(2);
const pol = POLICIES[name];
if (!pol) throw new Error(`unknown policy ${name}`);
const samples = Number(samplesArg || 2048);
const inputs = [];
for (let a = 0; a < 256; a += 17) for (let b = 0; b < 256; b += 17) inputs.push(Uint8Array.of(a, b)); // grid
for (let s = 0; s < 64; s++) for (const d of [-1, 0, 1]) { // around the thresholds
  const a = Math.max(0, Math.min(255, s + d)), b = Math.max(0, Math.min(255, (pol.params.freeMax ?? 25) - s + d));
  inputs.push(Uint8Array.of(a, b));
}
while (inputs.length < samples) inputs.push(Uint8Array.of(Math.random() * 256 | 0, Math.random() * 256 | 0));
const out = await multiEval(proc, Number(id), inputs);
let bad = 0;
inputs.forEach((inp, i) => {
  const got = verdictOf(parseInt(out[i].slice(2, 4), 16));
  if (got !== pol.spec(inp[0], inp[1])) bad++;
});
console.log(`${name} #${id} on ${proc}: ${inputs.length - bad}/${inputs.length} on-chain evals match spec`);
process.exit(bad ? 1 : 0);
