#!/usr/bin/env python3
"""Package the current device build for user signing, and verify every Mach-O."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--build-number', required=True)
    args = parser.parse_args()
    assert args.source.is_file(), 'Build IPA is missing'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    magic = {bytes.fromhex(value) for value in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
    with tempfile.TemporaryDirectory(prefix='video-rewatch-package-') as temporary:
        stage = Path(temporary)
        run('ditto', '-x', '-k', str(args.source), str(stage))
        apps = list((stage / 'Payload').glob('*.app'))
        assert len(apps) == 1, 'Expected exactly one application'
        app = apps[0]
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        assert info['CFBundleIdentifier'] == 'ph.telegra.Telegraph', 'Unexpected bundle identifier'
        assert info['CFBundleVersion'] == args.build_number, 'Stale build number'
        assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS'], 'Expected device build'
        extensions = []
        for extension in sorted(app.glob('PlugIns/*.appex')):
            extension_info = plistlib.loads((extension / 'Info.plist').read_bytes())
            assert extension_info['CFBundleIdentifier'].startswith(info['CFBundleIdentifier'] + '.')
            extensions.append(extension_info['CFBundleIdentifier'])
        assert len(extensions) == 6, 'Missing application extensions'
        machos = 0
        removed = 0
        for path in app.rglob('*'):
            if path.is_symlink() or not path.is_file():
                continue
            with path.open('rb') as stream:
                header = stream.read(4)
            if header not in magic:
                continue
            machos += 1
            result = subprocess.run(['codesign', '--display', str(path)], capture_output=True)
            if result.returncode == 0:
                run('codesign', '--remove-signature', str(path))
                removed += 1
            result = subprocess.run(['codesign', '--display', str(path)], capture_output=True)
            assert result.returncode != 0 and b'code object is not signed at all' in result.stderr, 'Could not verify unsigned Mach-O: ' + str(path) + ': ' + result.stderr.decode(errors='replace')
        for path in app.rglob('embedded.mobileprovision'):
            path.unlink()
        for path in sorted(app.rglob('_CodeSignature'), key=lambda value: len(value.parts), reverse=True):
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
        architecture = run('lipo', '-archs', str(app / info['CFBundleExecutable']))
        assert architecture == 'arm64', architecture
        temporary_ipa = args.output.with_suffix('.partial.ipa')
        try:
            run('ditto', '-c', '-k', '--keepParent', str(stage / 'Payload'), str(temporary_ipa))
            with zipfile.ZipFile(temporary_ipa) as archive:
                assert archive.testzip() is None, 'Corrupt archive'
                assert not any('/_CodeSignature/' in name or name.endswith('embedded.mobileprovision') for name in archive.namelist())
            temporary_ipa.replace(args.output)
        finally:
            temporary_ipa.unlink(missing_ok=True)
    checksum = hashlib.sha256()
    with args.output.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(block)
    digest = checksum.hexdigest()
    report = {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'], 'bundle_id': info['CFBundleIdentifier'], 'architecture': architecture, 'extensions': extensions, 'mach_o_files_verified_unsigned': machos, 'existing_signatures_removed': removed, 'bytes': args.output.stat().st_size, 'sha256': digest}
    args.output.with_suffix('.verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
