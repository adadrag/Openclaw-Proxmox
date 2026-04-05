# Changelog

All notable changes to `setup-openclaw-lxc.sh` are documented here.

---

## 2026-04-05

### Fixed
- **Desktop shortcuts now launch without prompts** — PCManFM-Qt 2.1.0 (Debian 13) checks `metadata::trust` gvfs metadata (not the executable bit, not `user.trusted` xattr, not `metadata::trusted`). Set via `dbus-launch gio set <file> metadata::trust true` run as the openclaw user during installation. `dbus-launch` creates a temporary D-Bus daemon and auto-activates gvfsd-metadata via D-Bus service activation, so no running VNC session is needed.

### Added
- **Admin user creation** — installer now asks for a Linux username to create with full passwordless sudo rights; this user is separate from the `openclaw` service account
- **SSH public key setup** — installer asks for an SSH public key for the admin user; key is written to `~/.ssh/authorized_keys`
- **SSH hardening** — password authentication is disabled in `sshd_config`; only key-based login is allowed

### Changed
- **Removed `--no-sandbox` from Chrome** — Chrome's sandbox relies on Linux user namespaces. On this Proxmox host, unprivileged user namespaces are enabled (`/proc/sys/kernel/unprivileged_userns_clone = 1`, `max_user_namespaces = 127591`), and the LXC container is created with `nesting=1` which passes these through to the container. Chrome runs as the non-root `openclaw` user, so it can create its own user namespace for sandboxing without needing `--no-sandbox`. The flag was removed from the `.desktop` file, CLI wrapper, OpenClaw `browser.noSandbox` config, and dashboard shortcut.

### Previous history

Earlier changes tracked in git commit history.
