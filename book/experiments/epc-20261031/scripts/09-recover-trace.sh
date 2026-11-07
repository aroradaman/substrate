#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
run_step counter-revert-after-trace kubectl-ate revert actor lifecycle-counter -a ate-demo-counter -o json
run_step counter-recover-after-trace kubectl-ate resume actor lifecycle-counter -a ate-demo-counter -o json
run_step counter-recovered-request curl --silent --show-error --fail --max-time 60 http://127.0.0.1:18000/
