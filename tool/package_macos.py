"""复制 macOS 应用、校验签名并创建可拖入 Applications 的测试 DMG。"""

from pathlib import Path
import hashlib
import json
import plistlib
import subprocess

root = Path(__file__).resolve().parents[1]
app = root / 'build/macos/Build/Products/Release/dianbo.app'
if not app.is_dir():
    raise SystemExit(f'Application missing: {app}')
dist = root / 'dist'
dist.mkdir(exist_ok=True)
stage = root / 'build/dmg-stage'
stage.mkdir(exist_ok=True)
target = stage / '电波表授时.app'
subprocess.run(['ditto', str(app), str(target)], check=True)
applications = stage / 'Applications'
if not applications.exists():
    applications.symlink_to('/Applications')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(target)], check=True)
info = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
binary = target / 'Contents/MacOS' / info['CFBundleExecutable']
archs = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
name = 'Dianbo-macOS.dmg'
subprocess.run(['hdiutil', 'create', '-volname', '电波表授时', '-srcfolder', str(stage), '-ov', '-format', 'UDZO', str(dist / name)], check=True)
subprocess.run(['hdiutil', 'verify', str(dist / name)], check=True)
digest = hashlib.sha256((dist / name).read_bytes()).hexdigest()
(dist / 'SHA256SUMS.txt').write_text(f'{digest}  {name}\n')
metadata = {'version': info['CFBundleShortVersionString'], 'architectures': archs.split(), 'notarized': False, 'sha256': digest}
(dist / 'build-info.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(metadata, ensure_ascii=False))
