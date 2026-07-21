# Submission notes for 2.1.0

For app reviewers: this release adds a first-launch profile setup step and a one-tap way to leave a group, plus stability fixes. No test account is required — every flow below is reachable from a fresh install.

## What's new
- First-launch profile setup: on first launch, a "Hello / My name is" sheet asks for a name and photo before you enter the app. It can also be reopened anytime from Settings > My info to edit your name or photo.
- Leave a group: open any group's Info screen and tap Leave to remove yourself from the group in one step, with an immediate confirmation prompt. If you are the group's only super admin, the admin role is automatically handed to another member first so the group keeps an admin.

## Fixes
- Agent contacts no longer appear duplicated in the contacts list.
- Retried invites to add an agent to a conversation now correctly resume the in-flight invite instead of creating a duplicate agent.
- Minor contacts-screen cleanup (removed a stray "Skip" button, fixed list scrolling).

## How to test
- Reinstall (or use a fresh device/simulator) to see the profile setup sheet appear automatically on first launch; type a name and/or add a photo, then tap "Come in." Re-launching before saving should show the sheet again.
- To edit later, go to Settings > My info and tap the pencil next to your name/photo.
- Create or join a group with at least one other member, open Group Info, and tap Leave to confirm the group is removed from your conversation list.