# convos-releases

Shared release tooling for Convos apps ([convos-ios](https://github.com/xmtplabs/convos-ios), [convos-client](https://github.com/xmtplabs/convos-client) android).

```
      cut (Thu 15:45 ET)         RCs per push        @convos-conductor merge
dev ───┬───────────────────────────────────────────────── (auto-bumped to next minor)
       └─ release/x.y.z ──●──●── notes pencil-edited ──┐
                                                       ▼
main ───────────────────────────────────────────────────●── tag vx.y.z ── stores staged
                                                        │                  (human presses submit)
                                                        └─ hotfix/x.y.z+1 ── fix ──→ PR to main
                                                                              └─ back-merge PR → dev
```

Weekly train: Thursday's cut branches `release/x.y.z` from dev, every push to
it uploads an RC, humans edit notes, one `@convos-conductor merge` comment
merges both repos, and promotion stages the store submissions — a human only
presses "Start rollout" / "Submit for Review". See `RUNBOOK.md` for
operations, `train/README.md` for the CLI.

- **`train/`** — the `train` CLI (cut, hotfix, RC recording, promote, merge).
  All release logic lives here, unit-tested; workflows are plumbing only.
- **`fastlane/lanes/`** — all fastlane lanes. `ios.rb` and `android.rb` are the
  per-platform entry points consumer repos import.
- **`releases/<version>/`** — one dir per train: `manifest.yml` (durable state:
  source shas, RC artifact ids, promotion record) + release-notes files.
- **`.github/workflows/`** — reusable (`workflow_call`) workflows consumer
  repos call with `uses: xmtplabs/convos-releases/.github/workflows/<f>.yml@main`.

## How consumers wire in

1. Flake input: `convos-releases.url = "github:xmtplabs/convos-releases";`
2. Devshell packages: `inputs'.convos-releases.packages.fastlane` (+ `.train`)
3. Stub `fastlane/Fastfile`:
   ```ruby
   import "#{ENV.fetch('CONVOS_LANES')}/ios.rb"   # or android.rb
   ```
   plus a local `fastlane/Pluginfile` (fastlane only loads plugin gems when
   the project has one). Repo-specific `Appfile`/`Matchfile` stay local too.
4. Thin caller workflow: triggers + `uses: …@main` + `secrets: inherit`.

**Versioning:** lane/gem/CLI code is pinned by each consumer's `flake.lock`
(`nix flake update convos-releases` to bump). The `@main` workflow ref only
pins step orchestration — reusable workflows run `nix develop ./` on the
caller's checkout.

## Maintenance

After changing `Gemfile`:

```bash
nix develop
bundle lock            # refresh Gemfile.lock
bundix                 # regenerate nix/gemset.nix
```

This repo is public: never commit secrets, keystores, or service-account
material. Lanes read credentials from env vars only.
