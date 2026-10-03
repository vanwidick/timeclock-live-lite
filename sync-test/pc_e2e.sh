#!/bin/bash
# End-to-end test of pc/TimeClockSync.ps1 v1.1 (live writes) against the mock API. Runs on Linux pwsh.
set -u; cd "$(dirname "$0")"; PW=/workspace/.pwsh/pwsh; T=$(mktemp -d); PORT=18791; pass=0; fail=0; TOK=test-token-0123456789abcdef
python3 mock_github.py $PORT & SRV=$!; sleep 0.7; trap "kill $SRV 2>/dev/null" EXIT
API=http://127.0.0.1:$PORT; RP=/repos/vanwidick/timeclock-sync/contents/timeclock-sync.json; D=$T/timeclock-data.json
chk(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
cat > $D <<'J'
{
    "app":  "TimeClock Live",
    "version":  "1.0.2",
    "saved":  "2026-10-03 08:00:05",
    "profile":  { "start": "08:00", "breaks": [ { "label": "Break 1", "start": "09:30" } ] },
    "pto":  { "startBalance": 12.5, "entries": [ ] },
    "alerts":  { "ntfyOn": true, "topic": "timeclock-van-SECRETTOPIC123", "server": "https://ntfy.sh" },
    "display":  { "on": true },
    "sync":  { "on": true, "topic": "tcsync-SECRETSYNC456" },
    "punches":  {"2026-10-02":[["in",28800],["lo",41400],["li",43200],["out",59400]],"2026-10-03":[["in",28800]]},
    "days":  { "2026-10-03": { "clockIn": "08:00:00", "breakCount": 0, "workedMin": 0 } }
}
J
run(){ TCSYNC_TOKEN=$TOK $PW -NoProfile -File ../pc/TimeClockSync.ps1 -Once -DataPath $D -StateDir $T/state -ApiBase $API "$@"; }
dump(){ curl -s $API/_dump | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['files'].get('$RP',''))"; }
stat(){ curl -s $API/_dump | python3 -c "import json,sys;print(json.load(sys.stdin)['stats']['$1'])"; }
phone(){ python3 - $API $RP $TOK "$1" <<'P'
import json,sys,urllib.request,base64
api,rp,tok,code=sys.argv[1:5]; H={'Authorization':'Bearer '+tok}
cur=json.loads(urllib.request.urlopen(urllib.request.Request(api+rp,headers=H)).read()); j=json.loads(base64.b64decode(cur['content'])); p=j['punches']
exec(code); j['by']='phone'
body=json.dumps({'message':'phone','content':base64.b64encode(json.dumps(j).encode()).decode(),'sha':cur['sha']}).encode()
urllib.request.urlopen(urllib.request.Request(api+rp,data=body,method='PUT',headers={**H,'Content-Type':'application/json'}))
P
}
others(){ python3 -c "import json,sys;j=json.load(open('$D'));j.pop('punches');print(json.dumps(j,sort_keys=True))"; }
nonpunch(){ python3 -c "import re;print(re.sub(r'\"punches\"\s*:\s*\{[^{}]*\}','P',open('$D',encoding='utf-8').read()),end='')"; }
NP0=$(nonpunch)
run
R=$(dump); chk "first run pushes desktop punches" '[[ "$R" == *"\"2026-10-03\":[[\"in\",28800]]"* ]]'
chk "cloud has only punches (no topics/profile/pto)" '[[ "$R" != *SECRET* && "$R" != *profile* && "$R" != *pto* ]]'
P0=$(stat put); G0=$(stat get304); TCSYNC_TOKEN=$TOK $PW -NoProfile -File ../pc/TimeClockSync.ps1 -Cycles 3 -IntervalSec 1 -DataPath $D -StateDir $T/state -ApiBase $API; chk "idle cycles: no push" '[[ $(stat put) == $P0 ]]'
echo "  (304s: $(( $(stat get304) - G0 )))"; chk "idle cycles use conditional GET (304, not rate-limited)" '[[ $(( $(stat get304) - G0 )) -ge 2 ]]'
phone "p['2026-10-03'].append(['bs',34200])"
run   # default -FileWrite Always: desktop may be running
F=$(cat $D)
chk "LIVE: phone punch written while desktop runs" '[[ "$F" == *"\"2026-10-03\":[[\"in\",28800],[\"bs\",34200]]"* ]]'
chk "rule 1: every non-punch byte unchanged (profile/pto/alerts/display/sync/days)" '[[ "$(nonpunch)" == "$NP0" ]]'
chk "rule 4: format \"punches\": {\"yyyy-MM-dd\":[[\"in\",n],...]}" 'python3 -c "
import json,re;p=json.load(open(\"$D\"))[\"punches\"]
assert all(re.fullmatch(r\"\d{4}-\d{2}-\d{2}\",k) and all(e[0] in (\"in\",\"out\",\"bs\",\"be\",\"lo\",\"li\") and type(e[1]) is int and 0<=e[1]<=86399 for e in v) for k,v in p.items())"'
chk "rule 2: no temp file left, .bak is valid JSON (previous version)" '[[ ! -e $D.lite.tmp ]] && python3 -c "import json;json.load(open(\"$D.bak\"))"'
chk "file is UTF-8 without BOM" 'python3 -c "import sys;sys.exit(open(\"$D\",\"rb\").read(3)==b\"\\xef\\xbb\\xbf\")"'
P1=$(stat put); run; chk "rule 7: own write not pushed back" '[[ $(stat put) == $P1 ]]'
# desktop v1.0.2 reloads and re-saves (same punches, new saved stamp + days) -> no push
python3 - $D <<'P'
import sys;p=sys.argv[1];s=open(p).read().replace('"saved":  "2026-10-03 08:00:05"','"saved":  "2026-10-03 09:30:01"').replace('"breakCount": 0','"breakCount": 1');open(p,'w').write(s)
P
run; chk "rule 7: desktop re-save with same punches -> no push" '[[ $(stat put) == $P1 ]]'
# desktop ends break, phone starts lunch at the same time -> both kept
python3 - $D <<'P'
import sys;p=sys.argv[1];s=open(p).read().replace('[["in",28800],["bs",34200]]','[["in",28800],["bs",34200],["be",35100]]');open(p,'w').write(s)
P
phone "p['2026-10-03'].append(['lo',41400])"
run
R=$(dump); F=$(cat $D)
chk "rule 3: concurrent desktop + phone punches merged in cloud" '[[ "$R" == *"[[\"in\",28800],[\"bs\",34200],[\"be\",35100],[\"lo\",41400]]"* ]]'
chk "rule 3: ...and in the file" '[[ "$F" == *"[[\"in\",28800],[\"bs\",34200],[\"be\",35100],[\"lo\",41400]]"* ]]'
# phone undo of lunch -> removed from file (truly deleted), other punches kept
phone "p['2026-10-03']=[e for e in p['2026-10-03'] if e[0]!='lo']"
run; F=$(cat $D); chk "phone undo removes exactly that punch from file" '[[ "$F" == *"\"2026-10-03\":[[\"in\",28800],[\"bs\",34200],[\"be\",35100]]"* ]]'
# rule 4: both devices start break 2 a few seconds apart (+ a 3rd break) -> max 2 breaks
python3 - $D <<'P'
import sys;p=sys.argv[1];s=open(p).read().replace('[["in",28800],["bs",34200],["be",35100]]','[["in",28800],["bs",34200],["be",35100],["bs",50400]]');open(p,'w').write(s)
P
phone "p['2026-10-03']+= [['bs',50404]]"
run; F=$(cat $D); R=$(dump)
chk "rule 4: duplicate break-2 start trimmed to max 2 breaks (file)" '[[ "$F" == *"\"2026-10-03\":[[\"in\",28800],[\"bs\",34200],[\"be\",35100],[\"bs\",50400]]"* ]]'
chk "rule 4: ...and cloud" '[[ "$R" == *"\"2026-10-03\":[[\"in\",28800],[\"bs\",34200],[\"be\",35100],[\"bs\",50400]]"* ]]'
chk "rule 1 still holds after many writes (only saved/breakCount changed by desktop)" '[[ "$(nonpunch)" == "$(echo "$NP0" | sed "s/08:00:05/09:30:01/; s/\"breakCount\": 0/\"breakCount\": 1/")" ]]'
# rule 3 race: the desktop saves a punch between our read and our write -> re-read, re-merge, nothing lost
cat > $T/hook.ps1 <<H
\$p = '$D'; \$s = [IO.File]::ReadAllText(\$p); \$s = \$s.Replace('["bs",50400]]', '["bs",50400],["be",51000]]'); [IO.File]::WriteAllText(\$p + '.x', \$s); Move-Item -Force (\$p + '.x') \$p
H
phone "p['2026-10-04']=[['in',28800]]"
run -TestPreWriteHook $T/hook.ps1; F=$(cat $D); R=$(dump)
chk "rule 3 race: desktop punch saved mid-sync kept in file" '[[ "$F" == *"[\"bs\",50400],[\"be\",51000]]"* && "$F" == *"\"2026-10-04\":[[\"in\",28800]]"* ]]'
chk "rule 3 race: ...and pushed to cloud" '[[ "$R" == *"[\"bs\",50400],[\"be\",51000]]"* && "$R" == *"\"2026-10-04\""* ]]'
# undo the race punch for the following steps
python3 - $D <<'P'
import sys;p=sys.argv[1];s=open(p).read().replace('["bs",50400],["be",51000]]','["bs",50400]]');open(p,'w').write(s)
P
run
# legacy mode still available
phone "p['2026-10-03']+= [['be',51300]]"
cp $D $T/before.json; run -FileWrite WhenClosed -AssumeDesktopRunning
chk "legacy -FileWrite WhenClosed + running: file untouched" 'cmp -s $D $T/before.json'
run; chk "back to default: queued punch written" '[[ "$(cat $D)" == *"[\"bs\",50400],[\"be\",51300]]"* ]]'
chk "log has no token/topic" '! grep -qE "$TOK|SECRET" $T/state/sync-log.txt'
cp $D $T/before2.json
TCSYNC_TOKEN=wrong $PW -NoProfile -File ../pc/TimeClockSync.ps1 -Once -DataPath $D -StateDir $T/state -ApiBase $API >/dev/null 2>&1; RC=$?
chk "bad token: fails, file untouched" '[[ $RC -ne 0 ]] && cmp -s $D $T/before2.json'
echo "pc e2e: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
