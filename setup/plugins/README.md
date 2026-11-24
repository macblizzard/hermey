# The `hermes-genui` plugin bundle

`hermes-genui/desktop/plugin.js` is the generated card plugin the Hermey apps load from
`/v1/genui/plugin.js`. Hermes upstream does not ship it, so it is versioned here and installed into
`<engine>/plugins/hermes-genui` by `setup/install.sh` (from this directory on `--from-source`, and
from the release's `hermes-genui-plugin.tar.gz` otherwise).

It is a build output, not hand-edited source. Refresh it from the engine checkout that builds the
plugin — `<engine-checkout>/plugins/hermes-genui/` in the Hermes source tree, keeping
`desktop/plugin.js` and `.digest` together:

```sh
cp -R <engine-checkout>/plugins/hermes-genui/. setup/plugins/hermes-genui/
```

The release workflow tars this directory as-is; `Tests/test_installer_hermeyd.py` refuses a tree
without a non-trivial `desktop/plugin.js`.
