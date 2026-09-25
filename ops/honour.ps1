# Pays any shortfall of the public 25% commitment (withdraws creator income first). One password prompt.
# Run:  powershell -ExecutionPolicy Bypass -File ops\honour.ps1
. "$PSScriptRoot\common.ps1"
Assert-Tools

$minted = [decimal](Invoke-Call $TRANSISTORS "minted()(uint256)")
$price = [decimal](Invoke-Call $TRANSISTORS "mintPrice()(uint256)")
$due = [decimal]::Floor($minted * $price * 2500 / 10000)
$paid = [decimal](Invoke-Call $REGISTRY "notifiedBy(address)(uint256)" $CREATOR)
Write-Step ("25% due " + (To-Okb "$due") + " OKB, already streamed " + (To-Okb "$paid") + " OKB")
if ($due -le $paid) { Write-Ok "Nothing to do: the commitment is fully honoured."; exit 0 }

Use-Password
try {
    $env:PROCESSOR = $PROCESSOR
    $env:REGISTRY = $REGISTRY
    Write-Step "Withdrawing creator income and streaming the shortfall"
    $out = Invoke-ForgeScript "HonourCommitment"
    ($out -split "`n") | Where-Object { $_ -match "chunk|streamed in total|honoured|still owed" } | ForEach-Object { Write-Host ("    " + $_.Trim()) }
    $paid2 = [decimal](Invoke-Call $REGISTRY "notifiedBy(address)(uint256)" $CREATOR)
    if ($paid2 -ge $due) { Write-Ok "Commitment fully honoured on-chain." } else { Write-Warn2 "Still short; top up the wallet and run again." }
    Write-Host ("    Wallet: " + (To-Okb (Get-Balance $CREATOR)) + " OKB")
} finally { Clear-Password }
