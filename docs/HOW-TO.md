# How to run Repair-DCLink

Copy the `scripts` folder onto a USB stick or into SYSVOL. Then log on **to the satellite DC** (the one that was off / on another VLAN) as Domain Admin.

## One-time install

```bat
mkdir C:\Scripts
copy Repair-DCLink.ps1 C:\Scripts\
copy Install-Repair-DCLink.ps1 C:\Scripts\
powershell -ExecutionPolicy Bypass -File C:\Scripts\Install-Repair-DCLink.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Repair-DCLink.ps1
```

If auto-detect fails:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Repair-DCLink.ps1 -DomainFqdn contoso.com -PrimaryDC DC1
```

## Ready-to-paste verify block

Run on the **satellite** DC after the repair:

```bat
type C:\Logs\Repair-DCLink.status.txt
schtasks /Query /TN Repair-DCLink-OnStart
schtasks /Query /TN Repair-DCLink-Hourly
repadmin /showrepl %COMPUTERNAME% | findstr /i "success failed"
```

## How to read the result

| Signal | Meaning |
|---|---|
| `ExitCode=0` and task `Ready` | Satellite pulled from the master. Done. |
| `Last attempt was successful` next to the **master** name, today | Hub path is healthy. |
| `ping=False` while `nltest=True` or `ldap=True` | Normal. ICMP is often blocked. |
| `ExitCode=2` | Master not reachable yet. Hourly task will retry. |
| `ExitCode=3` | Tombstone (event 2042). Demote + promote. Do not force-replicate. |
| `1722` / `1908` / `1256` **only** toward another satellite | Expected if that box is off or on another VLAN. |

## Optional: SYSVOL + GPO startup

1. Copy `Repair-DCLink.ps1` and `Repair-DCLink-Startup.cmd` to `\\<domain>\SYSVOL\<domain>\scripts\`.
2. Link a GPO to **OU=Domain Controllers** with a computer startup script pointing at `Repair-DCLink-Startup.cmd`.
3. The script no-ops on the master (`skipped-primary`).

## Dual-homed / extra NICs

If the satellite has a Hyper-V default switch, Docker NAT, or a leftover NIC, that NIC can register a bogus extra A record. Either:

- uncheck “Register this connection’s addresses in DNS” on the extra NIC, or
- disable the extra NIC on a DC.

Hub repair still works without that cleanup; locator / inbound *from* the satellite to the master may not.
