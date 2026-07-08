# convos-releases

Shared release tooling for Convos apps ([convos-ios](https://github.com/xmtplabs/convos-ios), [convos-client](https://github.com/xmtplabs/convos-client) android):

- **`fastlane/lanes/`** — all fastlane lanes. `ios.rb` and `android.rb` are the
  per-platform entry points consumer repos import.
- **`nix/modules/fastlane.nix`** — exposes `packages.fastlane`: a wrapper that
  pins `CONVOS_LANES` to this repo's lanes (in the nix store) and runs the
  bundlerEnv fastlane. Builds on linux + darwin.
- **`.github/workflows/`** — reusable (`workflow_call`) workflows consumer
  repos call with `uses: xmtplabs/convos-releases/.github/workflows/<f>.yml@main`.

## How consumers wire in

1. Flake input: `convos-releases.url = "github:xmtplabs/convos-releases";`
2. Devshell package: `inputs'.convos-releases.packages.fastlane`
3. Stub `fastlane/Fastfile`:
   ```ruby
   import "#{ENV.fetch('CONVOS_LANES')}/ios.rb"   # or android.rb
   ```
   plus a local `fastlane/Pluginfile` (fastlane only loads plugin gems when
   the project has one). Repo-specific `Appfile`/`Matchfile` stay local too.
4. Thin caller workflow: triggers + `uses: …@main` + `secrets: inherit`.

**Versioning:** lane/gem code is pinned by each consumer's `flake.lock`
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
