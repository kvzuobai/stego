# Stego: live deployments (X Layer mainnet, chain 196)

| Item | Value |
|---|---|
| Processor (circuits, ERC-721) | [`0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C`](https://www.oklink.com/xlayer/address/0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C) |
| Transistors (ERC-1155) | [`0x3775Ada4083fDbCc4A3CA0e3d38f15d17C187225`](https://www.oklink.com/xlayer/address/0x3775Ada4083fDbCc4A3CA0e3d38f15d17C187225) |
| Deployment wallet (creator) | [`0xC4AAaf5BD7e688F19F70E1e5067aF4c2d1307A74`](https://www.oklink.com/xlayer/address/0xC4AAaf5BD7e688F19F70E1e5067aF4c2d1307A74) |
| TapeOut factory | `0x1f09DAeFA827f02CBb40967cc91b259763760761`; `isCPU(processor) == true`, factory index 232 |
| Supply cap / price | 2,300,000 / 0.000066 OKB (immutable) |
| Website | https://stego-jade.vercel.app/ |
| Story | Stored on-chain, readable via `transistors.story()` |

## Transaction evidence
| Event | Tx | Block | Detail |
|---|---|---|---|
| Processor created via factory `createCPU` | `0x20c6d48a6e2eb3e06e0b6fda85dc2986d9bc7fc320b486f135636fb63e70787b` | 71,462,513 | 2026-09-24 06:32 UTC (13:32 UTC+7), inside the hackathon window. From the deployment wallet to the factory. |
| Circuit #1 tape-out | `0x220b3005f4b27c66ced257afd234fcddbbec85a718ec034c8ecadb4a67e5af0d` | 71,462,627 | `TransferSingle(creator → 0x0, id 0 NAND, 112)` = 112 transistors burned; circuit NFT #1 minted to the creator; 553,150 gas |

## Nerve Season 1 (official, launch step 3, 2026-09-24)
| Item | Value |
|---|---|
| Contract | [`0x23AE0d6b490407c378a1496C6B834238Cc2D78Bd`](https://www.oklink.com/xlayer/address/0x23AE0d6b490407c378a1496C6B834238Cc2D78Bd) · on-chain name "Stego Nerve - Season 1" |
| Deploy tx | `0xc25ef4148e5ac84ce374bd32cb4272a9c2a4fdc28de29c285b017338b0380c0f` (block 71,480,055) |
| Envelope check | WithdrawEnvelopeV1 `0x190D6cFe2C334420B29f4b7B50f908Ec5485661E` (tx `0x8ab178ac…ced7`); exit rule = circuit #1 |
| Joins close / season ends | 2026-09-28 18:24 / 2026-10-01 18:24 (UTC+7) |
| Rules | 0.01–0.05 OKB per wallet, 2 OKB cap, 10-STEGO ticket (0.00132 OKB), fees 2% / 10% / HALT, time-weighted pot shares, STEGO Boost up to +50%, 10% designer cut, no admin |

## Nerve rehearsal contract (NOT the official season)
Deployed early as a rehearsal and never promoted: 0 players, 0 OKB, and it has no name field. Its joins close 2026-09-28. The official Season 1 is a fresh deployment named "Stego Nerve - Season 1" on-chain.

### Rehearsal details
| Item | Value |
|---|---|
| Contract | [`0xA5D33488b139B1e0ABcF7b60e3fB4f26F020F098`](https://www.oklink.com/xlayer/address/0xA5D33488b139B1e0ABcF7b60e3fB4f26F020F098) |
| Deploy tx | `0xd6c4d0f0b14522af681e8c7bd74756460dadd9e966f32fcf8a2ae0f6a15c8d82` (block 71,465,826, from the deployment wallet) |
| Exit rule | Stego circuit #1 (WITHDRAW_GUARD_V1), TapeOut beacon implementation pinned `0x977f…29B2` |
| Joins close / season ends | 2026-09-28 14:27 / 2026-09-30 14:27 (UTC+7) |
| Rules | Deposit 0.001–0.05 OKB per wallet, 2 OKB cap; 10-STEGO ticket minted and burned on first join (0.00132 OKB); exit fee 2% ALLOW / 10% THROTTLE / HALT waits a day; stayers split the pot; 10% designer cut to the circuit #1 owner; no admin |

## Outside usage (organic, not the deployment wallet)
| When | Who | What | Tx |
|---|---|---|---|
| 2026-09-25 03:10 UTC | `0x03aEbF90342f923C9438f9Cb55ECF8A4dd8719b5` | Minted 1,000 STEGO directly (paid 0.06666 OKB) | `0x5f50c9ef997b360f0df732717623e53ac7e50a7382772c776c18105e201faddb` |

## Circuits
| Id | Policy | Gates | Netlist hash | On-chain check |
|---|---|---|---|---|
| 1 | WITHDRAW_GUARD_V1 | 112 (112 transistors burned) | `0x725616861c4d4e6a26de049aaf1cf48fd33e087c69e7082d080fc0bb31fcecf8` (identical to `circuits/out`) | 2,048/2,048 live `eval()` calls match spec; exhaustive 65,536/65,536 via the identical netlist |

| 2 | DRAWDOWN_BREAKER_V1 | 161 | identical to `circuits/out` | 1,024/1,024 live evals match; exhaustive via the identical netlist |
| 3 | ALLOCATION_BAND_V1 | 246 | identical to `circuits/out` | 1,024/1,024 live evals match; exhaustive via the identical netlist |

Launch step 1 (Phase2Safe) done 2026-09-24: 8 transactions (3 mint, 3 withdraw, 2 tape-out). The wallet holds 6,000 STEGO for bonds, owed 0, 0.1511 OKB left. STEGO minted in total: 6,519.

## Rule registry + vault (launch step 2, 2026-09-24)
| Item | Address |
|---|---|
| PolicyRegistry | [`0x0A184781674dc6dC6C689f72235a10A2d7D5B37d`](https://www.oklink.com/xlayer/address/0x0A184781674dc6dC6C689f72235a10A2d7D5B37d) |
| StegoVault (sgWOKB) | [`0x784Ba316b123b7099631FB834D9aC2D6B31e8b75`](https://www.oklink.com/xlayer/address/0x784Ba316b123b7099631FB834D9aC2D6B31e8b75) |
| WITHDRAW envelope spec | `0x36ce46FEC43902026Edd46038bDEDa057c2696Cd` |
| DRAWDOWN envelope spec | `0xaD40c6AFC3eF0628C1bC18404EAa6926B6C2aA16` |
| ALLOCATION envelope spec | `0xCA2640FD7A1a45f58078ad4D608fC34542b42633` |

Circuits #1–#3 were proposed with 2,000 STEGO bonds each (6,000 locked) and approved by the curator. They can be activated after 2026-09-25 11:16 UTC (18:16 UTC+7).

## Rules activated (launch step 4, 2026-09-25)
All three slots are active: WITHDRAW = circuit #1, DRAWDOWN = #2, ALLOCATION = #3. The vault accepts deposits (cap 5 OKB).
Transactions (blocks 71,570,582–71,570,586): `0x6973079801ee471d8f14b7303d4c970b16e9ea0a2623e2faba64e58b11d436a5`, `0x99f8771a8da8ebe8f8bea1048cee2f4953cc5060e4b843ce0665df2601a630b9`, `0x7488f68f3fa20a76055d442c695ab988d1ea1e208f68cab83b4d03e806375a55`

Re-check at any time:
```bash
node scripts/verify-live.mjs 0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C 1 WITHDRAW_GUARD_V1
```

## Not deployed yet (phase 2, ~0.1–0.43 OKB working capital, mostly returned as creator proceeds)
- Circuits DRAWDOWN_BREAKER_V1 (161) and ALLOCATION_BAND_V1 (246)
- Specs, PolicyRegistry, StegoVault; then activate after the timelock
- 25% commitment: stream 25% of the bootstrap proceeds (112 × 0.000066 = 0.007392 OKB → 0.001848 OKB) once the registry exists
