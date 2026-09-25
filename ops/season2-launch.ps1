# Launch the next Nerve season in one go: deploy (NerveSeason2), fund the pot, point the website at it
# (the old season moves to "past seasons" so its players can still claim), record it, commit and push
# (Vercel then redeploys the site automatically). One password prompt.
# Run:  powershell -ExecutionPolicy Bypass -File ops\season2-launch.ps1 -PotOkb 0.05
param(
    [Parameter(Mandatory = $true)][string]$PotOkb,
    [string]$SeasonName = "Stego Nerve - Season 2",
    [int]$JoinHours = 24,
    [int]$SeasonHours = 48,
    [int]$DiamondBps = 2000,
    [int]$ExitRuleCircuit = 1,
    [switch]$NoPush,
    [switch]$Force
)
. "$PSScriptRoot\common.ps1"
Assert-Tools

$html = Get-Content $Web -Raw -Encoding UTF8
$old = [regex]::Match($html, 'nerve:\s*"(0x[0-9a-fA-F]{40})"').Groups[1].Value
$now = [int64](& cast block latest --field timestamp --rpc-url $RPC 2>$null | Select-Object -First 1)
if ($old -and -not $Force) {
    $oldEnd = [int64](Invoke-Call $old "seasonEnd()(uint64)")
    if ($now -lt $oldEnd) { throw "The current season $old has not ended yet. Run ops\season-end.ps1 after it ends (or pass -Force)." }
}
$bal = [decimal](Get-Balance $CREATOR)
$need = [decimal]$PotOkb * 1e18 + 2e15
if ($bal -lt $need) { throw ("Wallet has " + (To-Okb "$bal") + " OKB; need about $PotOkb OKB for the pot plus gas.") }

Use-Password
try {
    Write-Step "Deploying $SeasonName (join $JoinHours h, season $SeasonHours h, diamond bonus $($DiamondBps / 100)%)"
    $env:PROCESSOR = $PROCESSOR
    $env:NERVE_SEASON_NAME = $SeasonName
    $env:NERVE_JOIN_HOURS = "$JoinHours"
    $env:NERVE_SEASON_HOURS = "$SeasonHours"
    $env:NERVE_DIAMOND_BONUS_BPS = "$DiamondBps"
    $env:NERVE_EXIT_RULE_CIRCUIT = "$ExitRuleCircuit"
    $out = Invoke-ForgeScript "DeployNerve2"
    $new = [regex]::Match($out, "NERVE\s+=\s+(0x[0-9a-fA-F]{40})").Groups[1].Value
    if (-not $new) { throw "Could not read the new season address from the output:`n$out" }
    Write-Ok "Deployed at $new"
    $check = & cast call $new "name()(string)" --rpc-url $RPC 2>$null
    Write-Ok "On-chain name: $check"

    Write-Step "Funding the pot with $PotOkb OKB"
    $h = Invoke-Send $new "fund()" $PotOkb
    Write-Ok ("Pot now " + (To-Okb (Invoke-Call $new "pot()(uint256)")) + " OKB  $h")

    Write-Step "Updating the website"
    $html = Get-Content $Web -Raw -Encoding UTF8
    $html = [regex]::Replace($html, '(\n  nerve: )"0x[0-9a-fA-F]{40}",[^\n]*', ('$1"' + $new + '", // ' + $SeasonName))
    if ($old) {
        $html = [regex]::Replace($html, 'pastSeasons: \[([^\]]*)\]', {
                param($m)
                $items = $m.Groups[1].Value.Trim()
                if ($items -match [regex]::Escape($old)) { return $m.Value }
                if ($items) { return "pastSeasons: [$items, `"$old`"]" } else { return "pastSeasons: [`"$old`"]" }
            })
    }
    [IO.File]::WriteAllText($Web, $html, (New-Object Text.UTF8Encoding($false)))
    Write-Ok "web/index.html now points at $new (previous season kept under pastSeasons)"

    $dep = $Deployments
    $join = [int64](Invoke-Call $new "joinDeadline()(uint64)")
    $end = [int64](Invoke-Call $new "seasonEnd()(uint64)")
    $fmt = { param($t) ([DateTimeOffset]::FromUnixTimeSeconds($t)).ToOffset([TimeSpan]::FromHours(7)).ToString("yyyy-MM-dd HH:mm") }
    Add-Content -Path $dep -Encoding UTF8 -Value ("`n## $SeasonName`n| Item | Value |`n|---|---|`n| Contract | ``$new`` (NerveSeason2) |`n| Joins close / season ends | " + (& $fmt $join) + " / " + (& $fmt $end) + " (UTC+7) |`n| Diamond bonus / exit rule | +$($DiamondBps / 100)% / circuit #$ExitRuleCircuit |`n| Pot seed | $PotOkb OKB (tx ``$h``) |`n")

    Write-Step "Committing"
    if ($TestMode) { Write-Host "    (test mode: nothing committed)"; Write-Step "Done (test)"; Write-Host "    New season: $new"; return }
    Push-Location $Root
    try {
        $ErrorActionPreference = "Continue"
        & git add web/index.html DEPLOYMENTS.md | Out-Null
        & git commit -q -m "Launch $SeasonName" | Out-Null
        if (-not $NoPush -and -not $TestMode) {
            & git push 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok "Pushed to GitHub; Vercel will redeploy the site in about a minute." } else { Write-Warn2 "git push failed; run 'git push' yourself." }
        } else { Write-Host "    (not pushed)" }
    } finally { Pop-Location }

    Write-Step "Done"
    Write-Host "    $SeasonName is live: $new"
    Write-Host ("    Joins close " + (& $fmt $join) + ", season ends " + (& $fmt $end) + " (UTC+7)")
    Write-Host ("    Wallet: " + (To-Okb (Get-Balance $CREATOR)) + " OKB")
} finally { Clear-Password }
