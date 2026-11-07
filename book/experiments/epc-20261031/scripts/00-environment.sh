#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
{
  date -u +%FT%TZ
  hostname
  uname -a
  id
  nproc
  free -h
  df -h / /home/daman
  stat -fc %T /sys/fs/cgroup
  go version
  kubectl version --client
  docker version
  docker buildx version
  git rev-parse HEAD
  git status --short
  docker ps --format '{{.Names}} {{.Image}}'
} > "$TASK_EVIDENCE/environment.txt" 2>&1
sha256sum go.mod go.sum .ko.yaml hack/create-kind-cluster.sh > "$TASK_EVIDENCE/source-inputs.sha256"
cat "$TASK_EVIDENCE/environment.txt"
