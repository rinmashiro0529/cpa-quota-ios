import base64
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / 'ci' / 'validate_public_copy.py'

class PublicCopyTests(unittest.TestCase):
    def test_reports_address_without_echoing_contents(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'public.md').write_text('Rin，private example\n', encoding='utf-8')
            subprocess.run(['git', '-C', str(root), 'add', 'public.md'], check=True)
            result = subprocess.run([sys.executable, '-I', '-B', str(SCRIPT), '--root', str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('public.md:1:', result.stdout)
            self.assertNotIn('private example', result.stdout)

    def test_markdown_boundaries_and_encodings(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            lines = ['# Rin，heading', '- Rin: list', '> 主代理 completed',
                     '````text', 'Rin, ignored', '```', '子代理 ignored', '````',
                     '~~~', '/Rin, ignored', '~~~', 'Author: Rin',
                     'https://example.org/Rin', '本轮按合同未经授权']
            text = (chr(13) + chr(10)).join(lines)
            (root / 'sample.md').write_bytes(bytes([239, 187, 191]) + text.encode('utf-8'))
            (root / 'private.md').write_text('Rin, untracked', encoding='utf-8')
            subprocess.run(['git', '-C', str(root), 'add', 'sample.md'], check=True)
            result = subprocess.run([sys.executable, '-I', '-B', str(SCRIPT), '--root', str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ['sample.md:1: private-address', 'sample.md:2: private-address', 'sample.md:3: assistant-narration'])

    def test_legitimate_attribution_and_untracked_private_file_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'readme.md').write_text('Author: Rin' + chr(10) + 'https://example.org/Rin,' + chr(10) + '[Author page](/Rin,)', encoding='utf-8')
            (root / 'private.md').write_text('Rin，private', encoding='utf-8')
            subprocess.run(['git', '-C', str(root), 'add', 'readme.md'], check=True)
            result = subprocess.run([sys.executable, '-I', '-B', str(SCRIPT), '--root', str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')

    def test_slash_address_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'readme.md').write_text('/rIn, hello', encoding='utf-8')
            subprocess.run(['git', '-C', str(root), 'add', 'readme.md'], check=True)
            result = subprocess.run([sys.executable, '-I', '-B', str(SCRIPT), '--root', str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout.splitlines(), ['readme.md:1: private-address'])

    def test_restore_log_preserves_checksum_validation(self):
        exporter = SCRIPT.with_name('export_frontend_evidence.py')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            data = b'review-copy-fixture'
            metadata = {'file': 'review.jpg', 'bytes': len(data), 'previewSHA256': hashlib.sha256(data).hexdigest()}
            lines = ['FRONTEND_SCREENSHOT_BEGIN ' + json.dumps(metadata),
                     'FRONTEND_SCREENSHOT_DATA ' + base64.b64encode(data).decode('ascii'),
                     'FRONTEND_SCREENSHOT_END']
            log = root / 'job.log'
            log.write_text(chr(10).join(lines), encoding='utf-8')
            result = subprocess.run([sys.executable, '-I', '-B', str(exporter), '--evidence', str(root / 'out'), '--restore-log', str(log)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / 'out' / 'review.jpg').read_bytes(), data)
            metadata['previewSHA256'] = '0' * 64
            lines[0] = 'FRONTEND_SCREENSHOT_BEGIN ' + json.dumps(metadata)
            log.write_text(chr(10).join(lines), encoding='utf-8')
            result = subprocess.run([sys.executable, '-I', '-B', str(exporter), '--evidence', str(root / 'bad'), '--restore-log', str(log)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('integrity check failed', result.stderr)

    def test_invalid_root_and_missing_argument(self):
        for arguments in ([], ['--root', 'nonexistent-path-for-public-copy-test']):
            result = subprocess.run([sys.executable, '-I', '-B', str(SCRIPT), *arguments], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)

    def test_export_rejects_symlink_before_invoking_xcrun(self):
        exporter = SCRIPT.with_name('export_frontend_evidence.py')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / 'actual-result'
            target.mkdir()
            evidence = root / 'evidence'
            evidence.mkdir()
            try:
                (evidence / 'NativeTests.xcresult').symlink_to(target, target_is_directory=True)
            except (OSError, NotImplementedError) as exc:
                self.skipTest('Directory symlinks unavailable: ' + str(exc))
            result = subprocess.run([sys.executable, '-I', '-B', str(exporter), '--evidence', str(evidence), '--export-screenshots'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Symlinked result bundles', result.stderr)

    def test_export_cli_missing_result(self):
        exporter = SCRIPT.with_name('export_frontend_evidence.py')
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run([sys.executable, '-I', '-B', str(exporter), '--evidence', tmp, '--export-screenshots'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('no native test or screenshot pass is claimed', result.stdout)

if __name__ == '__main__':
    unittest.main()
