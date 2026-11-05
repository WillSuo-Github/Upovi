#!/usr/bin/env python3
"""Collect research leads from community recipes without executing their code.

Recipe names, team IDs and URLs are untrusted leads, never product trust rules or
evidence of compatibility. Files are read inside ZIP archives, never extracted.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import zipfile


def literal(value):
    return isinstance(value, str) and value and not any(x in value for x in ['$', '`', '%', '\n'])


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)


def collect(path):
    leads = []
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            if entry.file_size > 2_000_000:
                continue
            if '/fragments/labels/' in entry.filename and entry.filename.endswith('.sh'):
                source = archive.read(entry).decode('utf-8', errors='replace')
                fields = {}
                for key in ['name', 'appName', 'type', 'expectedTeamID', 'downloadURL']:
                    found = re.findall(r'^\s*' + key + r'=["\']([^"\']*)["\']\s*$', source, re.M)
                    if len(found) == 1 and literal(found[0]):
                        fields[key] = found[0]
                repositories = re.findall(r'(?:downloadURLFromGit|versionFromGit)\s+["\']([^"\']+)["\']\s+["\']([^"\']+)["\']', source)
                leads.append({'kind': 'installomator-label', 'label': pathlib.PurePosixPath(entry.filename).stem,
                              'file': entry.filename, 'literalFields': fields,
                              'githubRepositoryLeads': sorted({'/'.join(x) for x in repositories}), 'verified': False})
            elif entry.filename.endswith('.download.recipe'):
                try:
                    data = plistlib.loads(archive.read(entry))
                except (ValueError, plistlib.InvalidFileException):
                    continue
                values = list(strings(data))
                urls = sorted({s for s in values if s.startswith('https://') and literal(s)})
                requirements = [s for s in values if 'identifier ' in s and 'anchor apple' in s]
                bundle_ids = sorted({bid for s in requirements for bid in re.findall(r'identifier\s+"([A-Za-z0-9_.-]+)"', s)})
                teams = sorted({team for s in requirements for team in re.findall(r'\b[A-Z0-9]{10}\b', s)})
                source_input = data.get('Input', {})
                leads.append({'kind': 'autopkg-download-recipe', 'identifier': data.get('Identifier', ''),
                              'name': source_input.get('NAME', ''), 'file': entry.filename,
                              'literalURLs': urls, 'bundleIDLeads': bundle_ids, 'teamIDLeads': teams, 'verified': False})
    return {'archive': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'leads': leads}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archives', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    options = parser.parse_args()
    catalogs = [collect(path) for path in sorted(options.archives.glob('*.zip'))]
    options.output.write_text(json.dumps({'schemaVersion': 1, 'verifiedApps': 0,
        'countingPolicy': 'Research leads only. Cross-catalog names, product variants, recipes and duplicate IDs are not verified unique apps.',
        'catalogs': catalogs}, indent=2) + '\n')
    print(json.dumps({'catalogs': [{'archive': c['archive'], 'researchLeads': len(c['leads'])} for c in catalogs],
                      'verifiedApps': 0}, indent=2))


if __name__ == '__main__':
    main()
