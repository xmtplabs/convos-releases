## Fixes
- fix: align ShareExtension MARKETING_VERSION to 2.2.0 (#1217)
- fix: restore agent files and links in Files & Links and Things (#1207)
- fix: Dev-configuration compile errors blocking the dev TestFlight release (#1206)
- fix: move view-model initial DB reads off the main thread (CONVOS-IOS-4A) (#1199)
- fix: mask attachment chips inside the agent builder summary card (#1194)
- fix(connections): attest capability-request sender against XMTP envelope (#1189)
- fix: publisher/backfill/merge hardening from the unified-profile review (M1, M3–M8) (#1173)

## Other
- Show the draft agent's name and emoji in the chat header while it activates (#1212)
- ci: migrate prod TestFlight callers to the generic ios-testflight workflow (#1210)
- chore: remove Bitrise config, fully replaced by GitHub Actions + fastlane (#1209)
- ci: bump convos-releases flake input for the testflight_dev lane (#1205)
- ci: dev TestFlight release on every push to dev (replaces Bitrise) (#1204)
- Share extension: conversation picker for targetless shares (#1197)
- ci: RC uploads only for numeric train branches (#1196)
- ci: skip automatic Claude review on train-authored PRs (#1195)
- docs: delete-my-account plan (iOS deletion state machine + wipe manifest) (#1165)
- Share extension: iMessage-style sharing + agent builder for targetless shares (#1027)

