# Builds ../TimeClockSync-PC.zip (TimeClockSync/{TimeClockSync.ps1, Install-TimeClockSync.ps1, README.txt}) with CRLF line endings.
import zipfile, os
here = os.path.dirname(os.path.abspath(__file__)); out = os.path.join(here, '..', 'TimeClockSync-PC.zip')
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for f in ('TimeClockSync.ps1', 'Install-TimeClockSync.ps1', 'README.txt'):
        data = open(os.path.join(here, f), 'rb').read().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
        assert all(b < 128 for b in data), f + ' must stay ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)'
        z.writestr('TimeClockSync/' + f, data)
print(out)
