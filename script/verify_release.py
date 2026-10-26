#!/usr/bin/env python3
"""Verify the local universal bundle, archive and signed Sparkle feed without publishing."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory', type=pathlib.Path)
parser.add_argument('--require-notarization', action='store_true')
options = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
release = json.loads((root / 'Resources/Release.json').read_text())
folder = options.directory.resolve()
bundle = folder / 'Upovi.app'
info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
assert info['CFBundleShortVersionString'] == release['version']
assert info['CFBundleVersion'] == release['build']
assert info['SUPublicEDKey'] == release['publicEDKey']
assert info['SUFeedURL'] == release['feedURL']
assert info['SURequireSignedFeed'] and info['SUVerifyUpdateBeforeExtraction']
subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(bundle)], check=True)
archs = subprocess.check_output(['lipo', '-archs', str(bundle / 'Contents/MacOS/Upovi')], text=True).split()
assert set(archs) == {'arm64', 'x86_64'}, archs
helper = bundle / 'Contents/MacOS/UpoviInstaller'
assert set(subprocess.check_output(['lipo', '-archs', str(helper)], text=True).split()) == {'arm64', 'x86_64'}
subprocess.run(['codesign', '--verify', '--strict', '--all-architectures', '-R',
                '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier "app.upovi.Installer"', str(helper)], check=True)
for name, identifier in [("UpoviStoreInstaller", "app.upovi.StoreInstaller"), ("UpoviStoreBridge", "app.upovi.StoreBridge")]:
    executable = bundle / "Contents/MacOS" / name
    assert set(subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split()) == {"arm64", "x86_64"}
    subprocess.run(["codesign", "--verify", "--strict", "--all-architectures", "-R",
                    '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier "' + identifier + '"', str(executable)], check=True)
assert subprocess.check_output([str(bundle / "Contents/MacOS/UpoviStoreBridge"), "version"], text=True).strip() == "7.0.0"
archive = folder / ('Upovi-' + release['version'] + '.zip')
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
assert digest == archive.with_suffix('.zip.sha256').read_text().split()[0]
tools = root / '.build/artifacts/sparkle/Sparkle/bin'
if not (tools / 'sign_update').is_file():
    subprocess.run(['swift', 'package', 'resolve'], cwd=root, check=True)
public_key = subprocess.check_output([str(tools / 'generate_keys'), '--account', release['keychainAccount'], '-p'], text=True).strip()
assert public_key == release['publicEDKey'], 'Keychain account does not match the bundled public key'
feed = folder / 'update-feed/appcast.xml'
subprocess.run([str(tools / 'sign_update'), '--account', release['keychainAccount'], '--verify', str(feed)], check=True)
xml = ET.parse(feed)
item = xml.find('./channel/item')
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
assert item.findtext(ns + 'version') == release['build']
enclosure = item.find('enclosure')
assert int(enclosure.attrib['length']) == archive.stat().st_size
assert enclosure.attrib['url'] == 'https://github.com/WillSuo-Github/Upovi/releases/download/v' + release['version'] + '/' + archive.name
subprocess.run([str(tools / 'sign_update'), '--account', release['keychainAccount'], '--verify', str(archive), enclosure.attrib[ns + 'edSignature']], check=True)
if options.require_notarization:
    subprocess.run(['xcrun', 'stapler', 'validate', str(bundle)], check=True)
    subprocess.run(['spctl', '--assess', '--type', 'execute', str(bundle)], check=True)
print(json.dumps({'version': release['version'], 'build': release['build'], 'architectures': archs,
                  'archiveSHA256': digest, 'nestedSignature': 'passed', 'signedFeed': 'passed',
                  'archiveSignature': 'passed', 'notarization': 'passed' if options.require_notarization else 'not_checked'}))
