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
- **0**: Exit without changes.

Shortcut installation requires a stable, root-owned script location and trusted parent directories. After confirmation it creates `/usr/local/bin/awg-manage` as a symbolic link, not a second copy. Existing different commands are retained. Keep the original script in place.

## Features

- Guided native AmneziaWG installation and custom UDP ports.
- Per-device client profiles, suspension/resumption and UTC account expiry.
- VPC access and split/full-tunnel IPv4 routing.
- Gateway-enforced per-client destination and port permissions.
- Local QR-code export, redacted diagnostics, private backups, restore and scoped removal.

Direct command examples:

```bash
sudo bash ./setup-wireguard.sh --help
sudo bash ./setup-wireguard.sh --manage awg-manage
sudo bash ./setup-wireguard.sh --configure-network awg-manage full --preview
sudo bash ./setup-wireguard.sh --doctor awg-manage
```

## Requirements and important notes

- Ubuntu with root access, systemd and active UFW. Installation offers its package changes for confirmation.
- AmneziaWG 3.1-compatible tools, kernel support and clients. This is not a V2Ray node or a standard WireGuard client profile.
- Distribution is a single `.sh` file, but it contains Python code and requires Python 3. Account expiry creates a private Python helper and systemd units.
- QR export requires an existing `qrencode` command. QR images, generated profiles and backups contain credentials; keep them private.
- Full mode provides IPv4 Internet egress; IPv6 is routed into the tunnel and blocked. It is not dual-stack Internet or a device-wide kill switch. Re-export and re-import client profiles after routing or endpoint changes.
- Cloud firewalls, Nginx and unrelated services remain under your control. Keep separate SSH or console access before network changes.
- A restore changing the tunnel subnet while a legacy VPC policy is active stops before mutation; plan that migration separately.
- Removing this script's forwarding configuration does not force the shared runtime IPv4-forwarding setting off, because another service may need it.

The release artifact passed 279 offline development tests and a Gitleaks scan with no findings. The development tests are not included in this minimal distribution. Real Linux firewall behavior, systemd reboot ordering, QR decoding and client connectivity still require deployment acceptance testing.

## Download statistics

The badge counts downloads of the `setup-wireguard.sh` **Release asset across all releases**. It does not count Git clones, raw source downloads, unique users or successful installations. Checksum-file downloads are excluded. GitHub supplies the count; the script contains no download-tracking telemetry.

Use the [Releases page](https://github.com/Accec/easy-awg/releases) or the Release download links above so downloads appear in this statistic. Badge updates may be cached.
