# Read-only status report. No password, no transactions.
# Run:  powershell -ExecutionPolicy Bypass -File ops\status.ps1
. "$PSScriptRoot\common.ps1"
Assert-Tools

$now = [int64](& cast block latest --field timestamp --rpc-url $RPC 2>$null | Select-Object -First 1)
function Fmt-Time([int64]$t) { ([DateTimeOffset]::FromUnixTimeSeconds($t)).ToOffset([TimeSpan]::FromHours(7)).ToString("yyyy-MM-dd HH:mm") + " (UTC+7)" }

$html = Get-Content $Web -Raw -Encoding UTF8
$nerve = [regex]::Match($html, 'nerve:\s*"(0x[0-9a-fA-F]{40})"').Groups[1].Value

Write-Step "Wallet $CREATOR"
Write-Host ("    OKB balance:           " + (To-Okb (Get-Balance $CREATOR)))
$owed = Invoke-Call $TRANSISTORS "owed(address)(uint256)" $CREATOR
Write-Host ("    Unclaimed mint income: " + (To-Okb $owed) + " OKB")

Write-Step "STEGO and the 25% commitment"
$minted = [decimal](Invoke-Call $TRANSISTORS "minted()(uint256)")
$price = [decimal](Invoke-Call $TRANSISTORS "mintPrice()(uint256)")
$due = [decimal]::Floor($minted * $price * 2500 / 10000)
$paid = [decimal](Invoke-Call $REGISTRY "notifiedBy(address)(uint256)" $CREATOR)
Write-Host "    STEGO minted:          $minted"
Write-Host ("    25% due / streamed:    " + (To-Okb "$due") + " / " + (To-Okb "$paid") + " OKB")
if ($due -gt $paid) { Write-Warn2 ("Shortfall " + (To-Okb ("{0}" -f ($due - $paid))) + " OKB. Run ops\honour.ps1") } else { Write-Ok "Commitment fully honoured" }

Write-Step "Rules and vault"
$live = 0
foreach ($slot in @("WITHDRAW", "DRAWDOWN", "ALLOCATION")) {
    $id = Invoke-Call $REGISTRY "activeCircuit(bytes32)(uint256)" (& cast format-bytes32-string $slot)
    if ($id -ne "0") { $live++ }
    Write-Host "    $slot -> circuit #$id"
}
Write-Host ("    Vault total deposited: " + (To-Okb (Invoke-Call $VAULT "totalAssets()(uint256)")) + " OKB")
if ($live -eq 3) { Write-Ok "All 3 rules live" } else { Write-Warn2 "$live of 3 rules live" }

if ($nerve) {
    Write-Step ("Current season " + (& cast call $nerve "name()(string)" --rpc-url $RPC 2>$null) + " $nerve")
    $join = [int64](Invoke-Call $nerve "joinDeadline()(uint64)")
    $end = [int64](Invoke-Call $nerve "seasonEnd()(uint64)")
    Write-Host ("    Pot:                   " + (To-Okb (Invoke-Call $nerve "pot()(uint256)")) + " OKB")
    Write-Host ("    Players in / ever:     " + (Invoke-Call $nerve "activePlayers()(uint256)") + " / " + (Invoke-Call $nerve "players()(uint256)"))
    Write-Host ("    Pool:                  " + (To-Okb (Invoke-Call $nerve "totalPrincipal()(uint256)")) + " OKB")
    Write-Host ("    Joins close:           " + (Fmt-Time $join) + $(if ($now -ge $join) { "  [closed]" } else { "" }))
    Write-Host ("    Season ends:           " + (Fmt-Time $end) + $(if ($now -ge $end) { "  [ENDED: run ops\season-end.ps1]" } else { "" }))
}
Write-Host ""
