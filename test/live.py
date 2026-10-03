from playwright.sync_api import sync_playwright
U='https://vanwidick.github.io/timeclock-live-lite/'
with sync_playwright() as p:
    b=p.chromium.launch(channel='chrome',headless=True); c=b.new_context(viewport={'width':360,'height':780},device_scale_factor=3,is_mobile=True)
    pg=c.new_page(); errs=[]; pg.on('pageerror',lambda e:errs.append(str(e)))
    r=pg.goto(U); pg.wait_for_timeout(1500)
    print('status',r.status,'title',pg.title()); print('footer',repr(pg.inner_text('footer'))); print('buttons',pg.eval_on_selector_all('#acts .btn','e=>e.map(x=>x.textContent)'))
    print('manifest',pg.evaluate("fetch('manifest.webmanifest').then(r=>r.status)"),'sw',pg.evaluate("navigator.serviceWorker.ready.then(r=>r.active&&r.active.scriptURL)"))
    pg.reload(); pg.wait_for_timeout(800); c.set_offline(True); pg.reload(); pg.wait_for_timeout(500); print('offline footer',pg.inner_text('footer').split('\n')[0]); print('errors',errs)
    c.set_offline(False); pg.screenshot(path='/workspace/timeclock-lite/test/live.png')
