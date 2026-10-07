import re
import unittest
from pathlib import Path

import yaml

from scripts.validate_release import validate_release_ref

ROOT = Path(__file__).resolve().parents[2]


class PyPIPublishingTests(unittest.TestCase):
    def test_publishing_requires_an_exact_version_tag(self):
        self.assertEqual(validate_release_ref('refs/tags/v0.1.0', '0.1.0'), '0.1.0')
        for ref in ['refs/heads/main', 'refs/heads/v0.1.0', 'refs/tags/v0.1.1', 'refs/tags/v0.1.0; echo unsafe']:
            with self.subTest(ref=ref), self.assertRaises(ValueError):
                validate_release_ref(ref, '0.1.0')

    def test_workflow_separates_unprivileged_build_from_oidc_upload(self):
        workflow = yaml.load((ROOT / '.github/workflows/publish-pypi.yml').read_text(encoding='utf-8'), Loader=yaml.BaseLoader)
        self.assertEqual(workflow['permissions'], {'contents': 'read'})
        self.assertEqual(workflow['on']['release']['types'], ['published'])
        self.assertIn('pull_request', workflow['on'])
        self.assertEqual(workflow['on']['workflow_dispatch']['inputs']['publish']['default'], 'false')
        publisher = workflow['jobs']['publish']
        self.assertEqual(publisher['needs'], 'build')
        self.assertEqual(publisher['permissions'], {'id-token': 'write'})
        self.assertEqual(publisher['environment']['name'], 'pypi')
        self.assertIn("github.repository == 'changkaiyan/vibemeeting'", publisher['if'])
        for step in publisher['steps']:
            self.assertNotIn('run', step)
        upload = publisher['steps'][-1]
        self.assertTrue(upload['uses'].startswith('pypa/gh-action-pypi-publish@'))
        self.assertNotIn('password', upload.get('with', {}))
        self.assertNotIn('secrets.', str(workflow))
        for job in workflow['jobs'].values():
            for step in job.get('steps', []):
                if 'uses' in step:
                    self.assertRegex(step['uses'], r'@[0-9a-f]{40}$')

    def test_build_checks_privacy_version_tests_and_wheel_before_upload(self):
        workflow = yaml.load((ROOT / '.github/workflows/publish-pypi.yml').read_text(encoding='utf-8'), Loader=yaml.BaseLoader)
        commands = '\n'.join(step.get('run', '') for step in workflow['jobs']['build']['steps'])
        for required in ['scripts/validate_release.py', 'scripts/release_audit.py',
                         'unittest discover', 'manage.py test', '-m build', 'twine check',
                         'scripts.tests.test_distribution_artifacts', 'vibemeeting --prepare-only']:
            self.assertIn(required, commands)
        version = re.search(r'(?ms)^\[project\].*?^version = "([^"]+)"', (ROOT / 'pyproject.toml').read_text(encoding='utf-8')).group(1)
        from vibemeeting import __version__
        self.assertEqual(version, __version__)


if __name__ == '__main__':
    unittest.main()
