# prox-backup.sh

Streaming backups of **Proxmox VE** virtual machines and LXC containers to
**Backblaze B2**, with a guided setup and per-client configuration.

No temporary files on disk: `vzdump` writes to stdout and `rclone rcat` uploads
straight to B2.

```
vzdump <guest> --stdout | rclone rcat b2-remote:bucket/folder/<guest>-<date>
```

> [!WARNING]
> **Heavily AI-generated code.** This project was written almost entirely with
> AI coding assistants, with human review. It is backup software: it has been
> tested against a local harness with stubbed Proxmox commands, but it has not
> been audited by a security professional and it has not been run for months in
> production. Read it, test it on a non-critical guest, and verify that you can
> actually **restore** a backup before you rely on it. Do not make it your only
> backup.

## Features

- **VMs and containers**: `qm` for VMs (`.vma`) and `pct` for LXC containers
  (`.tar`), with the compression you choose (`zstd` by default).
- **Asynchronous**: `start` detaches the process with `setsid`, so closing the
  terminal or the SSH session does not interrupt a running backup.
- **Multi-client**: one configuration file per client in
  `/etc/prox-backup/clients/<client>.conf`, each with its own rclone remote,
  bucket and folder.
- **Guided setup** (`setup`): creates or updates the rclone remote with your B2
  application key, validates the credentials, lists the buckets, creates bucket
  and folder, tests write and delete, then lists the VMs and containers on the
  node so you can choose what to back up.
- **Per-guest retention**, applied only after the upload has been verified.
- **Container fallback**: if the storage does not support snapshots, the backup
  is retried in `suspend` mode.

## Requirements

- Proxmox VE 8 or 9 (the `vzdump` options used are unchanged in 9.x)
- `rclone` >= 1.60, `python3`, `flock`, `numfmt` (coreutils)
- A Backblaze B2 bucket and an application key with read/write/delete
  permissions

`setup` and the backups must run as **root** on the Proxmox node.

## Install

```bash
install -m 0755 prox-backup.sh /usr/local/sbin/prox-backup.sh
```

## Configuration

```bash
/usr/local/sbin/prox-backup.sh setup acme
```

The wizard asks, in order:

1. the client name (used as the config file name);
2. the Backblaze Key ID and Application Key;
3. the rclone remote name (default `b2-<client>`);
4. the bucket: pick one from a numbered list or type a new name;
5. the folder inside the bucket (default `proxmox-<client>`);
6. which VMs and containers to back up, chosen from the guests on the node;
7. how many copies to keep per guest, and optionally a bandwidth limit.

Credentials are written only to `rclone.conf` (mode `600`); the client config
file contains references only.

## Usage

```bash
# start in the background: the terminal can be closed immediately
prox-backup.sh start acme

# lock state and the last lines of the latest log
prox-backup.sh status acme

# run in the foreground (for cron or systemd)
prox-backup.sh run acme
```

Nightly backup with cron:

```cron
0 3 * * * /usr/local/sbin/prox-backup.sh run acme
```

With a single client configured, the name can be omitted.

## Configuration file

`/etc/prox-backup/clients/<client>.conf` is a shell script, sourced as root:

```bash
RCLONE_REMOTE="b2-acme:acme-bucket/proxmox-acme"

GUESTS=(100 102 104)      # VM and container IDs, in the order you prefer

MODE_VM="snapshot"        # snapshot | suspend | stop
MODE_CT="snapshot"
MODE_CT_FALLBACK="suspend"   # used for CTs when the storage lacks snapshots

COMPRESS="zstd"           # zstd | gzip | lzo | 0
KEEP_COPIES=2             # total copies per guest, including the newest
BWLIMIT=""                # e.g. 8M, empty = no limit
VZDUMP_TMPDIR=""          # CT in suspend mode only
```

## How it works

**File names**: `vm100-2026-01-31.vma.zst`, `ct104-2026-01-31.tar.zst`. One
file per guest per day: running the script twice on the same day overwrites the
same object.

**Verification** after each upload: the remote object exists and its size is
greater than zero. This is not an integrity check of the archive.

**Retention**: after a verified upload, copies of the same guest beyond
`KEEP_COPIES` are deleted, oldest first. If verification fails, older copies are
left untouched.

**`hard_delete`**: the remote created by `setup` sets `hard_delete = true`;
otherwise deletions on B2 leave hidden versions that keep consuming storage.

**Logs**: one file per run in `/var/log/prox-backup/`, plus a
`<client>-latest.log` symlink.

**Lock**: one backup at a time per client
(`/run/prox-backup-<client>.lock`).

Environment overrides for the paths: `PROX_BACKUP_CONF_DIR`,
`PROX_BACKUP_LOG_DIR`, `PROX_BACKUP_RUN_DIR`.

## Testing

```bash
bash test/smoke.sh
```

The smoke test needs neither Proxmox nor Backblaze: it stubs `qm`, `pct` and
`vzdump`, and uses a `local` rclone remote as a fake B2 bucket. It covers the
guided setup, VM and container backup, the container fallback, retention,
process detachment and error handling.

## Known limitations

- Archives are not encrypted: confidentiality depends on the B2 bucket.
- One copy per guest per day (the file name only contains the date).
- No restore command: restoring is done with `qmrestore` / `pct restore`.
- No integrity check beyond object existence and size.

## License

[MIT](LICENSE)
