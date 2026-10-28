# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through [GitHub Security Advisories](https://github.com/AboulEinein/soroband/security/advisories/new). Please do not open a public issue. You will get a reply within 7 days.

## What Soroband accesses

- Per-connection byte counters, process IDs and process names from the kernel's network statistics.
- The current network's name (needs the Location permission on macOS) and the router's hardware address, to tell networks apart.
- A local SQLite database in `~/Library/Application Support/Soroband`.

Soroband does not read packet contents and makes no network requests of its own.
