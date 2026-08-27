# Submission notes for 2.6.0

_For app reviewers: summarize user-visible changes, test-account hints._

## Features
- feat: block agent DM composer while agent is paused (iOS #1404 parity) (#193)
- feat: add agent model picker to contact detail (#188)
- feat(abilities): let the prod Developer menu toggle Abilities v2 (#187)
- feat(connections): googledocs capability card + gmail seed parity with iOS (#179)

## Fixes
- fix: agent DM transcript hidden behind top chrome when keyboard opens (#196)
- fix: update sdk versions in nix config (#195)
- Fix empty state to account for synthetic membership updates (#190)
- fix(capabilities): add the Gmail brand icon to the connect pill and sheet (#183)
- fix(invite): make the in-conversation Show an invite code button work (#180)

## Other
- Agent composer Connections entry, chat-scoped browser, and agent grant-ledger announcements (#198)
- Make Connections v2 unconditional and remove isAbilitiesV2Enabled flag (#197)
- chore(renovate): sort the unified pre.* prerelease timeline (#194)
- chore: bump target api and billings sdk api, address console warnings (#192)
- chore(deps): update convos-releases flake input to 9d84268 (#191)
- Mpr/port ios 1393 1401 (#189)
- Replace chat drawer with tab-based conversation navigation (#184)

