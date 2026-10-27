#!/usr/bin/env python3
"""Compile the real-source installer harness. It accepts only isolated app copies under .local."""
import argparse
import pathlib
import subprocess


def main():
    repository = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=pathlib.Path)
    options = parser.parse_args()
    output = options.output.absolute()
    if output != output.resolve() or not output.is_relative_to(repository / '.local') or output == repository / '.local':
        parser.error('Use an unlinked acceptance directory inside this repository .local folder.')
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(['swift', 'build', '--product', 'UpoviPeer'], cwd=repository, check=True)
    products = pathlib.Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=repository, text=True).strip())
    modules = output / 'modules'
    modules.mkdir(exist_ok=True)
    header = repository / 'Sources/ArchiveSupport/include/ArchiveSupport.h'
    (modules / 'module.modulemap').write_text('module ArchiveSupport { header "' + str(header) + '" export * }\n')
    objects = []
    for target in ['UpoviCore', 'ArchiveSupport']:
        combined = products / (target + '.o')
        objects.extend([str(combined)] if combined.exists() else [str(path) for path in (products / (target + '.build')).rglob('*.o')])
    if len(objects) < 2:
        raise RuntimeError('Core build products were not found.')
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-I', str(products), '-I', str(products / 'Modules'),
                    '-I', str(modules), str(repository / 'script/acceptance/source_installation.swift'), *objects,
                    '-larchive', '-o', str(output / 'source-installation')], cwd=repository, check=True)
    print(output / 'source-installation')


if __name__ == '__main__':
    main()
