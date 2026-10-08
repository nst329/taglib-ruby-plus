#!/usr/bin/env python3
"""Validate the proposal against a compiled throwaway native prototype and real MP4s."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {args}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def box(name, payload, extended=False):
    if extended:
        return struct.pack('>I4sQ', 1, name, len(payload) + 16) + payload
    return struct.pack('>I4s', len(payload) + 8, name) + payload


def boxes(data):
    result = []
    offset = 0
    while offset < len(data):
        size, name = struct.unpack_from('>I4s', data, offset)
        header = 8
        if size == 1:
            size = struct.unpack_from('>Q', data, offset + 8)[0]
            header = 16
        if size < header or offset + size > len(data):
            raise ValueError(f'invalid fixture box at {offset}')
        result.append((name, data[offset + header:offset + size]))
        offset += size
    return result


def children(meta):
    return boxes(meta[4:])


def make_meta(entries):
    return b'\0' * 4 + b''.join(box(name, payload) for name, payload in entries)


def replace_child(meta, target, replacement):
    return make_meta([(name, replacement if name == target else payload) for name, payload in children(meta)])


def numeric_values():
    data = [(1, 0, b'a' * 100), (1, 1041, b'second'), (1, 0, b'a' * 100),
            (33, 7, b'\0\xff\0'), (0xffffffff, 0xffffffff, b'')]
    return [box(b'data', struct.pack('>II', kind, locale) + payload) for kind, locale, payload in data]


class MdtaUpstreamProbeTest(unittest.TestCase):
    native_assertions = 0
    cases = 0

    @classmethod
    def setUpClass(cls):
        """Generate video/audio/subtitle media once; mutate only copied terminal moov metadata."""
        probe = os.environ.get('MDTA_UPSTREAM_PROBE')
        if not probe or not Path(probe).is_file():
            raise RuntimeError('set MDTA_UPSTREAM_PROBE to the compiled test/mp4_mdta_upstream_probe.cpp executable')
        cls.probe = probe
        cls.directory = tempfile.TemporaryDirectory(prefix='mdta-upstream-contract-')
        cls.root = Path(cls.directory.name)
        cls.ffmpeg = os.environ.get('FFMPEG', '/Users/nasu/Bin/ffmpeg')
        cls.ffprobe = os.environ.get('FFPROBE', cls.ffmpeg.replace('ffmpeg', 'ffprobe'))
        source = cls.root / 'generated.mp4'
        run(os.environ.get('RUBY', '/opt/homebrew/opt/ruby/bin/ruby'),
            str(REPO / 'test/generate_mp4_mdta_fixture.rb'), str(source))
        subtitle = cls.root / 'subtitle.srt'
        subtitle.write_text('1\n00:00:00,000 --> 00:00:00,900\nSubtitle\n')
        cls.fixture = cls.root / 'original.mp4'
        run(cls.ffmpeg, '-v', 'error', '-i', str(source), '-i', str(subtitle),
            '-map', '0', '-map', '1', '-c', 'copy', '-c:s', 'mov_text',
            '-movflags', 'use_metadata_tags', str(cls.fixture))
        cls.original = cls.fixture.read_bytes()
        if boxes(cls.original)[-1][0] != b'moov':
            raise RuntimeError('terminal moov is required for fixture edits without moving media')
        cls.original_digest = hashlib.sha256(cls.original).hexdigest()

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def setUp(self):
        self.path = self.root / 'copy.mp4'
        shutil.copyfile(self.fixture, self.path)

    def tearDown(self):
        self.assertEqual(self.original_digest, hashlib.sha256(self.fixture.read_bytes()).hexdigest(),
                         'source fixture was modified')

    def execute(self, mode):
        args = [self.probe, mode, str(self.path)]
        if mode == 'restore':
            args.append(str(REPO / 'test/data/globe_east_90.jpg'))
        output = run(*args)
        self.assertIn('PASS ' + mode, output)
        self.__class__.native_assertions += int(re.search(r'assertions=(\d+)', output).group(1))
        self.__class__.cases += 1
        return output

    def rewrite_meta(self, transform):
        """Rebuild ancestor sizes while leaving all sample offsets and mdat bytes unchanged."""
        def walk(data):
            result = b''
            for name, payload in boxes(data):
                if name in (b'moov', b'udta'):
                    payload = walk(payload)
                if name == b'meta':
                    payload = transform(payload)
                result += box(name, payload)
            return result
        self.path.write_bytes(walk(self.path.read_bytes()))

    def media(self, path):
        output = run(self.ffprobe, '-v', 'error', '-show_packets', '-show_data_hash', 'sha256',
                     '-show_entries', 'packet=stream_index,pts,dts,duration,data_hash:stream=index,id,codec_name,codec_type',
                     '-of', 'json', str(path))
        report = json.loads(output)
        index_to_id = {s['index']: s['id'] for s in report['streams']}
        streams = {s['id']: {key: value for key, value in s.items() if key != 'index'} for s in report['streams']}
        packets = {track_id: [] for track_id in streams}
        for packet in report.get('packets', []):
            packets[index_to_id[packet['stream_index']]].append({key: value for key, value in packet.items() if key != 'stream_index'})
        return streams, packets

    def test_public_value_type_copy_assignment_and_swap(self):
        before = self.path.read_bytes()
        self.execute('value-types')
        self.assertEqual(before, self.path.read_bytes())

    def test_same_file_lifetime_artwork_chapters_and_media(self):
        before_streams, before_packets = self.media(self.path)
        self.assertTrue(any(s['codec_type'] == 'subtitle' for s in before_streams.values()))
        self.execute('restore')
        after_streams, after_packets = self.media(self.path)
        moov = next(p for n, p in boxes(self.path.read_bytes()) if n == b'moov')
        udta = next(p for n, p in boxes(moov) if n == b'udta')
        meta = next(p for n, p in boxes(udta) if n == b'meta')
        ilst = next(p for n, p in children(meta) if n == b'ilst')
        keys = next(p for n, p in children(meta) if n == b'keys')
        offset, index, target = 8, 1, None
        while offset < len(keys):
            size = struct.unpack_from('>I', keys, offset)[0]
            if keys[offset + 8:offset + size] == b'audio_normalization':
                target = struct.pack('>I', index)
            offset += size
            index += 1
        items = [p for n, p in boxes(ilst) if n == target]
        self.assertEqual(1, len(items), 'changed values must use one parent item')
        self.assertEqual(numeric_values(), [box(n, p) for n, p in boxes(items[0])])
        for index, stream in before_streams.items():
            self.assertEqual(stream, after_streams[index])
            self.assertEqual(before_packets[index], after_packets[index])

    def test_invalid_input_and_overflow_planner(self):
        before = self.path.read_bytes()
        self.execute('invalid')
        self.assertEqual(before, self.path.read_bytes())

    def test_empty_keys_table(self):
        self.rewrite_meta(lambda meta: replace_child(replace_child(meta, b'keys', b'\0' * 8), b'ilst', b''))
        self.execute('empty')

    def test_keys_without_values(self):
        self.rewrite_meta(lambda meta: replace_child(meta, b'ilst', b''))
        self.execute('keys-only')

    def test_removal_reindex_and_strip(self):
        self.execute('remove-strip')

    def test_multiple_parent_items_and_data_children_preserved(self):
        name = None
        parts = numeric_values()
        def transform(meta):
            nonlocal name
            keys = next(p for n, p in children(meta) if n == b'keys')
            offset, index = 8, 1
            while offset < len(keys):
                size = struct.unpack_from('>I', keys, offset)[0]
                if keys[offset + 8:offset + size] == b'audio_normalization':
                    name = struct.pack('>I', index)
                    break
                offset += size
                index += 1
            self.assertIsNotNone(name)
            original_ilst = next(p for n, p in children(meta) if n == b'ilst')
            result = b''
            for n, payload in boxes(original_ilst):
                result += box(name, b''.join(parts[:2])) + box(name, b''.join(parts[2:])) if n == name else box(n, payload)
            return replace_child(meta, b'ilst', result)
        self.rewrite_meta(transform)
        def raw_items(path):
            moov = next(p for n, p in boxes(path.read_bytes()) if n == b'moov')
            udta = next(p for n, p in boxes(moov) if n == b'udta')
            meta = next(p for n, p in boxes(udta) if n == b'meta')
            ilst = next(p for n, p in children(meta) if n == b'ilst')
            return [box(n, p) for n, p in boxes(ilst) if n == name]
        before = raw_items(self.path)
        self.assertEqual(2, len(before))
        self.execute('read-values')
        self.assertEqual(before, raw_items(self.path))

    def test_mdir_absence_keeps_ordinary_api(self):
        # Generate a genuine mdir-only fixture rather than relabelling numeric mdta items.
        self.path.unlink()
        run(self.ffmpeg, '-v', 'error', '-i', str(self.fixture), '-map', '0', '-c', 'copy',
            '-map_metadata', '-1', '-metadata', 'title=mdir title', str(self.path))
        self.execute('absent')

    def test_unsupported_structures_are_rejected_without_disk_writes(self):
        def remove_child(meta, target):
            return make_meta([(n, p) for n, p in children(meta) if n != target])
        def duplicate_key(meta):
            payload = next(p for n, p in children(meta) if n == b'keys')
            count = struct.unpack_from('>I', payload, 4)[0]
            first_size = struct.unpack_from('>I', payload, 8)[0]
            return replace_child(meta, b'keys', payload[:4] + struct.pack('>I', count + 1) + payload[8:] + payload[8:8 + first_size])
        mutations = {
            'missing-handler': lambda m: remove_child(m, b'hdlr'),
            'wrong-handler-with-keys': lambda m: m.replace(b'mdta', b'xxxx', 1),
            'missing-keys': lambda m: remove_child(m, b'keys'),
            'missing-ilst': lambda m: remove_child(m, b'ilst'),
            'duplicate-keys-atom': lambda m: m + box(b'keys', b'\0' * 8),
            'duplicate-ilst': lambda m: m + box(b'ilst', b''),
            'duplicate-handler': lambda m: m + box(b'hdlr', b'\0' * 8 + b'mdta' + b'\0' * 12),
            'other-namespace': lambda m: m.replace(b'mdtatitle', b'xxxxtitle', 1),
            'duplicate-key-name': duplicate_key,
            'invalid-key-utf8': lambda m: m.replace(b'mdtatitle', b'mdta\xffitle', 1),
            'nul-key': lambda m: m.replace(b'mdtatitle', b'mdtat\0tle', 1),
            'unknown-numeric-child': lambda m: m.replace(b'data', b'xxxx', 1),
            'non-fullbox': lambda m: m[4:],
            'zero-index': lambda m: replace_child(m, b'ilst', box(b'\0' * 4, numeric_values()[0])),
            'out-of-range-index': lambda m: replace_child(m, b'ilst', box(b'\xff' * 4, numeric_values()[0])),
            'ambiguous-fourcc': lambda m: replace_child(m, b'ilst', box(b'zzzz', numeric_values()[0])),
        }
        for name, transform in mutations.items():
            with self.subTest(name=name):
                self.path.write_bytes(self.original)
                self.rewrite_meta(transform)
                before = self.path.read_bytes()
                self.execute('unsupported')
                self.assertEqual(before, self.path.read_bytes())

    def test_multiple_meta_orders_and_scopes(self):
        for handler in (b'mdir', b'mdta'):
            for first in (True, False):
                with self.subTest(handler=handler, first=first):
                    self.path.write_bytes(self.original)
                    def transform(data):
                        result = b''
                        for name, payload in boxes(data):
                            if name == b'moov':
                                payload = transform(payload)
                            elif name == b'udta':
                                extra = box(b'meta', b'\0' * 4 + box(b'hdlr', b'\0' * 8 + handler + b'\0' * 12) + box(b'ilst', b''))
                                payload = extra + payload if first else payload + extra
                            result += box(name, payload)
                        return result
                    self.path.write_bytes(transform(self.original))
                    before = self.path.read_bytes()
                    self.execute('unsupported')
                    self.assertEqual(before, self.path.read_bytes())
        # Move the only mdta meta directly under moov; it must not be reported as absent.
        self.path.write_bytes(self.original)
        top = boxes(self.original)
        moov = next(p for n, p in top if n == b'moov')
        udta = next(p for n, p in boxes(moov) if n == b'udta')
        meta = next(p for n, p in boxes(udta) if n == b'meta')
        new_moov = b''.join(box(n, b''.join(box(c, p) for c, p in boxes(payload) if c != b'meta') if n == b'udta' else payload)
                            for n, payload in boxes(moov)) + box(b'meta', meta)
        self.path.write_bytes(b''.join(box(n, new_moov if n == b'moov' else p) for n, p in top))
        before = self.path.read_bytes()
        self.execute('unsupported')
        self.assertEqual(before, self.path.read_bytes())

    def test_unverified_layouts_and_multiple_udta_are_rejected(self):
        for variant in ('extended-meta', 'multiple-udta', 'fragmented'):
            with self.subTest(variant=variant):
                self.path.write_bytes(self.original)
                def transform(data):
                    result = b''
                    for name, payload in boxes(data):
                        if name in (b'moov', b'udta'):
                            payload = transform(payload)
                        result += box(name, payload, extended=variant == 'extended-meta' and name == b'meta')
                        if name == b'udta' and variant == 'multiple-udta':
                            result += box(b'udta', b'')
                    return result
                output = transform(self.original)
                if variant == 'fragmented':
                    output += box(b'moof', b'')
                self.path.write_bytes(output)
                before = self.path.read_bytes()
                self.execute('unsupported')
                self.assertEqual(before, self.path.read_bytes())

    def test_read_only_save_rejection_preserves_pending_edits(self):
        before = self.path.read_bytes()
        self.execute('read-only')
        self.assertEqual(before, self.path.read_bytes())

    def test_invalid_file_save_rejection(self):
        self.path.write_bytes(b'not an MP4')
        before = self.path.read_bytes()
        self.execute('invalid-file')
        self.assertEqual(before, self.path.read_bytes())

    def test_track_level_mdta_is_unsupported_rather_than_absent(self):
        top = boxes(self.original)
        moov = next(p for n, p in top if n == b'moov')
        udta = next(p for n, p in boxes(moov) if n == b'udta')
        meta = next(p for n, p in boxes(udta) if n == b'meta')
        result, added = b'', False
        for name, payload in boxes(moov):
            if name == b'udta':
                payload = b''.join(box(n, p) for n, p in boxes(payload) if n != b'meta')
            elif name == b'trak' and not added:
                payload = b''.join(box(n, p + box(b'meta', meta) if n == b'mdia' else p) for n, p in boxes(payload))
                added = True
            result += box(name, payload)
        self.assertTrue(added)
        self.path.write_bytes(b''.join(box(n, result if n == b'moov' else p) for n, p in top))
        before = self.path.read_bytes()
        self.execute('unsupported')
        self.assertEqual(before, self.path.read_bytes())

    def test_large_sparse_file_metadata_and_qt_offset_rejection(self):
        roots = boxes(self.original)
        with self.path.open('wb') as output:
            for name, payload in roots:
                if name == b'moov':
                    for _ in range(2):
                        size = 0x80000000
                        output.write(struct.pack('>I4s', size, b'free'))
                        output.seek(size - 8, 1)
                output.write(box(name, payload))
        self.execute('large-file')

    def test_late_chapter_failure_preserves_pending_state(self):
        self.execute('chapter-failure')

    def test_chapter_preflight_rejection_can_be_corrected(self):
        self.execute('chapter-preflight')

    def test_direct_item_map_edits_and_tag_save(self):
        self.execute('direct-map')

    def test_unreported_write_failure_is_detected_by_readback(self):
        before = self.path.read_bytes()
        output = self.execute('io-limitation')
        self.assertIn('DETECTED_FAILURE save=0', output)
        self.assertEqual(before, self.path.read_bytes())


if __name__ == '__main__':
    suite = (unittest.defaultTestLoader.loadTestsFromNames(sys.argv[1:], MdtaUpstreamProbeTest)
             if len(sys.argv) > 1 else unittest.defaultTestLoader.loadTestsFromTestCase(MdtaUpstreamProbeTest))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(f'native cases={MdtaUpstreamProbeTest.cases} assertions={MdtaUpstreamProbeTest.native_assertions}')
    raise SystemExit(0 if result.wasSuccessful() else 1)
