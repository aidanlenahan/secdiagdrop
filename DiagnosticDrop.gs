/**
 * DiagnosticDrop.gs  -  password-gated Drive drop + email approval broker
 *
 * The field script prompts for a password YOU remember. It sends the password
 * to this web app, which checks it against a stored SHA-256 hash and RATE
 * LIMITS attempts. A memorable password is safe here precisely because the
 * server locks out after a few wrong tries - brute force is not viable.
 *
 * Nothing is saved to Drive on upload. You get an email with Approve/Deny +
 * the device's IP/MAC/location. Only when you Approve is the file written.
 *
 * SETUP
 *  1. Drive -> New -> Folder. Copy the id from its URL -> FOLDER_ID.
 *  2. Choose a password you'll remember. Get its SHA-256 hash (lowercase hex):
 *       - PowerShell:
 *           $s=Read-Host -AsSecureString 'password'
 *           $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
 *           $p=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
 *           -join ([Security.Cryptography.SHA256]::Create().
 *             ComputeHash([Text.Encoding]::UTF8.GetBytes($p))|%{$_.ToString('x2')})
 *       - or any "sha256 hex" tool.
 *     Paste the 64-char hash into PASS_HASH below. The password itself is
 *     never stored anywhere.
 *  3. YOUR_EMAIL for the approval email.
 *  4. script.google.com -> New project -> paste -> Save.
 *  5. Deploy -> New deployment -> Web app; Execute as: Me; Access: Anyone.
 *     Copy the /exec URL into the PS $Config.UploadEndpoint.
 *  6. Re-deploy a NEW VERSION after any edit.
 *
 * Optional: point a memorable redirect (aidanlenahan.com/fradiag) at the /exec
 * URL for humans. The script still uses the real /exec URL directly.
 */


// secrets; change these here
const FOLDER_ID  = 'your_folder_id_here';
const PASS_HASH  = 'your_password_hash_here';   // 64 lowercase hex chars
const YOUR_EMAIL = 'your_gmail_address_here';

const MAX_TRIES   = 5;        // wrong attempts allowed...
const WINDOW_SEC  = 300;      // ...per this many seconds, then lockout

function store_() { return PropertiesService.getScriptProperties(); }
function json_(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }
function page_(m) { return HtmlService.createHtmlOutput('<div style="font-family:Segoe UI,Arial;padding:40px;text-align:center"><h2>'+m+'</h2><p>You can close this tab.</p></div>'); }
function esc_(s) { return String(s==null?'':s).replace(/[<>&]/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;'}[c])); }

// Returns the mm-dd-yyyy subfolder inside the root folder, creating it only if
// it does not already exist (reuses it for all runs on the same day).
function getDatedFolder_(rootId) {
  const root = DriveApp.getFolderById(rootId);
  const tz = Session.getScriptTimeZone() || 'America/New_York';
  const name = Utilities.formatDate(new Date(), tz, 'MM-dd-yyyy');
  const existing = root.getFoldersByName(name);
  return existing.hasNext() ? existing.next() : root.createFolder(name);
}

function sha256hex_(s) {
  const bytes = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, s, Utilities.Charset.UTF_8);
  return bytes.map(b => ('0' + (b & 0xff).toString(16)).slice(-2)).join('');
}

/** Constant-time-ish compare and rate limit. Returns true if allowed. */
function passOk_(pw) {
  const now = Math.floor(Date.now() / 1000);
  const gateRaw = store_().getProperty('gate');
  let gate = gateRaw ? JSON.parse(gateRaw) : { count: 0, start: now };
  if (now - gate.start > WINDOW_SEC) gate = { count: 0, start: now };   // window reset
  if (gate.count >= MAX_TRIES) return { ok: false, locked: true };

  const ok = (typeof pw === 'string') && (sha256hex_(pw) === PASS_HASH);
  if (!ok) {
    gate.count += 1;
    store_().setProperty('gate', JSON.stringify(gate));
    return { ok: false, locked: false, remaining: Math.max(0, MAX_TRIES - gate.count) };
  }
  store_().deleteProperty('gate');   // success clears the counter
  return { ok: true };
}

function doPost(e) {
  try {
    const b = JSON.parse(e.postData.contents);
    const gate = passOk_(b.password);
    if (!gate.ok) return json_({ ok:false, error: gate.locked ? 'locked out, try later' : 'bad password', remaining: gate.remaining });

    if (b.action === 'request') {
      const id = b.id || Utilities.getUuid();
      store_().setProperty('req_'+id, JSON.stringify({
        status:'pending', filename: b.filename || ('diag-'+id+'.md'), content: b.content || '',
        meta:{ computer:b.computer, location:b.location, hostname:b.hostname, publicIP:b.publicIP,
               localIPs:b.localIPs, macs:b.macs, geo:b.geo, technician:b.technician },
        created: new Date().toISOString()
      }));
      notify_(id, b);
      return json_({ ok:true, id:id, status:'pending' });
    }
    if (b.action === 'status') {
      const raw = store_().getProperty('req_'+b.id);
      if (!raw) return json_({ ok:false, error:'not found' });
      const rec = JSON.parse(raw);
      return json_({ ok:true, status:rec.status, url:rec.url || '' });
    }
    return json_({ ok:false, error:'unknown action' });
  } catch (err) { return json_({ ok:false, error:String(err) }); }
}

/**
 * GET is used ONLY for the approve/deny links you tap from the email, and for
 * a no-secret ping. Approve/deny carry a per-request one-time key (not your
 * password), so tapping a link never exposes the password.
 */
function doGet(e) {
  if (e.parameter.action === 'ping') return json_({ ok:true, alive:true });

  const id = e.parameter.id, key = e.parameter.key, decision = e.parameter.decision;
  if (!decision) return json_({ ok:true });
  const raw = store_().getProperty('req_'+id);
  if (!raw) return page_('Request not found or expired.');
  const rec = JSON.parse(raw);
  if (key !== rec.key) return page_('Invalid link.');

  if (decision === 'approve') {
    if (rec.status === 'pending') {
      const file = getDatedFolder_(FOLDER_ID).createFile(rec.filename, rec.content, MimeType.PLAIN_TEXT);
      rec.status = 'approved'; rec.url = file.getUrl();
      store_().setProperty('req_'+id, JSON.stringify(rec));
    }
    return page_('Approved. File saved to your Drive.');
  }
  if (decision === 'deny') {
    rec.status = 'denied'; store_().setProperty('req_'+id, JSON.stringify(rec));
    return page_('Denied. Nothing was saved.');
  }
  return page_('Unknown action.');
}

function notify_(id, b) {
  // one-time key for the email links, so the approve/deny URLs never carry the password
  const key = Utilities.getUuid().replace(/-/g,'').slice(0,16);
  const raw = store_().getProperty('req_'+id);
  const rec = JSON.parse(raw); rec.key = key; store_().setProperty('req_'+id, JSON.stringify(rec));

  const base = ScriptApp.getService().getUrl();
  const approve = base + '?id='+id+'&key='+key+'&decision=approve';
  const deny    = base + '?id='+id+'&key='+key+'&decision=deny';
  const html =
    '<p><b>Approve diagnostic upload?</b></p><ul>' +
    '<li>Computer: '+esc_(b.computer)+'</li>' +
    '<li>Location: '+esc_(b.location)+'</li>' +
    '<li>Hostname: '+esc_(b.hostname)+'</li>' +
    '<li>Public IP: '+esc_(b.publicIP)+'</li>' +
    '<li>Local IPs: '+esc_(b.localIPs)+'</li>' +
    '<li>MAC: '+esc_(b.macs)+'</li>' +
    '<li>Geo: '+esc_(b.geo)+'</li>' +
    '<li>Technician: '+esc_(b.technician)+'</li></ul>' +
    '<p><a href="'+approve+'" style="background:#0b8;color:#fff;padding:10px 18px;text-decoration:none;border-radius:6px">APPROVE</a>&nbsp;&nbsp;' +
    '<a href="'+deny+'" style="background:#c33;color:#fff;padding:10px 18px;text-decoration:none;border-radius:6px">DENY</a></p>';
  MailApp.sendEmail({ to: YOUR_EMAIL, subject: 'Approve diagnostic upload - '+esc_(b.computer), htmlBody: html });
}

function cleanup() {
  const props = store_().getProperties(), cutoff = Date.now() - 864e5;
  Object.keys(props).forEach(k => { if (k.indexOf('req_')===0) {
    try { if (new Date(JSON.parse(props[k]).created).getTime() < cutoff) store_().deleteProperty(k); }
    catch (e) { store_().deleteProperty(k); } } });
}
