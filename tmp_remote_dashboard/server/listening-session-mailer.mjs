// Email delivery for listening-session invites is intentionally a no-op today.
// The tenant is moving to Microsoft Graph for outbound mail, but that tenant
// setup is not ready yet. This module gives routes a single call site
// (`sendInvite`) to swap in a real Graph-based sender later without touching
// listening-session-routes.mjs: implement `sendViaGraph` and flip the
// `GRAPH_MAIL_CONFIGURED` check once credentials exist.
const GRAPH_MAIL_CONFIGURED = false;

export async function sendInvite({ email, sessionTitle, joinUrl }) {
  if (!GRAPH_MAIL_CONFIGURED) {
    console.warn(
      'listening-session invite email not sent (Microsoft Graph mail not configured yet): ' +
      JSON.stringify({ email, sessionTitle, joinUrl })
    );
    return { delivered: false, reason: 'MAIL_PROVIDER_NOT_CONFIGURED' };
  }

  // Placeholder for the future Graph-based implementation.
  return { delivered: false, reason: 'MAIL_PROVIDER_NOT_CONFIGURED' };
}
