// Cross-checks the local simulator against on-chain eval() on circuits that are already live.
import { ethers } from "ethers";
import { fromHex, decode, simulate, toHex } from "../lib/netlist.mjs";
import { provider, PROC_ABI, multiEval } from "../lib/chain.mjs";

const TARGETS = [
  ["0xDa659F36172E644424D4C009BdCEC23818F0a2F9", [1, 2, 3]], // RuleChip
  ["0xA196aB8ef5Ae052C13819E73f3Cc3f4263FAF744", [1]],       // LeoLabs ADD8
];
const SAMPLES = 48;

let failures = 0;
for (const [addr, ids] of TARGETS) {
  const proc = new ethers.Contract(addr, PROC_ABI, provider);
  for (const id of ids) {
    const [nIn, nOut, nState, gateCount] = (await proc.circuitInfo(id)).map(Number);
    if (nState) { console.log(`${addr}#${id}: sequential, skipped`); continue; }
    const els = decode(fromHex(await proc.netlist(id)), nIn);
    const nBytes = Math.ceil(nIn / 8);
    const inputs = Array.from({ length: SAMPLES }, () => Uint8Array.from(ethers.randomBytes(nBytes)).map((b, i) =>
      i === nBytes - 1 && nIn % 8 ? b & ((1 << (nIn % 8)) - 1) : b));
    const chain = await multiEval(addr, id, inputs);
    let bad = 0;
    inputs.forEach((inp, k) => {
      const local = toHex(simulate(els, nIn, nOut, inp));
      if (local !== chain[k]) { bad++; if (bad <= 3) console.log(`  mismatch in=${toHex(inp)} local=${local} chain=${chain[k]}`); }
    });
    failures += bad;
    console.log(`${addr.slice(0, 10)}#${id} nIn=${nIn} nOut=${nOut} gates=${gateCount} decoded=${els.length}: ${SAMPLES - bad}/${SAMPLES} match`);
  }
}
process.exit(failures ? 1 : 0);
