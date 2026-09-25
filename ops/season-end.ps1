# After a Nerve season ends: claim your seat (if any) and the designer cut, then settle the 25% commitment.
# One password prompt.  Run:  powershell -ExecutionPolicy Bypass -File ops\season-end.ps1 [-Season 0x...]
param([string]$Season)
. "$PSScriptRoot\common.ps1"
Assert-Tools

if (-not $Season) {
    $html = Get-Content $Web -Raw -Encoding UTF8
    $Season = [regex]::Match($html, 'nerve:\s*"(0x[0-9a-fA-F]{40})"').Groups[1].Value
}
if (-not $Season) { throw "No season address found." }
$name = (& cast call $Season "name()(string)" --rpc-url $RPC 2>$null)
$now = [int64](& cast block latest --field timestamp --rpc-url $RPC 2>$null | Select-Object -First 1)
$end = [int64](Invoke-Call $Season "seasonEnd()(uint64)")
if ($now -lt $end) {
    $mins = [math]::Ceiling(($end - $now) / 60)
    throw "$name has not ended yet ($mins minutes left). Nothing was sent."
}

$before = Get-Balance $CREATOR
Use-Password
try {
    Write-Step "Closing $name ($Season)"
    $seat = Invoke-Call $Season "principal(address)(uint256)" $CREATOR
    if ($seat -ne "0") {
        $h = Invoke-Send $Season "claim()"
        Write-Ok "Claimed your seat + pot share  $h"
    } else { Write-Host "    (you had no seat in this season)" }

    $cid = Invoke-Call $Season "circuitId()(uint256)"
    $designer = Invoke-Call $PROCESSOR "ownerOf(uint256)(address)" $cid
    if ($designer.ToLower() -eq $CREATOR.ToLower()) {
        # claimDesigner settles the season first, so this works even if nobody called settle yet
        $h = Invoke-Send $Season "claimDesigner()"
        Write-Ok "Claimed the designer cut  $h"
    } else { Write-Host "    Designer cut belongs to $designer (not you)." }

    Write-Step "Settling the 25% commitment for any new mints"
    $minted = [decimal](Invoke-Call $TRANSISTORS "minted()(uint256)")
    $price = [decimal](Invoke-Call $TRANSISTORS "mintPrice()(uint256)")
    $due = [decimal]::Floor($minted * $price * 2500 / 10000)
    $paid = [decimal](Invoke-Call $REGISTRY "notifiedBy(address)(uint256)" $CREATOR)
    if ($due -gt $paid) {
        $env:PROCESSOR = $PROCESSOR; $env:REGISTRY = $REGISTRY
        Invoke-ForgeScript "HonourCommitment" | Out-Null
        Write-Ok "Commitment topped up"
    } else { Write-Ok "Commitment already fully honoured" }

    $after = Get-Balance $CREATOR
    Write-Step "Done"
    Write-Host ("    Wallet: " + (To-Okb $before) + " -> " + (To-Okb $after) + " OKB")
    Write-Host ("    Left in the season contract: " + (To-Okb (Get-Balance $Season)) + " OKB (players who still have to claim)")
} finally { Clear-Password }
