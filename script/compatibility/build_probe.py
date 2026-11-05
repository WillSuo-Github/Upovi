#!/usr/bin/env python3
"""Build the compatibility probe against the actual UpoviCore debug objects."""
import pathlib
import subprocess
import datetime
import hashlib
import json


def build(output):
    repository = pathlib.Path(__file__).resolve().parents[2]
    output = pathlib.Path(output).absolute()
    if output != output.resolve() or not output.is_relative_to(repository / '.local'):
        raise ValueError('Use an unlinked output directory under repository .local.')
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(['swift', 'build', '--product', 'UpoviPeer'], cwd=repository, check=True)
    products = pathlib.Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=repository, text=True).strip())
    modules = output / 'modules'
    modules.mkdir(exist_ok=True)
    header = repository / 'Sources/ArchiveSupport/include/ArchiveSupport.h'
    (modules / 'module.modulemap').write_text(f'module ArchiveSupport {{ header "{header}" export * }}\n')
    objects = []
    for target in ['UpoviCore', 'ArchiveSupport']:
        combined = products / (target + '.o')
        objects.extend([str(combined)] if combined.exists() else map(str, (products / (target + '.build')).rglob('*.o')))
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-I', str(products),
                    '-I', str(products / 'Modules'), '-I', str(modules),
                    str(repository / 'script/compatibility/probe.swift'), *objects,
                    '-larchive', '-o', str(output / 'compatibility-probe')], cwd=repository, check=True)
    sources = sorted((repository / 'Sources/UpoviCore').rglob('*.swift')) + [repository / 'script/compatibility/probe.swift']
    sources += sorted(p for p in (repository / 'Sources/ArchiveSupport').rglob('*') if p.suffix in ['.c', '.h'])
    hashes = {str(path.relative_to(repository)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    record = json.dumps({'builtAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'gitHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repository, text=True).strip(),
        'sourceHashes': hashes, 'capabilities': ['externalReviewedBaselineV1'],
        'binarySHA256': hashlib.sha256((output / 'compatibility-probe').read_bytes()).hexdigest()}, indent=2) + '\n'
    (output / 'build-manifest.json').write_text(record)
    history = output / 'build-manifests'
    history.mkdir(exist_ok=True)
    (history / (json.loads(record)['binarySHA256'] + '.json')).write_text(record)
    return output / 'compatibility-probe'


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    print(build(parser.parse_args().output))
