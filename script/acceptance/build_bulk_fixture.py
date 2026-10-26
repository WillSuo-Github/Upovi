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
    parser.add_argument('--mode', choices=['bulk', 'admin-cleanup'], default='bulk')
    parser.add_argument('--replacement', type=pathlib.Path)
    parser.add_argument('--helper-bundle', type=pathlib.Path)
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
    if options.mode == 'bulk':
        for name in ['A.app', 'B.app', 'C.app']:
            target = output / 'Applications' / name
            target.parent.mkdir(exist_ok=True)
            run(['ditto', str(original), str(target)])
    else:
        target = pathlib.Path('/Applications/Upovi Download Cleanup Acceptance.app')
        if target.exists() or target.is_symlink() or not options.replacement or not options.helper_bundle or options.signing_identity == '-':
            parser.error('Administrator mode requires a replacement, signed helper bundle and an unused isolated target path.')
        replacement = options.replacement.resolve()
        latest = plistlib.loads((replacement / 'Contents/Info.plist').read_bytes())
        if latest.get('CFBundleIdentifier') != info['CFBundleIdentifier'] or latest.get('CFBundleShortVersionString') != '2.0.4':
            parser.error('Use the official signed Rectangle 2.0.4 replacement.')
        run(['codesign', '--verify', '--deep', '--strict', str(replacement)])
        run(['ditto', str(original), str(target)])
        (output / 'replacement.path').write_text(str(replacement))
    run(['swift', 'build', '--product', 'Upovi'], cwd=root)
    products = pathlib.Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip())
    modules = output / 'modules'; modules.mkdir()
    header = root / 'Sources/ArchiveSupport/include/ArchiveSupport.h'
    (modules / 'module.modulemap').write_text('module ArchiveSupport { header "' + str(header) + '" export * }\n')
    app = output / ('UpoviBulkAcceptance.app' if options.mode == 'bulk' else 'UpoviCleanupAcceptance.app')
    executable = app / 'Contents/MacOS/UpoviFixture'
    executable.parent.mkdir(parents=True)
    sources = [str(path) for path in (root / 'Sources/Upovi').rglob('*.swift') if path.name != 'UpoviApp.swift']
    objects = []
    for object_target in ['UpoviCore', 'ArchiveSupport']:
        if (products / (object_target + '.o')).exists():
            objects.append(str(products / (object_target + '.o')))
        else:
            objects.extend(str(path) for path in (products / (object_target + '.build')).rglob('*.o'))
    if not objects:
        raise RuntimeError('No compiled core objects found; inspect the SwiftPM product layout.')
    command = ['swiftc', '-swift-version', '6', '-parse-as-library', '-I', str(products), '-I', str(modules), '-F', str(products)]
    command += sources + [str(root / 'script/acceptance' / ('bulk_install.swift' if options.mode == 'bulk' else 'admin_cleanup.swift'))] + objects
    command += ['-larchive', '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks', '-o', str(executable)]
    run(command, cwd=root)
    info = dict(CFBundleExecutable='UpoviFixture', CFBundleIdentifier='app.upovi.TrustAcceptance',
                CFBundleName='Upovi Bulk Acceptance' if options.mode == 'bulk' else 'Upovi Cleanup Acceptance', CFBundlePackageType='APPL',
                CFBundleShortVersionString='0.4.4', CFBundleVersion='10', LSMinimumSystemVersion='14.0', NSPrincipalClass='NSApplication')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    run(['python3', 'script/embed_sparkle.py', str(app), options.signing_identity], cwd=root)
    command = ['codesign', '--force', '--sign', options.signing_identity]
    if options.signing_identity != '-':
        command += ['--options', 'runtime', '--timestamp']
    if options.mode == 'admin-cleanup':
        run(['ditto', str(options.helper_bundle / 'Contents/MacOS/UpoviInstaller'), str(app / 'Contents/MacOS/UpoviInstaller')])
    run(command + [str(app)])
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    print('Isolated fixture:', app)
    print('Launch the bundle with --args --root followed by:', output)
    if options.mode == 'bulk':
        print('A and C use the official signed ZIP; B intentionally fails its checksum until Repair fixture source is selected.')
    else:
        print('Isolated administrator target:', target)
        print('No administrator operation runs until explicitly selected in the fixture UI.')


if __name__ == '__main__':
    main()
