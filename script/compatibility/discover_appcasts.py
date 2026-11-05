#!/usr/bin/env python3
"""Cache static upstream Sparkle feeds as research inputs; never execute cask Ruby.

The feed list comes from the exact Homebrew source snapshot. Downloaded XML is
only an untrusted discovery input; production source selection and real signed
old/new application acceptance remain mandatory before any app is counted.
"""
import argparse
import concurrent.futures
import json
import pathlib
import re
import subprocess
import zipfile

import lab


def static_feeds(archive):
    result = []
    with zipfile.ZipFile(archive) as files:
        for entry in files.infolist():
            if '/Casks/' not in entry.filename or not entry.filename.endswith('.rb') or entry.file_size > 200_000:
                continue
            token = pathlib.PurePosixPath(entry.filename).stem
            if not re.fullmatch(r'[a-z0-9][a-z0-9+_-]{0,100}', token):
                continue
            source = files.read(entry).decode('utf-8')
            for block in re.findall(r'^  livecheck do\n(.*?)^  end', source, re.M | re.S):
                if not re.search(r'^\s+strategy :sparkle(?:\s|$)', block, re.M):
                    continue
                urls = re.findall(r'^\s+url ["\'](https://[^"\'\n]+)["\']\s*$', block, re.M)
                if len(urls) != 1 or any(x in urls[0] for x in ['#{', '$', '`']):
                    continue
                try:
                    lab.https_url(urls[0])
                except ValueError:
                    continue
                result.append({'token': token, 'appcastURL': urls[0], 'sourceFile': entry.filename, 'verified': False})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, required=True)
    parser.add_argument('--source-archive', type=pathlib.Path, required=True)
    parser.add_argument('--proxy-port', type=int)
    options = parser.parse_args()
    root = lab.private_root(options.root)
    feeds = lab.private_root(root / 'appcasts')
    (feeds / 'explicit-acceptance-root').write_text(str(feeds))
    catalog = {c['token']: c for c in lab.load(root / 'homebrew-casks.json')}
    leads = [x for x in static_feeds(options.source_archive)
             if x['token'] in catalog and not catalog[x['token']].get('disabled')]
    lab.write_json(root / 'homebrew-appcast-leads.json', {'sourceArchiveSHA256': lab.sha256(options.source_archive), 'leads': leads})

    def fetch(item):
        output = feeds / (item['token'] + '.xml')
        result = item | {'file': output.name}
        if output.exists() and output.stat().st_size <= 3_000_000:
            return result | {'downloaded': True, 'reusedSnapshot': True, 'sha256': lab.sha256(output)}
        command = ['curl', '--fail', '--silent', '--show-error', '--location', '--proto', '=https', '--proto-redir', '=https',
                   '--connect-timeout', '10', '--max-time', '40', '--max-filesize', '3000000', '--output', str(output)]
        if options.proxy_port:
            command += ['--proxy', 'http://127.0.0.1:' + str(options.proxy_port)]
        transfer = subprocess.run(command + [item['appcastURL']], capture_output=True)
        if transfer.returncode or output.stat().st_size > 3_000_000:
            output.unlink(missing_ok=True)
            return result | {'downloaded': False, 'transportExitCode': transfer.returncode}
        output.chmod(0o600)
        return result | {'downloaded': True, 'sha256': lab.sha256(output)}

    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        results = list(pool.map(fetch, leads))
    lab.write_json(feeds / 'inputs.json', results)
    print(json.dumps({'researchFeeds': len(results), 'downloaded': sum(x['downloaded'] for x in results), 'verifiedApps': 0}))


if __name__ == '__main__':
    main()
