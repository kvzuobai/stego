// Designer seasons: checks whether a live circuit can be a Nerve exit rule.
//   node scripts/check-candidate.mjs <circuitId> [processor]
// 1. pinout must be 16 inputs / 2 outputs / no state
// 2. every one of the 65,536 inputs stays inside the WITHDRAW safety envelope, and a riskier input never
//    gets a softer verdict (exhaustive, using the netlist downloaded from the chain)
// 3. the local simulation matches on-chain eval() on 256 random inputs
import { ethers } from "ethers";
import { provider, PROC_ABI, multiEval } from "../lib/chain.mjs";
import { decode, simulate, fromHex, toHex } from "../lib/netlist.mjs";
import { checkEnvelope, verdictOf } from "../policies.mjs";

const id = Number(process.argv[2]);
const procAddr = process.argv[3] || "0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C";
if (!Number.isInteger(id) || id <= 0) { console.log("usage: node scripts/check-candidate.mjs <circuitId> [processor]"); process.exit(2); }

const proc = new ethers.Contract(procAddr, [...PROC_ABI, "function ownerOf(uint256) view returns (address)"], provider);
const fail = (msg) => { console.log(`FAIL: ${msg}`); process.exit(1); };

let info;
try { info = (await proc.circuitInfo(id)).map(Number); } catch { fail(`circuit #${id} does not exist on ${procAddr}`); }
const [nIn, nOut, nState, gates] = info;
const designer = await proc.ownerOf(id);
console.log(`circuit #${id} on ${procAddr}: ${gates} gates, ${nIn} in / ${nOut} out / ${nState} state, designer ${designer}`);
if (nIn !== 16 || nOut !== 2 || nState !== 0) fail("pinout must be 16 inputs, 2 outputs, no LATCH state");

const els = decode(fromHex(await proc.netlist(id)), nIn);
const table = new Uint8Array(65536);
const inp = new Uint8Array(2);
for (let a = 0; a < 256; a++) for (let b = 0; b < 256; b++) {
  inp[0] = a; inp[1] = b;
  table[a * 256 + b] = Math.min(2, verdictOf(simulate(els, nIn, nOut, inp)[0]));
}
const env = checkEnvelope("WITHDRAW", (a, b) => table[a * 256 + b]);
if (env.pointViolations) fail(`${env.pointViolations} inputs break the envelope, e.g. A=${env.firstPoint[0]} B=${env.firstPoint[1]} verdict=${env.firstPoint[2]}`);
if (env.monotoneViolations) fail(`${env.monotoneViolations} places where a bigger exit gets a softer verdict, e.g. (${env.firstMono.slice(0, 2)}) vs (${env.firstMono.slice(2)})`);

const samples = Array.from({ length: 256 }, () => Uint8Array.of(Math.random() * 256 | 0, Math.random() * 256 | 0));
const chain = await multiEval(procAddr, id, samples);
const mism = samples.filter((s, k) => toHex(simulate(els, nIn, nOut, s)) !== chain[k]).length;
if (mism) fail(`${mism}/256 on-chain evals differ from the downloaded netlist`);

const hist = [0, 0, 0];
table.forEach((v) => hist[v]++);
console.log(`PASS: inside the WITHDRAW envelope on all 65,536 inputs, monotone, on-chain eval matches (256/256).`);
console.log(`verdict mix: ALLOW ${hist[0]}, THROTTLE ${hist[1]}, HALT ${hist[2]}. Eligible as a Nerve exit rule (CIRCUIT_ID=${id}).`);
