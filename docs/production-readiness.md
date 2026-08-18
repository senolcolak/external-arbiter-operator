<!--
SPDX-FileCopyrightText: 2026 SAP SE or an SAP affiliate company and cobaltcore-dev contributors
SPDX-License-Identifier: Apache-2.0
-->

# Production readiness review

This document records the safety and operability work identified during an architecture and code review of the external monitor lifecycle. Because the operator manages a voting Ceph monitor, failures in reconciliation, deletion, bootstrap, or upgrades can affect cluster quorum and must be treated as control-plane safety issues.

## P0 — required before production approval

### Live monmap bootstrap

Tracked upstream as [#24: Robust Monmap Retrieval Strategy](https://github.com/cobaltcore-dev/external-arbiter-operator/issues/24).

The external monitor should bootstrap from the authoritative monmap obtained from the running Ceph cluster instead of constructing a local monmap from `ROOK_CEPH_MON_HOST` and `ROOK_CEPH_MON_INITIAL_MEMBERS`. The live map carries the actual cluster membership, epoch, features, and monitor addresses.

Acceptance criteria:

- retrieve the current binary monmap from the source Ceph cluster;
- transfer it to the remote cluster without lossy serialization;
- use it during external monitor bootstrap;
- update it only when content changes and avoid unnecessary pod churn;
- cover a source cluster with multiple monitors in integration tests.

### Fail-safe remote cleanup and finalizers

`cleanUpArbiterDeployment()` creates a remote client but currently performs resource discovery through the source-cluster client. In addition, failure to construct the remote client is treated as a reason to skip cleanup successfully. Either behavior can leave the external `ceph-mon` workload orphaned after the source CR finalizer is removed.

Required behavior:

- list, update, and delete remote resources exclusively through the remote client;
- retain the `RemoteArbiter` finalizer until remote resources are confirmed deleted;
- treat remote API unavailability as retryable by default;
- provide any force-delete behavior as an explicit administrative action;
- remove `CephCluster.spec.mon.externalMonIDs` at a defined safe point in the teardown sequence.

Acceptance criteria:

- normal deletion leaves no remote Deployment, Service, ConfigMap, or Secret behind;
- remote API outage leaves the CR terminating and reconciliation retries;
- tests prove source/remote client separation;
- end-to-end deletion proves the external monitor is no longer running before cleanup completes.

### Collision-safe external monitor identity

`reserveExternalArbiterID()` selects the first free `ext-a` ... `ext-z` value from `CephCluster.spec.mon.externalMonIDs`. Concurrent reconciles can observe the same free value, persist it independently, and later interpret the presence of that ID as their own reservation.

Required behavior:

- monitor identity must be deterministic or ownership-aware;
- two `RemoteArbiter` resources must never converge on the same Ceph monitor ID;
- cleanup must only remove an ID owned by the deleting resource;
- conflicts must be detected and surfaced rather than silently accepted.

Acceptance criteria:

- concurrency tests create multiple arbiters in parallel without duplicate monitor IDs;
- a conflicting pre-existing ID cannot be adopted accidentally;
- deletion of one arbiter cannot remove another arbiter's registration.

## P1 — production hardening

### Honor Service exposure configuration

`RemoteArbiter.spec.service.type` supports `ClusterIP`, `NodePort`, and `LoadBalancer`, but the generated Service must explicitly copy that requested type. Network address selection must match the selected exposure mode.

Acceptance criteria:

- generated Service type equals the CR value;
- NodePort requires a valid externally reachable node address;
- LoadBalancer waits for a usable ingress address;
- controller tests cover all supported Service types.

### Rewrite or regenerate monitor health probes

The operator derives the remote Deployment from a Rook monitor Deployment. Rook probes can contain the original monitor ID in admin-socket paths such as `ceph-mon.a.asok`. Changing `--id` to `ext-a` without updating the probes can make a healthy external monitor fail startup/liveness checks.

Acceptance criteria:

- startup/liveness/readiness checks reference the external monitor identity;
- no source monitor ID remains in generated runtime paths;
- integration tests execute the actual probes against the remote monitor.

### Gate external monitor upgrades on stable source state

The source monitor Deployment is currently selected from a list and used as the template for synchronization. During a rolling Rook/Ceph upgrade, monitor Deployments can temporarily differ. The external monitor must not upgrade based on an arbitrary first item returned by the Kubernetes API.

Acceptance criteria:

- determine the intended Ceph version/image from authoritative desired state;
- detect an in-progress source monitor rollout;
- defer external monitor rollout until the source monitor set is in a safe and consistent state;
- perform one controlled external monitor rollout and verify it rejoins quorum.

### Keep the remote tie-breaker from becoming the preferred leader

The external monitor is normally placed in an independent site and may have higher latency than the two primary monitors. The operator should explicitly support the intended tie-breaker role so the remote monitor is not preferred as the quorum leader during normal operation.

Acceptance criteria:

- document and reconcile the desired leader eligibility policy;
- verify the policy after monitor creation and reconciliation;
- verify loss of either primary AZ still permits a healthy 2-of-3 quorum.

### Define durable monitor storage semantics

The current derived Deployment rewrites the monitor data path to a remote `hostPath`. Monitor state is important and must have explicit durability and scheduling semantics.

Acceptance criteria:

- choose and document a supported persistence model (for example PVC-backed storage or explicit node-bound local persistence);
- prevent silent rescheduling onto empty storage;
- document recovery/re-bootstrap behavior after remote node loss;
- test pod restart and node-loss scenarios.

### Add mandatory CI and end-to-end quorum tests

The repository Makefile already exposes formatting, vetting, linting, vulnerability scanning, envtest, and unit tests, but these checks should gate pull requests. The quorum behavior also needs an end-to-end test because unit tests cannot prove Ceph monitor membership and failure behavior.

Minimum CI coverage:

- build and `go test ./...`;
- `go vet` and `golangci-lint`;
- `govulncheck`;
- generated CRD/Helm consistency checks;
- installation test for the Helm chart;
- end-to-end topology with two Rook-managed monitors and one external monitor;
- failure test proving quorum survives loss of either primary AZ/monitor;
- cleanup test proving no remote monitor is orphaned.

### Validate and document the supported quorum topology

The intended resilience model is **2 Rook-managed MONs + 1 independent external MON**. A 3+1 arrangement has four votes and still requires three for majority; losing an AZ containing two monitors would leave only two votes and therefore no quorum.

Acceptance criteria:

- documentation states the supported topology and quorum arithmetic;
- CR admission or controller status warns when the source monitor topology does not provide the expected resilience;
- documentation clearly separates monitor/control-plane quorum from OSD/data durability.
