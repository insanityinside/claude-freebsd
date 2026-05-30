#!/bin/sh
#
# claude-code-freebsd.sh — install / update Claude Code on FreeBSD via Linuxulator
#
# The official Claude Code linux-x64 native binary runs unmodified under
# FreeBSD's Linux ABI (Linuxulator).  This script fetches that binary from
# Anthropic's download infrastructure (downloads.claude.ai), verifies its
# SHA256 against the signed manifest, installs it to
# /usr/local/libexec/claude-code/, and creates a thin wrapper at
# /usr/local/bin/claude that disables the binary's own auto-updater and instead
# prints a one-line nudge (at most once per day) when a newer release is out.
#
# Usage:  sudo sh claude-code-freebsd.sh [OPTIONS]
#
#   --channel latest|stable  release channel to track (default: latest)
#   --version X.Y.Z          install a specific version instead
#   --force                  reinstall even if already at the target version
#   --help                   show this help
#
# Requirements:
#   FreeBSD amd64, Linuxulator loaded (linux64 kmod + linux_base-rl9), root.
#
# This script does NOT set up Linuxulator and does NOT remove existing installs.
# If either is needed it will print the relevant command and exit cleanly.
#
# Re-run as root to update Claude Code at any time.
# Suppress the per-launch "update available" nudge:  CLAUDE_FBSD_NO_NOTIFY=1

set -eu

# ── constants ────────────────────────────────────────────────────────────────

PROG="claude-code-freebsd.sh"
REAL_DIR="/usr/local/libexec/claude-code"
REAL_BIN="$REAL_DIR/claude"
VER_FILE="$REAL_DIR/version"
WRAPPER="/usr/local/bin/claude"
PLATFORM="linux-x64"

DOWNLOAD_BASE="https://downloads.claude.ai/claude-code-releases"

# ── helpers ──────────────────────────────────────────────────────────────────

info() { printf '==> %s\n' "$*"; }

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo sh $PROG [OPTIONS]

  --channel latest|stable  release channel to track (default: latest)
  --version X.Y.Z          install a specific version instead
  --force                  reinstall even if already at the target version
  --help                   show this help

Requirements: FreeBSD amd64, Linuxulator (linux64 kmod + linux_base-rl9), root.

This script does NOT set up Linuxulator and does NOT remove existing installs.
If either is needed it prints the relevant command and exits cleanly.

Re-run as root to update Claude Code at any time.
Suppress the per-launch "update available" nudge:  CLAUDE_FBSD_NO_NOTIFY=1
EOF
}

# Fetch URL to dest file; dies with a message on failure.
fetch_to() {
    _url=$1; _dst=$2
    if fetch -qT30 -o "$_dst" "$_url" 2>/dev/null; then return 0; fi
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --max-time 30 -o "$_dst" "$_url"; then return 0; fi
    fi
    die "download failed: $_url"
}

# Like fetch_to but returns 1 on failure instead of dying.
try_fetch_to() {
    _url=$1; _dst=$2
    if fetch -qT30 -o "$_dst" "$_url" 2>/dev/null; then return 0; fi
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --max-time 30 -o "$_dst" "$_url" 2>/dev/null; then return 0; fi
    fi
    return 1
}

# ── argument parsing ──────────────────────────────────────────────────────────

channel=latest
pinver=""
force=0

while [ $# -gt 0 ]; do
    case "$1" in
        --channel)
            [ $# -ge 2 ] || die "--channel requires an argument (latest or stable)"
            shift; channel="$1"
            case "$channel" in
                latest|stable) ;;
                *) die "--channel must be 'latest' or 'stable', got: $channel" ;;
            esac ;;
        --version)
            [ $# -ge 2 ] || die "--version requires a version number (e.g. 2.1.100)"
            shift; pinver="$1"
            case "$pinver" in
                [0-9]*.[0-9]*.[0-9]*) ;;
                *) die "--version must be X.Y.Z, got: $pinver" ;;
            esac ;;
        --force)    force=1 ;;
        --help|-h)  usage; exit 0 ;;
        *)          usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

# ── preconditions ─────────────────────────────────────────────────────────────

[ "$(uname -s)" = FreeBSD ] \
    || die "FreeBSD only (this host reports: $(uname -s))"
[ "$(uname -m)" = amd64 ] \
    || die "amd64 only — the linux-x64 binary requires Linuxulator on amd64 (got $(uname -m))"
[ "$(id -u)" -eq 0 ] \
    || die "must run as root to write to /usr/local — re-run with sudo or doas"

if ! kldstat -q -n linux64.ko 2>/dev/null; then
    printf '%s: Linuxulator does not appear to be active.\n' "$PROG" >&2
    printf '\nOne-time setup (as root):\n' >&2
    printf '    pkg install -y linux_base-rl9\n' >&2
    printf '    sysrc linux_enable=YES\n' >&2
    printf '    service linux start\n\n' >&2
    exit 1
fi

# Conflict check: refuse to clobber a foreign /usr/local/bin/claude.
# Skip if this is already our own install (identified by the version sentinel).
if [ -e "$WRAPPER" ] || [ -L "$WRAPPER" ]; then
    if [ -f "$VER_FILE" ]; then
        : # Our previous install — treat this run as an update, continue.
    else
        real=$(readlink -f "$WRAPPER" 2>/dev/null || echo "(unresolvable)")
        if pkg which "$WRAPPER" 2>/dev/null | grep -q 'was installed by'; then
            pkg_label=$(pkg which "$WRAPPER" 2>/dev/null | \
                        sed 's/.*installed by package //')
            printf '%s: error: %s is managed by pkg (package: %s).\n' \
                "$PROG" "$WRAPPER" "$pkg_label" >&2
            printf '    Remove it first:  pkg delete %s\n\n' \
                "${pkg_label%%-*}" >&2
            exit 1
        elif printf '%s' "$real" | grep -q 'node_modules/@anthropic-ai/claude-code'; then
            printf '%s: error: %s is an npm-global Claude Code install.\n' \
                "$PROG" "$WRAPPER" >&2
            printf '    Remove it first:  npm uninstall -g @anthropic-ai/claude-code\n\n' >&2
            exit 1
        else
            printf '%s: error: %s already exists (resolves to: %s).\n' \
                "$PROG" "$WRAPPER" "$real" >&2
            printf '    Remove it manually, then re-run this script.\n\n' >&2
            exit 1
        fi
    fi
fi

# ── resolve version ───────────────────────────────────────────────────────────

if [ -n "$pinver" ]; then
    ver="$pinver"
    info "Pinned version: $ver"
else
    info "Resolving '$channel' version from downloads.claude.ai..."
    _tmp=$(mktemp /tmp/cc-ver.XXXXXX)
    fetch_to "$DOWNLOAD_BASE/$channel" "$_tmp"
    ver=$(cat "$_tmp" | tr -d '[:space:]')
    rm -f "$_tmp"
    case "$ver" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) die "unexpected version response from downloads.claude.ai: '$ver'" ;;
    esac
    info "Latest $channel: $ver"
fi

# ── skip if already current ───────────────────────────────────────────────────

if [ -f "$VER_FILE" ] && [ "$force" -eq 0 ]; then
    cur=$(cat "$VER_FILE")
    if [ "$cur" = "$ver" ]; then
        info "Already at $ver — nothing to do (use --force to reinstall)."
        exit 0
    fi
    info "Upgrading: $cur -> $ver"
fi

# ── download + verify ─────────────────────────────────────────────────────────

workdir=$(mktemp -d /tmp/cc-install.XXXXXX)
trap 'rm -rf "$workdir"' EXIT

# Fetch manifest and extract the linux-x64 checksum.
info "Fetching manifest for v${ver}..."
mf="$workdir/manifest.json"
if try_fetch_to "$DOWNLOAD_BASE/$ver/manifest.json" "$mf"; then
    expected=$(awk '
        /"'"$PLATFORM"'"/ { found = 1 }
        found && /"checksum"/ {
            sub(/.*"checksum": *"/, ""); sub(/".*/, ""); print; exit
        }
    ' "$mf")
else
    info "Warning: manifest unavailable for v$ver — skipping checksum verification."
    expected=""
fi

info "Downloading $PLATFORM binary for v${ver}..."
binary="$workdir/claude"
fetch_to "$DOWNLOAD_BASE/$ver/$PLATFORM/claude" "$binary"

# Verify SHA256 if we got a checksum from the manifest.
if [ -n "$expected" ]; then
    info "Verifying SHA256..."
    actual=$(sha256 -q "$binary")
    if [ "$actual" != "$expected" ]; then
        die "SHA256 mismatch!
  expected: $expected
  actual:   $actual"
    fi
    info "SHA256 OK"
fi

# ── install ───────────────────────────────────────────────────────────────────

info "Installing..."
mkdir -p "$REAL_DIR"
install -m 755 "$binary" "$REAL_BIN"
printf '%s\n' "$ver" > "$VER_FILE"

# Write the wrapper (overwrites on update; no variables expanded inside heredoc)
cat > "$WRAPPER" << 'END_WRAPPER'
#!/bin/sh
# Managed by claude-code-freebsd.sh — do not hand-edit.
#
# The Claude Code binary's own self-updater is disabled.
# To update:  sudo claude-code-freebsd.sh
# To silence the "update available" notice:  export CLAUDE_FBSD_NO_NOTIFY=1

export DISABLE_AUTOUPDATER=1
export DISABLE_UPDATES=1

_D=/usr/local/libexec/claude-code

# Throttled update check: async, TTY stderr only, at most once per day per user.
# Skip for --version/--help where claude exits before the fetch completes.
case "${1:-}" in --version|--help|-h) _do_nudge=0 ;; *) _do_nudge=1 ;; esac
if [ "$_do_nudge" -eq 1 ] && [ -z "${CLAUDE_FBSD_NO_NOTIFY:-}" ] && [ -t 2 ]; then
    _stamp="${HOME:-/tmp}/.claude-code-lastcheck"
    _do=0
    if [ ! -e "$_stamp" ]; then
        _do=1
    else
        _now=$(date +%s 2>/dev/null || echo 0)
        _then=$(stat -f %m "$_stamp" 2>/dev/null || echo 0)
        [ "$(( _now - _then ))" -gt 86400 ] && _do=1
    fi
    if [ "$_do" -eq 1 ]; then
        (
            _latest=$(fetch -qT2 -o - \
                https://downloads.claude.ai/claude-code-releases/latest \
                2>/dev/null | tr -d '[:space:]' || true)
            _cur=$(cat "$_D/version" 2>/dev/null || true)
            [ -n "$_latest" ] && : > "$_stamp" 2>/dev/null || true
            if [ -n "$_latest" ] && [ -n "$_cur" ] && [ "$_latest" != "$_cur" ]; then
                printf 'claude-code: %s available (you have %s) — update: sudo claude-code-freebsd.sh\n' \
                    "$_latest" "$_cur" >&2
            fi
        ) &
    fi
fi

# Warn if required nullfs mounts are absent — claude hangs without them.
for _mp in /compat/linux/tmp /compat/linux/home; do
    if ! mount | grep -q " on ${_mp} "; then
        printf 'claude-code: warning: %s is not mounted (claude may hang)\n' "$_mp" >&2
        printf 'claude-code:   add to /etc/fstab: %s %s nullfs rw 0 0\n' \
            "${_mp#/compat/linux}" "$_mp" >&2
        printf 'claude-code:   then run: mount %s\n' "$_mp" >&2
    fi
done

exec "$_D/claude" "$@"
END_WRAPPER
chmod 755 "$WRAPPER"

# ── done ─────────────────────────────────────────────────────────────────────

printf '\n'
info "Claude Code $ver installed."
info "  Binary  : $REAL_BIN"
info "  Wrapper : $WRAPPER  (self-update disabled)"
printf '\n'
info "Verify:  claude --version"
info "Update:  sudo $PROG"
info "Nudge:   export CLAUDE_FBSD_NO_NOTIFY=1  (to silence update notices)"
