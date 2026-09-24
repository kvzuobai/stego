# Stego launch checklist (wallet balance 0.1557 OKB)

Every step below was rehearsed on a copy of X Layer mainnet **from the real deployment wallet with its exact balance**. Measured cost of all setup: 0.0046 OKB. The wallet holds 0.061 OKB after the 0.09 season fund.

**PowerShell users:** the commands are written in bash style (`NAME=value command`). In PowerShell, set each value with `$env:NAME="value"` on its own line first. Values stay set for the whole window, so open a fresh window for each step, or re-set every value. Launch steps 1–2 are done (see DEPLOYMENTS.md).

Run everything from the `contracts` folder with the keystore account `0xstego-deployer`. After each step, send the printed output to Claude to verify on-chain before continuing.

```bash
cd "E:/bot/claude tapeout hackathon/contracts"
```

## Optional: publish source code on OKLink during deployment
Get a free API key at OKLink's developer portal, then add these flags to the steps marked 🔎. If verification fails, the deployment still succeeds and verification can be retried separately.
```
--verify --verifier oklink --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER --etherscan-api-key YOUR_OKLINK_KEY
```

## Day 0
**1. Circuits #2 and #3, plus 6,000 STEGO for bonds** (≈3 mint rounds; the mint money comes straight back)
```bash
PROCESSOR=0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C BOND=2000 forge script script/Stego.s.sol:Phase2Safe --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```
Note the printed `DRAWDOWN_ID` and `ALLOCATION_ID` (expected 2 and 3).

**2. 🔎 Registry + vault, circuits proposed and approved** (starts the 24 h wait)
```bash
PROCESSOR=0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C WITHDRAW_ID=1 DRAWDOWN_ID=2 ALLOCATION_ID=3 BOND=2000 TIMELOCK_SECONDS=86400 ENTRY_FEE_BPS=10 THROTTLE_FEE_BPS=100 DEPOSIT_CAP_WEI=5000000000000000000 forge script script/Stego.s.sol:DeployStego --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```

**3. 🔎 Official Nerve Season 1** (joins open 4 days, season ends after 7; min deposit 0.01 OKB; early joiners earn a larger pot share; STEGO Boost enabled; the exit rule is checked against the safety envelope on-chain; the on-chain name is "Stego Nerve - Season 1")
```bash
PROCESSOR=0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C NERVE_JOIN_HOURS=96 NERVE_SEASON_HOURS=168 forge script script/Stego.s.sol:DeployNerve --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```
Claude then puts the three addresses into `web/index.html`, and you publish the website.

## Day 1 (24 h after step 2)
**4. Activate the three rules**
```bash
REGISTRY=0x... forge script script/Stego.s.sol:ActivatePolicies --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```

**5. Honour the 25% commitment** (≈0.108 OKB streamed and claimed straight back as author; net ≈ 0)
```bash
PROCESSOR=0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C REGISTRY=0x... forge script script/Stego.s.sol:HonourCommitment --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer --broadcast --slow
```

**6. Season fund (0.09 OKB)**: use "Add to pot" on the website, or:
```bash
cast send 0xNERVE "fund()" --value 0.09ether --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer
```

**7. Your own tests on the website:** a Nerve seat (e.g. 0.005 OKB + 0.00132 ticket) and a small vault deposit (e.g. 0.01 OKB). If you are the only vault depositor, you can take out about 25% per day.

## During the season
- Re-run step 5 now and then. Every ticket sold adds a little to the 25% owed, and the website's tracker shows any shortfall.
- Play from **one wallet only**.

## Designer seasons (for Season 2+)
Pick a community circuit, check it with `cd circuits && node scripts/check-candidate.mjs <id>`, then deploy the next season with `NERVE_EXIT_RULE_CIRCUIT=<id>` added to the step-3 command. Its owner earns the 10% designer cut.

## Season 2: 48-hour sprint with the diamond-hands bonus (after Season 1 ends on 1 Oct)
NerveSeason2 adds a +20% pot-weight bonus for players who never leave, plus an on-chain player list (the site shows a leaderboard automatically). Joins stay open 24 h, and the season ends after 48 h.
```powershell
$env:PROCESSOR="0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C"
forge script script/Stego.s.sol:DeployNerve2 --rpc-url https://xlayerrpc.okx.com --account stego-deployer --broadcast --slow
```
Then set `nerve:` in `web/index.html` to the new address, `git push`, fund the pot (`cast send <NERVE2> "fund()" --value <amount>ether ...`), and promote. It must end before the 6 Oct deadline.

## After the season ends
- Claim your seat (if any) and the 10% designer cut on the website (`Claim`), or run `cast send 0xNERVE "claimDesigner()" --rpc-url https://xlayerrpc.okx.com --account 0xstego-deployer`.
- If nobody else played, all of the season fund comes back to you (as the only stayer and/or as designer).
