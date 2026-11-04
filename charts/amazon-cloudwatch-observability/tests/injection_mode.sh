#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Checks how manager.instrumentationInjectionMode (internal) and
# manager.applicationSignals.autoMonitor.instrumentationGuard (customer switch)
# reach the operator:
#
#   1. The default (old) renders no --instrumentation-injection-mode flag, so the
#      operator Deployment is unchanged from charts without the value.
#   2. injector and a language list render the flag with the normalised value.
#   3. Invalid values make the render fail.
#   4. instrumentationGuard is passed through in --auto-monitor-config: false by
#      default, absent when unset (null), true when set; also with Application
#      Signals disabled and together with the internal mode (the operator then
#      uses the injector for all four languages). A non-boolean fails the render.
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

# Prints the instrumentationGuard entry of --auto-monitor-config, e.g. "instrumentationGuard":true, or nothing.
guard_entry() {
    "$HELM" template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        --show-only templates/operator-deployment.yaml \
        "$@" | grep -- '--auto-monitor-config=' | sed 's/\\"/"/g' | grep -o '"instrumentationGuard":[a-z]*' || true
}

monitor_all_services() {
    "$HELM" template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        --show-only templates/operator-deployment.yaml \
        "$@" | grep -- '--auto-monitor-config=' | sed 's/\\"/"/g' | grep -o '"monitorAllServices":[a-z]*' || true
}

expect_guard() {
    local desc="$1" want="$2"; shift 2
    local got
    got="$(guard_entry "$@")"
    if [[ -z "$want" && -z "$got" ]] || [[ -n "$want" && "$got" == "\"instrumentationGuard\":${want}" ]]; then
        echo "PASS: ${desc}"
    else
        echo "FAIL: ${desc}: want '${want:-<not set>}', got '${got:-<not set>}'"
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

GUARD=manager.applicationSignals.autoMonitor.instrumentationGuard
expect_guard "instrumentationGuard default is false" "false"
expect_guard "instrumentationGuard unset (null) is not passed" "" --set "${GUARD}=null"
expect_guard "instrumentationGuard false" "false" --set "${GUARD}=false"
expect_guard "instrumentationGuard true" "true" --set "${GUARD}=true"
expect_guard "instrumentationGuard true with internal mode python" "true" --set "${GUARD}=true" --set manager.instrumentationInjectionMode=python
expect_flag "internal mode still rendered next to instrumentationGuard true" "python" --set "${GUARD}=true" --set manager.instrumentationInjectionMode=python
expect_guard "instrumentationGuard true with internal mode injector" "true" --set "${GUARD}=true" --set manager.instrumentationInjectionMode=injector
expect_flag "internal injector still rendered next to instrumentationGuard true" "injector" --set "${GUARD}=true" --set manager.instrumentationInjectionMode=injector
expect_flag "instrumentationGuard true alone renders no internal flag" "" --set "${GUARD}=true"
expect_guard "instrumentationGuard true kept with Application Signals disabled" "true" --set "${GUARD}=true" --set applicationSignals.enabled=false
if [[ "$(monitor_all_services --set "${GUARD}=true" --set applicationSignals.enabled=false)" == '"monitorAllServices":false' ]]; then
    echo "PASS: Application Signals disabled still turns monitorAllServices off"
else
    echo "FAIL: Application Signals disabled did not turn monitorAllServices off"
    fail_count=$((fail_count + 1))
fi
expect_render_failure "non-boolean instrumentationGuard fails" --set-string "${GUARD}=true"

if [[ "$fail_count" -gt 0 ]]; then
    echo "${fail_count} check(s) failed"
    exit 1
fi
echo "All injection mode checks passed"
