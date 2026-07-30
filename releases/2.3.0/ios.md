## Features
- feat(participation): move the bubble out of the input, hold it until loaded (#1239)
- feat: build-time agent-variant pin for prototype builds (#1216)
- feat(participation): agent participation control in the contact sheet (#1203)

## Fixes
- fix(participation): stop two races between switching and refreshing (#1246)
- fix(participation): key the bubble to the keyboard, not to stored focus (#1241)
- fix(renovate): actually enable the beta nix manager (#1234)
- Fix cold-launch flash of empty-state CTA over existing conversations (#1222)
- fix: align ShareExtension MARKETING_VERSION to 2.2.0 (#1217)
- fix(dev): honour USE_CONFIG for XMTP_CUSTOM_HOST in Local builds (#1211)
- fix: publisher/backfill/merge hardening from the unified-profile review (M1, M3–M8) (#1173)

## Other
- Reach the Listen flag from a production build (#1250)
- Composer: the attachments card is ours, so it stops wearing the system's arrow (#1249)
- Participation store races, glass menus, and attachments inside the input (#1247)
- Make the subscription badge backend-authoritative (#1245)
- Type subscription verify failures and surface a sync attention state (#1244)
- CON-807: agent lost-power surfaces bind to backend owner-computed agentPowerDepleted, not the viewer's wallet (#1243)
- Stop retrying encrypted images that fail deterministically (#1240)
- update nix flake for releases (#1231)
- Time-box and isolate per-conversation prepare in batch catch-up (#1229)
- Denormalize last-message pointers onto conversation, maintained by triggers (#1228)
- Slim the conversation-list last-message CTEs to a grouped MAX (#1224)
- ci: add Version Alignment PR check (#1220)

