"""Guards for the shell wrappers that hand a build to the publish tool.

Both scripts are run by hand, at the moment a release matters, so a wrong default is only discovered
by shipping somewhere unintended. These tests hold the two facts that already went stale: the repo the
wrapper publishes to, and the one argument a mirrored publish cannot safely be given a default for.
"""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Tools" / "release" / "publish_github.sh"


class PublishWrapperTests(unittest.TestCase):
    def test_publishes_to_the_repo_this_tree_is(self):
        # `macblizzard/hermes-altstore` was the private predecessor's side-load repo and no longer
        # exists; a wrapper defaulting to it fails at the first API call, long after the build.
        text = WRAPPER.read_text()
        self.assertIn("macblizzard/hermey", text)
        self.assertNotIn("hermes-altstore", text)
        self.assertIn("--repo \"$REPO\"", text)

    def test_a_mirror_needs_the_url_it_is_served_on(self):
        # The publish tool defaults `--mirror-base-url` to a placeholder host, so a mirrored manifest
        # built without one points at a name nobody has while the publish reports success.
        text = WRAPPER.read_text()
        self.assertIn("MIRROR_BASE_URL", text)
        self.assertIn("--mirror-base-url", text)
        self.assertNotIn("hermes.example.ts.net", text)


if __name__ == "__main__":
    unittest.main()
