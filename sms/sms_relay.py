"""
ClaudePC text-message relay.

Your phone --SMS--> Google Voice --email--> Gmail inbox
   --(this program, listening live)--> Claude Code on ClaudePC
   --answer--> Gmail reply --> Google Voice --SMS--> your phone

Only texts from the cell number in config.ini are accepted.
Text commands: new, stop, status, more, help.
"""
import configparser
import email
import email.policy
import imaplib
import json
import logging
import logging.handlers
import os
import queue
import re
import select
import shutil
import smtplib
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from email.message import EmailMessage
from email.utils import make_msgid, parseaddr

BASE = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.environ.get("SMS_RELAY_CONFIG", os.path.join(BASE, "config.ini"))
STATE_PATH = os.environ.get("SMS_RELAY_STATE", os.path.join(BASE, "state.json"))
LOG_PATH = os.environ.get("SMS_RELAY_LOG", os.path.join(BASE, "relay.log"))
GV_DOMAIN = "txt.voice.google.com"
LOCK_PORT = 47321
IS_WINDOWS = os.name == "nt"

log = logging.getLogger("relay")

HELP_TEXT = (
    "ClaudePC texting. Just text what you need.\n"
    "new = start a fresh conversation\n"
    "stop = cancel the current job\n"
    "status = is it busy?\n"
    "more = rest of a long answer\n"
    "claude <message> = ask Claude (it can use the whole computer)\n"
    "chatgpt <message> = ask ChatGPT"
)


# ---------------------------------------------------------------- helpers
def digits10(s):
    """Last 10 digits of a phone number (US), or '' if too short."""
    d = re.sub(r"\D", "", s or "")
    return d[-10:] if len(d) >= 10 else ""


def load_config():
    cp = configparser.ConfigParser(interpolation=None)
    if not cp.read(CFG_PATH, encoding="utf-8-sig"):  # utf-8-sig: Windows tools may add a BOM
        raise SystemExit(f"Config file not found: {CFG_PATH}")
    c = cp["relay"]
    cfg = {
        "gmail": c.get("gmail_address", "").strip(),
        "app_password": re.sub(r"\s", "", c.get("gmail_app_password", "")),
        "my_number": digits10(c.get("my_cell_number", "")),
        "imap_host": c.get("imap_host", "imap.gmail.com"),
        "imap_port": c.getint("imap_port", 993),
        "smtp_host": c.get("smtp_host", "smtp.gmail.com"),
        "smtp_port": c.getint("smtp_port", 465),
        "smtp_ssl": c.getboolean("smtp_ssl", True),
        "imap_ssl": c.getboolean("imap_ssl", True),
        "claude": c.get("claude_command", "").strip() or find_claude(),
        "chat_folder": c.get("chat_folder", os.path.join(BASE, "chat")),
        "claude_args": c.get("claude_extra_args", "--dangerously-skip-permissions").split(),
        "model": c.get("model", "").strip(),
        "part_len": c.getint("chars_per_text", 600),
        "max_parts": c.getint("max_texts_per_reply", 6),
        "timeout_min": c.getfloat("job_timeout_minutes", 60),
        "progress_min": c.getfloat("still_working_after_minutes", 5),
        "ack": c.getboolean("send_got_it", True),
        "poll_seconds": c.getfloat("fallback_poll_seconds", 3),
        "require_signature": c.getboolean("require_google_signature", True),
        "send_url": c.get("send_script_url", "").strip(),
        "fallback_node": c.get("fallback_node", "").strip(),
        "fallback_codex": c.get("fallback_codex_script", "").strip(),
        "fallback_sandbox": c.get("fallback_sandbox", "workspace-write").strip(),
        "primary": c.get("primary", "claude").strip().lower(),
        "send_secret": c.get("send_script_secret", "").strip(),
    }
    missing = [k for k in ("gmail", "app_password", "my_number") if not cfg[k]]
    if missing:
        raise SystemExit("config.ini is missing: " + ", ".join(missing))
    if "PASTE" in cfg["app_password"].upper():
        raise SystemExit("config.ini still has the placeholder app password")
    return cfg


def find_claude():
    found = shutil.which("claude")
    if found:
        return found
    for p in (
        os.path.expandvars(r"%USERPROFILE%\.local\bin\claude.exe"),
        os.path.expanduser("~/.local/bin/claude"),
    ):
        if os.path.exists(p):
            return p
    return "claude"


class State:
    """Small JSON file: Claude session id, processed message ids, leftover text."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.data = {"session_id": None, "codex_session": None, "history": [],
                     "seen": [], "more": [], "more_to": None}
        self.first_run = not os.path.exists(path)
        if not self.first_run:
            try:
                with open(path, encoding="utf-8") as f:
                    self.data.update(json.load(f))
            except Exception:
                log.exception("state file unreadable, starting clean")

    def save(self):
        with self.lock:
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.data, f)
            os.replace(tmp, self.path)

    def seen(self, mid):
        return mid in self.data["seen"]

    def mark(self, mid):
        self.data["seen"] = (self.data["seen"] + [mid])[-300:]
        self.save()


# ------------------------------------------------------- Google Voice mail
GOOGLE_DKIM = re.compile(r"dkim=pass[^;]*header\.[id]=@?(txt\.voice\.)?google\.com(?=[\s;)]|$)")


def google_signed(msg):
    """True if Gmail's own check says Google really sent this (DKIM pass).

    Only the topmost Authentication-Results header counts: Gmail adds it on
    arrival, while lower ones could have been written by whoever sent the mail.
    Without this check, a forged email could pose as a text from your number.
    """
    found = msg.get_all("Authentication-Results") or []
    if not found:
        return False
    top = str(found[0]).lower().strip()
    return top.startswith("mx.google.com") and bool(GOOGLE_DKIM.search(top))


def parse_gv_email(raw_bytes):
    """Return dict(sender, reply_to, text, msg_id, subject) or None if not a GV text."""
    msg = email.message_from_bytes(raw_bytes, policy=email.policy.default)
    reply_to = parseaddr(str(msg.get("Reply-To", "")))[1] or parseaddr(str(msg.get("From", "")))[1]
    reply_to = reply_to.strip().lower()
    if not reply_to.endswith("@" + GV_DOMAIN):
        return None
    subject = str(msg.get("Subject", ""))
    # Address looks like 1<gv number>.1<sender number>.<token>@txt.voice.google.com
    local = reply_to.split("@")[0]
    parts = local.split(".")
    sender = digits10(parts[1]) if len(parts) >= 3 else ""
    if not sender:
        m = re.search(r"from\s+(.+)$", subject, re.I)
        sender = digits10(m.group(1)) if m else ""
    body = ""
    part = msg.get_body(preferencelist=("plain",))
    if part is not None:
        body = part.get_content()
    else:
        part = msg.get_body(preferencelist=("html",))
        if part is not None:
            body = html_to_text(part.get_content())
    has_picture = any(
        p.get_content_maintype() == "image" for p in msg.walk() if not p.is_multipart()
    )
    text = clean_gv_body(body)
    if has_picture:
        text = (text + "\n[a picture was attached; pictures aren't supported yet]").strip()
    return {
        "sender": sender,
        "reply_to": reply_to,
        "text": text,
        "msg_id": str(msg.get("Message-ID", "")).strip() or make_msgid(),
        "subject": subject,
        "signed": google_signed(msg),
    }


def html_to_text(h):
    h = re.sub(r"(?is)<(script|style).*?</\1>", "", h)
    h = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</tr>", "\n", h)
    h = re.sub(r"<[^>]+>", "", h)
    for a, b in (("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&#39;", "'"), ("&quot;", '"')):
        h = h.replace(a, b)
    return h


FOOTER_START = re.compile(
    r"^\s*(to respond to this text message|you received this message because|your account\b|"
    r"google llc|this email was sent to)",
    re.I,
)
URL_ONLY = re.compile(r"^\s*<?https?://\S+>?\.?\s*$")


def clean_gv_body(body):
    out = []
    for line in body.replace("\r\n", "\n").split("\n"):
        if FOOTER_START.match(line):
            break
        if URL_ONLY.match(line):
            continue
        out.append(line.rstrip())
    return "\n".join(out).strip()


# --------------------------------------------------------------- sending
def split_for_sms(text, part_len):
    text = re.sub(r"\n{3,}", "\n\n", (text or "").strip()) or "(empty answer)"
    chunks = []
    while text:
        if len(text) <= part_len:
            chunks.append(text)
            break
        cut = max(text.rfind("\n", 0, part_len), text.rfind(". ", 0, part_len) + 1, text.rfind(" ", 0, part_len))
        if cut < part_len // 2:
            cut = part_len
        chunks.append(text[:cut].strip())
        text = text[cut:].strip()
    return chunks


class Sender:
    def __init__(self, cfg, state):
        self.cfg = cfg
        self.state = state
        self.lock = threading.RLock()

    def _send_one(self, to, body, subject):
        if self.cfg["send_url"]:
            return self._send_via_script(to, body, subject)
        m = EmailMessage()
        m["From"] = self.cfg["gmail"]
        m["To"] = to
        m["Subject"] = subject
        m["Message-ID"] = make_msgid()
        m.set_content(body)
        c = self.cfg
        for attempt in range(3):
            try:
                if c["smtp_ssl"]:
                    s = smtplib.SMTP_SSL(c["smtp_host"], c["smtp_port"], timeout=30)
                else:
                    s = smtplib.SMTP(c["smtp_host"], c["smtp_port"], timeout=30)
                with s:
                    if c["app_password"] != "-":
                        s.login(c["gmail"], c["app_password"])
                    s.send_message(m)
                return True
            except Exception:
                log.exception("send failed (attempt %d)", attempt + 1)
                time.sleep(3 * (attempt + 1))
        return False

    def _send_via_script(self, to, body, subject):
        """Send through the send-as-me Google script, so the reply comes from the Gmail
        that owns Google Voice (Google Voice rejects replies from any other address)."""
        ok, info = call_send_script(self.cfg, {"to": to, "subject": subject, "body": body})
        if not ok:
            log.error("send-as-me script refused or failed: %s", info)
        return ok

    def text(self, to, body, subject="Re: text"):
        """Send an answer as one or more texts; keep overflow for 'more'."""
        with self.lock:
            parts = split_for_sms(body, self.cfg["part_len"])
            maxp = self.cfg["max_parts"]
            now, later = parts[:maxp], parts[maxp:]
            total = len(now)
            for i, p in enumerate(now, 1):
                label = f"({i}/{total}) " if total > 1 else ""
                if i == total and later:
                    p += "\n[more: text 'more' for the rest]"
                self._send_one(to, label + p, subject)
                if i < total:
                    time.sleep(1.5)  # keep order on the phone
            self.state.data["more"] = later
            self.state.data["more_to"] = to if later else None
            self.state.save()

    def more(self, to, subject):
        with self.lock:  # wait for any answer still being sent
            rest = self.state.data.get("more") or []
            if not rest:
                self.text(to, "Nothing more to send.", subject)
            else:
                self.text(to, "\n".join(rest), subject)


def call_send_script(cfg, payload):
    """POST to the send-as-me script; returns (ok, info)."""
    data = json.dumps(dict(payload, secret=cfg["send_secret"])).encode("utf-8")
    for attempt in range(3):
        try:
            req = urllib.request.Request(cfg["send_url"], data=data, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                answer = json.loads(resp.read().decode("utf-8") or "{}")
            return bool(answer.get("ok")), answer
        except Exception as e:
            info = repr(e)
            time.sleep(3 * (attempt + 1))
    return False, info


# ---------------------------------------------------------------- Claude
class Worker(threading.Thread):
    def __init__(self, cfg, state, sender):
        super().__init__(daemon=True)
        self.cfg, self.state, self.sender = cfg, state, sender
        self.jobs = queue.Queue()
        self.proc = None
        self.busy = False
        self.cancelled = False

    def queued(self):
        return self.jobs.qsize()

    def stop_current(self):
        self.cancelled = True
        while not self.jobs.empty():
            try:
                self.jobs.get_nowait()
            except queue.Empty:
                break
        p = self.proc
        if p and p.poll() is None:
            kill_tree(p)
            return True
        return False

    def run(self):
        while True:
            job = self.jobs.get()
            self.busy, self.cancelled = True, False
            try:
                self.handle(job)
            except Exception:
                log.exception("job crashed")
                self.sender.text(job["reply_to"], "Something broke on ClaudePC while doing that. Try again, or text 'new'.", job["subject"])
            finally:
                self.busy, self.proc = False, None

    def handle(self, job):
        primary = self.cfg["primary"]
        if job.get("engine") == "codex":
            answer, err = self.ask_codex(job)
            if self.cancelled:
                return
            if err:
                answer = f"ChatGPT couldn't finish: {err[:300]}\nStart your text with 'claude' to ask Claude instead."
            else:
                self.remember("chatgpt", job, answer)
                if primary != "chatgpt":
                    answer = "(ChatGPT)\n" + answer
            self.sender.text(job["reply_to"], answer, job["subject"])
            return
        job["prompt"] = self.with_context("claude", job["text"])
        answer, err = self.ask_claude(job, resume=True)
        if err == "resume_failed":
            log.info("resume failed, starting a fresh conversation")
            self.state.data["session_id"] = None
            answer, err = self.ask_claude(job, resume=False)
        if self.cancelled:
            return
        if looks_like_limit(answer if answer is not None else err) and self.cfg["fallback_codex"]:
            log.info("Claude usage limit reached; asking ChatGPT (Codex) instead")
            answer, err = self.ask_codex(job)
            if self.cancelled:
                return
            if not err:
                self.remember("chatgpt", job, answer)
                answer = "(ChatGPT answering, Claude limit reached)\n" + answer
            else:
                err = "Claude is at its usage limit and ChatGPT also failed: " + err
        elif not err:
            self.remember("claude", job, answer)
            if primary == "chatgpt":
                answer = "(Claude)\n" + answer
        if err:
            answer = f"Claude couldn't finish: {err[:300]}\nText 'new' to start fresh if this keeps happening."
        self.sender.text(job["reply_to"], answer, job["subject"])

    # ---- shared memory between Claude and ChatGPT
    def remember(self, engine, job, answer):
        h = self.state.data.setdefault("history", [])
        h.append({"engine": engine, "q": job["text"][:1500], "a": (answer or "")[:1500]})
        self.state.data["history"] = h[-30:]
        self.state.save()

    def with_context(self, engine, text):
        """Prefix the texts the other assistant handled since this one last answered,
        so switching between Claude and ChatGPT doesn't lose the thread."""
        unseen = []
        for item in reversed(self.state.data.get("history") or []):
            if item["engine"] == engine:
                break
            unseen.append(item)
        if not unseen:
            return text
        lines = ["Earlier in this text conversation (answered by the other assistant), for context:"]
        for item in reversed(unseen[:6]):
            lines.append("Lipa: " + item["q"])
            lines.append("Answer: " + item["a"][:800])
        return "\n".join(lines) + "\n\nLipa's new text:\n" + text

    def run_job(self, args, job, cwd):
        """Run a helper program with the text on stdin. Returns (out, err, problem)."""
        flags = 0x08000000 if IS_WINDOWS else 0  # CREATE_NO_WINDOW
        self.proc = subprocess.Popen(
            args, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, creationflags=flags,
        )
        out_box = {}

        def comm():
            out_box["out"], out_box["err"] = self.proc.communicate(job.get("prompt", job["text"]).encode("utf-8"))

        t = threading.Thread(target=comm, daemon=True)
        t.start()
        start = time.time()
        warned = False
        c = self.cfg
        while t.is_alive():
            t.join(2)
            mins = (time.time() - start) / 60
            if not warned and mins >= c["progress_min"] and t.is_alive():
                warned = True
                self.sender._send_one(job["reply_to"], "Still working on it...", job["subject"])
            if mins >= c["timeout_min"] and t.is_alive():
                kill_tree(self.proc)
                t.join(10)
                return "", "", f"took longer than {int(c['timeout_min'])} minutes, so it was stopped"
        out = (out_box.get("out") or b"").decode("utf-8", "replace")
        err = (out_box.get("err") or b"").decode("utf-8", "replace")
        return out, err, None

    def ask_codex(self, job, resume=True):
        """ChatGPT's Codex CLI, kept inside its sandbox (fallback_sandbox, default
        workspace-write: it can only change the texting folder). Continues the saved
        ChatGPT conversation until 'new'."""
        c = self.cfg
        job["prompt"] = self.with_context("chatgpt", job["text"])
        answer_file = os.path.join(c["chat_folder"], ".codex-answer.txt")
        try:
            os.remove(answer_file)
        except OSError:
            pass
        sid = self.state.data.get("codex_session") if resume else None
        base = [c["fallback_node"] or "node", c["fallback_codex"], "exec"]
        opts = ["-c", f'sandbox_mode="{c["fallback_sandbox"]}"', "--skip-git-repo-check",
                "--json", "-o", answer_file]
        if sid:
            args = base + ["resume"] + opts + [sid, "-"]
        else:
            args = base + ["--sandbox", c["fallback_sandbox"], "--color", "never", "-C", c["chat_folder"]] + opts + ["-"]
        log.info("codex start (resume=%s, sandbox=%s) %r", bool(sid), c["fallback_sandbox"], job["text"][:80])
        out, err, problem = self.run_job(args, job, c["chat_folder"])
        if self.cancelled:
            return None, None
        if problem:
            return None, problem
        new_id = codex_thread_id(out)
        if new_id and new_id != sid:
            self.state.data["codex_session"] = new_id
            self.state.save()
        try:
            with open(answer_file, encoding="utf-8") as f:
                answer = f.read().strip()
        except OSError:
            answer = ""
        if answer:
            return answer, None
        if sid and resume:
            log.info("codex resume failed, starting a fresh ChatGPT conversation")
            self.state.data["codex_session"] = None
            return self.ask_codex(job, resume=False)
        return None, (err or out).strip()[-300:] or f"no answer (exit code {self.proc.returncode})"

    def ask_claude(self, job, resume):
        c = self.cfg
        os.makedirs(c["chat_folder"], exist_ok=True)
        args = [c["claude"], "-p", "--output-format", "json"]
        sid = self.state.data.get("session_id")
        if resume and sid:
            args += ["--resume", sid]
        if c["model"]:
            args += ["--model", c["model"]]
        args += c["claude_args"]
        log.info("claude start (resume=%s) %r", bool(resume and sid), job["text"][:80])
        out, err, problem = self.run_job(args, job, c["chat_folder"])
        if problem:
            return None, problem
        if self.cancelled:
            return None, None
        data = None
        for line in reversed(out.strip().splitlines()):
            try:
                data = json.loads(line)
                break
            except Exception:
                continue
        if data is None:
            try:
                data = json.loads(out)
            except Exception:
                pass
        if not isinstance(data, dict):
            msg = (err or out).strip()
            if resume and sid and re.search(r"session|conversation", msg, re.I):
                return None, "resume_failed"
            return None, msg or f"no answer (exit code {self.proc.returncode})"
        if data.get("session_id"):
            self.state.data["session_id"] = data["session_id"]
            self.state.save()
        result = data.get("result") or ""
        if data.get("is_error"):
            if resume and sid and re.search(r"session|conversation", result + err, re.I):
                return None, "resume_failed"
            return None, result or data.get("subtype") or "error"
        return result, None


def codex_thread_id(out):
    """Find the conversation id in Codex's --json event stream."""
    for line in out.splitlines():
        try:
            ev = json.loads(line)
        except Exception:
            continue
        for d in (ev, ev.get("msg") if isinstance(ev, dict) else None):
            if isinstance(d, dict):
                for key in ("thread_id", "session_id", "conversation_id"):
                    if isinstance(d.get(key), str) and d[key]:
                        return d[key]
    return None


LIMIT_WORDS = re.compile(
    r"usage limit|limit reached|hit your (usage |weekly |session )?limit|out of usage|"
    r"(5-hour|weekly|session) limit|rate limit", re.I)


def looks_like_limit(text):
    """True if Claude's reply is a usage-limit notice rather than a real answer."""
    t = (text or "").strip()
    return bool(t) and len(t) < 400 and bool(LIMIT_WORDS.search(t))


def kill_tree(p):
    try:
        if IS_WINDOWS:
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.pid)], capture_output=True, creationflags=0x08000000)
        else:
            p.kill()
    except Exception:
        log.exception("kill failed")


# --------------------------------------------------------------- inbox
class Inbox:
    def __init__(self, cfg, state, on_text):
        self.cfg, self.state, self.on_text = cfg, state, on_text
        self.M = None
        self.idle_ok = True

    def connect(self):
        c = self.cfg
        if c["imap_ssl"]:
            M = imaplib.IMAP4_SSL(c["imap_host"], c["imap_port"], timeout=60)
        else:
            M = imaplib.IMAP4(c["imap_host"], c["imap_port"], timeout=60)
        M.login(c["gmail"], c["app_password"])
        M.select("INBOX")
        self.M = M
        self.idle_ok = b"IDLE" in b" ".join(x if isinstance(x, bytes) else x.encode() for x in M.capabilities)
        log.info("inbox connected (live listening: %s)", self.idle_ok)

    def check(self):
        typ, data = self.M.uid("search", None, f'(UNSEEN FROM "{GV_DOMAIN}")')
        uids = data[0].split() if data and data[0] else []
        for uid in uids:
            typ, d = self.M.uid("fetch", uid, "(BODY.PEEK[])")
            raw = next((x[1] for x in d if isinstance(x, tuple)), None)
            self.M.uid("store", uid, "+FLAGS", "(\\Seen)")
            if raw is None:
                continue
            info = parse_gv_email(raw)
            if not info:
                continue
            if self.state.seen(info["msg_id"]):
                continue
            self.state.mark(info["msg_id"])
            if self.state.first_run:
                log.info("first run: skipping old text from %s", info["sender"])
                continue
            if self.cfg["require_signature"] and not info["signed"]:
                log.warning("ignored text claiming to be from %s: not signed by Google", info["sender"] or "unknown")
                continue
            if info["sender"] != self.cfg["my_number"]:
                log.warning("ignored text from %s (not your number)", info["sender"] or "unknown")
                continue
            self.on_text(info)
        if self.state.first_run:
            self.state.first_run = False
            self.state.save()

    def wait(self, seconds=None):
        """Wait for new mail. Uses IMAP IDLE (instant) or short polling."""
        if not self.idle_ok:
            time.sleep(self.cfg["poll_seconds"])
            self.M.noop()
            return
        M = self.M
        if hasattr(M, "idle"):  # Python 3.14+: built-in, fully reliable
            with M.idle(duration=seconds or 540) as idler:
                for typ, _ in idler:
                    if typ in ("EXISTS", "RECENT"):
                        break
            return
        # Older Python: do IDLE by hand. Short cycles bound any rare missed wake-up.
        seconds = seconds or 120
        tag = M._new_tag()
        M.send(tag + b" IDLE\r\n")
        first = M.readline()
        if not first.startswith(b"+"):
            self.idle_ok = False
            log.warning("server refused IDLE (%r); polling instead", first)
            return
        sock = M.sock
        deadline = time.time() + seconds
        try:
            while time.time() < deadline:
                ready = sock.pending() if hasattr(sock, "pending") else 0
                if not ready:
                    r, _, _ = select.select([sock], [], [], min(30, max(0.1, deadline - time.time())))
                    ready = bool(r)
                if ready:
                    line = M.readline()
                    if not line:
                        raise ConnectionError("server closed the connection")
                    if b"EXISTS" in line or b"RECENT" in line:
                        break
        finally:
            M.send(b"DONE\r\n")
            while True:
                line = M.readline()
                if not line:
                    raise ConnectionError("server closed the connection")
                if line.startswith(tag):
                    break

    def close(self):
        try:
            self.M.logout()
        except Exception:
            pass


# ----------------------------------------------------------------- main
class Relay:
    def __init__(self, cfg):
        self.cfg = cfg
        self.state = State(STATE_PATH)
        self.sender = Sender(cfg, self.state)
        self.worker = Worker(cfg, self.state, self.sender)
        self.worker.start()

    def on_text(self, info):
        text, to, subj = info["text"], info["reply_to"], "Re: " + (info["subject"] or "text")
        cmd = text.strip().lower().rstrip(".!")
        log.info("text in: %r", text[:80])
        if cmd in ("help", "?"):
            self.sender.text(to, HELP_TEXT, subj)
        elif cmd == "new":
            self.worker.stop_current()
            self.state.data.update(session_id=None, codex_session=None, history=[])
            self.state.save()
            self.sender.text(to, "OK, fresh conversation. What do you need?", subj)
        elif cmd in ("stop", "cancel"):
            killed = self.worker.stop_current()
            self.sender.text(to, "Stopped." if killed else "Nothing was running.", subj)
        elif cmd == "status":
            w = self.worker
            msg = "ClaudePC is on. " + ("Working on a job" if w.busy else "Idle")
            if w.queued():
                msg += f", {w.queued()} waiting"
            self.sender.text(to, msg + ".", subj)
        elif cmd == "more":
            self.sender.more(to, subj)
        elif not text.strip():
            self.sender.text(to, "Got an empty text. " + HELP_TEXT, subj)
        else:
            ahead = self.worker.queued() + (1 if self.worker.busy else 0)
            if self.cfg["ack"]:
                ack = "Got it, working on it." if not ahead else f"Got it. Starting after {ahead} job(s) ahead of it."
                threading.Thread(target=self.sender._send_one, args=(to, ack, subj), daemon=True).start()
            codex_ok = bool(self.cfg["fallback_codex"])
            engine = "codex" if (self.cfg["primary"] == "chatgpt" and codex_ok) else "claude"
            m_claude = re.match(r"\s*claude\b[\s:,-]*", text, re.I)
            m_gpt = re.match(r"\s*(chatgpt|gpt)\b[\s:,-]*", text, re.I)
            if m_claude:
                engine, text = "claude", text[m_claude.end():].strip() or "hello"
            elif m_gpt and codex_ok:
                engine, text = "codex", text[m_gpt.end():].strip() or "hello"
            self.worker.jobs.put({"text": text, "reply_to": to, "subject": subj, "engine": engine})

    def run_forever(self):
        backoff = 5
        while True:
            inbox = Inbox(self.cfg, self.state, self.on_text)
            try:
                inbox.connect()
                backoff = 5
                while True:
                    inbox.check()
                    inbox.wait()
            except (imaplib.IMAP4.error,) as e:
                log.error("inbox login/command error: %s", e)
                backoff = min(backoff * 2, 300)
            except Exception:
                log.exception("inbox connection dropped")
                backoff = min(backoff * 2, 120)
            finally:
                inbox.close()
            time.sleep(backoff)


def single_instance():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", LOCK_PORT))
        s.listen(1)
        return s
    except OSError:
        return None


def setup_logging(to_console):
    log.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    fh = logging.handlers.RotatingFileHandler(LOG_PATH, maxBytes=1_000_000, backupCount=3, encoding="utf-8")
    fh.setFormatter(fmt)
    log.addHandler(fh)
    if to_console:
        sh = logging.StreamHandler(sys.stdout)
        sh.setFormatter(fmt)
        log.addHandler(sh)


def self_test():
    cfg = load_config()
    ok = True
    print("Config: OK  (Gmail:", cfg["gmail"], " your cell: ...", cfg["my_number"][-4:], ")")
    try:
        M = imaplib.IMAP4_SSL(cfg["imap_host"], cfg["imap_port"], timeout=30)
        M.login(cfg["gmail"], cfg["app_password"])
        M.logout()
        print("Gmail reading: OK")
    except Exception as e:
        ok = False
        print("Gmail reading: FAILED -", e)
    if cfg["send_url"]:
        sent_ok, info = call_send_script(cfg, {"ping": True})
        ok = ok and sent_ok
        print("Sending (send-as-me script):", "OK, emails left today: %s" % info.get("left") if sent_ok else "FAILED - %s" % info)
    else:
        try:
            with smtplib.SMTP_SSL(cfg["smtp_host"], cfg["smtp_port"], timeout=30) as s:
                s.login(cfg["gmail"], cfg["app_password"])
            print("Gmail sending: OK")
        except Exception as e:
            ok = False
            print("Gmail sending: FAILED -", e)
    try:
        r = subprocess.run([cfg["claude"], "--version"], capture_output=True, text=True, timeout=60)
        print("Claude Code:", "OK " + r.stdout.strip() if r.returncode == 0 else "FAILED " + r.stderr.strip())
        ok = ok and r.returncode == 0
    except Exception as e:
        ok = False
        print("Claude Code: FAILED -", e)
    print("ALL GOOD" if ok else "SOMETHING FAILED (see above)")
    return 0 if ok else 1


def main():
    if "--test" in sys.argv:
        sys.exit(self_test())
    setup_logging(to_console="--console" in sys.argv)
    lock = single_instance()
    if lock is None:
        log.info("already running; exiting")
        return
    cfg = load_config()
    log.info("relay starting; listening for texts from ...%s", cfg["my_number"][-4:])
    Relay(cfg).run_forever()


if __name__ == "__main__":
    main()
