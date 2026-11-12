# Native rebuild proof fixture

Copied from the clean `native-rebuild-test` capture
`20261111T233134-native-rebuild-test` at commit `1ff012e`.

The fixture contains only the summary and the three guest serial logs. CI uses
it to render and validate `demo/render-self-build.py` without a KVM runner.
This is an evidence replay, not a live proof run.
