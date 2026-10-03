from playwright.sync_api import sync_playwright
import time
U='https://vanwidick.github.io/timeclock-live-lite/?v='+str(int(time.time()))
with sync_playwright() as p:
    b=p.chromium.launch(channel='chrome',headless=True); c=b.new_context(viewport={'width':360,'height':780},device_scale_factor=3,is_mobile=True)
    pg=c.new_page(); errs=[]; api=[]; pg.on('pageerror',lambda e:errs.append(str(e))); pg.on('dialog',lambda d:d.accept())
    pg.on('request',lambda r: 'api.github.com' in r.url and api.append(r.method+' '+r.url.split('?')[0]))
    r=pg.goto(U); pg.wait_for_timeout(2500)
    print('status',r.status,'| footer',repr(pg.inner_text('footer')))
    print('sw cache',pg.evaluate("navigator.serviceWorker.ready.then(()=>caches.keys())"))
    print('sync label',pg.inner_text('#syncLbl'),'|',pg.inner_text('#syncSt'),'| repo field',pg.input_value('#syncRepo'))
    print('api calls before token (should be none):',api)
    pg.fill('#syncTok','github_pat_FAKE_not_a_real_token_000000'); pg.click('#bSyncSave'); pg.wait_for_timeout(3000)
    print('after fake token:',pg.inner_text('#syncLbl'),'|',pg.inner_text('#syncSt'),'| api calls:',api)
    pg.click('#bSyncOff'); pg.wait_for_timeout(300); print('after disconnect:',pg.inner_text('#syncLbl'),'| cfg',pg.evaluate("localStorage.getItem('tcl-sync-cfg')"))
    print('errors',errs); pg.screenshot(path='/workspace/timeclock-lite/test/live-v1.2.0.png',full_page=True)
