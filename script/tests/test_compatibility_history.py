import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'compatibility'))
from discover_historical_casks import literal_descriptor


class HistoricalCaskTests(unittest.TestCase):
    def recipe(self, url='https://vendor.invalid/#{version}/App-#{arch}.dmg'):
        return f'''cask "app" do
  arch arm: "arm64", intel: "x64"
  version "1.2.3"
  sha256 arm: "{'a' * 64}",
         intel: "{'b' * 64}"
  url "{url}", verified: "vendor.invalid/"
  app "App.app"
end
'''

    def test_literal_architecture_and_version_substitutions_retain_actual_checksum(self):
        item = literal_descriptor(self.recipe())
        self.assertEqual(item['url'], 'https://vendor.invalid/1.2.3/App-arm64.dmg')
        self.assertEqual(item['sha256'], 'a' * 64)
        self.assertEqual(item['applicationNames'], ['App.app'])
        self.assertEqual(literal_descriptor(self.recipe('https://vendor.invalid/#{version.major_minor}/App.dmg'))['url'],
                         'https://vendor.invalid/1.2/App.dmg')

    def test_explicit_arm_branch_overrides_global_values_without_executing_ruby(self):
        recipe = self.recipe().replace('  app "App.app"', f'''  on_arm do
    version "1.3.0"
    sha256 "{'c' * 64}"
  end
  app "App.app"''')
        item = literal_descriptor('system("never-execute-research-code")\n' + recipe)
        self.assertEqual(item['version'], '1.3.0')
        self.assertEqual(item['sha256'], 'c' * 64)
        self.assertIn('/1.3.0/', item['url'])

    def test_unsupported_ruby_interpolations_missing_proofs_and_duplicate_fields_stay_held(self):
        for recipe in [self.recipe('https://vendor.invalid/#{system(command)}/App.dmg'),
                       self.recipe('https://secret:password@vendor.invalid/App.dmg'),
                       self.recipe().replace('version "1.2.3"', 'version :latest'),
                       self.recipe().replace('version "1.2.3"', 'version "1.2.3-beta.1"'),
                       self.recipe().replace('  version "1.2.3"', '  version "1.2.3"\n  version "1.2.4"'),
                       self.recipe().replace('intel: "x64"', 'arm: "other"'),
                       self.recipe().replace('intel: "x64"', 'intel: compute_architecture()'),
                       self.recipe().replace('a' * 64, 'invalid'),
                       self.recipe().replace('intel: "' + 'b' * 64 + '"', 'arm: "' + 'b' * 64 + '"')]:
            self.assertIsNone(literal_descriptor(recipe))


if __name__ == '__main__':
    unittest.main()
