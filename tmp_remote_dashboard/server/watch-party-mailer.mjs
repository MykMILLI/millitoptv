// SMTP delivery for watch party invites. Settings come from the dashboard
// (Watch parties > Email); the password is stored encrypted.

const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

export function composeInvite({ hostName, partyTitle, nowPlaying, joinUrl, code, note }) {
  const subject = `${hostName} invited you to watch together on MILLITOP TV`;
  const watching = nowPlaying ? `Now playing: ${nowPlaying}` : 'The host will start something shortly.';
  const text = [
    `${hostName} started a watch party: ${partyTitle}`,
    watching,
    note ? `\n"${note}"\n` : '',
    `Join in your browser: ${joinUrl}`,
    `Party code: ${code}`,
    '',
    'You can chat and talk with everyone while you watch. Use headphones to avoid echo.',
    'If you did not expect this email, you can ignore it.'
  ].filter(line => line !== '').join('\n');
  const html = `<!doctype html><html><body style="margin:0;background:#0b1422;font-family:Segoe UI,Arial,sans-serif;color:#e8eef7">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="padding:32px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#111e30;border:1px solid #263952;border-radius:16px">
<tr><td style="padding:28px">
<p style="margin:0 0 6px;font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:#7fb3ff">MILLITOP TV watch party</p>
<h1 style="margin:0 0 12px;font-size:22px;line-height:1.3;color:#fff">${escapeHtml(hostName)} invited you to watch together</h1>
<p style="margin:0 0 6px;font-size:16px;color:#fff">${escapeHtml(partyTitle)}</p>
<p style="margin:0 0 18px;font-size:14px;color:#b7c4d6">${escapeHtml(watching)}</p>
${note ? `<p style="margin:0 0 18px;padding:12px 14px;border-left:3px solid #4d8dff;background:#0d1828;font-size:14px;color:#dfe7f2">${escapeHtml(note)}</p>` : ''}
<p style="margin:0 0 22px"><a href="${escapeHtml(joinUrl)}" style="display:inline-block;background:#3b82f6;color:#fff;text-decoration:none;font-weight:600;padding:12px 22px;border-radius:10px">Join the watch party</a></p>
<p style="margin:0 0 4px;font-size:13px;color:#b7c4d6">Party code: <strong style="color:#fff;letter-spacing:.12em">${escapeHtml(code)}</strong></p>
<p style="margin:0;font-size:12px;color:#8b9ab0">Chat and voice work right in your browser. Use headphones to avoid echo. If you did not expect this email, ignore it.</p>
</td></tr></table></td></tr></table></body></html>`;
  return { subject, text, html };
}

export class WatchPartyMailer {
  constructor({ loadSmtp, importNodemailer = () => import('nodemailer') }) {
    this.loadSmtp = loadSmtp;
    this.importNodemailer = importNodemailer;
  }

  async transport() {
    const settings = await this.loadSmtp();
    if (!settings || !settings.enabled || !settings.host) {
      return { error: 'Email is not set up yet. An administrator can add SMTP details in the dashboard under Watch parties.' };
    }
    let nodemailer;
    try {
      nodemailer = (await this.importNodemailer()).default;
    } catch {
      return { error: 'The email library is not installed on the server (nodemailer).' };
    }
    const transporter = nodemailer.createTransport({
      host: settings.host,
      port: settings.port,
      secure: settings.security === 'ssl',
      requireTLS: settings.security === 'starttls',
      ignoreTLS: settings.security === 'none',
      auth: settings.username ? { user: settings.username, pass: settings.password ?? '' } : undefined,
      connectionTimeout: 15000,
      greetingTimeout: 15000,
      socketTimeout: 30000
    });
    return { transporter, settings };
  }

  async send({ to, subject, text, html }) {
    const { transporter, settings, error } = await this.transport();
    if (error) return { delivered: false, error };
    try {
      const info = await transporter.sendMail({
        from: { name: settings.fromName || 'MILLITOP TV', address: settings.fromEmail },
        replyTo: settings.replyTo || undefined,
        to,
        subject,
        text,
        html
      });
      return { delivered: true, messageId: info.messageId ?? null };
    } catch (failure) {
      return { delivered: false, error: describeSmtpError(failure) };
    } finally {
      transporter.close?.();
    }
  }

  async verify() {
    const { transporter, error } = await this.transport();
    if (error) return { ok: false, error };
    try {
      await transporter.verify();
      return { ok: true };
    } catch (failure) {
      return { ok: false, error: describeSmtpError(failure) };
    } finally {
      transporter.close?.();
    }
  }
}

export function describeSmtpError(error) {
  const code = String(error?.code ?? '');
  const response = String(error?.response ?? '').slice(0, 200);
  if (code === 'EAUTH') return `The SMTP server rejected the username or password.${response ? ` (${response})` : ''}`;
  if (code === 'ECONNECTION' || code === 'ESOCKET' || code === 'ETIMEDOUT' || code === 'ECONNREFUSED') {
    return 'Could not connect to the SMTP server. Check the server name, port and security mode.';
  }
  if (code === 'EENVELOPE') return `The SMTP server refused the sender or recipient.${response ? ` (${response})` : ''}`;
  if (code === 'EDNS') return 'The SMTP server name could not be found.';
  return `Email could not be sent${code ? ` (${code})` : ''}.${response ? ` ${response}` : ''}`;
}
