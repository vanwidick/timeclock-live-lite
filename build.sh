#!/bin/sh
# Rebuild index.html from src/index.src.html, embedding the subset Oswald Bold woff2 (src/oswald-700-subset.woff2).
cd "$(dirname "$0")"
python3 - <<'PY'
import base64
f=base64.b64encode(open('src/oswald-700-subset.woff2','rb').read()).decode()
s=open('src/index.src.html',encoding='utf-8').read().replace('__FONT__',f)
open('index.html','w',encoding='utf-8').write(s)
print('index.html', len(s), 'bytes')
PY
