import importlib.util
import pathlib
import sys
import tempfile
import unittest
import zipfile

DIRECTORY = pathlib.Path(__file__).resolve().parents[1] / 'compatibility'
sys.path.insert(0, str(DIRECTORY))
import discover_appcasts


class AppcastDiscoveryTests(unittest.TestCase):
    def testStaticRecipesAreReadWithoutExecutingRubyAndOnlyLiteralFeedsBecomeLeads(self):
        recipes = {
            'app': 'system("touch /tmp/never-execute-research-recipes")\n  livecheck do\n    url "https://vendor.invalid/appcast.xml"\n    strategy :sparkle\n  end\n',
            'interpolated': '  livecheck do\n    url "https://vendor.invalid/#{version}/feed.xml"\n    strategy :sparkle\n  end\n',
            'ambiguous': '  livecheck do\n    url "https://vendor.invalid/a.xml"\n    url "https://vendor.invalid/b.xml"\n    strategy :sparkle\n  end\n',
            'commented': '  livecheck do\n    url "https://vendor.invalid/feed.xml"\n    # strategy :sparkle\n  end\n',
            'credentials': '  livecheck do\n    url "https://secret:password@vendor.invalid/feed.xml"\n    strategy :sparkle\n  end\n',
            'variant@beta': '  livecheck do\n    url "https://vendor.invalid/beta.xml"\n    strategy :sparkle\n  end\n',
        }
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'source.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                for token, recipe in recipes.items():
                    archive.writestr('snapshot/Casks/a/' + token + '.rb', recipe)
            leads = discover_appcasts.static_feeds(path)
        self.assertEqual([row['token'] for row in leads], ['app'])
        self.assertFalse(leads[0]['verified'])
        self.assertEqual(leads[0]['appcastURL'], 'https://vendor.invalid/appcast.xml')


if __name__ == '__main__':
    unittest.main()
