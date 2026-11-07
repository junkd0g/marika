#!/usr/bin/env python3
"""Verify signed update packaging with throwaway keys and an inert fixture app."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-update-package-'))
keygen = root / 'keys.swift'
keygen.write_text('''import Foundation
import CryptoKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
for index in 0..<2 {
    let key = Curve25519.Signing.PrivateKey()
    let destination = root.appendingPathComponent("key-\\(index)")
    try key.rawRepresentation.base64EncodedData().write(to: destination)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    try key.publicKey.rawRepresentation.base64EncodedData().write(to: root.appendingPathComponent("public-\\(index)"))
}
''')
keys = [root / 'key-0', root / 'key-1']
try:
    subprocess.run(['/usr/bin/xcrun', 'swift', str(keygen), str(root)], check=True)
    app = root / 'Marika.app'
    executable = app / 'Contents/MacOS/Marika'; executable.parent.mkdir(parents=True)
    shutil.copyfile('/usr/bin/true', executable)
    executable.chmod(0o755)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier='app.marika.update-fixture', CFBundleName='Marika', CFBundleExecutable='Marika',
        CFBundlePackageType='APPL', CFBundleShortVersionString='0.2.0', CFBundleVersion='2',
        LSMinimumSystemVersion='15.0', SUFeedURL='https://example.invalid/appcast.xml',
        SUPublicEDKey=(root / 'public-0').read_text(), SURequireSignedFeed=True)))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    notes = root / 'notes.md'; notes.write_text('# Fixture release notes\n\nSigned updates preserve file integrity.\n')

    def package(name, key):
        output = root / name
        with (root / (name + '.log')).open('w') as log:
            result = subprocess.run(['python3', str(repo / 'scripts/package-update.py'), '--app', str(app),
                '--output', str(output), '--download-prefix', 'https://example.invalid/download/v0.2.0/',
                '--notes', str(notes), '--private-key-file', str(key)],
                cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        return result, output

    result, output = package('valid', keys[0])
    assert result.returncode == 0, root / 'valid.log'
    feed = output / 'appcast.xml'
    data = feed.read_bytes()
    enclosure = ET.fromstring(data).find('.//enclosure')
    assert enclosure is not None and enclosure.attrib['url'].endswith('/Marika-0.2.0.zip')
    signature = enclosure.attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature']
    wrong, wrong_output = package('wrong-key', keys[1])
    assert wrong.returncode != 0 and not (wrong_output / 'appcast.xml').exists(), root / 'wrong-key.log'
    signer = repo / '.build/artifacts/sparkle/Sparkle/bin/sign_update'
    archive = output / 'Marika-0.2.0.zip'
    with archive.open('ab') as file:
        file.write(b'tampered')
    bad_archive = subprocess.run([str(signer), '--ed-key-file', str(keys[0]), '--verify', str(archive), signature], capture_output=True)
    assert bad_archive.returncode != 0, 'A changed archive was accepted'
    tampered = data.replace(b'Fixture release notes', b'Tampered release notes', 1)
    assert tampered != data
    feed.write_bytes(tampered)
    bad_feed = subprocess.run([str(signer), '--ed-key-file', str(keys[0]), '--verify', str(feed)], capture_output=True)
    assert bad_feed.returncode != 0, 'A changed appcast was accepted'
    print('Signed update packaging passed: archive and feed signatures, embedded public key, mismatched key rejection and tamper detection. Logs:', root)
finally:
    for key in keys:
        key.unlink(missing_ok=True)
