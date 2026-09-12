# Changelog

Canonical source: [docs.hellocron.com/reference/client-changelog](https://docs.hellocron.com/reference/client-changelog/)

## v1.5-260912 (current)

Released 2026-09-12. One question at setup, names you can read in the dashboard.

- `configure` asks for the ingest key and nothing else. The API address is built into the client, so a config file holds just the key. `configure --api-key ck_xxx --project name` sets it up without prompting, and `--advanced` still asks for the API URL and ping endpoint for self-hosted or staging installs.
- `run` hands the command's output back on the stream it came from. It was captured for the ping and never printed, which silently emptied crontab lines that append to a log file and stopped cron from mailing a failure.
- `discover` builds monitor names from the URL or the script instead of the first word on the line: `fakturex-fcron`, not `curl-16f0fd`. Names are sanitised to the character set the API accepts, so a dot in a script filename no longer produces a monitor whose every ping is rejected. A short hash is appended only when two jobs would otherwise share a name.
- Prompts show a stub of the stored key instead of the whole thing.
- `discover --host-prefix` puts the short hostname in front of every generated name, for one crontab deployed to several servers. Without it names stay per job, because a monitor name cannot be changed later and a host can be renamed.
- The reported host can be pinned with `hostname=` in the config file or `HELLOCRON_HOSTNAME`, which matters in containers where the hostname is a random hex. `doctor` prints the host it would report.

## v1.4-260911

Released 2026-09-11. New name, new home.

- The script is `hellocron.sh`, downloaded from `https://hellocron.com/hellocron.sh`; `hellocron update` checks that URL.
- Config files are `~/.hellocron.conf` and `~/.hellocron-management.conf`; environment variables are `HELLOCRON_API_KEY`, `HELLOCRON_MANAGEMENT_KEY`, `HELLOCRON_PANEL_URL`.
- Default endpoints point at `api.hellocron.com` and `app.hellocron.com`.
- New `hello:cron` header in `help`, `doctor` and `version`.

## v1.3-260727

Released 2026-07-27. Config as code from the command line.

- `hellocron export` downloads every monitor on the account as a single bundle file.
- `hellocron apply -f monitors.json` reconciles the account with that file, with `--dry-run` to preview the changes first. Apply never deletes: monitors missing from the bundle are reported as orphaned and left alone.
- `hellocron configure --management-key` stores the Management API key in `~/.hellocron-management.conf` (permissions 600), kept **separate** from `~/.hellocron.conf`. The ingest key belongs on every monitored server; the management key can delete monitors along with their history, so the two never share a file. `HELLOCRON_MANAGEMENT_KEY` takes precedence and is the right choice for CI.
- Mixing the two keys up is now caught locally with an explanatory message instead of a bare `401`: `apply`/`export` refuse an ingest key (`ck_`), and pings refuse a management key (`mk_`).
- `hellocron doctor` reports the management key and the permissions of its config file when present.

## v1.2-260704

Released 2026-07-04. First public release, served at the download URL.

- Job lifecycle pings (`run`, `complete`, `fail`, `skip`) and command wrapping with automatic exit-code reporting.
- Interactive setup via `hellocron configure`, with configuration stored in `~/.hellocron.conf`.
- Cron job discovery via `hellocron discover`: detects existing cron jobs and generates a monitoring config.
- Self-update via `hellocron update` (and `update --check`): SHA-256 verification, syntax check, and a `.bak` backup before replacing.
- Environment diagnostics via `hellocron doctor`.
- Configurable timeouts, verbose mode, telemetry toggle, and default-project support.
