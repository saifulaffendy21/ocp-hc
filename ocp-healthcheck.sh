#!/bin/bash

# =====================================================================
# K8s/OCP Cluster Incident Snapshot Script
#
# Description: Provides a comprehensive, color-coded, live view of cluster health,
# with detailed etcd cluster health checks and VolumeSnapshot age checks.
# Supports both standard Kubernetes (kubectl) and OpenShift (oc).
#
# Usage: ./ocp-healthcheck.sh [options]
# Options:
#   -s, --save    Save output to a timestamped log file (strips colors in file)
#   -h, --help    Show usage information
# =====================================================================

set -euo pipefail

# --- Configuration & Colors ---
STATUS_OK="[ \033[1;32mOK\033[0m ]"
STATUS_FAIL="[ \033[1;31mFAIL\033[0m ]"
STATUS_WARN="[ \033[1;33mWARN\033[0m ]"

BOLD='\033[1m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

HEADER_BAR="${BLUE}================================================================================${NC}"
SUB_HEADER_BAR="${CYAN}--------------------------------------------------------------------------------${NC}"

SAVE_TO_FILE=false
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="cluster_snapshot_${TIMESTAMP}.log"

# --- Helper Functions ---

usage() {
    echo -e "Usage: $0 [OPTIONS]"
    echo -e "Options:"
    echo -e "  -s, --save    Save output to file: ${LOG_FILE}"
    echo -e "  -h, --help    Display this help message"
    exit 1
}

print_header() {
    echo -e "\n${HEADER_BAR}"
    echo -e "${BOLD}>>> $1 <<<${NC}"
    echo -e "${HEADER_BAR}\n"
}

print_sub_header() {
    echo -e "\n${SUB_HEADER_BAR}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${SUB_HEADER_BAR}"
}

determine_cli() {
    if command -v oc &> /dev/null; then
        KUBE_CMD="oc"
        IS_OPENSHIFT=true
        echo -e "${CYAN}OpenShift Client 'oc' detected.${NC}"
    elif command -v kubectl &> /dev/null; then
        KUBE_CMD="kubectl"
        IS_OPENSHIFT=false
        echo -e "${CYAN}Kubernetes Client 'kubectl' detected.${NC}"
    else
        echo -e "${STATUS_FAIL} ${RED}CRITICAL: Neither 'kubectl' nor 'oc' found in PATH.${NC}"
        exit 1
    fi
}

check_connectivity() {
    print_header "1. Connectivity & Cluster Info"
    echo -n "Checking connectivity to API server... "
    if $KUBE_CMD get nodes &> /dev/null; then
        echo -e "${STATUS_OK}"
        echo -e "\n${BOLD}Cluster Info:${NC}"
        $KUBE_CMD cluster-info | grep -E 'Kubernetes|control plane|CoreDNS' | head -n 3

        if [ "$IS_OPENSHIFT" = true ]; then
            echo -e "\n${BOLD}OpenShift Version:${NC}"
            oc version
        else
            echo -e "\n${BOLD}Kubernetes Version:${NC}"
            kubectl version --short 2>/dev/null || kubectl version
        fi
    else
        echo -e "${STATUS_FAIL}"
        echo -e "\n${RED}ERROR: Cannot authenticate to the cluster.${NC}"
        echo -e "Please ensure your KUBECONFIG is set correctly and you are logged in."
        echo -e "Try running '$KUBE_CMD get nodes' manually to debug."
        exit 1
    fi
}

strip_colors() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# --- Diagnostic Helpers ---

print_etcd_api_health() {
    print_sub_header "API Server etcd Health Endpoints"
    $KUBE_CMD get --raw='/healthz/etcd' 2>/dev/null || \
        echo -e "${STATUS_WARN} /healthz/etcd not available (RBAC or API endpoint not supported)."
    $KUBE_CMD get --raw='/readyz?verbose' 2>/dev/null | grep -i etcd || \
        echo -e "${STATUS_WARN} /readyz etcd checks not available (RBAC or API endpoint not supported)."
}

print_etcd_operator_status() {
    if [ "$IS_OPENSHIFT" = true ]; then
        print_sub_header "OpenShift Etcd Operator Status"
        oc get co etcd 2>/dev/null || echo -e "${STATUS_WARN} Unable to read ClusterOperator etcd."
        oc get etcd -n openshift-etcd 2>/dev/null || true
    fi
}

print_etcd_cluster_health() {
    print_sub_header "etcd Cluster Status (etcdctl via Pod Exec)"

    if [ "$IS_OPENSHIFT" != true ]; then
        echo -e "${STATUS_WARN} OpenShift etcd pod exec is not available outside OpenShift. Skipping."
        return
    fi

    if ! $KUBE_CMD get ns openshift-etcd &> /dev/null; then
        echo -e "${STATUS_WARN} Namespace 'openshift-etcd' not found. Skipping."
        return
    fi

    local etcd_pod
    etcd_pod=$($KUBE_CMD get pods -n openshift-etcd -l app=etcd \
        -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n 1)

    if [ -z "$etcd_pod" ]; then
        echo -e "${STATUS_WARN} No running etcd pod found in openshift-etcd."
        return
    fi

    $KUBE_CMD exec -n openshift-etcd "$etcd_pod" -c etcd-member -- /bin/bash -c \
        "etcdctl member list -w table; echo; etcdctl endpoint health --cluster; echo; etcdctl endpoint status -w table" \
        2>/dev/null || echo -e "${STATUS_WARN} Unable to run etcdctl (RBAC or certs issue)."
}

print_ceph_status() {
    print_sub_header "Ceph / ODF Cluster Health & Capacity"

    if [ "$IS_OPENSHIFT" != true ]; then
        echo -e "${STATUS_WARN} Ceph/ODF checks are OpenShift-specific. Skipping."
        return
    fi

    if ! $KUBE_CMD get ns openshift-storage &> /dev/null; then
        echo -e "${STATUS_WARN} Namespace 'openshift-storage' not found. Skipping."
        return
    fi

    local toolbox_pod
    toolbox_pod=$($KUBE_CMD get pod -n openshift-storage -l app=rook-ceph-tools \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -n "$toolbox_pod" ]; then
        $KUBE_CMD exec -n openshift-storage "$toolbox_pod" -- /bin/bash -c \
            "ceph -s; echo; ceph osd status; echo; ceph df" 2>/dev/null || \
            echo -e "${STATUS_WARN} Unable to run ceph commands in rook-ceph-tools."
        return
    fi

    echo -e "${STATUS_WARN} rook-ceph-tools pod not found; falling back to CephCluster details."
    oc get cephcluster -n openshift-storage -o yaml 2>/dev/null || \
        echo -e "${STATUS_WARN} Unable to read CephCluster resources."
}

print_loki_status() {
    print_sub_header "Loki (Logging) Components"

    if ! $KUBE_CMD get ns openshift-logging &> /dev/null; then
        echo -e "${STATUS_WARN} Namespace 'openshift-logging' not found. Skipping."
        return
    fi

    $KUBE_CMD get pods -n openshift-logging -l component=loki -o wide 2>/dev/null || \
        echo -e "${STATUS_WARN} Unable to list Loki pods."
}

print_volumesnapshot_older_than_week() {
    print_header "8. VolumeSnapshots Older Than 7 Days"
    if ! $KUBE_CMD api-resources | awk '{print $1}' | grep -q '^volumesnapshots$'; then
        echo -e "${STATUS_WARN} VolumeSnapshot API not found. Ensure snapshot.storage.k8s.io is installed."
        return
    fi

    if command -v jq &> /dev/null; then
        local cutoff_epoch
        cutoff_epoch=$(date -d '7 days ago' +%s)
        $KUBE_CMD get volumesnapshots.snapshot.storage.k8s.io -A -o json | \
            jq -r --argjson cutoff "$cutoff_epoch" '
                .items[]
                | . as $vs
                | ($vs.metadata.creationTimestamp | fromdateiso8601) as $created
                | select($created < $cutoff)
                | [
                    $vs.metadata.namespace,
                    $vs.metadata.name,
                    $vs.metadata.creationTimestamp,
                    ($vs.status.readyToUse // "unknown"),
                    ($vs.status.restoreSize // "unknown")
                  ]
                | @tsv' | \
            awk 'BEGIN {printf "NAMESPACE\tNAME\tCREATED\tREADY\tRESTORE_SIZE\n"} {print $0}' || \
            echo -e "${STATUS_OK} No VolumeSnapshots older than 7 days found."
    else
        echo -e "${STATUS_WARN} 'jq' not available; showing all VolumeSnapshots for manual review."
        $KUBE_CMD get volumesnapshots.snapshot.storage.k8s.io -A -o wide 2>/dev/null || \
            echo -e "${STATUS_WARN} Unable to list VolumeSnapshots."
    fi
}

# --- Main Snapshot Logic ---

run_snapshot() {
    determine_cli
    check_connectivity

    # --- Section 2: Nodes ---
    print_header "2. Node Status, Uptime & Capacity"
    $KUBE_CMD get nodes -o wide --sort-by=.metadata.name

    print_sub_header "Node Resource Usage (Top)"
    $KUBE_CMD top nodes 2>/dev/null || \
        echo -e "${YELLOW}Metrics API not available (metrics-server might be missing or not ready).${NC}"

    # --- Section 3: OpenShift Specifics (if applicable) ---
    if [ "$IS_OPENSHIFT" = true ]; then
        print_header "3. OpenShift Cluster Operators"
        echo "Checking for degraded operators..."
        oc get co --sort-by=.metadata.name
    fi

    # --- Section 4: Workload Status (Namespaced) ---
    print_header "4. Workload Status Summary (All Namespaces)"
    TOTAL_PODS=$($KUBE_CMD get pods -A --no-headers 2>/dev/null | wc -l || echo "0")
    NOT_READY_PODS=$($KUBE_CMD get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l || echo "0")

    echo -e "Total Pods: ${BOLD}${TOTAL_PODS}${NC} | Not Running/Completed: ${RED}${BOLD}${NOT_READY_PODS}${NC}"

    print_sub_header "Deployments/StatefulSets/DaemonSets not at desired state"
    $KUBE_CMD get deploy,sts,ds -A -o wide 2>/dev/null | \
        awk '$2 != $3 &&NR>1 {print $0}' || \
        echo -e "${STATUS_OK} All major workloads appear balanced."

    print_sub_header "Pods NOT in 'Running' or 'Completed' state (Top 30)"
    $KUBE_CMD get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded \
        --sort-by=.metadata.namespace 2>/dev/null | head -n 31 || \
        echo -e "${STATUS_OK} No unhealthy pods detected."

    # --- Section 5: Networking & Storage ---
    print_header "5. Networking & Storage"

    print_sub_header "Ingress / Routes"
    if [ "$IS_OPENSHIFT" = true ]; then
        oc get routes -A --sort-by=.metadata.namespace 2>/dev/null || echo "Unable to list routes."
    else
        $KUBE_CMD get ingress -A --sort-by=.metadata.namespace 2>/dev/null || echo "Unable to list ingresses."
    fi

    print_sub_header "Persistent Volume Claims (PVCs) Not Bound"
    PVC_NON_BOUND=$($KUBE_CMD get pvc -A --no-headers 2>/dev/null | awk '$2 != "Bound"' || true)
    if [ -z "$PVC_NON_BOUND" ]; then
        echo -e "${STATUS_OK} All PVCs are Bound."
    else
        echo -e "NAMESPACE\tNAME\tSTATUS\tVOLUME\tCAPACITY\tACCESS MODES\tSTORAGECLASS\tAGE"
        echo "$PVC_NON_BOUND"
    fi

    print_sub_header "Ceph / ODF Storage"
    print_ceph_status

    print_sub_header "Loki (Logging) Status"
    print_loki_status

    # --- Section 6: Custom Resources ---
    print_header "6. Custom Resource Definitions (CRDs)"
    echo "Listing installed CRDs (Definitions only, not instances):"
    $KUBE_CMD get crds 2>/dev/null | head -n 20 || echo "Unable to list CRDs."
    CRD_COUNT=$($KUBE_CMD get crds --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$CRD_COUNT" -gt 20 ]; then echo -e "... (showing top 20 of $CRD_COUNT CRDs) ..."; fi

    # --- Section 7: Recent Events ---
    print_header "7. Recent Cluster Events (Last 50, Chronological)"
    $KUBE_CMD get events -A --sort-by='.metadata.creationTimestamp' 2>/dev/null | tail -n 51 || \
        echo "Unable to list events."

    # --- Section 8: etcd Diagnostics ---
    print_header "8. Etcd Cluster Health"
    print_etcd_operator_status
    print_etcd_api_health
    print_etcd_cluster_health

    # --- Section 9: VolumeSnapshots older than 7 days ---
    print_volumesnapshot_older_than_week

    echo -e "\n${HEADER_BAR}"
    echo -e "${BOLD}Snapshot Complete at $(date)${NC}"
    echo -e "${HEADER_BAR}\n"
}

# --- Argument Parsing & Execution ---

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--save) SAVE_TO_FILE=true ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

if [ "$SAVE_TO_FILE" = true ]; then
    echo -e "${CYAN}Starting snapshot. Output will be saved to ./$LOG_FILE${NC}"
    { run_snapshot; } 2>&1 | tee >(strip_colors > "$LOG_FILE")
else
    run_snapshot
fi
