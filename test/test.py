import json, subprocess, time, sys, os
from datetime import datetime, timezone
from playwright.sync_api import sync_playwright
ROOT='/workspace/timeclock-lite'
srv=subprocess.Popen(['python3','-m','http.server','8799','--bind','127.0.0.1'],cwd=ROOT,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); time.sleep(1)
res=[]
def chk(n,c,x=''): res.append(c); print(('PASS ' if c else 'FAIL ')+n+(' :: '+str(x) if x!='' else ''))
def T(h,m,s=0): return datetime(2026,10,3,h+5,m,s,tzinfo=timezone.utc)  # CDT = UTC-5
try:
  with sync_playwright() as p:
    b=p.chromium.launch(channel='chrome',headless=True)
    ctx=b.new_context(viewport={'width':360,'height':780},device_scale_factor=3,is_mobile=True,has_touch=True,accept_downloads=True,service_workers='block')
    pg=ctx.new_page(); errs=[]; pg.on('pageerror',lambda e:errs.append(str(e))); pg.on('console',lambda m: m.type=='error' and errs.append(m.text))
    pg.on('dialog',lambda d:d.accept())
    pg.clock.install(time=T(7,58))
    # seed history: previous days of this pay period (desktop-format punches)
    seed={"2026-09-28":[["in",28800],["bs",34200],["be",35100],["lo",41400],["li",43200],["bs",50400],["be",51300],["out",59400]],
          "2026-09-29":[["in",28920],["bs",34200],["be",35100],["lo",41400],["li",43200],["out",59400]],
          "2026-09-30":[["in",28800],["lo",41400],["li",43200],["out",59400]],
          "2026-10-01":[["in",28800],["lo",41400],["li",43200],["out",57600]],
          "2026-10-02":[["in",28800],["lo",41400],["li",43200],["out",59400]],
          "2026-09-25":[["in",28800],["out",57600]]}
    pg.add_init_script("if(!localStorage.getItem('punches'))localStorage.setItem('punches',%s)"%json.dumps(json.dumps(seed)))
    pg.goto('http://127.0.0.1:8799/index.html'); pg.wait_for_timeout(300)
    btns=lambda: pg.eval_on_selector_all('#acts .btn','e=>e.map(x=>x.textContent)')
    chk('start shows only Clock In',btns()==['Clock In'],btns())
    chk('footer',pg.inner_text('footer')=='DESIGN BY VAN\nv1.2.0 · Oct 3, 2026',pg.inner_text('footer'))
    chk('footer font Oswald',pg.evaluate("document.fonts.check('700 30px OswaldTC')"))
    chk('pay period range',pg.inner_text('#ppRange')=='9/26/2026 – 10/9/2026',pg.inner_text('#ppRange'))
    # 9/28 8:00-16:30 minus 30 lunch = 8:00; 9/29 7:58->... (8:02-16:30 -30)=7:58 ; 9/30 8:00; 10/1 7:30; 10/2 8:00 => 39:28
    chk('pay period total pre',pg.inner_text('#ppTot')=='39:28',pg.inner_text('#ppTot'))
    pg.click('text=Clock In'); pg.wait_for_timeout(100)
    chk('after in: break1/lunch/out',btns()==['Break 1 Start','Lunch Out','Clock Out'],btns())
    pg.clock.run_for(92*60*1000)  # 9:30
    pg.click('text=Break 1 Start'); pg.wait_for_timeout(50)
    chk('on break only End',btns()==['Break 1 End'],btns())
    panel=lambda: {k:pg.inner_text('#'+k) for k in ('cdTitle','cdOut','cdDue','cdLeft','cdElapsed','cdLeftLbl')}
    bb=pg.locator('#cd').bounding_box(); hb=pg.locator('header').bounding_box()
    chk('panel visible at very top (above header)',pg.is_visible('#cd') and bb['y']<15 and bb['y']<hb['y'],(bb,hb))
    pv=panel(); chk('panel break 1 label/left/due',pv['cdTitle']=='ON BREAK 1' and pv['cdLeft'] in ('15:00','14:59') and pv['cdOut']=='9:30 AM' and pv['cdDue']=='9:45 AM' and pv['cdLeftLbl']=='TIME LEFT',pv)
    chk('stopwatch starts ~0:00',pv['cdElapsed'] in ('0:00','0:01'),pv['cdElapsed'])
    pg.clock.run_for(65*1000); pv=panel()
    chk('stopwatch counts up 1:05',pv['cdElapsed'] in ('1:05','1:06'),pv)
    chk('countdown counts down 13:55',pv['cdLeft'] in ('13:55','13:54'),pv)
    pg.mouse.wheel(0,3000); pg.wait_for_timeout(200); bb=pg.locator('#cd').bounding_box()
    chk('panel stays pinned at top when scrolled',pg.evaluate('scrollY')>100 and -1<=bb['y']<15,(pg.evaluate('scrollY'),bb))
    pg.mouse.wheel(0,-3000); pg.wait_for_timeout(200)
    pg.clock.run_for(12*60*1000+5000-65*1000)
    chk('warn at <=3 min',pg.get_attribute('#cd','class')=='on warn',(pg.get_attribute('#cd','class'),pg.inner_text('#cdLeft')))
    pg.screenshot(path=ROOT+'/test/break-warn.png')
    pg.clock.run_for(3*60*1000)
    chk('late at zero',pg.get_attribute('#cd','class')=='on late',(pg.get_attribute('#cd','class'),pg.inner_text('#cdLeft')))
    pv=panel(); chk('late shows red LATE +m:ss',pv['cdLeft'] in ('LATE +0:05','LATE +0:06') and pv['cdLeftLbl']=='PAST DUE' and pv['cdElapsed'] in ('15:05','15:06'),pv)
    chk('late color red',pg.evaluate("getComputedStyle(document.getElementById('cdLeft')).color")=='rgb(255, 107, 107)')
    pg.click('text=Break 1 End')
    chk('after b1: break2/lunch/out',btns()==['Break 2 Start','Lunch Out','Clock Out'],btns())
    chk('panel hidden while working',not pg.is_visible('#cd'))
    # undo test
    pg.click('#bUndo'); chk('undo armed',"Tap again" in pg.inner_text('#bUndo'))
    pg.click('#bUndo'); chk('undo restored break',btns()==['Break 1 End'],btns())
    pg.click('text=Break 1 End')
    pg.clock.run_for(2*3600*1000-15*60*1000)  # ~11:30
    pg.click('text=Lunch Out'); chk('lunch only Lunch In',btns()==['Lunch In'],btns())
    pv=panel(); chk('panel ON LUNCH with due +30',pv['cdTitle']=='ON LUNCH' and pv['cdOut']=='11:30 AM' and pv['cdDue']=='12:00 PM',pv)
    pg.clock.run_for(24*60*1000+30000)
    chk('lunch not warn at 5:30 left','warn' not in pg.get_attribute('#cd','class'),pg.inner_text('#cdLeft'))
    pg.clock.run_for(60*1000)
    chk('lunch warn at <=5',pg.get_attribute('#cd','class')=='on lunch warn',pg.inner_text('#cdLeft'))
    pg.screenshot(path=ROOT+'/test/lunch-warn.png')
    pg.clock.run_for(4*60*1000)
    pg.click('text=Lunch In')
    chk('after lunch: break2/out',btns()==['Break 2 Start','Clock Out'],btns())
    pg.clock.run_for(2*3600*1000)
    pg.click('text=Break 2 Start'); pg.clock.run_for(5*60*1000)
    pv=panel(); chk('panel ON BREAK 2',pv['cdTitle']=='ON BREAK 2' and pv['cdElapsed'] in ('5:00','5:01'),pv)
    pg.wait_for_timeout(1200); pg.screenshot(path=ROOT+'/screenshot.png'); pg.screenshot(path=ROOT+'/test/screenshot-full.png',full_page=True)
    pg.clock.run_for(9*60*1000); pg.click('text=Break 2 End')
    chk('after all: only Clock Out',btns()==['Clock Out'],btns())
    pg.clock.run_for(2*3600*1000)
    pg.click('text=Clock Out'); pg.wait_for_timeout(50)
    chk('after out: Clock Back In',btns()==['Clock Back In'],btns())
    st=json.loads(pg.evaluate("localStorage.getItem('punches')"))['2026-10-03']
    chk('stored format',all(isinstance(e,list) and len(e)==2 and isinstance(e[1],int) for e in st),st)
    tl=pg.inner_text('#tl'); print(tl)
    chk('timeline h:mm AM/PM','7:58 AM' in tl and 'Break 2 End' in tl)
    with pg.expect_download() as d: pg.click('#bExport')
    path=d.value.path(); doc=json.load(open(path))
    chk('export filename',d.value.suggested_filename=='timeclock-data.json')
    chk('export keys',list(doc.keys())==['app','version','saved','punches','days'],list(doc.keys()))
    day=doc['days']['2026-10-03']; print(json.dumps(day))
    chk('summary fields',list(day.keys())==['clockIn','clockOut','break1','break2','lunch','breakCount','workedMin'])
    chk('saved format',len(doc['saved'])==19 and doc['saved'].startswith('2026-10-03 '),doc['saved'])
    chk('worked today = 7:58->16:13:36 minus 29:30 lunch = 466 min',day['workedMin']==pg.evaluate("Math.floor(workedSec('2026-10-03',null)/60)") and day['workedMin']==466,day['workedMin'])
    raw=open(path).read(); chk('punches compact one-line', '"2026-10-03":[["in",' in raw)
    # import roundtrip into a fresh context
    pg2=ctx.new_page(); pg2.on('dialog',lambda d:d.accept())
    pg2.goto('http://127.0.0.1:8799/index.html'); pg2.evaluate("localStorage.clear()"); pg2.reload()
    pg2.set_input_files('#fileIn',path); pg2.wait_for_timeout(300)
    chk('import roundtrip',json.loads(pg2.evaluate("localStorage.getItem('punches')"))==doc['punches'])
    chk('no JS errors',not errs,errs)
    b.close()
    # offline via service worker
    b=p.chromium.launch(channel='chrome',headless=True); c=b.new_context(viewport={'width':360,'height':780})
    q=c.new_page(); q.goto('http://127.0.0.1:8799/'); q.wait_for_function("navigator.serviceWorker.controller!==null || navigator.serviceWorker.ready.then(()=>true)")
    q.reload(); q.wait_for_timeout(800); c.set_offline(True); q.reload(); q.wait_for_timeout(300)
    chk('loads offline via SW',q.inner_text('footer').startswith('DESIGN BY VAN'))
    b.close()
finally: srv.terminate()
print('ALL PASS' if all(res) else 'SOME FAILED')
