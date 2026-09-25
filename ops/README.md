# One-click operations

Each script does a whole phase. The ones that send transactions ask for your wallet password **once**, keep it only in that window, and clear it at the end. Every script checks the result on-chain and stops before sending anything if something looks wrong.

Run from the project folder in PowerShell:

| When | Command | Password? |
|---|---|---|
| Any time: see everything (wallet, pot, players, rules, 25% promise, deadlines) | `powershell -ExecutionPolicy Bypass -File ops\status.ps1` | No |
| When status says there's a 25% shortfall (new STEGO minted) | `powershell -ExecutionPolicy Bypass -File ops\honour.ps1` | Yes |
| After a season ends: claim your seat + designer cut, settle the 25% | `powershell -ExecutionPolicy Bypass -File ops\season-end.ps1` | Yes |
| Launch the next season: deploy, fund the pot, update the website, push to GitHub | `powershell -ExecutionPolicy Bypass -File ops\season2-launch.ps1 -PotOkb 0.05` | Yes |

`season2-launch.ps1` options: `-SeasonName "Stego Nerve - Season 3"`, `-JoinHours 24`, `-SeasonHours 48`, `-DiamondBps 2000`, `-ExitRuleCircuit 1`, `-NoPush`. It refuses to run while the current season is still going (override with `-Force`).

All four were rehearsed on a copy of X Layer mainnet (the three that send transactions ran from the real wallet address). `status.ps1` also ran against live mainnet.
