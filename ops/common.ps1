# Shared helpers for the Stego one-click scripts. Dot-source it: . "$PSScriptRoot\common.ps1"
# The wallet password is typed once per run, kept only in this PowerShell process, and cleared at the end.
# Test mode (for rehearsals on a local fork): $env:STEGO_RPC="http://127.0.0.1:8547"; $env:STEGO_TEST_UNLOCKED="1"

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
$Contracts = Join-Path $Root "contracts"
$Web = if ($env:STEGO_TEST_WEB) { $env:STEGO_TEST_WEB } else { Join-Path $Root "web\index.html" }
$Deployments = if ($env:STEGO_TEST_DEP) { $env:STEGO_TEST_DEP } else { Join-Path $Root "DEPLOYMENTS.md" }

$RPC = if ($env:STEGO_RPC) { $env:STEGO_RPC } else { "https://xlayerrpc.okx.com" }
$ACCOUNT = "stego-deployer"
$CREATOR = "0xC4AAaf5BD7e688F19F70E1e5067aF4c2d1307A74"
$PROCESSOR = "0x0d90BA20B57D63b8eEA92d674ef87284B2EB290C"
$TRANSISTORS = "0x3775Ada4083fDbCc4A3CA0e3d38f15d17C187225"
$REGISTRY = "0x0A184781674dc6dC6C689f72235a10A2d7D5B37d"
$VAULT = "0x784Ba316b123b7099631FB834D9aC2D6B31e8b75"
$TestMode = ($env:STEGO_TEST_UNLOCKED -eq "1")

function Write-Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Ok($text) { Write-Host "    OK  $text" -ForegroundColor Green }
function Write-Warn2($text) { Write-Host "    !!  $text" -ForegroundColor Yellow }

function Assert-Tools {
    foreach ($t in @("forge", "cast", "git")) {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { throw "$t is not installed or not on PATH." }
    }
}

function Use-Password {
    if ($TestMode) { return }
    $sec = Read-Host "Wallet password for '$ACCOUNT' (typed once, used only in this window)" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $env:ETH_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Clear-Password { Remove-Item Env:ETH_PASSWORD -ErrorAction SilentlyContinue }

function Get-SignerArgs {
    if ($TestMode) { return @("--unlocked", "--from", $CREATOR) }
    return @("--account", $ACCOUNT)
}

# Read-only contract call; returns the first value as a string.
function Invoke-Call([string]$to, [string]$sig) {
    $ErrorActionPreference = "Continue" # native tools write progress to stderr; judge by exit code
    $extra = @($args)
    $out = & cast call $to $sig @extra --rpc-url $RPC 2>&1
    if ($LASTEXITCODE -ne 0) { throw "cast call $sig failed: $out" }
    return (($out | Select-Object -First 1) -split " ")[0].Trim()
}

function Get-Balance([string]$addr) { $ErrorActionPreference = "Continue"; return ((& cast balance $addr --rpc-url $RPC 2>$null) | Select-Object -First 1).Trim() }
function To-Okb([string]$wei) { return (& cast from-wei $wei).Trim() }

# Sends one transaction; stops the script if it fails.
function Invoke-Send([string]$to, [string]$sig, [string]$valueEther) {
    $ErrorActionPreference = "Continue"
    $extra = @($args)
    $cmd = @("send", $to, $sig) + $extra + @("--rpc-url", $RPC) + (Get-SignerArgs)
    if ($valueEther) { $cmd += @("--value", "${valueEther}ether") }
    $out = & cast @cmd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Transaction '$sig' failed:`n$out" }
    $hash = ($out | Select-String -Pattern "transactionHash\s+(0x[0-9a-fA-F]{64})" | Select-Object -First 1)
    if ($hash) { return $hash.Matches[0].Groups[1].Value }
    return ""
}

# Runs a forge script from contracts/ and returns its full output.
function Invoke-ForgeScript([string]$name) {
    $ErrorActionPreference = "Continue"
    Push-Location $Contracts
    try {
        $signer = if ($TestMode) { @("--unlocked", "--sender", $CREATOR) } else { @("--account", $ACCOUNT) }
        $out = & forge script "script/Stego.s.sol:$name" --rpc-url $RPC @signer --broadcast --slow 2>&1
        $text = ($out | Out-String)
        if ($LASTEXITCODE -ne 0 -or $text -notmatch "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL") {
            throw "forge script $name failed:`n$text"
        }
        return $text
    } finally { Pop-Location }
}
