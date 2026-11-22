# Quantum readiness (shastaranch, private): UniFi adapter + first real ranch evaluation; monitor secret fix
- Timestamp: 2026-11-21T12:00:00Z
- Author: Kadyapam
- Tags: quantum-readiness, shastaranch, unifi, adapter, qnetmon, security

## Summary

The orchestrator can now evaluate the ranch's UniFi gear: shastaranch/noetl-quantum-readiness#70, open for review and not deployed. It uses three read-only sources:
- the UniFi controller export qnetmon already writes (allow-listed);
- a no-login SSH KEXINIT probe;
- TLS handshakes only.

The first real run covered all 6 devices: QS 15.9%, QTRM 15.4%, coverage 45.8%.
- **SSH:** every server offers hybrid ML-KEM with classical fallback, and every one offers ssh-rsa (SHA-1) host keys.
- **UDM HTTPS:** 443 accepts X25519MLKEM768.
- **Unknowns, never guessed:** UDM SSH (closed port), SNMP, MACsec and the WireGuard peer PSK.
- **CVEs:** no Ubiquiti source, so no CVE numbers.

Separately, shastaranch/qnetmon#46 (open, not deployed) strips plaintext `x_*` secrets from the monitor's raw files at collection, with an end-to-end test. The live checkout still holds old copies until #46 is pulled; rotation is the owner's call.

## Still the owner's

- Review and merge #70 and #46.
- Pull #46 into the live monitor checkout, then run a DuckDB CHECKPOINT or VACUUM.
- Decide on rotating the WireGuard key and the Wi-Fi passphrases.
- Approve before `/quantum/` shows real ranch data.
