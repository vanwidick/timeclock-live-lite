#!/bin/sh
# Rebuild index.html from src/index.src.html: embeds the subset Oswald Bold woff2 and inlines src/merge.js.
cd "$(dirname "$0")"
python3 - <<'PY'
import base64
f=base64.b64encode(open('src/oswald-700-subset.woff2','rb').read()).decode()
m=open('src/merge.js',encoding='utf-8').read().replace('if (typeof module !== "undefined") module.exports = { tcMerge3, tcLimitBreaks, tcPunchJson };','')
s=open('src/index.src.html',encoding='utf-8').read().replace('__FONT__',f).replace('/*__MERGE__*/',m)
open('index.html','w',encoding='utf-8').write(s)
print('index.html', len(s), 'bytes')
PY
