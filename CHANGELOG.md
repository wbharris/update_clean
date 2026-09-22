# Changelog

All notable changes to the Kali Update script will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [5.15] - 2026-09-22

### Changed
- `apt-get update`, `upgrade`, and `full-upgrade` failures increment the run failure count. A Kali index miss (including apt's exit 0 with "Failed to fetch") retries `kali.download`, then RWTH Aachen, then Princeton, and keeps the mirror that works in `/etc/apt/sources.list`.
- `apt clean` runs only after a successful upgrade, so a 503 does not throw away archives already downloaded.
- Critical packages (`base-files`, `base-passwd`, `bash`, `coreutils`, `util-linux`, running kernel) are held only while `autoremove` runs, then released. Existing holds on those packages and on `linux-image-*` / `linux-binary-*` are cleared at the start of a real run.
- Log retention deletes matching `*.apt-warnings` files and orphan warning logs.

### Fixed
- Kernel package match no longer uses a `grep` range that aborts with "Invalid range end".
- Old-kernel removal understands Kali `linux-binary-VERSION` as well as `linux-image-VERSION`, includes packages in the `hold ok installed` state, and purges both packages for a version that is removed.
- Keyring refresh downloads to a temporary file and tries more than one URL, so a reset connection cannot truncate the installed keyring.

## [5.14] - 2026-09-10

### Added
- `CLEAN_DEV_CACHES` (default: true) removes regenerable `/root/.cache/{pip,go-build,uv}` (and the sudo user's copies). Next pip/go/uv job rebuilds the cache. Set `CLEAN_DEV_CACHES=false` to skip.

## [5.13] - 2026-06-23

### Added
- `KERNEL_KEEP` env/config option (kernels to keep besides running; default: 2)
- Robust kernel removal: `list_installed_kernel_images`, `find_running_kernel_pkg`, `purge_kernel_related`, `remove_old_kernels`
- Bash 4+ requirement check; `set -o errtrace`
- `/etc/kali-update.conf` ownership validation (must be root-owned)
- ANSI color stripping in log files via `tee` + `sed`
- Reboot detection via before/after mtime of `/var/run/reboot-required`
- `FAILURES` and non-zero exit when failures are recorded
- Improved `cleanup()` trap: `flock` release, `sync`, proper exit code

### Changed
- Dry-run no longer runs keyring download, `dpkg --configure`, `apt-get update`, `apt-mark hold`, or destructive cleanup steps
- Dry-run logs planned kernel purges instead of executing them
- `apt-get` used for scripted APT steps (instead of `apt` alias)
- Running kernel package resolved dynamically for `apt-mark hold`

### Fixed
- Removed stray `done <<< "$KERNELS"` redirects from unrelated loops (config, preflight, snap, etc.)
- `--no-kernel` flag now honored before kernel removal
- Kernel removal no longer uses broken `head -n -1` logic (wrong kernel could be removed)
- Renamed `KERNELS` shadowing to `KERNELS_REMOVED` flag
- Logging helpers defined before `load_config_files()` (fixes `warn` before definition)

## [5.8] - 2026-06-19

### Added
- Full CLI support: `--dry-run`, `--no-kernel`, `--help` / `-h`, `--version` / `-v`
- Real dry-run mode (uses `-s` for APT commands and skips destructive actions)
- File locking using `flock` to prevent concurrent runs
- Desktop notifications via `notify-send` when running in a graphical session
- `needrestart` integration (runs automatically if installed)
- Config file support (`/etc/kali-update.conf`, `~/.config/kali-update.conf`, etc.)
- `LOG_RETENTION` environment variable (or config file) to control number of logs kept
- Disk space checks for `/`, `/var`, and `/boot`
- Pre-flight APT lock detection with waiting
- `systemd-resolved` status check
- Explicit `apt-get check` for package cache integrity
- Separate APT warnings log (`*.apt-warnings`)
- `apt-mark hold` on critical packages before cleanup
- Proper old kernel + headers + modules removal (keeps current + previous)
- GRUB update after kernel removal
- Summary with disk space freed calculation (pure awk, no `bc` dependency)
- Version is now logged at the start of every run

### Changed
- Replaced `bc` with pure `awk` for disk calculations (better portability)
- Improved Snap old revision removal logic
- Better error handling and warnings for non-critical steps

### Fixed
- Keyring now includes proper signature verification (`.asc` + `gpg --verify`)

## [5.7] - Previous

- Integrated multiple robustness improvements (keyring verification, better kernel logic, pre-flight checks, etc.)

## [5.x] and earlier

See git history for older changes.
