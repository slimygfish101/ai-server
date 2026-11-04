"""End-to-end test of sms_relay.py with a fake Gmail (IMAP+SMTP) and a fake Claude."""
import os, sys, socket, threading, time, json, re, tempfile, stat
from email.message import EmailMessage
from email.utils import make_msgid

TMP = tempfile.mkdtemp()
MY = "7185551234"
GV = "3475550000"
IMAP_PORT, SMTP_PORT = 18143, 18025

# ---------------- fake IMAP with IDLE ----------------
class Box:
    def __init__(self):
        self.msgs = []  # [uid, raw, seen]
        self.cv = threading.Condition()
    def add(self, raw):
        with self.cv:
            self.msgs.append([len(self.msgs) + 1, raw, False])
            self.cv.notify_all()
BOX = Box()

def imap_client(conn):
    f = conn.makefile("rb")
    def send(b):
        conn.sendall(b if isinstance(b, bytes) else b.encode())
    send("* OK fake ready\r\n")
    while True:
        line = f.readline()
        if not line:
            return
        parts = line.decode().strip().split(" ")
        tag, cmd = parts[0], parts[1].upper()
        rest = parts[2:]
        if cmd == "CAPABILITY":
            send("* CAPABILITY IMAP4rev1 IDLE\r\n" + f"{tag} OK done\r\n")
        elif cmd == "LOGIN":
            send(f"{tag} OK logged in\r\n")
        elif cmd == "SELECT":
            send(f"* {len(BOX.msgs)} EXISTS\r\n{tag} OK [READ-WRITE] selected\r\n")
        elif cmd in ("NOOP", "LOGOUT"):
            send(f"{tag} OK done\r\n")
            if cmd == "LOGOUT":
                return
        elif cmd == "UID" and rest[0].upper() == "SEARCH":
            u = [str(m[0]) for m in BOX.msgs if not m[2] and b"txt.voice.google.com" in m[1]]
            send(f"* SEARCH {' '.join(u)}\r\n{tag} OK done\r\n")
        elif cmd == "UID" and rest[0].upper() == "FETCH":
            m = BOX.msgs[int(rest[1]) - 1]
            send(f"* {m[0]} FETCH (UID {m[0]} BODY[] {{{len(m[1])}}}\r\n".encode() + m[1] + b")\r\n" + f"{tag} OK done\r\n".encode())
        elif cmd == "UID" and rest[0].upper() == "STORE":
            BOX.msgs[int(rest[1]) - 1][2] = True
            send(f"{tag} OK done\r\n")
        elif cmd == "IDLE":
            send("+ idling\r\n")
            n0 = len(BOX.msgs)
            done = threading.Event()
            def waiter():
                with BOX.cv:
                    while len(BOX.msgs) == n0 and not done.is_set():
                        BOX.cv.wait(0.2)
                if not done.is_set():
                    send(f"* {len(BOX.msgs)} EXISTS\r\n")
            th = threading.Thread(target=waiter, daemon=True); th.start()
            l2 = f.readline()  # DONE
            done.set(); th.join()
            send(f"{tag} OK IDLE terminated\r\n")
        else:
            send(f"{tag} BAD unknown\r\n")

def imap_server():
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", IMAP_PORT)); s.listen(5)
    while True:
        c, _ = s.accept()
        threading.Thread(target=imap_client, args=(c,), daemon=True).start()

# ---------------- fake SMTP ----------------
SENT = []
from aiosmtpd.controller import Controller
class H:
    async def handle_DATA(self, server, session, envelope):
        import email
        m = email.message_from_bytes(envelope.content)
        SENT.append((envelope.rcpt_tos[0], m.get_payload(decode=True).decode().strip(), time.time()))
        return "250 OK"

# ---------------- fake claude ----------------
claude = os.path.join(TMP, "fakeclaude")
with open(claude, "w") as f:
    f.write(f"""#!{sys.executable}
import sys, json, time
args = sys.argv[1:]
prompt = sys.stdin.read()
sid = args[args.index('--resume')+1] if '--resume' in args else 'sess-new'
if prompt.startswith('LONG'):
    out = ' '.join(f'word{{i}}' for i in range(900))
elif prompt.startswith('SLOW'):
    time.sleep(30); out = 'slow done'
else:
    out = f'Echo [{{sid}}]: ' + prompt
print(json.dumps({{"type":"result","subtype":"success","is_error":False,"result":out,"session_id":"sess-1"}}))
""")
os.chmod(claude, os.stat(claude).st_mode | stat.S_IEXEC)

cfg = os.path.join(TMP, "config.ini")
with open(cfg, "w") as f:
    f.write(f"""[relay]
gmail_address = claudepc@example.com
gmail_app_password = -
my_cell_number = (718) 555-1234
imap_host = 127.0.0.1
imap_port = {IMAP_PORT}
imap_ssl = false
smtp_host = 127.0.0.1
smtp_port = {SMTP_PORT}
smtp_ssl = false
claude_command = {claude}
chat_folder = {TMP}/chat
chars_per_text = 300
max_texts_per_reply = 3
require_google_signature = false
""")
os.environ.update(SMS_RELAY_CONFIG=cfg, SMS_RELAY_STATE=f"{TMP}/state.json", SMS_RELAY_LOG=f"{TMP}/relay.log")

def gv_mail(sender, text):
    m = EmailMessage()
    m["From"] = f'"(718) 555-1234" <1{GV}.1{sender}.AbCdEf123@txt.voice.google.com>'
    m["To"] = "claudepc@example.com"
    m["Subject"] = f"New text message from {sender}"
    m["Message-ID"] = make_msgid()
    m.set_content(f"<https://voice.google.com>\n{text}\nYOUR ACCOUNT <https://voice.google.com> HELP CENTER <https://support.google.com/voice#topic=1707989>\nTo respond to this text message, reply to this email or visit Google Voice\n<https://voice.google.com>.\nYou received this message because...\n")
    return bytes(m)

def wait_sent(n, timeout=15):
    t = time.time()
    while len(SENT) < n and time.time() - t < timeout:
        time.sleep(0.05)
    return SENT[:]

results = []
def check(name, cond, info=""):
    results.append(cond); print(("PASS " if cond else "FAIL ") + name, info if not cond else "")

if __name__ == "__main__":
    threading.Thread(target=imap_server, daemon=True).start()
    Controller(H(), hostname="127.0.0.1", port=SMTP_PORT).start()
    BOX.add(gv_mail(MY, "old text before install"))  # should be skipped on first run
    time.sleep(0.3)
    sys.path.insert(0, sys.argv[1])
    import sms_relay
    sms_relay.setup_logging(True)
    rcfg = sms_relay.load_config()

    def signed_with(ar):
        m = EmailMessage(); m["Authentication-Results"] = ar; m.set_content("x")
        return sms_relay.google_signed(m)
    check("signature: real Google DKIM accepted",
          signed_with("mx.google.com; dkim=pass header.i=@txt.voice.google.com header.s=20230601 header.b=abc; spf=pass"))
    check("signature: missing rejected", not sms_relay.google_signed(EmailMessage()))
    check("signature: look-alike domain rejected",
          not signed_with("mx.google.com; dkim=pass header.i=@txt.voice.google.com.evil.example header.s=x"))
    check("signature: other server's header rejected",
          not signed_with("evil.example; dkim=pass header.i=@txt.voice.google.com"))
    real = (b'Authentication-Results: mx.google.com;\r\n       dkim=pass header.i=@google.com header.s=20260707 header.b=UrQxhSLf;\r\n'
            b'       spf=pass (google.com: domain of x@grandcentral.bounces.google.com designates 209.85.220.73 as permitted sender);\r\n'
            b'       dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=google.com\r\n'
            b'Message-ID: <+15550001111.abc@txt.voice.google.com>\r\nSubject: New text message from (718) 555-1234\r\n'
            b'From: "(718) 555-1234" <15550001111.17185551234.VDBrf6gw-8@txt.voice.google.com>\r\nTo: me@example.com\r\n'
            b'Content-Type: text/plain; charset="UTF-8"\r\n\r\n\r\n<https://voice.google.com>\r\nTest\r\n'
            b'YOUR ACCOUNT <https://voice.google.com> HELP CENTER\r\n<https://support.google.com/voice#topic=1707989> HELP FORUM\r\n'
            b'This email was sent to you because you indicated that you\'d like to receive\r\nemail notifications for text messages.\r\n')
    info = sms_relay.parse_gv_email(real)
    check("real Google Voice email (Nov 2026 layout) parsed",
          info and info["sender"] == "7185551234" and info["text"] == "Test" and info["signed"], info)
    check("signature: failed DKIM rejected",
          not signed_with("mx.google.com; dkim=fail header.i=@txt.voice.google.com"))
    threading.Thread(target=sms_relay.Relay(rcfg).run_forever, daemon=True).start()
    time.sleep(1.5)
    check("old text skipped on first run", len(SENT) == 0, SENT)

    t0 = time.time()
    BOX.add(gv_mail(MY, "hello claude"))
    s = wait_sent(2)
    check("ack + answer sent", len(s) == 2, s)
    check("ack came fast (<1.5s)", s and s[0][2] - t0 < 1.5, s and s[0][2] - t0)
    check("reply goes to GV address", all(x[0].endswith("@txt.voice.google.com") and f".1{MY}." in x[0] for x in s), s)
    check("answer text clean", any(x[1] == "Echo [sess-new]: hello claude" for x in s), [x[1] for x in s])

    SENT.clear()
    BOX.add(gv_mail("2125559999", "i am a stranger"))
    time.sleep(1.5)
    check("stranger ignored", len(SENT) == 0, SENT)

    BOX.add(gv_mail(MY, "follow up"))
    s = wait_sent(2)
    check("conversation continues (resume)", any("Echo [sess-1]: follow up" == x[1] for x in s), [x[1] for x in s])

    SENT.clear(); BOX.add(gv_mail(MY, "New")); s = wait_sent(1)
    check("'new' command", s and "fresh conversation" in s[0][1], s)
    SENT.clear(); BOX.add(gv_mail(MY, "after new")); s = wait_sent(2)
    check("fresh session after new", any("Echo [sess-new]: after new" == x[1] for x in s), [x[1] for x in s])

    SENT.clear(); BOX.add(gv_mail(MY, "LONG please")); s = wait_sent(4)
    time.sleep(1)
    s = SENT[:]
    check("long answer split into 1 ack + 3 parts", len(s) == 4, [x[1][:20] for x in s])
    check("parts labeled and 'more' hint", s[1][1].startswith("(1/3)") and "text 'more'" in s[-1][1], [x[1][:12] for x in s])
    SENT.clear(); BOX.add(gv_mail(MY, "more")); time.sleep(6)
    check("'more' sends the rest", len(SENT) >= 1 and SENT[0][1].startswith("(1/"), [x[1][:12] for x in SENT])

    SENT.clear(); BOX.add(gv_mail(MY, "SLOW job")); wait_sent(1)
    BOX.add(gv_mail(MY, "status")); s = wait_sent(2)
    check("status while busy", any("Working on a job" in x[1] for x in s), [x[1] for x in s])
    SENT.clear(); BOX.add(gv_mail(MY, "stop")); s = wait_sent(1)
    check("stop kills job", s and s[0][1] == "Stopped.", s)
    time.sleep(2)
    check("no answer after stop", not any("slow done" in x[1] for x in SENT), SENT)

    # Replies through the send-as-me script (a pretend one here)
    import http.server
    POSTS = []
    class FakeScript(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            POSTS.append(body)
            ok = body.get("secret") == "s3cret"
            out = json.dumps({"ok": ok, "left": 99} if ok else {"ok": False, "error": "bad secret"}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(out)
        def log_message(self, *a):
            pass
    srv = http.server.HTTPServer(("127.0.0.1", 0), FakeScript)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    scfg = dict(rcfg, send_url=f"http://127.0.0.1:{srv.server_port}/exec", send_secret="s3cret")
    sender = sms_relay.Sender(scfg, sms_relay.State(f"{TMP}/state2.json"))
    n_smtp = len(SENT)
    ok = sender._send_one(f"1{GV}.1{MY}.tok@txt.voice.google.com", "hi from script", "Re: x")
    check("reply goes through send-as-me script, not SMTP",
          ok and POSTS and POSTS[-1]["body"] == "hi from script" and POSTS[-1]["secret"] == "s3cret" and len(SENT) == n_smtp, POSTS)
    bad = sms_relay.Sender(dict(scfg, send_secret="wrong"), sender.state)._send_one("x@txt.voice.google.com", "y", "z")
    check("wrong secret reported as failure", bad is False)

    print("\nALL PASSED" if all(results) else "\nSOME FAILED")
