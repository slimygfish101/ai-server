/**
 * ClaudePC text relay - runs free inside your Google account (script.google.com).
 *
 * 1. Every minute it checks Gmail for Google Voice texts from YOUR phone.
 * 2. "status" or "off" are handled right here. Anything else is queued for the PC,
 *    and the PC is turned on if it's off.
 * 3. The PC picks up the queue, asks Claude, and sends the answer back through here,
 *    which replies to the Google Voice email = a normal text to your phone.
 *
 * Script Properties (Project Settings > Script Properties):
 *   MY_NUMBER              your regular cell number, digits only
 *   AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID
 *                          the same 4 lines the Azure setup printed
 * Then run setup() once.
 */
const VM_PATH = '/resourceGroups/ClaudePC/providers/Microsoft.Compute/virtualMachines/ClaudePC';
const API = '2024-07-01';
const P = () => PropertiesService.getScriptProperties();

function setup() {
  ScriptApp.getProjectTriggers().forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('checkTexts').timeBased().everyMinutes(1).create();
  if (!P().getProperty('PC_SECRET')) P().setProperty('PC_SECRET', Utilities.getUuid().replace(/-/g, '') + Utilities.getUuid().replace(/-/g, ''));
  ['MY_NUMBER', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID']
    .forEach(k => { if (!P().getProperty(k)) Logger.log('MISSING Script Property: ' + k); });
  Logger.log('PC power right now: ' + powerState());
  Logger.log('Setup done. Secret for the PC (2nd line of text-relay.txt): ' + P().getProperty('PC_SECRET'));
}

// ---------- incoming texts ----------
function checkTexts() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(20000)) return;
  try {
    const mine = (P().getProperty('MY_NUMBER') || '').replace(/\D/g, '').slice(-10);
    if (!mine) return;
    const threads = GmailApp.search('from:txt.voice.google.com is:unread newer_than:1d', 0, 20);
    let queued = false;
    threads.forEach(thread => thread.getMessages().forEach(msg => {
      if (!msg.isUnread()) return;
      msg.markRead();
      const from = msg.getFrom().replace(/\D/g, '') + ' ' + msg.getSubject().replace(/\D/g, '');
      if (from.indexOf(mine) === -1) return;            // not from your phone: ignore
      const text = cleanBody(msg.getPlainBody());
      if (!text) return;
      P().setProperty('THREAD_ID', thread.getId());
      const cmd = text.toLowerCase().replace(/[^a-z ]/g, '').trim();
      if (cmd === 'status' || cmd === 'pc status') return sendText('PC is ' + friendly(powerState()) + '.');
      if (cmd === 'off' || cmd === 'pc off') {
        azure('post', '/deallocate');
        return sendText('Turning the PC off.');
      }
      const q = queue();
      q.push({ text: text, at: new Date().toISOString() });
      P().setProperty('QUEUE', JSON.stringify(q));
      queued = true;
    }));
    if (queued) wakePc();
  } finally { lock.releaseLock(); }
}

function cleanBody(body) {
  const out = [];
  for (const line of String(body).split(/\r?\n/)) {
    if (/^(To respond to this text message|YOUR ACCOUNT|HELP CENTER|HELP FORUM)/i.test(line.trim())) break;
    if (/^<?https?:\/\/voice\.google\.com/i.test(line.trim())) continue;
    out.push(line);
  }
  return out.join('\n').trim();
}

function wakePc() {
  const state = powerState();
  if (state === 'running' || state === 'starting') return;
  const last = Number(P().getProperty('STARTED_AT') || 0);
  if (Date.now() - last < 5 * 60 * 1000) return;
  azure('post', '/start');
  P().setProperty('STARTED_AT', String(Date.now()));
  sendText('Turning the PC on. Claude will answer in about 3-5 minutes.');
}

// ---------- the PC talks to this ----------
function doPost(e) {
  let body = {};
  try { body = JSON.parse(e.postData.contents); } catch (err) {}
  if (!body.secret || body.secret !== P().getProperty('PC_SECRET')) return json({ ok: false });
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    if (body.action === 'poll') {
      const q = queue();
      P().setProperty('QUEUE', '[]');
      return json({ ok: true, messages: q });
    }
    if (body.action === 'reply' && body.text) { sendText(String(body.text)); return json({ ok: true }); }
    return json({ ok: false });
  } finally { lock.releaseLock(); }
}

function json(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }
function queue() { try { return JSON.parse(P().getProperty('QUEUE') || '[]'); } catch (e) { return []; } }

// Replying to the Google Voice email sends a normal text to your phone.
function sendText(text) {
  const id = P().getProperty('THREAD_ID');
  if (!id) return;
  const thread = GmailApp.getThreadById(id);
  let rest = String(text).trim();
  for (let i = 0; i < 4 && rest; i++) {
    let part = rest.slice(0, 900);
    rest = rest.slice(900);
    if (i === 3 && rest) part = part.slice(0, 850) + '... (cut short, ask for the rest)';
    thread.reply(part);
  }
}

// ---------- Azure on/off ----------
function azure(method, suffix) {
  const p = P(), cache = CacheService.getScriptCache();
  let token = cache.get('az');
  if (!token) {
    const r = UrlFetchApp.fetch('https://login.microsoftonline.com/' + p.getProperty('AZURE_TENANT_ID') + '/oauth2/v2.0/token', {
      method: 'post',
      payload: {
        grant_type: 'client_credentials',
        client_id: p.getProperty('AZURE_CLIENT_ID'),
        client_secret: p.getProperty('AZURE_CLIENT_SECRET'),
        scope: 'https://management.azure.com/.default'
      }
    });
    token = JSON.parse(r.getContentText()).access_token;
    cache.put('az', token, 3000);
  }
  const url = 'https://management.azure.com/subscriptions/' + p.getProperty('AZURE_SUBSCRIPTION_ID') + VM_PATH + suffix + '?api-version=' + API;
  const opts = { method: method, headers: { Authorization: 'Bearer ' + token }, muteHttpExceptions: true };
  if (method === 'post') { opts.contentType = 'application/json'; opts.payload = '{}'; }
  const r = UrlFetchApp.fetch(url, opts);
  if (r.getResponseCode() >= 300) throw new Error('Azure said ' + r.getResponseCode() + ': ' + r.getContentText().slice(0, 300));
  const t = r.getContentText();
  return t ? JSON.parse(t) : {};
}

function powerState() {
  const s = (azure('get', '/instanceView').statuses || []).map(x => x.code).find(c => c.indexOf('PowerState/') === 0);
  return s ? s.split('/')[1] : 'unknown';
}

function friendly(s) {
  return { running: 'on', deallocated: 'off', deallocating: 'turning off', starting: 'turning on', stopped: 'off (but still billed!)' }[s] || s;
}
