# 03 (deep dive): How the forwarder decides what to scan

Companion to [03-telemetry.md](03-telemetry.md). In short: the forwarder filters a lot **by itself**, but you can only configure **where** it looks, not **which** files it picks.

Everything here comes from the 1.0.0 JAR (`javap` on `MemberFiles`, `ForwarderConfig`, `LogIdentity` and `ArchiveIdentity`), not from the docs. Constant names like `MAX_DEPTH` are the real field names.

## What you can configure: four settings

The forwarder reads **only environment variables**. It takes no command-line arguments ("every setting is an environment variable") and no properties file. The closest thing to a file is Compose's `env_file:`.

| Variable | Our value | What it does |
|---|---|---|
| `GF_TELEMETRY_FORWARDER_SCAN_DIR` | `/var/gemfire` | **One** root folder. If it isn't set, the working directory is used. It refuses system folders like `/`, `/etc`, `/usr`, `/var` or `/Users` ("would be scanned, a system folder"). |
| `GF_TELEMETRY_FORWARDER_INTERVAL` | `10` | Seconds between scans |
| `GF_TELEMETRY_FORWARDER_UPLOAD_LOGS` | (default `true`) | `false` ships stats only |
| `GF_TELEMETRY_FORWARDER_ONCE` | (default `false`) | `true` = one pass, then exit (handy for backfilling history or a cron job) |

Plus the store settings it shares with the MCP server: `GF_TELEMETRY_STORE` and `GF_S3_*`.

There are **no include/exclude patterns and no member-name setting.** The JAR has messages for old settings it removed:

| Old setting | Message |
|---|---|
| `GF_FWD_MEMBER_NAME` / `GF_FWD_LAYOUT` | "nothing: each file's member is read from the file itself" |
| `GF_FWD_MAX_FILE_BYTES` | "nothing: archives of any size are shipped" |
| `GF_FWD_LOG_FLUSH_BYTES` | "nothing: the log chunk size is fixed at 1 MiB" |
| `GF_FWD_GZIP` | "nothing: uploads are always compressed" |

As with the MCP server, an **unknown** `GF_TELEMETRY_FORWARDER_*`, `GF_S3_*` or `GF_TELEMETRY_*` variable stops startup, with a "did you mean…?" hint. It ignores the `*_SERVICE_HOST` / `*_PORT` variables that Kubernetes adds by itself.

## The built-in filtering

### 1. How it walks the folders (`MemberFiles`)

- **5 levels** deep (`MAX_DEPTH = 5`) and at most **50,000 entries** (`MAX_ENTRIES`). Past that it gives up with "the scan root is too broad". Files it already found keep shipping.
- **Hidden folders are skipped:** anything starting with `.` (like our `.forwarder.lock`) is never looked into.
- **It doesn't follow symlinks** (`NOFOLLOW_LINKS`), so a link to another folder won't pull that folder in.
- It does a **full walk every 5 minutes** (`FULL_WALK_INTERVAL`). Between full walks it seems to recheck only folders it already knows about. If that reading is right, a brand-new member folder could take up to 5 minutes to be noticed.

### 2. Only two file extensions

`*.gfs` and `*.log`. Everything else (`.dat`, disk stores, `.marker` files) is ignored without a message.

### 3. Then it checks what's inside each file

This is the real filter.

- **`.gfs`:** it reads the archive header for the member name.
  - The archive must come from **GemFire 10.2 or later**. Older headers hold the host name instead of the member name and are rejected.
  - A half-written header means "not yet shipping"; it tries again on the next scan.
- **`.log`:** it reads up to 2,000 lines or 512 KB, looking for the `Startup Configuration:` block with `name=`.
  - If there's no block, it falls back to the member name in the log lines, if that name is consistent.
  - If neither works: "it is not a GemFire member log". That's why `pulse.log` and gfsh logs are skipped.

### 4. Rules based on file names

| Pattern | What happens | Why |
|---|---|---|
| `meta-*-NN.log` | always skipped | GemFire bookkeeping |
| `<name>-NN-NN.log` (rolled log) | **not** shipped | the live log is followed byte by byte, so rolled copies would be duplicates |
| `<name>-NN-NN.gfs` (rolled stats) | shipped **once** | each rolled archive holds history that isn't in the live file |
| two live files claiming the same member | **neither** is shipped, with a warning to "remove or move the stale ones" | it can't tell which one is real; other members keep shipping |

## How to control what it scans

Since you can't filter by pattern, you choose the files by choosing the folder:

1. **Point `SCAN_DIR` at a narrower folder,** e.g. `/var/gemfire/server-1` for a single member ("or one member's volume", as its own error message puts it).
2. **Mount only what you want.** In Compose, that means mounting just `./data/gemfire/server-1:/var/gemfire/server-1` and so on, instead of the whole folder. This is the closest you get to an include list.
3. **Run more than one forwarder,** one per folder. `.forwarder.lock` stops two forwarders from scanning the same folder.
4. **Stats only:** set `GF_TELEMETRY_FORWARDER_UPLOAD_LOGS=false`.

## In this lab

`/var/gemfire` holds just the 4 member folders (`locator`, `server-1..3`), so the defaults are exactly right. The locator is included like any other member: `locator/locator.gfs` and `locator/locator.log` end up under `gfmcp/locator/` in the store.

This becomes relevant in **chunk 8 (runner mode)**: gemfire-runner's data folder has other things in it, and we'll want to point the forwarder at just the member folders.

## Look for yourself

```bash
# unpack the TAR somewhere scratch, then dump the strings and constants
mkdir -p /tmp/fwd && tar -xf vendor/gemfire-telemetry-forwarder-1.0.0.tar -C /tmp/fwd
J=/tmp/fwd/gemfire-telemetry-forwarder-1.0.0/lib/gemfire-telemetry-forwarder-1.0.0.jar
javap -p -constants -cp $J com.vmware.gemfire.telemetry.forwarder.MemberFiles | grep 'static final'
javap -v -cp $J com.vmware.gemfire.telemetry.forwarder.ForwarderConfig | grep '= String'
```

(macOS `strings` won't help here: it mistakes `.class` files for Mac binaries.)
