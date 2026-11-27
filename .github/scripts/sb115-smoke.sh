#!/usr/bin/env bash
# Full sweep on the panel's sing-box core: boot the panel, create one inbound
# per mainstream protocol plus one client linked to all of them, restart the
# core, then run the matching standalone sing-box as a client and push real
# traffic through every protocol on loopback. The AnyTLS inbound carries a
# padding scheme produced by our own frontend generator (scheme.json, made by
# the workflow from src/plugins/paddingScheme.ts).
# Best-effort throughout: every stage prints a SMOKE line and keeps going, so
# one run collects all the breakage.
set -u
cd "$(dirname "$0")/../.."
mkdir -p run && cd run

[ -x ../sui ] || { echo "SMOKE: panel binary missing, skipping"; exit 0; }
cp ../sui ./sui

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout key.pem -out cert.pem -days 2 -nodes -subj "/CN=localhost" 2>/dev/null
CERT="$PWD/cert.pem"; KEY="$PWD/key.pem"
UUID="11111111-2222-3333-4444-555555555555"
SSPW="$(openssl rand -base64 16)"

./sui > panel.log 2>&1 &
PANEL_PID=$!
trap 'kill $PANEL_PID 2>/dev/null; pkill -f "sing-box run" 2>/dev/null' EXIT

BASE="http://127.0.0.1:2095/app"
ok=""
for i in $(seq 1 30); do
  if curl -s -o /dev/null "$BASE/"; then ok=1; break; fi
  sleep 1
done
echo "SMOKE panel reachable: ${ok:-NO}"
curl -s -o /dev/null -w "SMOKE panel page HTTP %{http_code}\n" "$BASE/"

JAR=cookies.txt
XHDR="X-Requested-With: XMLHttpRequest"
echo "SMOKE login: $(curl -s -c $JAR -X POST $BASE/api/login -H "$XHDR" -d 'user=admin&pass=admin')"
echo "SMOKE status: $(curl -s -b $JAR $BASE/api/status)"

# TLS is a separate record in this panel; inbounds point at it by id.
cat > tls-data.json <<EOF
{"id":0,"name":"smoke","server":{"enabled":true,"server_name":"localhost","certificate_path":"$CERT","key_path":"$KEY"},"client":{"enabled":true,"server_name":"localhost","insecure":true}}
EOF
echo "SMOKE save tls: $(curl -s -b $JAR -X POST $BASE/api/save -H "$XHDR" \
  --data-urlencode object=tls --data-urlencode action=new \
  --data-urlencode data@tls-data.json)"
curl -s -b $JAR $BASE/api/tls > tls.json
TLS_ID=$(python3 -c 'import json; d=json.load(open("tls.json")); o=(d.get("obj") or {}).get("tls") or []; print([t["id"] for t in o if t.get("name")=="smoke"][-1] if o else 0)' 2>/dev/null || echo 0)
echo "SMOKE tls id: $TLS_ID"

# Build all inbound payloads in one go.
python3 - "$CERT" "$KEY" "$UUID" "$SSPW" "$TLS_ID" <<'EOF'
import json
cert, key, uuid, sspw = __import__("sys").argv[1:5]
tls_id = int(__import__("sys").argv[5])
tls = {"enabled": True, "server_name": "localhost", "certificate_path": cert, "key_path": key}
try:
    scheme = json.load(open("../scheme.json"))
    src = "generated-by-our-generator"
except Exception:
    scheme = ["stop=8", "0=30-30", "1=100-400",
              "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
              "3=9-9,500-1000", "4=500-1000", "5=500-1000", "6=500-1000", "7=500-1000"]
    src = "fallback-default"
print("SMOKE padding scheme source:", src)
inbounds = [
  {"id": 0, "type": "anytls", "tag": "anytls", "enable": True, "tls_id": 0,
   "listen": "127.0.0.1", "listen_port": 23456, "padding_scheme": scheme},
  {"id": 0, "type": "vless", "tag": "vless", "enable": True, "tls_id": 0,
   "listen": "127.0.0.1", "listen_port": 23457},
  {"id": 0, "type": "hysteria2", "tag": "hysteria2", "enable": True, "tls_id": 0,
   "listen": "127.0.0.1", "listen_port": 23458},
  {"id": 0, "type": "tuic", "tag": "tuic", "enable": True, "tls_id": 0,
   "listen": "127.0.0.1", "listen_port": 23459, "congestion_control": "cubic"},
  {"id": 0, "type": "vmess", "tag": "vmess", "enable": True, "tls_id": 0,
   "listen": "127.0.0.1", "listen_port": 23460},
  {"id": 0, "type": "trojan", "tag": "trojan", "enable": True, "tls_id": 0,
   "listen": "127.0.0.1", "listen_port": 23461},
  {"id": 0, "type": "shadowsocks", "tag": "shadowsocks", "enable": True, "tls_id": 0,
   "listen": "127.0.0.1", "listen_port": 23462,
   "method": "2022-blake3-aes-128-gcm", "password": sspw},
]
for ib in inbounds:
    if ib["type"] in ("anytls", "vless", "hysteria2", "tuic", "trojan"):
        ib["tls_id"] = tls_id
    json.dump(ib, open(f"inbound-{ib['tag']}.json", "w"))
json.dump({"uuid": uuid, "sspw": sspw}, open("creds.json", "w"))
EOF

for tag in anytls vless hysteria2 tuic vmess trojan shadowsocks; do
  echo "SMOKE save inbound $tag: $(curl -s -b $JAR -X POST $BASE/api/save -H "$XHDR" \
    --data-urlencode object=inbounds --data-urlencode action=new \
    --data-urlencode data@inbound-$tag.json)"
done

curl -s -b $JAR $BASE/api/inbounds > inbounds.json
IDS=$(python3 -c 'import json; d=json.load(open("inbounds.json")); o=(d.get("obj") or {}).get("inbounds") or []; print(json.dumps([x["id"] for x in o]))' 2>/dev/null || echo "[]")
echo "SMOKE inbound ids: $IDS"

python3 - "$UUID" "$SSPW" "$IDS" <<'EOF' > client-data.json
import json, sys
uuid, sspw, ids = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
print(json.dumps({"id": 0, "enable": True, "name": "smoke",
  "config": {
    "anytls": {"name": "smoke", "password": "smoke-pass-123"},
    "vless": {"name": "smoke", "uuid": uuid},
    "hysteria2": {"name": "smoke", "password": "smoke-pass-123"},
    "tuic": {"name": "smoke", "uuid": uuid, "password": "smoke-pass-123"},
    "vmess": {"name": "smoke", "uuid": uuid, "alterId": 0},
    "trojan": {"name": "smoke", "password": "smoke-pass-123"},
    "shadowsocks16": {"name": "smoke", "password": sspw}},
  "inbounds": ids, "links": []}))
EOF
echo "SMOKE save client: $(curl -s -b $JAR -X POST $BASE/api/save -H "$XHDR" \
  --data-urlencode object=clients --data-urlencode action=new \
  --data-urlencode data@client-data.json)"

echo "SMOKE restartSb: $(curl -s -b $JAR -X POST $BASE/api/restartSb -H "$XHDR")"
sleep 3
for p in 23456 23457 23458 23459 23460 23461 23462; do
  if ss -tuln | grep -q ":$p "; then echo "SMOKE port $p listening: yes"; else echo "SMOKE port $p listening: NO"; fi
done

curl -s -b $JAR $BASE/api/inbounds > inbounds-after.json
echo "SMOKE inbounds after client + restart (users attached):"
python3 -c 'import json; d=json.load(open("inbounds-after.json")); o=(d.get("obj") or {}).get("inbounds") or []; [print("  ", i.get("type"), i.get("tag"), "tls_id:", i.get("tls_id"), "users:", i.get("users")) for i in o]' 2>/dev/null || head -c 400 inbounds-after.json
echo

# Standalone client of the same core version; one tunnel per protocol.
SB="$SB_VERSION"
curl -sL -o sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/$SB/sing-box-${SB#v}-linux-amd64.tar.gz"
tar xzf sb.tar.gz --strip-components=1 "sing-box-${SB#v}-linux-amd64/sing-box" 2>/dev/null
if [ -x ./sing-box ]; then
  ./sing-box version
  TLSCLI='"tls": {"enabled": true, "server_name": "localhost", "insecure": true}'
  run_proto() {
    local name="$1" port="$2" outbound="$3"
    local cfg="{\"log\": {\"level\": \"warn\"}, \"inbounds\": [{\"type\": \"mixed\", \"listen\": \"127.0.0.1\", \"listen_port\": 11080}], \"outbounds\": [$outbound], \"route\": {\"final\": \"out\"}}"
    echo "$cfg" > "client-$name.json"
    ./sing-box check -c "client-$name.json" 2> "client-$name.check.log"
    echo "SMOKE $name config check exit: $? $(head -c 200 client-$name.check.log)"
    ./sing-box run -c "client-$name.json" > "client-$name.log" 2>&1 &
    sleep 2
    local h1 h2
    h1=$(curl -s -m 10 -x socks5h://127.0.0.1:11080 -o /dev/null -w "%{http_code}" http://example.com)
    h2=$(curl -s -m 10 -x socks5h://127.0.0.1:11080 -o /dev/null -w "%{http_code}" https://example.com)
    echo "SMOKE TUNNEL $name: http=$h1 https=$h2"
    pkill -f "sing-box run" 2>/dev/null; sleep 1
  }
  run_proto anytls 23456 "{\"type\": \"anytls\", \"tag\": \"out\", \"server\": \"127.0.0.1\", \"server_port\": 23456, \"password\": \"smoke-pass-123\", $TLSCLI}"
  run_proto vless 23457 "{\"type\": \"vless\", \"tag\": \"out\", \"server\": \"127.0.0.1\", \"server_port\": 23457, \"uuid\": \"$UUID\", $TLSCLI}"
  run_proto hysteria2 23458 "{\"type\": \"hysteria2\", \"tag\": \"out\", \"server\": \"127.0.0.1\", \"server_port\": 23458, \"password\": \"smoke-pass-123\", $TLSCLI}"
  run_proto tuic 23459 "{\"type\": \"tuic\", \"tag\": \"out\", \"server\": \"127.0.0.1\", \"server_port\": 23459, \"uuid\": \"$UUID\", \"password\": \"smoke-pass-123\", \"congestion_control\": \"cubic\", $TLSCLI}"
  run_proto vmess 23460 "{\"type\": \"vmess\", \"tag\": \"out\", \"server\": \"127.0.0.1\", \"server_port\": 23460, \"uuid\": \"$UUID\", \"alter_id\": 0, \"security\": \"auto\"}"
  run_proto trojan 23461 "{\"type\": \"trojan\", \"tag\": \"out\", \"server\": \"127.0.0.1\", \"server_port\": 23461, \"password\": \"smoke-pass-123\", $TLSCLI}"
  run_proto shadowsocks 23462 "{\"type\": \"shadowsocks\", \"tag\": \"out\", \"server\": \"127.0.0.1\", \"server_port\": 23462, \"method\": \"2022-blake3-aes-128-gcm\", \"password\": \"$SSPW:$SSPW\"}"
else
  echo "SMOKE: standalone sing-box download failed"
fi

echo "SMOKE panel log tail:"
tail -30 panel.log
exit 0
