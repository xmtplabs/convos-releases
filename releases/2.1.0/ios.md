## Features
- feat(onboarding): nametag feedback — instant sheet, single surface, avatar menu, camera crop (#1177)
- feat(agent-builder): log the silent generation/join pipeline failures (#1161)
- feat(onboarding): first-launch profile setup sheet (#1158)
- feat(groups): leave a group (self-removal) + super-admin succession (#1132)

## Fixes
- fix(avatars): show cached group photos instantly on cold launch (#1185)
- fix: create, persist, and resend a join idempotency key on agent-builder invites (#1171)
- Fix main-thread hangs reported by Sentry app-hang monitoring (#1168)
- fix(onboarding): re-offer profile sheet while profile unset; gate swipe dismissal (#1166)
- fix(onboarding): profile sheet header full-bleed under keyboard (#1162)
- fix(scan): route scan navigation through the chats tab from every entry point (#1156)
- fix(scan): stop the invite card double-render during a scan join (#1155)
- fix(invite): follow-up fixes (#1154)
- Fix invite-actions spacing on Contacts tab while suggested agents load (#1150)

## Other
- chore: bump convos-releases to 41eaa61a (store-rendered release notes) (#1190)
- Reconcile: merge main into dev (#1188)
- Promotion caller + conductor merge command (#1184)
- add ShareExtension to Matchfile (#1181)
- Add debug toggle to enable XMTP bidi streaming on next launch (#1176)
- ci: TestFlight RC caller for release trains + train in devshell (#1175)
- Request message history from peers after pairing adoption (#1169)
- Bump convos-releases pin (ShareExtension signing lanes) (#1167)
- Devices screen: iCloud devices section, Main-device designation, delete-all guard (#1163)
- Bump the version to 2.0.6 (#1160)
- Schedule TestFlight prod builds (3x/day, skip-if-stale) (#1157)
- Reinstall continuity: auto-revoke dead installation + restore conversation consent (#1151)
- Consume release tooling from convos-releases (#1147)

