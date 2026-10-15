#!/usr/bin/env python3
"""Validate release metadata and verify the payload with Sparkle before publication."""
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET

feed, archive, tag = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
info = plistlib.loads((Path(__file__).resolve().parent.parent / 'Resources/Info.plist').read_bytes())
items = ET.parse(feed).findall('./channel/item')
item = next((i for i in items if i.findtext(sparkle + 'version') == info['CFBundleVersion']), None)
assert item is not None, 'New build is missing from the appcast'
assert item.findtext(sparkle + 'shortVersionString') == tag.removeprefix('v') == info['CFBundleShortVersionString'], 'Release version mismatch'
assert item.findtext(sparkle + 'minimumSystemVersion') == info['LSMinimumSystemVersion'], 'Minimum macOS mismatch'
enclosure = item.find('enclosure')
assert enclosure is not None
assert enclosure.get('url') == f'https://github.com/samizar/hush-meet/releases/download/{tag}/Hush.dmg', 'Unexpected update URL'
assert int(enclosure.get('length', '0')) == archive.stat().st_size, 'Update length mismatch'
signature = enclosure.get(sparkle + 'edSignature')
assert signature, 'Unsigned update archive'
subprocess.run([str(Path(__file__).resolve().parent.parent / 'build/Sparkle/bin/sign_update'), '--account', 'app.hush.mac', '--verify', str(archive), signature], check=True)
print('Release metadata, archive length and Ed25519 signature verified.')
