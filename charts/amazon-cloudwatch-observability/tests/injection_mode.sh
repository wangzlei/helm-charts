#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Checks how manager.instrumentationInjectionMode reaches the operator:
#
#   1. The default (old) renders no --instrumentation-injection-mode flag, so the
#      operator Deployment is unchanged from charts without the value.
#   2. injector and a language list render the flag with the normalised value.
#   3. Invalid values make the render fail.
#
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/injection_mode.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"

fail_count=0

operator_args() {
    "$HELM" template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        --show-only templates/operator-deployment.yaml \
        "$@" | grep -- '--instrumentation-injection-mode' || true
}

expect_flag() {
    local desc="$1" want="$2"; shift 2
    local got
    got="$(operator_args "$@")"
    if [[ -z "$want" && -z "$got" ]] || [[ -n "$want" && "$got" == *"\"--instrumentation-injection-mode=${want}\""* ]]; then
        echo "PASS: ${desc}"
    else
        echo "FAIL: ${desc}: want '${want:-<no flag>}', got '${got:-<no flag>}'"
        fail_count=$((fail_count + 1))
    fi
}

expect_render_failure() {
    local desc="$1"; shift
    if "$HELM" template "$CHART_DIR" --set region=us-west-2 --set clusterName=test-cluster "$@" >/dev/null 2>&1; then
        echo "FAIL: ${desc}: render succeeded"
        fail_count=$((fail_count + 1))
    else
        echo "PASS: ${desc}"
    fi
}

expect_flag "default renders no flag" ""
expect_flag "old renders no flag" "" --set manager.instrumentationInjectionMode=old
expect_flag "injector" "injector" --set manager.instrumentationInjectionMode=injector
expect_flag "single language" "python" --set manager.instrumentationInjectionMode=python
expect_flag "language list" "python,nodejs" --set-string 'manager.instrumentationInjectionMode=python\,nodejs'
expect_flag "case and spaces are normalised" "python,java" --set-string 'manager.instrumentationInjectionMode=Python\, Java'
expect_render_failure "unknown mode fails" --set manager.instrumentationInjectionMode=other
expect_render_failure "unknown language fails" --set-string 'manager.instrumentationInjectionMode=python\,ruby'

if [[ "$fail_count" -gt 0 ]]; then
    echo "${fail_count} check(s) failed"
    exit 1
fi
echo "All injection mode checks passed"
