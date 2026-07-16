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

**Contents**

- [The normal week (no action required)](#the-normal-week-no-action-required)
- [Merging the train](#merging-the-train)
- [Promotion (automatic; how to re-run)](#promotion-automatic-how-to-re-run)
- [Hotfix: patching an already-released version](#hotfix-patching-an-already-released-version)
- [Manual cut (CI broken or off-schedule)](#manual-cut-ci-broken-or-off-schedule)
- [Fully manual cut (train CLI itself unusable)](#fully-manual-cut-train-cli-itself-unusable)
- [Manual RC upload (uploader workflows broken)](#manual-rc-upload-uploader-workflows-broken)
- [Manual store submission (promotion broken)](#manual-store-submission-promotion-broken)
- [Abandoning a train](#abandoning-a-train)
- [Skipping a week / changing the cut day](#skipping-a-week--changing-the-cut-day)
- [Troubleshooting](#troubleshooting-all-observed-live-unless-noted)

## The normal week (no action required)

1. **Thursday 15:45 ET** — the `release-cut` workflow cuts `release/x.y.z`
   from both repos' dev tips: manifest + seeded notes committed to
   `releases/x.y.z/` first, then branches, version-bump PRs to dev
   (auto-merged), and release PRs to main. The cut announces itself in
   **#app** with links to the release PRs, the notes, and this runbook.
2. **Every push to `release/x.y.z`** uploads an RC (TestFlight / Play
   internal) and records its artifact identity in the manifest.
3. **Humans edit notes** any time before merge: GitHub web pencil on
   `releases/x.y.z/*.md`. Write markdown — the GitHub Release renders
   it, and promotion renders plain text for the stores (headers →
   `Header:`, bullets → `•`, links → their text). Play caps android
   notes at 500 rendered chars; promotion fails with the count if over.
4. **Go/no-go: comment `@convos-conductor merge`** on either repo's release
   PR — it merges BOTH repos' PRs (see "Merging the train").
5. **Promotion runs automatically on the merge**: tags `vx.y.z`, stages the
   Play production draft and the App Store version (build attached, notes
   filled), creates the GitHub Releases, records `promoted` in the
   manifest, and comments on the PRs.
6. **Humans press the store buttons**: Play Console "Start rollout",
   App Store Connect "Submit for Review". That's the only manual step.
7. Check state at any point: `train status x.y.z`, or read
   `releases/x.y.z/manifest.yml`.

## Merging the train

Comment exactly `@convos-conductor merge` (as the first line) on either
repo's release/hotfix PR. Org members/collaborators only; the tool
re-verifies YOUR write access on every participating repo before merging
anything. It merges every repo in the manifest, refuses any PR whose tip
has no recorded RC ("no RC recorded for tip …" = wait for the upload), and
pins each merge to the tip it verified. Rerun-safe: an already-merged repo
is a no-op.

Merging via the GitHub UI also works (per repo, **merge commit only** —
squash/rebase changes the tree and promotion will refuse it), but you lose
the RC gate until branch protection enforces the checks.

## Promotion (automatic; how to re-run)

Triggered by the release PR's merge commit landing on main. Per repo it:
verifies the merge tree matches the RC'd branch tip, tags `vx.y.z`, stages
the store submission from the manifest-recorded artifact, writes the
`promoted` block to the manifest, creates the GitHub Release (body =
platform notes), and comments on the PR. Everything is ensure-state — a
failed run can be re-run and converges.

To re-run when the original run is gone or never fired: promotion is
per-repo, and the "Promote Release" workflow lives in EACH APP REPO — go
to convos-client and/or convos-ios (every repo the manifest lists) →
Actions → "Promote Release" → Run workflow → enter the version. It only
works for a version whose release/hotfix PR actually merged there (shas
are derived from the merged PR, not taken as input).

Promotion refuses notes that still contain the hotfix seed placeholder —
edit `releases/x.y.z/<platform>.md` on main, then re-run.

## Hotfix: patching an already-released version

Ships a patch on top of the latest release without waiting for the weekly
train. The base tag must be the LATEST `v*` tag on every participating
repo — you can't hotfix an older line.

1. **Cut**: Actions → "Release Cut" → Run workflow with
   `hotfix-base-tag: vx.y.z` (optionally `hotfix-repo: xmtplabs/convos-ios`
   for a single-platform hotfix). Locally:
   `train hotfix --base-tag vx.y.z --dry-run` first, then without.
   This creates `releases/x.y.(z+1)/` (kind: hotfix, template notes) and,
   per repo, a `hotfix/x.y.(z+1)` branch at the tag plus a version-bump
   commit, with a PR to main. No dev bump (dev is already ahead).
2. **Land the fix**: cherry-pick the fix commits onto `hotfix/x.y.(z+1)`
   and push. Every push uploads an RC and records it in the manifest,
   same as a release branch.
3. **Describe the fix**: the seeded notes are a placeholder template —
   pencil-edit `releases/x.y.(z+1)/*.md`. Promotion refuses unedited
   placeholders.
4. **Merge**: `@convos-conductor merge` on the hotfix PR.
5. **Promotion** runs as above, plus: it opens a **back-merge PR**
   `hotfix/x.y.(z+1)` → dev BEFORE recording anything (if that PR can't be
   created, promotion fails rather than losing the fix from dev). Expect a
   version-file conflict on the back-merge — dev is on the next minor;
   resolve it keeping dev's version.
6. **Press the store buttons.**

Rerun-safe: re-dispatching the same hotfix reconciles (manifest kind and
source shas must match; a hotfix branch is verified by ancestry). A
`hotfix/…` branch auto-deleted on merge is restored automatically for the
back-merge.

Sharp edges:
- **Both platforms hotfixing from the same base share the version.** An
  iOS-only hotfix from v2.1.0 claims 2.1.1; a later Android dispatch from
  the same v2.1.0 EXTENDS that train — the manifest gains Android's entry
  and notes, then the normal branch/PR flow runs. Edited notes are never
  clobbered. A moved base tag still fails loudly ("source-sha mismatch").
- **The latest-tag guard is per repo.** After an iOS-only v2.1.1, a
  both-platform hotfix from v2.1.1 fails Android's guard (its latest is
  still v2.1.0). Hotfix per platform from each repo's own latest tag;
  patch levels re-align at the next weekly train.

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
   release-branch + status: pending, rc: []), plus the notes files — seed
   each platform from its own repo:
   `train seed-notes --repo xmtplabs/convos-ios --since <last cut-date> > ios.md`
   and the same with `--repo xmtplabs/convos-client > android.md`
   (`submission-notes.md` starts as a copy of android.md under a reviewer
   header). Commit + push to main.
3. In each app repo: `git push origin <dev-sha>:refs/heads/release/x.y.z`.
4. Bump dev: branch `bot/bump-<next>` from the same SHA, apply
   `train bump-version bump <checkout> <next>`, commit, push, open a PR to
   dev and merge it.
5. Open the release PRs (`release/x.y.z` → `main`) in both repos.
6. RC uploads then trigger from the branch pushes as normal.

## Manual RC upload (uploader workflows broken)

From the app repo checkout, on the release branch, inside its dev shell:

- Android: from the `android/` directory (the Fastfile lives at
  `android/fastlane/`): `fastlane android play_internal` with `PROD_KEYSTORE_PATH`,
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

## Manual store submission (promotion broken)

Normally promotion stages all of this — use these steps only when it's
down. Use ONLY manifest-recorded artifacts (`train status x.y.z`), and
only for repos PRESENT in the manifest — a single-platform hotfix must
never tag or record the unaffected repo.

Per manifest-listed repo, from that repo's checkout on main:

```sh
# validates the RC + trees, tags vx.y.z, stages notes into .train-promote/:
GH_TOKEN=$(gh auth token) nix develop --command train promote prepare \
  --repo xmtplabs/<repo> --version x.y.z \
  --merge-sha <release PR merge commit> --head-sha <release branch tip>
```

- **Play**: Play Console → org.convos.android → Internal testing →
  promote the recorded versionCode to Production as a DRAFT → paste
  `.train-promote/android.store.txt` (the ≤500-char rendering prepare
  staged).
- **App Store**: App Store Connect → new App Store version x.y.z → attach
  the recorded TestFlight build number → paste `.train-promote/ios.store.txt`
  + reviewer notes from `.train-promote/submission.store.txt`.
- Record it (run where prepare ran — the GitHub Release body reads the
  notes prepare staged; also opens the hotfix back-merge PR when the
  manifest is hotfix-kind):

```sh
GH_TOKEN=$(gh auth token) nix develop --command train promote record \
  --repo xmtplabs/<repo> --version x.y.z --tag vx.y.z \
  --key <version-code|build-number> --value <artifact id> \
  --notes-sha <the notes-sha value prepare printed> --run manual
```

- Human presses "Start rollout" / "Submit for Review".

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

Config lives in `release-config.yml` on main (web pencil is fine):

```yaml
cut-day: thursday
skip-dates: ["2026-11-26"]   # ISO dates to skip
```

**Skip a week entirely** (holiday, freeze): add that week's cut-day date
to `skip-dates` BEFORE Thursday 15:45 ET. Nothing else — the scheduled
run sees the skip and exits.

**Move the cut EARLIER that week** (e.g. Wednesday, because Thursday is
a holiday):

1. On the day you want it, dispatch Actions → "Release Cut" → Run
   workflow with `force: true` (or locally `train cut --force`).
2. THEN add the skipped Thursday's date to `skip-dates`. Without it the
   scheduled run cuts a SECOND train that week (a `status: branched`
   train doesn't block the next cut).

**Move the cut LATER that week** (e.g. Friday): same two steps, opposite
order — add Thursday's date to `skip-dates` FIRST (before 15:45 ET), then
force-dispatch on Friday. Whichever day the schedule could still fire on
must be skipped before it arrives.

**Change the day permanently**: edit `cut-day`. The two cron slots in
`release-cut.yml` fire daily — the config decides which day acts — so no
workflow edit is needed.

Everything downstream is day-agnostic: RCs, merge, and promotion key off
the manifest, not the calendar.

## Troubleshooting (all observed live unless noted)

| Symptom | Cause | Fix |
|---|---|---|
| Cut fails: `manifest push ... failed (non-fast-forward? retry the cut)` | main ruleset rejected the push (actor not bypass-listed) or a real race with an append | Ensure `convos-conductor` is in the main ruleset's bypass list; workflow checkout must use `persist-credentials: false` (a persisted GITHUB_TOKEN header overrides the bot token). Races: just re-dispatch. |
| `release/x.y.z exists at <sha>, expected <sha>` | a branch with that name predates the cut (e.g. a manual release branch) | Confirm it's stale with its owner, delete it, re-dispatch (reconcile completes the rest). |
| Merge: `no RC recorded for tip <sha>` | the tip's RC upload is still running or failed | Wait for / re-run the RC upload, then comment the merge command again. |
| Merge: `<user> lacks write on <repo>` | commenter lacks push access on one participating repo | Someone with write on BOTH repos comments instead. |
| Promotion: `merge tree differs from RC'd branch tip` | squash/rebase merge, or main had commits dev didn't | Merge trains with a MERGE COMMIT; reconcile main→dev before merging. |
| Promotion: `android release notes render to N chars (Play limit 500)` | android.md too long once rendered | Nothing was tagged or staged — the gate runs before any mutation. Pencil-edit `releases/x.y.z/android.md` on main to shorten (check the rendered length: `train` renders headers/bullets/links to plain text), then convos-client → Actions → "Promote Release" → Run workflow with the version. iOS promotion is independent and unaffected. |
| Promotion: `still contains the seeded placeholder` | hotfix notes never edited | Pencil-edit `releases/x.y.z/*.md` on main, re-run promotion (dispatch with the version). |
| Promotion run failed midway / never fired | transient error, or the caller workflows landed after the merge | Re-run the failed run, or Actions → "Promote Release" → dispatch with the version — everything converges. |
| Promote queued run disappeared | a third run entered the shared store concurrency group (GitHub cancels the pending slot) | Dispatch "Promote Release" with the version. (not yet observed) |
| Hotfix: `<tag> is not the latest tag on <repo>` | trying to hotfix an old release line | Only the latest release can be hotfixed; ship a normal train instead. |
| Back-merge PR conflicts | expected: dev is on the next minor, both touched version files | Resolve on the back-merge PR keeping DEV's version. |
| Bump commit: `Author identity unknown` | bot git identity not configured in a fresh clone | Fixed in the tool (regression-tested); if seen, update the pinned train. |
| `Merge method X is not allowed on this repository` warning | repo forbids that merge method | Tool falls back SQUASH→MERGE→REBASE; if all fail, arm manually: `gh pr merge <n> --auto --merge`. |
| iOS: `No matching provisioning profiles found ... readonly` | a lane requests a bundle id whose profile isn't in convos-certificates (check the match error's "available profiles" list) | Add the id to convos-ios `fastlane/Matchfile`, register the App ID if new (`fastlane produce --skip_itc -a <id>`), run `fastlane ios sync_match type:appstore`. |
| iOS: `Invalid Pre-Release Train ... '<ver>' is closed` | that version already shipped on the App Store | The train's version is stale — abandon it; ensure dev's bump merged; next cut uses the next version. |
| Play: `versionCode already used` | re-uploading a commit whose code was consumed | Push any new commit to the release branch (new timestamp → new code). |
| `train X cut <old-date> is still status:cut` | an older train never completed or was never torn down | Finish it (re-dispatch reconciles) or abandon it per above. |
| Scheduled cut didn't fire | wrong day/skip-date, or both UTC slots outside 15:45 ET | Check `release-config.yml` and the two cron slots; `train cut --force` to cut now. |
| Cut succeeded but no #app announcement | `SLACK_WEBHOOK_APP` secret missing/rotated, or Slack outage (the cut run's log shows the skip note or warning) | Fix the secret for next time; announce manually — do NOT re-run a completed cut just for Slack. (not yet observed) |
| Append step: `manifest append failed after 3 attempts` | push contention on convos-releases main | Re-run the failed workflow (append is idempotent), or run `train append-rc` manually. |
