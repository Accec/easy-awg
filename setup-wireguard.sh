#!/usr/bin/env bash
# AmneziaWG-only setup for the existing Ubuntu server.
set +x
set -Eeuo pipefail
umask 077

EASY_AWG_VERSION=v2026-11-08-7

# Edit these defaults or supply environment variables when invoking the script.
# The wizard shows each default and lets you replace it before installation.
PUBLIC_IP=${PUBLIC_IP:-}
PUBLIC_IF=${PUBLIC_IF:-}
AWG_PORT=${AWG_PORT:-51820}
AWG_IF=${AWG_IF:-awg-manage}
SERVER_ADDRESS=${SERVER_ADDRESS:-10.78.0.1/24}
AWG_MTU=${AWG_MTU:-1280}

WORK='' AWG_FILE='' CLIENT_DIR='' METADATA_FILE=''
CLIENT_DIR_CREATED=0 METADATA_CREATED=0
AWG_ATTEMPTED=0 RULE_ADDED=0 FILES_CREATED=0 SUCCESS=0
UFW_RULE=()
say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }

acquire_lock() {
    python3 - <<'PY_LOCK' || return
import os
import stat
from pathlib import Path

directory = Path('/run/manage-amneziawg')
parent = directory.parent.lstat()
if (directory.parent.resolve() != directory.parent or not stat.S_ISDIR(parent.st_mode)
        or parent.st_uid != 0 or parent.st_mode & 0o022):
    raise SystemExit('The runtime directory must be canonical, root-owned, and not writable by other accounts.')
try:
    directory.mkdir(mode=0o700)
except FileExistsError:
    pass
info = directory.lstat()
if directory.resolve() != directory or not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
    raise SystemExit('The lock directory must be a root-owned mode-700 directory without symlinks.')
fd = os.open(directory / 'setup.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
        raise SystemExit('The lock must be a regular root-owned mode-600 file without hard links.')
finally:
    os.close(fd)
PY_LOCK
    # The validated root-only directory protects this non-truncating reopen.
    exec 9<>/run/manage-amneziawg/setup.lock
    flock -n 9 || die 'Another setup process is running.'
}

prompt_value() {
    local variable=$1 label=$2 default_value=$3 answer
    shift 3
    while true; do
        printf '%s [%s]: ' "$label" "$default_value" >&2
        if ! IFS= read -r answer; then
            say 'Input closed. Setup cancelled.' >&2
            return 1
        fi
        answer=${answer:-$default_value}
        if "$@" "$answer"; then
            printf -v "$variable" '%s' "$answer"
            return 0
        fi
    done
}

validate_public_interface() {
    if [[ ! $1 =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] ||
       ! ip -j -4 address show dev "$1" > "$WORK/addresses.json" 2>/dev/null; then
        say 'Choose an existing network interface from the list.' >&2
        return 1
    fi
    python3 - "$WORK/addresses.json" <<'PY_INTERFACE'
import json, sys
if not any(i.get('addr_info') for i in json.load(open(sys.argv[1]))):
    raise SystemExit('Choose an interface with an assigned IPv4 address.')
PY_INTERFACE
}

validate_port() {
    if [[ ! $1 =~ ^[1-9][0-9]{0,4}$ ]] || (( $1 > 65535 )); then
        say 'Enter a UDP port between 1 and 65535.' >&2
        return 1
    fi
    if [[ -n $(ss -H -lun "sport = :$1") ]] ||
       grep -Eq "(^|[^0-9])$1([^0-9]|$)" "$WORK/ufw-before.txt"; then
        say 'That port is occupied or already mentioned in UFW. Choose another port.' >&2
        return 1
    fi
}

validate_vpn_interface() {
    if [[ ! $1 =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]]; then
        say 'Use 1-15 letters, digits, underscores, or hyphens; start with a letter.' >&2
        return 1
    fi
    if ip link show dev "$1" >/dev/null 2>&1 ||
       systemctl is-active --quiet "awg-quick@$1" 2>/dev/null ||
       systemctl is-enabled --quiet "awg-quick@$1" 2>/dev/null ||
       systemctl is-active --quiet "wg-quick@$1" 2>/dev/null ||
       systemctl is-enabled --quiet "wg-quick@$1" 2>/dev/null ||
       [[ -e /etc/amnezia/amneziawg/$1.conf || -L /etc/amnezia/amneziawg/$1.conf ||
          -e /etc/amnezia/amneziawg/$1-client.conf || -L /etc/amnezia/amneziawg/$1-client.conf ||
           -e /etc/amnezia/amneziawg/clients/$1.conf || -L /etc/amnezia/amneziawg/clients/$1.conf ||
            -e /etc/amnezia/amneziawg/clients/$1 || -L /etc/amnezia/amneziawg/clients/$1 ||
            -e /etc/wireguard/$1.conf || -L /etc/wireguard/$1.conf ]]; then
        say 'That AmneziaWG interface or configuration already exists. Choose a new name.' >&2
        return 1
    fi
}

validate_address() {
    python3 - "$1" "$2" "$PUBLIC_IP" "$WORK" <<'PY_INPUT'
import ipaddress, json, sys
from pathlib import Path
kind, value, public, work = sys.argv[1:]
try:
    address = ipaddress.IPv4Address(value) if kind == 'public' else ipaddress.IPv4Interface(value)
except ValueError:
    raise SystemExit('Enter an IPv4 address, with a CIDR prefix for a VPN address.') from None
if kind == 'public':
    interfaces = json.load(open(Path(work) / 'addresses.json'))
    assigned = [a['local'] for i in interfaces for a in i.get('addr_info', [])]
    if str(address) not in assigned:
        raise SystemExit('Use an IPv4 address assigned to the selected interface.')
elif kind == 'server':
    network = address.network
    if not (network.is_private and network.prefixlen <= 30
            and address.ip not in (network.network_address, network.broadcast_address)
            and ipaddress.IPv4Address(public) not in network):
        raise SystemExit('Use a private VPN host address and subnet, for example 10.78.0.1/24.')
    for route in json.load(open(Path(work) / 'routes.json')):
        destination = route.get('dst', 'default')
        if destination == 'default': continue
        existing = ipaddress.IPv4Network(destination, strict=False)
        if existing.prefixlen and network.overlaps(existing):
            raise SystemExit('VPN subnet overlaps an existing server route: ' + destination)
else:
    raise SystemExit('Unknown address input type.')
PY_INPUT
}

validate_mtu() {
    [[ $1 == auto ]] && return 0
    # This wizard supports a conservative manual range, not the protocol's full range.
    if [[ ! $1 =~ ^[1-9][0-9]{3}$ ]] || (( $1 < 1280 || $1 > 1500 )); then
        say 'Enter auto or a decimal MTU between 1280 and 1500 (no leading zeros).' >&2
        return 1
    fi
}

guide_inputs() {
    say 'AmneziaWG setup wizard: press Enter to keep a displayed default; Ctrl+C cancels.'
    say 'Installation and firewall changes start only after the final APPLY confirmation.'
    say 'Current server IPv4 interfaces (read-only):'
    ip -4 -br address || return
    if [[ -z $PUBLIC_IF ]]; then
        PUBLIC_IF=$(ip -j -4 route show default | python3 -c 'import json,sys; routes=json.load(sys.stdin); best=min((r.get("metric",0) for r in routes),default=None); names={r.get("dev","") for r in routes if r.get("metric",0)==best}; print(next(iter(names)) if len(names)==1 else "")') || return
    fi
    prompt_value PUBLIC_IF '1/6 Public network interface' "$PUBLIC_IF" validate_public_interface || return
    if [[ -z $PUBLIC_IP ]]; then
        PUBLIC_IP=$(python3 - "$WORK/addresses.json" <<'PY_DEFAULT_IP'
import json, sys
values = {a['local'] for entry in json.load(open(sys.argv[1])) for a in entry.get('addr_info', [])
          if a.get('family') == 'inet' and a.get('scope') == 'global'}
print(next(iter(values)) if len(values) == 1 else '')
PY_DEFAULT_IP
) || return
    fi
    prompt_value PUBLIC_IP '2/6 Endpoint IPv4 on that interface' "$PUBLIC_IP" validate_address public || return
    prompt_value AWG_PORT '3/6 AmneziaWG UDP port' "$AWG_PORT" validate_port || return
    prompt_value AWG_IF '4/6 New AmneziaWG interface name' "$AWG_IF" validate_vpn_interface || return
    say 'The VPN addresses below are new tunnel addresses, not existing public or client LAN addresses.'
    prompt_value SERVER_ADDRESS '5/6 Server VPN address to create (CIDR)' "$SERVER_ADDRESS" validate_address server || return
    say 'MTU: auto selects the server tunnel MTU; future clients inherit that value. A number sets the tunnel MTU, not the public interface.'
    prompt_value AWG_MTU '6/6 Tunnel MTU (auto or 1280-1500)' "$AWG_MTU" validate_mtu
}

rollback() {
    if (( AWG_ATTEMPTED )); then
        systemctl disable --now "awg-quick@$AWG_IF" || say 'Review AmneziaWG service state.' >&2
        if ip link show dev "$AWG_IF" >/dev/null 2>&1; then
            say 'AmneziaWG is still present. Its configuration and UDP rule were retained.' >&2
            return
        fi
    fi
    if (( RULE_ADDED )); then
        ufw --force delete "${UFW_RULE[@]}" || say 'Review the newly added AmneziaWG UDP rule.' >&2
    fi
    if (( FILES_CREATED )); then rm -f -- "$AWG_FILE"; fi
    if (( METADATA_CREATED )); then rm -f -- "$METADATA_FILE"; fi
    if (( CLIENT_DIR_CREATED )); then rmdir -- "$CLIENT_DIR" || say "Review the new client directory: $CLIENT_DIR" >&2; fi
}

finish() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if (( rc != 0 && ! SUCCESS )); then rollback; fi
    if [[ -n $WORK ]]; then rm -rf -- "$WORK"; fi
    exit "$rc"
}

write_profiles() {
    local server_private server_public header_key junk_count obfuscation mtu_line=''
    validate_mtu "$AWG_MTU" || return
    if [[ $AWG_MTU != auto ]]; then mtu_line=$'\n'"MTU = $AWG_MTU"; fi
    server_private=$(awg genkey)
    server_public=$(printf '%s\n' "$server_private" | awg pubkey)
    header_key=$(awg genkey)
    junk_count=$(python3 -c 'import secrets; print(4 + secrets.randbelow(3))')
    # Official Amnezia client 3.1 fresh preset; the header-protection key is shared, not a peer identity.
    obfuscation="Jc = $junk_count
Jmin = 10
Jmax = 50
S1 = 12
S2 = 12
S3 = 12
S4 = 12
H1 = 1
H2 = 2
H3 = 3
H4 = 4
HeaderProtectionKey = $header_key
RekeyAfterTime = 100-120
RekeyTimeout = 3-7
RejectAfterTime = 150-180
KeepaliveTimeout = 5-15
MaxHandshakeAttempts = 15-20
RandomTrailers = on
DisableCookies = on"
    cat > "$WORK/server.conf" <<EOF
[Interface]
Address = $SERVER_ADDRESS$mtu_line
ListenPort = $AWG_PORT
PrivateKey = $server_private
$obfuscation
EOF
    printf '%s\n' "$server_public" > "$WORK/server-public.key"
    unset server_private header_key obfuscation
}

check_awg_version() {
    awg --version | python3 -c 'import re,sys; m=re.search(r"\bv?(\d+)\.(\d+)\.(\d+)",sys.stdin.read()); sys.exit(0 if m and tuple(map(int,m.groups()[:2])) >= (3,1) else "AmneziaWG tools 3.1 or newer are required for this configuration.")'
}

ensure_awg_tools() {
    if command -v awg >/dev/null && command -v awg-quick >/dev/null && check_awg_version; then
        return
    fi
    say 'Installing the official Amnezia PPA packages and running-kernel headers. Added packages/repository remain if setup later fails.'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        "linux-headers-$(uname -r)" software-properties-common python3-launchpadlib gnupg2
    add-apt-repository -y ppa:amnezia/ppa
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y amneziawg
    check_awg_version
}

prepare_awg_directories() {
    python3 - "$1" <<'PY_AWG_DIRS'
import os
import stat
import sys
from pathlib import Path

ROOT_UID = 0


def check_directory(path, private=False, create=False):
    path = Path(path)
    if path.resolve() != path:
        raise ValueError('AmneziaWG directories must be canonical and free of symlinks.')
    if not os.path.lexists(path):
        if not create:
            return
        path.mkdir(mode=0o700)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != ROOT_UID or info.st_mode & 0o022:
        raise ValueError('AmneziaWG directories must be root-owned and not writable by other accounts.')
    if private and stat.S_IMODE(info.st_mode) != 0o700:
        if any(path.iterdir()):
            raise ValueError('An existing nonempty private directory needs mode 700; its permissions were retained for manual review.')
        if create:
            # Only an empty, trusted directory is initialized; other deployments keep their permissions.
            os.chmod(path, 0o700)


def main(mode):
    if mode not in ('check', 'create'):
        raise ValueError('Invalid directory preparation mode.')
    for path, private in ((Path('/etc'), False), (Path('/etc/amnezia'), False),
                          (Path('/etc/amnezia/amneziawg'), True),
                          (Path('/etc/amnezia/amneziawg/clients'), True)):
        check_directory(path, private, mode == 'create')


if __name__ == '__main__':
    try:
        main(sys.argv[1])
    except (OSError, ValueError):
        raise SystemExit('AmneziaWG directory validation failed. Use canonical root-owned directories; private nonempty directories require mode 700. Existing permissions were retained.') from None
PY_AWG_DIRS
}

# shellcheck shell=bash
write_server_metadata() {
    ip -j link show dev "$AWG_IF" > "$WORK/tunnel.json"
    python3 - "$PUBLIC_IP" "$AWG_PORT" "$WORK/server-public.key" "$WORK/tunnel.json" > "$WORK/metadata.json" <<'PY_SERVER_METADATA'
import base64, ipaddress, json, sys
from pathlib import Path
public, port, key_file, link_file = sys.argv[1:]
public = str(ipaddress.IPv4Address(public))
port = int(port)
key = Path(key_file).read_text().strip()
try:
    raw = base64.b64decode(key, validate=True)
except ValueError:
    raise SystemExit('Invalid generated server public key.') from None
if len(raw) != 32 or base64.b64encode(raw).decode() != key or not 1 <= port <= 65535:
    raise SystemExit('Invalid generated server metadata.')
links = json.loads(Path(link_file).read_text())
if len(links) != 1 or type(links[0].get('mtu')) is not int or not 576 <= links[0]['mtu'] <= 65535:
    raise SystemExit('Unexpected running tunnel MTU.')
print(json.dumps({'version': 1, 'server_public': key, 'endpoint': public + ':' + str(port),
                  'mtu': links[0]['mtu']}, indent=2))
PY_SERVER_METADATA
    python3 - "$WORK/metadata.json" "$METADATA_FILE" <<'PY_PUBLISH_METADATA'
import os, sys
from pathlib import Path
source, destination = map(Path, sys.argv[1:])
data = source.read_bytes()
owned = None
try:
    with destination.open('xb') as output:
        info = os.fstat(output.fileno())
        owned = (info.st_dev, info.st_ino)
        output.write(data)
        output.flush()
        os.fsync(output.fileno())
except BaseException:
    if owned is not None:
        try:
            current = destination.lstat()
            if (current.st_dev, current.st_ino) == owned:
                destination.unlink()
        except FileNotFoundError:
            pass
    raise
PY_PUBLISH_METADATA
    METADATA_CREATED=1
}

update_psk() {
    python3 - "/etc/amnezia/amneziawg/$1.conf" "$2" "$1" "${3:-}" <<'PY_PSK'
import base64
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def fail(message):
    raise ValueError(message)


def run(*args, data=None):
    result = subprocess.run(args, input=data, text=True, capture_output=True)
    if result.returncode:
        fail('Command failed: ' + ' '.join(args[:3]) + '; no secret output was displayed.')
    return result.stdout.strip()


def key(value):
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        fail('Invalid AmneziaWG key encoding in a profile or runtime response.')
    if len(raw) != 32 or not any(raw) or base64.b64encode(raw).decode() != value:
        fail('Expected a nonzero 32-byte AmneziaWG key.')
    return value


AWG_FIELDS = ('Jc', 'Jmin', 'Jmax', 'S1', 'S2', 'S3', 'S4', 'H1', 'H2', 'H3', 'H4',
              'I1', 'I2', 'I3', 'I4', 'I5', 'HeaderProtectionKey', 'ContentPaddingAddition',
              'RekeyAfterTime', 'RekeyTimeout', 'RejectAfterTime', 'KeepaliveTimeout',
              'MaxHandshakeAttempts', 'RandomTrailers', 'DisableCookies')
AWG_OPTIONAL = {'I1': '', 'I2': '', 'I3': '', 'I4': '', 'I5': '', 'ContentPaddingAddition': '0'}


def number_range(value, maximum=65535):
    value = str(value).lower()
    if value == 'off':
        value = '0'
    match = re.fullmatch(r'([0-9]+)(?:-([0-9]+))?', value)
    if not match:
        fail('Invalid AmneziaWG numeric range.')
    low, high = int(match.group(1)), int(match.group(2) or match.group(1))
    if not 0 <= low <= high <= maximum:
        fail('AmneziaWG numeric range is outside its supported bounds.')
    return str(low) if low == high else str(low) + '-' + str(high)


def boolean(value):
    value = str(value).lower()
    if value in ('on', 'true', 'yes', '1'):
        return 'on'
    if value in ('off', 'false', 'no', '0'):
        return 'off'
    fail('Invalid AmneziaWG boolean field.')


def parameter(name, value):
    if name == 'HeaderProtectionKey':
        return key(value)
    if name in ('RandomTrailers', 'DisableCookies'):
        return boolean(value)
    if name.startswith('I') and name[1:].isdigit():
        value = '' if value == '(null)' else value
        if not isinstance(value, str) or any(not 32 <= ord(char) <= 126 for char in value) or '#' in value:
            fail('Invalid AmneziaWG signature field.')
        return value
    result = number_range(value, 4294967295 if name.startswith('H') else 65535)
    if name in ('Jc', 'Jmin', 'Jmax', 'S1', 'S2', 'S3', 'S4') and '-' in result:
        fail('AmneziaWG packet counts and padding require single numeric values.')
    return result


def parameters_from_fields(fields):
    normalized = {name.casefold(): value for name, value in fields.items()}
    result = {}
    for name in AWG_FIELDS:
        value = normalized.get(name.casefold(), AWG_OPTIONAL.get(name))
        if value is None:
            fail('The saved profile is missing a required AmneziaWG 3.1 parameter.')
        result[name] = parameter(name, value)
    if any(int(result[name]) < 12 for name in ('S1', 'S2', 'S3', 'S4')):
        fail('Header protection requires S1, S2, S3, and S4 of at least 12.')
    if int(result['Jmin']) > int(result['Jmax']):
        fail('AmneziaWG Jmin exceeds Jmax.')
    return result


def parameters_from_dump(row):
    if len(row) != 29:
        fail('Expected the AmneziaWG 3.1 29-field device dump; other formats were retained without changes.')
    return parameters_from_fields(dict(zip(AWG_FIELDS, row[3:28])))


def live_parameters(interface):
    output = run('awg', 'show', interface, 'dump').splitlines()
    if not output:
        fail('Missing AmneziaWG runtime state.')
    return parameters_from_dump(output[0].split('\t'))


def peer_security(text):
    result, current = {}, None
    for line in text.splitlines():
        body = line.split('#', 1)[0].strip()
        if body.startswith('['):
            if current is not None:
                public = key(current.get('publickey'))
                if public in result:
                    fail('Duplicate AmneziaWG runtime peer.')
                result[public] = boolean(current.get('advancedsecurity', 'off'))
            current = {} if body.lower() == '[peer]' else None
        elif current is not None and '=' in body:
            name, value = map(str.strip, body.split('=', 1))
            current[name.lower()] = value
    if current is not None:
        public = key(current.get('publickey'))
        if public in result:
            fail('Duplicate AmneziaWG runtime peer.')
        result[public] = boolean(current.get('advancedsecurity', 'off'))
    return result


def read_profile(path):
    if not path.is_absolute() or path.resolve() != path or not str(path).isprintable():
        fail('Configuration paths must be absolute, canonical, and free of symlinks.')
    parent = path.parent.stat()
    if parent.st_uid != os.geteuid() or parent.st_mode & 0o022:
        fail('Configuration directories must be owned by the executing user and not group/world writable.')
    if not stat.S_ISREG(path.lstat().st_mode):
        fail('Configuration paths must name regular files.')
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'r', newline='') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            fail('Configuration files must be regular, privately permissioned files owned by the executing user.')
        return stream.read(), info


def parse(text):
    lines, blocks, current = text.splitlines(keepends=True), [], None
    singleton = {'PrivateKey', 'PublicKey', 'PresharedKey', 'SaveConfig', 'ListenPort', 'Endpoint', 'AdvancedSecurity'} | set(AWG_FIELDS)
    canonical = {name.casefold(): name for name in singleton}
    for number, line in enumerate(lines):
        body = line.split('#', 1)[0].strip()
        if not body:
            continue
        if body.casefold() in ('[interface]', '[peer]'):
            current = {'kind': body[1:-1].capitalize(), 'fields': {}, 'indexes': {}}
            blocks.append(current)
        elif current is None or '=' not in body:
            fail('Malformed AmneziaWG configuration; no changes made.')
        else:
            name, value = map(str.strip, body.split('=', 1))
            name = canonical.get(name.casefold(), name)
            if name in singleton and name in current['fields']:
                fail('Duplicate security-sensitive field: ' + name)
            current['fields'][name] = value
            current['indexes'][name] = number
    interfaces = [block for block in blocks if block['kind'] == 'Interface']
    peers = [block for block in blocks if block['kind'] == 'Peer']
    if len(interfaces) != 1 or not peers:
        fail('Expected one Interface section and at least one Peer section.')
    if interfaces[0]['fields'].get('SaveConfig', '').lower() == 'true':
        fail('SaveConfig=true needs manual review before a persistent PSK update.')
    return lines, interfaces[0], peers


def add_psk(lines, block, psk):
    if 'PresharedKey' in block['fields']:
        return ''.join(lines)
    result = list(lines)
    index = block['indexes']['PublicKey']
    newline = '\r\n' if result[index].endswith('\r\n') else '\n'
    result[index] = result[index].rstrip('\r\n') + newline + 'PresharedKey = ' + psk + newline
    return ''.join(result)


def atomic_write(path, text, mode=0o600):
    fd, temporary = tempfile.mkstemp(prefix='.awg-psk-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def mapping(output):
    result = {}
    for line in output.splitlines():
        pair = line.split()
        if len(pair) != 2 or pair[0] in result:
            fail('Unexpected AmneziaWG runtime response.')
        result[pair[0]] = pair[1]
    return result


def interrupt(signum, frame):
    raise InterruptedError('Update interrupted.')


def main():
    server, client, interface, mode = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,14}', interface) or mode not in ('', '--check'):
        fail('Invalid interface name or operation.')
    original_server, server_info = read_profile(server)
    original_client, client_info = read_profile(client)
    if (server_info.st_dev, server_info.st_ino) == (client_info.st_dev, client_info.st_ino):
        fail('Server and client profiles must be different files.')
    server_lines, server_interface, server_peers = parse(original_server)
    client_lines, client_interface, client_peers = parse(original_client)
    server_parameters = parameters_from_fields(server_interface['fields'])
    if parameters_from_fields(client_interface['fields']) != server_parameters:
        fail('Server and client AmneziaWG parameters differ; no secrets were displayed.')
    if len(client_peers) != 1:
        fail('Select a client profile containing exactly one server Peer.')
    server_public = key(run('awg', 'pubkey', data=key(server_interface['fields'].get('PrivateKey')) + '\n'))
    client_public = key(run('awg', 'pubkey', data=key(client_interface['fields'].get('PrivateKey')) + '\n'))
    for peer in server_peers + client_peers:
        key(peer['fields'].get('PublicKey'))
        if 'PresharedKey' in peer['fields']:
            key(peer['fields']['PresharedKey'])
    matches = [peer for peer in server_peers if peer['fields']['PublicKey'] == client_public]
    if len(matches) != 1 or client_peers[0]['fields']['PublicKey'] != server_public:
        fail('Server/client public-key pairing differs; select the original matching client profile.')
    server_peer, client_peer = matches[0], client_peers[0]
    endpoint = client_peer['fields'].get('Endpoint', '')
    if any(not 33 <= ord(char) <= 126 for char in endpoint):
        fail('Endpoint contains whitespace or non-ASCII control/display characters.')
    server_psk = server_peer['fields'].get('PresharedKey')
    client_psk = client_peer['fields'].get('PresharedKey')
    if server_psk and client_psk and server_psk != client_psk:
        fail('Server and client PSKs differ. No rotation or overwrite was performed.')

    active = interface in run('awg', 'show', 'interfaces').split()
    live_psk = None
    problems = []
    if active:
        if live_parameters(interface) != server_parameters:
            fail('Saved and running AmneziaWG parameters differ; no secrets were displayed.')
        if key(run('awg', 'show', interface, 'public-key')) != server_public:
            fail('Running server public key differs from its saved configuration.')
        if client_public not in run('awg', 'show', interface, 'peers').split():
            fail('Target client peer is absent from the running interface.')
        runtime = mapping(run('awg', 'show', interface, 'preshared-keys'))
        if client_public not in runtime:
            fail('Target client PSK state is absent from the runtime response.')
        live_psk = None if runtime[client_public] == '(none)' else key(runtime[client_public])
        if live_psk != server_psk:
            fail('Saved server PSK differs from the running peer PSK; reconcile that state before updating.')
        live_port = run('awg', 'show', interface, 'listen-port')
        if not live_port.isdecimal() or not 1 <= int(live_port) <= 65535:
            fail('Unexpected runtime listen port.')
        endpoint = client_peer['fields'].get('Endpoint', '')
        endpoint_port = endpoint.rsplit(':', 1)[-1]
        if endpoint_port != live_port:
            problems.append('Client Endpoint port differs from the runtime listen port.')
        saved_port = server_interface['fields'].get('ListenPort')
        if saved_port and saved_port != '0' and saved_port != live_port:
            problems.append('Saved ListenPort differs from the runtime listen port.')
        handshakes = mapping(run('awg', 'show', interface, 'latest-handshakes'))
        timestamp = handshakes.get(client_public)
        if timestamp is None or not timestamp.isdecimal():
            fail('Unexpected handshake timestamp.')
        print('Running interface: ' + interface + '; listen port: ' + live_port)
        print('Latest handshake: ' + (str(max(0, int(time.time()) - int(timestamp))) + ' seconds ago'
              if int(timestamp) else 'none; end-to-end connectivity remains unverified.'))
    else:
        result = subprocess.run(['ip', 'link', 'show', 'dev', interface], capture_output=True)
        if result.returncode == 0:
            fail('That interface exists but is not a running AmneziaWG interface.')
        print('Interface inactive; only saved profiles are available for inspection.')
    endpoint = client_peer['fields'].get('Endpoint', '(not configured)')
    print('Client endpoint: ' + endpoint)
    print('Profile public-key pairing: matched.')
    print('Saved PSK: ' + ('matched and enabled.' if server_psk and client_psk
          else 'present on one side only.' if server_psk or client_psk else 'not enabled.'))
    if active:
        print('Server disk/runtime PSK state: matched.')
    if mode == '--check':
        print('Server public key: ' + server_public)
        print('Client public key: ' + client_public)
        if bool(server_psk) != bool(client_psk):
            problems.append('One side has a PSK and the other side does not.')
        for problem in problems:
            print('ERROR: ' + problem, file=sys.stderr)
        print('Checks cover the saved client file, not the profile currently active on your computer.')
        return 1 if problems else 0
    if problems:
        fail(' '.join(problems) + ' Fix the connection settings before changing its PSK.')
    if server_psk and client_psk:
        print('PSK already enabled and matched; no files or runtime settings changed.')
        return 0
    print('This adds one shared PSK without changing existing keys, addresses, ports, or other peers.')
    print('The selected client connection will pause until its updated profile is imported. Keep a separate SSH/console session.')
    with open('/dev/tty', 'r') as tty:
        print('Type APPLY to update this peer: ', end='', flush=True)
        if tty.readline().strip() != 'APPLY':
            fail('Update cancelled; no configuration changes made.')

    psk = server_psk or client_psk or key(run('awg', 'genpsk'))
    updated_server = add_psk(server_lines, server_peer, psk)
    updated_client = add_psk(client_lines, client_peer, psk)
    if read_profile(server)[0] != original_server or read_profile(client)[0] != original_client:
        fail('A profile changed during confirmation; rerun after reviewing the change.')
    if (interface in run('awg', 'show', 'interfaces').split()) != active:
        fail('Interface activation changed during confirmation; no configuration changes made.')
    if active:
        unchanged = (
            run('awg', 'show', interface, 'public-key') == server_public
            and client_public in run('awg', 'show', interface, 'peers').split()
            and mapping(run('awg', 'show', interface, 'preshared-keys')).get(client_public) == (live_psk or '(none)')
            and run('awg', 'show', interface, 'listen-port') == live_port
            and live_parameters(interface) == server_parameters
        )
        if not unchanged:
            fail('Runtime keys, target peer, or listen port changed during confirmation; no configuration changes made.')
    elif subprocess.run(['ip', 'link', 'show', 'dev', interface], capture_output=True).returncode == 0:
        fail('An interface appeared during confirmation; no configuration changes made.')
    backup = Path(tempfile.mkdtemp(prefix=interface + '-psk-backup-', dir=server.parent))
    os.chmod(backup, 0o700)
    atomic_write(backup / 'server.conf', original_server)
    atomic_write(backup / 'client.conf', original_client)
    touched = runtime_attempted = False
    with tempfile.TemporaryDirectory(prefix='.awg-psk-stage-', dir=server.parent) as staging:
        stage = Path(staging)
        atomic_write(stage / 'new.psk', psk + '\n')
        atomic_write(stage / 'previous.psk', live_psk + '\n' if live_psk else '')
        try:
            touched = True
            atomic_write(server, updated_server)
            atomic_write(client, updated_client)
            if active:
                runtime_attempted = True
                run('awg', 'set', interface, 'peer', client_public, 'preshared-key', str(stage / 'new.psk'))
                applied = mapping(run('awg', 'show', interface, 'preshared-keys'))
                if applied.get(client_public) != psk:
                    fail('Runtime PSK verification failed.')
                if live_parameters(interface) != server_parameters:
                    fail('Runtime AmneziaWG parameter verification failed.')
        except BaseException:
            # The old runtime PSK can differ from the client's one-sided saved value.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            errors = []
            if touched:
                for path, text, info in ((server, original_server, server_info), (client, original_client, client_info)):
                    try:
                        atomic_write(path, text, stat.S_IMODE(info.st_mode))
                    except BaseException:
                        errors.append('saved profile restore')
            if runtime_attempted:
                try:
                    run('awg', 'set', interface, 'peer', client_public, 'preshared-key', str(stage / 'previous.psk'))
                    restored = mapping(run('awg', 'show', interface, 'preshared-keys')).get(client_public)
                    if restored != (live_psk or '(none)'):
                        fail('Runtime restore verification failed.')
                except BaseException:
                    errors.append('runtime PSK restore')
            print('Private backups: ' + str(backup), file=sys.stderr)
            if errors:
                fail('Update failed; rollback needs manual review: ' + ', '.join(errors))
            fail('Update failed; saved profiles and previous runtime PSK were restored.')
    print('PSK enabled. Private backups: ' + str(backup))
    print('Updated client profile: ' + str(client) + ' (secret; transfer securely and replace the old client profile).')
    if not active:
        print('Runtime was not started. Activate the intended saved interface separately.')
    print('A successful client handshake still needs verification after importing the updated profile.')
    return 0


signal.signal(signal.SIGTERM, interrupt)
signal.signal(signal.SIGINT, interrupt)
try:
    sys.exit(main())
except (ValueError, OSError, InterruptedError) as error:
    if isinstance(error, OSError):
        print('ERROR: File or command operation failed; verify paths, ownership, and available commands.', file=sys.stderr)
    else:
        print('ERROR: ' + str(error), file=sys.stderr)
    sys.exit(1)
PY_PSK
}

manage_clients() (
    # A private runtime source lets the expiry timer install this same standalone module.
    local manager_dir
    manager_dir=$(mktemp -d /run/manage-awg-module.XXXXXXXX) || return
    trap 'rm -f -- "$manager_dir/manager.py"; rmdir -- "$manager_dir"' EXIT
    cat > "$manager_dir/manager.py" <<'PY_MANAGER'
import base64
import datetime
import fcntl
import ipaddress
import json
import os
import re
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def fail(message):
    raise ValueError(message)


def valid_name(value):
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,14}', value):
        fail('Use 1-15 letters, digits, underscores, or hyphens, starting with a letter.')
    return value


CLIENT_NAME_PATTERN = r'[A-Za-z][A-Za-z0-9_.-]{0,14}'


def valid_client_name(value):
    if not isinstance(value, str) or not re.fullmatch(CLIENT_NAME_PATTERN, value):
        fail('Use 1-15 letters, digits, underscores, hyphens, or dots, starting with a letter.')
    return value


def valid_port(value):
    value = str(value)
    if not re.fullmatch(r'[1-9][0-9]{0,4}', value) or int(value) > 65535:
        fail('UDP port must be a decimal number between 1 and 65535.')
    return int(value)


def key(value):
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        fail('Invalid AmneziaWG key encoding.')
    if len(raw) != 32 or not any(raw) or base64.b64encode(raw).decode() != value:
        fail('Expected a nonzero 32-byte AmneziaWG key.')
    return value


def run(*args, data=None):
    result = subprocess.run(args, input=data, text=True, capture_output=True,
                            env={**os.environ, 'LC_ALL': 'C'}, timeout=30)
    if result.returncode:
        fail('Command failed: ' + ' '.join(args[:3]) + '; secret output was suppressed.')
    return result.stdout.strip()


def prompt(message):
    with open('/dev/tty', 'r') as tty:
        print(message, end='', flush=True)
        answer = tty.readline()
    if not answer:
        fail('Input closed; operation cancelled.')
    return answer.strip()


def confirm(message):
    print(message)
    if prompt('Type APPLY to continue: ') != 'APPLY':
        fail('Operation cancelled; no configuration changes made.')


def secure_path(path, private_parent=False):
    path = Path(path)
    if not path.is_absolute() or path.resolve() != path or not str(path).isprintable():
        fail('Paths must be absolute, canonical, printable, and free of symlinks.')
    for parent in reversed(path.parents):
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.geteuid()):
            fail('Every parent directory must have trusted ownership.')
        # A root-owned sticky ancestor such as /tmp still protects a private child.
        if info.st_mode & 0o022 and not (info.st_uid == 0 and info.st_mode & stat.S_ISVTX):
            fail('A parent directory is writable by another account.')
    if private_parent:
        info = path.parent.stat()
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
            fail('The profile directory must be owned by root with mode 700.')
    return path


AWG_FIELDS = ('Jc', 'Jmin', 'Jmax', 'S1', 'S2', 'S3', 'S4', 'H1', 'H2', 'H3', 'H4',
              'I1', 'I2', 'I3', 'I4', 'I5', 'HeaderProtectionKey', 'ContentPaddingAddition',
              'RekeyAfterTime', 'RekeyTimeout', 'RejectAfterTime', 'KeepaliveTimeout',
              'MaxHandshakeAttempts', 'RandomTrailers', 'DisableCookies')
AWG_OPTIONAL = {'I1': '', 'I2': '', 'I3': '', 'I4': '', 'I5': '', 'ContentPaddingAddition': '0'}


def number_range(value, maximum=65535):
    value = str(value).lower()
    if value == 'off':
        value = '0'
    match = re.fullmatch(r'([0-9]+)(?:-([0-9]+))?', value)
    if not match:
        fail('Invalid AmneziaWG numeric range.')
    low, high = int(match.group(1)), int(match.group(2) or match.group(1))
    if not 0 <= low <= high <= maximum:
        fail('AmneziaWG numeric range is outside its supported bounds.')
    return str(low) if low == high else str(low) + '-' + str(high)


def boolean(value):
    value = str(value).lower()
    if value in ('on', 'true', 'yes', '1'):
        return 'on'
    if value in ('off', 'false', 'no', '0'):
        return 'off'
    fail('Invalid AmneziaWG boolean field.')


def parameter(name, value):
    if name == 'HeaderProtectionKey':
        return key(value)
    if name in ('RandomTrailers', 'DisableCookies'):
        return boolean(value)
    if name.startswith('I') and name[1:].isdigit():
        value = '' if value == '(null)' else value
        if not isinstance(value, str) or any(not 32 <= ord(char) <= 126 for char in value) or '#' in value:
            fail('Invalid AmneziaWG signature field.')
        return value
    result = number_range(value, 4294967295 if name.startswith('H') else 65535)
    if name in ('Jc', 'Jmin', 'Jmax', 'S1', 'S2', 'S3', 'S4') and '-' in result:
        fail('AmneziaWG packet counts and padding require single numeric values.')
    return result


def parameters_from_fields(fields):
    normalized = {name.casefold(): value for name, value in fields.items()}
    result = {}
    for name in AWG_FIELDS:
        value = normalized.get(name.casefold(), AWG_OPTIONAL.get(name))
        if value is None:
            fail('The saved profile is missing a required AmneziaWG 3.1 parameter.')
        result[name] = parameter(name, value)
    if any(int(result[name]) < 12 for name in ('S1', 'S2', 'S3', 'S4')):
        fail('Header protection requires S1, S2, S3, and S4 of at least 12.')
    if int(result['Jmin']) > int(result['Jmax']):
        fail('AmneziaWG Jmin exceeds Jmax.')
    return result


def parameters_from_dump(row):
    if len(row) != 29:
        fail('Expected the AmneziaWG 3.1 29-field device dump; other formats were retained without changes.')
    return parameters_from_fields(dict(zip(AWG_FIELDS, row[3:28])))


def live_parameters(interface):
    output = run('awg', 'show', interface, 'dump').splitlines()
    if not output:
        fail('Missing AmneziaWG runtime state.')
    return parameters_from_dump(output[0].split('\t'))


def peer_security(text):
    result, current = {}, None
    for line in text.splitlines():
        body = line.split('#', 1)[0].strip()
        if body.startswith('['):
            if current is not None:
                public = key(current.get('publickey'))
                if public in result:
                    fail('Duplicate AmneziaWG runtime peer.')
                result[public] = boolean(current.get('advancedsecurity', 'off'))
            current = {} if body.lower() == '[peer]' else None
        elif current is not None and '=' in body:
            name, value = map(str.strip, body.split('=', 1))
            current[name.lower()] = value
    if current is not None:
        public = key(current.get('publickey'))
        if public in result:
            fail('Duplicate AmneziaWG runtime peer.')
        result[public] = boolean(current.get('advancedsecurity', 'off'))
    return result


def read_profile(path, *, private_parent=True):
    path = secure_path(path, private_parent=private_parent)
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'r', newline='') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            fail('Profiles must be regular root-owned mode-600 files without hard links.')
        return stream.read()


def exists(path):
    return os.path.lexists(path)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write(path, text, expected=None):
    path = secure_path(path, private_parent=True)
    if expected is None:
        if exists(path):
            fail('Destination already exists; no overwrite was performed.')
    elif read_profile(path) != expected:
        fail('A profile changed outside this operation; no overwrite was performed.')
    fd, temporary = tempfile.mkstemp(prefix='.awg-manager-', dir=path.parent)
    identity = None
    try:
        with os.fdopen(fd, 'w', newline='') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        if expected is None:
            # link() is an atomic no-replace publication, including dangling symlinks.
            identity = (os.stat(temporary).st_dev, os.stat(temporary).st_ino)
            os.link(temporary, path, follow_symlinks=False)
            os.unlink(temporary)
        else:
            if read_profile(path) != expected:
                fail('A profile changed while staging its replacement.')
            os.replace(temporary, path)
        sync_directory(path.parent)
    except BaseException:
        if expected is None and exists(path) and identity == (path.lstat().st_dev, path.lstat().st_ino):
            os.unlink(path)
        raise
    finally:
        if exists(temporary):
            os.unlink(temporary)


def unlink_profile(path, expected):
    if read_profile(path) != expected:
        fail('A profile changed outside this operation; it was retained.')
    os.unlink(path)
    sync_directory(path.parent)


def parse_config(text):
    lines, blocks, current = text.splitlines(keepends=True), [], None
    known = ('Address PrivateKey PublicKey PresharedKey ListenPort Endpoint AllowedIPs '
             'PersistentKeepalive MTU SaveConfig FwMark AdvancedSecurity').split() + list(AWG_FIELDS)
    canonical = {name.lower(): name for name in known}
    repeated = {'Address', 'AllowedIPs', 'PreUp', 'PostUp', 'PreDown', 'PostDown', 'DNS'}
    for index, line in enumerate(lines):
        body = line.split('#', 1)[0].strip()
        if not body:
            continue
        if body.lower() in ('[interface]', '[peer]'):
            if current is not None:
                current['end'] = index
            current = {'kind': body[1:-1].capitalize(), 'start': index, 'end': len(lines),
                       'fields': {}, 'indexes': {}}
            blocks.append(current)
            continue
        if current is None or '=' not in body:
            fail('Malformed AmneziaWG configuration.')
        name, value = map(str.strip, body.split('=', 1))
        name = canonical.get(name.lower(), name)
        if name in current['fields'] and name not in repeated:
            fail('Duplicate configuration field; review the profile before managing it.')
        current['fields'].setdefault(name, []).append(value)
        current['indexes'].setdefault(name, []).append(index)
    interfaces = [block for block in blocks if block['kind'] == 'Interface']
    if len(interfaces) != 1 or not blocks or blocks[0] is not interfaces[0]:
        fail('Expected exactly one leading Interface section.')
    return {'text': text, 'lines': lines, 'interface': interfaces[0],
            'peers': [block for block in blocks if block['kind'] == 'Peer']}


def field(block, name, default=''):
    values = block['fields'].get(name, [default])
    if len(values) != 1:
        fail('A singleton configuration field is ambiguous.')
    return values[0]


def addresses(block, name, interface=False):
    parser = ipaddress.ip_interface if interface else lambda value: ipaddress.ip_network(value, strict=False)
    try:
        return [parser(part.strip()) for value in block['fields'].get(name, [])
                for part in value.split(',') if part.strip()]
    except ValueError:
        fail('Malformed address or prefix in a profile.')


def replace_field(text, block, name, value):
    lines = text.splitlines(keepends=True)
    indexes = block['indexes'].get(name, [])
    if len(indexes) > 1:
        fail('Field replacement is ambiguous.')
    if indexes:
        index = indexes[0]
        newline = '\r\n' if lines[index].endswith('\r\n') else '\n'
        comment = ' #' + lines[index].split('#', 1)[1].rstrip('\r\n') if '#' in lines[index] else ''
        lines[index] = name + ' = ' + value + comment + newline
    else:
        index = block['start']
        newline = '\r\n' if lines[index].endswith('\r\n') else '\n'
        lines[index] = lines[index].rstrip('\r\n') + newline + name + ' = ' + value + newline
    return ''.join(lines)


def endpoint_parts(value):
    if not value or any(not 33 <= ord(char) <= 126 for char in value):
        fail('Expected a printable Endpoint without whitespace.')
    if value.startswith('['):
        match = re.fullmatch(r'\[([^\]]+)\]:([0-9]+)', value)
        if not match:
            fail('Malformed bracketed Endpoint.')
        try:
            ipaddress.IPv6Address(match.group(1))
        except ValueError:
            fail('Malformed IPv6 Endpoint.')
        host, port = '[' + match.group(1) + ']', match.group(2)
    else:
        match = re.fullmatch(r'([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?):([0-9]+)', value)
        if not match:
            fail('Expected an IPv4 address or hostname and UDP port.')
        host, port = match.groups()
    return host, valid_port(port)


def allocate_address(server_interface, occupied_networks, local_addresses=()):
    server = ipaddress.IPv4Interface(server_interface)
    network = server.network
    if network.prefixlen > 30 or server.ip in (network.network_address, network.broadcast_address):
        fail('A usable server IPv4 subnet with spare host addresses is required.')
    first, last = int(network.network_address) + 1, int(network.broadcast_address) - 1
    intervals = [(int(server.ip), int(server.ip))]
    for value in occupied_networks:
        other = ipaddress.ip_network(value, strict=False)
        if other.version == 4 and network.overlaps(other):
            intervals.append((max(first, int(other.network_address)), min(last, int(other.broadcast_address))))
    for value in local_addresses:
        address = ipaddress.ip_address(value)
        if address.version == 4 and address in network:
            intervals.append((int(address), int(address)))
    candidate = first
    for start, end in sorted(intervals):
        if start <= candidate <= end:
            candidate = end + 1
    if candidate > last:
        fail('The server IPv4 subnet has no unused client address.')
    return str(ipaddress.IPv4Address(candidate)) + '/32'


def runtime_state(interface):
    if interface not in run('awg', 'show', 'interfaces').split():
        return None
    rows = [line.split('\t') for line in run('awg', 'show', interface, 'dump').splitlines()]
    if not rows or len(rows[0]) != 29:
        fail('Unexpected AmneziaWG runtime response.')
    state = {'public': key(rows[0][1]), 'port': valid_port(rows[0][2]),
             'obfuscation': parameters_from_dump(rows[0]), 'fwmark': rows[0][28], 'peers': {}}
    security = peer_security(run('awg', 'showconf', interface))
    for row in rows[1:]:
        if len(row) != 8:
            fail('Unexpected AmneziaWG peer response.')
        public, psk, endpoint, allowed, handshake, received, sent, keepalive = row
        key(public)
        if public in state['peers'] or not all(value.isdecimal() for value in (handshake, received, sent)):
            fail('Unexpected duplicate peer or runtime counters.')
        keepalive = number_range(keepalive)
        if endpoint != '(none)':
            endpoint_parts(endpoint)
        try:
            networks = [] if allowed == '(none)' else [str(ipaddress.ip_network(v, strict=False)) for v in allowed.split(',')]
        except ValueError:
            fail('Unexpected runtime AllowedIPs.')
        state['peers'][public] = {'psk': None if psk == '(none)' else key(psk),
                                 'endpoint': None if endpoint == '(none)' else endpoint,
                                 'allowed': sorted(networks), 'keepalive': keepalive,
                                 'advanced_security': security.get(public),
                                 'handshake': int(handshake)}
    if set(security) != set(state['peers']):
        fail('AmneziaWG peers changed between runtime snapshots; rerun the check.')
    return state


def stable_runtime(state):
    if state is None:
        return None
    # AWG 3.1's kernel ignores the legacy AdvancedSecurity setter and reports off; preserve it for rollback only.
    # Learned endpoints and counters may change while a client is connected.
    return {**{k: state[k] for k in ('public', 'port', 'fwmark', 'obfuscation')},
            'peers': {public: {k: peer[k] for k in ('psk', 'allowed', 'keepalive')}
                      for public, peer in state['peers'].items()}}


def stable_local(entries):
    return sorted((entry.get('ifname'), entry.get('mtu'),
                   sorted((info.get('local'), info.get('prefixlen')) for info in entry.get('addr_info', [])))
                  for entry in entries)


def set_peer(interface, public, peer):
    args = ['awg', 'set', interface, 'peer', public,
            'allowed-ips', ','.join(peer['allowed']), 'persistent-keepalive', str(peer['keepalive'])]
    if peer.get('advanced_security') is not None:
        args += ['advanced-security', peer['advanced_security']]
    if peer['psk']:
        args += ['preshared-key', '/dev/stdin']
    if peer.get('endpoint'):
        args += ['endpoint', peer['endpoint']]
    run(*args, data=(peer['psk'] + '\n') if peer['psk'] else '')


def ufw_has_rule(output, rule):
    expected = {name: rule[rule.index(name) + 1] for name in ('on', 'proto', 'to', 'port', 'comment')}
    for line in output.splitlines():
        try:
            tokens = shlex.split(line)
        except ValueError:
            continue
        if tokens[:2] != ['ufw', 'allow'] or 'in' not in tokens:
            continue
        if all(name in tokens and tokens.index(name) + 1 < len(tokens)
               and tokens[tokens.index(name) + 1] == value for name, value in expected.items()):
            return True
    return False


def lifecycle_expiry(value):
    if value is None or value == 'none':
        return None
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', value):
        fail('Use UTC YYYY-MM-DDTHH:MM:SSZ or none for expiry.')
    datetime.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ')
    return value


def lifecycle_expired(value, now=None):
    stamp = datetime.datetime.strptime(lifecycle_expiry(value), '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
    return stamp <= (time.time() if now is None else now)


def lifecycle_peer(text):
    if not isinstance(text, str) or len(text) > 16384:
        fail('Invalid saved disabled-peer record.')
    parsed = parse_config('[Interface]\n' + text)
    if len(parsed['peers']) != 1 or parsed['interface']['fields']:
        fail('Expected one saved disabled Peer section.')
    block = parsed['peers'][0]
    if set(block['fields']) - {'PublicKey', 'PresharedKey', 'AllowedIPs', 'PersistentKeepalive', 'Endpoint', 'AdvancedSecurity'}:
        fail('Unexpected disabled-peer fields; review before account changes.')
    public = key(field(block, 'PublicKey'))
    psk = key(field(block, 'PresharedKey')) if field(block, 'PresharedKey') else None
    allowed = sorted(str(n) for n in addresses(block, 'AllowedIPs'))
    if not allowed or any(ipaddress.ip_network(n).prefixlen != ipaddress.ip_network(n).max_prefixlen for n in allowed):
        fail('Managed accounts require individual host AllowedIPs.')
    endpoint = field(block, 'Endpoint') or None
    if endpoint:
        endpoint_parts(endpoint)
    return {'public': public, 'block': block, 'psk': psk, 'allowed': allowed,
            'keepalive': number_range(field(block, 'PersistentKeepalive', '0')),
            'endpoint': endpoint, 'advanced_security': boolean(field(block, 'AdvancedSecurity', 'off'))}


def lifecycle_accounts(text, public):
    data = json.loads(text)
    if (not isinstance(data, dict) or set(data) != {'version', 'server_public', 'accounts'}
            or type(data['version']) is not int or data['version'] != 1 or data['server_public'] != public
            or not isinstance(data['accounts'], dict)):
        fail('Invalid account lifecycle metadata.')
    seen = set()
    for name, record in data['accounts'].items():
        valid_client_name(name)
        if (not isinstance(record, dict) or set(record) != {'public', 'disabled', 'expires_at', 'peer'}
                or type(record['disabled']) is not bool):
            fail('Invalid account lifecycle record.')
        identity = key(record['public'])
        if identity in seen:
            fail('Duplicate account identity in lifecycle metadata.')
        seen.add(identity)
        if record['expires_at'] == 'none':
            fail('Lifecycle metadata stores unset expiry as null.')
        lifecycle_expiry(record['expires_at'])
        if record['disabled']:
            if lifecycle_peer(record['peer'])['public'] != identity:
                fail('Disabled-peer identity differs from lifecycle metadata.')
        elif record['peer'] is not None:
            fail('Active accounts must not have a disabled-peer record.')
    return data


LIFECYCLE_MARKER = '# Managed by AWG account expiry: '


def lifecycle_paths(interface):
    interface = valid_name(interface)
    directory = Path('/usr/local/libexec') / ('awg-admin-' + interface)
    service = 'awg-expiry-' + interface
    return [directory / 'manager.py', Path('/etc/systemd/system') / (service + '.service'),
            Path('/etc/systemd/system') / (service + '.timer'),
            Path('/etc/systemd/system') / ('awg-quick@' + interface + '.service.d') / '90-awg-expiry.conf']


def lifecycle_read_owned(path, interface):
    path = secure_path(path)
    if not exists(path):
        return None
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'r') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_nlink != 1 or info.st_size > 4 * 1024 * 1024):
            fail('Expiry files must be private root-owned regular files.')
        text = stream.read()
    if not text.startswith(LIFECYCLE_MARKER + interface + '\n'):
        fail('An expiry path contains an unowned file; retained.')
    return text


def lifecycle_owned_paths(interface):
    return [path for path in lifecycle_paths(interface) if exists(path) and lifecycle_read_owned(path, interface) is not None]


def lifecycle_write(path, text, old, interface):
    secure_path(path)
    if lifecycle_read_owned(path, interface) != old:
        fail('An expiry file changed outside this operation.')
    fd, temp = tempfile.mkstemp(prefix='.awg-expiry-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        if old is None:
            os.link(temp, path, follow_symlinks=False)
        else:
            if lifecycle_read_owned(path, interface) != old:
                fail('An expiry file changed while staging its replacement.')
            os.replace(temp, path)
        sync_directory(path.parent)
    finally:
        if exists(temp):
            os.unlink(temp)


def lifecycle_unit_state(unit, action):
    result = subprocess.run(['systemctl', action, unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    return result.returncode == 0


def lifecycle_refresh_expiry(manager):
    helper = lifecycle_paths(manager.interface)[0]
    if not exists(helper):
        return
    old = lifecycle_read_owned(helper, manager.interface)
    program = read_profile(Path(__file__))
    compile(program, '<awg-expiry-helper>', 'exec')
    marker = LIFECYCLE_MARKER + manager.interface + '\n'
    if program.startswith(marker):
        program = program[len(marker):]
    proposed = marker + program
    if proposed != old:
        lifecycle_write(helper, proposed, old, manager.interface)
        print('Updated the existing expiry helper; timer and service settings are unchanged.')


def lifecycle_install_expiry(manager, source=None):
    interface = manager.interface
    source = Path(__file__) if source is None else Path(source)
    # The shell supplies a root-owned private temporary file containing the entire embedded admin program.
    program = read_profile(source)
    compile(program, '<awg-expiry-helper>', 'exec')
    marker = LIFECYCLE_MARKER + interface + '\n'
    if program.startswith(marker):
        program = program[len(marker):]
    paths = lifecycle_paths(interface)
    helper, service_path, timer_path, dropin = paths
    timer = timer_path.name
    snapshots = {}
    created_dirs = []
    for path in paths:
        missing, parent = [], path.parent
        while not exists(parent):
            missing.append(parent)
            parent = parent.parent
        for directory in reversed(missing):
            secure_path(directory)
            directory.mkdir(mode=0o700)
            created_dirs.append(directory)
        snapshots[path] = lifecycle_read_owned(path, interface)
    proposed = {
        helper: marker + program,
        service_path: marker + '[Unit]\nDescription=AWG account expiry for ' + interface
            + '\nBefore=awg-quick@' + interface + '.service\nAfter=local-fs.target\n\n[Service]\nType=oneshot\n'
            + 'ExecStart=/usr/bin/python3 ' + str(helper) + ' --enforce-expiry ' + interface + '\n'
            + 'UMask=0077\nNoNewPrivileges=yes\n',
        timer_path: marker + '[Unit]\nDescription=AWG expiry schedule for ' + interface
            + '\n\n[Timer]\nOnBootSec=30s\nOnUnitActiveSec=60s\nAccuracySec=1s\nUnit=' + service_path.name
            + '\n\n[Install]\nWantedBy=timers.target\n',
        dropin: marker + '[Unit]\nRequires=' + service_path.name + '\nAfter=' + service_path.name + '\n'
    }
    was_enabled = lifecycle_unit_state(timer, 'is-enabled')
    was_active = lifecycle_unit_state(timer, 'is-active')
    touched = []
    try:
        for path, text in proposed.items():
            if snapshots[path] != text:
                lifecycle_write(path, text, snapshots[path], interface)
                touched.append(path)
        run('systemctl', 'daemon-reload')
        run('systemctl', 'enable', '--now', timer)
        if not lifecycle_unit_state(timer, 'is-enabled') or not lifecycle_unit_state(timer, 'is-active'):
            fail('Expiry timer activation was not verified.')
    except BaseException:
        errors = []
        for action, should_undo in [('stop', not was_active), ('disable', not was_enabled)]:
            if should_undo:
                try:
                    run('systemctl', action, timer)
                except BaseException:
                    errors.append('timer state')
        for path in reversed(touched):
            try:
                if lifecycle_read_owned(path, interface) != proposed[path]:
                    fail('Expiry file changed during rollback.')
                if snapshots[path] is None:
                    path.unlink()
                else:
                    lifecycle_write(path, snapshots[path], proposed[path], interface)
            except BaseException:
                errors.append('expiry files')
        try:
            run('systemctl', 'daemon-reload')
        except BaseException:
            errors.append('systemd reload')
        for directory in reversed(created_dirs):
            try:
                directory.rmdir()
            except OSError:
                pass
        if errors:
            fail('Expiry setup failed; review timer and helper rollback before continuing.')
        raise
    print('Expiry scheduler installed; enforcement interval is approximately 60 seconds.')


def lifecycle_reapply(interface, preview=False, confirm_action=True):
    paths = lifecycle_owned_paths(interface)
    if not paths:
        return
    if set(paths) != set(lifecycle_paths(interface)):
        fail('Expiry helper files are incomplete; review the backup before activating.')
    print('Reload and activate expiry timer for ' + valid_name(interface))
    if preview:
        return
    if confirm_action:
        confirm('Activate the restored account expiry timer?')
    run('systemctl', 'daemon-reload')
    run('systemctl', 'enable', '--now', 'awg-expiry-' + interface + '.timer')


def lifecycle_remove(interface, preview=False, confirm_action=True):
    paths = lifecycle_owned_paths(interface)
    if not paths:
        return
    print('Remove only managed expiry helper, units, and AWG drop-in for ' + valid_name(interface))
    if preview:
        return
    if confirm_action:
        confirm('Remove expiry scheduling for this interface? Existing account expiry will no longer be enforced.')
    run('systemctl', 'disable', '--now', 'awg-expiry-' + interface + '.timer')
    run('systemctl', 'stop', 'awg-expiry-' + interface + '.service')
    for path in paths:
        lifecycle_read_owned(path, interface)
        path.unlink()
    for directory in [lifecycle_paths(interface)[0].parent, lifecycle_paths(interface)[-1].parent]:
        try:
            directory.rmdir()
        except OSError:
            pass
    run('systemctl', 'daemon-reload')


def lifecycle_expiry_main(interface):
    valid_name(interface)
    if os.geteuid() != 0 or sys.platform != 'linux':
        fail('Run expiry enforcement as root on the Linux AWG server.')
    directory = Path('/run/manage-amneziawg')
    secure_path(directory)
    if not exists(directory):
        directory.mkdir(mode=0o700)
    lock_path = secure_path(directory / 'setup.lock', private_parent=True)
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
            fail('Invalid shared management lock.')
        fcntl.flock(fd, fcntl.LOCK_EX)
        Manager(interface).enforce_expiry(noninteractive=True)
    finally:
        os.close(fd)


class Manager:
    def __init__(self, interface, base=Path('/etc/amnezia/amneziawg')):
        self.interface = valid_name(interface)
        self.base = Path(base)
        self.server_path = self.base / (interface + '.conf')
        self.client_dir = self.base / 'clients' / interface
        self.metadata_path = self.client_dir / 'metadata.json'
        self.files = {self.server_path: read_profile(self.server_path)}
        self.server = parse_config(self.files[self.server_path])
        self.obfuscation = parameters_from_fields({name: field(self.server['interface'], name)
                                                   for name in AWG_FIELDS if name in self.server['interface']['fields']})
        self.server_public = key(run('awg', 'pubkey', data=key(field(self.server['interface'], 'PrivateKey')) + '\n'))
        self.server_addresses = addresses(self.server['interface'], 'Address', interface=True)
        ipv4 = [address for address in self.server_addresses if address.version == 4]
        if len(ipv4) != 1:
            fail('Management requires exactly one saved server IPv4 address and subnet.')
        self.address = ipv4[0]
        self.disk_peers = {}
        for block in self.server['peers']:
            public = key(field(block, 'PublicKey'))
            if public in self.disk_peers:
                fail('Duplicate server peer public key.')
            psk = field(block, 'PresharedKey')
            if psk:
                key(psk)
            self.disk_peers[public] = {'block': block, 'psk': psk or None,
                                      'advanced_security': boolean(field(block, 'AdvancedSecurity', 'off')),
                                      'allowed': sorted(str(n) for n in addresses(block, 'AllowedIPs'))}
        self.accounts_path = self.base / (interface + '.accounts.json')
        self.accounts = {'version': 1, 'server_public': self.server_public, 'accounts': {}}
        if exists(self.accounts_path):
            self.files[self.accounts_path] = read_profile(self.accounts_path)
            self.accounts = lifecycle_accounts(self.files[self.accounts_path], self.server_public)
        self.clients = {}
        candidates = [self.base / 'clients' / (interface + '.conf'), self.base / (interface + '-client.conf')]
        initial = [path for path in candidates if exists(path)]
        if len(initial) > 1:
            fail('Both flat and legacy first-client profiles exist; resolve that ambiguity before management.')
        paths = [('initial', initial[0])] if initial else []
        if exists(self.client_dir):
            secure_path(self.client_dir / '.directory-check', private_parent=True)
            for path in sorted(self.client_dir.iterdir()):
                if path.suffix != '.conf':
                    continue
                name = valid_client_name(path.stem)
                if name == 'initial':
                    fail('The name initial is reserved for the existing flat or legacy profile.')
                paths.append((name, path))
        public_names = set()
        for name, path in paths:
            text = read_profile(path)
            config = parse_config(text)
            if len(config['peers']) != 1:
                fail('Each stored client profile must contain exactly one server Peer.')
            public = key(run('awg', 'pubkey', data=key(field(config['interface'], 'PrivateKey')) + '\n'))
            peer = config['peers'][0]
            client_parameters = parameters_from_fields({name: field(config['interface'], name)
                                                        for name in AWG_FIELDS if name in config['interface']['fields']})
            if client_parameters != self.obfuscation:
                fail('A stored client AmneziaWG parameter set differs from the server; secrets were suppressed.')
            account = self.accounts['accounts'].get(name)
            if account and account['public'] != public:
                fail('Account metadata and stored client identity differ.')
            disabled = bool(account and account['disabled'])
            if public in public_names or (public in self.disk_peers) == disabled:
                fail('Stored client identity or disabled state differs from saved peers.')
            saved = lifecycle_peer(account['peer']) if disabled else self.disk_peers[public]

            if field(peer, 'PublicKey') != self.server_public:
                fail('A stored client points to a different server public key.')
            psk = field(peer, 'PresharedKey') or None
            if psk != saved['psk']:
                fail('A stored client PSK differs from its saved server peer.')
            client_addresses = addresses(config['interface'], 'Address', interface=True)
            client_v4 = [address for address in client_addresses if address.version == 4]
            if len(client_v4) != 1 or str(client_v4[0].ip) + '/32' not in saved['allowed']:
                fail('A stored client IPv4 address differs from its server peer AllowedIPs.')
            endpoint = field(peer, 'Endpoint')
            endpoint_parts(endpoint)
            self.files[path] = text
            self.clients[name] = {'path': path, 'config': config, 'public': public,
                                  'address': client_v4[0], 'endpoint': endpoint,
                                  'disabled': disabled, 'expires_at': account['expires_at'] if account else None}
            public_names.add(public)
        if set(self.accounts['accounts']) - set(self.clients):
            fail('Account metadata references a missing stored profile.')
        self.local = json.loads(run('ip', '-j', '-4', 'address', 'show'))
        if not isinstance(self.local, list):
            fail('Unexpected local interface response.')
        self.runtime = runtime_state(interface)
        if self.runtime and self.runtime['public'] != self.server_public:
            fail('Saved and running server public keys differ.')
        if self.runtime and self.runtime['obfuscation'] != self.obfuscation:
            fail('Saved and running AmneziaWG parameters differ; secrets were suppressed.')
        if self.runtime is None and any(entry.get('ifname') == interface for entry in self.local):
            fail('That interface exists but is not a running AmneziaWG interface.')
        self.metadata = None
        if exists(self.metadata_path):
            text = read_profile(self.metadata_path)
            metadata = json.loads(text)
            if (not isinstance(metadata, dict) or set(metadata) != {'version', 'server_public', 'endpoint', 'mtu'}
                    or metadata['version'] != 1 or metadata['server_public'] != self.server_public
                    or not isinstance(metadata['endpoint'], str) or type(metadata['mtu']) is not int
                    or not 576 <= metadata['mtu'] <= 65535):
                fail('Invalid interface management metadata; review it before continuing.')
            endpoint_parts(metadata['endpoint'])
            self.files[self.metadata_path] = text
            self.metadata = metadata
        network_path = self.base / (interface + '.network.json')
        if exists(network_path):
            self.files[network_path] = read_profile(network_path)
        if 'dns_state' in globals():
            dns_state(self)

    def require_active(self):
        if self.runtime is None:
            fail('Start the intended saved AmneziaWG interface before changing its peers or port.')
        if field(self.server['interface'], 'SaveConfig').lower() == 'true':
            fail('SaveConfig=true needs manual review before persistent peer management.')
        saved_port = field(self.server['interface'], 'ListenPort')
        if saved_port and saved_port != '0' and valid_port(saved_port) != self.runtime['port']:
            fail('Saved and running listen ports differ.')
        local = [entry for entry in self.local if entry.get('ifname') == self.interface]
        if len(local) != 1 or not any(info.get('local') == str(self.address.ip)
                                     and info.get('prefixlen') == self.address.network.prefixlen
                                     for info in local[0].get('addr_info', [])):
            fail('The saved server IPv4 address and running interface differ.')
        for client in self.clients.values():
            public = client['public']
            live = self.runtime['peers'].get(public)
            if client.get('disabled'):
                if live is not None:
                    fail('A disabled account is present in the running interface.')
                continue
            saved = self.disk_peers[public]
            if live is None or any(live[k] != saved[k] for k in ('psk', 'allowed')):
                fail('A managed peer differs between saved and running state.')
            if endpoint_parts(client['endpoint'])[1] != self.runtime['port']:
                fail('A stored client Endpoint port differs from the running server.')
        if self.metadata and endpoint_parts(self.metadata['endpoint'])[1] != self.runtime['port']:
            fail('The saved management Endpoint port differs from the running server.')

    def unchanged(self):
        fresh = Manager(self.interface, self.base)
        if (fresh.files != self.files or stable_local(fresh.local) != stable_local(self.local)
                or stable_runtime(fresh.runtime) != stable_runtime(self.runtime)):
            fail('Configuration or runtime changed during confirmation; rerun after reviewing it.')

    def profile_settings(self):
        endpoints = {client['endpoint'] for client in self.clients.values()}
        if self.metadata:
            endpoints.add(self.metadata['endpoint'])
        if len(endpoints) != 1:
            fail('Exactly one unambiguous stored server Endpoint is required.')
        mtu = field(self.server['interface'], 'MTU')
        if not mtu:
            values = {field(client['config']['interface'], 'MTU') for client in self.clients.values()}
            values.discard('')
            if len(values) > 1:
                fail('Stored client MTU values differ; resolve that ambiguity first.')
            mtu = next(iter(values), '')
        if not mtu and self.metadata:
            mtu = str(self.metadata['mtu'])
        if not mtu:
            mtu = str(next(entry['mtu'] for entry in self.local if entry.get('ifname') == self.interface))
        if not mtu.isdecimal() or not 576 <= int(mtu) <= 65535:
            fail('Unexpected tunnel MTU.')
        return next(iter(endpoints)), int(mtu)

    def metadata_text(self, endpoint=None):
        saved_endpoint, mtu = self.profile_settings()
        return json.dumps({'version': 1, 'server_public': self.server_public,
                           'endpoint': endpoint or saved_endpoint, 'mtu': mtu}, indent=2) + '\n'

    def untracked(self):
        known = {client['public'] for client in self.clients.values()}
        return sorted((set(self.disk_peers) | set(self.runtime['peers'] if self.runtime else ())) - known)

    def list_clients(self):
        print('Account\tIPv4 / AllowedIPs\tState\tExpires (UTC)\tRuntime\tLast handshake')
        for name, client in sorted(self.clients.items()):
            live = self.runtime['peers'].get(client['public']) if self.runtime else None
            stamp = live['handshake'] if live else 0
            age = str(max(0, int(time.time()) - stamp)) + 's ago' if stamp else 'none'
            state = 'disabled' if client.get('disabled') else 'active'
            if client.get('expires_at') and lifecycle_expired(client['expires_at']):
                state += ' (expired)'
            print(name + '\t' + str(client['address']) + '\t' + state + '\t'
                  + (client.get('expires_at') or 'none') + '\t' + ('present' if live else 'absent') + '\t' + age)
        for public in self.untracked():
            live = self.runtime['peers'].get(public) if self.runtime else None
            saved = self.disk_peers.get(public)
            allowed = (live or saved)['allowed']
            print('untracked:' + public[:12] + '\t' + ','.join(allowed) + '\t'
                  + ('present' if live else 'absent') + '\tmanual management')
        print('Accounts are AmneziaWG peers, not Linux users. Handshake status is not a service health check.')

    def selected(self, name):
        valid_client_name(name)
        if name not in self.clients:
            fail('No stored client with that account name; untracked peers are retained.')
        return self.clients[name]

    def export_client(self, name, destination=None):
        client = self.selected(name)
        if destination is None or destination == '':
            confirm('Display the complete client profile, including its private key, PSK, and header-protection key. '
                    'Terminal scrollback and session recordings (including Jumpserver) may retain these secrets.')
            self.unchanged()
            sys.stdout.write(self.files[client['path']])
            return
        destination = secure_path(Path(destination), private_parent=True)
        if destination == self.base or self.base in destination.parents:
            fail('Export outside the AmneziaWG configuration directory so managed profiles stay unchanged.')
        if destination.suffix != '.conf':
            fail('Export to a .conf file with a AmneziaWG-compatible filename.')
        valid_client_name(destination.stem)
        if exists(destination):
            fail('Export destination already exists; it was retained.')
        confirm('Export a secret client profile to ' + str(destination) + '. Keep it private and transfer it securely.')
        self.unchanged()
        atomic_write(destination, self.files[client['path']])
        print(str(destination))

    def transaction(self, changes, apply_runtime, undo_runtime, expected_runtime, rule=None):
        self.unchanged()
        created_dirs, touched = [], []
        backup = None
        previous_rules = None
        runtime_attempted = rule_attempted = False
        try:
            for path in changes:
                missing, parent = [], path.parent
                while not exists(parent):
                    missing.append(parent)
                    parent = parent.parent
                for directory in reversed(missing):
                    secure_path(directory)
                    directory.mkdir(mode=0o700)
                    created_dirs.append(directory)
                secure_path(path, private_parent=True)
            backup = Path(tempfile.mkdtemp(prefix=self.interface + '-manager-backup-', dir=self.base))
            os.chmod(backup, 0o700)
            records = []
            for index, path in enumerate(changes):
                original = self.files.get(path)
                records.append({'path': str(path), 'backup': str(index) + '.conf' if original is not None else None})
                if original is not None:
                    atomic_write(backup / (str(index) + '.conf'), original)
            atomic_write(backup / 'manifest.json', json.dumps(records, indent=2) + '\n')
            if rule:
                previous_rules = run('ufw', 'show', 'added')
                if re.search(r'(?<![0-9])' + rule[rule.index('port') + 1] + r'(?![0-9])', previous_rules):
                    fail('UFW rules changed before applying the new rule; existing rules were retained.')
                rule_attempted = True
                response = run('ufw', *rule)
                if 'Skipping adding existing rule' in response:
                    rule_attempted = False
                    fail('UFW reported an existing rule; it was retained for manual review.')
                if not ufw_has_rule(run('ufw', 'show', 'added'), rule):
                    fail('The new narrowly scoped UFW rule was not verified.')
            for path, text in changes.items():
                touched.append(path)
                original = self.files.get(path)
                if text is None:
                    unlink_profile(path, original)
                else:
                    atomic_write(path, text, original)
            runtime_attempted = True
            apply_runtime()
            if stable_runtime(runtime_state(self.interface)) != expected_runtime:
                fail('Post-change runtime verification failed.')
            for path, text in changes.items():
                if (text is None and exists(path)) or (text is not None and read_profile(path) != text):
                    fail('Post-change saved-profile verification failed.')
        except BaseException:
            old_handlers = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGINT, signal.SIGTERM)}
            errors = []
            try:
                if runtime_attempted:
                    try:
                        undo_runtime()
                        if stable_runtime(runtime_state(self.interface)) != stable_runtime(self.runtime):
                            fail('Runtime rollback verification failed.')
                    except BaseException:
                        errors.append('runtime restore')
                for path in reversed(touched):
                    original, proposed = self.files.get(path), changes[path]
                    try:
                        current = read_profile(path) if exists(path) else None
                        if current == original:
                            continue
                        if current != proposed:
                            fail('A profile changed during rollback; it was retained.')
                        if original is None:
                            unlink_profile(path, proposed)
                        else:
                            atomic_write(path, original, current)
                    except BaseException:
                        errors.append('saved profile restore')
                if rule_attempted:
                    try:
                        if ufw_has_rule(run('ufw', 'show', 'added'), rule):
                            run('ufw', '--force', 'delete', *rule)
                        if ufw_has_rule(run('ufw', 'show', 'added'), rule):
                            fail('UFW rollback verification failed.')
                        if run('ufw', 'show', 'added') != previous_rules:
                            fail('UFW rules changed outside the verified rollback; manual review is required.')
                    except BaseException:
                        errors.append('new UFW rule restore')
                for directory in reversed(created_dirs):
                    try:
                        directory.rmdir()
                    except OSError:
                        pass
            finally:
                for signum, handler in old_handlers.items():
                    signal.signal(signum, handler)
            if backup:
                print('Private backups: ' + str(backup), file=sys.stderr)
            if errors:
                fail('Operation failed; manual rollback review required: ' + ', '.join(errors))
            fail('Operation failed; previous profiles, runtime, and firewall state were restored.')
        print('Private backups: ' + str(backup))

    def add_client(self, name):
        valid_client_name(name)
        if name == 'initial' or name in self.clients:
            fail('That account name is reserved or already exists.')
        self.require_active()
        destination = self.client_dir / (name + '.conf')
        if exists(destination):
            fail('Client destination already exists.')
        endpoint, mtu = self.profile_settings()
        occupied = [n for peer in self.disk_peers.values() for n in peer['allowed']]
        occupied += [n for peer in self.runtime['peers'].values() for n in peer['allowed']]
        if 'network_reserved_addresses' in globals():
            occupied += network_reserved_addresses(self)
        local = [info['local'] for entry in self.local for info in entry.get('addr_info', []) if 'local' in info]
        local += [str(client['address'].ip) for client in self.clients.values()]
        address = allocate_address(str(self.address), occupied, local)
        # Extra routes belong to clients, never to server peer AllowedIPs.
        client_routes = [str(self.address.ip) + '/32']
        route_path = self.server_path.with_suffix('.client-routes')
        route_text = None
        if route_path.exists() or route_path.is_symlink():
            if route_path.is_symlink() or not route_path.is_file() or route_path.stat().st_uid != 0 or route_path.stat().st_mode & 0o077:
                fail('Client route policy must be a root-owned private regular file.')
            route_text = route_path.read_text()
            for value in route_text.splitlines():
                if not value.strip():
                    continue
                try:
                    network = ipaddress.ip_network(value.strip(), strict=True)
                except ValueError:
                    fail('Invalid network in client route policy.')
                if network.version != 4:
                    fail('This client route policy supports IPv4 only.')
                if str(network) not in client_routes:
                    client_routes.append(str(network))
        route_summary = 'The new client routes ' + ', '.join(client_routes)
        if 'network_state' in globals() and network_state(self)['mode'] == 'full':
            route_summary = 'The new client inherits full-tunnel IPv4 Internet routing and DNS; IPv6 is tunneled and blocked'
        confirm('Add account ' + name + ' with address ' + address + '. New keys and a PSK will be generated.\n'
                + route_summary + '; existing peers and networking stay in place.')
        self.unchanged()
        if route_path.is_symlink() or route_path.exists() != (route_text is not None) or (route_text is not None and (route_path.is_symlink() or not route_path.is_file() or route_path.read_text() != route_text)):
            fail('Client route policy changed during confirmation; retry.')
        if '.' in name:
            # An older persisted helper rejects dotted profiles, including when enforcing expiry for other accounts.
            lifecycle_refresh_expiry(self)
        private = key(run('awg', 'genkey'))
        public = key(run('awg', 'pubkey', data=private + '\n'))
        psk = key(run('awg', 'genpsk'))
        if public == self.server_public or public in self.disk_peers or public in self.runtime['peers'] or public in {c['public'] for c in self.clients.values()}:
            fail('Generated key collided with an existing key; retry without changing the configuration.')
        retained_psks = {field(c['config']['peers'][0], 'PresharedKey') for c in self.clients.values()}
        if psk in {peer['psk'] for peer in self.disk_peers.values()} | {peer['psk'] for peer in self.runtime['peers'].values()} | retained_psks:
            fail('Generated PSK collided with an existing PSK; retry.')
        obfuscation_text = ''.join(name + ' = ' + value + '\n' for name, value in self.obfuscation.items() if value != '')
        client_text = ('[Interface]\nPrivateKey = ' + private + '\nAddress = ' + address + '\nMTU = ' + str(mtu)
                       + '\n' + obfuscation_text
                       + '\n\n[Peer]\nPublicKey = ' + self.server_public + '\nPresharedKey = ' + psk
                       + '\nEndpoint = ' + endpoint + '\nAllowedIPs = ' + ', '.join(client_routes)
                       + '\nPersistentKeepalive = 25-35\n')
        peer_text = '[Peer]\nPublicKey = ' + public + '\nPresharedKey = ' + psk + '\nAllowedIPs = ' + address + '\n'
        self.network_pending_changes = {}
        if 'network_new_client' in globals():
            client_text, peer_text = network_new_client(self, name, address, client_text, peer_text)
        if 'dns_new_client' in globals():
            client_text = dns_new_client(self, name, public, client_text, self.network_pending_changes)
        server_text = self.files[self.server_path]
        server_text += ('\n' if not server_text.endswith('\n') else '') + '\n' + peer_text
        peer = {'psk': psk, 'allowed': [address], 'keepalive': '0', 'endpoint': None, 'advanced_security': None}
        expected = stable_runtime(self.runtime)
        expected['peers'][public] = {k: peer[k] for k in ('psk', 'allowed', 'keepalive')}
        self.transaction({self.server_path: server_text, destination: client_text,
                          self.metadata_path: self.metadata_text(), **self.network_pending_changes},
                         lambda: set_peer(self.interface, public, peer),
                         lambda: run('awg', 'set', self.interface, 'peer', public, 'remove'), expected)
        print('Client profile: ' + str(destination) + ' (secret; transfer securely).')
        print('Import the new profile and verify its handshake; connectivity has not been tested.')

    def lifecycle_record(self, name):
        client = self.selected(name)
        return dict(self.accounts['accounts'].get(name) or {
            'public': client['public'], 'disabled': False, 'expires_at': None, 'peer': None})

    def lifecycle_text(self, name, record):
        data = json.loads(json.dumps(self.accounts))
        if record is None:
            data['accounts'].pop(name, None)
        else:
            data['accounts'][name] = record
        return json.dumps(data, indent=2, sort_keys=True) + '\n'

    def lifecycle_ready(self):
        if field(self.server['interface'], 'SaveConfig').lower() == 'true':
            fail('SaveConfig=true needs manual review before persistent peer management.')
        if self.runtime is not None:
            self.require_active()

    def disable_client(self, name, *, noninteractive=False):
        client = self.selected(name)
        self.lifecycle_ready()
        if client.get('disabled'):
            print('Account already disabled: ' + name)
            return
        public = client['public']
        block = self.disk_peers[public]['block']
        lines = self.server['lines']
        peer_text = ''.join(lines[block['start']:block['end']])
        lifecycle_peer(peer_text)
        text = ''.join(lines[:block['start']] + lines[block['end']:])
        record = self.lifecycle_record(name)
        record.update(disabled=True, peer=peer_text)
        if not noninteractive:
            confirm('Disable account ' + name + ' immediately; retain its profile and reserved address for later reactivation.')
        expected = stable_runtime(self.runtime)
        if expected is not None:
            del expected['peers'][public]
        self.transaction({self.server_path: text, self.accounts_path: self.lifecycle_text(name, record)},
                         lambda: run('awg', 'set', self.interface, 'peer', public, 'remove') if self.runtime else None,
                         lambda: set_peer(self.interface, public, self.runtime['peers'][public]) if self.runtime else None,
                         expected)
        print('Disabled account: ' + name)

    def enable_client(self, name):
        client = self.selected(name)
        self.lifecycle_ready()
        record = self.lifecycle_record(name)
        if record['expires_at'] and lifecycle_expired(record['expires_at']):
            fail('Set a future expiry or clear expiry before enabling this expired account.')
        if not client.get('disabled'):
            print('Account already enabled: ' + name)
            return
        peer = lifecycle_peer(record['peer'])
        occupied = [n for value in self.disk_peers.values() for n in value['allowed']]
        if self.runtime:
            occupied += [n for value in self.runtime['peers'].values() for n in value['allowed']]
        if any(ipaddress.ip_network(a).overlaps(ipaddress.ip_network(b))
               for a in peer['allowed'] for b in occupied if ipaddress.ip_network(a).version == ipaddress.ip_network(b).version):
            fail('Reserved client address overlaps another saved or running peer.')
        text = self.files[self.server_path].rstrip() + '\n\n' + record['peer'].rstrip() + '\n'
        record.update(disabled=False, peer=None)
        confirm('Enable account ' + name + ' using its existing private profile. Access rules remain unchanged.')
        expected = stable_runtime(self.runtime)
        if expected is not None:
            expected['peers'][client['public']] = {k: peer[k] for k in ('psk', 'allowed', 'keepalive')}
        self.transaction({self.server_path: text, self.accounts_path: self.lifecycle_text(name, record)},
                         lambda: set_peer(self.interface, client['public'], peer) if self.runtime else None,
                         lambda: run('awg', 'set', self.interface, 'peer', client['public'], 'remove') if self.runtime else None,
                         expected)
        print('Enabled account: ' + name)

    def set_expiry(self, name, value):
        self.lifecycle_ready()
        record = self.lifecycle_record(name)
        expires = lifecycle_expiry(value)
        if expires and lifecycle_expired(expires):
            fail('Choose a future UTC timestamp, or use none to remove the expiry.')
        if record['expires_at'] == expires:
            print('Expiry unchanged.')
            return
        confirm('Set account ' + name + ' expiry to ' + (expires or 'none')
                + '. Automatic expiry runs every 60 seconds and before interface startup; system time must be correct.')
        if expires:
            lifecycle_install_expiry(self, Path(__file__))
        record['expires_at'] = expires
        self.transaction({self.accounts_path: self.lifecycle_text(name, record)},
                         lambda: None, lambda: None, stable_runtime(self.runtime))
        print('Expiry saved; a disabled account stays disabled until explicitly enabled.')

    def enforce_expiry(self, noninteractive=True):
        self.lifecycle_ready()
        names = [name for name, client in self.clients.items()
                 if not client.get('disabled') and client.get('expires_at') and lifecycle_expired(client['expires_at'])]
        for name in names:
            Manager(self.interface, self.base).disable_client(name, noninteractive=noninteractive)
        print('Expiry enforcement: ' + str(len(names)) + ' account(s) disabled.')

    def remove_client(self, name):
        client = self.selected(name)
        self.require_active()
        public = client['public']
        text = self.files[self.server_path]
        if not client.get('disabled'):
            block = self.disk_peers[public]['block']
            lines = self.server['lines']
            text = ''.join(lines[:block['start']] + lines[block['end']:])
        confirm('Remove account ' + name + ' from saved and running configuration; its old profile stops working. Private backups remain.')
        expected = stable_runtime(self.runtime)
        if expected is not None:
            expected['peers'].pop(public, None)
        changes = {self.server_path: text, client['path']: None, self.metadata_path: self.metadata_text()}
        if name in self.accounts['accounts']:
            changes[self.accounts_path] = self.lifecycle_text(name, None)
        if 'dns_remove_client' in globals():
            dns_remove_client(self, name, changes)
        self.transaction(changes,
                         lambda: run('awg', 'set', self.interface, 'peer', public, 'remove') if self.runtime and not client.get('disabled') else None,
                         lambda: set_peer(self.interface, public, self.runtime['peers'][public]) if self.runtime and not client.get('disabled') else None,
                         expected)
        print('Removed account: ' + name + '. Other peers and address reservations in access policies were retained.')

    def port_preflight(self, port):
        if run('ss', '-H', '-lun', 'sport = :' + str(port)):
            fail('The requested UDP port is already occupied.')
        if 'Status: active' not in run('ufw', 'status').splitlines():
            fail('UFW must already be active; it will not be enabled or reset here.')
        rules = run('ufw', 'show', 'added')
        if re.search(r'(?<![0-9])' + str(port) + r'(?![0-9])', rules):
            fail('An existing UFW rule already mentions the requested port; review it before changing ports.')

    def set_port(self, port):
        port = valid_port(port)
        self.require_active()
        previous = self.runtime['port']
        if port == previous:
            print('The requested port is already active; no changes made.')
            return
        endpoint, _ = self.profile_settings()
        host, _ = endpoint_parts(endpoint)
        try:
            public_ip = str(ipaddress.IPv4Address(host))
        except ValueError:
            fail('Automatic UFW updates require a literal IPv4 Endpoint assigned to this server.')
        public_interfaces = [entry.get('ifname') for entry in self.local
                             if any(info.get('local') == public_ip for info in entry.get('addr_info', []))]
        if len(public_interfaces) != 1 or public_interfaces[0] == self.interface:
            fail('The Endpoint IPv4 address is not assigned to exactly one public interface.')
        public_interface = public_interfaces[0]
        if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', public_interface) or public_interface == 'lo':
            fail('Unexpected public interface name.')
        self.port_preflight(port)
        untracked = self.untracked()
        print('Untracked peers needing manual Endpoint updates: ' + str(len(untracked)))
        confirm('Change ' + self.interface + ' UDP port ' + str(previous) + ' to ' + str(port) + '.\n'
                'FIRST allow inbound UDP ' + str(port) + ' in any attached cloud/provider firewall. This script does not change it.\n'
                'Keep a separate SSH/console session. Connected clients will be interrupted until their updated profiles are imported.\n'
                'All stored client Endpoint ports will change; untracked clients require manual updates.\n'
                'Only one narrow UFW allow rule is added. Existing firewall rules, including the old port, remain.')
        self.unchanged()
        self.port_preflight(port)
        changes = {self.server_path: replace_field(self.files[self.server_path], self.server['interface'], 'ListenPort', str(port))}
        for client in self.clients.values():
            host, _ = endpoint_parts(client['endpoint'])
            changes[client['path']] = replace_field(self.files[client['path']], client['config']['peers'][0],
                                                    'Endpoint', host + ':' + str(port))
        changes[self.metadata_path] = self.metadata_text(public_ip + ':' + str(port))
        rule = ['allow', 'in', 'on', public_interface, 'proto', 'udp', 'to', public_ip, 'port', str(port),
                'comment', 'manage-awg-' + self.interface]
        expected = stable_runtime(self.runtime)
        expected['port'] = port
        self.transaction(changes, lambda: run('awg', 'set', self.interface, 'listen-port', str(port)),
                         lambda: run('awg', 'set', self.interface, 'listen-port', str(previous)), expected, rule)
        print('Listen port: ' + str(port) + '. Re-export and re-import every stored client profile.')
        print('Old firewall rules remain. Verify client handshakes and any untracked clients separately.')


def dispatch(arguments):
    if len(arguments) < 2:
        fail('Supply an operation and AmneziaWG interface.')
    operation, interface, *values = arguments
    counts = {'--list-clients': (0, 0), '--add-client': (1, 1), '--export-client': (1, 2),
              '--remove-client': (1, 1), '--set-port': (1, 1)}
    if operation not in counts or not counts[operation][0] <= len(values) <= counts[operation][1]:
        fail('Invalid management arguments; use --help for the command forms.')
    if any(value.startswith('--') for value in values):
        fail('Unexpected option; see --help for command forms.')
    manager = Manager(interface)
    methods = {'--list-clients': manager.list_clients, '--add-client': manager.add_client,
               '--export-client': manager.export_client, '--remove-client': manager.remove_client,
               '--set-port': manager.set_port}
    methods[operation](*values)


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    if os.geteuid() != 0 or sys.platform != 'linux':
        fail('Run management commands as root on the Linux AmneziaWG server.')
    if len(arguments) == 2 and arguments[0] == '--manage':
        interface = valid_name(arguments[1])
        while True:
            print('\nAmneziaWG accounts for ' + interface + '\n1) Add client\n2) List clients\n3) Export client\n4) Remove client\n5) Change UDP port\n6) Configure VPC access\n0) Exit')
            choice = prompt('Select: ')
            if choice == '0':
                return 0
            if choice == '1':
                dispatch(['--add-client', interface, prompt('New account name: ')])
            elif choice == '2':
                dispatch(['--list-clients', interface])
            elif choice == '3':
                dispatch(['--export-client', interface, prompt('Account name: '),
                          prompt('Absolute destination .conf path (blank to display in terminal): ')])
            elif choice == '4':
                dispatch(['--remove-client', interface, prompt('Account name: ')])
            elif choice == '5':
                dispatch(['--set-port', interface, prompt('New UDP port: ')])
            elif choice == '6':
                return 42  # Return to the shell dispatcher while it retains the shared lock.
            else:
                print('Choose 0, 1, 2, 3, 4, 5, or 6.')
    else:
        dispatch(arguments)
    return 0


def interrupt(signum, frame):
    raise InterruptedError('Operation interrupted.')

"""Embedded network policy extension. Uses the preceding manager's validated helpers."""
import copy
import hashlib

NETWORK_UFW4 = Path('/etc/ufw/before.rules')
NETWORK_UFW6 = Path('/etc/ufw/before6.rules')
NETWORK_UFW_DEFAULT = Path('/etc/default/ufw')
NETWORK_UFW_SYSCTL = Path('/etc/ufw/sysctl.conf')
NETWORK_DNS_CURRENT = object()


def network_paths(manager):
    return (manager.base / (manager.interface + '.network.json'),
            Path('/etc/sysctl.d/90-awg-network-' + manager.interface + '.conf'))


def network_owned_paths(interface, base=Path('/etc/amnezia/amneziawg')):
    valid_name(interface)
    return [Path(base) / (interface + '.network.json'),
            Path('/etc/sysctl.d/90-awg-network-' + interface + '.conf')]


def network_assert_vpc_compatible(interface):
    manager = Manager(valid_name(interface))
    if network_state(manager)['mode'] == 'full':
        fail('Switch network mode to split before changing VPC routes; full-mode profiles were retained.')


def network_rule(value):
    parts = value.split(':')
    if len(parts) not in (2, 3):
        fail('Access rule: IPv4CIDR:tcp|udp:PORT, IPv4CIDR:icmp, or IPv4CIDR:any.')
    destination = ipaddress.ip_network(parts[0], strict=True)
    if destination.version != 4 or parts[1] not in ('tcp', 'udp', 'icmp', 'any'):
        fail('Access rules require an IPv4 prefix and tcp, udp, icmp, or any.')
    if parts[1] in ('tcp', 'udp'):
        if len(parts) != 3:
            fail('TCP and UDP rules require one destination port.')
        return str(destination) + ':' + parts[1] + ':' + str(valid_port(parts[2]))
    if len(parts) != 2:
        fail('ICMP and any rules do not accept a port.')
    return str(destination) + ':' + parts[1]


def network_dns(value):
    result = []
    for part in value.replace(',', ' ').split():
        address = ipaddress.IPv4Address(part)
        if address.is_unspecified or address.is_loopback or address.is_multicast:
            fail('DNS must be reachable IPv4 resolver addresses, not loopback or multicast.')
        if str(address) not in result:
            result.append(str(address))
    if not result or len(result) > 3:
        fail('Choose one to three IPv4 DNS resolver addresses.')
    return result


def network_state(manager):
    path = network_paths(manager)[0]
    if not exists(path):
        return {'version': 1, 'server_public': manager.server_public, 'mode': 'split',
                'egress': None, 'dns': [], 'clients': {}, 'access': {}}
    state = json.loads(read_profile(path))
    if (not isinstance(state, dict) or set(state) !=
            {'version', 'server_public', 'mode', 'egress', 'dns', 'clients', 'access'}
            or state['version'] != 1 or state['server_public'] != manager.server_public
            or state['mode'] not in ('split', 'full')
            or not isinstance(state['clients'], dict) or not isinstance(state['access'], dict)):
        fail('Invalid network policy metadata; existing files were retained.')
    if state['mode'] == 'full':
        valid_name(state['egress'])
        if state['dns'] != network_dns(' '.join(state['dns'])):
            fail('Invalid saved DNS policy.')
    elif state['egress'] is not None or state['dns']:
        fail('Split mode must not retain an Internet egress policy.')
    for name, original in state['clients'].items():
        valid_client_name(name)
        if not isinstance(original, dict) or set(original) != {'public', 'address', 'dns', 'allowed'}:
            fail('Invalid saved split profile fields.')
        key(original['public'])
        for value in original.values():
            if value is not None and (not isinstance(value, str) or '\n' in value or '\r' in value):
                fail('Invalid saved split profile field value.')
        for value in original['address'].split(','):
            ipaddress.ip_interface(value.strip())
        for value in original['allowed'].split(','):
            ipaddress.ip_network(value.strip(), strict=False)
    for name, policy in state['access'].items():
        valid_client_name(name)
        if not isinstance(policy, dict) or set(policy) != {'public', 'address', 'rules'}:
            fail('Invalid saved access policy.')
        key(policy['public'])
        address = ipaddress.ip_network(policy['address'], strict=True)
        if address.version != 4 or address.prefixlen != 32 or address.network_address not in manager.address.network:
            fail('Access policy address must be one VPN client IPv4 /32.')
        if not isinstance(policy['rules'], list) or len(policy['rules']) > 64:
            fail('Invalid saved access-rule list.')
        if policy['rules'] != sorted(set(network_rule(rule) for rule in policy['rules'])):
            fail('Invalid or duplicate saved access rules.')
        client = manager.clients.get(name)
        if client and (client['public'] != policy['public'] or str(client['address'].ip) + '/32' != policy['address']):
            fail('A saved access rule belongs to a different client; clear its stale policy first.')
    return state


def network_text(state):
    return json.dumps(state, sort_keys=True, indent=2) + '\n'


def network_profile_fields(text):
    config = parse_config(text)
    return {'address': field(config['interface'], 'Address'),
            'dns': field(config['interface'], 'DNS', None),
            'allowed': field(config['peers'][0], 'AllowedIPs')}


def network_field(text, section, name, value):
    config = parse_config(text)
    block = config['interface'] if section == 'interface' else config['peers'][0]
    if value is not None:
        return replace_field(text, block, name, value)
    indexes = block['indexes'].get(name, [])
    if len(indexes) > 1:
        fail('Repeated fields need manual reconciliation before changing network mode.')
    return ''.join(line for i, line in enumerate(config['lines']) if i not in indexes)


def network_ula(manager, address):
    # Client-only ULA provides an IPv6 route. Server peers deliberately allow only their original addresses.
    prefix = int.from_bytes(hashlib.sha256(manager.server_public.encode()).digest()[:5], 'big')
    value = (0xfd << 120) | (prefix << 80) | int(ipaddress.IPv4Interface(address).ip)
    return str(ipaddress.IPv6Address(value)) + '/128'


def network_full_profile(manager, address, text, state):
    original = network_profile_fields(text)
    ipv6 = network_ula(manager, address)
    addrs = [v.strip() for v in original['address'].split(',')]
    if ipv6 not in addrs:
        addrs.append(ipv6)
    text = network_field(text, 'interface', 'Address', ', '.join(addrs))
    text = network_field(text, 'interface', 'DNS', ', '.join(state['dns']))
    return network_field(text, 'peer', 'AllowedIPs', '0.0.0.0/0, ::/0')


def network_reserved_addresses(manager):
    return [entry['address'] for entry in network_state(manager)['access'].values()]


def network_new_client(manager, name, address, client_text, server_peer_text):
    state = network_state(manager)
    if name in state['access']:
        fail('A retained access policy uses this account name; clear it with inherit before reusing the name.')
    if state['mode'] == 'full':
        public = key(run('awg', 'pubkey', data=field(parse_config(client_text)['interface'], 'PrivateKey') + '\n'))
        state['clients'][name] = dict(public=public, **network_profile_fields(client_text))
        client_text = network_full_profile(manager, address, client_text, state)
        path = network_paths(manager)[0]
        manager.files[path] = read_profile(path)
        manager.network_pending_changes = {path: network_text(state)}
    return client_text, server_peer_text


def network_strip_marker(text, tag):
    start, end = '# BEGIN ' + tag, '# END ' + tag
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.strip() == start]
    ends = [i for i, line in enumerate(lines) if line.strip() == end]
    if not starts and not ends:
        return text
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        fail('Ambiguous network policy marker; no firewall changes made.')
    if any(line.strip().startswith(('# BEGIN ', '# END ')) for line in lines[starts[0] + 1:ends[0]]):
        fail('Nested ownership markers need manual review; no firewall content was removed.')
    return ''.join(lines[:starts[0]] + lines[ends[0] + 1:])


def network_normalize_nat(text):
    """Move recognized legacy table envelopes outside ownership markers, without changing rules."""
    lines = text.splitlines(keepends=True)
    index = 0
    while index < len(lines):
        match = re.fullmatch(r'# BEGIN (awg-test-vpc|awg-vpc-[A-Za-z][A-Za-z0-9_-]{0,14}|awg-network-[A-Za-z][A-Za-z0-9_-]{0,14}-nat)', lines[index].strip())
        if not match:
            index += 1
            continue
        tag = match.group(1)
        ends = [i for i in range(index + 1, len(lines)) if lines[i].strip() == '# END ' + tag]
        if len(ends) != 1:
            fail('Ambiguous NAT ownership marker; retained for review.')
        end = ends[0]
        inner = [line.strip() for line in lines[index + 1:end]]
        if '*nat' not in inner:
            index = end + 1
            continue
        if (len(inner) != 4 or inner[0:2] != ['*nat', ':POSTROUTING ACCEPT [0:0]']
                or inner[-1] != 'COMMIT'):
            fail('A legacy NAT table contains additional content; retained without modification.')
        tokens = shlex.split(inner[2])
        if tag.endswith('-nat'):
            if len(tokens) != 8 or tokens[:3] != ['-A', 'POSTROUTING', '-s'] or tokens[4] != '-o' or tokens[6:] != ['-j', 'MASQUERADE']:
                fail('Unexpected owned Internet NAT rule; retained.')
            ipaddress.IPv4Network(tokens[3], strict=True)
            valid_name(tokens[5])
        else:
            if len(tokens) != 12 or tokens[:3] != ['-A', 'POSTROUTING', '-s'] or tokens[4] != '-d' or tokens[6] != '-o' or tokens[8:11] != ['-j', 'SNAT', '--to-source']:
                fail('Unexpected legacy VPC NAT rule; retained.')
            ipaddress.IPv4Network(tokens[3], strict=True)
            ipaddress.IPv4Network(tokens[5], strict=True)
            valid_name(tokens[7])
            ipaddress.IPv4Address(tokens[11])
        replacement = ['*nat\n', ':POSTROUTING ACCEPT [0:0]\n', '# BEGIN ' + tag + '\n',
                       inner[2] + '\n', '# END ' + tag + '\n', 'COMMIT\n']
        lines[index:end + 1] = replacement
        index += len(replacement)
    return ''.join(lines)


def network_assert_outside_marker(lines, index):
    active = []
    for line in lines[:index]:
        body = line.strip()
        if body.startswith('# BEGIN '):
            active.append(body[len('# BEGIN '):])
        elif body.startswith('# END '):
            if not active or active[-1] != body[len('# END '):]:
                fail('Malformed firewall ownership marker ordering; retained.')
            active.pop()
    if active:
        fail('Insertion would nest ownership markers; retained for manual review.')


def network_insert_table(text, table, tag, rules):
    if table == 'nat' and (rules or '# BEGIN ' + tag in text or '# END ' + tag in text):
        text = network_normalize_nat(text)
    text = network_strip_marker(text, tag)
    if not rules:
        return text
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.strip() == '*' + table]
    block = '# BEGIN ' + tag + '\n' + '\n'.join(rules) + '\n# END ' + tag + '\n'
    if len(starts) > 1:
        fail('Multiple firewall table sections need manual review.')
    if not starts:
        if table != 'nat':
            fail('Expected UFW filter table was not found.')
        network_assert_outside_marker(lines, len(lines))
        return text.rstrip('\n') + '\n\n*nat\n:POSTROUTING ACCEPT [0:0]\n' + block + 'COMMIT\n'
    start = starts[0]
    commits = [i for i in range(start + 1, len(lines)) if lines[i].strip() == 'COMMIT']
    if not commits:
        fail('Incomplete firewall table.')
    end = commits[0]
    # Insert after declarations but before every packet rule, including established accepts.
    declarations = [i for i in range(start + 1, end) if lines[i].lstrip().startswith(':')]
    index = max(declarations, default=start) + 1
    if any(lines[i].lstrip().startswith(('-A ', '-I ')) for i in range(start + 1, index)):
        fail('Unexpected firewall declaration ordering.')
    network_assert_outside_marker(lines, index)
    lines.insert(index, block)
    return ''.join(lines)


def network_rules(manager, state, dns_policy=NETWORK_DNS_CURRENT):
    interface, subnet = manager.interface, str(manager.address.network)
    if dns_policy is NETWORK_DNS_CURRENT:
        dns_policy = dns_state(manager) if 'dns_state' in globals() else None
    rules = []
    for policy in sorted(state['access'].values(), key=lambda p: p['address']):
        ip = policy['address']
        for rule in policy['rules']:
            parts = rule.split(':')
            destination, protocol = parts[:2]
            protocol_args = '' if protocol == 'any' else ' -p ' + protocol
            port_args = ' --dport ' + parts[2] if len(parts) == 3 else ''
            for chain in ('ufw-before-input', 'ufw-before-forward'):
                rules.append('-A ' + chain + ' -i ' + interface + ' -s ' + ip + ' -d ' + destination + protocol_args + port_args + ' -j ACCEPT')
            reverse_port = ' --sport ' + parts[2] if len(parts) == 3 else ''
            rules.append('-A ufw-before-forward -o ' + interface + ' -d ' + ip + ' -s ' + destination + protocol_args + reverse_port + ' -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT')
        rules += ['-A ufw-before-input -i ' + interface + ' -s ' + ip + ' -j DROP',
                  '-A ufw-before-forward -i ' + interface + ' -s ' + ip + ' -j DROP',
                  '-A ufw-before-forward -o ' + interface + ' -d ' + ip + ' -j DROP']
    # Existing account restrictions take precedence; DNS never grants an ACL exception.
    if dns_policy is not None:
        resolver = str(ipaddress.IPv4Address(dns_policy['address']))
        if resolver != str(manager.address.ip):
            fail('Private DNS must listen on this interface server address.')
        for protocol in ('udp', 'tcp'):
            rules.append('-A ufw-before-input -i ' + interface + ' -s ' + subnet
                         + ' -d ' + resolver + '/32 -p ' + protocol + ' --dport 53 -j ACCEPT')
    if state['mode'] == 'full':
        rules += ['-A ufw-before-forward -i ' + interface + ' -o ' + state['egress'] + ' -s ' + subnet + ' -j ACCEPT',
                  '-A ufw-before-forward -i ' + state['egress'] + ' -o ' + interface + ' -d ' + subnet + ' -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT']
    nat = ['-A POSTROUTING -s ' + subnet + ' -o ' + state['egress'] + ' -j MASQUERADE'] if state['mode'] == 'full' else []
    ipv6 = ['-A ufw6-before-input -i ' + interface + ' -j DROP',
            '-A ufw6-before-forward -i ' + interface + ' -j DROP',
            '-A ufw6-before-forward -o ' + interface + ' -j DROP'] if state['access'] or state['mode'] == 'full' else []
    return rules, nat, ipv6


def network_render(manager, state, before4, before6, dns_policy=NETWORK_DNS_CURRENT):
    rules, nat, ipv6 = network_rules(manager, state, dns_policy)
    tag = 'awg-network-' + manager.interface
    before4 = network_insert_table(before4, 'filter', tag + '-filter', rules)
    before4 = network_insert_table(before4, 'nat', tag + '-nat', nat)
    before6 = network_insert_table(before6, 'filter', tag + '-filter6', ipv6)
    return before4, before6


def network_snapshot(path, private=False):
    path = secure_path(Path(path))
    if not exists(path):
        return None
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'r') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1
                or info.st_mode & 0o022 or (private and stat.S_IMODE(info.st_mode) != 0o600)):
            fail('Network files must be root-owned regular files with safe permissions.')
        return (stream.read(), stat.S_IMODE(info.st_mode))


def network_write(path, value, expected):
    if network_snapshot(path) != expected:
        fail('A network file changed during the operation; retained.')
    if value is None:
        if expected is not None:
            os.unlink(path)
            sync_directory(path.parent)
        return
    text, mode = value
    secure_path(path)
    fd, temporary = tempfile.mkstemp(prefix='.awg-network-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        if network_snapshot(path) != expected:
            fail('A network file changed while staging its replacement.')
        if expected is None:
            os.link(temporary, path, follow_symlinks=False)
            os.unlink(temporary)
        else:
            os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if exists(temporary):
            os.unlink(temporary)


def network_firewall_order():
    for command, prefix in [('iptables', 'ufw'), ('ip6tables', 'ufw6')]:
        for chain in ('INPUT', 'FORWARD'):
            output = run(command, '-S', chain)
            required = '-A ' + chain + ' -j ' + prefix + '-before-' + chain.lower()
            seen = False
            for line in output.splitlines():
                if not line.startswith('-A ' + chain + ' '):
                    continue
                if line == required:
                    seen = True
                    break
                if line == '-A ' + chain + ' -j ' + prefix + '-before-logging-' + chain.lower():
                    continue
                fail('An earlier firewall rule could bypass this policy; review firewall chain order first.')
            if not seen:
                fail('Expected UFW entry chain is missing; no access-isolation claim was made.')


def network_preflight(manager, state):
    if 'Status: active' not in run('ufw', 'status').splitlines():
        fail('UFW must already be active; this operation does not enable or reset it.')
    default = network_snapshot(NETWORK_UFW_DEFAULT)
    if not default or not re.search(r'^\s*IPV6\s*=\s*yes\s*$', default[0], re.M):
        fail('UFW IPv6 filtering must already be enabled (IPV6=yes).')
    network_firewall_order()
    if state['mode'] == 'full':
        ufw_sysctl = network_snapshot(NETWORK_UFW_SYSCTL)
        if ufw_sysctl and re.search(r'^\s*net[./]ipv4[./]ip_forward\s*=\s*0\s*(?:#.*)?$', ufw_sysctl[0], re.M):
            fail('UFW sysctl explicitly disables IPv4 forwarding; reconcile that setting first.')
        if state['egress'] == manager.interface:
            fail('Public egress must differ from the AWG interface.')
        entries = json.loads(run('ip', '-j', '-4', 'address', 'show', 'dev', state['egress']))
        if len(entries) != 1 or not any(ipaddress.IPv4Address(a['local']).is_global for a in entries[0].get('addr_info', [])):
            fail('Select an existing public IPv4 egress interface.')
        defaults = json.loads(run('ip', '-j', '-4', 'route', 'show', 'default'))
        if not any(route.get('dev') == state['egress'] for route in defaults):
            fail('Selected public interface needs an existing default route; no host route is changed here.')
        for resolver in state['dns']:
            routes = json.loads(run('ip', '-j', '-4', 'route', 'get', resolver))
            if not routes or routes[0].get('dev') != state['egress']:
                fail('Choose DNS resolvers reachable through the selected public egress.')


def network_verify_rules(manager, state, dns_policy=NETWORK_DNS_CURRENT):
    rules, nat, ipv6 = network_rules(manager, state, dns_policy)
    for command, table, entries in [('iptables', 'filter', rules), ('iptables', 'nat', nat),
                                     ('ip6tables', 'filter', ipv6)]:
        for line in entries:
            run(command, '-t', table, '-C', *shlex.split(line)[1:])
    if state['mode'] == 'full' and run('sysctl', '-n', 'net.ipv4.ip_forward') != '1':
        fail('IPv4 forwarding did not remain enabled after firewall reload.')


def network_apply(manager, state, profile_changes=None, preview=False, confirm_action=True, removing=False, force=False,
                  dns_policy=NETWORK_DNS_CURRENT, apply_service=None, rollback_service=None, before_service=None,
                  expected_originals=None):
    profile_changes = profile_changes or {}
    # Use one reviewed policy throughout the transaction, including after its file changes.
    if dns_policy is NETWORK_DNS_CURRENT:
        dns_policy = copy.deepcopy(dns_state(manager)) if 'dns_state' in globals() else None
    if manager.runtime:
        manager.require_active()
    path, sysctl_path = network_paths(manager)
    originals = {p: network_snapshot(p, p == path or p in profile_changes)
                 for p in [NETWORK_UFW4, NETWORK_UFW6, path, sysctl_path, *profile_changes]}
    for p, expected in (expected_originals or {}).items():
        if p not in originals or originals[p] != expected:
            fail('A reviewed file changed before the network transaction; retained.')
    if originals[NETWORK_UFW4] is None or originals[NETWORK_UFW6] is None:
        fail('Both UFW before-rules files must already exist.')
    before4, before6 = network_render(manager, state, originals[NETWORK_UFW4][0], originals[NETWORK_UFW6][0], dns_policy)
    sysctl_text = '# Managed AWG Internet forwarding: ' + manager.interface + '\nnet.ipv4.ip_forward=1\n'
    if originals[sysctl_path] is not None and originals[sysctl_path][0] != sysctl_text:
        fail('The expected owned forwarding file contains other settings; retained.')
    changes = {NETWORK_UFW4: (before4, originals[NETWORK_UFW4][1]),
               NETWORK_UFW6: (before6, originals[NETWORK_UFW6][1]),
               path: None if removing else (network_text(state), 0o600),
               sysctl_path: (sysctl_text, 0o644) if state['mode'] == 'full' else None}
    changes.update({p: None if text is None else (text, 0o600) for p, text in profile_changes.items()})
    changes = {p: value for p, value in changes.items() if originals[p] != value}
    print('Network mode: ' + state['mode'] + '; access-controlled accounts: ' + str(len(state['access'])))
    print('Files to change: ' + str(len(changes)) + '. Stored profiles need re-export and client re-import.')
    if state['mode'] == 'full':
        print('IPv4 Internet via ' + state['egress'] + '; IPv6 is routed into the tunnel and dropped, not IPv6 Internet service.')
        print('This is not a client kill switch: local/more-specific routes and OS DNS behavior need client verification.')
    if preview:
        print('Preview only; no files or network state changed.')
        return
    if not changes and not force:
        print('Already configured; no changes made.')
        return
    network_preflight(manager, state)
    run('iptables-restore', '--test', data=before4)
    run('ip6tables-restore', '--test', data=before6)
    if confirm_action:
        confirm('Apply this scoped AWG policy? Keep separate SSH/console access. Restricted clients may lose access immediately.\nNo public interface default route, SSH rule, cloud firewall, or DNS server is changed.')
    manager.unchanged()
    for p in originals:
        if network_snapshot(p) != originals[p]:
            fail('A network file changed during review; no changes made.')
    forwarding = run('sysctl', '-n', 'net.ipv4.ip_forward')
    backup = Path(tempfile.mkdtemp(prefix=manager.interface + '-network-backup-', dir=manager.base))
    os.chmod(backup, 0o700)
    manifest = []
    for index, (p, value) in enumerate(originals.items()):
        record = {'path': str(p), 'mode': value[1] if value else None, 'file': None}
        if value is not None:
            name = str(index) + '.txt'
            atomic_write(backup / name, value[0])
            record['file'] = name
        manifest.append(record)
    atomic_write(backup / 'manifest.json', json.dumps({'files': manifest, 'ip_forward': forwarding}, indent=2) + '\n')
    touched = []
    service_attempted = False
    try:
        if before_service is not None:
            service_attempted = True
            before_service()
        for p, value in changes.items():
            touched.append(p)
            network_write(p, value, originals[p])
        run('ufw', 'reload')
        if state['mode'] == 'full':
            run('sysctl', '-w', 'net.ipv4.ip_forward=1')
        network_firewall_order()
        network_verify_rules(manager, state, dns_policy)
        if apply_service is not None:
            service_attempted = True
            apply_service()
        for p, value in changes.items():
            if network_snapshot(p) != value:
                fail('Network post-write verification failed.')
        print('Network policy saved. Private rollback snapshot: ' + str(backup))
        print('Verify the imported client, public egress IP, DNS routing, IPv6 blocking, and reboot persistence separately.')
    except BaseException:
        errors = []
        for p in reversed(touched):
            try:
                if network_snapshot(p) != originals[p]:
                    network_write(p, originals[p], changes[p])
            except BaseException:
                errors.append('file rollback')
        try:
            run('sysctl', '-w', 'net.ipv4.ip_forward=' + forwarding)
            run('ufw', 'reload')
        except BaseException:
            errors.append('network rollback')
        if service_attempted and rollback_service is not None:
            if errors:
                errors.append('service rollback skipped because restored files or firewall need review')
            else:
                try:
                    rollback_service()
                except BaseException:
                    errors.append('service rollback')
        if errors:
            print('Rollback needs review: ' + ', '.join(errors) + '; private snapshot: ' + str(backup), file=sys.stderr)
        raise


def network_configure(manager, mode=None, egress=None, dns=None, preview=False):
    state = network_state(manager)
    old = copy.deepcopy(state)
    private_dns = copy.deepcopy(dns_state(manager)) if 'dns_state' in globals() else None
    if mode is None:
        mode = prompt('Traffic mode (split/full) [' + state['mode'] + ']: ').strip() or state['mode']
    if mode not in ('split', 'full'):
        fail('Traffic mode must be split or full.')
    changes = {}
    if mode == 'full':
        defaults = json.loads(run('ip', '-j', '-4', 'route', 'show', 'default'))
        suggestion = state['egress'] or (defaults[0].get('dev', '') if defaults else '')
        egress = egress or prompt('Public Internet egress interface [' + suggestion + ']: ').strip() or suggestion
        valid_name(egress)
        dns = dns or prompt('IPv4 DNS resolver(s) [' + ', '.join(state['dns'] or ['1.1.1.1']) + ']: ').strip() or ', '.join(state['dns'] or ['1.1.1.1'])
        state.update(mode='full', egress=egress, dns=network_dns(dns))
        for name, client in manager.clients.items():
            text = manager.files[client['path']]
            if private_dns is not None:
                text = dns_profile_base(manager, name, text, private_dns)
            if old['mode'] == 'split':
                state['clients'][name] = dict(public=client['public'], **network_profile_fields(text))
            original = state['clients'].get(name)
            if not original or original['public'] != client['public']:
                fail('Missing original split fields for a stored client; profile was retained.')
            if old['mode'] == 'full':
                text = network_restore_fields(text, original)
            changes[client['path']] = network_full_profile(manager, str(client['address']), text, state)
    else:
        if old['mode'] == 'full':
            for name, client in manager.clients.items():
                original = state['clients'].get(name)
                if not original or original['public'] != client['public']:
                    fail('Original split profile fields are missing or belong to another client.')
                changes[client['path']] = network_restore_fields(manager.files[client['path']], original)
        state.update(mode='split', egress=None, dns=[], clients={})
    if private_dns is not None:
        for name, client in manager.clients.items():
            text = changes.get(client['path'])
            if text is None:
                text = dns_profile_base(manager, name, manager.files[client['path']], private_dns)
            changes[client['path']] = dns_overlay_profile(manager, name, client['public'], text, private_dns)
        changes[dns_path(manager)] = dns_text(private_dns)
        print('Private DNS remains active. Full-mode DNS settings are retained for use after private DNS is disabled.')
    network_apply(manager, state, changes, preview=preview)


def network_restore_fields(text, original):
    for section, name, source in [('interface', 'Address', 'address'), ('interface', 'DNS', 'dns'), ('peer', 'AllowedIPs', 'allowed')]:
        text = network_field(text, section, name, original[source])
    return text


def network_set_access(manager, name, rules=None, preview=False):
    valid_client_name(name)
    state = network_state(manager)
    if rules is None:
        print('Rules: IPv4CIDR:tcp|udp:PORT, IPv4CIDR:icmp, IPv4CIDR:any. inherit removes restrictions; deny blocks all.')
        rules = prompt('Space-separated access rules for ' + name + ': ').split()
    if isinstance(rules, str):
        rules = rules.split()
    if rules == ['inherit']:
        state['access'].pop(name, None)
    else:
        client = manager.selected(name)
        if not rules or len(rules) > 64:
            fail('Supply one to 64 rules, deny, or inherit.')
        rules = [] if rules == ['deny'] else sorted(set(network_rule(rule) for rule in rules))
        state['access'][name] = {'public': client['public'], 'address': str(client['address'].ip) + '/32', 'rules': rules}
        print('Unlisted IPv4 destinations/ports are denied, including private DNS. Permit its server IPv4 /32 on UDP/TCP 53 explicitly when needed.')
        print('IPv6 forwarding is blocked for this managed tunnel while a network policy is active.')
    network_apply(manager, state, preview=preview)


def network_reapply(manager, preview=False, confirm_action=True):
    network_apply(manager, network_state(manager), preview=preview, confirm_action=confirm_action, force=True)


def network_remove(manager, preview=False, confirm_action=True):
    state = network_state(manager)
    state.update(mode='split', egress=None, dns=[], clients={}, access={})
    network_apply(manager, state, preview=preview, confirm_action=confirm_action, removing=True, dns_policy=None)

"""Per-interface private DNS; embedded after network management."""

DNS_SYSTEMD = Path('/etc/systemd/system')
DNS_BINARY = Path('/usr/sbin/dnsmasq')
DNS_MAX_RECORDS = 100


def dns_path(manager):
    return manager.base / (manager.interface + '.dns.json')


def dns_unit_name(interface):
    return 'awg-dns-' + valid_name(interface) + '.service'


def dns_owned_paths(interface, base=Path('/etc/amnezia/amneziawg')):
    interface = valid_name(interface)
    return (Path(base) / (interface + '.dns.json'),
            Path(base) / (interface + '.dnsmasq.conf'), DNS_SYSTEMD / dns_unit_name(interface))


def dns_domain(value):
    if not isinstance(value, str):
        fail('DNS names must be ASCII fully qualified names.')
    name = value[:-1].lower() if value.endswith('.') else value.lower()
    labels = name.split('.')
    if (len(name) > 253 or len(labels) < 2 or not re.fullmatch(r'[a-z0-9.-]+', name)
            or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in labels)
            or labels[-1].isdigit()):
        fail('Use a fully qualified ASCII DNS name, without wildcards, URLs, or spaces.')
    return name


def dns_ipv4(value):
    if not isinstance(value, str):
        fail('DNS addresses must be IPv4 strings.')
    try:
        address = ipaddress.IPv4Address(value)
    except ipaddress.AddressValueError:
        fail('DNS addresses require four decimal octets, for example 1.1.1.1.')
    if address.is_unspecified or address.is_loopback or address.is_multicast or address.is_link_local or address.is_reserved:
        fail('Choose a unicast IPv4 address, not loopback, link-local, multicast, or reserved space.')
    return str(address)


def dns_listener(manager, address):
    address = dns_ipv4(address)
    if address != str(manager.address.ip):
        fail('Private DNS must listen on this AWG instance server IPv4 only.')
    return address


def dns_records(value):
    if isinstance(value, str):
        pairs = value.replace(',', ' ').split()
        result = {}
        for pair in pairs:
            if pair.count('=') != 1:
                fail('Enter DNS records as name=IPv4, separated by spaces or commas.')
            name, address = pair.split('=')
            name = dns_domain(name)
            if name in result:
                fail('Duplicate private DNS name.')
            result[name] = dns_ipv4(address)
    elif isinstance(value, dict):
        result = {}
        for name, address in value.items():
            normalized = dns_domain(name)
            if normalized != name or normalized in result:
                fail('Saved private DNS names must be unique canonical lowercase names.')
            result[name] = dns_ipv4(address)
    else:
        fail('Invalid private DNS records.')
    if not 1 <= len(result) <= DNS_MAX_RECORDS:
        fail('Choose one to ' + str(DNS_MAX_RECORDS) + ' private DNS records.')
    return dict(sorted(result.items()))


def dns_upstreams(values, address):
    if isinstance(values, str):
        values = values.replace(',', ' ').split()
    if not isinstance(values, list) or not 1 <= len(values) <= 3:
        fail('Choose one to three IPv4 upstream DNS resolvers.')
    result = [dns_ipv4(value) for value in values]
    if len(set(result)) != len(result) or address in result:
        fail('Upstream DNS resolvers must be distinct and must not point back to this DNS listener.')
    return result


def dns_text(state):
    return json.dumps(state, indent=2, sort_keys=True) + '\n'


def dns_check_route(text, address):
    config = parse_config(text)
    if len(config['peers']) != 1 or not any(ipaddress.IPv4Address(address) in route
            for route in addresses(config['peers'][0], 'AllowedIPs') if route.version == 4):
        fail('A stored client does not route the server DNS IPv4 through its AWG peer; fix its AllowedIPs first.')


def dns_validate_state(manager, state):
    if (not isinstance(state, dict) or set(state) != {'version', 'server_public', 'address', 'upstreams', 'records', 'clients'}
            or type(state['version']) is not int or state['version'] != 1
            or state['server_public'] != manager.server_public or state['address'] != str(manager.address.ip)
            or not isinstance(state['clients'], dict)):
        fail('Invalid private DNS metadata or server identity.')
    dns_listener(manager, state['address'])
    if state['records'] != dns_records(state['records']) or state['upstreams'] != dns_upstreams(state['upstreams'], state['address']):
        fail('Saved private DNS policy is not canonical.')
    if set(state['clients']) != set(manager.clients):
        fail('Private DNS metadata and stored client inventory differ.')
    for name, record in state['clients'].items():
        valid_client_name(name)
        client = manager.clients[name]
        if (not isinstance(record, dict) or set(record) != {'public', 'dns'} or record['public'] != client['public']
                or (record['dns'] is not None and (not isinstance(record['dns'], str)
                    or any(ord(c) < 32 or ord(c) == 127 for c in record['dns']) or len(record['dns']) > 2048))):
            fail('Invalid saved client DNS baseline or identity.')
        profile = manager.files[client['path']]
        if field(parse_config(profile)['interface'], 'DNS', None) != state['address']:
            fail('A stored client no longer uses its managed DNS address; review external edits first.')
        dns_check_route(profile, state['address'])
    return state


def dns_state(manager):
    path = dns_path(manager)
    if not exists(path):
        return None
    text = read_profile(path)
    if len(text) > 256 * 1024:
        fail('Private DNS metadata exceeds the size limit.')
    state = json.loads(text)
    dns_validate_state(manager, state)
    previous = manager.files.get(path)
    if previous is not None and previous != text:
        fail('Private DNS metadata changed during management.')
    manager.files[path] = text
    _, config_path, unit_path = dns_owned_paths(manager.interface, manager.base)
    for owned, expected in [(config_path, dns_render(manager, state)),
                            (unit_path, dns_unit(manager))]:
        # The shared systemd directory is normally 0755; its owned unit stays private.
        current = read_profile(owned, private_parent=False) if owned == unit_path else read_profile(owned)
        if current != expected:
            fail('Owned private DNS service/configuration differs from its saved policy; retained.')
        if owned in manager.files and manager.files[owned] != current:
            fail('Private DNS service/configuration changed during management.')
        manager.files[owned] = current
    return state


def dns_profile_base(manager, name, text, state=None):
    state = dns_state(manager) if state is None else state
    if state is None:
        return text
    record = state['clients'].get(name)
    if not record or record['public'] != manager.clients[name]['public']:
        fail('Missing original DNS baseline for this client.')
    return network_field(text, 'interface', 'DNS', record['dns'])


def dns_overlay_profile(manager, name, public, text, state):
    dns_check_route(text, state['address'])
    state['clients'][name] = {'public': public, 'dns': field(parse_config(text)['interface'], 'DNS', None)}
    return network_field(text, 'interface', 'DNS', state['address'])


def dns_new_client(manager, name, public, text, pending_changes):
    state = dns_state(manager)
    if state is None:
        return text
    text = dns_overlay_profile(manager, name, public, text, state)
    pending_changes[dns_path(manager)] = dns_text(state)
    return text


def dns_remove_client(manager, name, pending_changes):
    state = dns_state(manager)
    if state is not None:
        state['clients'].pop(name)
        pending_changes[dns_path(manager)] = dns_text(state)


def dns_render(manager, state):
    dns_listener(manager, state['address'])
    text = ('# Managed private AWG DNS: ' + manager.interface + '\n'
            'port=53\nbind-dynamic\n'
            'listen-address=' + state['address'] + '\nno-hosts\nno-resolv\nno-poll\n'
            'user=nobody\ngroup=nogroup\ncache-size=256\nlocal-ttl=0\nlog-facility=-\n')
    text += ''.join('server=' + address + '\n' for address in state['upstreams'])
    for name, address in state['records'].items():
        # Keep AAAA/HTTPS and subordinate queries inside the private zone, not public DNS.
        text += 'host-record=' + name + ',' + address + '\nlocal=/' + name + '/\n'
    return text


def dns_unit(manager):
    config = dns_owned_paths(manager.interface, manager.base)[1]
    awg = 'awg-quick@' + manager.interface + '.service'
    return ('# Managed private AWG DNS: ' + manager.interface + '\n'
            '[Unit]\nDescription=Private DNS for AWG ' + manager.interface + '\n'
            'Requires=' + awg + '\nAfter=' + awg + '\nPartOf=' + awg + '\nBindsTo=' + awg + '\n'
            '[Service]\nType=simple\nExecStart=' + str(DNS_BINARY) + ' --keep-in-foreground --conf-file='
            + json.dumps(str(config)) + ' --pid-file=\nRestart=on-failure\nRestartSec=2\n'
            'NoNewPrivileges=yes\nPrivateTmp=yes\nProtectHome=yes\nProtectSystem=strict\n'
            'ProtectKernelTunables=yes\nProtectKernelModules=yes\nProtectControlGroups=yes\n'
            'StandardOutput=null\nStandardError=null\n'
            '[Install]\nWantedBy=' + awg + ' multi-user.target\n')


def dns_validate(manager):
    state = dns_state(manager)
    paths = dns_owned_paths(manager.interface, manager.base)
    if state is None:
        if any(exists(p) for p in paths[1:]):
            fail('Private DNS service/configuration exists without owned metadata; retained for review.')
        return None
    for path, expected in [(paths[1], dns_render(manager, state)), (paths[2], dns_unit(manager))]:
        current = network_snapshot(path, private=True)
        if current != (expected, 0o600):
            fail('Owned private DNS service/configuration differs from its saved policy; retained.')
    return state


def dns_command(*args, required=True):
    result = subprocess.run(args, text=True, capture_output=True, timeout=60,
                            env={**os.environ, 'LC_ALL': 'C'})
    if required and result.returncode:
        fail('Private DNS command failed; command output suppressed: ' + str(args[0]))
    return result


def dns_service_state(interface):
    unit = dns_unit_name(interface)
    active = dns_command('systemctl', 'is-active', unit, required=False).stdout.strip()
    enabled = dns_command('systemctl', 'is-enabled', unit, required=False).stdout.strip()
    if active not in ('active', 'inactive', 'failed', 'unknown') or enabled not in ('enabled', 'disabled', 'not-found'):
        fail('Unexpected private DNS service state; existing services were retained.')
    return active, enabled


def dns_service_apply(manager, enabled):
    unit = dns_unit_name(manager.interface)
    dns_command('systemctl', 'daemon-reload')
    if enabled:
        dns_command('systemctl', 'enable', unit)
        # Restore stages DNS while AWG is stopped; its Wants dependency starts DNS later.
        if manager.runtime:
            dns_command('systemctl', 'restart', unit)
            dns_verify_listener(manager)
    else:
        dns_command('systemctl', 'stop', unit, required=False)
        dns_command('systemctl', 'disable', unit, required=False)
        active, enabled_state = dns_service_state(manager.interface)
        if active == 'active' or enabled_state == 'enabled':
            fail('The private DNS service did not stop and disable.')



def dns_verify_listener(manager):
    # Type=simple can report active before dnsmasq has bound its sockets.
    stable = 0
    for attempt in range(5):
        if dns_service_state(manager.interface) != ('active', 'enabled'):
            fail('The private DNS service did not remain active and enabled.')
        pid = dns_command('systemctl', 'show', '--property=MainPID', '--value', dns_unit_name(manager.interface)).stdout.strip()
        output = dns_command('ss', '-H', '-lntup', 'sport = :53').stdout
        protocols = set()
        for line in output.splitlines():
            parts = line.split()
            if len(parts) < 6 or parts[0] not in ('tcp', 'udp'):
                fail('Unexpected DNS socket inventory after startup.')
            pids = set(re.findall(r'pid=(\d+)', line))
            if pid.isdecimal() and int(pid) > 0 and pid in pids:
                address = parts[4].rsplit(':', 1)[0].strip('[]').split('%', 1)[0]
                if pids != {pid} or address != str(manager.address.ip):
                    fail('Private DNS opened an unexpected listener; rolling back.')
                protocols.add(parts[0])
        stable = stable + 1 if protocols == {'tcp', 'udp'} else 0
        if stable >= 2:
            return
        if attempt < 4:
            time.sleep(0.2)
    fail('Private DNS TCP and UDP listeners were not verified on the intended tunnel IPv4.')


def dns_service_restore(manager, old):
    unit = dns_unit_name(manager.interface)
    dns_command('systemctl', 'daemon-reload')
    if old[1] == 'enabled':
        dns_command('systemctl', 'enable', unit)
    else:
        dns_command('systemctl', 'disable', unit, required=False)
    if old[0] == 'active':
        dns_command('systemctl', 'restart', unit)
    else:
        dns_command('systemctl', 'stop', unit, required=False)
    active, enabled = dns_service_state(manager.interface)
    if (active == 'active') != (old[0] == 'active') or (enabled == 'enabled') != (old[1] == 'enabled'):
        fail('Private DNS service rollback needs manual review.')


def dns_stop(manager, disable=True):
    if dns_validate(manager) is None:
        return
    dns_command('systemctl', 'stop', dns_unit_name(manager.interface))
    if disable:
        dns_command('systemctl', 'disable', dns_unit_name(manager.interface))
    active, enabled = dns_service_state(manager.interface)
    if active == 'active' or (disable and enabled == 'enabled'):
        fail('Private DNS stop/disable verification failed.')


def dns_ports_available(manager, old):
    own_pid = None
    if old and dns_service_state(manager.interface)[0] == 'active':
        value = dns_command('systemctl', 'show', '--property=MainPID', '--value', dns_unit_name(manager.interface)).stdout.strip()
        if value.isdecimal() and int(value) > 0:
            own_pid = value
    output = dns_command('ss', '-H', '-lntup', 'sport = :53').stdout
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 6 or parts[0] not in ('tcp', 'udp'):
            fail('Unexpected DNS socket inventory; review port 53 before setup.')
        address = parts[4].rsplit(':', 1)[0].strip('[]')
        if address in ('*', '0.0.0.0', '::', str(manager.address.ip)):
            pids = set(re.findall(r'pid=(\d+)', line))
            if not own_pid or pids != {own_pid}:
                fail('Port 53 conflicts with another listener; existing DNS services were retained.')


def dns_binary_install():
    if not DNS_BINARY.is_file():
        # dnsmasq-base supplies the binary without enabling the global dnsmasq service.
        dns_command('apt-get', 'update')
        result = subprocess.run(['apt-get', 'install', '-y', '--no-install-recommends', 'dnsmasq-base'],
                                text=True, capture_output=True, timeout=300,
                                env={**os.environ, 'LC_ALL': 'C', 'DEBIAN_FRONTEND': 'noninteractive'})
        if result.returncode or not DNS_BINARY.is_file():
            fail('dnsmasq-base installation failed; any installed packages remain. No global DNS service was requested.')


def dns_check_config(manager, state):
    with tempfile.TemporaryDirectory(prefix=manager.interface + '-dns-check-', dir=manager.base) as directory:
        path = Path(directory) / 'dnsmasq.conf'
        atomic_write(path, dns_render(manager, state))
        dns_command(str(DNS_BINARY), '--test', '--conf-file=' + str(path))


def dns_show(manager):
    state = dns_validate(manager)
    if state is None:
        print('Private DNS: disabled for ' + manager.interface)
        return
    print('Private DNS: ' + state['address'] + ':53 on ' + manager.interface)
    print('Upstream resolvers: ' + ', '.join(state['upstreams']))
    for index, (name, address) in enumerate(state['records'].items(), 1):
        print(str(index) + ') ' + name + ' = ' + address)
    print('Connected clients use this DNS for all system DNS queries, not only private names.')


def dns_change(manager, state, *, preview=False, confirm_action=True):
    old = dns_validate(manager)
    paths = dns_owned_paths(manager.interface, manager.base)
    owned_originals = {p: network_snapshot(p, private=True) for p in paths}
    profiles = {}
    if state is not None:
        state = copy.deepcopy(state)
        for name, client in manager.clients.items():
            text = manager.files[client['path']]
            if old:
                text = dns_profile_base(manager, name, text, old)
            profiles[client['path']] = dns_overlay_profile(manager, name, client['public'], text, state)
        profiles.update({paths[0]: dns_text(state), paths[1]: dns_render(manager, state), paths[2]: dns_unit(manager)})
    else:
        if old is None:
            print('Private DNS is already disabled.')
            return
        profiles.update({client['path']: dns_profile_base(manager, name, manager.files[client['path']], old)
                         for name, client in manager.clients.items()})
        profiles.update({p: None for p in paths})
    print('Private DNS ' + ('enable/update' if state else 'disable') + ': ' + manager.interface)
    if state:
        print('All system DNS queries use the tunnel DNS while connected; unrelated names are forwarded upstream.')
        print('Private records also prevent public DNS fallback for those names and their subdomains.')
        print('VPC routes and destination permissions are separate: configure VPC access before opening private services.')
        print('Restricted accounts need explicit UDP and TCP 53 permission to ' + state['address'] + '/32 in Client access permissions.')
    print('When client DNS settings change, re-export and re-import the affected profiles; imported profiles are not updated remotely.')
    print('Record-only updates keep client profiles unchanged; cached DNS answers may take time to expire.')
    policy = network_state(manager)
    if preview:
        network_apply(manager, policy, profiles, preview=True, dns_policy=state, expected_originals=owned_originals)
        return
    service = dns_service_state(manager.interface)
    if old is None and (service[0] == 'active' or service[1] != 'not-found'):
        fail('A same-named DNS service already exists without owned metadata; retained.')
    if confirm_action:
        confirm('Apply this private DNS change? Public DNS records, server resolv.conf, hosts and unrelated services stay unchanged.\n'
                'If needed, dnsmasq-base and its dependencies will be installed and retained on later failure.\n'
                'DNS outages may affect all domain resolution on connected clients.')
    manager.unchanged()
    if state:
        dns_ports_available(manager, old)
        for address in state['upstreams']:
            local = {a.get('local') for entry in manager.local for a in entry.get('addr_info', [])}
            routes = json.loads(run('ip', '-j', '-4', 'route', 'get', address))
            if address in local or not routes or routes[0].get('dev') == manager.interface or routes[0].get('type') in ('local', 'blackhole', 'unreachable', 'prohibit'):
                fail('Upstream DNS must be reachable outside this AWG interface and must not be a local address.')
        dns_binary_install()
        dns_check_config(manager, state)
        dns_ports_available(manager, old)
    network_apply(manager, policy, profiles, confirm_action=False, dns_policy=state, force=True,
                  before_service=(lambda: dns_stop(manager, disable=True)) if state is None else None,
                  expected_originals=owned_originals,
                  apply_service=lambda: dns_service_apply(manager, state is not None),
                  rollback_service=lambda: dns_service_restore(manager, service))
    print('Private DNS settings saved. Real client DNS, VPC reachability and reboot behavior still require verification.')


def dns_configure(manager, preview=False):
    manager.require_active()
    old = dns_validate(manager)
    current_records = ' '.join(name + '=' + ip for name, ip in (old['records'].items() if old else []))
    while True:
        value = prompt('Private DNS records (name=IPv4, separated by spaces)' + (' [' + current_records + ']' if old else '') + ': ').strip() or current_records
        try:
            records = dns_records(value)
            break
        except ValueError as error:
            print('Invalid private DNS records: ' + str(error))
    current_upstreams = ', '.join(old['upstreams'] if old else ['1.1.1.1', '9.9.9.9'])
    while True:
        value = prompt('Upstream IPv4 DNS resolvers [' + current_upstreams + ']: ').strip() or current_upstreams
        try:
            upstreams = dns_upstreams(value, str(manager.address.ip))
            break
        except ValueError as error:
            print('Invalid upstream DNS resolvers: ' + str(error) + ' Press Enter to use the displayed defaults, or enter IPv4 addresses.')
    state = {'version': 1, 'server_public': manager.server_public, 'address': str(manager.address.ip),
             'upstreams': upstreams, 'records': records, 'clients': {}}
    dns_change(manager, state, preview=preview)


def dns_disable(manager, preview=False, confirm_action=True):
    dns_change(manager, None, preview=preview, confirm_action=confirm_action)


def dns_reapply(manager, preview=False, confirm_action=True):
    state = dns_validate(manager)
    if state is not None:
        if not preview and not DNS_BINARY.is_file():
            fail('Install dnsmasq-base before restoring/reapplying private DNS; this operation does not install packages.')
        dns_change(manager, state, preview=preview, confirm_action=confirm_action)

"""Private local operations; embedded after the account manager by the packager."""
import fcntl as ops_fcntl
import hashlib as ops_hashlib
import shutil as ops_shutil
from types import SimpleNamespace as OpsNamespace

OPS_BASE = Path('/etc/amnezia/amneziawg')
OPS_SYSTEMD = Path('/etc/systemd/system')
OPS_LIBEXEC = Path('/usr/local/libexec')
OPS_SYSCTL = Path('/etc/sysctl.d')
OPS_UFW = Path('/etc/ufw/before.rules')
OPS_LOCK = Path('/run/manage-amneziawg/setup.lock')
OPS_FORMAT = 'awg-private-snapshot-v1'
OPS_LIMIT = 4 * 1024 * 1024



class OpsHandoffChanged(ValueError):
    """The shared lock was released; snapshot rollback is no longer safe."""


class OpsWriteFailure(ValueError):
    def __init__(self, message, owned=None):
        super().__init__(message)
        self.owned = {} if owned is None else owned

def ops_command(*args, input=None, required=True):
    """Never return failed command stderr, which may include private configuration."""
    result = subprocess.run(args, input=input, text=True, capture_output=True,
                            env={**os.environ, 'LC_ALL': 'C'}, timeout=30)
    if required and result.returncode:
        fail('Operation command failed; output suppressed: ' + str(args[0]))
    return result


def ops_read(path):
    path = secure_path(Path(path))
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
        fail('An operation file is not a trusted private regular file.')
    if info.st_mode & 0o077 or info.st_size > OPS_LIMIT:
        fail('An operation file must have private permissions and a bounded size.')
    return path.read_text(), stat.S_IMODE(info.st_mode)


def ops_read_public(path):
    path = secure_path(Path(path))
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid() or info.st_mode & 0o022 or info.st_size > OPS_LIMIT:
        fail('An owned system file changed ownership, type, permissions, or size.')
    return path.read_text(), stat.S_IMODE(info.st_mode)



def ops_atomic(path, text, expected=None):
    path = secure_path(Path(path))
    current = ops_read_public(path) if exists(path) else None
    if (current[0] if current else None) != expected:
        fail('An operation file changed before staging.')
    fd, temporary = tempfile.mkstemp(prefix='.awg-operations-', dir=path.parent)
    published = False
    mode = current[1] if current else 0o600
    try:
        with os.fdopen(fd, 'w', newline='') as stream:
            os.fchmod(stream.fileno(), current[1] if current else 0o600)
            stream.write(text); stream.flush(); os.fsync(stream.fileno())
        again = ops_read_public(path)[0] if exists(path) else None
        if again != expected:
            fail('An operation file changed while staging.')
        if expected is None:
            os.link(temporary, path, follow_symlinks=False)
        else:
            os.replace(temporary, path)
        published = True
        sync_directory(path.parent)
    except BaseException:
        raise OpsWriteFailure('Atomic operation write failed; secret output suppressed.', {path: (text, mode)} if published else {}) from None
    finally:
        if exists(Path(temporary)):
            os.unlink(temporary)

def ops_dns_paths(interface):
    return set(dns_owned_paths(interface, base=OPS_BASE)) if 'dns_owned_paths' in globals() else set()


def ops_allowed(interface, path):
    interface = valid_name(interface)
    path = Path(path)
    fixed = {OPS_BASE / (interface + suffix) for suffix in ('.conf', '-client.conf', '.client-routes', '.accounts.json', '.network.json')}
    fixed |= {OPS_BASE / 'clients' / (interface + '.conf'), OPS_BASE / 'clients' / interface / 'metadata.json'}
    fixed |= {OPS_SYSCTL / ('90-' + tag + '.conf') for tag in ('awg-network-' + interface, 'awg-vpc-' + interface, 'awg-test-vpc')}
    fixed |= {OPS_LIBEXEC / ('awg-admin-' + interface) / 'manager.py',
              OPS_SYSTEMD / ('awg-expiry-' + interface + '.service'),
              OPS_SYSTEMD / ('awg-expiry-' + interface + '.timer'),
              OPS_SYSTEMD / ('awg-quick@' + interface + '.service.d') / '90-awg-expiry.conf'}
    fixed.update(ops_dns_paths(interface))
    if path in fixed:
        return True
    return (path.parent == OPS_BASE / 'clients' / interface and path.suffix == '.conf'
            and bool(re.fullmatch(CLIENT_NAME_PATTERN, path.stem)) and path.stem != 'initial')


def ops_manager(interface):
    return Manager(valid_name(interface), base=OPS_BASE)


def ops_unit_state(interface):
    unit = 'awg-quick@' + valid_name(interface) + '.service'
    active = ops_command('systemctl', 'is-active', unit, required=False).stdout.strip()
    enabled = ops_command('systemctl', 'is-enabled', unit, required=False).stdout.strip()
    if active not in ('active', 'inactive', 'failed', 'unknown') or enabled not in ('enabled', 'disabled', 'not-found'):
        fail('The selected unit is in a transitional or unsupported state; review it first.')
    return {'active': active == 'active', 'enabled': enabled == 'enabled'}


def ops_owned_paths(manager):
    paths = set(manager.files)
    for suffix in ('.client-routes', '.accounts.json', '.network.json'):
        path = OPS_BASE / (manager.interface + suffix)
        if exists(path):
            paths.add(path)
    if 'network_owned_paths' in globals():
        paths.update(path for path in network_owned_paths(manager.interface, base=OPS_BASE) if exists(path))
    if 'lifecycle_owned_paths' in globals():
        paths.update(lifecycle_owned_paths(manager.interface))
    if 'dns_validate' in globals():
        dns_validate(manager)
        paths.update(path for path in ops_dns_paths(manager.interface) if exists(path))
    for path in paths:
        if not ops_allowed(manager.interface, path):
            fail('An owned path falls outside the selected interface allowlist.')
    return sorted(paths, key=str)


def ops_vpc(manager):
    """Adopt legacy rules only when both the exact NAT rule and source subnet match."""
    if not exists(OPS_UFW):
        return None
    text, _ = ops_read_public(OPS_UFW)
    found = []
    rules = ops_command('ufw', 'show', 'added').stdout
    for tag in ('awg-vpc-' + manager.interface, 'awg-test-vpc'):
        begin, end = '# BEGIN ' + tag + '\n', '# END ' + tag + '\n'
        if begin not in text and end not in text:
            continue
        if text.count(begin) != 1 or text.count(end) != 1:
            fail('Legacy VPC markers are ambiguous; retained for review.')
        start, stop = text.index(begin), text.index(end) + len(end)
        if stop <= start:
            fail('Legacy VPC markers are reversed.')
        block = text[start:stop]
        lines = block[len(begin):-len(end)].splitlines()
        if len(lines) == 4 and lines[:2] == ['*nat', ':POSTROUTING ACCEPT [0:0]'] and lines[-1] == 'COMMIT':
            rule = lines[2]
        elif len(lines) == 1:
            rule = lines[0]
            prefix = text[:start]
            if prefix.rfind('*nat\n') <= prefix.rfind('COMMIT\n'):
                fail('Legacy VPC rule is outside a NAT table.')
        else:
            fail('Legacy VPC block contains unmanaged content; retained.')
        tokens = shlex.split(rule)
        if len(tokens) != 12 or tokens[:3] != ['-A', 'POSTROUTING', '-s'] or tokens[4] != '-d' or tokens[6] != '-o' or tokens[8:11] != ['-j', 'SNAT', '--to-source']:
            fail('Legacy VPC rule format differs from the script-owned format.')
        source = str(ipaddress.IPv4Network(tokens[3]))
        if source != str(manager.address.network):
            if tag == 'awg-test-vpc':
                continue
            fail('Legacy VPC source belongs to another interface.')
        target = str(ipaddress.IPv4Network(tokens[5]))
        out = valid_name(tokens[7])
        ipaddress.IPv4Address(tokens[11])
        ufw_rule = ['route', 'allow', 'in', 'on', manager.interface, 'out', 'on', out, 'from', source, 'to', target, 'comment', tag]
        normalized = []
        for line in rules.splitlines():
            if line.startswith('ufw '):
                parts = shlex.split(line)[1:]
                for key_name in ('from', 'to'):
                    if key_name in parts:
                        at = parts.index(key_name) + 1
                        if parts[at] != 'any':
                            parts[at] = str(ipaddress.IPv4Network(parts[at], strict=False))
                normalized.append(parts)
        if normalized.count(ufw_rule) != 1:
            fail('Legacy VPC firewall rule does not match its owned NAT block.')
        sysctl = OPS_SYSCTL / ('90-' + tag + '.conf')
        if exists(sysctl):
            settings = [l.replace(' ', '') for l in ops_read_public(sysctl)[0].splitlines() if l.strip() and not l.lstrip().startswith('#')]
            if settings != ['net.ipv4.ip_forward=1']:
                fail('Legacy VPC sysctl file contains unmanaged settings.')
        found.append({'tag': tag, 'block': block, 'rule': ufw_rule, 'sysctl': str(sysctl) if exists(sysctl) else None})
    if len(found) > 1:
        fail('Multiple legacy VPC policies require review before this operation.')
    return found[0] if found else None



def ops_validate_vpc(interface, vpc, source):
    if vpc is None:
        return
    if not isinstance(vpc, dict) or set(vpc) != {'tag', 'block', 'rule', 'sysctl'} or vpc['tag'] not in ('awg-vpc-' + interface, 'awg-test-vpc'):
        fail('Invalid legacy VPC snapshot metadata.')
    tag = vpc['tag']
    block = vpc['block']
    if not isinstance(block, str) or not block.startswith('# BEGIN ' + tag + '\n') or not block.endswith('# END ' + tag + '\n'):
        fail('Invalid legacy VPC snapshot markers.')
    lines = block.splitlines()[1:-1]
    if len(lines) == 4 and lines[:2] == ['*nat', ':POSTROUTING ACCEPT [0:0]'] and lines[-1] == 'COMMIT':
        lines = lines[2:3]
    if len(lines) != 1:
        fail('Legacy VPC snapshot contains unmanaged rules.')
    t = shlex.split(lines[0])
    if len(t) != 12 or t[:3] != ['-A', 'POSTROUTING', '-s'] or t[4] != '-d' or t[6] != '-o' or t[8:11] != ['-j', 'SNAT', '--to-source']:
        fail('Invalid legacy VPC snapshot rule.')
    if str(ipaddress.IPv4Network(t[3])) != source:
        fail('Legacy VPC snapshot source differs from the selected tunnel.')
    target = str(ipaddress.IPv4Network(t[5]))
    out = valid_name(t[7])
    ipaddress.IPv4Address(t[11])
    rule = ['route', 'allow', 'in', 'on', interface, 'out', 'on', out, 'from', source, 'to', target, 'comment', tag]
    if vpc['rule'] != rule or vpc['sysctl'] not in (None, str(OPS_SYSCTL / ('90-' + tag + '.conf'))):
        fail('Legacy VPC snapshot metadata differs from its narrow rule.')


def ops_vpc_apply(manager, desired):
    current = ops_vpc(manager)
    if current == desired:
        return
    before, mode = ops_read_public(OPS_UFW)
    after = before
    if current:
        after = after.replace(current['block'], '', 1)
    if desired:
        ops_validate_vpc(manager.interface, desired, str(manager.address.network))
        tag = desired['tag']
        if '# BEGIN ' + tag in after or '# END ' + tag in after:
            fail('A VPC marker collision requires manual review.')
        rule = next(l for l in desired['block'].splitlines() if l.startswith('-A '))
        block = '# BEGIN ' + tag + '\n' + rule + '\n# END ' + tag + '\n'
        lines = after.splitlines(keepends=True)
        starts = [i for i, line in enumerate(lines) if line.strip() == '*nat']
        if len(starts) > 1:
            fail('Multiple existing NAT tables require manual review.')
        if starts:
            end = next((i for i in range(starts[0] + 1, len(lines)) if lines[i].strip() == 'COMMIT'), None)
            if end is None or any(l.strip().startswith('*') for l in lines[starts[0] + 1:end]):
                fail('Existing NAT table is malformed.')
            after = ''.join(lines[:end]) + block + ''.join(lines[end:])
        else:
            after = '*nat\n:POSTROUTING ACCEPT [0:0]\n' + block + 'COMMIT\n' + after
    ops_atomic(OPS_UFW, after, before)
    OPS_UFW.chmod(mode)
    try:
        if current:
            ops_command('ufw', '--force', 'route', 'delete', *current['rule'][1:])
        if desired:
            ops_command('sysctl', '-w', 'net.ipv4.ip_forward=1')
            ops_command('ufw', *desired['rule'])
        ops_command('ufw', 'reload')
    except BaseException:
        ops_atomic(OPS_UFW, before, after)
        OPS_UFW.chmod(mode)
        if desired:
            ops_command('ufw', '--force', 'route', 'delete', *desired['rule'][1:], required=False)
        if current:
            ops_command('ufw', *current['rule'], required=False)
        ops_command('ufw', 'reload', required=False)
        raise


def ops_udp_rules(interface):
    rules = []
    for line in ops_command('ufw', 'show', 'added').stdout.splitlines():
        if not line.startswith('ufw '):
            continue
        rule = shlex.split(line)[1:]
        if rule[-2:] == ['comment', 'manage-awg-' + interface]:
            ops_validate_udp(interface, rule)
            rules.append(rule)
    return rules


def ops_validate_udp(interface, rule):
    if (not isinstance(rule, list) or len(rule) != 12 or not all(isinstance(v, str) for v in rule) or rule[:3] != ['allow', 'in', 'on']
            or rule[4:7] != ['proto', 'udp', 'to'] or rule[8] != 'port'
            or rule[10:] != ['comment', 'manage-awg-' + interface]):
        fail('An owned UDP rule has unexpected content; retained.')
    valid_name(rule[3]); ipaddress.IPv4Address(rule[7]); valid_port(rule[9])


def ops_backup(interface, destination=None, announce=True):
    manager = ops_manager(interface)
    manager.unchanged()
    vpc = ops_vpc(manager)
    paths = ops_owned_paths(manager)
    if vpc and vpc['sysctl']:
        paths.append(Path(vpc['sysctl']))
    contents = {}
    for path in sorted(set(paths), key=str):
        reader = ops_read if OPS_BASE in path.parents or OPS_LIBEXEC in path.parents else ops_read_public
        contents[path] = reader(path)
    if sum(len(value[0].encode()) for value in contents.values()) > 32 * OPS_LIMIT or len(contents) > 2000:
        fail('Snapshot size exceeds the bounded backup limit.')
    state = ops_unit_state(interface)
    if destination is None:
        parent = OPS_BASE / 'backups'
        if not exists(parent):
            secure_path(parent).mkdir(mode=0o700)
        secure_path(parent / '.check', private_parent=True)
        destination = Path(tempfile.mkdtemp(prefix=interface + '-', dir=parent))
    else:
        destination = secure_path(Path(destination), private_parent=True)
        if exists(destination):
            fail('Backup destination already exists; it was retained.')
        destination.mkdir(mode=0o700)
    records = []
    try:
        for index, (path, (text, mode)) in enumerate(contents.items()):
            blob = str(index) + '.private'
            ops_atomic(destination / blob, text)
            records.append({'path': str(path), 'blob': blob, 'sha256': ops_hashlib.sha256(text.encode()).hexdigest(), 'mode': mode})
        manifest = {'format': OPS_FORMAT, 'interface': interface, 'unit': state, 'files': records, 'vpc': vpc, 'udp': ops_udp_rules(interface)}
        ops_atomic(destination / 'manifest.json', json.dumps(manifest, indent=2) + '\n')
        manager.unchanged()
    except BaseException:
        print('Incomplete private snapshot retained at: ' + str(destination), file=sys.stderr)
        raise
    if announce:
        print('Private snapshot: ' + str(destination) + ' (contains credentials; keep private).')
    return destination


def dns_restore_preflight(interface, contents, base):
    """Validate DNS snapshot data and executable unit text before touching services."""
    if 'dns_owned_paths' not in globals():
        return
    owned = set(dns_owned_paths(interface, base=base))
    present = owned.intersection(contents)
    if not present:
        return
    if present != owned:
        fail('Private DNS snapshot is incomplete; configuration was retained.')
    if any(contents[path][1] != 0o600 for path in owned):
        fail('Private DNS snapshot files must have private permissions.')
    if base / (interface + '.network.json') not in contents:
        fail('Private DNS snapshot lacks its managed firewall policy.')
    server_path = base / (interface + '.conf')
    config = parse_config(contents[server_path][0])
    address = [value for value in addresses(config['interface'], 'Address', interface=True) if value.version == 4]
    if len(address) != 1:
        fail('Private DNS restore requires one server IPv4 address.')
    server_public = key(run('awg', 'pubkey', data=key(field(config['interface'], 'PrivateKey')) + '\n'))
    profiles = {}
    initial_paths = {base / (interface + '-client.conf'), base / 'clients' / (interface + '.conf')}
    for path, (text, mode) in contents.items():
        if path in initial_paths:
            name = 'initial'
        elif path.parent == base / 'clients' / interface and path.suffix == '.conf':
            name = valid_client_name(path.stem)
        else:
            continue
        if name in profiles:
            fail('Private DNS snapshot contains duplicate client identities.')
        profile = parse_config(text)
        if len(profile['peers']) != 1 or key(field(profile['peers'][0], 'PublicKey')) != server_public:
            fail('Private DNS snapshot client belongs to a different server.')
        public = key(run('awg', 'pubkey', data=key(field(profile['interface'], 'PrivateKey')) + '\n'))
        profiles[name] = {'path': path, 'public': public}
    candidate = OpsNamespace(interface=interface, base=base, address=address[0], server_public=server_public,
                             clients=profiles, files={path: value[0] for path, value in contents.items()})
    state = dns_validate_state(candidate, json.loads(contents[dns_path(candidate)][0]))
    _, config_path, unit_path = dns_owned_paths(interface, base=base)
    if contents[config_path][0] != dns_render(candidate, state) or contents[unit_path][0] != dns_unit(candidate):
        fail('Private DNS snapshot service/configuration differs from its validated policy.')


def ops_load_backup(interface, directory):
    interface = valid_name(interface)
    directory = secure_path(Path(directory))
    secure_path(directory / '.check', private_parent=True)
    manifest = json.loads(ops_read(directory / 'manifest.json')[0])
    if not isinstance(manifest, dict) or set(manifest) != {'format', 'interface', 'unit', 'files', 'vpc', 'udp'} or manifest['format'] != OPS_FORMAT or manifest['interface'] != interface:
        fail('Snapshot format or selected interface does not match.')
    unit = manifest['unit']
    if not isinstance(unit, dict) or set(unit) != {'active', 'enabled'} or any(type(v) is not bool for v in unit.values()):
        fail('Invalid snapshot service state.')
    records = manifest['files']
    if not isinstance(records, list) or not 1 <= len(records) <= 2000:
        fail('Invalid snapshot file inventory.')
    contents, blobs = {}, set()
    for record in records:
        if not isinstance(record, dict) or set(record) != {'path', 'blob', 'sha256', 'mode'}:
            fail('Invalid snapshot record.')
        if not isinstance(record['path'], str):
            fail('Invalid snapshot path type.')
        path = Path(record['path'])
        if not ops_allowed(interface, path) or path in contents or path != Path(os.path.normpath(path)):
            fail('Snapshot contains an unexpected or duplicate path.')
        blob = record['blob']
        if not isinstance(blob, str) or not re.fullmatch(r'[0-9]+\.private', blob) or blob in blobs:
            fail('Snapshot blob path is invalid or duplicated.')
        blobs.add(blob)
        mode = record['mode']
        if type(mode) is not int or mode not in (0o600, 0o644, 0o700, 0o755):
            fail('Invalid snapshot file permissions.')
        if (OPS_BASE in path.parents or OPS_LIBEXEC in path.parents) and mode not in (0o600, 0o700):
            fail('Private configuration has public snapshot permissions.')
        text, _ = ops_read(directory / blob)
        if ops_hashlib.sha256(text.encode()).hexdigest() != record['sha256']:
            fail('Snapshot integrity check failed.')
        if path.suffix == '.conf' and OPS_BASE in path.parents and path not in ops_dns_paths(interface):
            config = parse_config(text)
            if any(name in config['interface']['fields'] for name in ('PreUp', 'PostUp', 'PreDown', 'PostDown', 'SaveConfig')):
                fail('Automatic restore requires profiles without shell hooks or SaveConfig.')
        contents[path] = (text, mode)
    if OPS_BASE / (interface + '.conf') not in contents:
        fail('Snapshot lacks the selected server configuration.')
    if sum(len(text.encode()) for text, mode in contents.values()) > 32 * OPS_LIMIT:
        fail('Snapshot size exceeds the bounded restore limit.')
    server_config = parse_config(contents[OPS_BASE / (interface + '.conf')][0])
    server_v4 = [a for a in addresses(server_config['interface'], 'Address', interface=True) if a.version == 4]
    if len(server_v4) != 1:
        fail('Snapshot requires exactly one server IPv4 tunnel address.')
    ops_validate_vpc(interface, manifest['vpc'], str(server_v4[0].network))
    if not isinstance(manifest['udp'], list) or len(manifest['udp']) > 100:
        fail('Invalid snapshot UDP rule inventory.')
    for rule in manifest['udp']:
        ops_validate_udp(interface, rule)
    for path, (text, mode) in contents.items():
        if path.parent == OPS_SYSCTL:
            if path.name == '90-awg-network-' + interface + '.conf':
                if OPS_BASE / (interface + '.network.json') not in contents:
                    fail('Network sysctl snapshot lacks its network policy.')
            elif not manifest['vpc'] or manifest['vpc']['sysctl'] != str(path):
                fail('Legacy sysctl snapshot lacks matching VPC ownership.')
        if (OPS_SYSTEMD in path.parents or OPS_LIBEXEC in path.parents) and path not in ops_dns_paths(interface):
            if not text.startswith('# Managed by AWG account expiry: ' + interface + '\n'):
                fail('Expiry snapshot ownership marker is absent.')
    if 'dns_restore_preflight' in globals():
        dns_restore_preflight(interface, contents, base=OPS_BASE)
    return manifest, contents


def ops_current(path):
    return ops_read_public(path) if exists(path) else None


def ops_rollback_files(originals, owned):
    conflicts = []
    for path, value in reversed(list(owned.items())):
        original = originals.get(path)
        current = ops_current(path)
        if current == original:
            continue
        if current != value:
            conflicts.append(path)
            continue
        try:
            if original is None:
                path.unlink(); sync_directory(path.parent)
            else:
                ops_atomic(path, original[0], current[0] if current else None)
                path.chmod(original[1])
            owned[path] = original
        except BaseException:
            conflicts.append(path)
    return conflicts


def ops_write_files(contents, expected):
    owned = {}
    try:
        for path, value in contents.items():
            missing, parent = [], path.parent
            while not exists(parent):
                missing.append(parent); parent = parent.parent
            for directory in reversed(missing):
                secure_path(directory).mkdir(mode=0o700)
            before = expected.get(path)
            if ops_current(path) != before:
                fail('A selected file changed concurrently; retained.')
            if value is None:
                if before is not None:
                    path.unlink()
                    owned[path] = None
                    sync_directory(path.parent)
            else:
                text, mode = value
                ops_atomic(path, text, before[0] if before else None)
                owned[path] = (text, before[1] if before else 0o600)
                # Validate the published file before changing its permissions.
                if ops_current(path) != owned[path]:
                    fail('A published operation file changed concurrently; retained.')
                path.chmod(mode)
                owned[path] = value
        return owned
    except BaseException as error:
        if isinstance(error, OpsWriteFailure):
            owned.update(error.owned)
        conflicts = ops_rollback_files(expected, owned)
        raise OpsWriteFailure('File transaction failed; ' + ('concurrent changes retained; manual rollback required.' if conflicts else 'previous owned files restored.'), owned) from None

def ops_reapply(interface, manager):
    if exists(OPS_BASE / (interface + '.network.json')):
        if 'network_reapply' not in globals():
            fail('Network restoration support is missing.')
        network_reapply(manager, confirm_action=False)
    ops_command('systemctl', 'daemon-reload')
    if 'lifecycle_reapply' in globals():
        lifecycle_reapply(interface, confirm_action=False)
    if 'dns_reapply' in globals():
        dns_reapply(manager, confirm_action=False)


def ops_start_guard(interface):
    manager = ops_manager(interface)
    paths = set(ops_owned_paths(manager))
    paths.update(path for path in (OPS_UFW, OPS_UFW.with_name('before6.rules')) if exists(path))
    return {path: ops_current(path) for path in paths}


def ops_validate_lock():
    path = secure_path(OPS_LOCK, private_parent=True)
    info = path.lstat()
    descriptor = os.fstat(9)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1
            or stat.S_IMODE(info.st_mode) != 0o600
            or (info.st_dev, info.st_ino) != (descriptor.st_dev, descriptor.st_ino)):
        fail('The inherited operation lock does not match the trusted shared lock.')


def ops_set_unit(interface, state):
    unit = 'awg-quick@' + interface + '.service'
    ops_command('systemctl', 'enable' if state['enabled'] else 'disable', unit)
    if not state['active']:
        return
    ops_validate_lock()
    ops_manager(interface).enforce_expiry(noninteractive=True)
    before = ops_start_guard(interface)
    try:
        ops_fcntl.flock(9, ops_fcntl.LOCK_UN)
        try:
            # The dependency expiry service obtains this same lock in another process.
            ops_command('systemctl', 'start', unit)
        finally:
            ops_fcntl.flock(9, ops_fcntl.LOCK_EX)
        ops_validate_lock()
        after = ops_start_guard(interface)
        if after != before:
            raise OpsHandoffChanged('Managed state changed during service-start handoff; changes were retained. Review the private rollback snapshot manually.')
        manager = ops_manager(interface)
        manager.require_active()
        if 'dns_state' in globals() and dns_state(manager) is not None:
            if ops_command('systemctl', 'is-active', dns_unit_name(interface), required=False).stdout.strip() != 'active':
                raise OpsHandoffChanged('The restored private DNS service is not active; retain current files and review the rollback snapshot.')
        if ops_command('systemctl', 'is-active', unit, required=False).stdout.strip() != 'active':
            raise OpsHandoffChanged('Selected service did not start after lock handoff; current files were retained for review.')
    except OpsHandoffChanged:
        raise
    except BaseException:
        raise OpsHandoffChanged('Service-start handoff failed; concurrent state was retained. Automatic snapshot rollback was skipped.') from None


def ops_check_unit_owner(interface, manager):
    state = ops_unit_state(interface)
    if manager.runtime and not state['active']:
        fail('The live AWG interface is not owned by the active systemd unit; retain it and review manual startup first.')
    return state



def ops_assert_absent(interface):
    if runtime_state(interface) is not None:
        fail('An unowned live AWG interface exists without its saved profile; retained for review.')
    result = ops_command('ip', '-j', 'link', 'show', 'dev', interface, required=False)
    if result.returncode == 0 and json.loads(result.stdout or '[]'):
        fail('An existing network interface uses the restore name; retained for review.')


def ops_stop_checked(interface, has_profile=True):
    if has_profile and 'dns_stop' in globals():
        dns_stop(ops_manager(interface), disable=True)
    ops_command('systemctl', 'stop', 'awg-quick@' + interface + '.service')
    if has_profile:
        if ops_manager(interface).runtime is not None:
            fail('The AWG interface remains active after stopping its unit; configuration was retained.')
    else:
        ops_assert_absent(interface)

def ops_note_removed(owned, expected, paths):
    for path in paths:
        if path in expected and not exists(path):
            owned[path] = None
            expected[path] = None


def ops_network_expectation(manager):
    path = OPS_BASE / (manager.interface + '.network.json')
    if not exists(path) and not ('dns_state' in globals() and dns_state(manager) is not None):
        return None
    before = {p: ops_current(p) for p in (NETWORK_UFW4, NETWORK_UFW6)}
    if any(value is None for value in before.values()):
        fail('Network restore requires both existing UFW rules files.')
    state = network_state(manager)
    rendered = network_render(manager, state, before[NETWORK_UFW4][0], before[NETWORK_UFW6][0])
    after = {p: (text, before[p][1]) for p, text in zip((NETWORK_UFW4, NETWORK_UFW6), rendered)}
    return before, after


def ops_cleanup_restore_hooks(interface, owned, originals, network_expected, vpc_applied, old_vpc):
    # Do not detach policy metadata from a concurrently changed policy or configuration.
    for path, expected in owned.items():
        if ops_current(path) not in (expected, originals.get(path)):
            fail('Concurrent restore edits require manual policy cleanup.')
    if 'dns_stop' in globals() and exists(OPS_BASE / (interface + '.conf')):
        dns_stop(ops_manager(interface), disable=True)
    if network_expected:
        before, after = network_expected
        current = {path: ops_current(path) for path in before}
        if current == after:
            manager = ops_manager(interface)
            paths = network_owned_paths(interface, base=OPS_BASE)
            network_remove(manager, confirm_action=False)
            for path in paths:
                if not exists(path):
                    owned[path] = None
        elif current != before:
            fail('Concurrent firewall edits were retained; policy cleanup requires manual review.')
    if vpc_applied:
        ops_vpc_apply(ops_manager(interface), old_vpc)
    if 'lifecycle_remove' in globals():
        paths = lifecycle_owned_paths(interface)
        lifecycle_remove(interface, confirm_action=False)
        for path in paths:
            if not exists(path):
                owned[path] = None

def ops_dns_restore_guard(interface, old, contents):
    if not ops_dns_paths(interface).intersection(contents):
        return
    if 'DNS_BINARY' in globals() and not DNS_BINARY.is_file():
        fail('Install dnsmasq-base before restoring a private DNS snapshot; no services were changed.')
    if old is None or dns_validate(old) is None:
        active, enabled = dns_service_state(interface)
        if active not in ('inactive', 'unknown') or enabled != 'not-found':
            fail('A same-named unowned DNS service exists; no services or files were changed.')


def ops_restore(interface, backup, preview=False):
    interface = valid_name(interface)
    manifest, contents = ops_load_backup(interface, backup)
    old = ops_manager(interface) if exists(OPS_BASE / (interface + '.conf')) else None
    if old:
        ops_check_unit_owner(interface, old)
    ops_dns_restore_guard(interface, old, contents)
    old_vpc = ops_vpc(old) if old else None
    if old_vpc:
        saved_server = parse_config(contents[OPS_BASE / (interface + '.conf')][0])
        saved_v4 = [a for a in addresses(saved_server['interface'], 'Address', interface=True) if a.version == 4]
        if len(saved_v4) != 1 or saved_v4[0].network != old.address.network:
            fail('Restore changes the legacy VPC source subnet; remove that VPC policy before restoring. No service changes were made.')
    if old is None:
        ops_assert_absent(interface)
        leftovers = lifecycle_owned_paths(interface) if 'lifecycle_owned_paths' in globals() else []
        if leftovers or exists(OPS_BASE / (interface + '.network.json')) or any(exists(path) for path in ops_dns_paths(interface)):
            fail('Orphaned management resources require review before restoring a removed instance.')
    current_paths = ops_owned_paths(old) if old else []
    changes = {p: None for p in current_paths if p not in contents}
    changes.update(contents)
    for path in changes:
        if not ops_allowed(interface, path):
            fail('Restore path is outside the selected interface inventory.')
    expected = {p: ops_read_public(p) if exists(p) else None for p in changes}
    original_expected = dict(expected)
    print('Restore selected interface: ' + interface + '; files: ' + str(len(changes)) + '. Other services and global firewall files remain untouched.')
    for path, value in changes.items():
        print(('Remove: ' if value is None else 'Restore: ') + str(path))
    if preview:
        return
    confirm('Restore the private snapshot. The selected AWG tunnel will disconnect during this operation.')
    rollback = ops_backup(interface, announce=False) if old else None
    state = ops_unit_state(interface)
    unit = 'awg-quick@' + interface + '.service'
    modified = False
    owned = {}
    network_expected = None
    vpc_applied = False
    try:
        ops_stop_checked(interface, has_profile=old is not None)
        if old and 'network_remove' in globals() and exists(OPS_BASE / (interface + '.network.json')):
            network_paths_before = network_owned_paths(interface, base=OPS_BASE)
            network_remove(ops_manager(interface), confirm_action=False)
            ops_note_removed(owned, expected, network_paths_before)
        if 'lifecycle_remove' in globals():
            lifecycle_paths_before = lifecycle_owned_paths(interface)
            lifecycle_remove(interface, confirm_action=False)
            ops_note_removed(owned, expected, lifecycle_paths_before)
        owned.update(ops_write_files(changes, expected))
        modified = True
        restored = ops_manager(interface)
        ops_vpc_apply(restored, manifest['vpc'])
        vpc_applied = True
        network_expected = ops_network_expectation(restored)
        ops_reapply(interface, restored)
        for rule in manifest['udp']:
            ops_command('ufw', *rule)
        ops_set_unit(interface, manifest['unit'])
    except OpsHandoffChanged:
        print('Private rollback snapshot: ' + str(rollback), file=sys.stderr)
        raise
    except BaseException as error:
        if isinstance(error, OpsWriteFailure):
            owned.update(error.owned)
        try:
            ops_cleanup_restore_hooks(interface, owned, original_expected, network_expected, vpc_applied, old_vpc)
        except BaseException:
            fail('Restore failed; concurrent changes or incomplete policy cleanup were retained. Manual rollback review required at ' + str(rollback))
        conflicts = ops_rollback_files(original_expected, owned)
        if conflicts:
            fail('Restore failed; concurrent file changes retained. Manual rollback review required at ' + str(rollback))
        try:
            if old:
                previous_manager = ops_manager(interface)
                ops_reapply(interface, previous_manager)
                ops_vpc_apply(previous_manager, old_vpc)
                if rollback:
                    rollback_manifest, _ = ops_load_backup(interface, rollback)
                    for rule in rollback_manifest['udp']:
                        ops_command('ufw', *rule)
                ops_set_unit(interface, state)
            else:
                ops_command('systemctl', 'daemon-reload')
        except OpsHandoffChanged:
            print('Private rollback snapshot: ' + str(rollback), file=sys.stderr)
            raise
        except BaseException:
            fail('Restore failed; manual rollback review required at ' + str(rollback) + '. Secret output suppressed.')
        fail('Restore failed; previous managed state restored. Secret output suppressed.')
    print('Snapshot restored. Re-import exported profiles if endpoints or routes changed; client connectivity remains unverified.')
    if rollback:
        print('Rollback snapshot: ' + str(rollback))


def ops_uninstall(interface, preview=False):
    manager = ops_manager(interface)
    ops_check_unit_owner(interface, manager)
    paths = ops_owned_paths(manager)
    vpc = ops_vpc(manager)
    if vpc and vpc['sysctl']:
        paths.append(Path(vpc['sysctl']))
    print('Selected interface removal: ' + interface + '; owned files: ' + str(len(set(paths))) + '. Shared packages and other services stay installed.')
    print('Legacy generic UDP allow rules are retained unless separately verified; global forwarding stays unchanged.')
    for path in sorted(set(paths), key=str):
        print('Remove: ' + str(path))
    if preview:
        return
    confirm('Back up, stop, and remove only this AWG instance. Its connected clients will disconnect. Private rollback backups remain.')
    backup = ops_backup(interface, announce=False)
    originals = {p: ops_read_public(p) for p in paths}
    state = ops_unit_state(interface)
    udp = ops_udp_rules(interface)
    owned = {}
    expected = dict(originals)
    unit = 'awg-quick@' + interface + '.service'
    try:
        ops_stop_checked(interface)
        ops_command('systemctl', 'disable', unit)
        if 'network_remove' in globals() and exists(OPS_BASE / (interface + '.network.json')):
            network_paths_before = network_owned_paths(interface, base=OPS_BASE)
            network_remove(ops_manager(interface), confirm_action=False)
            ops_note_removed(owned, expected, network_paths_before)
        if 'lifecycle_remove' in globals():
            lifecycle_paths_before = lifecycle_owned_paths(interface)
            lifecycle_remove(interface, confirm_action=False)
            ops_note_removed(owned, expected, lifecycle_paths_before)
        if vpc:
            ops_vpc_apply(manager, None)
        for path in paths:
            if exists(path):
                if ops_read_public(path) != originals[path]:
                    fail('An owned file changed during removal; retained.')
                path.unlink()
                owned[path] = None
                sync_directory(path.parent)
        for rule in udp:
            ops_command('ufw', '--force', 'delete', *rule)
        ops_command('systemctl', 'daemon-reload')
    except BaseException:
        conflicts = ops_rollback_files(originals, owned)
        if conflicts:
            fail('Removal failed; concurrent changes retained. Manual rollback snapshot: ' + str(backup))
        try:
            previous = ops_manager(interface)
            ops_reapply(interface, previous)
            ops_vpc_apply(previous, vpc)
            for rule in udp:
                ops_command('ufw', *rule)
            ops_set_unit(interface, state)
        except OpsHandoffChanged:
            print('Private rollback snapshot: ' + str(backup), file=sys.stderr)
            raise
        except BaseException:
            fail('Removal failed; manual rollback review required. Private snapshot: ' + str(backup))
        fail('Removal failed; previous managed state restored. Private snapshot: ' + str(backup))
    print('Selected AWG instance removed. Rollback snapshot: ' + str(backup))
    print('Shared dependencies, global forwarding, generic UDP rules, and backup directories were retained.')


def ops_doctor(interface):
    """Output aggregates only; source addresses, public keys, and credentials stay private."""
    valid_name(interface)
    print('AWG diagnostic summary (identifiers and credentials redacted)')
    probes = [
        ('service', ('systemctl', 'is-active', 'awg-quick@' + interface + '.service')),
        ('boot enablement', ('systemctl', 'is-enabled', 'awg-quick@' + interface + '.service')),
        ('IPv4 forwarding', ('sysctl', '-n', 'net.ipv4.ip_forward')),
        ('UFW', ('ufw', 'status')),
        ('IPv4 routes', ('ip', '-j', '-4', 'route', 'show')),
        ('IPv6 routes', ('ip', '-j', '-6', 'route', 'show')),
        ('NAT inspection', ('iptables', '-t', 'nat', '-S')),
    ]
    for label, command in probes:
        try:
            result = ops_command(*command, required=False)
            value = 'available' if result.returncode == 0 else 'unavailable'
            if label == 'service': value = result.stdout.strip() if result.stdout.strip() in ('active', 'inactive', 'failed') else 'unknown'
            elif label == 'boot enablement': value = result.stdout.strip() if result.stdout.strip() in ('enabled', 'disabled') else 'unknown'
            elif label == 'IPv4 forwarding': value = 'enabled' if result.stdout.strip() == '1' else 'disabled or unknown'
            elif label == 'UFW': value = 'active' if result.stdout.startswith('Status: active') else 'inactive or unknown'
            elif 'routes' in label and result.returncode == 0:
                rows = json.loads(result.stdout)
                value = str(len(rows)) + ' routes' if isinstance(rows, list) else 'unexpected response'
            print(label + ': ' + value)
        except (OSError, ValueError, subprocess.SubprocessError):
            print(label + ': unavailable')
    try:
        manager = ops_manager(interface)
        manager.unchanged()
        print('Saved profile pairing: validated; stored clients: ' + str(len(manager.clients)))
        if 'dns_validate' in globals():
            dns = dns_validate(manager)
            if dns is None:
                print('Private DNS: not configured')
            else:
                service = ops_command('systemctl', 'is-active', dns_unit_name(interface), required=False).stdout.strip()
                service = service if service in ('active', 'inactive', 'failed') else 'unknown'
                print('Private DNS: configuration validated; service=' + service + '; records=' + str(len(dns['records'])))
        if manager.runtime:
            peers = manager.runtime['peers']
            timestamps = [p.get('handshake', 0) for p in peers.values()]
            print('Runtime peers: ' + str(len(peers)) + '; peers with any completed handshake: ' + str(sum(bool(t) for t in timestamps)))
            transfer = ops_command('awg', 'show', interface, 'transfer', required=False)
            rx = tx = 0
            if transfer.returncode == 0:
                for line in transfer.stdout.splitlines():
                    row = line.split()
                    if len(row) == 3 and row[1].isdigit() and row[2].isdigit():
                        rx += int(row[1]); tx += int(row[2])
                print('Tunnel byte counters: received=' + str(rx) + ', sent=' + str(tx) + ' (reset on runtime recreation).')
            listening = ops_command('ss', '-H', '-l', '-u', '-n', 'sport', '=', ':' + str(manager.runtime['port']), required=False)
            print('UDP listener: ' + ('present' if listening.returncode == 0 and listening.stdout.strip() else 'not observed'))
        else:
            print('Runtime: inactive; saved profiles only.')
    except (OSError, ValueError, subprocess.SubprocessError, KeyError):
        print('Saved/runtime consistency: failed or unavailable; details suppressed to protect configuration.')
    print('These are local observations, not an end-to-end health check. Cloud firewall, return path, client DNS, and client browsing remain unverified.')


def ops_health(interface):
    """Read-only local checks; private command output is never printed."""
    interface = valid_name(interface)
    results = []
    errors = (OSError, ValueError, TypeError, KeyError, IndexError, subprocess.SubprocessError)

    def report(label, status, message):
        results.append(status)
        print('[' + status + '] ' + label + ': ' + message)

    def read(*args, codes=(0,)):
        result = ops_command(*args, required=False)
        if result.returncode not in codes or len(result.stdout.encode()) > OPS_LIMIT:
            raise OSError('Inspection failed')
        return result.stdout.strip()

    def check(label, probe):
        try:
            status, message = probe()
            report(label, status, message)
        except errors:
            report(label, 'UNKNOWN', 'inspection unavailable or response not understood; private details suppressed.')

    def service(unit):
        value = read('systemctl', 'is-active', unit, codes=(0, 3, 4))
        if value == 'active':
            return 'PASS', 'active' + (' (active/exited is normal for awg-quick).' if unit.startswith('awg-quick@') else '.')
        if value in ('inactive', 'failed', 'unknown'):
            return 'FAIL', 'not active.'
        return 'UNKNOWN', 'service is transitioning or returned an unexpected state.'

    def boot(unit=None):
        value = read('systemctl', 'is-enabled', unit or 'awg-quick@' + interface + '.service', codes=(0, 1, 4))
        if value == 'enabled':
            return 'PASS', 'enabled at boot.'
        if value in ('disabled', 'static', 'indirect', 'enabled-runtime', 'masked', 'masked-runtime', 'not-found'):
            return 'WARN', 'not persistently enabled; review reboot behavior.'
        return 'UNKNOWN', 'boot enablement not established.'

    def link():
        rows = json.loads(read('ip', '-j', 'link', 'show'))
        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise ValueError('Unexpected link inventory')
        matches = [row for row in rows if row.get('ifname') == interface]
        if not matches:
            return 'FAIL', 'interface is absent.'
        if len(matches) != 1 or not isinstance(matches[0].get('flags'), list):
            raise ValueError('Unexpected link state')
        return ('PASS', 'administratively UP; operstate UNKNOWN is valid for a tunnel.') if 'UP' in matches[0]['flags'] else ('FAIL', 'interface is administratively down.')

    print('AWG health check: ' + interface + ' (read-only local observations)')
    check('AWG service', lambda: service('awg-quick@' + interface + '.service'))
    check('Boot enablement', boot)
    check('Tunnel interface', link)
    for directory in (OPS_BASE, OPS_BASE / 'clients', OPS_BASE / 'clients' / interface):
        def permissions(path=directory):
            if not exists(path):
                return ('FAIL' if path == OPS_BASE else 'SKIP'), str(path) + ' is absent.'
            info = path.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
                return 'FAIL', str(path) + ' needs trusted root ownership and mode 700; no permissions were changed.'
            return 'PASS', str(path) + ' has private directory permissions.'
        check('Profile directory', permissions)

    runtime_present = None
    port = None
    try:
        runtime_present = interface in read('awg', 'show', 'interfaces').split()
        report('AWG runtime', 'PASS' if runtime_present else 'FAIL', 'interface registered with AWG.' if runtime_present else 'interface is not registered with AWG.')
        if runtime_present:
            port = valid_port(read('awg', 'show', interface, 'listen-port'))
            report('Listen port', 'PASS', str(port) + '/udp configured in AWG.')
    except errors:
        report('AWG runtime / port', 'UNKNOWN', 'inspection unavailable; private details suppressed.')
    if port is not None:
        def udp_listener():
            rows = [line.split() for line in read('ss', '-H', '-l', '-u', '-n', 'sport', '=', ':' + str(port)).splitlines()]
            if any(len(row) < 5 or row[3].rsplit(':', 1)[-1] != str(port) for row in rows):
                raise ValueError('Unexpected UDP inventory')
            return ('PASS', 'local UDP socket observed; remote reachability is unverified.') if rows else ('FAIL', 'configured UDP socket not observed.')
        check('UDP listener', udp_listener)
    else:
        report('UDP listener', 'SKIP', 'no validated runtime port.')

    peers = None
    if runtime_present:
        def handshakes():
            nonlocal peers
            parsed = {}
            for line in read('awg', 'show', interface, 'latest-handshakes').splitlines():
                row = line.split()
                if len(row) != 2 or not row[1].isdecimal() or row[0] in parsed:
                    raise ValueError('Unexpected handshake inventory')
                parsed[key(row[0])] = int(row[1])
            peers = parsed
            if not peers:
                return 'SKIP', 'zero runtime peers; add or enable an account before client testing.'
            now = int(time.time())
            future = sum(value > now for value in peers.values())
            if future:
                return 'UNKNOWN', 'future handshake timestamps observed; check system time.'
            recent = sum(0 < value and now - value <= 180 for value in peers.values())
            never = sum(value == 0 for value in peers.values())
            stale = len(peers) - recent - never
            status = 'PASS' if recent == len(peers) else 'WARN'
            return status, 'peers=' + str(len(peers)) + ', recent (<=180s)=' + str(recent) + ', older=' + str(stale) + ', never=' + str(never) + '; idle clients may have old handshakes, not proof of failure.'
        check('Peer handshakes', handshakes)
        def transfer():
            counters = {}
            for line in read('awg', 'show', interface, 'transfer').splitlines():
                row = line.split()
                if len(row) != 3 or not all(value.isdecimal() for value in row[1:]) or row[0] in counters:
                    raise ValueError('Unexpected transfer inventory')
                counters[key(row[0])] = (int(row[1]), int(row[2]))
            if peers is None or set(counters) != set(peers):
                return 'UNKNOWN', 'peer inventory changed or was not validated; rerun the check.'
            if not counters:
                return 'SKIP', 'zero runtime peers.'
            return 'PASS', 'received=' + str(sum(v[0] for v in counters.values())) + ', sent=' + str(sum(v[1] for v in counters.values())) + ' bytes; cumulative counters reset on runtime recreation, not a traffic-rate test.'
        check('Transfer counters', transfer)
    else:
        report('Peer handshakes / transfer', 'SKIP', 'AWG runtime was not observed.')

    manager = None
    try:
        manager = ops_manager(interface)
        report('Saved profiles', 'PASS', 'validated; stored accounts=' + str(len(manager.clients)) + '.')
        if manager.runtime:
            if field(manager.server['interface'], 'SaveConfig').lower() == 'true':
                report('Saved/runtime pairing', 'UNKNOWN', 'SaveConfig=true prevents complete management validation; connectivity is not classified as failed.')
            else:
                try:
                    manager.require_active()
                    report('Saved/runtime pairing', 'PASS', 'addresses, listen ports and managed peers match.')
                except errors:
                    report('Saved/runtime pairing', 'FAIL', 'saved and live state did not pass validation; private details suppressed.')
        else:
            report('Saved/runtime pairing', 'SKIP', 'saved profiles only; runtime inactive.')
    except errors:
        report('Saved profiles', 'UNKNOWN', 'validation failed or inspection unavailable; check profile ownership/modes and saved/runtime consistency. Runtime checks above remain independent.')

    if manager is not None:
        try:
            policy = network_state(manager)
            vpc = ops_vpc(manager)
            report('Routing policy', 'PASS', policy['mode'] + ' policy validated; owned VPC policy ' + ('present.' if vpc else 'absent.'))
            if policy['mode'] == 'full' or vpc:
                def forwarding():
                    value = read('sysctl', '-n', 'net.ipv4.ip_forward')
                    if value not in ('0', '1'):
                        raise ValueError('Unexpected forwarding state')
                    return ('PASS', 'IPv4 forwarding enabled.') if value == '1' else ('FAIL', 'IPv4 forwarding disabled for configured routed access.')
                check('IPv4 forwarding', forwarding)
                egress = policy['egress'] if policy['mode'] == 'full' else vpc['rule'][vpc['rule'].index('out') + 2]
                def route_check():
                    if policy['mode'] == 'full':
                        routes = json.loads(read('ip', '-j', '-4', 'route', 'show', 'default'))
                    else:
                        target = ipaddress.IPv4Network(vpc['rule'][vpc['rule'].index('to') + 1])
                        local = {ipaddress.IPv4Address(item['local']) for entry in getattr(manager, 'local', [])
                                 for item in entry.get('addr_info', []) if item.get('family', 'inet') == 'inet'}
                        destination = next((address for address in target.hosts() if address not in local), None)
                        if destination is None:
                            return 'WARN', 'VPC target contains only local addresses; remote egress is not applicable.'
                        routes = json.loads(read('ip', '-j', '-4', 'route', 'get', str(destination)))
                    if not isinstance(routes, list) or any(not isinstance(row, dict) for row in routes):
                        raise ValueError('Unexpected routes')
                    found = any(row.get('dev') == egress and row.get('type', 'unicast') == 'unicast' for row in routes)
                    return ('PASS', 'expected egress route observed; target reachability unverified.') if found else ('FAIL', 'expected egress route not observed.')
                check('Configured egress route', route_check)
            else:
                report('IPv4 forwarding / egress', 'SKIP', 'no full-tunnel or owned VPC forwarding policy.')
        except errors:
            report('Routing policy', 'UNKNOWN', 'policy or firewall inspection not validated; no network changes made.')
        try:
            dns = dns_validate(manager)
            if dns is None:
                report('Private DNS', 'SKIP', 'not configured.')
            else:
                report('Private DNS configuration', 'PASS', 'owned policy and files validated; records=' + str(len(dns['records'])) + '.')
                check('Private DNS service', lambda: service(dns_unit_name(interface)))
                check('Private DNS boot enablement', lambda: boot(dns_unit_name(interface)))
                def dns_listener():
                    pid = read('systemctl', 'show', '--property=MainPID', '--value', dns_unit_name(interface))
                    if not pid.isdecimal() or int(pid) == 0:
                        return 'FAIL', 'no running resolver process.'
                    protocols = set()
                    for line in read('ss', '-H', '-lntup', 'sport = :53').splitlines():
                        parts = line.split()
                        if len(parts) < 6 or parts[0] not in ('tcp', 'udp'):
                            raise ValueError('Unexpected DNS listener inventory')
                        owners = set(re.findall(r'pid=(\d+)', line))
                        address = parts[4].rsplit(':', 1)[0].strip('[]').split('%', 1)[0]
                        if pid in owners:
                            if owners != {pid} or address != dns['address']:
                                return 'FAIL', 'resolver owns an unexpected listener.'
                            protocols.add(parts[0])
                        elif address == dns['address'] and not owners:
                            return 'UNKNOWN', 'DNS socket owner not visible.'
                    return ('PASS', 'owned TCP and UDP sockets on the tunnel IPv4; answers untested.') if protocols == {'tcp', 'udp'} else ('FAIL', 'owned TCP/UDP DNS listeners missing.')
                check('Private DNS listeners', dns_listener)
        except errors:
            report('Private DNS', 'UNKNOWN', 'configuration inspection not validated; details suppressed.')
    else:
        report('Routing policy / private DNS', 'UNKNOWN', 'saved configuration was not validated.')
    result = 1 if 'FAIL' in results else 2 if 'UNKNOWN' in results else 0
    print('Summary: ' + ', '.join(status + '=' + str(results.count(status)) for status in ('PASS', 'WARN', 'FAIL', 'UNKNOWN', 'SKIP')) + '; exit=' + str(result) + '.')
    print('Local checks only: effective NAT/ACL/UFW rules, cloud firewall, client return path, DNS answers, VPC application access and HTTPS remain unverified. Full-traffic mode checks the default egress, not a separate VPC route. Nothing was changed.')
    return result


def ops_export_qr(interface, name, destination=None):
    manager = ops_manager(interface)
    client = manager.selected(name)
    if destination is None or destination == '':
        encoder = ops_shutil.which('qrencode')
        if not encoder:
            fail('Optional command qrencode is not installed; text profile export remains available.')
        confirm('Display a QR code containing the complete client profile, including its private key, PSK, and header-protection key. '
                'Terminal scrollback and session recordings (including Jumpserver) may retain these secrets.')
        manager.unchanged()
        result = ops_command(encoder, '-t', 'ANSIUTF8', '-o', '-', input=manager.files[client['path']], required=False)
        if result.returncode or not result.stdout.strip() or len(result.stdout.encode()) > OPS_LIMIT:
            fail('QR encoder failed or returned unexpected output; private output was suppressed.')
        manager.unchanged()
        sys.stdout.write(result.stdout)
        return
    destination = secure_path(Path(destination), private_parent=True)
    if destination.suffix.lower() != '.png' or destination == OPS_BASE or OPS_BASE in destination.parents:
        fail('Export QR to a new .png file outside the managed configuration tree.')
    if exists(destination):
        fail('QR destination exists; it was retained.')
    encoder = ops_shutil.which('qrencode')
    if not encoder:
        fail('Optional command qrencode is not installed; configuration-file export remains available.')
    confirm('Create a private QR image containing the entire client profile, including its private key. Keep it off public pages and logs.')
    manager.unchanged()
    fd, temporary = tempfile.mkstemp(prefix='.awg-qr-', dir=destination.parent)
    temp_path = Path(temporary)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'wb') as output:
            result = subprocess.run([encoder, '-t', 'PNG', '-o', '-'], input=manager.files[client['path']].encode(),
                                    stdout=output, stderr=subprocess.PIPE, timeout=30)
        if result.returncode or temp_path.stat().st_size > OPS_LIMIT or temp_path.read_bytes()[:8] != b'\x89PNG\r\n\x1a\n':
            fail('QR encoder failed or returned unexpected output; private stderr was suppressed.')
        manager.unchanged()
        os.link(temp_path, destination)
        sync_directory(destination.parent)
    finally:
        temp_path.unlink(missing_ok=True)
    print('Private QR image: ' + str(destination))

"""Command-line integration, embedded after the management feature modules."""

_admin_original_dispatch = dispatch


def admin_preview(values):
    values = list(values)
    preview = bool(values and values[-1] == '--preview')
    if preview:
        values.pop()
    if '--preview' in values:
        fail('Place --preview once, at the end of the command.')
    return values, preview


def admin_dispatch(arguments):
    if len(arguments) < 2:
        fail('Supply an operation and an AmneziaWG interface; see --help.')
    operation, interface, *values = arguments
    valid_name(interface)
    legacy = {'--list-clients', '--add-client', '--export-client', '--remove-client', '--set-port'}
    if operation in legacy:
        return _admin_original_dispatch(arguments)
    if operation in {'--restore', '--uninstall', '--configure-network', '--set-access',
                     '--configure-dns', '--disable-dns'}:
        values, preview = admin_preview(values)
    else:
        preview = False
    counts = {
        '--doctor': (0, 0), '--health': (0, 0), '--backup': (0, 1), '--restore': (1, 1),
        '--uninstall': (0, 0), '--export-qr': (1, 2),
        '--disable-client': (1, 1), '--enable-client': (1, 1),
        '--set-expiry': (2, 2), '--enforce-expiry': (0, 0),
        '--configure-network': (0, 1), '--set-access': (1, 65),
        '--assert-vpc-compatible': (0, 0),
        '--check-server': (0, 0), '--check-empty-server': (0, 0),
        '--show-dns': (0, 0), '--configure-dns': (0, 0), '--disable-dns': (0, 0),
    }
    if operation not in counts or not counts[operation][0] <= len(values) <= counts[operation][1]:
        fail('Invalid management arguments; see --help for command forms.')
    if any(value.startswith('--') for value in values):
        fail('Unexpected option; see --help for command forms.')
    if operation == '--doctor':
        return ops_doctor(interface)
    if operation == '--health':
        return ops_health(interface)
    if operation == '--backup':
        return ops_backup(interface, values[0] if values else None)
    if operation == '--restore':
        return ops_restore(interface, values[0], preview=preview)
    if operation == '--uninstall':
        return ops_uninstall(interface, preview=preview)
    if operation == '--export-qr':
        return ops_export_qr(interface, values[0], values[1] if len(values) > 1 else None)
    if operation == '--enforce-expiry':
        return lifecycle_expiry_main(interface)
    if operation == '--assert-vpc-compatible':
        return network_assert_vpc_compatible(interface)
    if operation == '--configure-network':
        mode = values[0] if values else None
        if mode not in (None, 'split', 'full'):
            fail('Traffic mode must be split or full.')
        return network_configure(Manager(interface), mode=mode, preview=preview)
    if operation == '--set-access':
        valid_client_name(values[0])
        return network_set_access(Manager(interface), values[0],
                                  rules=values[1:] or None, preview=preview)
    manager = Manager(interface)
    if operation == '--show-dns':
        return dns_show(manager)
    if operation == '--configure-dns':
        return dns_configure(manager, preview=preview)
    if operation == '--disable-dns':
        return dns_disable(manager, preview=preview)
    if operation in {'--check-server', '--check-empty-server'}:
        manager.require_active()
        _, mtu = manager.profile_settings()
        if operation == '--check-empty-server':
            if manager.metadata is None or manager.clients or manager.disk_peers or manager.runtime['peers']:
                fail('New installation requires server metadata and zero client peers.')
            live_mtu = next(entry.get('mtu') for entry in manager.local if entry.get('ifname') == interface)
            if type(live_mtu) is not int or live_mtu != mtu or manager.metadata['mtu'] != live_mtu:
                fail('Saved management MTU and running tunnel MTU differ.')
        manager.unchanged()
        print('Saved server and runtime configuration validated; client connectivity was not tested.')
        return
    if operation == '--disable-client':
        return manager.disable_client(values[0])
    if operation == '--enable-client':
        return manager.enable_client(values[0])
    return manager.set_expiry(values[0], values[1])


def admin_choose_client(interface):
    manager = Manager(interface)
    names = sorted(manager.clients)
    if not names:
        print('No stored accounts for this instance. Add a client first.')
        return None
    print('\nChoose an existing account for ' + interface + ':')
    print('Number\tAccount\tVPN IPv4\tState')
    choices = {}
    for number, name in enumerate(names, 1):
        client = manager.clients[name]
        state = 'disabled' if client.get('disabled') else 'active'
        if client.get('expires_at') and lifecycle_expired(client['expires_at']):
            state += ' (expired)'
        print(str(number) + ')\t' + name + '\t' + str(client['address']) + '\t' + state)
        choices[str(number)] = name
    print('0) Back')
    while True:
        choice = prompt('Account number (0 to go back): ')
        if choice == '0':
            return None
        if choice in choices:
            manager.unchanged()
            return choices[choice]
        print('Choose an account number from 1 to ' + str(len(names)) + ', or 0 to go back.')


def admin_dns_menu(interface):
    while True:
        print('\nPrivate DNS (dnsmasq): ' + interface + '\n'
              '1) Show DNS settings\n2) Configure private DNS\n'
              '3) Disable private DNS\n0) Back')
        choice = prompt('Select: ')
        if choice == '0':
            return
        operations = {'1': '--show-dns', '2': '--configure-dns', '3': '--disable-dns'}
        if choice in operations:
            admin_dispatch([operations[choice], interface])
        else:
            print('Choose a menu number from 0 to 3.')


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else list(arguments)
    if os.geteuid() != 0 or sys.platform != 'linux':
        fail('Run management commands as root on the Linux AmneziaWG server.')
    if len(arguments) != 2 or arguments[0] != '--manage':
        result = admin_dispatch(arguments)
        return result if arguments[0] == '--health' else 0
    interface = valid_name(arguments[1])
    while True:
        print('\nAmneziaWG management: ' + interface + '\n'
              '1) Add client\n2) List clients\n3) Export client\n4) Remove client\n'
              '5) Change UDP port\n6) Configure VPC access\n'
              '7) Split / full traffic mode\n8) Client access permissions\n'
              '9) Disable client\n10) Enable client\n11) Client expiry\n'
              '12) Redacted diagnostics\n13) Private backup\n14) Restore backup\n'
              '15) Export client QR (terminal or PNG)\n16) Uninstall this interface\n'
              '17) Private DNS (dnsmasq)\n18) AWG health check\n0) Exit')
        choice = prompt('Select: ')
        if choice == '0':
            return 0
        if choice == '6':
            network_assert_vpc_compatible(interface)
            return 42  # The shell holds the lock while running the existing VPC wizard.
        simple = {'2': '--list-clients', '7': '--configure-network', '12': '--doctor', '18': '--health'}
        accounts = {'3': '--export-client', '4': '--remove-client', '8': '--set-access',
                    '9': '--disable-client', '10': '--enable-client', '11': '--set-expiry',
                    '15': '--export-qr'}
        if choice in accounts:
            account = admin_choose_client(interface)
            if account is None:
                continue
            values = [accounts[choice], interface, account]
            if choice == '3':
                values.append(prompt('Absolute destination .conf path (blank to display in terminal): '))
            elif choice == '11':
                values.append(prompt('Expiry UTC (YYYY-MM-DDTHH:MM:SSZ), or none: '))
            elif choice == '15':
                values.append(prompt('New absolute private .png path (blank for terminal QR): '))
            admin_dispatch(values)
        elif choice in simple:
            admin_dispatch([simple[choice], interface])
        elif choice == '1':
            admin_dispatch(['--add-client', interface, prompt('Account name: ')])
        elif choice == '5':
            admin_dispatch(['--set-port', interface, prompt('New UDP port: ')])
        elif choice == '13':
            destination = prompt('New absolute backup directory (blank for automatic): ')
            admin_dispatch(['--backup', interface] + ([destination] if destination else []))
        elif choice == '14':
            admin_dispatch(['--restore', interface, prompt('Absolute private backup directory: ')])
        elif choice == '16':
            admin_dispatch(['--uninstall', interface])
            return 0
        elif choice == '17':
            admin_dns_menu(interface)
        else:
            print('Choose a menu number from 0 to 18.')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    try:
        sys.exit(main())
    except (ValueError, OSError, InterruptedError, subprocess.TimeoutExpired, KeyError, StopIteration) as error:
        message = str(error) if isinstance(error, ValueError) else 'File, command, or runtime operation failed; secret output was suppressed.'
        print('ERROR: ' + message, file=sys.stderr)
        sys.exit(1)

PY_MANAGER
    python3 "$manager_dir/manager.py" "$@"
)

configure_vpc() {
    local vpc_command
    for vpc_command in awg ip ufw iptables iptables-restore sysctl systemctl python3; do
        command -v "$vpc_command" >/dev/null || { say "Required command missing: $vpc_command" >&2; return 1; }
    done
    python3 - "$@" <<'PY_VPC_WIZARD'
#!/usr/bin/env python3
"""Configure one directly connected IPv4 VPC policy for an existing AWG interface."""
import argparse
import base64
import datetime
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import sys
import tempfile

BASE = Path('/etc/amnezia/amneziawg')
BEFORE = Path('/etc/ufw/before.rules')
PRIVATE = tuple(ipaddress.IPv4Network(n) for n in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'))


def fail(message):
    raise ValueError(message)


def run(*args, data=None, check=True):
    result = subprocess.run(args, input=data, text=True, capture_output=True,
                            env={**os.environ, 'LC_ALL': 'C'}, timeout=30)
    if check and result.returncode:
        fail('Command failed: ' + ' '.join(args[:3]) + '; command output was suppressed.')
    return result.stdout.strip() if check else result


def valid_interface(value):
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,14}', value):
        fail('Use an existing interface name, at most 15 letters, digits, dots, underscores or hyphens.')
    return value


def target_network(value):
    try:
        network = ipaddress.IPv4Network(value, strict=True)
    except ValueError:
        fail('Enter an IPv4 host or a network-aligned IPv4 CIDR.')
    if not any(network.subnet_of(private) for private in PRIVATE):
        fail('The target must be inside an RFC1918 private network.')
    return str(network)


def read_secure(path, private=False, optional=False):
    path = Path(path)
    if not path.is_absolute() or path.resolve() != path:
        fail('Configuration paths must be canonical and free of symlinks: ' + str(path))
    for parent in path.parents:
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            fail('Configuration parent must be root-owned and not writable by other accounts: ' + str(parent))
    try:
        info = path.lstat()
    except FileNotFoundError:
        if optional:
            return None
        raise
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1
            or info.st_mode & (0o077 if private else 0o022)):
        fail('Configuration file has unexpected ownership, permissions or links: ' + str(path))
    return path.read_text()


def snapshot(path, private=False, optional=False):
    text = read_secure(path, private, optional)
    return (text, stat.S_IMODE(path.stat().st_mode) if text is not None else 0o600)


def atomic_write(path, text, mode=0o600):
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def sections(text):
    result = []
    current = None
    for index, raw in enumerate(text.splitlines(keepends=True)):
        line = raw.split('#', 1)[0].strip()
        if line.startswith('['):
            if line not in ('[Interface]', '[Peer]'):
                fail('Unexpected configuration section.')
            current = {'kind': line, 'fields': {}, 'lines': {}}
            result.append(current)
        elif '=' in line:
            if current is None:
                fail('A configuration field is outside a section.')
            key, value = (x.strip() for x in line.split('=', 1))
            # Only fields used here need uniqueness; unrelated AWG directives are preserved.
            if key in current['fields'] and key in ('PrivateKey', 'PublicKey', 'PresharedKey', 'AllowedIPs', 'Address'):
                fail('Duplicate configuration field: ' + key)
            current['fields'][key] = value
            current['lines'][key] = index
    return result


def update_client_routes(text, server_public, old_target, new_target):
    peers = [s for s in sections(text) if s['kind'] == '[Peer]' and s['fields'].get('PublicKey') == server_public]
    if len(peers) != 1 or 'AllowedIPs' not in peers[0]['fields']:
        fail('A stored client must have exactly one matching server peer with AllowedIPs.')
    peer = peers[0]
    old_values = [x.strip() for x in peer['fields']['AllowedIPs'].split(',')]
    try:
        canonical = [str(ipaddress.ip_network(x, strict=False)) for x in old_values]
    except ValueError:
        fail('A stored client has an invalid AllowedIPs entry.')
    values = [value for value, normalized in zip(old_values, canonical)
              if old_target == new_target or normalized != old_target]
    if new_target not in [str(ipaddress.ip_network(x, strict=False)) for x in values]:
        values.append(new_target)
    if values == old_values:
        return text
    lines = text.splitlines(keepends=True)
    index = peer['lines']['AllowedIPs']
    original = lines[index]
    prefix = original[:len(original) - len(original.lstrip())]
    comment = ' #' + original.split('#', 1)[1].rstrip('\r\n') if '#' in original else ''
    ending = '\r\n' if original.endswith('\r\n') else '\n'
    lines[index] = prefix + 'AllowedIPs = ' + ', '.join(values) + comment + ending
    return ''.join(lines)


def nat_rule(policy):
    return ('-A POSTROUTING -s {source} -d {target} -o {out} -j SNAT --to-source {snat}').format(**policy)


def block_span(text, tag):
    begin, end = '# BEGIN ' + tag, '# END ' + tag
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == begin]
    ends = [i for i, line in enumerate(lines) if line.rstrip('\r\n') == end]
    if not starts and not ends:
        return lines, None
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        fail('Malformed or duplicate managed NAT marker: ' + tag)
    return lines, (starts[0], ends[0])


def extract_nat(text, tag):
    lines, span = block_span(text, tag)
    if span is None:
        return None
    inner = ''.join(lines[span[0] + 1:span[1]]).strip().splitlines()
    if inner and inner[0] == '*nat':
        if len(inner) != 4 or inner[1] != ':POSTROUTING ACCEPT [0:0]' or inner[-1] != 'COMMIT':
            fail('The managed NAT table contains unexpected content; it was retained.')
        inner = inner[2:3]
    if len(inner) != 1:
        fail('The managed NAT block must contain exactly one owned rule.')
    if not any(line.strip() == '*nat' for line in lines[span[0] + 1:span[1]]):
        table = None
        for line in lines[:span[0]]:
            if line.strip().startswith('*'):
                table = line.strip()
            elif line.strip() == 'COMMIT':
                table = None
        if table != '*nat':
            fail('The managed NAT rule is outside the NAT table.')
    tokens = shlex.split(inner[0])
    if len(tokens) != 12 or tokens[0:3] != ['-A', 'POSTROUTING', '-s'] or tokens[4] != '-d' or tokens[6] != '-o' or tokens[8:11] != ['-j', 'SNAT', '--to-source']:
        fail('Unexpected managed NAT rule; it was retained.')
    policy = dict(source=target_network(tokens[3]), target=target_network(tokens[5]), out=valid_interface(tokens[7]), snat=str(ipaddress.IPv4Address(tokens[11])))
    return policy


def rewrite_nat(text, tag, rule):
    lines, span = block_span(text, tag)
    if sum(line.strip() == '*nat' for line in lines) > 1:
        fail('Multiple NAT tables need manual review before changing a VPC policy.')
    if span is not None:
        extract_nat(text, tag)
        body = lines[span[0] + 1:span[1]]
        existing_rule = next(i for i, line in enumerate(body) if line.startswith('-A POSTROUTING'))
        if body[existing_rule].rstrip('\r\n') == rule:
            return text
        body[existing_rule] = rule + '\n'
        return ''.join(lines[:span[0] + 1] + body + lines[span[1]:])
    nat_starts = [i for i, line in enumerate(lines) if line.strip() == '*nat']
    block = '# BEGIN ' + tag + '\n' + rule + '\n# END ' + tag + '\n'
    if len(nat_starts) > 1:
        fail('Multiple NAT tables need manual review before adding a VPC policy.')
    if nat_starts:
        start = nat_starts[0]
        open_owner = None
        for line in lines[:start]:
            if line.startswith('# BEGIN awg-'):
                open_owner = line.strip()[8:]
            elif open_owner and line.strip() == '# END ' + open_owner:
                open_owner = None
        if open_owner:
            fail('An existing table-wide VPC policy needs review before adding a second policy.')
        end = next((i for i in range(start + 1, len(lines)) if lines[i].strip() == 'COMMIT'), None)
        if end is None or any(line.strip().startswith('*') for line in lines[start + 1:end]):
            fail('The existing NAT table is incomplete.')
        return ''.join(lines[:end]) + block + ''.join(lines[end:])
    return ('# BEGIN ' + tag + '\n*nat\n:POSTROUTING ACCEPT [0:0]\n' + rule + '\nCOMMIT\n# END ' + tag + '\n' + text)


def ufw_rule(policy, tag):
    return ['route', 'allow', 'in', 'on', policy['interface'], 'out', 'on', policy['out'],
            'from', policy['source'], 'to', policy['target'], 'comment', tag]


def normalized_ufw_rules(text):
    rules = []
    for line in text.splitlines():
        if not line.startswith('ufw '):
            continue
        tokens = shlex.split(line)[1:]
        for key in ('from', 'to'):
            if key in tokens:
                index = tokens.index(key) + 1
                try:
                    tokens[index] = str(ipaddress.ip_network(tokens[index], strict=False))
                except ValueError:
                    pass
        rules.append(tokens)
    return rules


def prompt(label, default):
    with open('/dev/tty', 'r') as tty:
        print(label + (' [' + default + ']' if default else '') + ': ', end='', flush=True)
        answer = tty.readline()
    if not answer:
        fail('Input closed; no changes applied.')
    return answer.strip() or default



def choose_number(label, options, default=''):
    """Accept a displayed number or an exact value, preserving manual input."""
    if not options:
        fail('No eligible choices are available for ' + label + '.')
    values = [value for value, _ in options]
    for index, (_, description) in enumerate(options, 1):
        print(str(index) + ') ' + description)
    default_number = str(values.index(default) + 1) if default in values else ''
    while True:
        answer = prompt(label + ' (number or value)', default_number)
        if answer.isascii() and answer.isdecimal() and 1 <= int(answer) <= len(options):
            return values[int(answer) - 1]
        if answer in values:
            return answer
        print('Choose a displayed number or value.')


def vpc_interfaces(awg_interfaces, vpn_address):
    defaults = {route.get('dev') for route in json.loads(run('ip', '-j', '-4', 'route', 'show', 'default'))}
    entries = json.loads(run('ip', '-j', '-4', 'address', 'show'))
    result = {}
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        name = entry.get('ifname', '')
        if not isinstance(name, str):
            continue
        if name in defaults or name in awg_interfaces or name == 'lo' or 'UP' not in (entry.get('flags') or []):
            continue
        try:
            valid_interface(name)
        except ValueError:
            continue
        addresses = []
        for item in entry.get('addr_info') or []:
            if not isinstance(item, dict) or item.get('family') != 'inet':
                continue
            try:
                addresses.append(ipaddress.IPv4Interface(item['local'] + '/' + str(item['prefixlen'])))
            except (KeyError, TypeError, ValueError):
                continue
        addresses = [address for address in addresses
                     if any(address.network.subnet_of(private) for private in PRIVATE)
                     and not address.network.overlaps(vpn_address.network)]
        if addresses:
            result[name] = addresses
    return result


def choose_vpc_target(assigned, saved=None):
    networks = list(dict.fromkeys(str(address.network) for address in assigned))
    local_ips = {address.ip for address in assigned}
    def validate(value):
        target = target_network(value)
        network = ipaddress.IPv4Network(target)
        if not any(network.subnet_of(address.network) for address in assigned):
            fail('The complete target must be on the selected private interface subnet.')
        if network.prefixlen == 32 and network.network_address in local_ips:
            fail('Choose the remote server address, not this gateway address.')
        return target
    try:
        saved = validate(saved) if saved else None
    except ValueError:
        saved = None
    options = ([(saved, 'Keep saved target: ' + saved)] if saved else [])
    options += [('custom', 'Enter a remote server IPv4 or custom CIDR (single host uses /32)')]
    options += [(network, 'Entire connected subnet: ' + network + ' (all addresses, not one server)') for network in networks]
    print('Target means the remote server or network to access, not this gateway address.')
    print('Remote server addresses are not discovered from local interfaces; use the target server VPC address.')
    for index, (_, description) in enumerate(options, 1):
        print(str(index) + ') ' + description)
    while True:
        answer = prompt('3/4 VPC target choice (number or IPv4/CIDR)', '1')
        if answer.isascii() and answer.isdecimal() and 1 <= int(answer) <= len(options):
            answer = options[int(answer) - 1][0]
        if answer == 'custom':
            answer = prompt('Remote server IPv4 or network-aligned CIDR', '')
        try:
            return validate(answer)
        except ValueError as error:
            print(str(error))


def choose_vpc_policy(awg_interfaces, vpn_address, old):
    candidates = vpc_interfaces(awg_interfaces, vpn_address)
    print('Private exit interfaces below belong to this AWG gateway, not the remote target server.')
    options = [(name, name + ' | gateway ' + ', '.join(str(address.ip) for address in addresses)
                + ' | connected subnet ' + ', '.join(dict.fromkeys(str(address.network) for address in addresses)))
               for name, addresses in candidates.items()]
    default = old['out'] if old and old['out'] in candidates else next(iter(candidates)) if len(candidates) == 1 else ''
    outbound = choose_number('2/4 VPC exit interface', options, default)
    assigned = candidates[outbound]
    target = choose_vpc_target(assigned, old['target'] if old else None)
    matching = [address for address in assigned if ipaddress.IPv4Network(target).subnet_of(address.network)]
    sources = list(dict.fromkeys(str(address.ip) for address in matching))
    default = old['snat'] if old and old['snat'] in sources else sources[0] if len(sources) == 1 else ''
    snat = choose_number('4/4 Gateway SNAT IPv4', [(source, source + ' (local gateway on ' + outbound + ')') for source in sources], default)
    return target, outbound, snat


def route_details(target, source=None, incoming=None):
    command = ['ip', '-j', '-4', 'route', 'get', str(ipaddress.ip_network(target).network_address)]
    if source:
        command += ['from', source, 'iif', incoming]
    routes = json.loads(run(*command))
    if len(routes) != 1 or routes[0].get('type', 'unicast') != 'unicast':
        fail('The target needs one unicast route.')
    return routes[0]


def interface_addresses(interface):
    entries = json.loads(run('ip', '-j', '-4', 'address', 'show', 'dev', interface))
    if len(entries) != 1 or 'UP' not in entries[0].get('flags', []):
        fail('The selected interface must exist and be up.')
    return [ipaddress.IPv4Interface(x['local'] + '/' + str(x['prefixlen'])) for x in entries[0]['addr_info'] if x.get('family') == 'inet']


def validate_route(policy, vpn_address):
    target = ipaddress.IPv4Network(policy['target'])
    vpc_addresses = interface_addresses(policy['out'])
    match = [a for a in vpc_addresses if str(a.ip) == policy['snat'] and target.subnet_of(a.network)]
    if not match or not any(match[0].network.subnet_of(n) for n in PRIVATE):
        fail('The SNAT address and complete target must be on the selected private VPC interface subnet.')
    if target.overlaps(vpn_address.network) or policy['out'] == policy['interface']:
        fail('VPC and AWG networks and interfaces must be distinct.')
    defaults = json.loads(run('ip', '-j', '-4', 'route', 'show', 'default'))
    if policy['out'] in {r.get('dev') for r in defaults}:
        fail('Select the private VPC interface, not a default-route interface.')
    if target.prefixlen == 32 and target.network_address == ipaddress.IPv4Address(policy['snat']):
        fail('Choose a remote VPC target, not this gateway SNAT address.')
    first = target.network_address + (1 if target.prefixlen < 31 else 0)
    last = target.broadcast_address - (1 if target.prefixlen < 31 else 0)
    if first == ipaddress.IPv4Address(policy['snat']):
        first += 1
    if last == ipaddress.IPv4Address(policy['snat']):
        last -= 1
    route = route_details(str(first) + '/32')
    if route.get('dev') != policy['out'] or route.get('gateway') or route.get('prefsrc', route.get('src')) != policy['snat']:
        fail('The existing route must go directly through the selected VPC interface and SNAT address.')
    # Check the last address too so a more-specific route does not silently redirect the far end.
    end = route_details(str(last) + '/32')
    if end.get('dev') != policy['out'] or end.get('gateway'):
        fail('The entire target must use the directly connected VPC route.')
    routes = json.loads(run('ip', '-j', '-4', 'route', 'show', 'table', 'all'))
    for route in routes:
        if route.get('dst', 'default') == 'default' or route.get('type') in ('local', 'broadcast'):
            continue
        network = ipaddress.IPv4Network(route['dst'], strict=False)
        if network.overlaps(target) and network.prefixlen >= target.prefixlen and (route.get('dev') != policy['out'] or route.get('gateway')):
            fail('A conflicting more-specific route intersects the selected target.')


def verify_forward_routes(policy):
    target = ipaddress.IPv4Network(policy['target'])
    first = target.network_address + (1 if target.prefixlen < 31 else 0)
    last = target.broadcast_address - (1 if target.prefixlen < 31 else 0)
    probes = {str(a) + '/32' for a in (first, last) if str(a) != policy['snat']}
    source_network = ipaddress.IPv4Network(policy['source'])
    for line in run('awg', 'show', policy['interface'], 'allowed-ips').splitlines():
        fields = line.split(None, 1)
        if len(fields) != 2:
            fail('Unexpected active peer AllowedIPs output.')
        for value in fields[1].replace(',', ' ').split():
            if value == '(none)':
                continue
            network = ipaddress.ip_network(value, strict=True)
            if network.version != 4 or not network.overlaps(source_network):
                continue
            if network.prefixlen != 32 or not network.subnet_of(source_network):
                fail('VPC forwarding expects client IPv4 /32 peers inside the AWG subnet.')
            for target_probe in probes:
                route = route_details(target_probe, str(network.network_address), policy['interface'])
                if route.get('dev') != policy['out'] or route.get('gateway'):
                    fail('A client-source forwarding lookup does not use the direct VPC route.')


def admin_snapshot(path):
    # A missing sidecar still participates in the confirmation race check.
    return snapshot(path, private=True) if path.exists() or path.is_symlink() else (None, 0o600)


def metadata_key(value):
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        fail('Invalid account key encoding; key values were suppressed.')
    if len(raw) != 32 or not any(raw) or base64.b64encode(raw).decode() != value:
        fail('Invalid account key encoding; key values were suppressed.')
    return value


def disabled_peer(record):
    text = record['peer']
    if not isinstance(text, str) or len(text) > 16384:
        fail('Invalid saved disabled-peer record.')
    parsed = sections(text)
    if len(parsed) != 1 or parsed[0]['kind'] != '[Peer]':
        fail('Expected one saved disabled Peer section.')
    fields = parsed[0]['fields']
    if set(fields) - {'PublicKey', 'PresharedKey', 'AllowedIPs', 'PersistentKeepalive', 'Endpoint', 'AdvancedSecurity'}:
        fail('Unexpected disabled-peer fields.')
    if metadata_key(fields.get('PublicKey')) != record['public']:
        fail('Disabled-peer identity differs from lifecycle metadata.')
    if fields.get('PresharedKey'):
        metadata_key(fields['PresharedKey'])
    allowed = [ipaddress.ip_network(value.strip(), strict=True) for value in fields.get('AllowedIPs', '').split(',')]
    if not allowed or any(value.prefixlen != value.max_prefixlen for value in allowed):
        fail('Disabled accounts require individual host AllowedIPs.')
    return fields, {str(value) for value in allowed}


def account_records(text, public, peers):
    if text is None:
        return {}
    data = json.loads(text)
    if (not isinstance(data, dict) or set(data) != {'version', 'server_public', 'accounts'}
            or type(data['version']) is not int or data['version'] != 1 or data['server_public'] != public
            or not isinstance(data['accounts'], dict)):
        fail('Invalid account lifecycle metadata.')
    identities = set()
    for name, record in data['accounts'].items():
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,14}', name):
            fail('Invalid account name in lifecycle metadata.')
        if (not isinstance(record, dict) or set(record) != {'public', 'disabled', 'expires_at', 'peer'}
                or type(record['disabled']) is not bool):
            fail('Invalid account lifecycle record.')
        identity = metadata_key(record['public'])
        if identity in identities:
            fail('Duplicate account identity in lifecycle metadata.')
        identities.add(identity)
        expiry = record['expires_at']
        if expiry is not None:
            if not isinstance(expiry, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', expiry):
                fail('Invalid saved account expiry.')
            datetime.datetime.strptime(expiry, '%Y-%m-%dT%H:%M:%SZ')
        if (identity in peers) == record['disabled']:
            fail('Account lifecycle state differs from active server peers.')
        if record['disabled']:
            disabled_peer(record)
        elif record['peer'] is not None:
            fail('An active account must not retain a disabled-peer record.')
    return data['accounts']


def admin_metadata(interface, public, peers):
    paths = [BASE / (interface + suffix) for suffix in ('.accounts.json', '.network.json')]
    snapshots = {path: admin_snapshot(path) for path in paths}
    network_text = snapshots[paths[1]][0]
    if network_text is not None:
        network = json.loads(network_text)
        if (not isinstance(network, dict)
                or set(network) != {'version', 'server_public', 'mode', 'egress', 'dns', 'clients', 'access'}
                or type(network['version']) is not int or network['version'] != 1
                or network['server_public'] != public or network['mode'] not in ('split', 'full')
                or not isinstance(network['clients'], dict) or not isinstance(network['access'], dict)):
            fail('Invalid network policy metadata; existing profiles were retained.')
        if network['mode'] == 'full':
            fail('Switch network mode to split before changing VPC routes; full-mode profiles were retained.')
        if network['egress'] is not None or network['dns'] != []:
            fail('Split mode must not retain an Internet egress policy.')
    return account_records(snapshots[paths[0]][0], public, peers), snapshots


def verify_admin_snapshots(snapshots):
    for path, expected in snapshots.items():
        if path.name.endswith(('.accounts.json', '.network.json')) and admin_snapshot(path) != expected:
            fail('Account or network policy changed during confirmation; retry.')


def collect_clients(server_public, peers, interface, accounts=None):
    accounts = accounts or {}
    candidates = sorted((BASE / 'clients').glob('*.conf')) if (BASE / 'clients').exists() else []
    named_dir = BASE / 'clients' / interface
    if named_dir.exists() or named_dir.is_symlink():
        info = named_dir.lstat()
        if named_dir.resolve() != named_dir or not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
            fail('Named client directory must be root-owned, private and free of symlinks.')
        candidates += sorted(named_dir.glob('*.conf'))
    candidates += sorted(BASE.glob('*-client.conf'))
    found, accounted = {}, set()
    identities = {record['public']: name for name, record in accounts.items()}
    for path in candidates:
        text, mode = snapshot(path, private=True)
        parsed = sections(text)
        if not any(s['kind'] == '[Peer]' and s['fields'].get('PublicKey') == server_public for s in parsed):
            continue
        interfaces = [s for s in parsed if s['kind'] == '[Interface]']
        if len(interfaces) != 1 or 'PrivateKey' not in interfaces[0]['fields']:
            fail('A matching client profile is malformed: ' + str(path))
        public = run('awg', 'pubkey', data=interfaces[0]['fields']['PrivateKey'] + '\n')
        name = path.stem if path.parent == named_dir else 'initial' if path in (
            BASE / 'clients' / (interface + '.conf'), BASE / (interface + '-client.conf')) else None
        account = accounts.get(name)
        if public in identities and identities[public] != name:
            fail('Account metadata and stored client name differ: ' + str(path))
        if account:
            if account['public'] != public or name in accounted or (public in peers) == account['disabled']:
                fail('Stored client identity or state differs from lifecycle metadata: ' + str(path))
            accounted.add(name)
        if account and account['disabled']:
            saved, allowed = disabled_peer(account)
            client_peers = [s for s in parsed if s['kind'] == '[Peer]']
            if len(client_peers) != 1 or client_peers[0]['fields'].get('PublicKey') != server_public:
                fail('A disabled client must contain exactly one matching server Peer.')
            if (client_peers[0]['fields'].get('PresharedKey') or None) != (saved.get('PresharedKey') or None):
                fail('A disabled client PSK differs from its saved peer; key values were suppressed.')
            addresses = [ipaddress.ip_interface(value.strip()) for value in interfaces[0]['fields'].get('Address', '').split(',')]
            client_hosts = {str(value.ip) + '/' + str(value.max_prefixlen) for value in addresses}
            if len([value for value in addresses if value.version == 4]) != 1 or client_hosts != allowed:
                fail('A disabled client address differs from its saved peer AllowedIPs.')
        elif public not in peers:
            fail('A matching client profile is not an active server peer: ' + str(path))
        found[path] = (text, mode)
    if set(accounts) - accounted:
        fail('Account metadata references a missing stored profile.')
    # A fresh server may store route policy before its first named client is added.
    if not found and peers:
        fail('No matching stored client profiles were found; export them on this server before configuring VPC routes.')
    return found


def runtime_fingerprint(interface):
    return (hashlib.sha256(run('awg', 'showconf', interface).encode()).hexdigest(),
            run('systemctl', 'show', 'awg-quick@' + interface, '--property=ActiveEnterTimestamp', '--value'))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('interface', nargs='?')
    parser.add_argument('--preview', action='store_true', help='Read-only preview using saved policy or interactive input.')
    args = parser.parse_args(argv)
    if os.geteuid() != 0 or sys.platform != 'linux':
        fail('Run on the existing Linux AWG server as root.')
    if run('ufw', 'status').splitlines()[0] != 'Status: active':
        fail('UFW must already be active; this wizard does not enable or reset it.')
    available = run('awg', 'show', 'interfaces').split()
    if not available:
        fail('Create and activate an AWG interface before configuring VPC access.')
    print('Active AWG interfaces: ' + ', '.join(available))
    interface = valid_interface(args.interface or choose_number(
        '1/4 AWG interface', [(name, name) for name in available], available[0] if len(available) == 1 else ''))
    if interface not in available:
        fail('Choose an active AWG interface.')
    server_path = BASE / (interface + '.conf')
    server_snapshot = snapshot(server_path, private=True)
    server_sections = sections(server_snapshot[0])
    server_interface = [s for s in server_sections if s['kind'] == '[Interface]']
    if len(server_interface) != 1:
        fail('The server profile must have one Interface section.')
    address_values = server_interface[0]['fields'].get('Address', '').split(',')
    if len(address_values) != 1:
        fail('This wizard expects one server IPv4 tunnel address.')
    vpn_address = ipaddress.IPv4Interface(address_values[0].strip())
    if vpn_address not in interface_addresses(interface):
        fail('The saved and active AWG address differ; reconcile them first.')
    source = target_network(str(vpn_address.network))
    public = run('awg', 'show', interface, 'public-key')
    if run('awg', 'pubkey', data=server_interface[0]['fields'].get('PrivateKey', '') + '\n') != public:
        fail('The saved server key and active interface differ.')
    peers = set(run('awg', 'show', interface, 'peers').split())
    disk_peers = {s['fields'].get('PublicKey') for s in server_sections if s['kind'] == '[Peer]'}
    if disk_peers != peers:
        fail('Saved and active server peers differ; reconcile them first.')
    accounts, admin_snapshots = admin_metadata(interface, public, peers)
    before_snapshot = snapshot(BEFORE)
    rules_before = run('ufw', 'show', 'added')
    all_rules = normalized_ufw_rules(rules_before)
    tag = 'awg-vpc-' + interface
    legacy = extract_nat(before_snapshot[0], 'awg-test-vpc')
    old = extract_nat(before_snapshot[0], tag)
    if old and legacy and legacy['source'] == source:
        fail('Both old and new managed policies exist; reconcile them first.')
    if not old and legacy and legacy['source'] == source:
        old, tag = legacy, 'awg-test-vpc'
    if old:
        old['interface'] = interface
        if old['source'] != source or all_rules.count(ufw_rule(old, tag)) != 1:
            fail('The existing managed NAT and UFW forwarding policy disagree; retained for review.')
    if any('comment' in r and r[-1] == tag and (not old or r != ufw_rule(old, tag)) for r in all_rules):
        fail('An unexpected rule uses the managed VPC comment; retained for review.')
    route_path = BASE / (interface + '.client-routes')
    route_snapshot = snapshot(route_path, private=True, optional=True)
    routes = []
    for value in (route_snapshot[0] or '').splitlines():
        if value.strip():
            network = str(ipaddress.IPv4Network(value.strip(), strict=True))
            if network not in routes:
                routes.append(network)
    if old and old['target'] not in routes:
        fail('The existing managed NAT target is missing from the client route policy.')
    print(run('ip', '-brief', '-4', 'address', 'show'))
    if args.preview and old:
        target, outbound, snat = old['target'], old['out'], old['snat']
    else:
        target, outbound, snat = choose_vpc_policy(available, vpn_address, old)
    policy = dict(interface=interface, source=source, target=target, out=outbound, snat=snat)
    validate_route(policy, vpn_address)
    clients = collect_clients(public, peers, interface, accounts)
    sysctl_path = Path('/etc/sysctl.d/90-' + tag + '.conf')
    sysctl_snapshot = snapshot(sysctl_path, optional=True)
    sysctl_text = sysctl_snapshot[0]
    if sysctl_text is not None:
        settings = [line.strip().replace(' ', '') for line in sysctl_text.splitlines() if line.strip() and not line.lstrip().startswith('#')]
        if settings != ['net.ipv4.ip_forward=1']:
            fail('The managed sysctl file contains unexpected settings; it was retained.')
    else:
        sysctl_text = '# AWG clients may route to the selected VPC target.\nnet.ipv4.ip_forward=1\n'
    forwarding_before = run('sysctl', '-n', 'net.ipv4.ip_forward')
    if forwarding_before == '1':
        verify_forward_routes(policy)
    fingerprint_before = runtime_fingerprint(interface)
    snapshots = {BEFORE: before_snapshot, route_path: route_snapshot, sysctl_path: sysctl_snapshot, **clients, **admin_snapshots}
    proposed = {BEFORE: rewrite_nat(before_snapshot[0], tag, nat_rule(policy)), sysctl_path: sysctl_text}
    new_routes = [r for r in routes if not old or r != old['target'] or old['target'] == target]
    if target not in new_routes:
        new_routes.append(target)
    # Retain byte-for-byte policy text when the effective routes do not change.
    proposed[route_path] = route_snapshot[0] if new_routes == routes else '\n'.join(new_routes) + '\n'
    for path, (text, mode) in clients.items():
        proposed[path] = update_client_routes(text, public, old['target'] if old else None, target)
    changes = {path: text for path, text in proposed.items() if text != snapshots[path][0]}
    new_rule = ufw_rule(policy, tag)
    old_rule = ufw_rule(old, tag) if old else None
    for rule in all_rules:
        if rule[:12] == new_rule[:12] and rule != old_rule:
            fail('An existing forwarding rule has the same scope; review it before adopting this policy.')
    run('iptables-restore', '--test', data=proposed[BEFORE])
    print('\nVPC access: ' + source + ' -> ' + target + ' via ' + outbound + '; SNAT ' + snat)
    print('Stored client profiles: ' + str(len(clients)) + '; changed files: ' + str(len(changes)))
    print('Server keys, peers, port and AWG service remain unchanged. SSH, default route and unrelated UFW rules stay in place.')
    print('Existing imported clients need the updated AllowedIPs or a fresh profile import; Test sees the VPC SNAT address.')
    if args.preview:
        print('Preview only; no files or network settings changed.')
        return
    if not changes and old_rule == new_rule and forwarding_before == '1':
        check_nat(policy)
        print('Already configured; no changes made.')
        return
    if prompt('Type APPLY to apply this VPC policy', '') != 'APPLY':
        print('Cancelled; no changes made.')
        return
    for path, expected in snapshots.items():
        current = admin_snapshot(path) if path in admin_snapshots else snapshot(path, private=path == route_path or path in clients, optional=expected[0] is None)
        if current != expected:
            fail('Configuration changed during confirmation; retry.')
    if snapshot(server_path, private=True) != server_snapshot or run('ufw', 'show', 'added') != rules_before or runtime_fingerprint(interface) != fingerprint_before or run('sysctl', '-n', 'net.ipv4.ip_forward') != forwarding_before:
        fail('Server state changed during confirmation; retry.')
    validate_route(policy, vpn_address)
    apply_changes(changes, snapshots, policy, old_rule, new_rule, forwarding_before, fingerprint_before, server_path, server_snapshot)


def check_nat(policy):
    run('iptables', '-w', '5', '-t', 'nat', '-C', *shlex.split(nat_rule(policy))[1:])


def apply_changes(changes, snapshots, policy, old_rule, new_rule, forwarding_before, fingerprint_before, server_path, server_snapshot):
    verify_admin_snapshots(snapshots)
    backup = Path(tempfile.mkdtemp(prefix=policy['interface'] + '-vpc-backup-', dir=BASE))
    os.chmod(backup, 0o700)
    records = []
    for i, (path, (text, mode)) in enumerate(snapshots.items()):
        saved = str(i) + '.txt' if text is not None else None
        if saved:
            atomic_write(backup / saved, text)
        records.append(dict(path=str(path), backup=saved, mode=mode))
    atomic_write(backup / 'manifest.json', json.dumps(dict(files=records, ip_forward=forwarding_before, old_rule=old_rule, new_rule=new_rule), indent=2) + '\n')
    atomic_write(backup / 'README.txt', 'Rollback reference only; contains private client keys.\nRestore only files still matching this operation, undo the new UFW rule and restore the old rule, then reload UFW.\nDo not restore ip_forward=0 if other services now depend on forwarding.\nAWG service and server profile were not changed.\n')
    touched, added, deleted, reloaded, forwarding_attempted = [], False, False, False, False
    print('Private backup: ' + str(backup))
    previous_handlers = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM)}
    def interrupt(signum, frame):
        raise InterruptedError('Operation interrupted.')
    for signum in previous_handlers:
        signal.signal(signum, interrupt)
    try:
        for path, text in changes.items():
            verify_admin_snapshots(snapshots)
            if snapshot(path, private=(BASE / 'clients') in path.parents or path.suffix == '.client-routes' or path.name.endswith('-client.conf'), optional=snapshots[path][0] is None) != snapshots[path]:
                fail('A file changed before writing; retry.')
            touched.append(path)
            atomic_write(path, text, snapshots[path][1])
        if old_rule != new_rule:
            added = True
            result = run('ufw', *new_rule)
            if 'Skipping adding existing rule' in result:
                added = False
                fail('A matching UFW rule appeared concurrently; retained.')
            if old_rule:
                deleted = True
                run('ufw', '--force', 'route', 'delete', *old_rule[1:])
        reloaded = True
        run('ufw', 'reload')
        forwarding_attempted = True
        run('sysctl', '-w', 'net.ipv4.ip_forward=1')
        check_nat(policy)
        verify_forward_routes(policy)
        if normalized_ufw_rules(run('ufw', 'show', 'added')).count(new_rule) != 1:
            fail('Forwarding rule verification failed.')
        if run('sysctl', '-n', 'net.ipv4.ip_forward') != '1' or runtime_fingerprint(policy['interface']) != fingerprint_before or snapshot(server_path, private=True) != server_snapshot:
            fail('Post-change server state verification failed.')
        verify_admin_snapshots(snapshots)
        for path, text in changes.items():
            if path.read_text() != text:
                fail('Post-change file verification failed.')
    except BaseException:
        for signum in previous_handlers:
            signal.signal(signum, signal.SIG_IGN)
        errors = []
        if added:
            try:
                if new_rule in normalized_ufw_rules(run('ufw', 'show', 'added')):
                    run('ufw', '--force', 'route', 'delete', *new_rule[1:])
            except BaseException:
                errors.append('new UFW rule')
        if deleted:
            try:
                if old_rule not in normalized_ufw_rules(run('ufw', 'show', 'added')):
                    run('ufw', *old_rule)
            except BaseException:
                errors.append('old UFW rule')
        for path in reversed(touched):
            try:
                original, mode = snapshots[path]
                current = read_secure(path, optional=True)
                if current == original:
                    continue
                if current != changes[path]:
                    fail('File changed externally during rollback.')
                if original is None:
                    path.unlink()
                else:
                    atomic_write(path, original, mode)
            except BaseException:
                errors.append(str(path))
        if reloaded or BEFORE in touched:
            try:
                run('ufw', 'reload')
            except BaseException:
                errors.append('UFW reload')
        if forwarding_attempted or reloaded:
            try:
                run('sysctl', '-w', 'net.ipv4.ip_forward=' + forwarding_before)
            except BaseException:
                errors.append('IP forwarding')
        if errors:
            fail('Apply failed; review backup for incomplete rollback: ' + ', '.join(errors))
        fail('Apply failed; this operation was rolled back. Backup: ' + str(backup))
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
    print('VPC policy applied and checked. AWG service was not restarted.')
    print('Update/reimport the stored client profiles, then test access to ' + policy['target'] + '.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, InterruptedError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        sys.exit(1)

PY_VPC_WIZARD
}

# Embedded entry menu; operations run in a separate process to release their locks on return.
entry_prompt() {
    IFS= read -r -p "$2" "$1" < /dev/tty
}

entry_update() (
    local script=${BASH_SOURCE[0]}
    (( $# == 0 )) || { (( $# == 1 )) && [[ $1 == --check ]]; } || {
        say 'Use --update or --check-update without extra arguments.' >&2
        return 1
    }
    (( EUID == 0 )) || { say 'Run script updates as root.' >&2; return 1; }
    [[ $(uname -s) == Linux ]] || { say 'Run script updates on the Linux AWG server.' >&2; return 1; }
    command -v python3 >/dev/null || { say 'Python 3 is required to check script updates.' >&2; return 1; }
    if [[ ${1:-} != --check ]]; then
        command -v flock >/dev/null || { say 'The flock command is required to update this script.' >&2; return 1; }
        acquire_lock || return
    fi
    python3 - "$script" "$@" <<'PY_UPDATER'
"""Update only the trusted standalone script from a verified GitHub Release."""
import datetime
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

REPOSITORY = 'Accec/easy-awg'
API_URL = 'https://api.github.com/repos/' + REPOSITORY + '/releases/latest'
ROOT_UID = 0
SCRIPT_LIMIT = 4 * 1024 * 1024
METADATA_LIMIT = 1024 * 1024
CHECKSUM_LIMIT = 4096
HOSTS = {'api.github.com', 'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'}


def fail(message):
    raise ValueError(message)


def version_tuple(value):
    if not isinstance(value, str):
        fail('The release version is invalid.')
    match = re.fullmatch(r'v(\d{4})-(\d{2})-(\d{2})-([1-9][0-9]*)', value, flags=re.ASCII)
    if not match or len(value) > 40:
        fail('Use a release version formatted as vYYYY-MM-DD-N.')
    year, month, day, index = map(int, match.groups())
    datetime.date(year, month, day)
    return year, month, day, index


def script_version(data):
    if not data.startswith(b'#!/usr/bin/env bash\n') or b'\0' in data:
        fail('The script does not have the expected Bash header.')
    markers = re.findall(rb'^EASY_AWG_VERSION=([^\r\n]+)$', data, re.M)
    if len(markers) != 1:
        fail('The script needs one EASY_AWG_VERSION marker; retain it for manual review.')
    try:
        version = markers[0].decode('ascii')
    except UnicodeError:
        fail('The script version is not ASCII.')
    version_tuple(version)
    return version


def checked_url(url):
    if not isinstance(url, str):
        fail('Unexpected download URL.')
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != 'https' or parsed.netloc not in HOSTS or parsed.fragment
            or any(ord(character) < 33 or ord(character) > 126 for character in url)):
        fail('Downloads require HTTPS on the expected GitHub hosts.')
    return url


class GitHubRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        checked_url(newurl)
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def fetch(url, limit):
    checked_url(url)
    request = urllib.request.Request(url, headers={
        'User-Agent': 'easy-awg-updater', 'Accept': 'application/vnd.github+json' if url == API_URL else 'application/octet-stream',
        'Accept-Encoding': 'identity',
    })
    try:
        with urllib.request.build_opener(GitHubRedirects()).open(request, timeout=30) as response:
            checked_url(response.geturl())
            if response.status != 200:
                fail('GitHub returned an unexpected HTTP status.')
            length = response.headers.get('Content-Length')
            if length is not None and (not re.fullmatch(r'[0-9]+', length) or int(length) > limit):
                fail('The download exceeds its size limit.')
            data = response.read(limit + 1)
            if len(data) > limit or (length is not None and len(data) != int(length)):
                fail('The download was oversized or incomplete.')
            return data
    except (urllib.error.URLError, OSError, TimeoutError, http.client.HTTPException):
        fail('GitHub download failed; the installed script was retained.')


def release_metadata(data):
    try:
        release = json.loads(data)
    except (ValueError, UnicodeError):
        fail('GitHub release metadata is invalid.')
    if (not isinstance(release, dict) or release.get('draft') is not False
            or release.get('prerelease') is not False or not isinstance(release.get('assets'), list)):
        fail('Expected a published stable GitHub Release.')
    tag = release.get('tag_name')
    version_tuple(tag)
    assets = {}
    for name, limit in [('setup-wireguard.sh', SCRIPT_LIMIT), ('SHA256SUMS', CHECKSUM_LIMIT)]:
        matches = [item for item in release['assets'] if isinstance(item, dict) and item.get('name') == name]
        if len(matches) != 1:
            fail('The release must include exactly one script and one SHA256SUMS asset.')
        asset = matches[0]
        expected_url = 'https://github.com/' + REPOSITORY + '/releases/download/' + tag + '/' + name
        if (asset.get('state') != 'uploaded' or type(asset.get('size')) is not int
                or not 0 < asset['size'] <= limit or asset.get('browser_download_url') != expected_url):
            fail('A release asset has unexpected state, size or download URL.')
        digest = asset.get('digest')
        if digest is not None and (not isinstance(digest, str) or not re.fullmatch(r'sha256:[a-f0-9]{64}', digest)):
            fail('A release asset digest is invalid.')
        assets[name] = asset
    return tag, assets


def download_asset(asset, limit):
    data = fetch(asset['browser_download_url'], limit)
    if len(data) != asset['size']:
        fail('A release asset changed size or was truncated.')
    digest = asset.get('digest')
    if digest and digest != 'sha256:' + hashlib.sha256(data).hexdigest():
        fail('A release asset differs from the selected release digest.')
    return data


def checksum(data):
    match = re.fullmatch(rb'([a-f0-9]{64})  setup-wireguard\.sh\n?', data)
    if not match:
        fail('SHA256SUMS must contain exactly one unambiguous setup-wireguard.sh record.')
    return match[1].decode('ascii')


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
            info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink)


def trusted_parents(directory):
    if directory.resolve(strict=True) != directory or not str(directory).isprintable():
        fail('Script directories must be canonical and free of symlinks.')
    for parent in (directory, *directory.parents):
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != ROOT_UID or info.st_mode & 0o022:
            fail('Script directories must be root-owned and not writable by other accounts.')


def read_source(invoked):
    invoked = Path(os.path.abspath(invoked))
    if not str(invoked).isprintable():
        fail('The script path must be printable.')
    trusted_parents(invoked.parent)
    entry = invoked.lstat()
    target = invoked
    if stat.S_ISLNK(entry.st_mode):
        if entry.st_uid != ROOT_UID:
            fail('The command shortcut must be root-owned.')
        link = Path(os.readlink(invoked))
        target = Path(os.path.abspath(link if link.is_absolute() else invoked.parent / link))
    trusted_parents(target.parent)
    fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != ROOT_UID or info.st_nlink != 1
                or info.st_mode & (0o022 | stat.S_ISUID | stat.S_ISGID) or info.st_size > SCRIPT_LIMIT):
            fail('The script must be one trusted root-owned regular file without unsafe permissions or hard links.')
        data = stream.read(SCRIPT_LIMIT + 1)
        if len(data) != info.st_size or fingerprint(os.fstat(stream.fileno())) != fingerprint(info):
            fail('The script changed while it was being read.')
    return target, info, data


def unchanged(invoked, original):
    current = read_source(invoked)
    if current[0] != original[0] or fingerprint(current[1]) != fingerprint(original[1]) or current[2] != original[2]:
        fail('The installed script or command shortcut changed; the current version was retained.')


def sync_directory(directory):
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def staged_file(directory, prefix, data, mode, owner):
    fd, name = tempfile.mkstemp(prefix=prefix, dir=directory)
    path = Path(name)
    try:
        with os.fdopen(fd, 'wb') as output:
            os.fchown(output.fileno(), owner.st_uid, owner.st_gid)
            os.fchmod(output.fileno(), mode)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
            info = os.fstat(output.fileno())
        return path, info
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def confirm():
    # Buffered read/write mode requires seeking; terminals need separate streams.
    with open('/dev/tty', 'r', encoding='utf-8') as reader, \
            open('/dev/tty', 'w', encoding='utf-8') as writer:
        writer.write('Type APPLY to replace only this script and retain a private backup: ')
        writer.flush()
        return reader.readline().strip() == 'APPLY'


def install_candidate(invoked, original, candidate, tag):
    target, owner, old = original
    temporary = None
    backup = None
    staged_info = None
    try:
        unchanged(invoked, original)
        temporary, staged_info = staged_file(target.parent, '.easy-awg-update-', candidate, stat.S_IMODE(owner.st_mode), owner)
        result = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-n', str(temporary)],
                                capture_output=True, timeout=30, env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
        if result.returncode:
            fail('The release script failed Bash syntax validation; the installed script was retained.')
        unchanged(invoked, original)
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        backup, _ = staged_file(target.parent, target.name + '.backup-' + stamp + '-', old, 0o600, owner)
        sync_directory(target.parent)
        unchanged(invoked, original)
        os.replace(temporary, target)
        sync_directory(target.parent)
        unchanged(invoked, (target, staged_info, candidate))
    except BaseException as error:
        restored = False
        try:
            current = read_source(invoked)
            if (staged_info is not None and current[0] == target
                    and fingerprint(current[1]) == fingerprint(staged_info) and current[2] == candidate):
                rollback, _ = staged_file(target.parent, '.easy-awg-rollback-', old, stat.S_IMODE(owner.st_mode), owner)
                try:
                    unchanged(invoked, current)
                    os.replace(rollback, target)
                    sync_directory(target.parent)
                    restored = True
                finally:
                    rollback.unlink(missing_ok=True)
        except BaseException:
            fail('Update failed; review the current script and private backup before retrying: ' + str(backup))
        if backup is not None:
            print('Private previous-script backup: ' + str(backup))
        if restored:
            fail('Update failed after replacement; the previous script was restored.')
        if isinstance(error, ValueError):
            raise
        fail('Update failed; the current script was retained.')
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print('Updated script to ' + tag + ': ' + str(target))
    print('Private previous-script backup: ' + str(backup))
    print('AWG services, accounts and network configuration were not changed. Run the script again to use the new version.')


def update_script(path, check_only=False):
    original = read_source(path)
    current = script_version(original[2])
    tag, assets = release_metadata(fetch(API_URL, METADATA_LIMIT))
    print('Installed script: ' + current)
    print('Latest stable release: ' + tag)
    if version_tuple(tag) < version_tuple(current):
        print('The local version is newer than the published release; no downgrade was performed.')
        return
    digest = checksum(download_asset(assets['SHA256SUMS'], CHECKSUM_LIMIT))
    if tag == current:
        if digest != hashlib.sha256(original[2]).hexdigest():
            fail('The same version has different content; the local script was retained for manual review.')
        print('The installed script already matches this release.')
        return
    print('Update available: ' + current + ' -> ' + tag)
    print('Target: ' + str(original[0]))
    print('Only the script will change. A private backup is kept; AWG packages, services and configuration stay unchanged.')
    print('The checksum verifies consistency with this GitHub Release; it is not an independent publisher signature.')
    if check_only:
        print('Check only; no script asset was downloaded and no files were changed.')
        return
    if not confirm():
        print('Cancelled; no files changed.')
        return
    unchanged(path, original)
    candidate = download_asset(assets['setup-wireguard.sh'], SCRIPT_LIMIT)
    if hashlib.sha256(candidate).hexdigest() != digest:
        fail('The script SHA256 does not match SHA256SUMS; the installed script was retained.')
    if script_version(candidate) != tag:
        fail('The downloaded script version differs from the selected release tag.')
    install_candidate(path, original, candidate, tag)


def main(argv=None):
    arguments = sys.argv[1:] if argv is None else list(argv)
    if os.geteuid() != 0 or sys.platform != 'linux':
        fail('Run the updater as root on the Linux AWG server.')
    if len(arguments) not in (1, 2) or (len(arguments) == 2 and arguments[1] != '--check'):
        fail('Usage: updater SCRIPT_PATH [--check]')
    update_script(arguments[0], check_only=len(arguments) == 2)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError, KeyboardInterrupt):
        # Avoid printing network response bodies, signed redirect URLs, or downloaded script text.
        message = str(sys.exc_info()[1]) if isinstance(sys.exc_info()[1], ValueError) else 'Update stopped; inspect the current script and any retained private backup.'
        print('ERROR: ' + message, file=sys.stderr)
        sys.exit(1)

PY_UPDATER
)

entry_install_command() {
    (( $# == 0 )) || { say 'Use --install-command without extra arguments.' >&2; return 1; }
    (( EUID == 0 )) || { say 'Run shortcut installation with sudo or as root.' >&2; return 1; }
    [[ $(uname -s) == Linux ]] || { say 'Install the shortcut on the Linux AWG server.' >&2; return 1; }
    command -v python3 >/dev/null || { say 'Python 3 is required to validate the shortcut.' >&2; return 1; }
    entry_command_python
}

entry_initialize() {
    (( $# == 0 )) || { say 'Use --initialize without extra arguments.' >&2; return 1; }
    (( EUID == 0 )) || { say 'Run initialization with sudo or as root.' >&2; return 1; }
    [[ $(uname -s) == Linux ]] || { say 'Initialize on the Linux AWG server.' >&2; return 1; }
    command -v python3 >/dev/null || { say 'Python 3 is required for initialization.' >&2; return 1; }
    entry_command_python --initialize
}

entry_start() {
    local status
    # Only an interactive no-argument launch offers installation; CLI operations stay unchanged.
    if (( EUID == 0 )) && [[ -t 0 && -t 1 && $(uname -s) == Linux ]] && command -v python3 >/dev/null; then
        if entry_command_python --offer; then return 0; else status=$?; fi
        (( status == 10 )) || return "$status"
    fi
    entry_menu
}

entry_command_python() {
    python3 - "${BASH_SOURCE[0]}" "$@" <<'PY_ENTRY_COMMAND'
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile


def command_fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_uid,
            info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink)


def command_parents(directory):
    directory = Path(directory)
    if not directory.is_absolute() or directory.resolve() != directory or not str(directory).isprintable():
        raise ValueError('Shortcut paths must be absolute, printable and free of directory symlinks.')
    missing = []
    for parent in reversed((directory, *directory.parents)):
        try:
            info = parent.lstat()
        except FileNotFoundError:
            missing.append(parent)
            continue
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError('Script and command directories must be root-owned and not writable by other accounts.')
    return missing


def command_source(path):
    path = Path(path).resolve(strict=True)
    command_parents(path.parent)
    info = path.lstat()
    if (not str(path).isprintable() or not stat.S_ISREG(info.st_mode) or info.st_uid != 0
            or info.st_nlink != 1 or info.st_mode & 0o022 or info.st_mode & (stat.S_ISUID | stat.S_ISGID)):
        raise ValueError('The script must be a regular root-owned file, without hard links or write access for other accounts.')
    return path, info


def command_destination(destination, source):
    try:
        info = destination.lstat()
    except FileNotFoundError:
        return None
    if destination == source and stat.S_ISREG(info.st_mode):
        return info
    if stat.S_ISLNK(info.st_mode):
        try:
            if destination.resolve(strict=True) == source:
                return info
        except (OSError, RuntimeError):
            pass
    raise ValueError('An existing command or link uses this path; it was retained: ' + str(destination))


def command_confirm():
    # Buffered read/write mode requires seeking; terminals need separate streams.
    with open('/dev/tty', 'r', encoding='utf-8') as reader, \
            open('/dev/tty', 'w', encoding='utf-8') as writer:
        writer.write('Type APPLY to install this command shortcut: ')
        writer.flush()
        return reader.readline().strip() == 'APPLY'


def command_path_collision(destination, source):
    found = shutil.which(destination.name)
    if found and Path(found).absolute() != destination and Path(found).resolve() != source:
        raise ValueError('Another command with this name is already on PATH; it was retained: ' + found)


def command_install(source, destination=Path('/usr/local/bin/awg-manage'), confirm=command_confirm):
    source, original = command_source(source)
    destination = Path(destination)
    command_parents(destination.parent)
    existing = command_destination(destination, source)
    command_path_collision(destination, source)
    executable = bool(original.st_mode & stat.S_IXUSR)
    if existing is not None and executable:
        print('Command shortcut already points to this script: ' + str(destination))
        return
    print('Command: ' + str(destination))
    print('Script:  ' + str(source))
    print('This creates a symbolic link, not a second script. Keep the source at this location.')
    if not executable:
        print('Owner execute permission will be added to the source script.')
    if not confirm():
        print('Cancelled; script installation and VPN configuration unchanged.')
        return
    source_now, current = command_source(source)
    if source_now != source or command_fingerprint(current) != command_fingerprint(original):
        raise ValueError('The source script changed during confirmation; no shortcut was installed.')
    missing = command_parents(destination.parent)
    now = command_destination(destination, source)
    command_path_collision(destination, source)
    if (existing is None) != (now is None) or (existing is not None and command_fingerprint(now) != command_fingerprint(existing)):
        raise ValueError('The command path changed during confirmation; the current entry was retained.')
    created = []
    fd = None
    changed_mode = False
    try:
        for directory in missing:
            try:
                directory.mkdir(mode=0o755)
                created.append(directory)
                os.chmod(directory, 0o755)
            except FileExistsError:
                pass
            command_parents(directory)
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        if command_fingerprint(os.fstat(fd)) != command_fingerprint(original):
            raise ValueError('The source script changed before linking; retry after reviewing it.')
        if not executable:
            changed_mode = True
            os.fchmod(fd, stat.S_IMODE(original.st_mode) | stat.S_IXUSR)
        if existing is None:
            # symlink creation is exclusive: a racing command is never overwritten.
            os.symlink(str(source), destination)
    except BaseException:
        if changed_mode and fd is not None:
            current = os.fstat(fd)
            expected = list(command_fingerprint(original))
            expected[6] |= stat.S_IXUSR
            if command_fingerprint(current) == tuple(expected):
                os.fchmod(fd, stat.S_IMODE(original.st_mode))
        for directory in reversed(created):
            try:
                directory.rmdir()
            except OSError:
                pass
        raise
    finally:
        if fd is not None:
            os.close(fd)
    print('Command ready. Run: sudo ' + str(destination))
    print('The short name awg-manage works when /usr/local/bin is in the command search PATH.')


def initialize_prompt(message):
    with open('/dev/tty', 'r', encoding='utf-8') as reader, \
            open('/dev/tty', 'w', encoding='utf-8') as writer:
        writer.write(message)
        writer.flush()
        answer = reader.readline()
    if not answer:
        raise ValueError('Input closed; initialization cancelled.')
    return answer.strip()


def initialize_source(path):
    path = Path(path).resolve(strict=True)
    allowed = {0}
    sudo_uid = os.environ.get('SUDO_UID', '')
    if sudo_uid.isdecimal():
        allowed.add(int(sudo_uid))
    for parent in path.parents:
        info = parent.lstat()
        sticky = info.st_uid == 0 and bool(info.st_mode & stat.S_ISVTX)
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in allowed
                or info.st_mode & 0o022 and not sticky):
            raise ValueError('The downloaded script has an untrusted parent directory; source retained.')
    info = path.lstat()
    if (not str(path).isprintable() or not stat.S_ISREG(info.st_mode) or info.st_uid not in allowed
            or info.st_nlink != 1 or info.st_mode & (0o022 | stat.S_ISUID | stat.S_ISGID)):
        raise ValueError('Use a regular script owned by root or the invoking sudo user, without shared write access or hard links.')
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as stream:
        if command_fingerprint(os.fstat(stream.fileno())) != command_fingerprint(info):
            raise ValueError('The downloaded script changed while opening it; source retained.')
        data = stream.read(4 * 1024 * 1024 + 1)
        if command_fingerprint(os.fstat(stream.fileno())) != command_fingerprint(info):
            raise ValueError('The downloaded script changed while reading it; source retained.')
    if (len(data) > 4 * 1024 * 1024 or not data.startswith(b'#!/usr/bin/env bash\n') or b'\0' in data
            or len(re.findall(rb'^EASY_AWG_VERSION=v[0-9]{4}-[0-9]{2}-[0-9]{2}-[1-9][0-9]*$', data, re.M)) != 1):
        raise ValueError('The downloaded file is not a versioned standalone AWG script; source retained.')
    return path, info, data


def initialize_command_state(destination, source, target):
    try:
        info = destination.lstat()
    except FileNotFoundError:
        return None, None
    command_parents(destination.parent)
    if (stat.S_ISLNK(info.st_mode) and info.st_uid == 0
            and destination.resolve(strict=True) in (source, target)):
        return info, os.readlink(destination)
    raise ValueError('An existing different command uses this path; retained: ' + str(destination))


def initialize_ready(source, destination=Path('/usr/local/bin/awg-manage')):
    try:
        source, info = command_source(source)
        shortcut, _ = initialize_command_state(destination, source, source)
        return (source.name == 'setup-wireguard.sh' and stat.S_IMODE(info.st_mode) == 0o700
                and stat.S_IMODE(source.parent.stat().st_mode) == 0o700 and shortcut is not None)
    except (OSError, ValueError, RuntimeError):
        return False


@contextmanager
def command_lock(directory=Path('/run/manage-amneziawg')):
    # Share the install/update lock, but release it before entering the installed menu.
    command_parents(directory.parent)
    try:
        directory.mkdir(mode=0o700)
    except FileExistsError:
        pass
    command_parents(directory)
    if stat.S_IMODE(directory.lstat().st_mode) != 0o700:
        raise ValueError('The runtime lock directory must have mode 700; existing permissions were retained.')
    fd = os.open(directory / 'setup.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise ValueError('The installation lock must be a root-owned mode-600 regular file without hard links.')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another setup process is running.') from None
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def initialize_sync_directory(directory):
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def initialize_cleanup_allowed(source, info):
    # User-writable download parents may be swapped after validation. Keep those originals.
    if info.st_uid != 0:
        return False
    try:
        command_parents(source.parent)
        return True
    except (OSError, ValueError):
        return False


def initialize_install(source, directory, destination=Path('/usr/local/bin/awg-manage'), confirm=None):
    source, original, data = initialize_source(source)
    directory, destination = Path(directory), Path(destination)
    target = directory / 'setup-wireguard.sh'
    missing = command_parents(directory) + command_parents(destination.parent)
    if directory.exists() and stat.S_IMODE(directory.stat().st_mode) != 0o700:
        raise ValueError('Choose a dedicated installation directory with mode 700; existing directory permissions were retained.')
    previous = None
    if os.path.lexists(target):
        current, previous = command_source(target)
        if current != target or stat.S_IMODE(previous.st_mode) != 0o700 or target.read_bytes() != data:
            raise ValueError('A different script already occupies the installation path; use its updater or choose another directory.')
    old_link, old_text = initialize_command_state(destination, source, target)
    found = shutil.which(destination.name)
    if found and Path(found).absolute() != destination and Path(found).resolve() not in (source, target):
        raise ValueError('Another command with this name is on PATH; it was retained.')
    if source == target and old_link is not None:
        print('Initialization already complete: ' + str(target))
        return target
    print('Install directory: ' + str(directory))
    print('Installed script:  ' + str(target))
    print('Command shortcut:  ' + str(destination))
    remove_original = initialize_cleanup_allowed(source, original)
    if source != target:
        note = ('removed only after installation and verification succeed' if remove_original
                else 'retained: download location is not protected by root-owned directories')
        print('Original script:   ' + str(source) + ' (' + note + ')')
    print('Only script installation paths change. Existing AWG services, configuration, accounts and keys stay unchanged.')
    confirm = confirm or (lambda: initialize_prompt('Type APPLY to initialize the script installation: ') == 'APPLY')
    if not confirm():
        print('Cancelled; script installation and VPN configuration unchanged.')
        return None
    latest, current, current_data = initialize_source(source)
    if latest != source or command_fingerprint(current) != command_fingerprint(original) or current_data != data:
        raise ValueError('The source changed during confirmation; no installation was performed.')
    command_parents(directory)
    command_parents(destination.parent)
    now, now_text = initialize_command_state(destination, source, target)
    if ((old_link is None) != (now is None) or now_text != old_text
            or old_link is not None and command_fingerprint(now) != command_fingerprint(old_link)):
        raise ValueError('The command path changed during confirmation; current entry retained.')
    created, installed, linked, temporary, temporary_link = [], None, None, None, None
    try:
        for path in dict.fromkeys(missing):
            try:
                path.mkdir(mode=0o700 if path == directory else 0o755)
                created.append((path, path.lstat()))
            except FileExistsError:
                pass
            command_parents(path)
        if stat.S_IMODE(directory.stat().st_mode) != 0o700:
            raise ValueError('The installation directory changed; its permissions were retained.')
        if previous is None:
            fd, temporary = tempfile.mkstemp(prefix='.easy-awg-install-', dir=directory)
            with os.fdopen(fd, 'wb') as stream:
                os.fchmod(stream.fileno(), 0o700)
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            if subprocess.run(['bash', '-n', temporary], capture_output=True, timeout=15).returncode:
                raise ValueError('The staged script failed Bash syntax validation; original retained.')
            # Hard-link publication is exclusive, unlike replacement of an existing destination.
            os.link(temporary, target, follow_symlinks=False)
            installed = target.lstat()
            os.unlink(temporary)
            temporary = None
            installed = target.lstat()
        else:
            if command_fingerprint(target.lstat()) != command_fingerprint(previous):
                raise ValueError('The installed script changed during confirmation; retained.')
        if target.read_bytes() != data:
            raise ValueError('Installed script verification failed; original retained.')
        if old_link is None:
            os.symlink(str(target), destination)
        elif destination.resolve(strict=True) != target:
            if command_fingerprint(destination.lstat()) != command_fingerprint(old_link):
                raise ValueError('The command changed before relocation; retained.')
            fd, temporary_link = tempfile.mkstemp(prefix='.easy-awg-link-', dir=destination.parent)
            os.close(fd)
            os.unlink(temporary_link)
            os.symlink(str(target), temporary_link)
            now, now_text = initialize_command_state(destination, source, target)
            if (now is None or command_fingerprint(now) != command_fingerprint(old_link) or now_text != old_text):
                raise ValueError('The command changed before relocation; retained.')
            os.replace(temporary_link, destination)
            temporary_link = None
        linked = destination.lstat()
        if not destination.is_symlink() or destination.resolve(strict=True) != target:
            raise ValueError('The installed command failed verification; original retained.')
        # Persist new files and directory entries before removing a protected original.
        for path in dict.fromkeys([directory, destination.parent, *(p.parent for p, _ in reversed(created))]):
            initialize_sync_directory(path)
        latest, current, current_data = initialize_source(source)
        if latest != source or command_fingerprint(current) != command_fingerprint(original) or current_data != data:
            raise ValueError('The source changed before cleanup; current source retained.')
        if source != target and remove_original and initialize_cleanup_allowed(source, current):
            os.unlink(source)
    except BaseException:
        if linked is not None and os.path.lexists(destination) and command_fingerprint(destination.lstat()) == command_fingerprint(linked):
            if old_text is None:
                destination.unlink()
            elif os.readlink(destination) != old_text:
                destination.unlink()
                destination.symlink_to(old_text)
        if installed is not None and os.path.lexists(target) and command_fingerprint(target.lstat()) == command_fingerprint(installed):
            target.unlink()
        # Remove staged files before removing their newly created parent directories.
        for path in (temporary, temporary_link):
            if path is not None:
                try:
                    os.unlink(path)
                except OSError:
                    pass
        for path, info in reversed(created):
            try:
                if command_fingerprint(path.lstat())[:2] == command_fingerprint(info)[:2]:
                    path.rmdir()
            except OSError:
                pass
        raise
    finally:
        for path in (temporary, temporary_link):
            if path is not None:
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass
    print('Initialization complete. Run: sudo ' + str(destination))
    return target


def initialize_main(source, offer=False):
    if offer:
        if initialize_ready(source):
            return 10
        print('Initialize a stable script location and the awg-manage command before using the menu?')
        while True:
            answer = initialize_prompt('1) Initialize script  2) Skip for now  0) Exit: ')
            if answer in ('0', '1', '2'):
                break
            print('Choose 1, 2, or 0.')
        if answer == '0':
            return 0
        if answer == '2':
            return 10
    directory = initialize_prompt('Installation directory [/usr/local/lib/easy-awg]: ') or '/usr/local/lib/easy-awg'
    with command_lock():
        target = initialize_install(source, directory)
    if target is not None and offer:
        os.execv('/bin/bash', ['bash', '--', str(target)])
    return 10 if offer else 0


if __name__ == '__main__':
    try:
        if os.geteuid() != 0 or sys.platform != 'linux' or len(sys.argv) not in (2, 3):
            raise ValueError('Run script installation as root on the Linux AWG server.')
        if len(sys.argv) == 2:
            with command_lock():
                command_install(sys.argv[1])
        elif sys.argv[2] in ('--initialize', '--offer'):
            sys.exit(initialize_main(sys.argv[1], offer=sys.argv[2] == '--offer'))
        else:
            raise ValueError('Unexpected script installation option.')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        sys.exit(1)

PY_ENTRY_COMMAND
}

entry_instances() {
    command -v python3 >/dev/null || { say 'Python 3 is required to list saved instances.' >&2; return 1; }
    python3 - <<'PY_ENTRY_INSTANCES'
import os
from pathlib import Path
import re
import stat
import sys

base = Path('/etc/amnezia/amneziawg')
try:
    info = base.lstat()
except FileNotFoundError:
    sys.exit(0)
if base.resolve() != base or not stat.S_ISDIR(info.st_mode):
    raise SystemExit('The AWG configuration directory must be a canonical directory without symlinks.')
for directory in (base, *base.parents):
    info = directory.lstat()
    if info.st_uid != 0 or info.st_mode & 0o022:
        raise SystemExit('The AWG configuration directory and its parents must be root-owned and not writable by other accounts.')
for path in sorted(base.glob('*.conf')):
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,14}', path.stem):
        continue
    fd = None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or info.st_mode & 0o077:
            continue
        if info.st_size > 1024 * 1024:
            continue
        with os.fdopen(fd, 'r', encoding='utf-8') as stream:
            fd = None
            text = stream.read(1024 * 1024 + 1)
        section, ports = '', []
        for line in text.splitlines():
            line = line.split('#', 1)[0].strip()
            if line.startswith('['):
                section = line
            elif section == '[Interface]' and '=' in line:
                name, value = (part.strip() for part in line.split('=', 1))
                if name == 'ListenPort':
                    ports.append(value)
        # Exported client profiles have no server ListenPort and are not instances.
        if len(ports) == 1 and re.fullmatch(r'[1-9][0-9]{0,4}', ports[0]) and int(ports[0]) <= 65535:
            print(path.stem)
    except (OSError, UnicodeError):
        print('Skipped an unreadable saved profile: ' + path.name, file=sys.stderr)
    finally:
        if fd is not None:
            os.close(fd)
PY_ENTRY_INSTANCES
}

entry_run() {
    local script=${BASH_SOURCE[0]}
    [[ -f $script && -r $script ]] || { say 'Save this script to a readable file before opening the menu.' >&2; return 1; }
    # A new Bash process preserves errexit inside the installer and isolates EXIT traps and lock FDs.
    bash -- "$script" "$@"
}

entry_manage() {
    local listing name choice index
    local -a instances=()
    listing=$(entry_instances) || return
    while IFS= read -r name; do
        if [[ -n $name ]]; then instances+=("$name"); fi
    done <<< "$listing"
    if (( ${#instances[@]} == 0 )); then
        say 'No saved native AWG instances found. Choose installation from the main menu when ready.'
        return 0
    fi
    while true; do
        say ''
        say 'Choose an existing AWG instance:'
        for ((index = 0; index < ${#instances[@]}; index++)); do
            say "$((index + 1))) ${instances[index]}"
        done
        say '0) Back'
        entry_prompt choice 'Instance: ' || return 0
        [[ $choice == 0 ]] && return 0
        if [[ $choice =~ ^[1-9][0-9]{0,3}$ ]] && (( 10#$choice <= ${#instances[@]} )); then
            index=$((10#$choice - 1))
            entry_run --manage "${instances[index]}"
            return
        fi
        say 'Choose one of the listed instance numbers, or 0 to go back.'
    done
}

entry_menu() {
    local choice status
    while true; do
        say ''
        say 'AmneziaWG main menu'
        say '1) Install a new instance'
        say '2) Manage an existing instance'
        say '3) Initialize / install command (awg-manage)'
        say '4) Check / update script'
        say '0) Exit'
        entry_prompt choice 'Select: ' || return 0
        case $choice in
            0) return 0 ;;
            1)
                if entry_run --install; then :; else
                    status=$?
                    say "Installation exited with status $status. Review the messages above before retrying." >&2
                fi
                ;;
            2)
                if entry_manage; then :; else
                    status=$?
                    say "Management exited with status $status. Review the messages above before retrying." >&2
                fi
                ;;
            3)
                if entry_run --initialize; then
                    # Initialization may relocate this script; the old menu must stop.
                    return 0
                else
                    status=$?
                    say "Script initialization exited with status $status. Review the messages above before retrying." >&2
                fi
                ;;
            4)
                if entry_run --update; then
                    # Stop the old menu even when the child replaced the script on disk.
                    return 0
                else
                    status=$?
                    say "Script update exited with status $status. Review the messages above before retrying." >&2
                fi
                ;;
            *) say 'Choose 1, 2, 3, 4, or 0.' ;;
        esac
    done
}

main() {
    if (( $# == 0 )); then
        entry_start
        return
    fi
    case ${1:-} in
        --version)
            (( $# == 1 )) || die 'Use --version without extra arguments.'
            say "$EASY_AWG_VERSION"
            return
            ;;
        --update|--check-update)
            local update_command=$1
            (( $# == 1 )) || die 'Use --update or --check-update without extra arguments.'
            if [[ $update_command == --check-update ]]; then entry_update --check; else entry_update; fi
            return
            ;;
    esac
    if [[ ${1:-} == --initialize ]]; then
        shift
        entry_initialize "$@"
        return
    fi
    if [[ ${1:-} == --install-command ]]; then
        shift
        entry_install_command "$@"
        return
    fi
    if [[ ${1:-} == --help ]]; then
        say 'Usage: sudo bash setup-manage-amneziawg.sh  (interactive main menu)'
        say '       sudo bash setup-manage-amneziawg.sh --install'
        say '       sudo bash setup-manage-amneziawg.sh --initialize'
        say '       sudo bash setup-manage-amneziawg.sh --install-command'
        say '       sudo bash setup-manage-amneziawg.sh --version'
        say '       sudo bash setup-manage-amneziawg.sh --check-update'
        say '       sudo bash setup-manage-amneziawg.sh --update'
        say 'No arguments offers first-run script initialization, then opens the main menu: install, manage, initialize, or update.'
        say 'Initialization asks for a private installation directory and creates awg-manage. A protected root-owned source is removed after verified installation; other source paths are retained. Existing VPN data stays unchanged.'
        say 'Updates use Accec/easy-awg stable Release assets and SHA256SUMS, require APPLY, back up the old script, and never downgrade.'
        say 'Only this script is replaced; AWG packages, running services, saved accounts, and network policies remain unchanged. Re-run after updating.'
        say 'Shortcut installation links /usr/local/bin/awg-manage to this script after APPLY; existing different commands remain untouched.'
        say '       sudo bash setup-manage-amneziawg.sh --enable-psk INTERFACE [CLIENT_PROFILE]'
        say '       sudo bash setup-manage-amneziawg.sh --check INTERFACE [CLIENT_PROFILE]'
        say '       sudo bash setup-manage-amneziawg.sh --manage INTERFACE'
        say '       sudo bash setup-manage-amneziawg.sh --add-client INTERFACE NAME'
        say '       sudo bash setup-manage-amneziawg.sh --list-clients INTERFACE'
        say '       sudo bash setup-manage-amneziawg.sh --export-client INTERFACE NAME [/ABSOLUTE/NAME.conf]'
        say '       sudo bash setup-manage-amneziawg.sh --remove-client INTERFACE NAME'
        say '       sudo bash setup-manage-amneziawg.sh --set-port INTERFACE PORT'
        say '       sudo bash setup-manage-amneziawg.sh --configure-vpc [INTERFACE] [--preview]'
        say '       sudo bash setup-manage-amneziawg.sh --doctor INTERFACE'
        say '       sudo bash setup-manage-amneziawg.sh --health INTERFACE'
        say '       sudo bash setup-manage-amneziawg.sh --disable-client INTERFACE NAME'
        say '       sudo bash setup-manage-amneziawg.sh --enable-client INTERFACE NAME'
        say '       sudo bash setup-manage-amneziawg.sh --set-expiry INTERFACE NAME UTC_TIMESTAMP_OR_none'
        say '       sudo bash setup-manage-amneziawg.sh --enforce-expiry INTERFACE'
        say '       sudo bash setup-manage-amneziawg.sh --configure-network INTERFACE [split|full] [--preview]'
        say '       sudo bash setup-manage-amneziawg.sh --show-dns INTERFACE'
        say '       sudo bash setup-manage-amneziawg.sh --configure-dns INTERFACE [--preview]'
        say '       sudo bash setup-manage-amneziawg.sh --disable-dns INTERFACE [--preview]'
        say '       sudo bash setup-manage-amneziawg.sh --set-access INTERFACE NAME [RULE ...|inherit|deny] [--preview]'
        say '       sudo bash setup-manage-amneziawg.sh --backup INTERFACE [/ABSOLUTE/NEW_DIRECTORY]'
        say '       sudo bash setup-manage-amneziawg.sh --restore INTERFACE /ABSOLUTE/BACKUP_DIRECTORY [--preview]'
        say '       sudo bash setup-manage-amneziawg.sh --uninstall INTERFACE [--preview]'
        say '       sudo bash setup-manage-amneziawg.sh --export-qr INTERFACE NAME [/ABSOLUTE/NAME.png]'
        say 'Guided setup: seven prompts with editable defaults, input validation, then APPLY confirmation.'
        say 'MTU defaults to 1280; set AWG_MTU or choose auto or a manual value from 1280 to 1500 in the wizard.'
        say 'Installs AmneziaWG, creates one client with a PSK, and adds one public UDP rule to active UFW.'
        say 'PSK update preserves existing keys and networking, backs up profiles, and updates only the selected peer.'
        say 'Check mode reads profiles and live state without printing secrets or changing configuration.'
        say 'New installation creates only the server, with no default client. Add named clients in management; split/full routing remains configurable.'
        say 'VPC wizard: choose the existing AWG interface, private VPC exit, target, and SNAT address; review before APPLY.'
        say 'VPC changes update stored client routes. Re-export/re-import distributed profiles; cloud firewalls remain unchanged.'
        say 'Full mode provides IPv4 Internet egress, explicit DNS, and tunneled IPv6 blocking; it is not dual-stack Internet or a client kill switch.'
        say 'Private DNS is optional per instance: named IPv4 records plus upstream forwarding. Connected clients send system DNS queries through the tunnel, not only private names.'
        say 'DNS changes require profile re-export/re-import. VPC routes, destination ACLs, HTTPS certificates, and Passkey RP/origin settings remain separate.'
        say 'Access RULE: IPv4CIDR:tcp:PORT, IPv4CIDR:udp:PORT, IPv4CIDR:icmp, or IPv4CIDR:any. ACLs run on the gateway.'
        say 'Expiry uses UTC and a systemd timer. QR export requires an existing qrencode command; QR images contain private keys.'
        say 'Omit the export path (or leave it blank in the menu) to display the profile or QR in the terminal after APPLY. Session recordings may capture secrets.'
        say 'Backups contain secrets. Restore/uninstall preview before confirmation and retain unrelated services and shared packages.'
        say 'Accounts are AmneziaWG peers. Named profiles: /etc/amnezia/amneziawg/clients/INTERFACE/NAME.conf; initial refers to the existing first profile.'
        say 'Client names: 1-15 ASCII letters, digits, dots, underscores, or hyphens; start with a letter. Example: alice.mac.'
        say 'Existing-account menu actions show a numbered account list; select a number, or 0 to go back. CLI commands still take account names.'
        say 'Peer/port changes and exports require APPLY. Keep a separate SSH/console session; port changes also require a manual cloud-firewall check.'
        say 'Requires AmneziaWG 3.1-compatible tools, kernel support, and clients; a standard WireGuard client does not support this profile.'
        say 'New installation uses the official Amnezia PPA after APPLY. Packages and repository additions remain if later setup fails.'
        say 'This creates a separate native AWG interface. It does not migrate or take over an existing Amnezia Docker deployment.'
        return
    fi
    case ${1:-} in
        --configure-vpc)
            shift
            (( EUID == 0 )) || die 'Run with sudo or as root.'
            [[ $(uname -s) == Linux ]] || die 'Run on the Linux AmneziaWG server.'
            local vpc_command
            for vpc_command in python3 flock; do
                command -v "$vpc_command" >/dev/null || die "Required command missing: $vpc_command"
            done
            acquire_lock
            if [[ -n ${1:-} && $1 != --preview ]]; then
                manage_clients --assert-vpc-compatible "$1" || return
            fi
            configure_vpc "$@"
            return
            ;;
        --manage|--add-client|--list-clients|--export-client|--remove-client|--set-port|--doctor|--health|--backup|--restore|--uninstall|--export-qr|--disable-client|--enable-client|--set-expiry|--enforce-expiry|--configure-network|--set-access|--assert-vpc-compatible|--check-server|--check-empty-server|--show-dns|--configure-dns|--disable-dns)
            (( $# >= 2 )) || die 'Supply the AmneziaWG interface; use --help for command forms.'
            [[ $2 =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]] || die 'Invalid AmneziaWG interface name.'
            (( EUID == 0 )) || die 'Run with sudo or as root.'
            [[ $(uname -s) == Linux ]] || die 'Run on the Linux AmneziaWG server.'
            local manager_command
            local manager_commands=(awg ip python3 flock)
            if [[ $1 == --health ]]; then manager_commands=(python3 flock); fi
            for manager_command in "${manager_commands[@]}"; do
                command -v "$manager_command" >/dev/null || die "Required command missing: $manager_command"
            done
            if [[ $1 == --set-port || $1 == --manage ]]; then
                for manager_command in ufw ss; do
                    command -v "$manager_command" >/dev/null || die "Required command missing: $manager_command"
                done
            fi
            if [[ $1 != --doctor && $1 != --health ]]; then check_awg_version; fi
            # Scheduled enforcement takes this same lock inside Python.
            if [[ $1 != --enforce-expiry ]]; then acquire_lock; fi
            local manager_status
            while true; do
                if manage_clients "$@"; then
                    return 0
                else
                    manager_status=$?
                fi
                if [[ $1 == --manage && $manager_status == 42 ]]; then
                    configure_vpc "$2" || return
                else
                    return "$manager_status"
                fi
            done
            ;;
    esac
    if [[ ${1:-} == --enable-psk || ${1:-} == --check ]]; then
        (( $# >= 2 && $# <= 3 )) || die 'Supply INTERFACE and optionally an absolute CLIENT_PROFILE path.'
        local mode=$1 interface=$2 client=${3:-} command_name
        [[ $interface =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]] || die 'Invalid AmneziaWG interface name.'
        (( EUID == 0 )) || die 'Run with sudo or as root.'
        [[ $(uname -s) == Linux ]] || die 'Run on the Linux AmneziaWG server.'
        for command_name in awg ip python3 flock; do
            command -v "$command_name" >/dev/null || die "Required command missing: $command_name"
        done
        check_awg_version
        if [[ $mode == --check && $# == 2 &&
              ! -e /etc/amnezia/amneziawg/clients/$interface.conf && ! -L /etc/amnezia/amneziawg/clients/$interface.conf &&
              ! -e /etc/amnezia/amneziawg/$interface-client.conf && ! -L /etc/amnezia/amneziawg/$interface-client.conf ]]; then
            acquire_lock
            manage_clients --check-server "$interface"
            return
        fi
        if [[ -z $client ]]; then
            if [[ -e /etc/amnezia/amneziawg/clients/$interface.conf && -e /etc/amnezia/amneziawg/$interface-client.conf ]]; then
                die 'Both new and legacy client profiles exist. Supply the intended CLIENT_PROFILE explicitly.'
            fi
            client="/etc/amnezia/amneziawg/clients/$interface.conf"
            [[ -e $client ]] || client="/etc/amnezia/amneziawg/$interface-client.conf"
        fi
        [[ $client == /* ]] || die 'CLIENT_PROFILE must be an absolute path.'
        acquire_lock
        if [[ $mode == --check ]]; then
            update_psk "$interface" "$client" --check
        else
            update_psk "$interface" "$client"
        fi
        return
    fi
    (( $# == 1 )) && [[ $1 == --install ]] || die 'Use --help, --install, or run without arguments for the main menu.'
    shift
    (( EUID == 0 )) || die 'Run with sudo or as root.'
    [[ $(uname -s) == Linux ]] || die 'Run on the Ubuntu server.'
    if [[ ! -r /etc/os-release ]] || ! grep -qx 'ID=ubuntu' /etc/os-release; then
        die 'This script targets Ubuntu.'
    fi
    for cmd in ufw ip ss python3 systemctl flock apt-get; do
        command -v "$cmd" >/dev/null || die "Required command missing: $cmd"
    done
    acquire_lock
    WORK=$(mktemp -d /tmp/manage-amneziawg.XXXXXXXX)
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    export LC_ALL=C

    ufw status | grep -qx 'Status: active' || die 'UFW must already be active; this script does not reset or enable it.'
    ufw show added > "$WORK/ufw-before.txt"
    ip -j -4 route show table all > "$WORK/routes.json"
    guide_inputs < /dev/tty
    validate_mtu "$AWG_MTU" || die 'Invalid tunnel MTU.'

    [[ $AWG_IF =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]] || die 'Invalid AmneziaWG interface name.'
    [[ $PUBLIC_IF =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || die 'Invalid public interface name.'
    if [[ ! $AWG_PORT =~ ^[1-9][0-9]{0,4}$ ]] || (( AWG_PORT > 65535 )); then die 'Invalid UDP port.'; fi
    ip -j -4 route show table all > "$WORK/routes.json"
    ip -j -4 address show dev "$PUBLIC_IF" > "$WORK/addresses.json"
    python3 - "$SERVER_ADDRESS" "$PUBLIC_IP" "$WORK/routes.json" "$WORK/addresses.json" <<'PY'
import ipaddress, json, sys
server = ipaddress.IPv4Interface(sys.argv[1])
public = ipaddress.IPv4Address(sys.argv[2])
network = server.network
if not (network.is_private and network.prefixlen <= 30
        and server.ip not in (network.network_address, network.broadcast_address)
        and public not in network):
    raise SystemExit('Invalid VPN addresses.')
for route in json.load(open(sys.argv[3])):
    destination = route.get('dst', 'default')
    if destination == 'default': continue
    existing = ipaddress.IPv4Network(destination, strict=False)
    if existing.prefixlen and network.overlaps(existing):
        raise SystemExit('VPN subnet overlaps an existing server route: ' + destination)
addresses = [a['local'] for i in json.load(open(sys.argv[4])) for a in i.get('addr_info', [])]
if str(public) not in addresses:
    raise SystemExit('Public IP is not assigned to the selected interface.')
PY
    if ip link show dev "$AWG_IF" >/dev/null 2>&1; then die "Interface already exists: $AWG_IF"; fi
    if [[ -n $(ss -H -lun "sport = :$AWG_PORT") ]]; then die "UDP port already occupied: $AWG_PORT"; fi
    if systemctl is-active --quiet "awg-quick@$AWG_IF" 2>/dev/null ||
       systemctl is-enabled --quiet "awg-quick@$AWG_IF" 2>/dev/null ||
       systemctl is-active --quiet "wg-quick@$AWG_IF" 2>/dev/null ||
       systemctl is-enabled --quiet "wg-quick@$AWG_IF" 2>/dev/null; then
        die 'The selected AmneziaWG unit is already active or enabled.'
    fi
    [[ ! -e /etc/wireguard/$AWG_IF.conf && ! -L /etc/wireguard/$AWG_IF.conf ]] || die 'An existing native WireGuard configuration uses this interface name; it was retained.'
    AWG_FILE="/etc/amnezia/amneziawg/$AWG_IF.conf"
    CLIENT_DIR="/etc/amnezia/amneziawg/clients/$AWG_IF"
    METADATA_FILE="$CLIENT_DIR/metadata.json"
    [[ ! -L /etc/amnezia && ! -L /etc/amnezia/amneziawg && ! -L /etc/amnezia/amneziawg/clients ]] || die 'AmneziaWG directories must not be symbolic links.'
    prepare_awg_directories check
    for path in "$AWG_FILE" "$CLIENT_DIR" "/etc/amnezia/amneziawg/clients/$AWG_IF.conf" "/etc/amnezia/amneziawg/$AWG_IF-client.conf"; do
        [[ ! -e $path && ! -L $path ]] || die "Existing configuration retained: $path"
    done
    ufw status | grep -qx 'Status: active' || die 'UFW must already be active; this script does not reset or enable it.'
    ufw show added > "$WORK/ufw-before.txt"
    if grep -Eq "(^|[^0-9])$AWG_PORT([^0-9]|$)" "$WORK/ufw-before.txt"; then
        die 'A UFW rule already mentions this UDP port. Review the existing rule before continuing.'
    fi
    say "AmneziaWG endpoint: $PUBLIC_IP:$AWG_PORT/udp on $PUBLIC_IF"
    say "Server: $SERVER_ADDRESS; interface: $AWG_IF; initial clients: 0"
    say "MTU: $AWG_MTU (auto selects the server tunnel MTU; future clients inherit it)."
    say 'Only AmneziaWG configuration and one UDP allow rule will be added. Existing services and other rules stay in place.'
    say 'Check that the proposed VPN subnet does not overlap the client LAN or another VPN.'
    say 'This is a new native AmneziaWG 3.1 interface, not a migration of an existing WireGuard or Amnezia Docker deployment.'
    say 'The official Amnezia PPA, running-kernel headers, and AWG packages may be installed; these remain if later setup fails.'
    say 'Installing the AWG kernel module can affect backend selection on a later restart of other Amnezia deployments.'
    say 'Existing services are not restarted. No global upgrade, firewall reset, kernel unload, or automatic reboot is performed.'
    read -r -p 'Type APPLY to continue: ' reply < /dev/tty
    [[ $reply == APPLY ]] || die 'No installation changes applied.'

    ensure_awg_tools
    # Package installation may have created directories; recheck trust and initialize only empty private ones.
    prepare_awg_directories create
    for path in "$AWG_FILE" "$CLIENT_DIR" "/etc/amnezia/amneziawg/clients/$AWG_IF.conf" "/etc/amnezia/amneziawg/$AWG_IF-client.conf"; do
        [[ ! -e $path && ! -L $path ]] || die "A configuration appeared during package installation and was retained: $path"
    done
    mkdir -m 700 -- "$CLIENT_DIR"
    CLIENT_DIR_CREATED=1
    write_profiles
    FILES_CREATED=1
    install -m 600 "$WORK/server.conf" "$AWG_FILE"
    UFW_RULE=(allow in on "$PUBLIC_IF" proto udp to "$PUBLIC_IP" port "$AWG_PORT" comment 'manage-awg-udp')
    RULE_ADDED=1
    ufw "${UFW_RULE[@]}"
    AWG_ATTEMPTED=1
    systemctl enable --now "awg-quick@$AWG_IF"
    systemctl is-active --quiet "awg-quick@$AWG_IF"
    ip link show dev "$AWG_IF" >/dev/null
    write_server_metadata
    # Read back full 3.1 parameters and the server identity before accepting a peer-free installation.
    manage_clients --check-empty-server "$AWG_IF" >/dev/null
    SUCCESS=1
    say ''
    say 'Server interface configured and enabled at boot. No client account or profile was created.'
    say "Add a named client from management option 1: sudo bash $0 --manage $AWG_IF"
    say 'Use an AmneziaWG 3.1-compatible client for profiles you export after adding an account.'
    say "If a Vultr Firewall is attached, also allow inbound UDP $AWG_PORT there."
    say "After adding and activating a client, check its handshake with: awg show $AWG_IF"
    say "Read-only server check: sudo bash $0 --check $AWG_IF"
    say "New clients initially route only ${SERVER_ADDRESS%/*}/32 unless a different network policy is configured."
    say 'Existing public service access remains unchanged. Client handshake and reboot behavior still require verification.'
    say ''
    say 'Optional traffic mode: 1) Keep split routing (default); 2) Configure full Internet traffic.'
    local traffic_choice
    while true; do
        read -r -p 'Traffic mode [1]: ' traffic_choice < /dev/tty || traffic_choice=1
        case ${traffic_choice:-1} in
            1) break ;;
            2)
                if ! manage_clients --configure-network "$AWG_IF" full; then
                    say 'AWG installation is complete. Full traffic setup did not complete; inspect the error before retrying.' >&2
                    return 1
                fi
                break
                ;;
            *) say 'Choose 1 or 2.' ;;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi

