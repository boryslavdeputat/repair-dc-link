# Repair-DCLink

**Hub-and-spoke Active Directory repair for satellite domain controllers that are often powered off or live on another VLAN.**

When a spare DC boots after days offline, `repadmin /syncall` fails, RPC 1722 lights up toward neighbors that are still off, ICMP is blocked, and Task Scheduler eats `-NoProfile`. This toolkit makes the satellite **pull only from the master (PDC)** and ignore the rest.

[Українською](README.uk.md) · [How to run](docs/HOW-TO.md) · [Troubleshooting](docs/TROUBLESHOOTING.md)

## Who this is for

Small / branch forests where:

- one DC is the PDC / source of truth
- one or more extra DCs are powered off most of the time (lab, branch, power saving)
- those extras may sit on another VLAN or behind a firewall that blocks ICMP
- you want them to catch up **automatically 3 minutes after boot** and hourly after that

## What it does

On a **satellite** DC (not the master):

1. Waits for the master using **nltest or LDAP 389** (ping is optional)
2. Points each NIC at the master’s IP **on the same /24**, plus `127.0.0.1`
3. Syncs time from the domain hierarchy (fallback: master as NTP peer — no invalid `/force`)
4. Repairs the secure channel toward the master
5. `repadmin /replicate Local Master <NC> /force` for domain, configuration, schema, DomainDnsZones, ForestDnsZones
6. Skips extra / foreign naming contexts
7. Treats RPC **1722 / 1908 / 1256** to other satellites as expected
8. Installs SYSTEM tasks via a `.cmd` wrapper (so `schtasks` does not parse `-NoProfile`)

On the **master** the script exits immediately (`skipped-primary`). It never seizes FSMO and never runs metadata cleanup.

## Quick start

On the satellite DC, as Domain Admin:

```bat
powershell -ExecutionPolicy Bypass -File .\scripts\Install-Repair-DCLink.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Repair-DCLink.ps1
```

Success looks like:

```
ExitCode=0
Result=ok
```

and `repadmin /showrepl` on **this** DC shows **Last attempt was successful** next to the master, today.

`dcdiag` may still complain about another satellite. That is fine.

## Layout

```
scripts/Repair-DCLink.ps1           # repair (auto-detects domain + PDC)
scripts/Install-Repair-DCLink.ps1   # copy to C:\Scripts + scheduled tasks
scripts/Repair-DCLink.cmd           # run now (interactive)
scripts/Repair-DCLink-Startup.cmd   # optional GPO / SYSVOL startup
```

Logs: `C:\Logs\Repair-DCLink.log`  
Status: `C:\Logs\Repair-DCLink.status.txt`

## Expected red lines (not a failure)

| Error | When it is OK |
|---|---|
| RPC 1722 | Partner DC powered off or VLAN / firewall |
| 1908 / 1256 | Locator cannot find an offline / other-VLAN partner |
| `dcdiag Replications failed` | Failures are **only** from another satellite |
| `ping=False` | ICMP filtered; nltest/LDAP succeeded |

## What this is not

- Not a replacement for a healthy always-on PDC
- Not for a DC past tombstone lifetime (event **2042** → demote / promote)
- Not `repadmin /syncall` (that often returns **8440** invalid NC)
- Not a license to paste production `showrepl` into public GitHub issues — see [SECURITY.md](SECURITY.md)

## Requirements

Windows Server with AD DS (PowerShell 5.1). Run **on the DC**, locally.

## License

MIT
