#!/usr/bin/env python3
"""Read authentic old archive URLs/checksums from official historical cask snapshots.

Only a bounded literal subset is supported. No Ruby, shell, recipe processor or
downloaded application is executed. An old descriptor is a research input, never
an upgrade success. Production signing/source/install/restore gates still apply.
"""
import argparse
import hashlib
import json
import pathlib
import re
import zipfile

import lab


def declaration(source, name, indent=2):
    lines = source.splitlines()
    values = [(i, re.fullmatch(' ' * indent + re.escape(name) + r'\s+(.+)', line)) for i, line in enumerate(lines)]
    values = [(i, match) for i, match in values if match]
    if len(values) != 1:
        return None
    index, match = values[0]
    parts = [match[1].strip()]
    for line in lines[index + 1:]:
        if not line.strip() or len(line) - len(line.lstrip(' ')) <= indent:
            break
        parts.append(line.strip())
    return ' '.join(parts)


def quoted(value, options=False):
    if value is None:
        return None
    match = re.fullmatch(r'["\']([^"\'\n]+)["\']' + (r'(?:,\s*[^\n]*)?' if options else ''), value)
    return match[1] if match else None


def literal_descriptor(source):
    if len(source.encode()) > 200_000:
        return None
    blocks = re.findall(r'^  on_arm do\n(.*?)^  end\s*$', source, re.M | re.S)
    if len(blocks) > 1:
        return None
    arm = blocks[0] if blocks else ''

    def field(name):
        return declaration(arm, name, 4) or declaration(source, name)

    version = quoted(field('version'))
    if not version or '#{' in version or not re.fullmatch(r'[0-9][0-9A-Za-z.+,_-]{0,127}', version):
        return None
    if re.search(r'(?:alpha|beta|preview|nightly|dev|head|(?:^|[-.])rc\d*)', version, re.I):
        return None
    raw_sha = field('sha256')
    sha = quoted(raw_sha)
    if not sha and raw_sha and re.fullmatch(r'(?:arm|intel):\s*"[a-fA-F0-9]{64}"(?:,\s*(?:arm|intel):\s*"[a-fA-F0-9]{64}")*', raw_sha):
        pairs = re.findall(r'(arm|intel):\s*"([a-fA-F0-9]{64})"', raw_sha)
        if len({key for key, _ in pairs}) == len(pairs):
            sha = dict(pairs).get('arm')
    if not sha or not re.fullmatch(r'[a-fA-F0-9]{64}', sha):
        return None
    url = quoted(field('url'), options=True)
    if not url:
        return None
    arch = None
    arch_line = declaration(source, 'arch')
    if arch_line:
        if not re.fullmatch(r'(?:arm|intel):\s*"[A-Za-z0-9_-]+"(?:,\s*(?:arm|intel):\s*"[A-Za-z0-9_-]+")*', arch_line):
            return None
        pairs = re.findall(r'(arm|intel):\s*"([A-Za-z0-9_-]+)"', arch_line)
        if len({key for key, _ in pairs}) != len(pairs):
            return None
        arch = dict(pairs).get('arm')
    substitutions = {'version': version, 'arch': arch}
    csv = version.split(',')
    substitutions['version.csv.first'] = csv[0]
    substitutions['version.csv.second'] = csv[1] if len(csv) == 2 else None
    if len(csv) == 1:
        pieces = version.split('.')
        substitutions.update({'version.major': pieces[0], 'version.minor': pieces[1] if len(pieces) > 1 else None,
                              'version.patch': pieces[2] if len(pieces) > 2 else None,
                              'version.major_minor': '.'.join(pieces[:2]) if len(pieces) >= 2 else None,
                              'version.major_minor_patch': '.'.join(pieces[:3]) if len(pieces) >= 3 else None,
                              'version.no_dots': version.replace('.', ''),
                              'version.dots_to_underscores': version.replace('.', '_'),
                              'version.dots_to_hyphens': version.replace('.', '-')})
    invalid = False

    def replace(match):
        nonlocal invalid
        value = substitutions.get(match[1])
        if value is None:
            invalid = True
            return ''
        return value

    url = re.sub(r'#\{([^{}]+)\}', replace, url)
    if invalid or any(s in url for s in ['#{', '$', '`']):
        return None
    try:
        lab.https_url(url)
    except ValueError:
        return None
    apps = re.findall(r'^  app\s+["\']([^"\'#\n]+\.app)["\']', source, re.M)
    return {'version': version, 'url': url, 'sha256': sha.lower(),
            'applicationNames': sorted({pathlib.PurePosixPath(name).name for name in apps})}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, required=True)
    options = parser.parse_args()
    root = lab.private_root(options.root)
    catalog = {c['token']: c for c in lab.load(root / 'homebrew-casks.json')}
    audited = {c['token']: c for c in lab.load(root / 'audit.json')['rows']}
    chosen, alternatives = {}, []
    sources = lab.load(root / 'historical-homebrew-source-provenance.json')
    for snapshot in sorted(sources, key=lambda x: x['committedAt'], reverse=True):
        path = root / snapshot['file']
        if path.parent != root or path.resolve() != path or lab.sha256(path) != snapshot['archiveSHA256']:
            raise ValueError('Historical snapshot provenance mismatch.')
        with zipfile.ZipFile(path) as archive:
            for entry in archive.infolist():
                if '/Casks/' not in entry.filename or not entry.filename.endswith('.rb') or entry.file_size > 200_000:
                    continue
                token = pathlib.PurePosixPath(entry.filename).stem
                current = catalog.get(token)
                if not current or current.get('disabled') or '@' in token or not re.fullmatch(r'[a-z0-9][a-z0-9+_-]{0,100}', token):
                    continue
                row = audited[token]
                if not row['declaredAppNames']:
                    continue
                raw = archive.read(entry)
                old = literal_descriptor(raw.decode('utf-8'))
                if not old or old['version'] == current['version'] or not set(old['applicationNames']) & set(row['declaredAppNames']):
                    continue
                relative = entry.filename.split('/', 1)[1]
                item = {'token': token, 'cask': token, 'bundleID': row['declaredBundleIDs'][0] if len(row['declaredBundleIDs']) == 1 else '',
                        'oldVersion': '', 'discoverBaseline': True, 'oldURL': old['url'], 'oldSHA256': old['sha256'],
                        'oldDeclaredVersion': old['version'], 'oldRecipeSHA256': hashlib.sha256(raw).hexdigest(),
                        'oldReleaseURL': 'https://github.com/Homebrew/homebrew-cask/blob/' + snapshot['commit'] + '/' + relative,
                        'historicalSourceCommit': snapshot['commit'], 'historicalSourceDate': snapshot['committedAt'],
                        'provenance': 'Exact official historical cask URL and independent checksum, parsed without executing Ruby; actual old Apple signature, production source selection, installation and restoration still required.'}
                if token in chosen:
                    if chosen[token]['oldURL'] != item['oldURL']:
                        alternatives.append(item)
                else:
                    chosen[token] = item
    lab.write_json(root / 'historical-cask-pairs.json', list(chosen.values()))
    lab.write_json(root / 'historical-cask-alternatives.json', alternatives)
    print(json.dumps({'unverifiedPairs': len(chosen), 'olderAlternatives': len(alternatives), 'verifiedApps': 0}))


if __name__ == '__main__':
    main()
