import tempfile
import unittest
import struct
import zlib
import hashlib
from unittest.mock import patch
from pathlib import Path
from zipfile import ZipFile

from scripts.release_audit import audit_paths, export_release, strip_png_metadata, PUBLIC_CONTACT_EMAIL


class ReleaseAuditTests(unittest.TestCase):
    def test_binary_screenshot_requires_exact_reviewed_hash(self):
        from scripts import release_audit
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'demo.jpg'
            reviewed = b'\xff\xd8\xffreviewed-synthetic-demo'
            path.write_bytes(reviewed)
            with patch.object(release_audit, 'REVIEWED_BINARY_HASHES',
                              {'demo.jpg': hashlib.sha256(reviewed).hexdigest()}, create=True):
                self.assertEqual(audit_paths(root, ['demo.jpg']), [])
                path.write_bytes(reviewed + b'changed')
                self.assertEqual(audit_paths(root, ['demo.jpg'])[0]['rule'], 'unreviewed-binary')

    def test_nonempty_real_credentials_in_env_example_block_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.env.example').write_text('LIVEKIT_API_SECRET=' + 'unexpectedRealValue123456', encoding='utf-8')
            self.assertEqual(audit_paths(root, ['.env.example'])[0]['rule'], 'credential-literal')

    def test_only_explicitly_approved_contact_locations_allow_public_email(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ['README.md', 'random.txt']:
                (root / name).write_text(PUBLIC_CONTACT_EMAIL, encoding='utf-8')
            self.assertEqual(audit_paths(root, ['README.md']), [])
            self.assertEqual(audit_paths(root, ['random.txt'])[0]['rule'], 'email')

    def test_release_uses_standard_apache_license_without_use_restrictions(self):
        root = Path(__file__).resolve().parents[2]
        license_text = (root / 'LICENSE').read_text(encoding='utf-8')
        self.assertIn('Version 2.0, January 2004', license_text)
        self.assertIn('Grant of Copyright License', license_text)
        self.assertIn('END OF TERMS AND CONDITIONS', license_text)
        readme = (root / 'README.md').read_text(encoding='utf-8')
        self.assertIn('本项目采用标准', readme)
        self.assertNotIn('商业使用必须取得授权', readme)
        self.assertNotIn('许可方案待维护者确认', readme)

    def test_png_metadata_removal_preserves_pixel_chunks(self):
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
        pixels = chunk(b'IDAT', b'unchanged-pixel-payload')
        header = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', b'header')
        end = chunk(b'IEND', b'')
        original = header + chunk(b'tEXt', b'Author\0private') + pixels + end
        self.assertEqual(strip_png_metadata(original), header + pixels + end)
        with self.assertRaises(ValueError):
            strip_png_metadata(b'not-a-png')

    def test_detects_credentials_and_personal_data_without_echoing_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            content = '\n'.join([
                'token = "sk-' + 'a' * 35 + '"',
                'contact = "private' + '@mail.test"',
                'path = "C:/' + 'Users/' + 'private-person/work"',
                'host = "192.168.' + '1.157"',
                'secret = "' + 'randomCredential123456789' + '"',
            ])
            (root / 'config.py').write_text(content, encoding='utf-8')
            findings = audit_paths(root, ['config.py'])
            self.assertTrue({'provider-key', 'email', 'home-path', 'private-ip',
                             'credential-literal'} <= {item['rule'] for item in findings})
            self.assertNotIn('randomCredential', str(findings))
            self.assertNotIn('private-person', str(findings))

    def test_allows_documentation_examples_and_synthetic_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.env.example').write_text('API_SECRET=\nHOST=127.0.0.1\n', encoding='utf-8')
            (root / 'test_sample.py').write_text('password = "synthetic-test-password"\nemail = "user@example.com"', encoding='utf-8')
            self.assertEqual(audit_paths(root, ['.env.example', 'test_sample.py']), [])

    def test_rejects_private_files_archives_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ['.env', 'data.db', 'private.key', 'meeting.mp4', 'source.zip']:
                (root / name).write_text('private', encoding='utf-8')
            self.assertEqual(len(audit_paths(root, ['.env', 'data.db', 'private.key', 'meeting.mp4', 'source.zip'])), 5)

    def test_export_fails_before_writing_if_audit_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.env').write_text('private', encoding='utf-8')
            output = root / 'release.zip'
            with self.assertRaises(ValueError):
                export_release(root, ['.env'], output)
            self.assertFalse(output.exists())

    def test_export_contains_only_audited_source_without_git_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'README.md').write_text('# Demo', encoding='utf-8')
            output = root / 'release.zip'
            export_release(root, ['README.md'], output)
            with ZipFile(output) as archive:
                self.assertEqual(archive.namelist(), ['vibemeeting/README.md'])

    def test_rejects_path_traversal_and_git_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            findings = audit_paths(Path(directory), ['../private.txt', '.git/config'])
            self.assertEqual(len(findings), 2)

    def test_repository_readme_has_release_sections_and_valid_local_links(self):
        import re
        root = Path(__file__).resolve().parents[2]
        readme = (root / 'README.md').read_text(encoding='utf-8')
        for section in ['## 项目动机', '## 使用体验与Feature', '## 一键安装', '## 文档与开发', '## 许可证与联系']:
            self.assertIn(section, readme)
        for target in re.findall(r'\]\((\./[^)#]+)(?:#[^)]*)?\)', readme):
            self.assertTrue((root / target).is_file(), target)


if __name__ == '__main__':
    unittest.main()
