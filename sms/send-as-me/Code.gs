/**
 * ClaudePC "send as me" helper (Google Apps Script, runs in your own Google account).
 *
 * Google Voice only accepts email replies sent from the Gmail that owns the Google Voice
 * number. This script lets ClaudePC send exactly those replies from your Gmail and nothing
 * else: it can only SEND (it cannot read your mail), only to Google Voice reply addresses,
 * and only into the conversation with your approved cell number.
 *
 * Setup (once, in script.google.com while signed in to the Gmail that owns Google Voice):
 *   1. New project, paste this file, save.
 *   2. Project Settings > Script properties: add ALLOWED_NUMBER = your cell, 10 digits.
 *   3. Run setup() once and allow it; the log shows the secret.
 *   4. Deploy > New deployment > Web app: Execute as "Me", Who has access "Anyone".
 *   5. Put the web app URL and the secret into config.ini on ClaudePC (never in a chat).
 */

function doPost(e) {
  var props = PropertiesService.getScriptProperties();
  var secret = props.getProperty('SECRET');
  var allowed = (props.getProperty('ALLOWED_NUMBER') || '').replace(/\D/g, '').slice(-10);
  var d;
  try {
    d = JSON.parse(e.postData.contents);
  } catch (err) {
    return reply({ ok: false, error: 'bad request' });
  }
  if (!secret || d.secret !== secret) return reply({ ok: false, error: 'bad secret' });
  if (d.ping) return reply({ ok: true, left: MailApp.getRemainingDailyQuota() });

  var to = String(d.to || '').toLowerCase();
  if (!/^[0-9a-z._+\-]+@txt\.voice\.google\.com$/.test(to)) {
    return reply({ ok: false, error: 'only Google Voice reply addresses' });
  }
  // The address looks like 1<your GV number>.1<their number>.<token>@txt.voice.google.com
  if (allowed.length !== 10 || to.indexOf('.1' + allowed + '.') === -1) {
    return reply({ ok: false, error: 'not the approved number' });
  }
  MailApp.sendEmail({
    to: to,
    subject: String(d.subject || 'Re: text').slice(0, 200),
    body: String(d.body || '').slice(0, 2000)
  });
  return reply({ ok: true, left: MailApp.getRemainingDailyQuota() });
}

function reply(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

/** Run once: makes the secret ClaudePC uses, and asks Google for permission to send mail. */
function setup() {
  var props = PropertiesService.getScriptProperties();
  var secret = props.getProperty('SECRET');
  if (!secret) {
    secret = Utilities.getUuid().replace(/-/g, '') + Utilities.getUuid().replace(/-/g, '');
    props.setProperty('SECRET', secret);
  }
  Logger.log('Emails left today: ' + MailApp.getRemainingDailyQuota());
  Logger.log('Secret (type it into config.ini on ClaudePC only): ' + secret);
}
