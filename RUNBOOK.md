# Release Train Runbook

Manual procedures for the weekly release train: what the automation does,
how to drive it by hand when CI is broken, and how to abandon a train that
went wrong. The `train` CLI is the same code CI runs — prefer it over raw
git/API commands even when operating manually (see `train/README.md` for
subcommand details).

Everything below assumes the convos-releases dev shell:

```sh
cd convos-releases
GH_TOKEN=$(gh auth token) nix develop --command train <subcommand>
```

Your account needs: push access to convos-ios/convos-client, org-admin (or
equivalent bypass) for direct pushes to convos-releases `main`, and — for
store steps — App Store Connect / Play Console access.

## The normal week (no action required)

1. **Thursday 15:45 ET** — the `release-cut` workflow cuts `release/x.y.z`
   from both repos' dev tips: manifest + seeded notes committed to
   `releases/x.y.z/` first, then branches, version-bump PRs to dev
   (auto-merged), and release PRs to main.
2. **Every push to `release/x.y.z`** uploads an RC (TestFlight / Play
   internal) and records its artifact identity in the manifest.
3. **Humans edit notes** any time before merge: GitHub web pencil on
   `releases/x.y.z/*.md`.
4. **Merge of the release PR** (go/no-go) → Phase-2 promotion stages the
   store submissions from the manifest-recorded artifacts. Until Phase 2
   ships: submit manually from the QA'd artifacts (see "Manual store
   submission").
5. Check state at any point: `train status x.y.z`, or read
   `releases/x.y.z/manifest.yml`.

## Manual cut (CI broken or off-schedule)

Same code path CI runs:

```sh
# preview everything first — zero mutations:
GH_TOKEN=$(gh auth token) nix develop --command train cut --dry-run --force

# real cut:
GH_TOKEN=$(gh auth token) nix develop --command train cut --force
```

Notes:
- Run from a checkout of convos-releases `main` (the tool refuses other
  refs in CI; locally, be on main — its pushes go to `main` directly).
- Your git identity/signing applies to the manifest commits when run
  locally; the org-admin ruleset bypass covers the direct push.
- The cut is **idempotent**: re-running after a partial failure reconciles
  toward the manifest (existing branches/PRs at the recorded SHAs are
  skipped, missing pieces are created). A same-day interrupted train is
  resumed automatically; an OLDER train still in `status: cut` blocks new
  cuts loudly — resolve or abandon it first.

## Fully manual cut (train CLI itself unusable)

The essential invariant: **manifest first, app repos second**.

1. Determine the version: both repos' dev must agree
   (`train bump-version read <checkout>` or read
   `android/gradle.properties` / `MARKETING_VERSION` in the pbxproj).
2. In convos-releases: create `releases/x.y.z/manifest.yml` (copy a prior
   train's shape: version, kind: release, cut-date, per-repo source-sha +
   release-branch + status: pending, rc: []), plus `ios.md`, `android.md`,
   `submission-notes.md` (`train seed-notes --repo xmtplabs/convos-ios
   --since <last cut-date>` prints seeded content). Commit + push to main.
3. In each app repo: `git push origin <dev-sha>:refs/heads/release/x.y.z`.
4. Bump dev: branch `bot/bump-<next>` from the same SHA, apply
   `train bump-version bump <checkout> <next>`, commit, push, open a PR to
   dev and merge it.
5. Open the release PRs (`release/x.y.z` → `main`) in both repos.
6. RC uploads then trigger from the branch pushes as normal.

## Manual RC upload (uploader workflows broken)

From the app repo checkout, on the release branch, inside its dev shell:

- Android: `fastlane android play_internal` with `PROD_KEYSTORE_PATH`,
  `PROD_KEYSTORE_PASSWORD`, `PROD_KEY_ALIAS`, `PROD_KEY_PASSWORD`,
  `PLAY_SERVICE_ACCOUNT_JSON_PATH` exported (values from 1Password).
- iOS: `fastlane testflight_prod` with the App Store Connect key trio +
  `MATCH_PASSWORD` + `MATCH_GIT_URL` exported.

Then record the artifact in the manifest yourself:

```sh
GH_TOKEN=$(gh auth token) nix develop --command train append-rc \
  --repo xmtplabs/convos-client --sha <branch-sha> \
  --run <build log URL or "manual"> \
  --key version-code --value <code> --version x.y.z
# iOS: --key build-number --value <CFBundleVersion the lane printed>
```

## Manual store submission (Phase 2 not yet automated)

Use ONLY manifest-recorded artifacts (`train status x.y.z`):

- **Play**: Play Console → org.convos.android → Internal testing →
  promote the recorded versionCode to Production as a DRAFT → paste
  `releases/x.y.z/android.md` (≤500 chars) → human presses
  "Start rollout".
- **App Store**: App Store Connect → new App Store version x.y.z → attach
  the recorded TestFlight build number → paste `releases/x.y.z/ios.md` +
  reviewer notes from `submission-notes.md` → human presses
  "Submit for Review".
- Tag both repos: `git tag vX.Y.Z <merge-commit> && git push origin vX.Y.Z`.

## Abandoning a train

When a cut train must be discarded (bad state, version already shipped,
rehearsal). Battle-tested order:

```sh
# 1. Close the release PRs (never merge them):
gh pr close <n> --repo xmtplabs/convos-ios   --comment "Train abandoned: <reason>"
gh pr close <n> --repo xmtplabs/convos-client --comment "Train abandoned: <reason>"

# 2. Delete the release branches:
gh api -X DELETE repos/xmtplabs/convos-ios/git/refs/heads/release/x.y.z
gh api -X DELETE repos/xmtplabs/convos-client/git/refs/heads/release/x.y.z

# 3. Remove the train's ledger dir from convos-releases main
#    (org-admin bypass required for the direct push):
rm -rf releases/x.y.z && git commit -am "train: tear down x.y.z (<reason>)" && git push
```

Keep vs revert:
- **Keep the dev version bumps** (roll forward) — dev already moved to the
  next version; the next cut uses it. Reverting bumps re-opens the
  closed-TestFlight-train trap.
- Store uploads that already happened are fine: a Play internal release is
  superseded by the next upload; a TestFlight build just sits unused.
  Consumed versionCodes/build numbers are not reusable — never re-cut the
  SAME version after its artifacts uploaded unless you keep the same
  branch SHAs (identical codes re-upload will be rejected loudly).
- Deleting `releases/x.y.z/` (not just editing status) is what allows a
  clean fresh cut of that version later; a manifest left at
  `status: cut` from an earlier date BLOCKS all future cuts by design.

## Skipping a week / changing the cut day

Edit `release-config.yml` on main (web pencil is fine):

```yaml
cut-day: thursday
skip-dates: ["2026-11-26"]   # ISO dates to skip
```

Manual off-schedule cut: `train cut --force` (see above). To cut early in
place of the scheduled one, cut with `--force`, then add that week's
cut-day date to `skip-dates` (a train in `status: branched` doesn't block
the next cut — without the skip entry you'd cut TWO trains that week).

## Troubleshooting (all observed live)

| Symptom | Cause | Fix |
|---|---|---|
| Cut fails: `manifest push ... failed (non-fast-forward? retry the cut)` | main ruleset rejected the push (actor not bypass-listed) or a real race with an append | Ensure `convos-conductor` is in the main ruleset's bypass list; workflow checkout must use `persist-credentials: false` (a persisted GITHUB_TOKEN header overrides the bot token). Races: just re-dispatch. |
| `release/x.y.z exists at <sha>, expected <sha>` | a branch with that name predates the cut (e.g. a manual release branch) | Confirm it's stale with its owner, delete it, re-dispatch (reconcile completes the rest). |
| Bump commit: `Author identity unknown` | bot git identity not configured in a fresh clone | Fixed in the tool (regression-tested); if seen, update the pinned train. |
| `Merge method X is not allowed on this repository` warning | repo forbids that merge method | Tool falls back SQUASH→MERGE→REBASE; if all fail, arm manually: `gh pr merge <n> --auto --merge`. |
| iOS: `No matching provisioning profiles found ... readonly` | a lane requests a bundle id whose profile isn't in convos-certificates (check the match error's "available profiles" list) | Add the id to convos-ios `fastlane/Matchfile`, register the App ID if new (`fastlane produce --skip_itc -a <id>`), run `fastlane ios sync_match type:appstore`. |
| iOS: `Invalid Pre-Release Train ... '<ver>' is closed` | that version already shipped on the App Store | The train's version is stale — abandon it; ensure dev's bump merged; next cut uses the next version. |
| Play: `versionCode already used` | re-uploading a commit whose code was consumed | Push any new commit to the release branch (new timestamp → new code). |
| `train X cut <old-date> is still status:cut` | an older train never completed or was never torn down | Finish it (re-dispatch reconciles) or abandon it per above. |
| Scheduled cut didn't fire | wrong day/skip-date, or both UTC slots outside 15:45 ET | Check `release-config.yml` and the two cron slots; `train cut --force` to cut now. |
| Append step: `manifest append failed after 3 attempts` | push contention on convos-releases main | Re-run the failed workflow (append is idempotent), or run `train append-rc` manually. |
