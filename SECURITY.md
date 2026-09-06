# Security

This toolkit is meant to run **locally on a domain controller** as SYSTEM or Domain Admin.

## Do not put in issues, PRs, or screenshots

- Domain names, hostnames, IP addresses, VLAN IDs
- Usernames, passwords, hashes, Kerberos tickets
- `repadmin /showrepl` dumps, `dcdiag` full output, `nltest` with real DC names
- Event log exports, `C:\Logs\Repair-DCLink.log` from a production forest

Redact first. Placeholder names (`contoso.com`, `DC1`, `DC2`) are enough to debug.

## What this code does not do

- No credentials are stored
- No remote execution / no WinRM from a workstation into your forest
- No FSMO seize
- No metadata cleanup
- No changes on the master DC (it exits immediately if you run it there)

## If you fork

Keep defaults generic. Do not commit a customized copy that hard-codes your domain, PDC name, or partner list into the public tree.
