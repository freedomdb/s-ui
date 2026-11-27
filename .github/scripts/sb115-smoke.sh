#!/usr/bin/env bash
# Boot the freshly built panel, drive its API to create an AnyTLS inbound and
# a client, restart the core, then run the matching standalone sing-box as a
# client and push real traffic through the tunnel on loopback.
# Best-effort throughout: every stage prints a SMOKE line and keeps going.
set -u
cd "$(dirname "$0")/../.."
mkdir -p run && cd run

[ -x ../sui ] || { echo "SMOKE: panel binary missing, skipping"; exit 0; }
cp ../sui ./sui

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout key.pem -out cert.pem -days 2 -nodes -subj "/CN=localhost" 2>/dev/null
CERT="$PWD/cert.pem"; KEY="$PWD/key.pem"

./sui > panel.log 2>&1 &
PANEL_PID=$!
trap 'kill $PANEL_PID 2>/dev/null; pkill -f "sing-box run" 2>/dev/null' EXIT

ok=""
for i in $(seq 1 30); do
  if curl -s -o /dev/null "http://127.0.0.1:2095/app/"; then ok=1; break; fi
  sleep 1
done
echo "SMOKE panel reachable: ${ok:-NO}"
curl -s -o /dev/null -w "SMOKE panel page HTTP %{http_code}\n" "http://127.0.0.1:2095/app/"

JAR=cookies.txt
echo "SMOKE login: $(curl -s -c $JAR -X POST http://127.0.0.1:2095/app/api/login -d 'user=admin&pass=admin')"
echo "SMOKE status: $(curl -s -b $JAR http://127.0.0.1:2095/app/api/status)"

python3 - "$CERT" "$KEY" > inbound-data.json <<'EOF'
import json, sys
cert, key = sys.argv[1], sys.argv[2]
print(json.dumps({
  "id": 0, "type": "anytls", "tag": "anytls-smoke", "enable": True, "tls_id": 0,
  "listen": "127.0.0.1", "listen_port": 23456,
  "padding_scheme": ["stop=8", "0=30-30", "1=120-450",
    "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
    "3=9-9,500-1000", "4=500-1000", "5=500-1000", "6=500-1000", "7=500-1000"],
  "tls": {"enabled": True, "server_name": "localhost",
          "certificate_path": cert, "key_path": key}
}))
EOF
echo "SMOKE save inbound: $(curl -s -b $JAR -X POST http://127.0.0.1:2095/app/api/save \
  --data-urlencode object=inbounds --data-urlencode action=new \
  --data-urlencode data@inbound-data.json)"

curl -s -b $JAR http://127.0.0.1:2095/app/api/inbounds > inbounds.json
IBID=$(python3 -c 'import json; d=json.load(open("inbounds.json")); o=d.get("obj") or []; print(next((x["id"] for x in o if x.get("tag")=="anytls-smoke"), 0))' 2>/dev/null || echo 0)
echo "SMOKE inbound id: $IBID"
head -c 500 inbounds.json; echo

python3 - "$IBID" > client-data.json <<'EOF'
import json, sys
print(json.dumps({"id": 0, "enable": True, "name": "smoke",
  "config": {"anytls": {"name": "smoke", "password": "smoke-pass-123"}},
  "inbounds": [int(sys.argv[1])]}))
EOF
echo "SMOKE save client: $(curl -s -b $JAR -X POST http://127.0.0.1:2095/app/api/save \
  --data-urlencode object=clients --data-urlencode action=new \
  --data-urlencode data@client-data.json)"

echo "SMOKE restartSb: $(curl -s -b $JAR -X POST http://127.0.0.1:2095/app/api/restartSb)"
sleep 3
if ss -tln | grep -q 23456; then echo "SMOKE anytls port listening: yes"; else echo "SMOKE anytls port listening: NO"; fi

curl -s -b $JAR http://127.0.0.1:2095/app/api/config > config.json
echo "SMOKE generated anytls inbound:"
python3 -c 'import json; d=json.load(open("config.json")); c=d.get("obj") or {}; print(json.dumps([i for i in c.get("inbounds", []) if i.get("type")=="anytls"], indent=1))' 2>/dev/null || head -c 500 config.json
echo

# Standalone client of the same core version, for a real tunnel.
SB="$SB_VERSION"
curl -sL -o sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/$SB/sing-box-${SB#v}-linux-amd64.tar.gz"
tar xzf sb.tar.gz --strip-components=1 "sing-box-${SB#v}-linux-amd64/sing-box" 2>/dev/null
if [ -x ./sing-box ]; then
  ./sing-box version
  cat > client-sb.json <<'EOF'
{"log": {"level": "info"},
 "inbounds": [{"type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": 11080}],
 "outbounds": [{"type": "anytls", "tag": "out", "server": "127.0.0.1", "server_port": 23456,
   "password": "smoke-pass-123",
   "tls": {"enabled": true, "server_name": "localhost", "insecure": true}}],
 "route": {"final": "out"}}
EOF
  ./sing-box check -c client-sb.json; echo "SMOKE client config check exit: $?"
  ./sing-box run -c client-sb.json > client.log 2>&1 &
  sleep 2
  curl -s -m 10 -x socks5h://127.0.0.1:11080 -o /dev/null -w "SMOKE tunnel http://example.com -> %{http_code}\n" http://example.com
  curl -s -m 10 -x socks5h://127.0.0.1:11080 -o /dev/null -w "SMOKE tunnel https://example.com -> %{http_code}\n" https://example.com
  echo "SMOKE client log tail:"; tail -5 client.log
else
  echo "SMOKE: standalone sing-box download failed"
fi

echo "SMOKE panel log tail:"
tail -30 panel.log
exit 0
