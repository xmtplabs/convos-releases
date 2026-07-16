# cut-cron

Cloudflare Worker that dispatches the weekly `release-cut` workflow at
15:45 ET sharp. GitHub's own `schedule:` trigger lags 15–25 minutes; this
worker exists purely for punctuality — every decision (DST slot, cut day,
skip-dates, reconcile) still lives in the `train` CLI.

## Deploy

```sh
cd workers/cut-cron
wrangler deploy
wrangler secret put GITHUB_TOKEN       # fine-grained PAT: convos-releases only, Actions read/write
wrangler secret put SLACK_WEBHOOK_URL  # optional: #app webhook, used ONLY to report dispatch failures
```

Token rotation: mint a new fine-grained PAT with the same scope and
`wrangler secret put GITHUB_TOKEN` again.

## Behavior

- Fires daily at 19:45 and 20:45 UTC (like the old GitHub crons — which
  day acts is release-config.yml's cut-day); passes the matching slot string
  as the workflow's `schedule` input, so `train cut` treats it exactly like
  a scheduled run (skip-dates and cut-day config still apply).
- Dispatch failure (revoked token, GitHub outage) throws — visible in the
  worker's Cloudflare logs — and pings #app when the Slack secret is set.
- Fallback if the worker is down: convos-releases → Actions → Release Cut →
  Run workflow (`force: true` for an off-schedule cut, or no inputs plus the
  `schedule` input to mimic the slot).

The GitHub `schedule:` triggers were REMOVED from release-cut.yml when this
worker took over: a punctual worker cut followed by a lagged GitHub cron cut
would see dev already bumped and cut a second train the same day.
