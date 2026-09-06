# Troubleshooting

## `ERROR: Invalid argument/option - '-NoProfile'`

`schtasks /Create /TR` parsed `-NoProfile` as a schtasks switch.

Fix: `/TR` must be `C:\\Scripts\\Repair-DCLink-Task.cmd`. The `.cmd` file is the one that calls `powershell.exe -NoProfile ...`. Re-run `Install-Repair-DCLink.ps1`.

## Script waits forever / `ping=False`

Do not require ICMP. Master is up if **nltest** finds a DC or **TCP 389** connects. This repo waits on `nltest OR ldap OR ping`.

If you still wait 30 minutes: DNS on that satellite cannot resolve the master FQDN, or LDAP/RPC to the master is filtered.

## `repadmin /syncall /AdePq` = 8440 invalid NC

Do not use `/syncall` as the primary repair. Pull each required NC with:

```
repadmin /replicate <LocalDC> <MasterDC> <NC> /force
```

Skip extra naming contexts that are not domain / configuration / schema / DomainDnsZones / ForestDnsZones.

## `w32tm /resync /rediscover /force` = 0x80070057

On some builds `/force` is invalid. Use `/resync` or `/resync /rediscover` only. The script already does that, then falls back to a manual peer of the master.

## `dcdiag /test:replications` fails but ExitCode=0

If every failure is **From SATELLITE-B to SATELLITE-A** with 1722/1908, that is the hub model. The test that matters is inbound from the **master**.

## Inbound *to the master from the satellite* still 1722

Hub-and-spoke only requires the satellite to **pull from** the master. The master does not need to pull from a box that is often powered off.

If you *do* want the master to find the satellite: fix DNS (A record in the domain zone, `_msdcs` CNAME to that hostname, no extra NAT IPs).

## Event 2042 / tombstone

The DC was offline longer than tombstone lifetime. Stop. Demote (or metadata cleanup if it is gone) and promote a new DC. Force-replicate will linger-object the forest.

## Copy to `C:\\Scripts` throws IOException (same path)

Installer copies onto itself. It now skips that copy. Tasks are created at `\\Repair-DCLink-OnStart` (not a custom folder).
