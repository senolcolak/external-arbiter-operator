#!/usr/bin/env bash
# Copyright 2025 SAP SE or an SAP affiliate company and cobaltcore-dev contributors
# SPDX-License-Identifier: Apache-2.0

set -eo pipefail

# Configuration
ROOK_DIR="./rook/deploy/examples"
NAMESPACE="rook-ceph"
ARBITER_NAMESPACE="arbiter-operator"
IMAGE_REPO=${IMAGE_REPO:-"localhost:5000/cobaltcore-dev/external-arbiter-operator"}
IMAGE_TAG=${IMAGE_TAG:-"latest"}
IMAGE_NAME="${IMAGE_REPO}:${IMAGE_TAG}"

# Check for required tools
for tool in kubectl helm docker openssl; do
    if ! command -v $tool &> /dev/null; then
        echo "Error: $tool is not installed."
        exit 1
    fi
done

echo "--- Step 1: Installing cert-manager ---"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.2/cert-manager.yaml

echo "Waiting for cert-manager to be ready..."
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s

echo "--- Step 2: Installing Rook CRDs and common resources ---"
if [ ! -d "$ROOK_DIR" ]; then
    echo "Rook directory not found. Running 'make deps'..."
    make deps
fi
kubectl apply -f "${ROOK_DIR}/crds.yaml"
kubectl apply -f "${ROOK_DIR}/common.yaml"

echo "--- Step 3: Installing Rook operator ---"
kubectl apply -f "${ROOK_DIR}/operator.yaml"
kubectl apply -f "${ROOK_DIR}/csi-operator.yaml"

echo "Waiting for Rook operator to be ready..."
kubectl wait --for=condition=Available deployment/rook-ceph-operator -n "${NAMESPACE}" --timeout=120s

echo "--- Step 4: Creating Ceph cluster (test mode) ---"
kubectl apply -f "${ROOK_DIR}/cluster-test.yaml"

echo "Waiting for Ceph cluster to be ready (this might take a few minutes)..."
# We wait for at least one mon to be ready.
# In cluster-test.yaml, monitors are usually named rook-ceph-mon-a, etc.
echo "Waiting for mon-a pod..."
kubectl wait --for=condition=Ready pod -l app=rook-ceph-mon -n "${NAMESPACE}" --timeout=300s

echo "--- Step 5: Installing Ceph toolbox ---"
kubectl apply -f "${ROOK_DIR}/toolbox.yaml"

echo "--- Step 6: Building and loading operator image ---"
docker build -t "${IMAGE_NAME}" .
if command -v kind >/dev/null && kind get clusters | grep -q $(kubectl config current-context); then
  echo "Loading image into kind cluster..."
  kind load docker-image "${IMAGE_NAME}"
elif command -v minikube >/dev/null && kubectl config current-context | grep -q minikube; then
  echo "Minikube detected. Note: you might need to run 'eval \$(minikube docker-env)' before running this script if not using kind."
fi

echo "--- Step 7: Installing external-arbiter-operator via Helm ---"
make helm
helm upgrade --install arbiter-operator ./contrib/charts/external-arbiter-operator \
    --create-namespace \
    --namespace "${ARBITER_NAMESPACE}" \
    --set image.repository="${IMAGE_REPO}" \
    --set image.tag="${IMAGE_TAG}" \
    --values ./contrib/charts/external-arbiter-operator/local.yaml

echo "--- Step 8: Configuring remote cluster user and secret ---"
./hack/configure-k8s-user.sh
kubectl apply -f ./contrib/k8s/examples/secret.yaml -n "${ARBITER_NAMESPACE}"

echo "--- Step 9: Applying RemoteCluster and RemoteArbiter CRs ---"
kubectl apply -f ./contrib/k8s/examples/remote-cluster.yaml -n "${ARBITER_NAMESPACE}"
kubectl apply -f ./contrib/k8s/examples/remote-arbiter.yaml -n "${ARBITER_NAMESPACE}"

echo "--------------------------------------------------"
echo "Setup complete! Monitor the progress with:"
echo "kubectl get remotearbiter -n ${ARBITER_NAMESPACE} -w"
echo ""
echo "To check Ceph status:"
echo "kubectl exec -n ${NAMESPACE} deployment/rook-ceph-tools -- ceph -s"
echo "To check mon quorum:"
echo "kubectl exec -n ${NAMESPACE} deployment/rook-ceph-tools -- ceph mon dump"
