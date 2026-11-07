#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
run_step build-ate-setup go build -p=8 -o "$TASK_EVIDENCE/bin/ate-setup" ./cmd/ate-setup
run_step build-kubectl-ate go build -p=8 -o "$TASK_EVIDENCE/bin/kubectl-ate" ./cmd/kubectl-ate
run_step resolve-kind hack/kind.sh version
go version -m "$TASK_EVIDENCE/bin/ate-setup" > "$TASK_EVIDENCE/ate-setup-build-info.txt"
go version -m "$TASK_EVIDENCE/bin/kubectl-ate" > "$TASK_EVIDENCE/kubectl-ate-build-info.txt"
