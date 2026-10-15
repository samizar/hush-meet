#!/usr/bin/env python3
"""Fail closed if a second HTTP/network implementation is added to shipping Swift sources."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
allowed = root / 'Sources/HushKit/NetworkClient.swift'
patterns = re.compile(r'\b(URLSession|NSURLConnection|NWConnection|NWListener|URLProtocol|CFReadStreamCreateForHTTPRequest|HTTPClient|WebSocket|Process)\b|\b(socket|connect)\s*\(')
errors = []
for tree in [root / 'Sources', root / 'Vendor']:
    for file in tree.rglob('*.swift'):
        if file == allowed:
            continue
        source = file.read_text()
        if patterns.search(source):
            errors.append(str(file.relative_to(root)))
if errors:
    raise SystemExit('Network bypass found: ' + ', '.join(errors))
print('Network audit passed: NetworkClient is the only first-party HTTP implementation. Pinned Sparkle handles signed updates separately.')
