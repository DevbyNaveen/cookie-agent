#!/usr/bin/env python3
"""Replay public/synthetic paired audio through the actual helper. Never records the microphone.

Results are measurements on this machine, not a claim of production accuracy.
Run: python3 scripts/check-models.py --engine parakeet --clips build/model-fixtures
Generate synthetic clips first with: python3 scripts/bench.py --make-synthetic build/model-fixtures
"""
import argparse
import json
import math
import os
from pathlib import Path
import select
import struct
import subprocess
import tempfile
import time
import wave
from bench import pcm16, wer, words


class Helper:
    def __init__(self, path, log):
        self.log = open(log, 'wb')
        self.proc = subprocess.Popen([path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)

    def send(self, obj, payload=b''):
        body = json.dumps(obj).encode()
        self.proc.stdin.write(struct.pack('>I', len(body)) + body + struct.pack('>I', len(payload)) + payload)
        self.proc.stdin.flush()

    def receive(self, timeout=30):
        deadline = time.monotonic() + timeout
        def exact(count):
            data = bytearray()
            while len(data) < count:
                left = deadline - time.monotonic()
                if left <= 0 or not select.select([self.proc.stdout], [], [], left)[0]:
                    raise TimeoutError('helper deadline exceeded')
                chunk = os.read(self.proc.stdout.fileno(), count - len(data))
                if not chunk:
                    raise RuntimeError('helper exited (status ' + str(self.proc.poll()) + ')')
                data.extend(chunk)
            return data
        size = struct.unpack('>I', exact(4))[0]
        if size > 8 * 1024 * 1024:
            raise RuntimeError('invalid helper frame size')
        obj = json.loads(exact(size))
        size = struct.unpack('>I', exact(4))[0]
        if size > 8 * 1024 * 1024:
            raise RuntimeError('invalid helper payload size')
        exact(size)
        return obj

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.log.close()


def percentile(values, p):
    return sorted(values)[max(0, math.ceil(len(values) * p) - 1)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', choices=['speech', 'parakeet'], default='parakeet')
    parser.add_argument('--clips', type=Path, required=True)
    parser.add_argument('--locale', default='en-US')
    parser.add_argument('--exclude', action='append', default=[], help='Exclude a category, e.g. latvian for an English-only recognizer')
    parser.add_argument('--batch', action='store_true', help='Parakeet full-utterance diagnostic, not the app streaming path')
    parser.add_argument('--gpu', action='store_true', help='Diagnostic Core ML GPU placement')
    parser.add_argument('--helper', default='Helpers/enkeon-sense/.build/release/enkeon-sense')
    args = parser.parse_args()
    if args.batch and args.engine != 'parakeet':
        parser.error('--batch requires parakeet')
    label = args.engine + ('-batch' if args.batch else '') + ('-gpu' if args.gpu else '')
    args.clips.mkdir(parents=True, exist_ok=True)
    helper = Helper(args.helper, args.clips / (label + '-helper.log'))
    rows = []
    try:
        if args.engine == 'parakeet':
            print('Preparing Parakeet Ultra (first run downloads roughly 630 MB)…', flush=True)
            started = time.monotonic()
            helper.send({'op': 'parakeet.prepare', 'id': 'prepare', 'compute': 'gpu' if args.gpu else 'ane'})
            ready = helper.receive(timeout=600)
            if not ready.get('ok'):
                raise RuntimeError(str(ready))
            print(f'Parakeet Ultra loaded in {time.monotonic() - started:.1f}s.', flush=True)
        clips = sorted(p for p in args.clips.rglob('*') if p.suffix.lower() in ['.wav', '.aiff', '.flac', '.m4a']
                       and not any(category in p.relative_to(args.clips).parts for category in args.exclude))
        if not clips:
            raise RuntimeError('No clips found')
        with tempfile.TemporaryDirectory() as temp:
            for index, clip in enumerate(clips):
                reference_file = clip.with_suffix('.txt')
                if not reference_file.exists():
                    continue
                reference = reference_file.read_text().strip()
                pcm = pcm16(str(clip), temp)
                sid = f'clip-{index}'
                if not args.batch:
                    helper.send({'op': args.engine + '.start', 'id': sid, 'locale': args.locale})
                    reply = helper.receive()
                    if reply.get('id') != sid or not reply.get('ok'):
                        raise RuntimeError(str(reply))
                events = []
                for offset in ([] if args.batch else range(0, len(pcm), 3200)):
                    helper.send({'op': args.engine + '.audio', 'id': sid}, pcm[offset:offset + 3200])
                    time.sleep(0.1)
                    while select.select([helper.proc.stdout], [], [], 0)[0]:
                        event = helper.receive()
                        if event.get('id') != sid or event.get('error') or event.get('event') == 'error':
                            raise RuntimeError('speech failed during recording: ' + str(event))
                        events.append(event)
                released = time.monotonic()
                helper.send({'op': args.engine + ('.transcribe' if args.batch else '.finish'), 'id': sid}, pcm if args.batch else b'')
                while True:
                    reply = helper.receive()
                    if reply.get('id') != sid:
                        raise RuntimeError('cross-session response: ' + str(reply))
                    if reply.get('error') or reply.get('event') == 'error':
                        raise RuntimeError(str(reply))
                    if reply.get('event') == 'final':
                        break
                latency = (time.monotonic() - released) * 1000
                hypothesis = reply.get('text', '')
                row = {'clip': str(clip.relative_to(args.clips)), 'reference': reference, 'heard': hypothesis,
                       'wer': wer(reference, hypothesis), 'release_to_final_ms': latency,
                       'partial_updates': len(events), 'duration_seconds': len(pcm) / 32000}
                rows.append(row)
                (args.clips / (label + '-results.json')).write_text(json.dumps({'complete': False, 'rows': rows}, indent=2))
                print(f"{row['clip']}: {latency:.0f} ms, {row['wer'] * 100:.1f}% normalized WER", flush=True)
                if row['wer']:
                    print('  heard:', hypothesis, flush=True)
        if not rows:
            raise RuntimeError('No referenced clips were tested')
        total = sum(len(words(r['reference'])) for r in rows)
        summary = {'engine': label, 'clips': len(rows),
                   'normalized_wer': sum(r['wer'] * len(words(r['reference'])) for r in rows) / max(total, 1),
                   'silence_false_positives': sum(bool(r['heard'].strip()) for r in rows if not r['reference']),
                   'p50_ms': percentile([r['release_to_final_ms'] for r in rows], .5),
                   'p95_ms': percentile([r['release_to_final_ms'] for r in rows], .95)}
        print(json.dumps(summary, indent=2), flush=True)
        (args.clips / (label + '-results.json')).write_text(json.dumps({'complete': True, 'summary': summary, 'rows': rows}, indent=2))
    except Exception as error:
        (args.clips / (label + '-results.json')).write_text(json.dumps({'complete': False, 'error': str(error), 'rows': rows}, indent=2))
        raise
    finally:
        helper.close()


if __name__ == '__main__':
    main()
