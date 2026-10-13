#!/usr/bin/env python3
"""Small App Store Connect API client with no dependencies beyond openssl.

Reads KEY_ID, ISSUER_ID and P8_PATH from the environment (source the shared
config in a subshell and export them). Signs the JWT with openssl so the key
file is never read into this process, and prints nothing from it.

    asc.py builds <ASC_APP_ID>     newest builds: version, processingState, beta state
    asc.py testers <ASC_APP_ID>    testers of the app and their state (NOT_INVITED/INVITED/INSTALLED)
    asc.py groups <ASC_APP_ID>     TestFlight groups: internal, automatic distribution, testers with state
    asc.py apps                    app records visible to this key (numeric id, bundle id, name)
    asc.py bundleids               App IDs registered in the developer portal (id, identifier, name)
    asc.py users                   Admin-only endpoint; exit 0 means the key is Admin
    asc.py get <path>              raw GET under /v1/, JSON to stdout
    asc.py notes <ASC_APP_ID> <build> "<text>"   TestFlight "What to Test" for that build (created or
                                   replaced; text on stdin when omitted; the build must be listed already)
"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request

def token():
    kid, iss, p8 = os.environ["KEY_ID"], os.environ["ISSUER_ID"], os.environ["P8_PATH"]
    b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
    now = int(time.time())
    head = b64(json.dumps({"alg": "ES256", "kid": kid, "typ": "JWT"}).encode())
    body = b64(json.dumps({"iss": iss, "iat": now, "exp": now + 600,
                           "aud": "appstoreconnect-v1"}).encode())
    msg = f"{head}.{body}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", p8],
                         input=msg, capture_output=True, check=True).stdout
    # DER SEQUENCE { INTEGER r, INTEGER s } -> raw r||s, 32 bytes each
    i = 2 if der[1] < 0x80 else 3
    rl = der[i + 1]; r = der[i + 2:i + 2 + rl]; i = i + 2 + rl
    sl = der[i + 1]; s = der[i + 2:i + 2 + sl]
    raw = r[-32:].rjust(32, b"\0") + s[-32:].rjust(32, b"\0")
    return f"{head}.{body}.{b64(raw)}"

def get(path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com/v1/" + path,
                                 headers={"Authorization": f"Bearer {token()}"})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)

def request(method, path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request("https://api.appstoreconnect.apple.com/v1/" + path, data=data, method=method,
                                 headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}

def build_id(app, version):
    d = get(f"builds?filter[app]={app}&filter[version]={version}&fields[builds]=version&limit=5")
    if not d["data"]:
        sys.exit(f"build {version} is not listed for app {app} yet (processing has not started, or the number is wrong)")
    return d["data"][0]["id"]

def set_notes(app, version, text, locale="en-US"):
    """TestFlight's What to Test for one build: created or replaced, at most 4000 characters."""
    bid = build_id(app, version)
    existing = get(f"builds/{bid}/betaBuildLocalizations?fields[betaBuildLocalizations]=locale,whatsNew")["data"]
    for loc in existing:
        if loc["attributes"]["locale"] == locale:
            request("PATCH", f"betaBuildLocalizations/{loc['id']}",
                    {"data": {"type": "betaBuildLocalizations", "id": loc["id"], "attributes": {"whatsNew": text[:4000]}}})
            return "replaced"
    request("POST", "betaBuildLocalizations",
            {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": text[:4000]},
                      "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
    return "created"

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    if cmd == "notes":
        # asc.py notes <app id> <build number> "<what to test>"   (or the text on stdin)
        app, version = sys.argv[2], sys.argv[3]
        text = sys.argv[4] if len(sys.argv) > 4 else sys.stdin.read()
        print(f"build {version}: What to Test {set_notes(app, version, text.strip())}")
        return
    if cmd == "builds":
        app = sys.argv[2]
        d = get(f"builds?filter[app]={app}&sort=-uploadedDate&limit=5"
                "&fields[builds]=version,processingState,uploadedDate,expired")
        for b in d["data"]:
            a = b["attributes"]
            line = f"build {a['version']}  {a['processingState']}  uploaded {a['uploadedDate']}"
            if a.get("expired"): line += "  EXPIRED"
            try:
                bd = get(f"builds/{b['id']}/buildBetaDetail")["data"]["attributes"]
                line += f"  internal={bd['internalBuildState']} external={bd['externalBuildState']}"
            except urllib.error.HTTPError:
                pass
            print(line)
    elif cmd == "testers":
        app = sys.argv[2]
        d = get(f"betaTesters?filter[apps]={app}&fields[betaTesters]=email,state&limit=50")
        for t in d["data"]:
            print(f"{t['attributes'].get('email')}  {t['attributes'].get('state')}")
    elif cmd == "groups":
        app = sys.argv[2]
        d = get(f"betaGroups?filter[app]={app}&fields[betaGroups]=name,isInternalGroup,hasAccessToAllBuilds&limit=50")
        for g in d["data"]:
            a = g["attributes"]
            members = get(f"betaGroups/{g['id']}/betaTesters?fields[betaTesters]=email,state&limit=50")["data"]
            testers = ", ".join(f"{t['attributes'].get('email')}:{t['attributes'].get('state')}" for t in members)
            # hasAccessToAllBuilds is what the web UI calls "Enable automatic distribution".
            print(f"{a['name']}  internal={a.get('isInternalGroup')}  auto={a.get('hasAccessToAllBuilds')}  {testers or 'no testers'}")
    elif cmd == "apps":
        d = get("apps?fields[apps]=name,bundleId&limit=50")
        for a in d["data"]:
            print(f"{a['id']}  {a['attributes']['bundleId']}  {a['attributes']['name']}")
    elif cmd == "bundleids":
        # The identifier filter matches prefixes (com.jkulak returns every
        # com.jkulak.* id), so list everything and let the caller compare exactly.
        d = get("bundleIds?fields[bundleIds]=identifier,name&limit=200")
        for b in d["data"]:
            print(f"{b['id']}  {b['attributes']['identifier']}  {b['attributes']['name']}")
    elif cmd == "users":
        get("users?limit=1")
        print("admin")
    elif cmd == "get":
        print(json.dumps(get(sys.argv[2]), indent=1))
    else:
        print(__doc__)
        sys.exit(2)

if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} from App Store Connect: {e.read()[:300].decode(errors='replace')}", file=sys.stderr)
        sys.exit(1)
