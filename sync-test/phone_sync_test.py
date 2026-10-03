"""Phone <-> cloud <-> PC round trip: Playwright phone app + mock GitHub API + the real pc/TimeClockSync.ps1 (Linux pwsh)."""
import json, subprocess, time, os, tempfile, base64, urllib.request
from datetime import datetime, timezone
from playwright.sync_api import sync_playwright
ROOT='/workspace/timeclock-lite'; API='http://127.0.0.1:18790'; RP='/repos/vanwidick/timeclock-sync/contents/timeclock-sync.json'
mock=subprocess.Popen(['python3',ROOT+'/sync-test/mock_github.py','18790'])
web=subprocess.Popen(['python3','-m','http.server','8799','--bind','127.0.0.1'],cwd=ROOT,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); time.sleep(1)
res=[]
def chk(n,c,x=''): res.append(bool(c)); print(('PASS ' if c else 'FAIL ')+n+(' :: '+str(x) if x!='' else ''))
def remote():
    d=json.loads(urllib.request.urlopen(API+'/_dump').read()); t=d['files'].get(RP); return json.loads(t) if t else None
T=tempfile.mkdtemp(); DATA=T+'/timeclock-data.json'
open(DATA,'w').write('{\n    "app":  "TimeClock Live",\n    "alerts":  { "topic": "timeclock-van-SECRETTOPIC" },\n    "punches":  {"2026-10-02":[["in",28800],["lo",41400],["li",43200],["out",59400]],"2026-10-03":[["in",28800]]},\n    "days":  { }\n}')
def pc(*extra):
    r=subprocess.run(['/workspace/.pwsh/pwsh','-NoProfile','-File',ROOT+'/pc/TimeClockSync.ps1','-Once','-DataPath',DATA,'-StateDir',T+'/state','-ApiBase',API,*extra],env={**os.environ,'TCSYNC_TOKEN':'test-token-0123456789abcdef'},capture_output=True,text=True)
    if r.returncode: print(r.stdout,r.stderr)
    return r.returncode
def filep(): return json.load(open(DATA))['punches']
try:
  pc(); chk('PC pushed desktop punches to cloud',remote()['punches']['2026-10-03']==[['in',28800]])
  with sync_playwright() as p:
    b=p.chromium.launch(channel='chrome',headless=True)
    ctx=b.new_context(viewport={'width':360,'height':780},device_scale_factor=3,is_mobile=True,has_touch=True,service_workers='block',accept_downloads=True)
    pg=ctx.new_page(); errs=[]; pg.on('pageerror',lambda e:errs.append(str(e))); pg.on('dialog',lambda d:d.accept())
    pg.clock.install(time=datetime(2026,10,3,14,30,tzinfo=timezone.utc)); pg.clock.resume()   # 9:30 AM CT
    pg.goto('http://127.0.0.1:8799/index.html'); pg.wait_for_timeout(300)
    chk('sync card off by default',pg.inner_text('#syncLbl').upper()=='OFF')
    pg.evaluate("localStorage.setItem('tcl-sync-cfg',JSON.stringify({api:%r}))"%API)  # test-only API base override
    pg.fill('#syncTok','wrong-token-xxxxxxxxxxxxxxxx'); pg.click('#bSyncSave'); pg.wait_for_timeout(800)
    chk('bad token shows error',pg.inner_text('#syncLbl').upper()=='ERROR' and '401' in pg.inner_text('#syncSt'),pg.inner_text('#syncSt'))
    pg.click('#bSyncOff'); pg.evaluate("localStorage.setItem('tcl-sync-cfg',JSON.stringify({api:%r}))"%API)
    pg.fill('#syncTok','test-token-0123456789abcdef'); pg.click('#bSyncSave'); pg.wait_for_timeout(800)
    chk('connected',pg.inner_text('#syncLbl').upper()=='ON',pg.inner_text('#syncSt'))
    btns=lambda: pg.eval_on_selector_all('#acts .btn','e=>e.map(x=>x.textContent)')
    chk('phone pulled PC clock-in (shows break/lunch/out)',btns()==['Break 1 Start','Lunch Out','Clock Out'],btns())
    chk('token not shown/kept in input',pg.input_value('#syncTok')=='' and not pg.is_visible('#syncTok'))
    pg.click('text=Break 1 Start'); pg.wait_for_timeout(1500)
    rp=remote()['punches']['2026-10-03']; chk('phone punch pushed to cloud',[e[0] for e in rp]==['in','bs'],rp)
    chk('cloud doc marked by phone',remote()['by']=='phone')
    pc(); chk('desktop running (default live mode): phone break written into data file',[e[0] for e in filep()['2026-10-03']]==['in','bs'],filep()['2026-10-03'])
    chk('alerts.topic still in file and never in cloud','SECRETTOPIC' in open(DATA).read() and 'SECRET' not in json.dumps(remote()))
    # desktop (closed->reopened) ends the break; PC sync pushes; phone pulls
    j=json.load(open(DATA)); j['punches']['2026-10-03'].append(['be',35100]); s=open(DATA).read()
    old='"2026-10-03":'+json.dumps(filep()['2026-10-03'],separators=(',',':')); assert old in s
    open(DATA,'w').write(s.replace(old,'"2026-10-03":'+json.dumps(j['punches']['2026-10-03'],separators=(',',':'))))
    pc(); pg.click('#bSyncNow'); pg.wait_for_timeout(1000)
    chk('desktop Break End reached phone',btns()==['Break 2 Start','Lunch Out','Clock Out'],btns())
    chk('phone timeline shows PC punch','Break 1 End' in pg.inner_text('#tl'))
    # phone undo of Break 1 End -> cloud -> PC file
    pg.click('#bUndo'); pg.click('#bUndo'); pg.wait_for_timeout(1500)
    chk('undo synced to cloud',[e[0] for e in remote()['punches']['2026-10-03']]==['in','bs'])
    pc(); chk('undo reached PC file',[e[0] for e in filep()['2026-10-03']]==['in','bs'],filep()['2026-10-03'])
    chk('footer v1.2.1',pg.inner_text('footer').endswith('v1.2.1 · Oct 3, 2026'),pg.inner_text('footer'))
    with pg.expect_download() as d: pg.click('#bExport')
    chk('token not in export',b'test-token-0123456789abcdef' not in open(d.value.path(),'rb').read())
    chk('history day from PC visible on phone','Fri 10/2\n8:00' in pg.inner_text('#hist'),pg.inner_text('#hist'))
    pg.screenshot(path=ROOT+'/sync-test/phone-synced.png',full_page=True)
    chk('no JS errors',not errs,errs)
    b.close()
finally:
  mock.terminate(); web.terminate()
print('ALL PASS' if all(res) else 'SOME FAILED')
