#!/usr/bin/env python3
"""Build an explicitly isolated native batch acceptance app; never launches or replaces daily apps."""
import argparse
import pathlib
import plistlib
import subprocess


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def main():
    root = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--original', type=pathlib.Path, required=True, help='Official signed Rectangle 2.0.3 application to copy read-only.')
    parser.add_argument('--output', type=pathlib.Path, default=root / '.local/bulk-acceptance')
    parser.add_argument('--signing-identity', default='-')
    options = parser.parse_args()
    original = options.original.resolve()
    output = options.output.resolve()
    if not output.is_relative_to(root / '.local') or output == root / '.local' or output.exists():
        parser.error('Choose a new directory below this repository .local folder; existing evidence is never overwritten.')
    info = plistlib.loads((original / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.knollsoft.Rectangle' or info.get('CFBundleShortVersionString') != '2.0.3':
        parser.error('Use the official Rectangle 2.0.3 fixture.')
    run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(original)])
    output.mkdir(parents=True, mode=0o700)
    for name in ['A.app', 'B.app', 'C.app']:
        target = output / 'Applications' / name
        target.parent.mkdir(exist_ok=True)
        run(['ditto', str(original), str(target)])
    run(['swift', 'build', '--product', 'Upovi'], cwd=root)
    products = pathlib.Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip())
    modules = output / 'modules'; modules.mkdir()
    header = root / 'Sources/ArchiveSupport/include/ArchiveSupport.h'
    (modules / 'module.modulemap').write_text('module ArchiveSupport { header "' + str(header) + '" export * }\n')
    app = output / 'UpoviBulkAcceptance.app'
    executable = app / 'Contents/MacOS/UpoviFixture'
    executable.parent.mkdir(parents=True)
    sources = [str(path) for path in (root / 'Sources/Upovi').rglob('*.swift') if path.name != 'UpoviApp.swift']
    objects = []
    for target in ['UpoviCore', 'ArchiveSupport']:
        if (products / (target + '.o')).exists():
            objects.append(str(products / (target + '.o')))
        else:
            objects.extend(str(path) for path in (products / (target + '.build')).rglob('*.o'))
    if not objects:
        raise RuntimeError('No compiled core objects found; inspect the SwiftPM product layout.')
    command = ['swiftc', '-swift-version', '6', '-parse-as-library', '-I', str(products), '-I', str(modules), '-F', str(products)]
    command += sources + [str(root / 'script/acceptance/bulk_install.swift')] + objects
    command += ['-larchive', '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks', '-o', str(executable)]
    run(command, cwd=root)
    info = dict(CFBundleExecutable='UpoviFixture', CFBundleIdentifier='app.upovi.TrustAcceptance',
                CFBundleName='Upovi Bulk Acceptance', CFBundlePackageType='APPL',
                CFBundleShortVersionString='0.4.3', CFBundleVersion='9', LSMinimumSystemVersion='14.0', NSPrincipalClass='NSApplication')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    run(['python3', 'script/embed_sparkle.py', str(app), options.signing_identity], cwd=root)
    command = ['codesign', '--force', '--sign', options.signing_identity]
    if options.signing_identity != '-':
        command += ['--options', 'runtime', '--timestamp']
    run(command + [str(app)])
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    print('Isolated fixture:', app)
    print('Launch the bundle with --args --root followed by:', output)
    print('A and C use the official signed ZIP; B intentionally fails its checksum until Repair fixture source is selected.')


if __name__ == '__main__':
    main()
