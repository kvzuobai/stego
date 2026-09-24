import { ethers } from "ethers";
import { toHex } from "./netlist.mjs";

export const RPC = process.env.XLAYER_RPC || "https://xlayerrpc.okx.com";
export const provider = new ethers.JsonRpcProvider(RPC, 196, { staticNetwork: true, batchMaxCount: 1 });

export const FACTORY = "0x1f09daefa827f02cbb40967cc91b259763760761";
export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";

export const PROC_ABI = [
  "function eval(uint256,bytes) view returns (bytes)",
  "function circuitInfo(uint256) view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount)",
  "function netlist(uint256) view returns (bytes)",
  "function nextId() view returns (uint256)",
  "function transistors() view returns (address)",
  "function tapeout(bytes nl, uint32 nIn, uint32 nOut) payable returns (uint256)",
  "function TAPEOUT_FEE() view returns (uint256)",
  "event TapedOut(uint256 indexed circuitId, address indexed author, uint32 gateCount, uint32 nState)",
];
const MC_ABI = ["function aggregate3((address target,bool allowFailure,bytes callData)[] calls) view returns ((bool success,bytes returnData)[])"];

// Evaluates many inputs through Multicall3, chunked to stay under the RPC's per-call gas cap.
export async function multiEval(proc, id, inputs, { chunk = 40 } = {}) {
  const pi = new ethers.Interface(PROC_ABI);
  const mc = new ethers.Contract(MULTICALL3, MC_ABI, provider);
  const out = [];
  for (let i = 0; i < inputs.length; i += chunk) {
    const calls = inputs.slice(i, i + chunk).map((inp) => ({
      target: proc, allowFailure: false, callData: pi.encodeFunctionData("eval", [id, toHex(inp)]),
    }));
    for (let attempt = 0; ; attempt++) {
      try {
        const res = await mc.aggregate3(calls);
        for (const r of res) out.push(pi.decodeFunctionResult("eval", r.returnData)[0]);
        break;
      } catch (e) {
        if (attempt >= 4) throw e;
        await new Promise((r) => setTimeout(r, 1000 * (attempt + 1)));
      }
    }
  }
  return out;
}
