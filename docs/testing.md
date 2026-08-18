# Testing the external-arbiter-operator

This document describes how to set up a local testing environment for the `external-arbiter-operator`.

## Prerequisites

To run the automated test environment, you need the following tools installed:
- `kubectl`
- `helm`
- `docker`
- `openssl`
- A local Kubernetes cluster (e.g., [Kind](https://kind.sigs.k8s.io/) or [Minikube](https://minikube.sigs.k8s.io/))

## Automated Setup

We provide a script that automates the deployment of a full testing environment, including a Rook-managed Ceph cluster and the `external-arbiter-operator`.

To start the setup, run:

```bash
./hack/deploy-test-env.sh
```

### What the script does:
1.  **Installs cert-manager**: Required for the operator's webhooks.
2.  **Deploys Rook-Ceph**: Sets up a minimal Ceph cluster using Rook's `cluster-test.yaml`.
3.  **Builds the Operator**: Builds the Docker image for the `external-arbiter-operator`.
4.  **Installs the Operator**: Deploys the operator via Helm.
5.  **Configures RBAC**: Sets up a dedicated namespace and user in the cluster to act as the "target cluster" for the external arbiter.
6.  **Deploys CRs**: Applies the `RemoteCluster` and `RemoteArbiter` Custom Resources.

## Manual Verification

Once the setup is complete, you can verify that the external arbiter has successfully joined the Ceph quorum.

### 1. Check Arbiter Resource Status
Check if the `RemoteArbiter` resource is ready:

```bash
kubectl get remotearbiter -n arbiter-operator
```

### 2. Verify Monitor Pod
Ensure a monitor pod is running in the `external-arbiter` namespace:

```bash
kubectl get pods -n external-arbiter
```

### 3. Check Ceph Quorum
Use the Rook toolbox to check the status of the Ceph cluster:

```bash
kubectl exec -n rook-ceph deployment/rook-ceph-tools -- ceph -s
kubectl exec -n rook-ceph deployment/rook-ceph-tools -- ceph mon dump
```

You should see the external monitor (e.g., `arbiter-a`) listed in the monitor map and participating in the quorum.

## Customization

You can customize the image repository and tag by setting environment variables:

```bash
IMAGE_REPO="my-registry/operator" IMAGE_TAG="dev" ./hack/deploy-test-env.sh
```

## Troubleshooting

- **Image Pull Errors**: If you are using Minikube and see image pull errors, ensure you have run `eval $(minikube docker-env)` before building the image or use the `IMAGE_REPO` variable to point to a registry accessible by your cluster.
- **Rook Startup**: The Ceph cluster can take several minutes to start. The script waits for the first monitor to be ready, but OSDs and other components might still be initializing.
