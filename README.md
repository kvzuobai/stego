# Stego: circuit-governed vaults on TapeOut × X Layer

A vault whose risk rules are **TapeOut circuits**. Before every deposit, withdrawal and rebalance, `StegoVault` calls `processor.eval()` on the policy circuit of the matching slot and obeys the verdict. Each slot has a **safety envelope**: what any design must and must never do, plus "a riskier input never gets a softer verdict". Authors design competing circuits inside it. Every shipped circuit is proven against its envelope over all 65,536 inputs, and anyone who finds one violation (a single bad answer or a monotonicity break) takes the author's transistor bond.

| Folder | What |
|---|---|
| `circuits/` | NAND netlist generator, simulator (bit-exact with on-chain `eval`), policy definitions, exhaustive proofs |
| `contracts/` | `PolicyRegistry`, `StegoVault`, spec contracts, Foundry tests + X Layer fork test, deploy scripts |
| `contracts/src/NerveSeason.sol` | Nerve: a bank-run game whose exit price is set by live circuit #1. Stayers split the fees; tickets burn STEGO. |
| `circuits/scripts/check-candidate.mjs` | Designer seasons: proves a community circuit safe as a Nerve exit rule (all 65,536 inputs + on-chain cross-check) |
| `web/index.html` | Demo dashboard: one static file, live X Layer data, no backend. Open it directly or host it anywhere. |
| `LAUNCH_CHECKLIST.md` | Exact launch commands in order for the current wallet budget, all rehearsed |

**Live site:** https://stego-jade.vercel.app/ · **Deployed contracts and transaction evidence:** [DEPLOYMENTS.md](DEPLOYMENTS.md)

## Build and test
```bash
# circuits (Node 18+)
cd circuits && npm install && node scripts/build.mjs && node scripts/check-simulator.mjs
# contracts (Foundry)
cd contracts
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 foundry-rs/forge-std --no-git
forge test
forge test --match-path "test/fork/*" --fork-url https://xlayerrpc.okx.com
```

## Verification status
- `circuits`: `node scripts/check-simulator.mjs` → the simulator matches on-chain `eval()` 192/192 on 4 live circuits.
- `circuits`: `node scripts/build.mjs` → every policy PASSes its own design spec and its slot envelope (all 65,536 points + monotonicity). The test fixtures are correctly flagged: BUGGY (point violation) and NONMONO (monotonicity only).
- `contracts`: `forge test` → all pass (63 incl. inherited suites) at 3,000–5,000 fuzz runs (envelope + monotonicity, curator approval, timelock, point and monotone slashing, TapeOut-upgrade freeze, tamper, rewards and on-chain commitment tracking, competing designs, vault policies, two maxWithdraw regressions found by fuzzing, a first-day exit-limit regression found by UI testing, Nerve game rules, time-weighted pot shares, join quotes, STEGO Boost, envelope-checked designer seasons and solvency).
- `contracts`: `forge test --match-path "test/fork/*" --fork-url https://xlayerrpc.okx.com` → full flow on the **real** TapeOut factory: create → mint → tape out (1 transistor burned per gate) → real `eval` == spec → bond → activate → vault deposit/withdraw/HALT → outside mint → creator withdraw → 25% streamed to authors.
- Full phase 2–6 rehearsal on an anvil fork **from the real deployment wallet** with +0.5 OKB: Phase2Safe (9 rounds, 0 left unclaimed, resumable), DeployStego, 24 h activation, HonourCommitment (0.1077 OKB streamed, recorded in `notifiedBy`, no double-pay), ClaimAuthorRewards, vault deposit/withdraw, official Nerve Season 1 (pot seed, seat, claims). Net cost 0.024 OKB, of which 0.015 was still sitting in the vault under the daily exit limit. Repeated with only **+0.1 OKB**: 5 mint rounds, the 25% commitment streamed in 2 chunks (claimed back in between), everything completed; net cost 0.014 OKB, of which 0.0075 was still in the vault.

## Policies (pin interface: in = A byte, B byte; out = verdict 0 ALLOW / 1 THROTTLE / 2 HALT)
| Circuit | Gates | Inputs | Rule |
|---|---|---|---|
| WITHDRAW_GUARD_V1 | 112 | A = outflow this epoch, B = request (TVL/256 units) | ≤~10%/day free, ≤25% pays 1% fee to LPs, more waits a day |
| DRAWDOWN_BREAKER_V1 | 161 | A = price vs HWM, B = epoch-start price vs HWM (255 = HWM) | >4% drawdown or >3% daily drop → de-risk only; >10% → deposits closed |
| ALLOCATION_BAND_V1 | 246 | A = deployed after, B = before (255 = 100%) | ≥20% stays idle, ≤~10% moved per rebalance |

Safety defaults: exits **fail open** (a missing or broken WITHDRAW policy never traps funds). Deposits and strategy moves **fail closed**.

## Mainnet runbook (X Layer, chain 196)
Use one dedicated wallet for everything. It becomes the "deployment wallet" in the submission. Never paste a private key anywhere; import it once into Foundry's encrypted keystore:

```bash
cast wallet import stego-deployer --interactive
```

All commands run from `contracts/`. `--account 0xstego-deployer` prompts for the keystore password.

**Step 1: create the processor through the TapeOut factory** (0.0066 OKB fee; supply and price are immutable). The `STORY` is the on-chain public disclosure required by Rule 2:

> STEGO: transistors for circuit-governed vaults on X Layer. Fixed supply cap: 2,300,000 (a thousand Intel 4004s). Price: 0.000066 OKB per transistor, immutable. Use: tape out risk-policy circuits (withdraw guard, drawdown breaker, allocation band) that StegoVault enforces on-chain through eval(); policy authors bond STEGO transistors, slashable by any counterexample. Commitment: 25% of creator mint proceeds are streamed to active policy authors via PolicyRegistry.notifyReward.

```bash
NAME="Stego" SYMBOL="STEGO" SUPPLY=2300000 PRICE_WEI=66000000000000 STORY="STEGO: transistors for circuit-governed vaults on X Layer. Fixed supply cap: 2,300,000 (a thousand Intel 4004s). Price: 0.000066 OKB per transistor, immutable. Use: tape out risk-policy circuits (withdraw guard, drawdown breaker, allocation band) that StegoVault enforces on-chain through eval(); policy authors bond STEGO transistors, slashable by any counterexample. Commitment: 25% of creator mint proceeds are streamed to active policy authors via PolicyRegistry.notifyReward." forge script script/Stego.s.sol:CreateProcessor --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```

**Step 2a (low budget, ~0.004 OKB after step 1): tape out one circuit.** This meets Rule 3. The script mints your own transistors in small batches and withdraws the creator proceeds after each one, so only fees are spent. Dry-run from 0.0127 OKB: create + bootstrap left 0.0028 OKB.
```bash
PROCESSOR=0x... forge script script/Stego.s.sol:BootstrapCircuit --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```
Bootstrap proceeds are your own money cycling back. When the registry launches, stream 25% of them too so the commitment is honoured from day one.

**Nerve Season (the bank-run game, gas only, ~0.00004 OKB).** It uses live circuit #1 as the exit rule, so no tape-out is needed. The defaults are joins open for 96 h, the season ends at 144 h, deposits of 0.001–0.05 OKB per wallet, a 2 OKB cap, a 10-STEGO ticket, fees of 2% (ALLOW) and 10% (THROTTLE), and a 10% designer cut. It has no admin.
```bash
PROCESSOR=0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C forge script script/Stego.s.sol:DeployNerve --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```
Then set `nerve: "0x…"` in `web/index.html` (the `CFG` block). Only play from one wallet yourself; the rules forbid self-trading.

**Step 2 (full, needs ~0.5 OKB up front): mint the transistors needed and tape out all 3 policy circuits.**
```bash
PROCESSOR=0x... BOND=2000 forge script script/Stego.s.sol:TapeOutPolicies --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```

**Step 3: deploy the specs, registry and vault, then propose the circuits** (starts the timelock).
```bash
PROCESSOR=0x... WITHDRAW_ID=1 DRAWDOWN_ID=2 ALLOCATION_ID=3 BOND=2000 TIMELOCK_SECONDS=86400 ENTRY_FEE_BPS=10 THROTTLE_FEE_BPS=100 DEPOSIT_CAP_WEI=5000000000000000000 forge script script/Stego.s.sol:DeployStego --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```

**Step 4: after the timelock, activate** (anyone can call).
```bash
REGISTRY=0x... forge script script/Stego.s.sol:ActivatePolicies --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```

**Phase 2 (recommended): tape out circuits #2–#3 and prepare the bonds.** It mints in one round by default (each mint pays a fixed 0.00066 OKB protocol fee), withdraws the creator proceeds straight after and checks nothing is left unclaimed. It is resumable: circuits already taped out are skipped. Rehearsed from the real wallet with +0.5 OKB: 1 round, 0 left unclaimed, total cost 0.0033 OKB. Add `ROUND_WEI=50000000000000000` only if you want to cap each round at 0.05 OKB.
```bash
PROCESSOR=0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C BOND=2000 forge script script/Stego.s.sol:Phase2Safe --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```

**Recurring: honour the 25% commitment.** The script computes all proceeds ever (`minted() × mintPrice()`), subtracts what is already recorded on-chain in `PolicyRegistry.notifiedBy(creator)`, and streams exactly the shortfall as WOKB to active policy authors. Running it twice never double-pays.
```bash
PROCESSOR=0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C REGISTRY=0x... forge script script/Stego.s.sol:HonourCommitment --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```
Claim author rewards for your circuits, unwrapped back to OKB:
```bash
REGISTRY=0x... forge script script/Stego.s.sol:ClaimAuthorRewards --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```

Afterwards, verify the contracts on OKLink.

## Design choices that answer the obvious critiques
- **"A Solidity `if` would be cheaper."** True (~3k vs ~0.3–0.9M gas, still < $0.001 on X Layer). The circuit buys three things an `if` can't: it can't be upgraded, it can be exhaustively verified by anyone, and strangers can author it safely because a circuit cannot call out or move funds. Slots are envelopes, not one fixed function, so designs genuinely differ (`WITHDRAW_GUARD_V1` vs the stricter `WITHDRAW_GUARD_STRICT`).
- **"TapeOut can upgrade processors."** The registry pins TapeOut's beacon implementation. On any upgrade, slashing freezes (honest authors can't be punished for TapeOut's change) and verdicts stop being trusted. Vault exits fail open, and deposits and rebalances fail closed until the curator reviews and re-pins.
- **"Strangers could push a bad but compliant policy."** Activation needs curator approval plus the 24 h timelock, and the curator can reject pending designs.
- **"The 25% promise is just a promise."** The processor's creator is a wallet, so it can't be enforced by code after the fact. It is made auditable instead: the dashboard tracks mint proceeds vs amounts streamed, and each payment emits `RewardNotified`.
- **"8-bit inputs are coarse."** Intentional: 16 input bits keep every circuit exhaustively provable (65,536 cases). Rounding is conservative (requests round up).

## Known limits (disclose them, don't hide them)
- Unaudited, hackathon build. The deposit cap starts at 5 WOKB.
- TapeOut processors are upgradeable by TapeOut (beacon proxy). `reportTamper` pulls a circuit out of service if its netlist ever changes.
- A withdrawal's epoch budget is measured against TVL at the first action of the epoch, so very large deposit-then-exit within one day can be throttled.
