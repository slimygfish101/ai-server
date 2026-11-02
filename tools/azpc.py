#!/usr/bin/env python3
"""Claude's remote control for ClaudePC on Azure (used from Claude's cloud chat sessions).

Needs AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID
from the environment settings (the limited "claude-pc-switch" key).

  tools/azpc.py status | start | stop | restart
  tools/azpc.py run '<PowerShell commands>'      # runs as SYSTEM on the PC
  tools/azpc.py helper muse|grok
  tools/azpc.py setup-status
"""
import json
import os
import ssl
import sys
import time
import urllib.parse
import urllib.request

RG = "ClaudePC"
VM = "ClaudePC"
API = "2024-07-01"
ARM = "https://management.azure.com"


def _context():
    for path in (os.environ.get("SSL_CERT_FILE"), os.environ.get("REQUESTS_CA_BUNDLE"), "/root/.ccr/ca-bundle.crt"):
        if path and os.path.exists(path):
            return ssl.create_default_context(cafile=path)
    return ssl.create_default_context()


CTX = _context()


def _call(method, url, body=None, headers=None, form=False):
    data = None
    headers = dict(headers or {})
    if body is not None:
        if form:
            data = urllib.parse.urlencode(body).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, context=CTX, timeout=120) as resp:
        text = resp.read().decode()
        return json.loads(text) if text else {}


def _token():
    tenant = os.environ["AZURE_TENANT_ID"]
    reply = _call("POST", f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token", form=True, body={
        "grant_type": "client_credentials",
        "client_id": os.environ["AZURE_CLIENT_ID"],
        "client_secret": os.environ["AZURE_CLIENT_SECRET"],
        "scope": f"{ARM}/.default",
    })
    return reply["access_token"]


def _vm_url(suffix=""):
    sub = os.environ["AZURE_SUBSCRIPTION_ID"]
    return f"{ARM}/subscriptions/{sub}/resourceGroups/{RG}/providers/Microsoft.Compute/virtualMachines/{VM}{suffix}"


def arm(method, suffix="", body=None, query=""):
    sep = "&" if "?" in suffix else "?"
    url = _vm_url(suffix) + f"{sep}api-version={API}{query}"
    return _call(method, url, body, {"Authorization": f"Bearer {_token()}"})


def power_state():
    view = arm("GET", "/instanceView")
    states = [s["code"] for s in view.get("statuses", []) if s["code"].startswith("PowerState/")]
    return states[0].split("/", 1)[1] if states else "unknown"


def wait_for(state, minutes=10):
    deadline = time.time() + minutes * 60
    while time.time() < deadline:
        current = power_state()
        if current == state:
            return current
        time.sleep(15)
    return power_state()


def run_ps(script):
    name = f"claude-{int(time.time())}"
    vm = arm("GET")
    arm("PUT", f"/runCommands/{name}", {
        "location": vm["location"],
        "properties": {"source": {"script": script}, "asyncExecution": False, "timeoutInSeconds": 900},
    })
    try:
        for _ in range(120):
            view = arm("GET", f"/runCommands/{name}", query="&$expand=instanceView")["properties"].get("instanceView", {})
            if view.get("executionState") in ("Succeeded", "Failed", "TimedOut", "Canceled"):
                print(view.get("executionState"))
                print(view.get("output", ""))
                if view.get("error"):
                    print(view["error"], file=sys.stderr)
                return
            time.sleep(10)
        print("still running after 20 minutes")
    finally:
        try:
            arm("DELETE", f"/runCommands/{name}")
        except Exception:
            pass


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    if cmd == "status":
        print(power_state())
    elif cmd == "start":
        arm("POST", "/start")
        print(wait_for("running"))
    elif cmd == "stop":  # deallocate: the only kind of "off" that stops Azure's per-hour charge
        arm("POST", "/deallocate")
        print(wait_for("deallocated"))
    elif cmd == "restart":
        arm("POST", "/restart")
        print("restarting")
    elif cmd == "run" and len(argv) > 2:
        run_ps(argv[2])
    elif cmd == "helper" and len(argv) > 2 and argv[2] in ("muse", "grok"):
        run_ps(f"Set-Content C:\\ClaudePC\\helper.txt '{argv[2]}'; Get-Content C:\\ClaudePC\\helper.txt")
    elif cmd == "setup-status":
        run_ps("Get-Content C:\\ClaudePC\\setup-status.txt -ErrorAction SilentlyContinue; "
               "Get-Content C:\\ClaudePC\\logs\\bootstrap.log -Tail 40 -ErrorAction SilentlyContinue")
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
