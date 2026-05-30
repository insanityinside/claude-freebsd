# claude-freebsd

Install and manage [Claude Code](https://claude.ai/code) on FreeBSD via the Linux ABI (Linuxulator).

> **Note:** This tool is a stopgap until Anthropic publishes a native FreeBSD
> binary. Progress is tracked in
> [issue #61313](https://github.com/anthropics/claude-code/issues/61313).

## Background

Anthropic ships Claude Code as a native binary built with `bun build --compile`.
From version 2.1.113 onward the npm package no longer contains runnable
JavaScript — it only pulls a per-platform compiled binary, and FreeBSD is not
among the supported targets.

The official `linux-x64` binary runs unmodified under FreeBSD's Linux ABI
(Linuxulator), confirmed on FreeBSD 15.0-RELEASE amd64. This tool automates
the fetch, verification, and installation of that binary, and keeps it updated
without relying on the binary's own auto-updater (which cannot write to
`/usr/local/bin` as a normal user anyway).

## Tested on

- FreeBSD 15.0-RELEASE-p5 amd64

If you're running an older version of FreeBSD and run into problems, please
[open an issue](https://github.com/insanityinside/claude-freebsd/issues) with
your FreeBSD version and the output of the failing command.

## Requirements

- FreeBSD **amd64** (the linux-x64 binary requires Linuxulator on amd64)
- Linuxulator enabled (`linux64` kernel module or built-in)
- `linux_base-rl9` package (provides the glibc runtime the binary links against)
- Root access for installation and updates

### One-time Linuxulator setup

```sh
pkg install -y linux_base-rl9
sysrc linux_enable=YES
service linux start
```

### Required `/etc/fstab` entries

Claude Code will hang on startup if any of these are missing or misconfigured.
The `fdescfs` entry **must** include `linrdlnk` — without it Claude hangs
indefinitely on startup (FreeBSD's `mount` command does not display this option
in its output; the tool checks `/etc/fstab` directly).

```
devfs     /compat/linux/dev      devfs     rw
tmpfs     /compat/linux/dev/shm  tmpfs     rw,size=1g,mode=1777
fdescfs   /compat/linux/dev/fd   fdescfs   rw,linrdlnk
linprocfs /compat/linux/proc     linprocfs rw
linsysfs  /compat/linux/sys      linsysfs  rw
/tmp      /compat/linux/tmp      nullfs    rw
/home     /compat/linux/home     nullfs    rw
```

After editing `/etc/fstab`, mount everything:

```sh
mount -a
```

## Installation

Download `claude-freebsd.sh` and run it as root with `--install`:

```sh
fetch https://raw.githubusercontent.com/insanityinside/claude-freebsd/main/claude-freebsd.sh
chmod +x claude-freebsd.sh
sudo ./claude-freebsd.sh --install
```

This will:

1. Check that all prerequisites are in place (Linuxulator, glibc, fstab mounts)
2. Fetch the latest `linux-x64` Claude Code binary from `downloads.claude.ai`
3. Verify its SHA256 against Anthropic's signed manifest
4. Install the binary to `/usr/local/libexec/claude-code/claude`
5. Install a wrapper at `/usr/local/bin/claude` that disables the binary's own
   auto-updater (which cannot update itself when installed system-wide)
6. Install itself to `/usr/local/bin/claude-freebsd` for future updates

## Usage

```
claude-freebsd --install   [OPTIONS]  install Claude Code (and this tool)
claude-freebsd --update    [OPTIONS]  update Claude Code to latest
claude-freebsd --uninstall            remove Claude Code, the wrapper, and this tool
claude-freebsd --help                 show this help

Options (for --install / --update):
  --channel latest|stable  release channel to track (default: latest)
  --version X.Y.Z          install a specific version instead
  --force                  reinstall even if already at the target version
```

### Updating Claude Code

```sh
sudo claude-freebsd --update
```

The wrapper installed at `/usr/local/bin/claude` checks once per day (per user)
whether a newer release is available and prints a one-line notice on stderr if
so. To suppress it:

```sh
export CLAUDE_FBSD_NO_NOTIFY=1
```

### Selecting a release channel

The channel choice is **persistent** — setting it once with `--channel` saves
it to `/usr/local/share/claude-freebsd/channel` and becomes the default for all
future `--update` runs and the per-launch update nudge. You do not need to pass
`--channel` again unless you want to switch.

Install on the stable channel:

```sh
sudo claude-freebsd --install --channel stable
```

Switch to stable after an existing install:

```sh
sudo claude-freebsd --update --channel stable
```

Switch back to latest:

```sh
sudo claude-freebsd --update --channel latest
```

### Pinning a specific version

```sh
sudo claude-freebsd --update --version 2.1.100
```

### Updating this tool

```sh
sudo claude-freebsd --self-update
```

Downloads the latest tagged release from GitHub and replaces
`/usr/local/bin/claude-freebsd`. After any `--install`, `--update`, or
`--uninstall` run, the tool also checks GitHub (at most once per day) and
prints a one-line notice if a newer version is available.

### Uninstalling

```sh
sudo claude-freebsd --uninstall
```

This removes `/usr/local/bin/claude` (the wrapper), `/usr/local/libexec/claude-code/`
(the binary and version files), `/usr/local/share/claude-freebsd/` (internal status/config files) and `/usr/local/bin/claude-freebsd` (this tool).
It will only remove files it installed itself — if anything at those paths was
put there by another means it will be left untouched. User config (`~/.claude/`)
is never removed.

## How it works

The wrapper at `/usr/local/bin/claude`:

- Sets `DISABLE_AUTOUPDATER=1` and `DISABLE_UPDATES=1` before exec'ing the
  binary, preventing Claude Code from attempting to update itself
- Checks that all required Linuxulator mounts are present and warns on stderr
  if any are missing or misconfigured
- Performs a throttled background check (at most once per day, 2-second timeout)
  and prints a nudge if a newer release is available

The real binary lives at `/usr/local/libexec/claude-code/claude` and is never
on `PATH` directly.

## Related

- [Claude Code issue #61313](https://github.com/anthropics/claude-code/issues/61313) — tracking native FreeBSD binary support
- [Claude Code issue #30640](https://github.com/anthropics/claude-code/issues/30640) — original FreeBSD packaging request

## License

[BSD 2-Clause](LICENSE) — Copyright (c) 2026, Richard Aspden
