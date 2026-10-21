#!/usr/bin/env sh
# Offline approximation of what Argo CD will generate from this repo.
# Needs Go >= 1.22 and Python 3 with PyYAML. Usage: gitops/tools/render-check/run.sh [--quiet]
# Set SIM_OUT=/path/out.yaml to also write every rendered ApplicationSet and Application.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
(cd "$here" && go build -o "$here/render" .)
exec python3 -I "$here/simulate.py" "$repo" "$here/render" "$@"
