#!/usr/bin/env python3
"""Embed Sparkle preserving symlinks and sign nested code inside out."""
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
bundle, identity = pathlib.Path(sys.argv[1]), sys.argv[2]
source = root / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
assert source.is_dir(), 'Resolve the pinned Sparkle package before packaging'
framework = bundle / 'Contents/Frameworks/Sparkle.framework'
if framework.exists():
    shutil.rmtree(framework)
framework.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(source, framework, symlinks=True)
version = framework / 'Versions/B'
components = [version / 'Autoupdate', version / 'Updater.app',
              version / 'XPCServices/Downloader.xpc', version / 'XPCServices/Installer.xpc', framework]
for component in components:
    command = ['codesign', '--force', '--sign', identity]
    if identity != '-':
        command += ['--options', 'runtime', '--timestamp']
    subprocess.run(command + [str(component)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(framework)], check=True)
