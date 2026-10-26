#!/usr/bin/env python3
"""Write application metadata from the single release configuration."""
import base64
import json
import os
import pathlib
import plistlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
release = json.loads((root / 'Resources/Release.json').read_text())
assert re.fullmatch(r'\d+(?:\.\d+){2}', release['version'])
assert re.fullmatch(r'\d+', release['build'])
assert release['feedURL'].startswith('https://')
assert len(base64.b64decode(release['publicEDKey'], validate=True)) == 32
info = dict(CFBundleExecutable='Upovi', CFBundleIdentifier='app.upovi.Upovi',
            CFBundleName='Upovi', CFBundleDisplayName='Upovi', CFBundlePackageType='APPL',
            CFBundleShortVersionString=os.environ.get('MARKETING_VERSION', release['version']),
            CFBundleVersion=os.environ.get('CURRENT_PROJECT_VERSION', release['build']),
            UpoviSourceRevision=sys.argv[2],
            CFBundleIconFile=os.environ.get('ASSETCATALOG_COMPILER_APPICON_NAME', 'Upovi'), LSMinimumSystemVersion='14.0',
            NSPrincipalClass='NSApplication',
            NSLocalNetworkUsageDescription='Discover opted-in peers and exchange selected app version reports.',
            NSHumanReadableCopyright='Copyright © 2026 Upovi contributors. MIT License.',
            SUFeedURL=release['feedURL'], SUPublicEDKey=release['publicEDKey'],
            SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUEnableSystemProfiling=False,
            SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True)
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
