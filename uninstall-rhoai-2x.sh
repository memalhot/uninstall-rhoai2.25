#!/bin/bash

# Uninstall RHOAI 2.x from a workload cluster, as run on oac-dev-workload0 on
# 2026-10-09 ahead of the 3.5 install. 3.x cannot be reached by upgrading an
# installed 2.x, so the cluster has to be cleared first.
#
#   CONTEXT=<kube context> ./uninstall-rhoai-2x.sh check
#   CONTEXT=<kube context> ./uninstall-rhoai-2x.sh uninstall
#   CONTEXT=<kube context> ./uninstall-rhoai-2x.sh cleanup
#   CONTEXT=<kube context> ./uninstall-rhoai-2x.sh verify
#
# Pause Argo first or selfHeal reinstalls the operator halfway through the
# teardown: scripts/pause-app-sync.sh <cluster>-rhoai, or add a deny sync
# window to the default AppProject in the UI (kind deny, schedule "* * * * *",
# duration 24h, applications <cluster>-rhoai, manual sync off). Confirm the
# window on the Application itself, not just the project page -- a window with
# no selectors is listed but matches nothing. Lift it only after the chart's
# `enabled: false` has merged.
#
# This destroys every workbench, model server and pipeline on the cluster.
# User project namespaces and their PVCs survive; redhat-ods-applications,
# redhat-ods-monitoring and rhods-notebooks do not.

set -u

: "${CONTEXT:?set CONTEXT to the target kube context, as listed by oc config get-contexts}"

# Every call goes through here so none can fall back to the current context.
# A bare `oc delete crd` during the dev run landed on whichever cluster was
# checked out, which happened to be the right one.
oc() { command oc --context="$CONTEXT" --as system:admin "$@"; }

fail=0
ok() { printf '  %-52s OK\n' "$1"; }
nok() { printf '  %-52s FAIL %s\n' "$1" "$2"; fail=1; }

usage() {
  echo "usage: CONTEXT=<kube context> $0 {check|uninstall|cleanup|verify}" >&2
  exit 2
}

confirm() {
  [ "${FORCE:-0}" = "1" ] && return 0
  echo
  echo "About to $1 on:"
  echo "  $(oc whoami --show-server 2>/dev/null)"
  printf 'Type yes to continue: '
  read -r reply
  [ "$reply" = "yes" ] || { echo "aborted" >&2; exit 1; }
}

check() {
  echo "server:  $(oc whoami --show-server)"
  echo
  echo "operator:"
  oc get csv -n redhat-ods-operator 2>/dev/null | grep -e rhods-operator -e NAME
  echo
  echo "DataScienceCluster:"
  oc get datasciencecluster -o jsonpath='{range .items[*].status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null |
    grep -Ee '^(Ready|ComponentsReady)='
  echo
  echo "workloads that will be destroyed:"
  printf '  notebooks:         %s\n' "$(oc get notebooks.kubeflow.org -A --no-headers 2>/dev/null | wc -l)"
  printf '  inferenceservices: %s\n' "$(oc get inferenceservices -A --no-headers 2>/dev/null | wc -l)"
  printf '  pipelines:         %s\n' "$(oc get datasciencepipelinesapplications -A --no-headers 2>/dev/null | wc -l)"
  echo
  echo "PVCs in namespaces the uninstall deletes:"
  oc get pvc -n rhods-notebooks --no-headers 2>/dev/null || echo "  (none)"
  echo
  echo "user project namespaces (these survive):"
  oc get ns -l opendatahub.io/dashboard=true -o name 2>/dev/null | sed 's/^/  /'
}

# The documented procedure: the label tells the operator to remove everything
# it owns. It has to stay running until it finishes, which is why the operator
# namespace is deleted last and why Argo has to be paused rather than left to
# prune the Subscription out from under it.
uninstall() {
  confirm "uninstall RHOAI 2.x"
  oc create configmap delete-self-managed-odh -n redhat-ods-operator
  oc label configmap/delete-self-managed-odh \
    api.openshift.com/addon-managed-odh-delete=true -n redhat-ods-operator

  echo "waiting for redhat-ods-applications to go away..."
  while oc get project redhat-ods-applications >/dev/null 2>&1; do
    sleep 5
  done

  oc delete namespace redhat-ods-operator --ignore-not-found
}

cleanup() {
  confirm "delete RHOAI leftovers"

  # The namespaces hang in Terminating until discovery succeeds cluster-wide,
  # and discovery fails while the kueue visibility APIServices have no
  # endpoints. That is the Red Hat build of Kueue being unable to deploy its
  # controller: it cannot update a 2.x CRD that is v1alpha1-only, because the
  # API server will not let v1alpha1 leave spec.versions while it is still in
  # status.storedVersions. Deleting them lets RHBoK recreate them correctly.
  for crd in cohorts.kueue.x-k8s.io topologies.kueue.x-k8s.io; do
    if oc get crd "$crd" >/dev/null 2>&1; then
      echo "deleting deadlocked CRD $crd"
      oc delete crd "$crd" --timeout=60s
    fi
  done

  # Webhook configurations outlive the uninstall and keep pointing at services
  # in the deleted applications namespace, which rejects every write to the
  # resources they intercept -- including the finalizer patches below.
  echo "deleting webhooks left pointing at redhat-ods-applications"
  for kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
    for w in $(oc get "$kind" -o json 2>/dev/null | python3 -I -c "
import json,sys
for i in json.load(sys.stdin)['items']:
    if any(h.get('clientConfig',{}).get('service',{}).get('namespace') == 'redhat-ods-applications'
           for h in i.get('webhooks',[])):
        print(i['metadata']['name'])
"); do
      oc delete "$kind" "$w" --ignore-not-found
    done
  done

  # Their controller left with the operator, so nothing will ever clear these
  # and the CRD delete below would hang on them.
  echo "stripping orphaned notebook finalizers"
  oc get notebooks.kubeflow.org -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null |
    while read -r ns name; do
      [ -n "${name:-}" ] || continue
      oc patch notebook.kubeflow.org "$name" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}'
    done

  # Left behind by the uninstall. They have to go before 3.x installs: the v1
  # DataScienceCluster is a stored version the v2 CRD does not serve, which is
  # the same deadlock as the kueue CRDs above, on the operator being installed.
  # The pattern spares kueues.kueue.openshift.io, which belongs to RHBoK.
  echo "deleting leftover 2.x CRDs"
  for c in $(oc get crd -o name 2>/dev/null | grep -Ee 'opendatahub|kubeflow'); do
    oc delete "$c" --timeout=60s
  done
}

verify() {
  echo "server:  $(oc whoami --show-server)"
  echo

  local ns
  ns=$(oc get ns -o name 2>/dev/null | grep -Ee 'redhat-ods|rhods' | wc -l)
  [ "$ns" -eq 0 ] && ok "RHOAI namespaces gone" || nok "RHOAI namespaces gone" "$ns remaining"

  local crds
  crds=$(oc get crd -o name 2>/dev/null | grep -cEe 'opendatahub|kubeflow')
  [ "$crds" -eq 0 ] && ok "2.x CRDs gone" || nok "2.x CRDs gone" "$crds remaining"

  local hooks
  hooks=$(oc get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json 2>/dev/null | python3 -I -c "
import json,sys
print(sum(1 for i in json.load(sys.stdin)['items']
          if any(h.get('clientConfig',{}).get('service',{}).get('namespace') == 'redhat-ods-applications'
                 for h in i.get('webhooks',[]))))
")
  [ "$hooks" -eq 0 ] && ok "orphaned webhooks gone" || nok "orphaned webhooks gone" "$hooks remaining"

  # Not strictly part of the uninstall, but 3.x needs Kueue working and the
  # uninstall is what unblocks it.
  local kueue
  kueue=$(oc get kueue.kueue.openshift.io cluster -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
  [ "$kueue" = "True" ] && ok "Red Hat build of Kueue available" || nok "Red Hat build of Kueue available" "${kueue:-not installed}"

  local stale
  stale=$(oc get apiservice -o json 2>/dev/null | python3 -I -c "
import json,sys
print(sum(1 for i in json.load(sys.stdin)['items']
          if any(c['type'] == 'Available' and c['status'] != 'True' for c in i.get('status',{}).get('conditions',[]))))
")
  [ "$stale" -eq 0 ] && ok "no unavailable APIServices" || nok "no unavailable APIServices" "$stale (blocks namespace deletion)"

  echo
  [ "$fail" -eq 0 ] && echo "clear to install 3.x" || echo "not clear yet"
  return "$fail"
}

case "${1:-}" in
  check) check ;;
  uninstall) uninstall ;;
  cleanup) cleanup ;;
  verify) verify ;;
  *) usage ;;
esac
