import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('duo_evidence', ROOT / 'ci/validate_duo_evidence.py')
duo = importlib.util.module_from_spec(spec); spec.loader.exec_module(duo)


class DuoEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.udid = str(uuid4())
        self.write('simulator.json', {'udid': self.udid, 'device': 'iPhone Duo', 'runtimeVersion': '27.1'})
        self.dimensions = {}
        for name, image, screen, angle, size in [
                ('before', 'outer-before', 'cover', 0, (1398, 2034)),
                ('confirmed', 'inner-open', 'inner', 180, (2853, 2007)),
                ('portrait', 'inner-portrait', 'inner', 180, (2007, 2853)),
                ('closed', 'outer-after', 'cover', 0, (2034, 1398))]:
            self.write(f'state-{name}.json', {'udid': self.udid, 'activeScreen': screen, 'hingeAngle': angle,
                                           'sizePoints': [size[0] / 3, size[1] / 3]})
            (self.root / (image + '.png')).write_bytes(b'synthetic-not-an-actual-screenshot')
            self.dimensions[image + '.png'] = size

    def write(self, name, data):
        (self.root / name).write_text(json.dumps(data))

    def change(self, name, **updates):
        data = json.loads((self.root / name).read_text()); data.update(updates); self.write(name, data)

    def validate(self):
        # These unit cases test state contracts only, not synthetic PNG pixels.
        with patch.object(duo, 'png_dimensions', side_effect=lambda p: self.dimensions[p.name]):
            return duo.validate(self.root)

    def test_complete_state_sequence_has_narrow_scope(self):
        result = self.validate()
        self.assertEqual(result['status'], 'passed'); self.assertEqual(len(result['screenshots']), 4)
        self.assertFalse(result['physicalDevice']); self.assertFalse(result['allWorkspacesTested'])

    def test_closed_or_wrong_display_cannot_pass_as_inner(self):
        for update in ({'activeScreen': 'cover'}, {'hingeAngle': 0}, {'hingeAngle': float('nan')}):
            with self.subTest(update=update):
                self.change('state-confirmed.json', activeScreen='inner', hingeAngle=180, **{})
                self.change('state-confirmed.json', **update)
                with self.assertRaises(ValueError): self.validate()

    def test_wrong_device_or_runtime_is_rejected(self):
        for field, value in [('device', 'iPhone 18 Pro'), ('runtimeVersion', '26.2')]:
            self.write('simulator.json', {'udid': self.udid, 'device': 'iPhone Duo', 'runtimeVersion': '27.1', field: value})
            with self.assertRaises(ValueError): self.validate()

    def test_mismatched_udid_is_rejected(self):
        self.change('state-portrait.json', udid=str(uuid4()))
        with self.assertRaises(ValueError): self.validate()

    def test_wrong_geometry_or_missing_portrait_is_rejected(self):
        self.change('state-portrait.json', sizePoints=[951, 669])
        with self.assertRaises(ValueError): self.validate()

    def test_missing_state_fails_closed(self):
        (self.root / 'state-closed.json').unlink()
        with self.assertRaises(OSError): self.validate()

    def test_fake_png_is_rejected_without_pixel_mock(self):
        with self.assertRaises(ValueError): duo.png_dimensions(self.root / 'inner-open.png')

    def test_workflow_requires_portrait_and_metadata_validation(self):
        workflow = (ROOT / '.github/workflows/duo-inner-display.yml').read_text()
        self.assertIn('python3 -I -B ci/validate_duo_evidence.py', workflow)
        self.assertNotIn('if python3', workflow)
        self.assertIn('contents: read', workflow)
        self.assertNotIn('contents: write', workflow)
        self.assertIn('c6ff3e961a9858fb061907448e702d7d1617dc4a', workflow)


if __name__ == '__main__': unittest.main()
