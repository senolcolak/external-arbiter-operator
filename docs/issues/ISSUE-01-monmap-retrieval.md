# ISSUE-01: Robust Monmap Retrieval Strategy

## Description
The current implementation of the Arbiter Operator generates a new monmap for the external monitor using `monmaptool --create`. This approach relies on `ROOK_CEPH_MON_HOST` and `ROOK_CEPH_MON_INITIAL_MEMBERS` environment variables to populate the map.

However, the requirements and the manual setup procedure explicitly state that the monmap should be obtained from the existing Ceph cluster:
> "dump monmap ceph mon getmap -o /tmp/monmap"
> "copy monmap to host kubectl cp rook-ceph/rook-ceph-tools-854954b685-qbfps:/tmp/monmap $PWD/monmap"

## Analysis
Generating a fresh monmap (`monmaptool --create`) carries significant risks:
1.  **Inconsistency**: The generated map might not match the actual epoch, features, or member list of the running cluster, especially if `ROOK_CEPH_MON_HOST` is stale or incomplete (e.g. during a split-brain scenario or partial outage).
2.  **Joining Issues**: A new monitor attempting to join with a locally generated map might be rejected or cause peering issues if it claims to be part of a cluster with a different map structure.
3.  **Missing Features**: The running cluster might have specific features enabled in the monmap that `monmaptool --create` (with default flags) might not include.

## Proposed Solution
Modify the `remotearbiter_controller` to fetch the actual monmap from the running Rook cluster instead of generating it.

### Implementation Details
1.  **Retrieve Monmap**:
    -   Use the Rook Toolbox pod (as hinted in requirements: *"[optional] label to lookup rook toolbox pod in case if we need to execute ceph commands"*) or execute `ceph mon getmap` inside one of the existing Rook monitor pods.
    -   The controller should handle the extraction of this binary file.
2.  **Pass Monmap to External Mon**:
    -   Store the retrieved monmap in a ConfigMap (or Secret) in the *remote* cluster, similar to how `monmap` configmap is used in the manual setup.
    -   Mount this ConfigMap into the external arbiter pod.
    -   The `init-monmap` container should copy this map instead of running `monmaptool --create`.

### Acceptance Criteria
-   The operator successfully retrieves the current binary monmap from the Rook cluster.
-   The external arbiter pod starts with the exact monmap retrieved from the cluster.
-   `monmaptool --create` is removed from the init container logic.
