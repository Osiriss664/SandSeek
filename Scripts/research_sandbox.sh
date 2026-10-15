#!/usr/bin/env bash
# Builds and runs the web research sandbox with Apple `container`.
#
#   Scripts/research_sandbox.sh build    build the sandseek-sandbox image
#   Scripts/research_sandbox.sh start    start a fresh sandbox on a free port of 127.0.0.1
#   Scripts/research_sandbox.sh stop     stop and remove the sandbox
#   Scripts/research_sandbox.sh status   report whether the sandbox answers
#   Scripts/research_sandbox.sh selftest check that the sandbox refuses the Mac,
#                                        the local network and metadata addresses
#
# The sandbox is the only part of `sandseek` with internet access. It runs
# in its own Linux VM with a read-only root and no Mac folders mounted. A
# firewall inside the VM lets it reach public internet addresses, but not the
# Mac's own addresses (private or public, collected at start), plus DNS on
# the Mac when the Mac is its name server, and accepts new inbound connections
# on port 9100 inside the VM only, from the VM's default gateway (the address
# the published port connects from; anything that can send from that address,
# such as processes on the Mac, can still reach 9100). The
# server runs as a non-root user with no Linux capabilities. Its port is
# published to the Mac's loopback address only, on a free port that `start`
# picks each time (inside the VM the port stays 9100). See docs/SECURITY.md.
#
# Each `start` makes a new random secret and writes it to a file (mode 0600, in
# a folder only you can write to). The folder is mounted read-only into the VM,
# and the sandbox reads the secret from it once, when it starts. Every request
# to the sandbox must be signed with the secret, and every answer is signed
# with it too, so SandSeek can tell the sandbox from another program on the
# port. The secret is in no environment variable and no command line. `stop`
# deletes the file: no secret means the sandbox is not running. The Mac's own
# addresses go into the same folder as a second file, `blocked-addresses`.
#
# One SandSeek at a time. `start` first takes a lock (the file `lock` in that
# folder) and keeps it for as long as the sandbox runs; a second `start`, from
# the app, the command line or another copy, fails with a plain message
# instead of stopping the first one's VM. The lock is an operating system
# lock (flock) held by a small perl process that `start` leaves running; it
# writes its pid and start time into the file. The system drops the lock when
# that process ends, however it ends. That process does not end when the app
# or the shell that ran `start` crashes: it and the VM keep running until a
# `stop`, or until the next `start` of the same app, which is told the
# holder's pid in SANDSEEK_SANDBOX_REPLACE and takes over from exactly that
# one. Any other holder is left alone and `start` fails with a plain message.
# `start` also records the port it picked (file `port`) and the VM's name
# (file `vm-name`), both mode 0600, for the app, the command line and the
# other commands to read. Under the lock, `start` removes the VMs and files a
# crashed run left behind. SANDSEEK_SANDBOX_PORT fixes the port (for tests).
#
# The only `container` this script runs is Apple's, at /usr/local/bin/container,
# and only after `require_container` has checked it (see below). It never
# looks for `container` through PATH, and it runs with a fixed environment:
# nothing from your shell reaches `container` but the settings named below.

set -euo pipefail
# No file name expansion: $dns_servers is split into words below, not matched.
set -f

# A line break for ${...} patterns below: bash 3.2 (macOS /bin/bash) is not
# reliable with $'\n' written inside them.
nl=$'\n'

# The old TUFF_RESEARCH_ names are ignored now; say so instead of silently
# using the defaults. This does not stop the script.
for old_name in TUFF_RESEARCH_SANDBOX_PORT TUFF_RESEARCH_DNS; do
  if [[ -n "${!old_name+x}" ]]; then
    echo "warning: $old_name is the old name and is ignored; use SANDSEEK_${old_name#TUFF_RESEARCH_}" >&2
  fi
done

# A fixed environment. The script starts itself again once with `env -i`, so
# nothing else of your shell's environment (DYLD_*, BASH_ENV, proxy variables,
# tokens) reaches it, `container` or the programs they start. These are kept:
# HOME, USER, LOGNAME and TMPDIR, the language, and the three settings the
# script reads: SANDSEEK_SANDBOX_PORT, SANDSEEK_SANDBOX_REPLACE, SANDSEEK_DNS and
# SEARXNG_URL. The
# marker below tells the second run that it already has the fixed environment.
if [[ "${SANDSEEK_SANDBOX_CLEAN_ENV:-}" != 1 ]]; then
  clean_env=(PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8
             HOME="${HOME:?HOME is not set}" SANDSEEK_SANDBOX_CLEAN_ENV=1)
  for kept_name in USER LOGNAME TMPDIR SANDSEEK_SANDBOX_PORT SANDSEEK_SANDBOX_REPLACE SANDSEEK_DNS SEARXNG_URL; do
    if [[ -n "${!kept_name:-}" ]]; then
      clean_env+=("$kept_name=${!kept_name}")
    fi
  done
  exec /usr/bin/env -i "${clean_env[@]}" /bin/bash "${BASH_SOURCE[0]}" "$@"
fi
# Whatever the marker said, only system folders are searched from here on.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

image="sandseek-sandbox:latest"
# Every VM is called sandseek-sandbox-<8 hex digits>, new at each start, so
# `container list | grep sandseek` finds them. `name` is set by `start` (made)
# and by the other commands (read from the vm-name file).
name_prefix="sandseek-sandbox"
name=""
# SANDSEEK_SANDBOX_PORT fixes the Mac's port (tests). Without it, `start` picks
# a free one and records it, and the other commands read it back.
port_override="${SANDSEEK_SANDBOX_PORT:-}"
port="$port_override"
# DNS servers for the VM, space-separated. Unset, the VM asks the Mac, which
# uses the same DNS as the rest of the Mac; set it (for example to
# "1.1.1.1 9.9.9.9") to use public resolvers instead.
dns_servers="${SANDSEEK_DNS:-}"
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
context="$script_directory/../Sandbox"
# Where the secret goes. SandSeek reads the same file (ResearchSandboxSecret in
# Sources/SandSeekCore/ResearchSandboxSigning.swift); change both together.
# The folder, not the file, is mounted into the VM, at the path below.
secret_folder="$HOME/Library/Application Support/SandSeek/sandbox"
secret_file="$secret_folder/secret"
vm_secret_folder="/run/sandseek-sandbox"
# What `start` records next to the secret (the app reads the same files; see
# ResearchSandboxFiles in Sources/SandSeekCore): the Mac's port, the VM's
# name, and the lock.
port_file="$secret_folder/port"
name_file="$secret_folder/vm-name"
lock_file="$secret_folder/lock"
# A perl that is not Apple's own copy in /usr/bin is never used.
perl_bin=/usr/bin/perl
# The Mac's own interface addresses, one per line, written at each start. The
# VM's entrypoint puts them into its firewall and the server refuses them (see
# Sandbox/entrypoint.sh and Sandbox/server.py); the file name must match
# BLOCKED_FILE_NAME in server.py. They are not secret.
blocked_file="$secret_folder/blocked-addresses"
# Where `ifconfig` is on macOS. Never found through PATH.
ifconfig_bin=/sbin/ifconfig
# One public address that is no Mac's own, added to the list only so the
# security check can tell the list from the private ranges (a.root-servers.net;
# SandSeek never talks to it).
test_address=198.41.0.4
# SandSeek 0.1.0 wrote its secret here, in TUFF's folder; it is not TUFF's.
old_secret_file="$HOME/Library/Application Support/TUFF/web-sandbox.secret"

# SANDSEEK_SANDBOX_PORT and SANDSEEK_DNS go into `container run` arguments;
# a typo gives a confusing error from deep inside it, so check the form first.
# Nothing to check when the port is not fixed.
check_port() {
  [[ -n "$port_override" ]] || return 0
  if ! [[ "$port" =~ ^[1-9][0-9]{3,4}$ ]] || (( 10#$port < 1024 || 10#$port > 65535 )); then
    echo "SANDSEEK_SANDBOX_PORT must be a port number from 1024 to 65535, not: $port" >&2
    exit 2
  fi
  port=$((10#$port))
}

check_dns() {
  local server octet
  for server in $dns_servers; do
    if [[ "$server" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      for octet in ${server//./ }; do
        (( 10#$octet <= 255 )) || { echo "SANDSEEK_DNS: not an IPv4 address: $server" >&2; exit 2; }
      done
    elif ! [[ "$server" =~ ^[0-9a-fA-F:]{2,39}$ && "$server" == *:*:* && "$server" != *:::* ]]; then
      echo "SANDSEEK_DNS must list IPv4 or IPv6 addresses separated by spaces, not: $server" >&2
      exit 2
    fi
  done
}

# --- The Mac's own addresses -----------------------------------------------
# Every address goes into an nft rule in the VM, so each one is checked
# strictly here (and again in entrypoint.sh and server.py); what does not pass
# is left out and reported.

# Succeeds for a plain dotted IPv4 address: four groups of 0 to 255, no leading
# zeros, nothing else.
valid_ipv4() {
  local text="$1" part
  [[ "$text" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for part in $text; do
    [[ "$part" == 0 || "$part" != 0* ]] || return 1
    (( 10#$part <= 255 )) || return 1
  done
}

# Succeeds for an IPv6 address in the plain hexadecimal form (groups of one to
# four digits, at most one "::"): no zone id, no dotted tail, no brackets.
valid_ipv6() {
  local text="$1" flat group count=0 compressed=0
  [[ "$text" =~ ^[0-9a-fA-F:]{2,39}$ && "$text" == *:*:* && "$text" != *:::* ]] || return 1
  if [[ "$text" == *::* ]]; then
    compressed=1
    flat="${text#*::}"
    [[ "$flat" != *::* ]] || return 1
    [[ "$text" != :* || "$text" == ::* ]] || return 1
    [[ "$text" != *: || "$text" == *:: ]] || return 1
    flat="${text/::/:}"
    flat="${flat#:}"
    flat="${flat%:}"
  else
    [[ "$text" != :* && "$text" != *: ]] || return 1
    flat="$text"
  fi
  local IFS=:
  for group in $flat; do
    [[ "$group" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
    count=$((count + 1))
  done
  if (( compressed )); then (( count <= 7 )); else (( count == 8 )); fi
}

# Reads `ifconfig` output on standard input and prints the address of every
# "inet" and "inet6" line, once each, lowercase, without a zone id
# (`fe80::1%lo0`), one per line. Loopback and link-local addresses are
# included. An address that does not pass the checks above is reported on
# standard error and left out.
collect_mac_addresses() {
  LC_ALL=C awk 'NF >= 2 && ($1 == "inet" || $1 == "inet6") { sub(/%.*/, "", $2); print $2 }' |
  {
    local address seen=" "
    while read -r address; do
      address="$(printf '%s' "$address" | LC_ALL=C tr 'A-F' 'a-f')"
      if ! valid_ipv4 "$address" && ! valid_ipv6 "$address"; then
        printf 'ignoring an interface address that is not valid: %q\n' "${address:0:64}" >&2
        continue
      fi
      [[ "$seen" != *" $address "* ]] || continue
      seen+="$address "
      printf '%s\n' "$address"
    done
  }
}

# Writes the Mac's addresses and $test_address to $blocked_file, in the secret
# folder (made by write_secret, which must run first). Like the secret, the
# file is written to a temporary file and renamed. Fails, with a message, when
# `ifconfig` fails or gives no usable address, or gives more than the 256 the
# server accepts.
write_blocked_addresses() {
  local output listing count temporary
  if ! output="$("$ifconfig_bin" 2>/dev/null)"; then
    echo "could not read the Mac's network addresses with $ifconfig_bin; not starting the sandbox" >&2
    return 1
  fi
  listing="$(collect_mac_addresses <<<"$output")" || return 1
  if [[ -z "$listing" ]]; then
    echo "found no usable network address of the Mac; not starting the sandbox" >&2
    return 1
  fi
  if [[ "$nl$listing$nl" != *"$nl$test_address$nl"* ]]; then
    listing+="$nl$test_address"
  fi
  count="$(printf '%s\n' "$listing" | wc -l | tr -d ' ')"
  if (( count > 256 )); then
    echo "the Mac has $count network addresses; at most 256 are handed to the sandbox" >&2
    return 1
  fi
  temporary="$(umask 077 && mktemp -- "$secret_folder/.blocked.XXXXXX")" || return 1
  if ! { printf '%s\n' "$listing" >"$temporary" \
         && chmod 600 "$temporary" \
         && mv -f -- "$temporary" "$blocked_file"; }; then
    rm -f -- "$temporary"
    echo "could not write $blocked_file" >&2
    return 1
  fi
}

# Apple's `container`, where Apple's installer puts it. Never found through
# PATH. SandSeek (the app) makes the same checks before it runs the tool; the
# team below is the one that signs Apple's release, and the requirement and the
# oldest version must match Sources/SandSeekAppLogic/ResearchContainerTool.swift.
container_bin=/usr/local/bin/container
container_requirement='anchor apple generic and certificate leaf[subject.OU] = "UPBK2H6LZM"'
container_minimum_major=1
container_minimum_minor=5
container_minimum_patch=0

# How `stat` prints a file's owner (a number) and permissions (octal). On macOS
# /usr/bin/stat is the BSD one; the other form is for Linux, where the script's
# tests run.
if [[ "$(/usr/bin/uname -s)" == Darwin ]]; then
  stat_format=(-f '%u %Lp')
else
  stat_format=(-c '%u %a')
fi

# Succeeds when $1 belongs to root and neither its group nor others can write
# to it. A link is judged itself, not by what it points to.
owned_by_root_and_closed() {
  local facts owner mode
  facts="$(/usr/bin/stat "${stat_format[@]}" -- "$1" 2>/dev/null)" || return 1
  owner="${facts%% *}"
  mode="${facts#* }"
  [[ "$owner" == 0 && "$mode" =~ ^[0-7]+$ ]] || return 1
  (( (8#$mode & 8#022) == 0 ))
}

# Succeeds when the absolute path $1 and every folder above it, up to /, are
# owned by root and closed to group and others. If not, sets $untrusted_path
# to the first one that is not (a global, since the caller needs it).
untrusted_path=""
chain_is_closed() {
  local path="$1"
  [[ "$path" == /* ]] || { untrusted_path="$path"; return 1; }
  while :; do
    owned_by_root_and_closed "$path" || { untrusted_path="$path"; return 1; }
    [[ "$path" == / ]] && return 0
    path="${path%/*}"
    [[ -n "$path" ]] || path=/
  done
}

# Prints the real path of $1: links followed, with plain `readlink` (macOS has
# no `readlink -f` in bash 3.2 days) and `cd -P` for the folder.
resolve_path() {
  local path="$1" target directory count=0
  while [[ -L "$path" ]]; do
    count=$((count + 1))
    (( count <= 20 )) || return 1
    target="$(/usr/bin/readlink "$path")" || return 1
    case "$target" in
      /*) path="$target" ;;
      *) path="${path%/*}/$target" ;;
    esac
  done
  directory="${path%/*}"
  [[ -n "$directory" ]] || directory=/
  directory="$(cd -P -- "$directory" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s' "${directory%/}" "${path##*/}"
}

# Succeeds when the output $1 of `container --version` names a version that is
# at least the oldest one SandSeek supports. The first "1.5" or "1.5.0" counts.
version_is_supported() {
  local pattern='([0-9]+)\.([0-9]+)(\.([0-9]+))?' major minor patch
  [[ "$1" =~ $pattern ]] || return 1
  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  patch=$((10#${BASH_REMATCH[4]:-0}))
  if (( major != container_minimum_major )); then
    (( major > container_minimum_major ))
  elif (( minor != container_minimum_minor )); then
    (( minor > container_minimum_minor ))
  else
    (( patch >= container_minimum_patch ))
  fi
}

# Refuses (exit 1) unless $container_bin is Apple's container tool: an
# executable regular file that only root can change, together with every
# folder above it, as given and with links followed; signed by Apple's team
# (codesign checks the chain to Apple's certificate authority and the team);
# and new enough. Then makes sure the container system service runs. A hung
# `container` command is ended by the app's time limit, not here.
require_container() {
  local resolved version
  if [[ ! -e "$container_bin" && ! -L "$container_bin" ]]; then
    echo "Apple container is not installed at $container_bin; see https://github.com/apple/container" >&2
    exit 1
  fi
  resolved="$(resolve_path "$container_bin")" || resolved=""
  if [[ -z "$resolved" || ! -f "$resolved" || ! -x "$resolved" ]]; then
    echo "$container_bin is not an executable file, so it is not run. Reinstall Apple container with Apple's installer: https://github.com/apple/container" >&2
    exit 1
  fi
  if ! chain_is_closed "$container_bin" || ! chain_is_closed "$resolved"; then
    if [[ "$untrusted_path" == "$container_bin" || "$untrusted_path" == "$resolved" ]]; then
      echo "$untrusted_path can be changed by you or by others, so it is not run. Reinstall Apple container with Apple's installer: https://github.com/apple/container" >&2
    else
      echo "The folder $untrusted_path, on the way to $container_bin, can be changed by you or by others, so it is not run. Apple's installer does not change this folder. To let SandSeek trust it, make it belong to root: sudo chown root:wheel $untrusted_path && sudo chmod 755 $untrusted_path (this affects an Intel Homebrew installed in /usr/local)." >&2
    fi
    exit 1
  fi
  if ! /usr/bin/codesign --verify --strict -R="$container_requirement" "$resolved" >/dev/null 2>&1; then
    echo "$container_bin is not signed by Apple, so it is not run. Install Apple container from https://github.com/apple/container" >&2
    exit 1
  fi
  if ! version="$("$container_bin" --version 2>&1)" || ! version_is_supported "$version"; then
    echo "Apple container $container_minimum_major.$container_minimum_minor.$container_minimum_patch or newer is needed; found: ${version:0:80}. Update it from https://github.com/apple/container" >&2
    exit 1
  fi
  "$container_bin" system status >/dev/null 2>&1 || "$container_bin" system start
}

# Makes a new secret (32 random bytes as 64 hex characters) and writes it to
# $secret_file. The file is written to a temporary file in the same folder,
# given mode 0600 and then renamed over the old one, so a reader sees the old
# secret or the new one and never half of it. Everything here is a shell
# builtin or reads /dev/urandom, so the secret is never in a command line. The
# folder is made with mode 0700; an existing one only has to be yours, not a
# symlink, and not writable by group or others, so that nobody else can replace
# the file. Its path goes into `--mount`, which splits on commas, so a comma or
# a line break in it is refused.
prepare_secret_folder() {
  local modes
  if [[ "$secret_folder" == *,* || "$secret_folder" == *"$nl"* ]]; then
    echo "the sandbox secret folder's path has a comma or a line break in it; not writing the sandbox secret" >&2
    return 1
  fi
  [[ -e "$secret_folder" || -L "$secret_folder" ]] || mkdir -p -m 700 -- "$secret_folder"
  if [[ -L "$secret_folder" || ! -d "$secret_folder" || ! -O "$secret_folder" ]]; then
    echo "$secret_folder is not a folder of yours; not writing the sandbox secret" >&2
    return 1
  fi
  modes="$(ls -ld -- "$secret_folder")"
  modes="${modes%% *}"
  if [[ "${modes:5:1}" == w || "${modes:8:1}" == [wtT] ]]; then
    echo "$secret_folder can be written to by others (${modes}); not writing the sandbox secret. Run chmod go-w on it" >&2
    return 1
  fi
  chmod 700 "$secret_folder"
}

# Then the secret itself, as described above.
write_secret() {
  local secret temporary
  prepare_secret_folder || return 1
  if [[ -d "$secret_file" ]]; then
    echo "$secret_file is a folder; not writing the sandbox secret" >&2
    return 1
  fi
  secret="$(LC_ALL=C od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
  if [[ ! "$secret" =~ ^[0-9a-f]{64}$ ]]; then
    echo "could not make a random secret" >&2
    return 1
  fi
  # No `--` after the mode below: macOS chmod reads it as a file name. The
  # path is absolute ($HOME), so it cannot be taken for an option.
  temporary="$(umask 077 && mktemp -- "$secret_folder/.secret.XXXXXX")" || return 1
  if ! { printf '%s' "$secret" >"$temporary" \
         && chmod 600 "$temporary" \
         && mv -f -- "$temporary" "$secret_file"; }; then
    rm -f -- "$temporary"
    echo "could not write $secret_file" >&2
    return 1
  fi
}

# Removes the secret, the list of the Mac's addresses, the port and the VM's
# name. The folder stays: it holds the lock file, which is never deleted (a
# new file under the same name would be a second lock).
remove_secret() {
  rm -f -- "$secret_file" "$blocked_file" "$port_file" "$name_file"
}

# --- Port, name, lock, leftovers -------------------------------------------

# Writes $2 and a line break to the file $1 in the secret folder, mode 0600,
# through a temporary file that is renamed (like the secret).
write_private_file() {
  local temporary
  temporary="$(umask 077 && mktemp -- "$secret_folder/.state.XXXXXX")" || return 1
  if ! { printf '%s\n' "$2" >"$temporary" \
         && chmod 600 "$temporary" \
         && mv -f -- "$temporary" "$1"; }; then
    rm -f -- "$temporary"
    echo "could not write $1" >&2
    return 1
  fi
}

# Succeeds for a plain file of yours that only you can read and write (a link
# is not followed: it fails). The app checks the same for the port file.
private_file_ok() {
  local facts
  [[ -f "$1" && ! -L "$1" ]] || return 1
  facts="$(/usr/bin/stat "${stat_format[@]}" -- "$1" 2>/dev/null)" || return 1
  [[ "$facts" == "$(/usr/bin/id -u) 600" ]]
}

# Sets $private_value to the first 64 bytes of the private file $1 without one
# final line break (and no more: a second line break stays, so the checks
# below refuse it, as the app and verify_sandbox_signature.py do). Fails when
# the file is not private (see private_file_ok). The "x" keeps $(...) from
# eating line breaks; call this directly, not inside $(...), for the same
# reason.
private_value=""
private_text() {
  local text
  private_value=""
  private_file_ok "$1" || return 1
  text="$(head -c 64 "$1"; printf x)" || return 1
  text="${text%x}"
  private_value="${text%"$nl"}"
}

# Prints the port `start` recorded: digits only, 1024 to 65535, in a private
# file. Fails when there is none or it is not like that.
recorded_port() {
  local text
  private_text "$port_file" || return 1
  text="$private_value"
  [[ "$text" =~ ^[0-9]{4,5}$ ]] || return 1
  (( 10#$text >= 1024 && 10#$text <= 65535 )) || return 1
  printf '%s' "$((10#$text))"
}

# Prints the VM name `start` recorded (sandseek-sandbox- and 8 hex digits).
recorded_name() {
  local text
  private_text "$name_file" || return 1
  text="$private_value"
  [[ "$text" =~ ^sandseek-sandbox-[0-9a-f]{8}$ ]] || return 1
  printf '%s' "$text"
}

# Sets $port (unless SANDSEEK_SANDBOX_PORT fixes it) and $name from what
# `start` recorded, for the commands that talk to a sandbox that is running.
# Without a record there is nothing to find: $port stays empty.
find_sandbox() {
  if [[ -z "$port_override" ]]; then
    port="$(recorded_port)" || port=""
  fi
  name="$(recorded_name)" || name=""
}

# A free port on 127.0.0.1: perl binds port 0, reads the port the system chose
# and lets go of it. Another program can take it before the VM publishes it;
# `start` then tries another (see there).
pick_port() {
  local picked
  picked="$("$perl_bin" -e 'use strict; use IO::Socket::INET;
    my $socket = IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1",
      LocalPort => 0, Proto => "tcp", ReuseAddr => 1) or exit 1;
    print $socket->sockport;' 2>/dev/null)" || return 1
  [[ "$picked" =~ ^[0-9]{4,5}$ ]] && (( 10#$picked >= 1024 && 10#$picked <= 65535 )) || return 1
  port=$((10#$picked))
}

# Succeeds for a name `start` could have made: sandseek-sandbox-<8 hex digits>,
# or the plain sandseek-sandbox of SandSeek 0.1.0. A VM someone started by hand
# under another name is not touched.
is_sandbox_name() {
  [[ "$1" == "$name_prefix" || "$1" =~ ^sandseek-sandbox-[0-9a-f]{8}$ ]]
}

# The lock. A small perl process takes flock on $lock_file, writes "<pid>
# <start time>" into it, tells `start` ("locked <pid>", or "busy <pid> <time>"
# when someone else holds it), detaches from the script and then only waits.
# It ends on SIGTERM, or when the lock file is gone or replaced. The marker
# word in its command line lets `stop` recognise it before sending a signal.
lock_marker=sandseek-lock-holder
lock_helper_code='use strict; use warnings;
use Fcntl qw(:flock O_RDWR O_CREAT);
use POSIX ();
my ($marker, $path, $stamp) = @ARGV;
$| = 1;
sysopen(my $handle, $path, O_RDWR | O_CREAT, 0600) or do { print "error cannot open the lock file\n"; exit 3 };
if (!flock($handle, LOCK_EX | LOCK_NB)) {
  my $held = <$handle>;
  $held = "" unless defined $held;
  $held =~ s/\s+\z//;
  print "busy $held\n";
  exit 1;
}
truncate($handle, 0);
sysseek($handle, 0, 0);
syswrite($handle, "$$ $stamp\n");
POSIX::setsid();
$SIG{TERM} = sub { exit 0 };
$SIG{HUP} = "IGNORE";
print "locked $$\n";
open(STDIN, "<", "/dev/null");
open(STDOUT, ">", "/dev/null");
open(STDERR, ">", "/dev/null");
my $inode = (stat $handle)[1];
while (1) {
  select(undef, undef, undef, 1);
  my @now = stat($path);
  exit 0 unless @now && $now[1] == $inode;
}'
# A lock holder younger than this many seconds may still be starting its VM.
lock_grace=300
lock_pid=""
# Set by the app to the pid of the lock holder it recorded after its own start,
# when it starts a fresh VM in place of its own running one. Only a holder with
# exactly that pid is ended; any other holder is somebody else's and stays.
# The command line never sets it.
replace_requested="${SANDSEEK_SANDBOX_REPLACE:-}"
busy_message="Another SandSeek is using the web sandbox. Close it first, or press Stop in it."

# Succeeds when process $1 exists and is not a zombie.
process_alive() {
  local state
  state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
  [[ -n "$state" && "$state" != Z* ]]
}

# Succeeds when process $1 is a lock holder of this script for this lock file.
lock_holder_is_ours() {
  local command
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  command="$(ps -ww -o command= -p "$1" 2>/dev/null)" || return 1
  [[ "$command" == *"$lock_marker"*"$lock_file"* ]]
}

# Ends lock holder $1 (only if it is one) and waits up to 5 seconds for it.
end_lock_holder() {
  local waited=0
  lock_holder_is_ours "$1" || return 1
  kill "$1" 2>/dev/null || true
  while process_alive "$1" && (( waited < 50 )); do
    sleep 0.1
    waited=$((waited + 1))
  done
  return 0
}

# Succeeds when the live holder $1 (started at time $2) has lost its VM: it is
# older than $lock_grace and the VM it recorded is not in `container list`
# any more (the VM crashed or was deleted by hand). It cannot be ended by a
# `stop` that has nothing to stop, and would block every start. If the list
# cannot be read, nothing is assumed.
lock_holder_is_orphan() {
  local listed recorded
  [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] || return 1
  lock_holder_is_ours "$1" || return 1
  (( $(/bin/date +%s) - $2 > lock_grace )) || return 1
  listed="$("$container_bin" list --all --quiet 2>/dev/null)" || return 1
  if recorded="$(recorded_name)"; then
    ! grep -qxF "$recorded" <<<"$listed"
  fi
}

# Takes the lock, for as long as the sandbox runs. Sets $lock_pid. Returns 75
# with a plain message when another SandSeek holds it. A lock whose process is
# gone is free (the system dropped it): it is simply taken. A holder that has
# not written its pid yet, or a probe of the app that holds the lock for an
# instant, is given a moment (up to three tries) before the lock counts as busy.
take_lock() {
  local attempt reply reply_file waited held_pid held_stamp took_over=0
  # Four passes: three for a short-lived holder, plus one after a take-over.
  for attempt in 1 2 3 4; do
    reply_file="$(umask 077 && mktemp -- "$secret_folder/.lock-reply.XXXXXX")" || return 1
    "$perl_bin" -e "$lock_helper_code" -- "$lock_marker" "$lock_file" "$(/bin/date +%s)" \
      >"$reply_file" 2>&1 </dev/null &
    lock_pid=$!
    waited=0
    reply=""
    while (( waited < 50 )); do
      reply="$(head -n 1 "$reply_file" 2>/dev/null || true)"
      [[ -z "$reply" ]] || break
      sleep 0.1
      waited=$((waited + 1))
    done
    rm -f -- "$reply_file"
    case "$reply" in
      "locked "*)
        lock_pid="${reply#locked }"
        return 0 ;;
      "busy "*)
        wait "$lock_pid" 2>/dev/null || true
        lock_pid=""
        held_pid="" held_stamp=""
        read -r held_pid held_stamp <<<"${reply#busy }" || true
        if (( ! took_over )) && [[ "$replace_requested" =~ ^[0-9]+$ && "$replace_requested" == "$held_pid" ]] \
            && lock_holder_is_ours "$held_pid"; then
          # The caller (the app) says the holder of the lock is the one it
          # recorded after its own start, and it is: end it first.
          took_over=1
          end_lock_holder "$held_pid" || true
          continue
        fi
        if (( ! took_over )) && lock_holder_is_orphan "$held_pid" "$held_stamp"; then
          echo "the sandbox of another SandSeek (process $held_pid) is gone; taking over its lock" >&2
          took_over=1
          end_lock_holder "$held_pid" || true
          continue
        fi
        if (( attempt < 3 )) && ! { [[ "$held_pid" =~ ^[0-9]+$ ]] && process_alive "$held_pid"; }; then
          # Nobody alive is named: the lock is held for an instant only.
          sleep 0.3
          continue
        fi
        echo "$busy_message" >&2
        return 75 ;;
      *)
        kill "$lock_pid" 2>/dev/null || true
        wait "$lock_pid" 2>/dev/null || true
        lock_pid=""
        echo "could not take the sandbox lock ($lock_file): ${reply:-no answer from $perl_bin}" >&2
        return 1 ;;
    esac
  done
  echo "$busy_message" >&2
  return 75
}

# Lets go of the lock this script took (ends its holder).
release_lock() {
  if [[ -n "$lock_pid" ]]; then
    kill "$lock_pid" 2>/dev/null || true
    wait "$lock_pid" 2>/dev/null || true
    lock_pid=""
  fi
}

# Stops and deletes the VM $1, ignoring errors.
remove_vm() {
  "$container_bin" stop "$1" >/dev/null 2>&1 || true
  "$container_bin" delete "$1" >/dev/null 2>&1 || true
}

# Removes what a run that did not end normally left: every VM made by this
# script (see is_sandbox_name) and the secret, port, name and address files.
# Only call it while holding the lock, so no live owner's VM is touched.
remove_leftovers() {
  local listed id
  if listed="$("$container_bin" list --all --quiet 2>/dev/null)"; then
    while IFS= read -r id; do
      if is_sandbox_name "$id"; then remove_vm "$id"; fi
    done <<<"$listed"
  else
    echo "warning: could not list the containers, so leftover sandboxes were not looked for" >&2
  fi
  remove_secret
}

# The file SandSeek 0.1.0 wrote in TUFF's folder. Only that file, and only a
# plain file of yours; TUFF's own files are never touched.
remove_old_secret() {
  if [[ -f "$old_secret_file" && ! -L "$old_secret_file" && -O "$old_secret_file" ]]; then
    rm -f -- "$old_secret_file"
  fi
}

# A request that is not signed is refused with 401 and the code `unauthorized`.
# That is the answer a running sandbox gives this script, which cannot sign
# (it has no tool for that on the Mac); SandSeek checks the real signature
# before it uses the sandbox. An image from before signed requests answers an
# unsigned /health with 200 instead. `probe` sets $health_state to `ok` (the
# 401), `old` (an unsigned 200) or `none`, and succeeds for `ok` only.
health_state=none
probe() {
  local reply
  health_state=none
  reply="$(curl -sS --max-time 2 -w '\n%{http_code}' "http://127.0.0.1:$port/health" 2>/dev/null)" \
    || return 1
  if [[ "${reply##*$nl}" == 401 && "$reply" == *'"unauthorized"'* ]]; then
    health_state=ok
  elif [[ "${reply##*$nl}" == 200 ]]; then
    health_state=old
  fi
  [[ "$health_state" == ok ]]
}

old_image_message="the sandbox image is older than this SandSeek and does not check signatures; rebuild it with: $0 build"

# Sends one request signed with the secret from inside the VM, where root can
# read it, and prints "STATUS signed" or "STATUS unsigned" (the answer's
# signature was checked), the answer's error code on a line of its own (empty
# when it has none), then the answer's body. MODE is `replay` (the same
# signed request twice; the second answer is printed), `plain` (Content-Type
# text/plain) or empty.
#   signed_call METHOD PATH BODY [MODE]
signed_client='
import hashlib, hmac, http.client, json, os, sys, time

method, path, body = sys.argv[1], sys.argv[2], sys.argv[3].encode()
mode = sys.argv[4] if len(sys.argv) > 4 else ""
with open("'"$vm_secret_folder"'/secret", "rb") as handle:
    secret = handle.read().removesuffix(b"\n")

def auth(*fields):
    return hmac.new(secret, "\n".join(fields).encode(), hashlib.sha256).hexdigest()

nonce = os.urandom(32).hex()
stamp = str(int(time.time()))
headers = {
    "Host": "127.0.0.1:9100",
    "X-Sandbox-Nonce": nonce,
    "X-Sandbox-Time": stamp,
    "X-Sandbox-Auth": auth("sandseek-sandbox-req-v1", method, path, nonce, stamp,
                           hashlib.sha256(body).hexdigest()),
}
if method == "POST":
    headers["Content-Type"] = "text/plain" if mode == "plain" else "application/json"

def send():
    connection = http.client.HTTPConnection("127.0.0.1", 9100, timeout=40)
    connection.request(method, path, body=body or None, headers=headers)
    response = connection.getresponse()
    data = response.read()
    connection.close()
    return response.status, response.getheader("X-Sandbox-Auth"), data

status, tag, data = send()
if mode == "replay":
    status, tag, data = send()
expected = auth("sandseek-sandbox-resp-v1", method, path, nonce, str(status),
                hashlib.sha256(data).hexdigest())
good = tag is not None and hmac.compare_digest(tag.strip().lower(), expected)
text = data.decode("utf-8", "replace")
try:
    code = json.loads(text).get("error", {}).get("code", "")
except (ValueError, AttributeError):
    code = ""
print(status, "signed" if good else "unsigned")
print(code if isinstance(code, str) else "")
print(text)
'

signed_call() {
  "$container_bin" exec "$name" python3 -c "$signed_client" "$@" 2>&1
}

# The first line of a signed_call answer: "200 signed".
call_status() { printf '%s' "${1%%$nl*}"; }
# The second line: the JSON error code in the answer, or empty.
call_code() {
  local rest="${1#*$nl}"
  printf '%s' "${rest%%$nl*}"
}
# Everything after the second line: the answer's body.
call_body() {
  local rest="${1#*$nl}"
  printf '%s' "${rest#*$nl}"
}

case "${1:-}" in
  build)
    require_container
    # `container build` starts a builder VM (2 CPUs, 2 GB) that keeps running
    # afterwards. Stop it again unless it was already running before. With
    # --quiet, `container builder status` prints the builder's ID only while
    # it runs; if the check itself fails, the builder is left alone.
    builder_was_running=1
    if builder="$("$container_bin" builder status --quiet 2>/dev/null)" && [[ -z "$builder" ]]; then
      builder_was_running=""
    fi
    build_status=0
    "$container_bin" build -t "$image" "$context" || build_status=$?
    if [[ -z "$builder_was_running" ]]; then
      "$container_bin" builder stop >/dev/null 2>&1 || true
    fi
    exit "$build_status"
    ;;
  start)
    # A trace would print the secret (`secret=...` while it is written), so do
    # not run under `bash -x` or `set -x`.
    if [[ $- == *x* ]]; then
      echo "not starting with xtrace on: the trace would print the sandbox secret" >&2
      exit 1
    fi
    check_port
    check_dns
    require_container
    prepare_secret_folder || exit 1
    # One SandSeek at a time: nothing is touched until the lock is ours.
    lock_status=0
    take_lock || lock_status=$?
    (( lock_status == 0 )) || exit "$lock_status"
    # From here on, every way out but success deletes the new secret and any
    # VM that was started, so a missing secret still means "not running", and
    # lets go of the lock. (On success the lock stays: see take_lock.)
    cleanup_failed_start() {
      if [[ -n "$name" ]]; then remove_vm "$name"; fi
      remove_secret
      release_lock
    }
    trap cleanup_failed_start EXIT
    # The lock is ours, so any VM and file from an earlier run has no owner
    # (it crashed, or was never stopped): remove them. This also removes a VM
    # of SandSeek 0.1.0, which was called plain sandseek-sandbox.
    remove_leftovers
    name="$name_prefix-$(LC_ALL=C od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    if [[ ! "$name" =~ ^sandseek-sandbox-[0-9a-f]{8}$ ]]; then
      echo "could not make a random name for the sandbox" >&2
      exit 1
    fi
    # The file is complete before the sandbox starts, which reads it once. The
    # old VM is gone by now, so nothing is signing with the previous secret.
    write_secret || exit 1
    write_blocked_addresses || exit 1
    remove_old_secret
    write_private_file "$name_file" "$name" || exit 1
    # The entrypoint starts as root with these four capabilities only, to load
    # the firewall; the server then gives them all up and runs as user 10001.
    # The secret goes in as a read-only file in a mounted folder, never in the
    # environment or a command line, where other users would see it in `ps`.
    # Only the Mac's side of --publish is the free port; the server and the
    # firewall in the VM keep port 9100.
    attempt=1
    while :; do
      if [[ -z "$port_override" ]]; then
        pick_port || { echo "could not find a free port on 127.0.0.1" >&2; exit 1; }
      fi
      write_private_file "$port_file" "$port" || exit 1
      run_options=(
        --detach --rm --name "$name"
        --mount "type=bind,source=$secret_folder,target=$vm_secret_folder,readonly"
        --read-only --tmpfs /tmp
        --cap-drop ALL --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID --cap-add SETPCAP
        --ulimit nproc=512
        --cpus 2 --memory 1G
        --publish "127.0.0.1:$port:9100"
      )
      for server in $dns_servers; do
        run_options+=(--dns "$server")
      done
      if [[ -n "${SEARXNG_URL:-}" ]]; then
        run_options+=(--env "SEARXNG_URL=$SEARXNG_URL")
      fi
      if run_output="$("$container_bin" run "${run_options[@]}" "$image" 2>&1)"; then
        break
      fi
      # Another program may have taken the port since it was picked. Try a new
      # one (a fixed port is not changed).
      if [[ -z "$port_override" ]] && (( attempt < 3 )) \
          && grep -qiE 'in use|already|bind' <<<"$run_output"; then
        attempt=$((attempt + 1))
        remove_vm "$name"
        continue
      fi
      printf '%s\n' "$run_output" >&2
      exit 1
    done
    # The entrypoint refuses to start when it finds no default gateway (see
    # Sandbox/entrypoint.sh) or cannot load the firewall, and `--rm` deletes the
    # container then, so keep the last non-empty log (a later "not found" error
    # must not replace it) to show below. The two flags are set from the whole
    # log, since the last five lines shown may not contain those lines.
    startup_log=""
    refused=0 firewall_loaded=0 listening=0 gone=0 firewall_line=""
    polls_after_listening=0
    old_image=0 list_failed=0
    # A hung curl or `container` call must not outlast the app's start timeout
    # (180 s), so the poll counts below also sit under an overall deadline.
    deadline=$((SECONDS + 120))
    for _ in $(seq 1 50); do
      # Ready needs the container to be running as well as the port to give
      # the unsigned 401: something else on the port must not pass for it.
      if probe; then
        if ! running="$("$container_bin" list --quiet 2>/dev/null)"; then
          list_failed=1
        elif grep -qxF "$name" <<<"$running"; then
          # A `stop` run meanwhile (by hand or by another SandSeek) ended the
          # holder: a sandbox with no lock must not be reported ready.
          if ! process_alive "$lock_pid"; then
            echo "the sandbox was stopped while it started" >&2
            exit 1
          fi
          trap - EXIT
          echo "web research sandbox ready at http://127.0.0.1:$port"
          exit 0
        fi
      elif [[ "$health_state" == old ]]; then
        old_image=1
        break
      fi
      if out="$("$container_bin" logs "$name" 2>/dev/null)" && [[ -n "$out" ]]; then
        startup_log="$(tail -n 5 <<<"$out")"
        [[ "$out" == *"refusing to start"* ]] && refused=1
        if [[ "$out" == *"firewall: inbound port 9100 accepted"* ]]; then
          firewall_loaded=1
          firewall_line="$(grep -m1 'firewall: inbound port 9100 accepted' <<<"$out")"
        fi
        [[ "$out" == *"SandSeek sandbox listening on"* ]] && listening=1
      fi
      # Stop early when the entrypoint refused to start or the container is gone.
      (( refused )) && break
      if remaining="$("$container_bin" list --all --quiet 2>/dev/null)" \
          && ! grep -qxF "$name" <<<"$remaining"; then
        gone=1
        break
      fi
      # The server listens but nothing reached it: each poll can wait 2 s, so
      # give it a few more tries, not the whole 50. (Before the server listens,
      # a slow start is normal: the firewall, DNS rules and imports come first.)
      if (( listening )); then
        polls_after_listening=$((polls_after_listening + 1))
        (( polls_after_listening < 10 )) || break
      fi
      (( SECONDS < deadline )) || break
      sleep 0.2
    done
    if [[ -n "$startup_log" ]]; then
      echo "sandbox log:" >&2
      printf '%s\n' "$startup_log" >&2
    fi
    if (( old_image )); then
      echo "$old_image_message" >&2
    elif (( refused || gone )); then
      # `--rm` has deleted the container, so `container logs` has nothing.
      debug_command="$container_bin run"
      for option in "${run_options[@]}"; do
        case "$option" in
          --rm|--detach) ;;
          # The value may hold credentials and this goes into error messages.
          SEARXNG_URL=*) debug_command+=" SEARXNG_URL=<your value>" ;;
          *) debug_command+=" $(printf '%q' "$option")" ;;
        esac
      done
      debug_command+=" $image"
      echo "the sandbox container exited and was removed (it runs with --rm)." >&2
      echo "The log above usually says why. Its secret was deleted with it, so to run it once in the foreground without --rm, first write a test secret to $secret_file (64 hex characters, chmod 600) and the Mac's addresses to $blocked_file (one per line, at least one), then run: $debug_command" >&2
    else
      if (( list_failed )); then
        echo "the sandbox answered on 127.0.0.1:$port, but \`container list\` failed, so it could not be confirmed as this sandbox; it was stopped and its secret deleted. Try again" >&2
      else
        echo "sandbox started but did not answer on 127.0.0.1:$port; it was stopped and its secret deleted (the log is above)" >&2
      fi
      if (( firewall_loaded && listening )); then
        echo "the server is listening, and the log said: $firewall_line" >&2
        echo "(if the published port connects from another address than that gateway, the server is unreachable; see docs/SECURITY.md)" >&2
      fi
    fi
    exit 1
    ;;
  stop)
    require_container
    # `stop` does not take the lock, so it cannot tell a start in progress from
    # a sandbox that runs. A lock holder under 5 seconds old whose VM is not
    # recorded yet is a start that has just begun: leave it alone, or its
    # files would be removed under it. (Anything older is stopped, also a
    # start that hangs; the app's time limit ends those too.)
    held_pid="" held_stamp=""
    if [[ -f "$lock_file" ]]; then
      read -r held_pid held_stamp <"$lock_file" || true
    fi
    if [[ "$held_stamp" =~ ^[0-9]+$ ]] && lock_holder_is_ours "$held_pid" \
        && (( $(/bin/date +%s) - 10#$held_stamp < 5 )) && ! recorded_name >/dev/null; then
      echo "A SandSeek is starting the web sandbox just now, so it was not stopped. Try again in a few seconds." >&2
      exit 75
    fi
    # Exactly the VM `start` recorded (or the plain name of 0.1.0's VM).
    name="$(recorded_name)" || name="$name_prefix"
    remove_vm "$name"
    if ! remaining="$("$container_bin" list --all --quiet 2>/dev/null)" \
        || grep -qxF "$name" <<<"$remaining"; then
      echo "could not confirm the sandbox was removed; see: container list --all" >&2
      exit 1
    fi
    # No secret means no sandbox is running.
    remove_secret
    # The VM is gone, so the lock can go: end its holder, if the file names one.
    end_lock_holder "$held_pid" || true
    echo "web research sandbox stopped"
    ;;
  status)
    check_port
    find_sandbox
    if [[ -z "$port" ]]; then
      echo "web research sandbox is not answering: none was started (no port is recorded)" >&2
      exit 1
    fi
    probe || true
    if [[ "$health_state" == ok ]]; then
      echo "web research sandbox answers at http://127.0.0.1:$port and refuses unsigned requests; SandSeek checks its signature before use"
    elif [[ "$health_state" == old ]]; then
      echo "$old_image_message" >&2
      exit 1
    else
      echo "web research sandbox is not answering at http://127.0.0.1:$port" >&2
      exit 1
    fi
    ;;
  selftest)
    check_port
    require_container
    find_sandbox
    [[ -n "$port" && -n "$name" ]] || { echo "start the sandbox first: $0 start" >&2; exit 1; }
    probe || true
    if [[ "$health_state" == old ]]; then
      echo "$old_image_message" >&2
      exit 1
    fi
    [[ "$health_state" == ok ]] || { echo "start the sandbox first: $0 start" >&2; exit 1; }
    failures=0
    pass() { echo "  ok    $1"; }
    fail() { echo "  FAIL  $1" >&2; failures=$((failures + 1)); }

    echo "Fetches the sandbox must refuse:"
    # The same helper the entrypoint uses for the inbound rule.
    gateway="$("$container_bin" exec "$name" python3 /app/default_gateway.py)" \
      || { echo "  FAIL  could not read the VM's default gateway (rebuild the image?)" >&2; exit 1; }
    # The Mac's addresses the sandbox was started with (see write_blocked_addresses),
    # and the ones it has now. The Mac can gain addresses after the start (the
    # bridge to the VM exists only while it runs); those are private, so the
    # private ranges refuse them, and they are tested below like the others.
    given=()
    if [[ -f "$blocked_file" ]]; then
      while IFS= read -r line; do
        if [[ -n "$line" ]]; then given+=("$line"); fi
      done <"$blocked_file"
    fi
    if (( ${#given[@]} == 0 )); then
      echo "  FAIL  the list of the Mac's addresses ($blocked_file) is missing or empty; start the sandbox again" >&2
      exit 1
    fi
    current=()
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then current+=("$line"); fi
    done < <("$ifconfig_bin" 2>/dev/null | collect_mac_addresses 2>/dev/null || true)
    blocked_urls=(
      "http://$gateway/"
      "http://$gateway:8080/v1/models"
      "http://127.0.0.1:8080/v1/models"
      "http://localhost/"
      "http://[::1]/"
      "http://10.0.0.1/"
      "http://172.16.0.1/"
      "http://192.168.1.1/"
      "http://169.254.169.254/latest/meta-data/"
      "http://100.100.100.200/"
      "http://0.0.0.0/"
      "http://localtest.me/"
      "http://example.com:8080/"
      "file:///etc/passwd"
      "ftp://example.com/"
    )
    for address in "${given[@]}" ${current[@]+"${current[@]}"}; do
      if [[ "$address" == *:* ]]; then
        blocked_urls+=("http://[$address]/")
      else
        blocked_urls+=("http://$address/")
      fi
    done
    # A public address, so only the Mac's list can be why it is refused.
    reply="$(signed_call POST /v1/fetch "{\"url\": \"http://$test_address/\"}" || true)"
    if [[ "$(call_code "$reply")" == blocked_address && "$(call_status "$reply")" == *" signed" ]]; then
      pass "http://$test_address/, a public address on the Mac's list, is refused by the server"
    else
      fail "http://$test_address/, a public address on the Mac's list, was not refused: ${reply:0:200}"
    fi
    for url in "${blocked_urls[@]}"; do
      reply="$(signed_call POST /v1/fetch "{\"url\": \"$url\"}" || true)"
      code="$(call_code "$reply")"
      case "$code" in
        blocked_address|blocked_port|invalid_url|dns_error)
          if [[ "$(call_status "$reply")" == *" signed" ]]; then
            pass "$url refused ($code)"
          else
            fail "$url was refused ($code) but the answer was not signed"
          fi ;;
        *) fail "$url was not refused: ${reply:0:200}" ;;
      esac
    done

    echo "The VM's own protection:"
    if "$container_bin" exec "$name" nft list table inet sandseek_sandbox >/dev/null 2>&1; then
      pass "the firewall is loaded"
    else
      fail "the firewall is not loaded"
    fi
    # -nn prints the port as a number (nft would otherwise print a service name).
    # This reads the loaded rules; it does not send a packet from another
    # address, so it shows that the rule names the gateway, not that other
    # senders are refused.
    input_rules="$("$container_bin" exec "$name" nft -nn list chain inet sandseek_sandbox input 2>/dev/null || true)"
    if grep -q 'hook input.*policy drop' <<<"$input_rules" \
        && grep -qF "ip saddr $gateway tcp dport 9100 accept" <<<"$input_rules" \
        && [[ "$(grep -c 'dport 9100' <<<"$input_rules")" == 1 ]]; then
      pass "the firewall drops new inbound connections except to port 9100 from the gateway $gateway"
    else
      fail "the firewall's input chain is missing or not as expected: ${input_rules:0:200}"
    fi
    # The Mac's own addresses are elements of the sets blocked4 and blocked6
    # (see firewall.nft); `nft get element` reads them back whatever way nft
    # spells an address. The output chain must refuse both sets.
    missing=""
    for address in "${given[@]}"; do
      if [[ "$address" == *:* ]]; then set_name=blocked6; else set_name=blocked4; fi
      "$container_bin" exec "$name" nft get element inet sandseek_sandbox "$set_name" "{ $address }" \
        >/dev/null 2>&1 || missing+=" $address"
    done
    if [[ -z "$missing" ]]; then
      pass "every one of the Mac's addresses it was given is in the firewall's blocked sets"
    else
      fail "not in the firewall's blocked sets:$missing"
    fi
    output_rules="$("$container_bin" exec "$name" nft -nn list chain inet sandseek_sandbox output 2>/dev/null || true)"
    if grep -q 'daddr @blocked4.*reject' <<<"$output_rules" && grep -q 'daddr @blocked6.*reject' <<<"$output_rules"; then
      pass "the output chain rejects both sets of the Mac's addresses"
    else
      fail "the output chain does not reject the blocked sets: ${output_rules:0:200}"
    fi
    # Only the firewall makes this fail at once with a refusal (a connection
    # reset): without the rule the address is simply unanswered. Port 53 is
    # used because this address (a root server) accepts TCP there, so without
    # the rule the connection would succeed, not be reset. The DNS exception covers the VM's own name servers only,
    # so this address is still refused on port 53.
    refusal="$("$container_bin" exec --user 10001:10001 "$name" python3 -c "
import socket, sys
try:
    socket.create_connection((sys.argv[1], 53), timeout=4).close()
    print('connected')
except ConnectionRefusedError:
    print('refused')
except OSError as error:
    print('other', type(error).__name__)
" "$test_address" 2>/dev/null || true)"
    if [[ "$refusal" == refused ]]; then
      pass "a connection to $test_address, a public address on the Mac's list, is refused by the firewall"
    else
      fail "a connection to $test_address: ${refusal:-no answer} (a refusal was expected)"
    fi
    privileges="$("$container_bin" exec "$name" python3 -c '
import glob
for path in glob.glob("/proc/[0-9]*/cmdline"):
    try:
        if b"/app/server.py" not in open(path, "rb").read().split(b"\0"):
            continue
        status = dict(l.split(":", 1) for l in open(path[:-7] + "status") if ":" in l)
    except OSError:
        continue
    caps = [n for n in ("CapPrm", "CapEff", "CapBnd", "CapAmb") if int(status[n], 16)]
    print(status["Uid"].split()[0], ",".join(caps) or "none")
    break
' 2>/dev/null || true)"
    if [[ "$privileges" == "10001 none" ]]; then
      pass "the server runs as user 10001 with no capabilities"
    else
      fail "the server's user and capabilities are not as expected: ${privileges:-not found}"
    fi

    # These run as the server's user, as code that took the server over would.
    echo "Direct connections from inside the VM, which must fail:"
    # The Mac's DNS port (53) is the one exception, when the VM uses it.
    for target in "$gateway:8080" "$gateway:22" "$gateway:5000" "$gateway:443" \
                  "192.168.1.1:80" "192.168.0.1:80" "10.0.0.1:80" "169.254.169.254:80"; do
      if "$container_bin" exec --user 10001:10001 "$name" python3 -c "
import socket, sys
host, port = sys.argv[1].rsplit(':', 1)
try:
    socket.create_connection((host, int(port)), timeout=3).close()
except OSError:
    sys.exit(1)
" "$target" >/dev/null 2>&1; then
        fail "the VM can open a connection to $target"
      else
        pass "the VM cannot connect to $target"
      fi
    done

    # Every TCP port on the Mac. DNS (53) may answer when the VM's name server
    # is the Mac, which is the default; nothing else may.
    echo "Every TCP port on the Mac, from inside the VM:"
    open_ports="$("$container_bin" exec --user 10001:10001 "$name" python3 -c '
import socket, sys
from concurrent.futures import ThreadPoolExecutor
host = sys.argv[1]
def probe(port):
    try:
        socket.create_connection((host, port), timeout=1).close()
        return port
    except OSError:
        return None
with ThreadPoolExecutor(64) as pool:
    print(" ".join(str(p) for p in pool.map(probe, range(1, 65536)) if p))
' "$gateway" 2>/dev/null)" || open_ports="error"
    mac_dns="no"
    if "$container_bin" exec "$name" awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf 2>/dev/null \
        | grep -qx "$gateway"; then
      mac_dns="yes"
    fi
    case "$open_ports" in
      "")
        pass "no port on the Mac is reachable" ;;
      53)
        if [[ "$mac_dns" == "yes" ]]; then
          pass "only the Mac's DNS port (53) is reachable, as configured"
        else
          fail "the Mac's port 53 is reachable although the VM does not use the Mac for DNS"
        fi ;;
      error)
        fail "the port scan of the Mac did not run" ;;
      *)
        fail "the VM can reach these ports on the Mac: $open_ports" ;;
    esac

    echo "Requests to the sandbox API that must be refused:"
    status="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: attacker.example' \
      -H 'Content-Type: application/json' --data '{"url":"https://example.com/"}' \
      "http://127.0.0.1:$port/v1/fetch")"
    [[ "$status" == "403" ]] && pass "foreign Host header refused" || fail "foreign Host header answered $status"
    status="$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
      --data '{"url":"https://example.com/"}' "http://127.0.0.1:$port/v1/fetch")"
    [[ "$status" == "401" ]] && pass "unsigned request refused" || fail "unsigned request answered $status"
    # Signed correctly, so it is the content type that is refused.
    reply="$(signed_call POST /v1/fetch '{"url":"https://example.com/"}' plain || true)"
    [[ "$(call_status "$reply")" == "415 signed" ]] \
      && pass "browser-style simple POST refused" || fail "simple POST answered: ${reply:0:200}"
    reply="$(signed_call POST /v1/fetch '{"url":"https://example.com/"}' replay || true)"
    if [[ "$(call_status "$reply")" == "401 signed" && "$(call_code "$reply")" == "replayed_request" ]]; then
      pass "a request sent twice is refused the second time"
    else
      fail "a repeated request was not refused: ${reply:0:200}"
    fi
    reply="$(signed_call PUT /health '' || true)"
    [[ "$(call_status "$reply")" == "405 signed" ]] \
      && pass "other methods are refused (after the signature check)" || fail "PUT answered: ${reply:0:200}"

    echo "The sandbox must check requests and sign its answers:"
    reply="$(signed_call GET /health '' || true)"
    body="$(call_body "$reply")"
    if [[ "$(call_status "$reply")" == "200 signed" && "$body" == *'"status": "ok"'* && "$body" == *'"api": 1'* ]]; then
      pass "a signed /health request is answered with a signed answer"
    else
      fail "a signed /health request was not answered with a signed answer: ${reply:0:200}"
    fi
    if [[ "$body" == *"\"blocked_addresses\": ${#given[@]}"[,\}]* ]]; then
      pass "the server refuses all ${#given[@]} addresses it was given (the Mac's and one test address)"
    else
      fail "the server does not report ${#given[@]} blocked addresses (rebuild the image?): ${body:0:200}"
    fi
    # The folder is mounted read-only; /proc/mounts in the VM shows whether
    # Apple container did that.
    mount_options="$("$container_bin" exec "$name" awk -v dir="$vm_secret_folder" \
      '$2 == dir { print $4 }' /proc/mounts 2>/dev/null || true)"
    case ",$mount_options," in
      *,ro,*) pass "the secret folder is mounted read-only in the VM" ;;
      *) fail "the secret folder is not mounted read-only in the VM (mount options: ${mount_options:-none})" ;;
    esac
    if [[ -e "$secret_file" ]]; then
      pass "the secret file exists on the Mac ($secret_file)"
    else
      fail "the secret file $secret_file does not exist, so SandSeek cannot use the sandbox"
    fi

    echo "A public page must still work:"
    reply="$(signed_call POST /v1/fetch '{"url":"https://example.com/"}' || true)"
    if [[ "$(call_status "$reply")" == "200 signed" && "$reply" == *'"text"'* ]]; then
      pass "https://example.com/ fetched"
    else
      fail "https://example.com/ could not be fetched; check the VM's internet access"
    fi

    if [[ "$failures" -gt 0 ]]; then
      echo "$failures check(s) failed" >&2
      exit 1
    fi
    echo "all sandbox checks passed"
    ;;
  *)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
