#!/usr/bin/env python3
"""Download the six public Latvian smoke fixtures used in MODEL-RESEARCH-2026-10-31.txt.

Google FLEURS, CC BY 4.0, via FluidInference/fleurs. No microphone or private data.
Files remain under ignored build/. SHA-256 records permit comparison across runs;
the mirror's mutable main branch is not a frozen, held-out benchmark.
"""
import hashlib
import json
from pathlib import Path
import urllib.request

BASE = 'https://huggingface.co/datasets/FluidInference/fleurs/resolve/main/lv_lv/'
ROOT = Path(__file__).resolve().parents[1] / 'build/model-fixtures/latvian'


def fetch(name, limit):
    with urllib.request.urlopen(BASE + name, timeout=30) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError('fixture exceeds size bound')
    return data


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    references = dict(line.split(' ', 1) for line in fetch('lv_lv.trans.txt', 2_000_000).decode().splitlines() if line)
    manifest = []
    for index in range(6):
        name = f'lv_lv_{index:04d}'
        reference = references[name]
        data = fetch(name + '.wav', 16_000_000)
        if not data.startswith(b'RIFF') or data[8:12] != b'WAVE':
            raise ValueError('expected WAV fixture')
        (ROOT / (name + '.wav')).write_bytes(data)
        (ROOT / (name + '.txt')).write_text(reference + '\n')
        manifest.append({'id': name, 'url': BASE + name + '.wav', 'sha256': hashlib.sha256(data).hexdigest()})
    (ROOT / 'manifest.json').write_text(json.dumps({'dataset': 'Google FLEURS', 'license': 'CC BY 4.0', 'files': manifest}, indent=2))
    print('Downloaded six Latvian FLEURS smoke fixtures; not a representative benchmark.')


if __name__ == '__main__':
    main()
