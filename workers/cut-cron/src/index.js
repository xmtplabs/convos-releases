// Punctual replacement for GitHub's scheduled-workflow trigger, which lags
// 15-25 minutes. Fires release-cut.yml via workflow_dispatch the second the
// cron hits; ALL policy (DST slot, cut-day, skip-dates, reconcile) stays in
// the train CLI — this worker only supplies punctuality.
export default {
  async scheduled(event, env, ctx) {
    // Two UTC crons cover 15:45 America/New_York across DST, mirroring the
    // slot strings train's slot decision expects; it keeps exactly one.
    const slot = event.cron.startsWith("45 19") ? "45 19 * * *" : "45 20 * * *";

    try {
      const res = await fetch(
        "https://api.github.com/repos/xmtplabs/convos-releases/actions/workflows/release-cut.yml/dispatches",
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${env.GITHUB_TOKEN}`,
            Accept: "application/vnd.github+json",
            "User-Agent": "convos-cut-cron",
            "X-GitHub-Api-Version": "2022-11-28",
          },
          body: JSON.stringify({ ref: "main", inputs: { schedule: slot } }),
        },
      );

      if (res.status !== 204) {
        const body = (await res.text()).slice(0, 300);
        throw new Error(`HTTP ${res.status} ${body}`);
      }
    } catch (err) {
      // Covers non-204 responses AND transport failures (DNS, TLS, timeouts)
      // — every path where the cut was not dispatched alerts, then rethrows
      // so the failure is also visible in Cloudflare's logs.
      ctx.waitUntil(alertSlack(env, err));
      throw new Error(`release-cut dispatch failed: ${err.message}`);
    }
  },
};

async function alertSlack(env, err) {
  if (!env.SLACK_WEBHOOK_URL) return;

  try {
    await fetch(env.SLACK_WEBHOOK_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        text: `⚠️ release-cut dispatch failed: ${err.message}\nFallback: convos-releases → Actions → Release Cut → Run workflow.`,
      }),
    });
  } catch {
    // Slack being down too is only visible in the worker logs.
  }
}
