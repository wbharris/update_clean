# Kali Update

One clean update & cleanup script for Kali Linux.

**Version:** See the `VERSION` file in this repo (or run `./kali-update.sh --version`)

## Main Script

**`kali-update.sh`** — The complete update and cleanup script.

### What it does

**Update:**
- Refreshes Kali keyring (with GPG verification)
- Fixes interrupted installs and broken packages
- `apt update`
- Package cache check (`apt-get check`)
- `apt upgrade`
- `apt full-upgrade`

**Cleanup:**
- `apt --purge autoremove`
- `apt autoclean` + `apt clean`
- Purge residual config files (`apt purge '~c'`)
- Remove old kernels (keeps current + previous for safety)
- Remove old snap revisions
- Update + remove unused Flatpaks
- Firmware updates (fwupdmgr)
- Vacuum journal logs (last 30 days)
- Clean partial apt lists
- Update locate database (if present)
- Rebuild man database
- Update GRUB after kernel changes

**Other:**
- Tracks disk usage before/after (across /, /var, /boot)
- Keeps only the last **3** log files
- Color output + clear logging
- Records last run details in /var/lib/kali-update/last-run
- Safety checks (root, internet, disk space, APT lock)

### Usage

```bash
sudo ./kali-update.sh
```

Or with options:
```bash
sudo ./kali-update.sh --dry-run
sudo ./kali-update.sh --no-kernel
```

Run periodically (recommended weekly).

### Logging & Records

- Detailed logs: `/var/log/kali-update/`
- Only the most recent 3 logs are kept automatically.
- Last run record: `/var/lib/kali-update/last-run`

### Safety

- Must run as root.
- Requires at least 2GB free disk space.
- Keeps current + one previous kernel as fallback.
- Non-critical steps won't stop the script.

### Scheduling

**Cron example (weekly):**

```bash
0 4 * * 0 /path/to/kali-update.sh
```

Or use a systemd timer for more control.

### Versioning

- Version is in the `VERSION` file.
- Script also supports `--version`.
- See `CHANGELOG.md` for history.
