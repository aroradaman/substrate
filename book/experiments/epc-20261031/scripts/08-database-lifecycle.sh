#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
bash "$TASK_EVIDENCE/scripts/capture-database.sh" running
run_step counter-db-suspend kubectl-ate suspend actor lifecycle-counter -a ate-demo-counter --mode=sync -o json
bash "$TASK_EVIDENCE/scripts/capture-database.sh" suspended
run_step counter-db-request curl --silent --show-error --fail --max-time 60 http://127.0.0.1:18000/
bash "$TASK_EVIDENCE/scripts/capture-database.sh" resumed
