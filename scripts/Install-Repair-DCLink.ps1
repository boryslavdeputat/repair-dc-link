#Requires -RunAsAdministrator
<#
  Install Repair-DCLink on THIS satellite domain controller (the one that is
  often powered off or sits on another VLAN).

  Run once as Domain Admin on the satellite DC:

    powershell -ExecutionPolicy Bypass -File .\Install-Repair-DCLink.ps1

  Optional:

    .\Install-Repair-DCLink.ps1 -DomainFqdn contoso.com -PrimaryDC DC1
#>
[CmdletBinding()]
param(
  [string]$ScriptPath = 'C:\Scripts\Repair-DCLink.ps1',
  [string]$SourceScript = '',
  [string]$DomainFqdn = '',
  [string]$PrimaryDC = ''
)

$ErrorActionPreference = 'Stop'
if (-not $SourceScript) {
  $SourceScript = Join-Path $PSScriptRoot 'Repair-DCLink.ps1'
}
if (-not (Test-Path $SourceScript)) {
  throw "Cannot find Repair-DCLink.ps1 next to installer: $SourceScript"
}

if (-not $DomainFqdn) { $DomainFqdn = $env:USERDNSDOMAIN }
if (-not $DomainFqdn) {
  $DomainFqdn = (Get-WmiObject Win32_ComputerSystem).Domain
}
if (-not $PrimaryDC) {
  $nl = & nltest.exe /dsgetdc:$DomainFqdn /pdc 2>&1 | Out-String
  if ($nl -match 'DC:\s*\\\\([^\s\\]+)') { $PrimaryDC = $Matches[1].Split('.')[0] }
}
if (-not $DomainFqdn -or -not $PrimaryDC) {
  throw 'Pass -DomainFqdn and -PrimaryDC (could not auto-detect).'
}

$dir = Split-Path $ScriptPath -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$srcFull = (Resolve-Path $SourceScript).Path
$dstFull = $ScriptPath
if ($srcFull.ToLower() -ne $dstFull.ToLower()) {
  Copy-Item $SourceScript $ScriptPath -Force
}
Write-Host "Installed script: $ScriptPath"

$wrapper = Join-Path $dir 'Repair-DCLink-Task.cmd'
@(
  '@echo off'
  "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -DomainFqdn $DomainFqdn -PrimaryDC $PrimaryDC"
) | Set-Content -Path $wrapper -Encoding ASCII

# schtasks /TR must point at the .cmd. Do not put -NoProfile on this line.
schtasks.exe /Create /TN "Repair-DCLink-OnStart" /TR $wrapper /SC ONSTART /DELAY 0003:00 /RU SYSTEM /RL HIGHEST /F | Out-Host
schtasks.exe /Create /TN "Repair-DCLink-Hourly" /TR $wrapper /SC HOURLY /MO 1 /RU SYSTEM /RL HIGHEST /F | Out-Host

Write-Host ""
Write-Host "Tasks created (SYSTEM, highest):"
Write-Host "  Repair-DCLink-OnStart   - 3 min after boot"
Write-Host "  Repair-DCLink-Hourly    - every hour"
Write-Host "Log:    C:\Logs\Repair-DCLink.log"
Write-Host "Status: C:\Logs\Repair-DCLink.status.txt"
Write-Host ""
Write-Host "Run now:"
Write-Host "  schtasks /Run /TN Repair-DCLink-OnStart"
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath"
