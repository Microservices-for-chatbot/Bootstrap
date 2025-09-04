#!/bin/bash

# --- Kubernetes Cluster Setup ---
echo "Setting hostname to kmaster..."
sudo hostnamectl set-hostname kmaster

echo "Initializing Kubernetes control plane..."
# NOTE: The --pod-network-cidr is important and must match your CNI.
# 10.32.0.0/12 is the standard for Weave Net.
sudo kubeadm init --pod-network-cidr=10.32.0.0/12

echo "Configuring kubectl for the current user..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "Applying Weave Net CNI..."
kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml

# Wait for the node to be ready before removing the taint
echo "Waiting for the node to be ready..."
kubectl get nodes
while [ $(kubectl get nodes | grep "kmaster" | awk '{print $2}') != "Ready" ]; do
  sleep 5
done

echo "Removing the control-plane taint from the kmaster node..."
kubectl taint node kmaster node-role.kubernetes.io/control-plane:NoSchedule- || true

# --- Helm and Ingress Installation ---
echo "Installing Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "Adding Nginx Ingress Controller Helm repo and installing..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx

# --- Metrics Server Installation and Patching ---
echo "Installing Metrics Server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# This section automates the 'kubectl edit' step
echo "Patching Metrics Server deployment to enable kubelet-insecure-tls..."
kubectl wait --for=condition=Available deployment/metrics-server --timeout=120s -n kube-system

kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

echo "Setup complete! Your cluster is ready for deployments."