#!/usr/bin/env python3
"""Prepare a signed update archive and appcast locally; never publishes a release."""
import argparse
import base64
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, default=Path('build/Marika.app'))
parser.add_argument('--output', type=Path, default=Path('build/update-release'))
parser.add_argument('--download-prefix', required=True, help='HTTPS directory URL where the archive will be published')
parser.add_argument('--notes', type=Path, required=True, help='Markdown release notes')
parser.add_argument('--account', default='marika-updates', help='Sparkle signing-key account in Keychain')
parser.add_argument('--private-key-file', type=Path, help='Optional private key file instead of Keychain; never embedded')
args = parser.parse_args()
sdk = Path(__file__).resolve().parents[1] / '.build/artifacts/sparkle/Sparkle'
info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
version = info.get('CFBundleShortVersionString', '')
if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', version):
    parser.error('The app must have a numeric release version.')
public_key = info.get('SUPublicEDKey', '')
try:
    valid_key = len(base64.b64decode(public_key, validate=True)) == 32
except ValueError:
    valid_key = False
if not valid_key or not info.get('SURequireSignedFeed'):
    parser.error('Build with MARIKA_UPDATE_PUBLIC_KEY and signed-feed verification enabled first.')
for value in [info.get('SUFeedURL', ''), args.download_prefix]:
    url = urllib.parse.urlsplit(value)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
        parser.error('The appcast and download URLs must use HTTPS without credentials, queries, or fragments.')
if not args.notes.is_file() or not (sdk / 'bin/generate_appcast').is_file():
    parser.error('Provide release notes and build the app first to resolve Sparkle.')

subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
args.output.mkdir(parents=True, exist_ok=True)
archive = args.output / f'Marika-{version}.zip'
subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(args.app), str(archive)], check=True)
shutil.copyfile(args.notes, archive.with_suffix('.md'))
signing = ['--ed-key-file', str(args.private_key_file)] if args.private_key_file else ['--account', args.account]

def verify_archive_signature(signature):
    with tempfile.TemporaryDirectory(prefix='marika-verify-update-') as folder:
        verifier = Path(folder) / 'verify.swift'
        verifier.write_text('''import Foundation
import CryptoKit
import Darwin
let args = CommandLine.arguments
guard let keyData = Data(base64Encoded: args[1]), let signature = Data(base64Encoded: args[2]) else { exit(1) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let contents = try Data(contentsOf: URL(fileURLWithPath: args[3]))
guard key.isValidSignature(signature, for: contents) else { exit(1) }
''')
        subprocess.run(['/usr/bin/xcrun', 'swift', str(verifier), public_key, signature, str(archive)], check=True)

# Reject a mismatched private key before producing a feed, including when Sparkle
# has previously cached an archive's valid signature from another invocation.
signature = subprocess.check_output([str(sdk / 'bin/sign_update'), *signing, '-p', str(archive)], text=True).strip()
verify_archive_signature(signature)
subprocess.run([str(sdk / 'bin/generate_appcast'), *signing, '--embed-release-notes', '--maximum-deltas', '0',
                '--download-url-prefix', args.download_prefix.rstrip('/') + '/', str(args.output)], check=True)
feed = args.output / 'appcast.xml'
subprocess.run([str(sdk / 'bin/sign_update'), *signing, '--verify', str(feed)], check=True)

# Check the archive against the key embedded in the app, rather than merely trusting
# that the release tool found the intended private key in Keychain.
namespace = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
enclosure = next((item for item in ET.parse(feed).findall('.//enclosure')
                  if urllib.parse.unquote(urllib.parse.urlsplit(item.attrib.get('url', '')).path).endswith('/' + archive.name)), None)
if enclosure is None:
    raise SystemExit('The generated feed does not contain this archive.')
signature = enclosure.attrib.get('{' + namespace['sparkle'] + '}edSignature', '')
verify_archive_signature(signature)
print('Verified signed update archive:', archive)
print('Verified signed appcast:', feed)
