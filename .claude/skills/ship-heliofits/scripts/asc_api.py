"""Minimal App Store Connect API client.

Signs ES256 JWTs per Apple's spec and calls the ASC REST API. The .p8 key
never leaves this process: it is read from local disk and used only to sign
requests to api.appstoreconnect.apple.com.

Usage: python3 asc_api.py <METHOD> <path> [json-body]
  python3 asc_api.py GET /v1/apps
"""
import sys, os, time, json, urllib.request, urllib.error
import jwt

KEY_ID = "4QPRA2KW39"
ISSUER_ID = "7b467b82-5579-417f-aa7e-b7d16f47f8d9"
KEY_PATH = os.path.expanduser(f"~/.claude/secrets/appstoreconnect/AuthKey_{KEY_ID}.p8")
BASE = "https://api.appstoreconnect.apple.com"

def make_token():
    with open(KEY_PATH) as f:
        private_key = f.read()
    now = int(time.time())
    payload = {
        "iss": ISSUER_ID,
        "iat": now,
        "exp": now + 600,          # Apple caps this at 20 min; 10 is plenty
        "aud": "appstoreconnect-v1",
    }
    headers = {"kid": KEY_ID, "typ": "JWT"}
    return jwt.encode(payload, private_key, algorithm="ES256", headers=headers)

def call(method, path, body=None):
    token = make_token()
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

if __name__ == "__main__":
    method = sys.argv[1]
    path = sys.argv[2]
    body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    status, resp = call(method, path, body)
    print("HTTP", status)
    print(json.dumps(resp, indent=2)[:3000])
