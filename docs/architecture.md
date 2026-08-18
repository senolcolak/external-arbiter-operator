<!--
SPDX-FileCopyrightText: 2026 SAP SE or an SAP affiliate company and cobaltcore-dev contributors
SPDX-License-Identifier: Apache-2.0
-->

# Architecture

The External Arbiter Operator automates the lifecycle of a Ceph monitor that runs outside the Kubernetes cluster managed by Rook. Its primary use case is a Ceph control plane stretched across two availability zones where two Rook-managed monitors need a third, independently placed quorum vote.

## Problem and quorum model

With only two monitors, `mon.a` in AZ-A and `mon.b` in AZ-B, a complete AZ or network partition leaves each surviving side with only one of two votes. Neither side has a majority, so the Ceph monitor control plane loses quorum.

The operator adds a third real `ceph-mon`, for example `mon.ext-a`, in an independent Kubernetes cluster or failure domain:

- AZ-A: Rook-managed `mon.a`
- AZ-B: Rook-managed `mon.b`
- independent site: externally managed `mon.ext-a`

The resulting monitor set has three votes. After the loss of either AZ, the remaining Rook monitor plus the external monitor can still form a 2-of-3 majority.

> The external arbiter is not a lightweight witness. It is a real Ceph monitor and participates in monitor consensus. This architecture improves MON/control-plane quorum resilience; it does not by itself add OSD, placement-group, or application-data redundancy.

## Conceptual view

![External Arbiter Operator conceptual architecture](images/external-arbiter-operator-concept.webp)

The intended topology is **two Rook-managed monitors plus one external monitor**. Adding one external monitor to an arbitrary monitor count does not automatically improve failure tolerance. Quorum mathematics and failure-domain placement must be evaluated for the complete monitor set.

## Controller and resource flow

The operator runs in the source Kubernetes cluster alongside the Rook `CephCluster` resource and manages two custom resources:

- `RemoteCluster` describes access to the Kubernetes cluster where the external monitor will run.
- `RemoteArbiter` describes the external monitor and references both the source `CephCluster` and the target `RemoteCluster`.

At a high level the reconciliation flow is:

1. The `RemoteCluster` controller reads the kubeconfig Secret and validates that the remote API is reachable and that the configured identity has the required namespace permissions.
2. The `RemoteArbiter` controller reads the source `CephCluster` and the Rook-generated monitor configuration.
3. It reserves an external monitor ID and registers that ID in `CephCluster.spec.mon.externalMonIDs`, telling Rook that the monitor belongs to the cluster but is not managed by Rook.
4. It derives the remote monitor configuration from the source monitor resources and creates the corresponding Secret, ConfigMap, Service, and Deployment in the remote Kubernetes cluster.
5. The remote Deployment runs `ceph-mon` as the external monitor and joins the Ceph monitor quorum.
6. Periodic reconciliation checks the source and remote state and synchronizes configuration changes.

## Detailed implementation view

![External Arbiter Operator detailed architecture](images/external-arbiter-operator-detailed.webp)

The current implementation deliberately reuses information from the Rook-created monitor Deployment, including the Ceph image, keyring material, monitor host/member configuration, override configuration, and parts of the pod specification. This keeps the external monitor close to the Rook-managed monitor configuration, but it also creates compatibility and lifecycle coupling that must be handled carefully across Rook/Ceph upgrades.

## Scope and non-goals

The operator is responsible for external monitor orchestration and synchronization. It is not responsible for:

- OSD replication or erasure-coding policy;
- CRUSH failure-domain design;
- application workload failover;
- network connectivity between Ceph participants;
- making an invalid monitor topology safe merely by adding one external monitor.

For a resilient deployment, the remote monitor must be reachable from the surviving Ceph participants and its own storage, placement, and lifecycle must be independent from the two primary availability zones.

## Production readiness

The architecture is useful, but several safety properties are required before treating the operator as a production-grade quorum component. The current review backlog is documented in [Production readiness](production-readiness.md). The most important existing upstream item is [#24: Robust Monmap Retrieval Strategy](https://github.com/cobaltcore-dev/external-arbiter-operator/issues/24), which replaces locally constructed bootstrap monmaps with the authoritative monmap from the running Ceph cluster.
