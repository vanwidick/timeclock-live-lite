#!/bin/bash
# End-to-end test of pc/TimeClockSync.ps1 against the mock API (runs on Linux pwsh; Windows-only bits are bypassed by test switches).
set -u; cd "$(dirname "$0")"; PW=/workspace/.pwsh/pwsh; T=$(mktemp -d); PORT=18791; pass=0; fail=0
python3 mock_github.py $PORT & SRV=$!; sleep 0.7; trap "kill $SRV" EXIT
API=http://127.0.0.1:$PORT; RP=/repos/vanwidick/timeclock-sync/contents/timeclock-sync.json
chk(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
# desktop-style data file (profile/alerts with a secret topic that must never leave the PC)
cat > $T/timeclock-data.json <<'J'
{
    "app":  "TimeClock Live",
    "version":  "1.0.1",
    "saved":  "2026-10-03 08:00:05",
    "profile":  { "start": "08:00" },
    "alerts":  { "ntfyOn": true, "topic": "timeclock-van-SECRETTOPIC123", "server": "https://ntfy.sh" },
    "sync":  { "on": true, "topic": "tcsync-SECRETSYNC456" },
    "punches":  {"2026-10-02":[["in",28800],["lo",41400],["li",43200],["out",59400]],"2026-10-03":[["in",28800]]},
    "days":  { }
}
J
run(){ TCSYNC_TOKEN=test-token-0123456789abcdef $PW -NoProfile -File ../pc/TimeClockSync.ps1 -Once -DataPath $T/timeclock-data.json -StateDir $T/state -ApiBase $API "$@"; }
dump(){ curl -s $API/_dump | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['files'].get('$RP',''))"; }
run -AssumeDesktopRunning
R=$(dump); chk "first run creates cloud file with PC punches" '[[ "$R" == *"\"2026-10-03\":[[\"in\",28800]]"* ]]'
chk "cloud file has no alerts/sync topics or profile" '[[ "$R" != *SECRET* && "$R" != *profile* ]]'
# phone adds break start in the cloud
python3 - $API $RP <<'P'
import json,sys,urllib.request,base64
api,rp=sys.argv[1],sys.argv[2]
d=json.loads(urllib.request.urlopen(urllib.request.Request(api+'/_dump')).read())['files'][rp]; j=json.loads(d)
j['punches']['2026-10-03'].append(['bs',34200]); j['by']='phone'
r=urllib.request.Request(api+rp,headers={'Authorization':'Bearer test-token-0123456789abcdef'}); cur=json.loads(urllib.request.urlopen(r).read())
body=json.dumps({'message':'phone','content':base64.b64encode(json.dumps(j).encode()).decode(),'sha':cur['sha']}).encode()
urllib.request.urlopen(urllib.request.Request(api+rp,data=body,method='PUT',headers={'Authorization':'Bearer test-token-0123456789abcdef','Content-Type':'application/json'}))
P
cp $T/timeclock-data.json $T/before.json
run -AssumeDesktopRunning
chk "desktop running: data file untouched (phone punch queued)" 'cmp -s $T/timeclock-data.json $T/before.json'
# desktop punches lunch out meanwhile (rewrites file)
sed -i 's/"2026-10-03":\[\["in",28800\]\]/"2026-10-03":[["in",28800],["lo",41400]]/' $T/timeclock-data.json
run -AssumeDesktopRunning
R=$(dump); chk "cloud = PC lunch + phone break merged" '[[ "$R" == *"\"2026-10-03\":[[\"in\",28800],[\"bs\",34200],[\"lo\",41400]]"* ]]'
chk "queued phone punch not treated as a PC deletion" '[[ "$R" == *"[\"bs\",34200]"* ]]'
run -AssumeDesktopClosed
F=$(cat $T/timeclock-data.json)
chk "desktop closed: phone punch written into data file" '[[ "$F" == *"\"2026-10-03\":[[\"in\",28800],[\"bs\",34200],[\"lo\",41400]]"* ]]'
chk "other fields preserved byte-for-byte" '[[ "$F" == *"\"topic\": \"timeclock-van-SECRETTOPIC123\""* && "$F" == *"\"profile\":  { \"start\": \"08:00\" }"* ]]'
chk "data file still valid JSON" 'python3 -c "import json;json.load(open(\"$T/timeclock-data.json\"))"'
chk ".bak written" '[[ -f $T/timeclock-data.json.bak ]]'
# phone undo (removes bs) -> PC removes it too
python3 - $API $RP <<'P'
import json,sys,urllib.request,base64
api,rp=sys.argv[1],sys.argv[2]
r=urllib.request.Request(api+rp,headers={'Authorization':'Bearer test-token-0123456789abcdef'}); cur=json.loads(urllib.request.urlopen(r).read())
j=json.loads(base64.b64decode(cur['content'])); j['punches']['2026-10-03']=[e for e in j['punches']['2026-10-03'] if e[0]!='bs']
body=json.dumps({'message':'phone undo','content':base64.b64encode(json.dumps(j).encode()).decode(),'sha':cur['sha']}).encode()
urllib.request.urlopen(urllib.request.Request(api+rp,data=body,method='PUT',headers={'Authorization':'Bearer test-token-0123456789abcdef','Content-Type':'application/json'}))
P
run -AssumeDesktopClosed
F=$(cat $T/timeclock-data.json); chk "phone undo propagates to PC file" '[[ "$F" == *"\"2026-10-03\":[[\"in\",28800],[\"lo\",41400]]"* ]]'
chk "log has no token/topic" '! grep -qE "test-token-0123456789abcdef|SECRET" $T/state/sync-log.txt'
TCSYNC_TOKEN=wrong $PW -NoProfile -File ../pc/TimeClockSync.ps1 -Once -DataPath $T/timeclock-data.json -StateDir $T/state -ApiBase $API -AssumeDesktopClosed >/dev/null 2>&1; RC=$?
chk "bad token fails without touching file" '[[ $RC -ne 0 ]] && [[ "$(cat $T/timeclock-data.json)" == "$F" ]]'
echo "pc e2e: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
