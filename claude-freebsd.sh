#!/bin/sh
#
# claude-freebsd — install and manage Claude Code on FreeBSD via Linuxulator
#
# The official Claude Code linux-x64 native binary runs unmodified under
# FreeBSD's Linux ABI (Linuxulator).  This tool fetches that binary from
# Anthropic's download infrastructure (downloads.claude.ai), verifies its
# SHA256 against the signed manifest, and installs it behind a thin wrapper
# at /usr/local/bin/claude that disables the binary's own auto-updater.
#
# Usage:
#   claude-freebsd --install     [OPTIONS]  install Claude Code (and this tool)
#   claude-freebsd --update      [OPTIONS]  update Claude Code to latest
#   claude-freebsd --uninstall              remove Claude Code and this tool
#   claude-freebsd --self-update            update this tool from GitHub
#   claude-freebsd --help                   show this help
#
# Options (for --install / --update):
#   --channel latest|stable  release channel to track (default: latest)
#   --version X.Y.Z          install a specific version instead
#   --force                  reinstall even if already at the target version
#
# Root is required for --install, --update, --uninstall, and --self-update.
# Suppress the per-launch "update available" nudge:  CLAUDE_FBSD_NO_NOTIFY=1

set -eu

# ── constants ────────────────────────────────────────────────────────────────

PROG="claude-freebsd"
SCRIPT_VERSION="1.0.1"
GITHUB_REPO="insanityinside/claude-freebsd"
SELF_PATH="/usr/local/bin/$PROG"
REAL_DIR="/usr/local/libexec/claude-code"
REAL_BIN="$REAL_DIR/claude"
VER_FILE="$REAL_DIR/version"
WRAPPER="/usr/local/bin/claude"
PLATFORM="linux-x64"

DOWNLOAD_BASE="https://downloads.claude.ai/claude-code-releases"
GITHUB_API="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
GITHUB_RAW="https://raw.githubusercontent.com/$GITHUB_REPO"

# ── helpers ──────────────────────────────────────────────────────────────────

info() { printf '==> %s\n' "$*"; }

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
claude-freebsd — install and manage Claude Code on FreeBSD via Linuxulator

Usage:
  $PROG --install     [OPTIONS]  install Claude Code (and this tool)
  $PROG --update      [OPTIONS]  update Claude Code to latest
  $PROG --uninstall              remove Claude Code, the wrapper, and this tool
  $PROG --self-update            update this tool from GitHub
  $PROG --help                   show this help

Options (for --install / --update):
  --channel latest|stable  release channel to track (default: latest)
  --version X.Y.Z          install a specific version instead
  --force                  reinstall even if already at the target version

Requirements:
  FreeBSD amd64, Linuxulator active (linux64 kmod + linux_base-rl9), root.

The following /etc/fstab entries are required for Claude Code to run correctly.
The fdescfs entry MUST include linrdlnk or claude will hang on startup.

  devfs     /compat/linux/dev      devfs     rw
  tmpfs     /compat/linux/dev/shm  tmpfs     rw,size=1g,mode=1777
  fdescfs   /compat/linux/dev/fd   fdescfs   rw,linrdlnk
  linprocfs /compat/linux/proc     linprocfs rw
  linsysfs  /compat/linux/sys      linsysfs  rw
  /tmp      /compat/linux/tmp      nullfs    rw
  /home     /compat/linux/home     nullfs    rw

Suppress the per-launch "update available" nudge:  CLAUDE_FBSD_NO_NOTIFY=1
EOF
}

# Write the /usr/local/bin/claude wrapper from the current script's template.
write_wrapper() {
    cat > "$WRAPPER" << 'END_WRAPPER'
#!/bin/sh
# Managed by claude-freebsd — do not hand-edit.
#
# The Claude Code binary's own self-updater is disabled.
# To update:  sudo claude-freebsd --update
# To silence the "update available" notice:  export CLAUDE_FBSD_NO_NOTIFY=1

export DISABLE_AUTOUPDATER=1
export DISABLE_UPDATES=1

_D=/usr/local/libexec/claude-code

# Check all required Linuxulator mounts — claude hangs or misbehaves without them.
_mounts=$(mount)
_mount_warn=0
for _mp in \
    /compat/linux/dev     \
    /compat/linux/dev/shm \
    /compat/linux/dev/fd  \
    /compat/linux/proc    \
    /compat/linux/sys     \
    /compat/linux/tmp     \
    /compat/linux/home
do
    if ! printf '%s\n' "$_mounts" | grep -q " on ${_mp} "; then
        printf 'claude: warning: %s is not mounted\n' "$_mp" >&2
        _mount_warn=1
    fi
done
# fdescfs MUST have linrdlnk — without it claude hangs indefinitely on startup.
# mount(8) does not report fdescfs options in its output, so check /etc/fstab.
if printf '%s\n' "$_mounts" | grep -q " on /compat/linux/dev/fd "; then
    if ! grep -vE '^[[:space:]]*#' /etc/fstab 2>/dev/null | \
       grep -qE '[[:space:]]/compat/linux/dev/fd[[:space:]].*linrdlnk'; then
        printf 'claude: warning: /compat/linux/dev/fd is mounted without linrdlnk — claude will hang on startup\n' >&2
        printf 'claude:   /etc/fstab should read: fdescfs /compat/linux/dev/fd fdescfs rw,linrdlnk 0 0\n' >&2
        printf 'claude:   then remount: umount /compat/linux/dev/fd && mount /compat/linux/dev/fd\n' >&2
        _mount_warn=1
    fi
fi
if [ "$_mount_warn" -eq 1 ]; then
    printf 'claude: add missing/corrected entries to /etc/fstab, then: mount -a\n' >&2
    printf 'claude:   devfs     /compat/linux/dev      devfs     rw\n' >&2
    printf 'claude:   tmpfs     /compat/linux/dev/shm  tmpfs     rw,size=1g,mode=1777\n' >&2
    printf 'claude:   fdescfs   /compat/linux/dev/fd   fdescfs   rw,linrdlnk\n' >&2
    printf 'claude:   linprocfs /compat/linux/proc     linprocfs rw\n' >&2
    printf 'claude:   linsysfs  /compat/linux/sys      linsysfs  rw\n' >&2
    printf 'claude:   /tmp      /compat/linux/tmp      nullfs    rw\n' >&2
    printf 'claude:   /home     /compat/linux/home     nullfs    rw\n' >&2
fi

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
                printf 'claude-code: %s available (you have %s) — update: sudo claude-freebsd --update\n' \
                    "$_latest" "$_cur" >&2
            fi
        ) &
    fi
fi

exec "$_D/claude" "$@"
END_WRAPPER
    chmod 755 "$WRAPPER"
}

# Throttled check for a newer manager release on GitHub (at most once per day).
# Prints a one-line notice if a newer tag exists; never fatal.
check_manager_update() {
    _mstamp="${HOME:-/tmp}/.claude-freebsd-lastcheck"
    _do=0
    if [ ! -e "$_mstamp" ]; then
        _do=1
    else
        _now=$(date +%s 2>/dev/null || echo 0)
        _then=$(stat -f %m "$_mstamp" 2>/dev/null || echo 0)
        [ "$(( _now - _then ))" -gt 86400 ] && _do=1
    fi
    [ "$_do" -eq 0 ] && return 0
    _gh_ver=$(fetch -qT3 -o - "$GITHUB_API" 2>/dev/null | \
        sed -n 's/.*"tag_name": *"v*\([^"]*\)".*/\1/p' | head -1 || true)
    : > "$_mstamp" 2>/dev/null || true
    [ -z "$_gh_ver" ] && return 0
    [ "$_gh_ver" = "$SCRIPT_VERSION" ] && return 0
    printf '\n'
    info "Manager update available: v$SCRIPT_VERSION -> v$_gh_ver"
    info "  Run: sudo $PROG --self-update"
}

# Fetch URL to dest file; dies on failure.
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

action=""
channel=latest
pinver=""
force=0

while [ $# -gt 0 ]; do
    case "$1" in
        --install)      action=install ;;
        --update)       action=update ;;
        --uninstall)    action=uninstall ;;
        --self-update)  action=selfupdate ;;
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

# Default: show help
if [ -z "$action" ]; then
    usage
    exit 0
fi

# ── resolve own path (needed for root hint, self-install, and skip logic) ──────

self=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
# Running from outside SELF_PATH means we should always update the manager and
# wrapper, even if the Claude Code binary is already current.
need_selfinstall=0
[ "$self" != "$SELF_PATH" ] && need_selfinstall=1

# ── root check ────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    printf '%s: --%s requires root. Re-run with sudo or doas:\n\n' "$PROG" "$action" >&2
    # Print the exact command to repeat, including any options passed
    _cmd="sudo $self --$action"
    # --channel / --version / --force only apply to install and update
    if [ "$action" = "install" ] || [ "$action" = "update" ]; then
        [ "$channel" != "latest" ] && _cmd="$_cmd --channel $channel"
        [ -n "$pinver" ]           && _cmd="$_cmd --version $pinver"
        [ "$force" -eq 1 ]         && _cmd="$_cmd --force"
    fi
    printf '    %s\n\n' "$_cmd" >&2
    exit 1
fi

# ── OS / arch checks ──────────────────────────────────────────────────────────

[ "$(uname -s)" = FreeBSD ] \
    || die "FreeBSD only (this host reports: $(uname -s))"
[ "$(uname -m)" = amd64 ] \
    || die "amd64 only — the linux-x64 binary requires Linuxulator on amd64 (got $(uname -m))"

# ── uninstall ─────────────────────────────────────────────────────────────────

if [ "$action" = "uninstall" ]; then
    # Refuse to remove anything unless VER_FILE is present — that file is written
    # exclusively by this tool, so its existence confirms the install is ours.
    if [ ! -f "$VER_FILE" ]; then
        info "Nothing to uninstall — $VER_FILE not found."
        info "If Claude Code was installed by another method, remove it manually."
        exit 0
    fi
    info "Removing Claude Code (Linuxulator install)..."
    # Wrapper — only remove if it contains our marker comment, which is written
    # by every version of this tool and won't appear in a foreign install.
    if [ -e "$WRAPPER" ] || [ -L "$WRAPPER" ]; then
        if grep -q "# Managed by claude-freebsd" "$WRAPPER" 2>/dev/null; then
            rm -f "$WRAPPER"
            info "  removed: $WRAPPER"
        else
            info "  skipped: $WRAPPER (not managed by $PROG — leaving untouched)"
        fi
    fi
    # Binary + version sentinel + directory
    if [ -d "$REAL_DIR" ]; then
        rm -rf "$REAL_DIR"
        info "  removed: $REAL_DIR"
    fi
    # Manager — safe to remove even if we are currently running from it
    if [ -e "$SELF_PATH" ]; then
        rm -f "$SELF_PATH"
        info "  removed: $SELF_PATH"
    fi
    printf '\n'
    info "Done. User config (~/.claude/) was not touched."
    check_manager_update
    exit 0
fi

# ── self-update ───────────────────────────────────────────────────────────────

if [ "$action" = "selfupdate" ]; then
    info "Checking GitHub for manager updates (current: v$SCRIPT_VERSION)..."
    _gh_ver=$(fetch -qT10 -o - "$GITHUB_API" 2>/dev/null | \
        sed -n 's/.*"tag_name": *"v*\([^"]*\)".*/\1/p' | head -1 || true)
    [ -z "$_gh_ver" ] && die "could not fetch release info from GitHub"
    if [ "$_gh_ver" = "$SCRIPT_VERSION" ]; then
        info "Already at latest manager version (v$SCRIPT_VERSION)."
        exit 0
    fi
    [ -e "$SELF_PATH" ] || die "$SELF_PATH not found — run --install first"
    info "Updating manager: v$SCRIPT_VERSION -> v$_gh_ver"
    _tmpscript=$(mktemp /tmp/claude-freebsd-update.XXXXXX)
    trap 'rm -f "$_tmpscript"' EXIT
    fetch_to "$GITHUB_RAW/v${_gh_ver}/claude-freebsd.sh" "$_tmpscript"
    install -m 755 "$_tmpscript" "$SELF_PATH"
    info "Manager updated to v$_gh_ver at $SELF_PATH"
    write_wrapper
    info "Wrapper updated at $WRAPPER"
    exit 0
fi

# ── Linuxulator check ─────────────────────────────────────────────────────────

# kldstat -n checks by filename; also catches the case where the kernel was
# compiled with Linuxulator built in (sysctl exists even without the kmod).
if ! kldstat -q -n linux64.ko 2>/dev/null && \
   ! sysctl -n compat.linux.osrelease >/dev/null 2>&1; then
    printf '%s: Linuxulator does not appear to be active.\n' "$PROG" >&2
    printf '\nOne-time setup (as root):\n' >&2
    printf '    pkg install -y linux_base-rl9\n' >&2
    printf '    sysrc linux_enable=YES\n' >&2
    printf '    service linux start\n\n' >&2
    exit 1
fi

# Claude Code is a dynamically-linked ELF that needs glibc (libc.so.6,
# libpthread, libdl, libm, librt).  Check for the key library rather than
# the package name so this works however glibc was provisioned.
if [ ! -f /compat/linux/lib64/libc.so.6 ]; then
    printf '%s: Linux glibc runtime not found at /compat/linux/lib64/libc.so.6.\n' "$PROG" >&2
    printf '    Install it:  pkg install -y linux_base-rl9\n\n' >&2
    exit 1
fi

# ── conflict check ────────────────────────────────────────────────────────────

# Refuse to clobber a foreign /usr/local/bin/claude.
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

# ── skip binary download if already current ───────────────────────────────────

skip_binary=0
if [ -f "$VER_FILE" ] && [ "$force" -eq 0 ]; then
    cur=$(cat "$VER_FILE")
    if [ "$cur" = "$ver" ]; then
        if [ "$need_selfinstall" -eq 0 ]; then
            info "Claude Code is already at $ver — nothing to do (use --force to reinstall)."
            check_manager_update
            exit 0
        fi
        info "Claude Code is already at $ver — updating manager and wrapper only."
        skip_binary=1
    else
        info "Upgrading: $cur -> $ver"
    fi
fi

# ── download + verify ─────────────────────────────────────────────────────────

if [ "$skip_binary" -eq 0 ]; then

workdir=$(mktemp -d /tmp/cc-install.XXXXXX)
trap 'rm -rf "$workdir"' EXIT

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

# ── install Claude Code binary ────────────────────────────────────────────────

info "Installing Claude Code..."
mkdir -p "$REAL_DIR"
install -m 755 "$binary" "$REAL_BIN"
printf '%s\n' "$ver" > "$VER_FILE"

fi # end skip_binary

# ── write wrapper (always — may contain updated template) ─────────────────────

write_wrapper

# ── self-install ──────────────────────────────────────────────────────────────

if [ "$self" != "$SELF_PATH" ]; then
    info "Installing manager to $SELF_PATH..."
    install -m 755 "$self" "$SELF_PATH"
fi

# ── done ─────────────────────────────────────────────────────────────────────

printf '\n'
if [ "$skip_binary" -eq 0 ]; then
    info "Claude Code $ver installed."
else
    info "Manager and wrapper updated (Claude Code remains at $ver)."
fi
info "  Binary  : $REAL_BIN"
info "  Wrapper : $WRAPPER  (self-update disabled)"
info "  Manager : $SELF_PATH"
printf '\n'
if [ "$need_selfinstall" -eq 1 ]; then
    info "Going forward, manage Claude Code with:"
    info "  sudo claude-freebsd --update          # update to latest"
    info "  sudo claude-freebsd --update --channel stable"
    info "  sudo claude-freebsd --update --version X.Y.Z"
else
    info "To update:  sudo claude-freebsd --update"
fi
check_manager_update
