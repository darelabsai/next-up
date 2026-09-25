from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PublicDocumentationTests(unittest.TestCase):
    def test_public_markdown_file_links_resolve(self):
        files = [ROOT / 'README.md', ROOT / 'CONTRIBUTING.md', ROOT / 'SECURITY.md']
        files += list((ROOT / 'docs').rglob('*.md'))
        for path in files:
            for target in re.findall(r'\]\(([^\s)]+)\)', path.read_text()):
                if '://' in target or target.startswith(('#', 'mailto:')):
                    continue
                relative = target.split('#', 1)[0]
                if relative:
                    with self.subTest(path=str(path.relative_to(ROOT)), target=target):
                        self.assertTrue((path.parent / relative).is_file())

    def test_setup_distinguishes_first_install_from_update(self):
        text = (ROOT / 'docs/setup.md').read_text()
        for phrase in ('first-install bootstrap', 'existing installed app',
                       '/Applications/cmux.app', 'hermes --tui',
                       'not a signed/notarized', 'Jarvis Bridge is optional',
                       'Do not also install a LaunchAgent',
                       'fake system commands', 'Uninstall'):
            self.assertIn(phrase, text)

    def test_scope_does_not_reuse_historical_acceptance(self):
        text = (ROOT / 'docs/release-scope.md').read_text()
        self.assertIn('not evidence that a new build', text)
        self.assertIn('No Claude Code, Codex, Grok Build', text)
        self.assertIn('not an executable whitelist', text)
        self.assertIn('not a metadata-only observer', text)


if __name__ == '__main__':
    unittest.main()
