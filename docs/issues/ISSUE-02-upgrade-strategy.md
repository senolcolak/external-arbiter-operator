# ISSUE-02: Robust Monitor Upgrade Strategy

## Description
The current implementation of the upgrade strategy for the external monitor is insufficient and potentially risky.
The requirement states:
> "Arbiter operator watch Rook mons Pods container versions to upgrade external mon pod contaner version after **all** rook pods are up and upgraded"
> "If **all** Rook mon containers have different version from ext mon container, Operator changes version of ext mon container"

## Analysis
The current logic in `fetchMonitorDeployment` and `Reconcile` loop:
1.  Lists all deployments matching `app.kubernetes.io/part-of=<ceph-cluster-name>` and `ceph_daemon_type=mon`.
2.  Arbitrarily picks the first item (`Items[0]`) from the list.
3.  Checks if this specific deployment is ready (`Replicas == UpdatedReplicas`).
4.  Updates the Arbiter deployment to match the image/version of this *single* deployment.

**Risks:**
-   **Partial Upgrade**: If Rook is in the middle of a rolling upgrade, some monitors might be on version N and others on version N+1. If the operator happens to pick a monitor on version N+1, it will upgrade the Arbiter to N+1 *before* all internal monitors are upgraded. This violates the "after all rook pods are up and upgraded" requirement.
-   **Non-Determinism**: Selecting `Items[0]` is non-deterministic or arbitrary depending on the order returned by the API server (though usually alphabetical). If the order changes or if deployments are recreated, the behavior might fluctuate.

## Proposed Solution
Refine the upgrade logic to inspect **all** Rook monitor deployments.

### Implementation Details
1.  **List All Monitors**: Retrieve the full list of monitor deployments.
2.  **Verify Consistency**:
    -   Iterate through all monitor deployments.
    -   Ensure *every* monitor deployment is `Ready` and stable (no update in progress).
    -   Ensure *all* monitor deployments are using the **same** image version.
3.  **Upgrade Decision**:
    -   Only if ALL internal monitors are stable and on the same new version, proceed to update the external Arbiter deployment.
    -   If there is a version mismatch among internal monitors (rolling upgrade in progress), pause the Arbiter upgrade until the cluster converges.

### Acceptance Criteria
-   The Arbiter Operator waits until all Rook monitor deployments report the same image version.
-   The Arbiter Operator does not upgrade the external monitor if any internal monitor is still updating or degraded.
-   The code explicitly loops over all monitor items instead of taking `Items[0]`.
