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

On an interactive root Linux terminal, first launch offers script initialization before the main menu. Choose initialization or skip it; changes require `APPLY`.

The main menu offers:

- **1**: Install a new instance.
- **2**: Select and manage an existing instance.
- **3**: Initialize the script installation and `awg-manage` command.
- **4**: Check for a new Release and update this script.
- **0**: Exit without changes.

## Script initialization

Choose main-menu option **3**, accept the first-run offer, or run `sudo bash ./setup-wireguard.sh --initialize`.

Choose an absolute installation directory; the default is `/usr/local/lib/easy-awg`. Review the plan and type `APPLY`. The script creates a root-owned mode-700 directory, installs the single `setup-wireguard.sh` with mode 700, and creates `/usr/local/bin/awg-manage` as a symlink. It verifies copied bytes and Bash syntax and durably writes the installation before removing an original under protected root-owned directories. Originals in user-owned/shared download locations are retained; the plan tells you which behavior applies. Failed installation retains the original and rolls back resources created by that attempt. Unrelated commands and different destination files are retained.

After initialization, run `sudo awg-manage` or `sudo /usr/local/bin/awg-manage`; the old download path is no longer needed. Existing VPN profiles, accounts, keys, services and network policies stay unchanged. Initialization shares the installer/updater lock and releases it before reopening the installed menu. Explicit CLI operations do not initialize automatically.

The previous `--install-command` link-only command remains available. It requires a trusted root-owned source location, adds owner execute permission if needed and links to the existing script without relocation. Keep the source in place when using that legacy command.

## Features

- Confirmed first-run initialization into a private installation directory and a stable `awg-manage` command.
- Read-only AWG health checks with separate PASS/WARN/FAIL/UNKNOWN/SKIP results.
- Guided server-only native AmneziaWG installation with six prompts and custom UDP ports; add named accounts afterward.
- Per-device client profiles, names such as `alice.mac`, suspension/resumption and UTC account expiry.
- Numbered account selection for existing-client operations, with VPN addresses and configured state.
- Numbered VPC interface, target-scope and SNAT choices, plus split/full-tunnel IPv4 routing.
- Gateway-enforced per-client destination and port permissions.
- Optional per-instance dnsmasq with private domain records, upstream forwarding, and client DNS inheritance/restoration.
- Terminal configuration/QR output or private file export, redacted diagnostics, backups, restore and scoped removal.
- Confirmed script updates from stable GitHub Releases, with checksum validation, backups and downgrade protection.

Direct command examples:

```bash
sudo bash ./setup-wireguard.sh --help
sudo bash ./setup-wireguard.sh --manage awg-manage
sudo bash ./setup-wireguard.sh --configure-network awg-manage full --preview
sudo bash ./setup-wireguard.sh --doctor awg-manage
sudo bash ./setup-wireguard.sh --health awg-manage
```

## Server-only installation

New installations create the server with **zero client accounts**. The six prompts
cover public interface, endpoint IPv4, UDP port, AWG interface name, server VPN
CIDR and MTU. No default client key, peer PSK, client profile or server peer is
generated. After installation, select the instance and choose **1: Add client**
to create a named account. Existing accounts, including legacy `initial` profiles,
remain unchanged. VPC routes and DNS policy can be prepared before adding the first
account. Automatic server MTU selection is recorded for later clients.

## Script updates
**One-time upgrade for versions v2026-11-08-2 and v2026-11-08-3:** these versions have a terminal-confirmation bug in shortcut installation and script updates (`File or stream is not seekable`). Version v2026-11-08-4 fixes both prompts. Download and verify the fixed release, then manually replace the saved script once; the affected updater fails at its own confirmation prompt. Keep the same canonical path if using an existing command symlink. Replacing only the script preserves AWG accounts, keys and network settings.

Choose main-menu option **4**, or use:
```bash
sudo bash ./setup-wireguard.sh --version
sudo bash ./setup-wireguard.sh --check-update
sudo bash ./setup-wireguard.sh --update
```
The updater uses the latest stable Release from this repository. It validates `SHA256SUMS`, the script version marker and Bash syntax, then requires `APPLY` before replacement. A private old-script backup is retained beside the script; the existing command symlink and permissions are preserved. Run the script again after updating.
Only this script is updated: AWG packages, running services, account profiles, network rules and installed expiry helpers are not replaced. Check-only mode does not download the script asset or change files. Older releases never replace a newer local script; equal versions with different contents stop for manual review. The installed script and parent directories must be root-owned and protected from writes by other accounts. Checksums verify consistency, not an independent publisher signature; updates trust this repository and its HTTPS Release assets.
**Upgrading from `v2026-11-08-1`:** that release has no updater. Download and verify this release using the commands above, then manually replace your saved script once. Keep the same canonical location if using the command shortcut. Future releases can be installed through option **4**.
## Choosing an existing account
Management options **3**, **4**, **8**, **9**, **10**, **11** and **15** first show a numbered account list: profile export, removal, access permissions, disable/enable, expiry and QR export.

The list includes each saved account's name, VPN IPv4 address and configured state (active, disabled, or expired). Enter its number to continue, or **0** to go back without running the operation. Invalid choices are retried; even one account requires an explicit selection. Empty lists return to the management menu.

Saved disabled accounts, dotted names and the reserved `initial` profile remain selectable. Untracked peers are excluded. State labels describe configuration, not connectivity. Adding a client still asks for a new name; command-line operations still take account names. Existing confirmations and private-export warnings remain in place.

## Exporting clients
In management option **3** or **15**, leave the destination blank to display the configuration or QR directly in the terminal after `APPLY`. Enter an absolute destination to save a private `.conf` or `.png` file instead. Direct terminal examples:
```bash
sudo bash ./setup-wireguard.sh --export-client awg-manage alice.mac
sudo bash ./setup-wireguard.sh --export-qr awg-manage alice.mac
```
Client names start with an ASCII letter and accept up to 15 letters, digits, dots, underscores or hyphens. Interface naming rules are unchanged. Configuration text and QR codes contain credentials: terminal scrollback, output redirection and session recordings can retain them. Display them only in a trusted session. QR generation stays local and requires `qrencode`.
## Private DNS

Choose management option **17: Private DNS (dnsmasq)**, then show settings,
configure private DNS, disable it, or return. The command-line equivalents are:

```bash
sudo bash ./setup-wireguard.sh --show-dns awg-manage
sudo bash ./setup-wireguard.sh --configure-dns awg-manage --preview
sudo bash ./setup-wireguard.sh --configure-dns awg-manage
sudo bash ./setup-wireguard.sh --disable-dns awg-manage --preview
sudo bash ./setup-wireguard.sh --disable-dns awg-manage
```

The wizard accepts named IPv4 records and upstream IPv4 resolver addresses. Invalid records or upstream addresses now show a field-specific error and retry that field without exiting management. Previously valid records are retained. Press Enter to use the displayed defaults; a dash is invalid. Closing terminal input aborts before applying changes. For
example, a private record can map `manage.example.test` to a remote VPC host. The
resolver listens on the selected AWG instance, using its actual server tunnel
address, rather than assuming a particular `10.x.x.x` address. It uses a dedicated
configuration and systemd service; DHCP, query logging, the server's global DNS,
`/etc/hosts`, public DNS records, and unrelated DNS services remain unchanged.
Existing port conflicts are reported rather than stopping another resolver.

**This is centralized tunnel DNS, not client-side split DNS.** Compatible clients
prefer this resolver for system DNS queries while connected; only the configured
private names receive the local override, and other names are forwarded upstream.
Applications with independent DNS/DoH settings may bypass the system resolver.
An unavailable gateway resolver can affect other domain lookups. DNS selection
does not itself turn split traffic routing into a full-tunnel VPN.

Private DNS remains selected when switching between full and split traffic modes.
While it is enabled, the full-mode wizard's resolver setting is retained as the
baseline to restore if private DNS is disabled; change the active resolver's
upstream servers through option **17** instead.

Enabling DNS updates stored client profiles, including disabled accounts, and new
accounts inherit the setting. Re-export and re-import profiles after enabling or
disabling DNS; existing imported profiles do not receive pushed changes. Record
updates alone do not require new profiles when their routes remain valid. A fresh
server with no accounts can save DNS policy before its first named account is added.
Disabling the service restores the saved client DNS settings; remove or replace old
imported profiles at the same time so they do not keep querying a stopped resolver.

DNS records do not create VPC routes or grant access to target services. Configure
VPC access separately with option **6**, and allow the application ports as needed.
Restricted accounts retain their ACLs: explicitly include both UDP and TCP port 53
to the server tunnel IP if they need DNS. A `deny` account remains denied. HTTPS
still needs a certificate matching the browser hostname and trusted by the client;
existing Passkeys require the original RP ID and allowed Origin settings.

## AWG health checks

Choose instance-menu option **18: AWG health check**, or run `sudo awg-manage --health INTERFACE`.

The read-only report checks service and boot state, interface, profile directory permissions, runtime UDP port/socket, peer handshake recency and cumulative transfer counters, saved/runtime consistency, forwarding and route policy, and optional private DNS service/listeners. Independent runtime checks continue even when saved configuration is invalid. No/stale handshakes warn rather than declaring an idle client broken; an empty peer list is skipped. CLI exit status is `1` for any FAIL, otherwise `2` for any UNKNOWN, otherwise `0`. Interactive checks return to the instance menu.

These local checks do not verify effective NAT/ACL/UFW rules, cloud firewalls, client return paths, DNS answers, VPC application access or HTTPS. Full-traffic mode checks default egress rather than a separate VPC route. No configuration, service or firewall changes are made.

### DNS settings permission correction

This release fixes the DNS settings reader treating `/etc/systemd/system` as a private mode-700 directory. Normal trusted shared-directory permissions such as 755 are accepted for that owned unit path; **do not change the system directory to 700**. Private profiles still require mode-700 directories, and owned unit files still require root ownership, mode 600 and no symlink/hard-link aliases. The error was a management-read failure, not proof that running AWG or DNS had stopped.

## Requirements and important notes

- Ubuntu with root access, systemd and active UFW. Installation offers its package changes for confirmation.
- AmneziaWG 3.1-compatible tools, kernel support and clients. This is not a V2Ray node or a standard WireGuard client profile.
- Distribution is a single `.sh` file, but it contains Python code and requires Python 3. Account expiry creates a private Python helper and systemd units.
- Private DNS setup offers `dnsmasq-base` only when needed and confirmed; it retains shared packages on failure or removal. Updating the script alone does not enable DNS or change existing client profiles.
- QR export requires an existing `qrencode` command. QR images, generated profiles and backups contain credentials; keep them private.
- Full mode provides IPv4 Internet egress; IPv6 is routed into the tunnel and blocked. It is not dual-stack Internet or a device-wide kill switch. Re-export and re-import client profiles after routing or endpoint changes.
- Cloud firewalls, Nginx and unrelated services remain under your control. Keep separate SSH or console access before network changes.
- A restore changing the tunnel subnet while a legacy VPC policy is active stops before mutation; plan that migration separately.
- Removing this script's forwarding configuration does not force the shared runtime IPv4-forwarding setting off, because another service may need it.

The release artifact passed 703 offline development tests, including real pseudo-terminal confirmation regressions and a Gitleaks scan with no findings. The development tests are not included in this minimal distribution. Real Linux firewall behavior, systemd reboot ordering, actual dnsmasq resolution, QR decoding and client connectivity still require deployment acceptance testing.

## Download statistics

The badge counts downloads of the `setup-wireguard.sh` **Release asset across all releases**. It does not count Git clones, raw source downloads, unique users or successful installations. Checksum-file downloads are excluded. GitHub supplies the count; the script contains no download-tracking telemetry.

Use the [Releases page](https://github.com/Accec/easy-awg/releases) or the Release download links above so downloads appear in this statistic. Badge updates may be cached.
