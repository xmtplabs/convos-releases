# Train

A small Ruby app that conducts the XMTP release train: weekly release-branch
cuts across convos-ios and convos-client, durable train state in
`releases/x.y.z/manifest.yml`, and per-upload artifact recording.

Run it exactly as CI does:

```sh
GH_TOKEN=$(gh auth token) nix develop --command train cut --dry-run
```

Tests run as the package's `checkPhase` (`nix build -L .#train`) or
directly from `train/`: `ruby -Ilib -Itest test/run_all.rb`.

## Subcommands

### `train cut [--dry-run] [--force] [--schedule CRON] [--date YYYY-MM-DD]`

The weekly cut. Decides whether it is cut time (15:45 America/New_York on
the `cut-day` from `release-config.yml`, minus `skip-dates`), recovers
in-flight trains, captures one dev SHA per app repo, commits the manifest +
seeded release notes first, then ensures per repo: `release/x.y.z` branch,
version-bump PR to dev (auto-merge), release PR to main.

- `--dry-run` — print the full plan (versions, SHAs, branches, PRs); mutate
  nothing.
- `--force` — bypass the day/time/skip checks (manual cut).
- `--schedule CRON` — the cron slot that fired (CI passes
  `github.event.schedule`); keeps exactly one of the two UTC slots across
  DST.
- `--date YYYY-MM-DD` — override "today" (ET) for testing.

### `train append-rc --repo OWNER/NAME --sha SHA --run URL --key (version-code|build-number) --value N [--version X.Y.Z] [--dry-run]`

Records an uploaded release candidate's artifact identity in the train
manifest. Idempotent per (sha, key, value); value must be a positive
integer; pushes with retry and fails loud if the manifest can't be updated.
The train version is derived from `GITHUB_REF_NAME` (`release/X` /
`hotfix/X`) unless `--version` is given.

### `train seed-notes --repo OWNER/NAME [--since YYYY-MM-DD]`

Prints seeded release notes to stdout: PRs merged to dev since `--since`
(default: last 7 days), grouped Features / Fixes / Other by title prefix,
bot authors excluded.

### `train bump-version (read|bump) DIR [NEW_VERSION]`

Reads or sets an app checkout's marketing version. Knows both layouts:
`android/gradle.properties` (`VERSION_NAME`) and
`Convos.xcodeproj/project.pbxproj` (`MARKETING_VERSION`, all entries).
Fails on inconsistent or malformed versions.

### `train status [VERSION]`

Human-readable dump of one train (or all): version, kind, cut date, and
per-repo status with every recorded RC (commit, run URL, artifact id).
Read-only; no token needed.

## Environment

- `GH_TOKEN` — required for anything that talks to GitHub (`cut`,
  `append-rc`, `seed-notes`).
- `GITHUB_REF_NAME` / `GITHUB_ACTIONS` — set by CI; `cut` refuses to run
  from a non-main ref, and error output switches to workflow annotations.
