<#
.SYNOPSIS
  Repair Active Directory replication on a satellite DC after it was powered off
  or isolated on another VLAN. Pulls ONLY from the designated master (PDC).

.DESCRIPTION
  Hub-and-spoke model:
    - Master / PDC stays the source of truth.
    - Each satellite DC pulls naming contexts FROM the master toward itself.
    - Other satellites may be offline for days or on another VLAN.
    - RPC 1722 / 1908 / 1256 to those partners is EXPECTED and is not a failure.

  Safe as SYSTEM from Task Scheduler at startup (no prompts).
  Does NOT seize FSMO. Does NOT run a repair on the master itself.
  If this DC was offline longer than tombstone lifetime (event 2042), it stops.

  PowerShell 5.1, ASCII log files. schtasks must call a .cmd wrapper
  (passing powershell.exe -NoProfile in /TR is parsed as a schtasks switch).

.PARAMETER DomainFqdn
  AD DNS domain. Default: this computer's domain.

.PARAMETER PrimaryDC
  Short name of the master DC (usually the PDC emulator). Default: auto-detect.

.PARAMETER IgnorePartners
  Other DCs that may be offline / other VLAN. Default: every DC except local and master.

.EXAMPLE
  .\Repair-DCLink.ps1
  .\Repair-DCLink.ps1 -DomainFqdn contoso.com -PrimaryDC DC1
  .\Install-Repair-DCLink.ps1
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
  [string]$DomainFqdn = '',
  [string]$PrimaryDC  = '',
  [string]$LocalDC    = $env:COMPUTERNAME,
  [string[]]$IgnorePartners = @(),
  [int]$WaitForMasterMinutes = 30,
  [int]$RetrySeconds = 30,
  [switch]$SkipDnsFix,
  [switch]$SkipTimeFix,
  [string]$LogDir = 'C:\Logs'
)

$ErrorActionPreference = 'Continue'
$script:LogFile = Join-Path $LogDir 'Repair-DCLink.log'
$script:StatusFile = Join-Path $LogDir 'Repair-DCLink.status.txt'

function Write-Log {
  param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')]$Level = 'INFO')
  $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
  try {
    $dir = Split-Path $script:LogFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 2MB)) {
      $bak = $script:LogFile + '.old'
      Remove-Item $bak -Force -ErrorAction SilentlyContinue
      Move-Item $script:LogFile $bak -Force
    }
    Add-Content -Path $script:LogFile -Value $line -Encoding ASCII
  } catch {}
  $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }[$Level]
  Write-Host $line -ForegroundColor $color
}

function Save-Status {
  param([int]$Code, [string]$Text)
  $body = @(
    "LastRun=$(Get-Date -Format s)"
    "ExitCode=$Code"
    "LocalDC=$LocalDC"
    "PrimaryDC=$PrimaryDC"
    "Domain=$DomainFqdn"
    "Result=$Text"
  ) -join "`r`n"
  Set-Content -Path $script:StatusFile -Value $body -Encoding ASCII
}

function Invoke-Native {
  param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string[]]$ArgumentList)
  Write-Log ("CMD {0} {1}" -f $File, ($ArgumentList -join ' '))
  $outFile = [IO.Path]::GetTempFileName()
  $errFile = [IO.Path]::GetTempFileName()
  try {
    $p = Start-Process -FilePath $File -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow `
      -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $stdout = ''
    $stderr = ''
    if (Test-Path $outFile) { $stdout = Get-Content $outFile -Raw -ErrorAction SilentlyContinue }
    if (Test-Path $errFile) { $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue }
    if ($stdout) { Write-Log ($stdout.TrimEnd()) }
    if ($stderr) { Write-Log $stderr.TrimEnd() 'WARN' }
    return [pscustomobject]@{ ExitCode = [int]$p.ExitCode; StdOut = [string]$stdout; StdErr = [string]$stderr }
  } catch {
    Write-Log $_.Exception.Message 'ERROR'
    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = $_.Exception.Message }
  } finally {
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ShortName([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }
  return $Name.Split('.')[0].ToUpper()
}

function Resolve-DomainFqdn {
  param([string]$Hint)
  if ($Hint) { return $Hint.Trim().ToLower() }
  if ($env:USERDNSDOMAIN) { return $env:USERDNSDOMAIN.ToLower() }
  try {
    $d = (Get-WmiObject Win32_ComputerSystem -ErrorAction Stop).Domain
    if ($d -and $d -ne 'WORKGROUP') { return $d.ToLower() }
  } catch {}
  return ''
}

function Resolve-PrimaryDC {
  param([string]$Hint, [string]$Domain)
  if ($Hint) { return (Get-ShortName $Hint) }
  $r = Invoke-Native nltest.exe @("/dsgetdc:$Domain", '/pdc')
  $blob = $r.StdOut + $r.StdErr
  if ($blob -match 'DC:\s*\\\\([^\s\\]+)') {
    return (Get-ShortName $Matches[1])
  }
  $r2 = Invoke-Native nltest.exe @("/dsgetdc:$Domain")
  $blob2 = $r2.StdOut + $r2.StdErr
  if ($blob2 -match 'DC:\s*\\\\([^\s\\]+)') {
    return (Get-ShortName $Matches[1])
  }
  return ''
}

function Get-DomainControllerShortNames {
  param([string]$Domain)
  $names = New-Object System.Collections.Generic.List[string]
  $r = Invoke-Native nltest.exe @("/dclist:$Domain")
  foreach ($line in @(($r.StdOut + $r.StdErr) -split "`r?`n")) {
    if ($line -match '^\s*([A-Za-z0-9._-]+)') {
      $n = Get-ShortName $Matches[1]
      if ($n -and $n -notmatch 'GET|LIST|THE|COMMAND' -and -not $names.Contains($n)) {
        [void]$names.Add($n)
      }
    }
  }
  return $names
}

function Test-IsHubNamingContext {
  param([string]$Nc, [string]$DomainFqdn)
  if ([string]::IsNullOrWhiteSpace($Nc)) { return $false }
  $dn = 'DC=' + ($DomainFqdn -replace '\.', ',DC=')
  if ($Nc -eq $dn) { return $true }
  if ($Nc -eq "DC=DomainDnsZones,$dn") { return $true }
  if ($Nc -match '^CN=Configuration,') { return $true }
  if ($Nc -match '^CN=Schema,') { return $true }
  if ($Nc -match '^DC=ForestDnsZones,') { return $true }
  if ($Nc -match '^DC=DomainDnsZones,') { return $true }
  return $false
}

function Wait-ForMaster {
  param([string]$Fqdn, [int]$Minutes, [int]$Step)
  $deadline = (Get-Date).AddMinutes($Minutes)
  Write-Log "Waiting for master $Fqdn (up to $Minutes min)..."
  while ((Get-Date) -lt $deadline) {
    $ping = $false
    try { $ping = Test-Connection -ComputerName $Fqdn -Count 1 -Quiet -ErrorAction SilentlyContinue } catch {}
    $dnsOk = $false
    try {
      $null = [System.Net.Dns]::GetHostAddresses($Fqdn)
      $dnsOk = $true
    } catch {}
    $rpc = Invoke-Native nltest.exe @("/dsgetdc:$DomainFqdn")
    $nlOk = ($rpc.ExitCode -eq 0 -or ($rpc.StdOut -match 'Dom Name:'))
    $ldap = $false
    try {
      $tcp = New-Object System.Net.Sockets.TcpClient
      $iar = $tcp.BeginConnect($Fqdn, 389, $null, $null)
      $ldap = $iar.AsyncWaitHandle.WaitOne(2000, $false) -and $tcp.Connected
      $tcp.Close()
    } catch {}
    # ICMP is often blocked across VLANs. nltest or LDAP 389 is enough.
    if ($nlOk -or $ldap -or $ping) {
      Write-Log ("Master is reachable: {0} (nltest={1} ldap={2} ping={3})" -f $Fqdn, $nlOk, $ldap, $ping) 'OK'
      return $true
    }
    Write-Log "Master not ready yet (ping=$ping dns=$dnsOk ldap=$ldap). Sleep $Step sec." 'WARN'
    Start-Sleep -Seconds $Step
  }
  return $false
}

function Set-TimeFromMaster {
  param([string]$MasterFqdn)
  Write-Log "Time: prefer domain hierarchy, fallback to $MasterFqdn"
  [void](Invoke-Native w32tm.exe @('/config','/syncfromflags:domhier','/update'))
  $r = Invoke-Native w32tm.exe @('/resync','/rediscover')
  $blob = $r.StdOut + $r.StdErr
  if ($r.ExitCode -ne 0 -or $blob -match 'parameter is incorrect|unexpected') {
    [void](Invoke-Native w32tm.exe @('/config',"/manualpeerlist:$MasterFqdn,0x8",'/syncfromflags:manual','/update'))
    Restart-Service w32time -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    [void](Invoke-Native w32tm.exe @('/resync'))
  }
  [void](Invoke-Native w32tm.exe @('/query','/status'))
}

function Set-DnsTowardMaster {
  param([string]$MasterFqdn)
  $masterIps = @()
  try {
    $masterIps = @([System.Net.Dns]::GetHostAddresses($MasterFqdn) |
      Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
      ForEach-Object { $_.IPAddressToString })
  } catch {}
  if (-not $masterIps) {
    Write-Log "Cannot resolve master IP; skip DNS NIC fix." 'WARN'
    return
  }
  Write-Log ("Master IPv4: {0}" -f ($masterIps -join ', '))
  Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=true' | ForEach-Object {
    if ($_.Description -match 'Loopback|isatap|Teredo') { return }
    $nicIp = @($_.IPAddress) | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
    if (-not $nicIp) { return }
    $pref = $null
    foreach ($m in $masterIps) {
      $a = $nicIp.Split('.'); $b = $m.Split('.')
      if ($a[0] -eq $b[0] -and $a[1] -eq $b[1] -and $a[2] -eq $b[2]) { $pref = $m; break }
    }
    if (-not $pref) { $pref = $masterIps[0] }
    try {
      $rc = $_.SetDNSServerSearchOrder(@($pref, '127.0.0.1'))
      Write-Log ("NIC {0} ({1}) DNS {2},127.0.0.1 rc={3}" -f $_.Description, $nicIp, $pref, $rc.ReturnValue)
    } catch {
      Write-Log $_.Exception.Message 'WARN'
    }
  }
  [void](Invoke-Native ipconfig.exe @('/flushdns'))
  [void](Invoke-Native ipconfig.exe @('/registerdns'))
}

function Repair-SecureChannel {
  param([string]$Domain, [string]$MasterShort)
  $q = Invoke-Native nltest.exe @("/sc_query:$Domain")
  $blob = ($q.StdOut + $q.StdErr)
  if ($blob -match 'NERR_Success' -or $blob -match 'Trusted') {
    Write-Log "Secure channel query looks OK." 'OK'
    return $true
  }
  Write-Log "Secure channel unhealthy. Reset toward $MasterShort" 'WARN'
  $r = Invoke-Native nltest.exe @("/sc_reset:$Domain\$MasterShort")
  $blob2 = ($r.StdOut + $r.StdErr)
  if ($r.ExitCode -eq 0 -or $blob2 -match 'NERR_Success') { return $true }
  $r3 = Invoke-Native nltest.exe @("/sc_reset:$Domain")
  $blob3 = ($r3.StdOut + $r3.StdErr)
  return ($r3.ExitCode -eq 0 -or $blob3 -match 'NERR_Success')
}

function Get-NamingContexts {
  $list = New-Object System.Collections.Generic.List[string]
  try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $d = Get-ADRootDSE
    foreach ($nc in @($d.defaultNamingContext, $d.configurationNamingContext, $d.schemaNamingContext) + @($d.namingContexts)) {
      if ($nc -and -not $list.Contains($nc)) { [void]$list.Add($nc) }
    }
  } catch {
    $fallback = @(
      "DC=$($DomainFqdn.Replace('.',',DC='))"
      "CN=Configuration,DC=$($DomainFqdn.Replace('.',',DC='))"
      "CN=Schema,CN=Configuration,DC=$($DomainFqdn.Replace('.',',DC='))"
      "DC=DomainDnsZones,DC=$($DomainFqdn.Replace('.',',DC='))"
      "DC=ForestDnsZones,DC=$($DomainFqdn.Replace('.',',DC='))"
    )
    foreach ($nc in $fallback) { if (-not $list.Contains($nc)) { [void]$list.Add($nc) } }
  }
  return $list
}

function Test-TombstoneRisk {
  $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Directory Service'; Id = 2042; StartTime = (Get-Date).AddDays(-14) } -MaxEvents 5 -ErrorAction SilentlyContinue
  if ($ev) {
    Write-Log "Event 2042 found: this DC was offline too long (tombstone). Do NOT force-replicate. Demote and promote again." 'ERROR'
    return $true
  }
  return $false
}

function Sync-FromMaster {
  param([string]$LocalShort, [string]$MasterShort, [string]$Domain, [string[]]$Ignore)
  $ignoreU = @($Ignore | ForEach-Object { $_.ToUpper() } | Where-Object { $_ -and $_ -ne $LocalShort.ToUpper() -and $_ -ne $MasterShort.ToUpper() })
  Write-Log ("Hub-only pull from {0}. Ignore offline partners: {1}" -f $MasterShort, ($(if ($ignoreU) { $ignoreU -join ',' } else { '(none)' })))

  Write-Log "Recalculate KCC topology"
  [void](Invoke-Native repadmin.exe @('/kcc', $LocalShort))

  $ncs = Get-NamingContexts
  $ok = 0
  $fail = 0
  foreach ($nc in $ncs) {
    if (-not (Test-IsHubNamingContext -Nc $nc -DomainFqdn $Domain)) {
      Write-Log "Skip extra NC $nc (not required for hub repair)" 'WARN'
      continue
    }
    Write-Log "Pull NC from $MasterShort -> $LocalShort : $nc"
    $r = Invoke-Native repadmin.exe @('/replicate', $LocalShort, $MasterShort, $nc, '/force')
    $text = $r.StdOut + $r.StdErr
    if ($r.ExitCode -eq 0 -and $text -match 'completed successfully') { $ok++ }
    elseif ($r.ExitCode -eq 0 -and $text -notmatch 'ERROR|failed') { $ok++ }
    else { $fail++; Write-Log ("Replicate failed for {0}: exit={1}" -f $nc, $r.ExitCode) 'WARN' }
  }

  if (Get-Command dfsrdiag.exe -ErrorAction SilentlyContinue) {
    Write-Log "Poll DFSR for SYSVOL"
    [void](Invoke-Native dfsrdiag.exe @('PollAD'))
  }

  Write-Log "Replication summary (1722/1908/1256 to ignored partners is expected)"
  $sum = Invoke-Native repadmin.exe @('/replsummary')
  $show = Invoke-Native repadmin.exe @('/showrepl', $LocalShort)
  $blob = ($sum.StdOut + $show.StdOut)
  foreach ($p in $ignoreU) {
    if ($blob -match [regex]::Escape($p) -and $blob -match '1722|1908|1256') {
      Write-Log ("Partner {0} unreachable (VLAN/powered off). Ignored." -f $p) 'WARN'
    }
  }

  if ($ok -eq 0) { return $false }
  return $true
}

function Ensure-ScheduledTasks {
  param([string]$ScriptPath)
  if (-not $ScriptPath) { $ScriptPath = $PSCommandPath }
  if (-not $ScriptPath) { $ScriptPath = 'C:\Scripts\Repair-DCLink.ps1' }
  try {
    $dir = 'C:\Scripts'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $dest = Join-Path $dir 'Repair-DCLink.ps1'
    if ($ScriptPath -and (Test-Path $ScriptPath) -and ((Resolve-Path $ScriptPath).Path.ToLower() -ne $dest.ToLower())) {
      Copy-Item $ScriptPath $dest -Force
    }
    $wrapper = Join-Path $dir 'Repair-DCLink-Task.cmd'
    $argDomain = $DomainFqdn
    $argPdc = $PrimaryDC
    @(
      '@echo off'
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Repair-DCLink.ps1 -DomainFqdn $argDomain -PrimaryDC $argPdc"
    ) | Set-Content -Path $wrapper -Encoding ASCII
    # schtasks /TR must be a .cmd. Do not put -NoProfile on the schtasks command line.
    cmd.exe /c "schtasks /Create /TN Repair-DCLink-OnStart /TR C:\Scripts\Repair-DCLink-Task.cmd /SC ONSTART /DELAY 0003:00 /RU SYSTEM /RL HIGHEST /F"
    cmd.exe /c "schtasks /Create /TN Repair-DCLink-Hourly /TR C:\Scripts\Repair-DCLink-Task.cmd /SC HOURLY /MO 1 /RU SYSTEM /RL HIGHEST /F"
    Write-Log "Scheduled tasks ensured (OnStart + Hourly via Repair-DCLink-Task.cmd)" 'OK'
  } catch {
    Write-Log $_.Exception.Message 'WARN'
  }
}

function Repair-CoreServices {
  foreach ($svc in @('Netlogon','NTDS','DNS','W32Time')) {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if (-not $s) { continue }
    if ($s.Status -ne 'Running') {
      Write-Log "Starting service $svc (was $($s.Status))" 'WARN'
      try { Start-Service $svc -ErrorAction Stop } catch { Write-Log $_.Exception.Message 'ERROR' }
    }
  }
}

# -------------------- main --------------------
$exit = 1
$reason = 'not-started'
try {
  if (-not (Test-Admin)) { throw 'Run as Administrator / SYSTEM.' }

  $DomainFqdn = Resolve-DomainFqdn $DomainFqdn
  if (-not $DomainFqdn) { throw 'Cannot detect domain. Pass -DomainFqdn.' }

  $LocalDC = Get-ShortName $LocalDC
  $PrimaryDC = Resolve-PrimaryDC -Hint $PrimaryDC -Domain $DomainFqdn
  if (-not $PrimaryDC) { throw 'Cannot detect PDC. Pass -PrimaryDC.' }

  $primaryFqdn = "$PrimaryDC.$DomainFqdn"

  Write-Log "=== Repair-DCLink start ==="
  Write-Log "Domain=$DomainFqdn Local=$LocalDC Master=$PrimaryDC ($primaryFqdn)"

  if ($LocalDC -eq $PrimaryDC) {
    Write-Log "This computer IS the master. Nothing to pull. Exit." 'OK'
    Save-Status 0 'skipped-primary'
    exit 0
  }

  Repair-CoreServices
  Ensure-ScheduledTasks

  if (-not (Wait-ForMaster -Fqdn $primaryFqdn -Minutes $WaitForMasterMinutes -Step $RetrySeconds)) {
    $reason = 'master-unreachable'
    Save-Status 2 $reason
    Write-Log "Master $primaryFqdn still down. Task will retry next run." 'ERROR'
    exit 2
  }

  if (Test-TombstoneRisk) {
    $reason = 'tombstone-2042'
    Save-Status 3 $reason
    exit 3
  }

  if (-not $SkipDnsFix)  { Set-DnsTowardMaster -MasterFqdn $primaryFqdn }
  if (-not $SkipTimeFix) { Set-TimeFromMaster -MasterFqdn $primaryFqdn }

  if (-not (Repair-SecureChannel -Domain $DomainFqdn -MasterShort $PrimaryDC)) {
    Write-Log "Secure channel reset did not report success. Continue to replicate anyway." 'WARN'
  } else {
    Write-Log "Secure channel OK." 'OK'
  }

  $ignore = @($IgnorePartners | ForEach-Object { Get-ShortName $_ } | Where-Object { $_ })
  if (-not $ignore) {
    $all = @(Get-DomainControllerShortNames -Domain $DomainFqdn)
    $ignore = @($all | Where-Object { $_ -ne $LocalDC -and $_ -ne $PrimaryDC })
  }

  $synced = Sync-FromMaster -LocalShort $LocalDC -MasterShort $PrimaryDC -Domain $DomainFqdn -Ignore $ignore
  Write-Log "dcdiag replications (failures only to ignored partners are OK)"
  [void](Invoke-Native dcdiag.exe @('/test:replications','/q'))

  if ($synced) {
    Write-Log "Completed: $LocalDC pulled from master $PrimaryDC" 'OK'
    $exit = 0
    $reason = 'ok'
  } else {
    Write-Log "Completed with replication errors. See $script:LogFile" 'ERROR'
    $exit = 1
    $reason = 'repl-errors'
  }
}
catch {
  Write-Log $_.Exception.Message 'ERROR'
  $exit = 1
  $reason = $_.Exception.Message
}
finally {
  Save-Status $exit $reason
  Write-Log "=== Repair-DCLink end exit=$exit ($reason) ==="
}
exit $exit
