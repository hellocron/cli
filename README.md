# HelloCron CLI

Lightweight shell client for [HelloCron](https://hellocron.com): cron job and
HTTP/SSL endpoint monitoring via simple pings. Wraps the ping API so you don't
write curl by hand.

Full docs: [docs.hellocron.com/guides/shell-script](https://docs.hellocron.com/guides/shell-script/)

## Installation

Download the latest client and put it on your PATH:

```bash
curl -fsSL https://hellocron.com/hellocron.sh -o /usr/local/bin/hellocron
chmod +x /usr/local/bin/hellocron
```

Optional: verify the download against the published checksum.

```bash
curl -fsSL https://hellocron.com/hellocron.sh.sha256
sha256sum /usr/local/bin/hellocron
```

Or clone this repo and run `hellocron.sh` directly.

Configure once with your ingest key, created in the panel under Settings and API keys:

```bash
hellocron configure                      # asks for the key, nothing else
hellocron configure --api-key ck_xxx     # or set it without prompting
```

That writes `~/.hellocron.conf` with permissions 600:

```ini
api_key=ck_your_ingest_key
telemetry_enabled=true
default_project=
```

The API address is built into the client, so it is not part of the config. Point the
client somewhere else only for a self-hosted or staging setup, with
`hellocron configure --advanced` or an `api_url=` line in the config file.

A legacy JSON config at `~/.hellocron-config.json` is still read when `.hellocron.conf`
is absent.

## Version and updates

The download URL always serves the latest client. Updates are on demand, not
automatic.

```bash
hellocron version          # installed version and date
hellocron update --check   # check whether a newer version exists
hellocron update           # download, verify checksum, replace (keeps a .bak)
```

`update` pulls from the same URL, verifies the SHA-256 checksum, runs a syntax
check, backs up the current file as `.bak`, then swaps it in. It needs `curl`,
`sha256sum` and `bash`, and only updates over HTTPS.

Version history: see `CHANGELOG.md`, or the canonical
[client changelog](https://docs.hellocron.com/reference/client-changelog/).

## Usage

```bash
hellocron ping <monitor-name> <status> [options]
```

### Statuses

```bash
hellocron ping my-job run
hellocron ping my-job complete
hellocron ping my-job fail
hellocron ping my-job skip
```

### Options

| Flag | Description |
|------|-------------|
| `--tags <a,b>` | Comma-separated tags |
| `--project <name>` | Project the job belongs to |
| `--timeout <seconds>` | Expected maximum run time, sent with the `run` state |
| `[message]` | Free text after the state becomes the message (for example the error) |

`ping` sends one state and nothing else. Duration, exit code and captured error output
come from `run`, which wraps the command and sends both pings for you:

```bash
hellocron run db-backup --tags nightly pg_dump mydb > /tmp/backup.sql
```

### Example

```bash
hellocron ping db-backup run

pg_dump mydb > /tmp/backup.sql
EXIT=$?

if [ $EXIT -eq 0 ]; then
  hellocron ping db-backup complete
else
  hellocron ping db-backup fail "pg_dump exited with $EXIT"
fi
exit $EXIT
```

## Checking your setup

Run `doctor` to verify that everything is configured correctly:

```bash
hellocron doctor          # checks config, API URL, key, connectivity
hellocron doctor --ping   # additionally sends a real test ping (state: skip)
```

It checks: HTTP tool availability (curl/wget), config file and its permissions,
API URL and key, temp directory, API reachability (`/health`) and crontab access.
Exit code is `0` when everything is OK, `1` when problems are found.

## Using in Docker

Mount the script and config into your container:

```yaml
volumes:
  - ./hellocron.sh:/usr/local/bin/hellocron:ro
  - ./.hellocron.conf:/root/.hellocron.conf:ro
```

## Checking your setup

```bash
hellocron doctor          # config, key, connectivity, crontab access
hellocron doctor --ping   # additionally sends a real test ping (state: skip)
```

## Sign up

HelloCron is free to use: [hellocron.com](https://hellocron.com)

## License

MIT, see `LICENSE`.
