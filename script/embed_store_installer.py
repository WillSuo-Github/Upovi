#!/usr/bin/env python3
"""Give the privileged Store installer a signed application identity for App Management consent."""
import pathlib
import plistlib
import shutil
import subprocess
import sys

bundle = pathlib.Path(sys.argv[1])
identity = sys.argv[2]
helper = bundle / 'Contents/Helpers/UpoviStoreInstaller.app'
if helper.exists():
    shutil.rmtree(helper)
executable = helper / 'Contents/MacOS/UpoviStoreInstaller'
executable.parent.mkdir(parents=True)
shutil.copy2(bundle / 'Contents/MacOS/UpoviStoreInstaller', executable)
info = dict(CFBundleIdentifier='app.upovi.StoreInstaller', CFBundleExecutable='UpoviStoreInstaller',
            CFBundleName='Upovi Installer', CFBundleDisplayName='Upovi Installer', CFBundlePackageType='APPL',
            CFBundleShortVersionString='1.0', CFBundleVersion='1', LSMinimumSystemVersion='14.0', LSUIElement=True)
(helper / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
args = ['/usr/bin/codesign', '--force', '--identifier', 'app.upovi.StoreInstaller', '--sign', identity]
if identity != '-':
    args += ['--options', 'runtime', '--timestamp']
subprocess.run(args + [str(helper)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--all-architectures', str(helper)], check=True)
