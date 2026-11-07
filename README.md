# easy-awg

An easy-to-use script for deploying and managing AWG (AmneziaWG).

[![Release asset downloads](https://img.shields.io/github/downloads/Accec/easy-awg/setup-wireguard.sh?displayAssetName=false&label=downloads)](https://github.com/Accec/easy-awg/releases)

## Download and run

Download the single script and its checksum on your Ubuntu server:

```bash
curl -fL https://github.com/Accec/easy-awg/releases/latest/download/setup-wireguard.sh -o setup-wireguard.sh
curl -fL https://github.com/Accec/easy-awg/releases/latest/download/SHA256SUMS -o SHA256SUMS
sha256sum -c SHA256SUMS
```

Review the script before running it, then open the interactive menu:

```bash
sudo bash ./setup-wireguard.sh
```

The main menu offers:

- **1**: Install a new instance.
- **2**: Select and manage an existing instance.
- **3**: Install the optional `awg-manage` command shortcut.
- **4**: Check for a new Release and update this script.
- **0**: Exit without changes.

Shortcut installation requires a stable, root-owned script location and trusted parent directories. After confirmation it creates `/usr/local/bin/awg-manage` as a symbolic link, not a second copy. Existing different commands are retained. Keep the original script in place.

## Features

- Guided native AmneziaWG installation and custom UDP ports.
- Per-device client profiles, names such as `alice.mac`, suspension/resumption and UTC account expiry.
- Numbered VPC interface, target-scope and SNAT choices, plus split/full-tunnel IPv4 routing.
- Gateway-enforced per-client destination and port permissions.
- Terminal configuration/QR output or private file export, redacted diagnostics, backups, restore and scoped removal.
- Confirmed script updates from stable GitHub Releases, with checksum validation, backups and downgrade protection.

Direct command examples:

```bash
sudo bash ./setup-wireguard.sh --help
sudo bash ./setup-wireguard.sh --manage awg-manage
sudo bash ./setup-wireguard.sh --configure-network awg-manage full --preview
sudo bash ./setup-wireguard.sh --doctor awg-manage
```

## Script updates
Choose main-menu option **4**, or use:
```bash
sudo bash ./setup-wireguard.sh --version
sudo bash ./setup-wireguard.sh --check-update
sudo bash ./setup-wireguard.sh --update
```
The updater uses the latest stable Release from this repository. It validates `SHA256SUMS`, the script version marker and Bash syntax, then requires `APPLY` before replacement. A private old-script backup is retained beside the script; the existing command symlink and permissions are preserved. Run the script again after updating.
Only this script is updated: AWG packages, running services, account profiles, network rules and installed expiry helpers are not replaced. Check-only mode does not download the script asset or change files. Older releases never replace a newer local script; equal versions with different contents stop for manual review. The installed script and parent directories must be root-owned and protected from writes by other accounts. Checksums verify consistency, not an independent publisher signature; updates trust this repository and its HTTPS Release assets.
**Upgrading from `v2026-11-08-1`:** that release has no updater. Download and verify this release using the commands above, then manually replace your saved script once. Keep the same canonical location if using the command shortcut. Future releases can be installed through option **4**.
## Exporting clients
In management option **3** or **15**, leave the destination blank to display the configuration or QR directly in the terminal after `APPLY`. Enter an absolute destination to save a private `.conf` or `.png` file instead. Direct terminal examples:
```bash
sudo bash ./setup-wireguard.sh --export-client awg-manage alice.mac
sudo bash ./setup-wireguard.sh --export-qr awg-manage alice.mac
```
Client names start with an ASCII letter and accept up to 15 letters, digits, dots, underscores or hyphens. Interface naming rules are unchanged. Configuration text and QR codes contain credentials: terminal scrollback, output redirection and session recordings can retain them. Display them only in a trusted session. QR generation stays local and requires `qrencode`.
## Requirements and important notes

- Ubuntu with root access, systemd and active UFW. Installation offers its package changes for confirmation.
- AmneziaWG 3.1-compatible tools, kernel support and clients. This is not a V2Ray node or a standard WireGuard client profile.
- Distribution is a single `.sh` file, but it contains Python code and requires Python 3. Account expiry creates a private Python helper and systemd units.
- QR export requires an existing `qrencode` command. QR images, generated profiles and backups contain credentials; keep them private.
- Full mode provides IPv4 Internet egress; IPv6 is routed into the tunnel and blocked. It is not dual-stack Internet or a device-wide kill switch. Re-export and re-import client profiles after routing or endpoint changes.
- Cloud firewalls, Nginx and unrelated services remain under your control. Keep separate SSH or console access before network changes.
- A restore changing the tunnel subnet while a legacy VPC policy is active stops before mutation; plan that migration separately.
- Removing this script's forwarding configuration does not force the shared runtime IPv4-forwarding setting off, because another service may need it.

The release artifact passed 399 offline development tests and a Gitleaks scan with no findings. The development tests are not included in this minimal distribution. Real Linux firewall behavior, systemd reboot ordering, QR decoding and client connectivity still require deployment acceptance testing.

## Download statistics

The badge counts downloads of the `setup-wireguard.sh` **Release asset across all releases**. It does not count Git clones, raw source downloads, unique users or successful installations. Checksum-file downloads are excluded. GitHub supplies the count; the script contains no download-tracking telemetry.

Use the [Releases page](https://github.com/Accec/easy-awg/releases) or the Release download links above so downloads appear in this statistic. Badge updates may be cached.
