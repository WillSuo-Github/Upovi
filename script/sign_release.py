#!/usr/bin/env python3
"""Sign the staged distribution bundle inside out, including Sparkle helpers."""
import argparse
import pathlib
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('bundle', type=pathlib.Path)
parser.add_argument('identity')
options = parser.parse_args()
if options.identity == '-':
    parser.error('Distribution signing requires a Developer ID identity.')
bundle = options.bundle.resolve()
framework = bundle / 'Contents/Frameworks/Sparkle.framework'
version = framework / 'Versions/B'
components = [
    (version / 'XPCServices/Installer.xpc', None),
    (version / 'XPCServices/Downloader.xpc', None),
    (version / 'Autoupdate', None),
    (version / 'Updater.app', None),
    (framework, None),
    (bundle / 'Contents/MacOS/UpoviInstaller', 'app.upovi.Installer'),
    (bundle / 'Contents/MacOS/UpoviStoreInstaller', 'app.upovi.StoreInstaller'),
    (bundle / 'Contents/MacOS/UpoviStoreBridge', 'app.upovi.StoreBridge'),
    (bundle / 'Contents/Helpers/UpoviStoreInstaller.app', 'app.upovi.StoreInstaller'),
    (bundle, 'app.upovi.Upovi'),
]

with tempfile.TemporaryDirectory(prefix='upovi-signing-') as temporary:
    for index, (component, identifier) in enumerate(components):
        # Preserve each component's own capabilities, excluding debugger access.
        metadata = subprocess.run(
            ['codesign', '-d', '--entitlements', '-', '--xml', str(component)],
            capture_output=True, check=True,
        )
        entitlements = plistlib.loads(metadata.stdout) if metadata.stdout.strip() else {}
        entitlements.pop('com.apple.security.get-task-allow', None)
        path = pathlib.Path(temporary) / f'{index}.entitlements'
        path.write_bytes(plistlib.dumps(entitlements))
        command = ['codesign', '--force', '--sign', options.identity,
                   '--options', 'runtime', '--timestamp', '--entitlements', str(path)]
        if identifier:
            command += ['--identifier', identifier]
        subprocess.run(command + [str(component)], check=True)
        subprocess.run([
            'codesign', '--verify', '--strict', '--all-architectures', '-R',
            '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists',
            str(component),
        ], check=True)

subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(bundle)], check=True)
