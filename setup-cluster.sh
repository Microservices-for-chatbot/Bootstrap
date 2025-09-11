#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- The "Ultimate Fix" for non-interactive apt and needrestart ---
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
# Forcefully prevent any command from waiting for input
exec < /dev/null

# --- Install base dependencies, jq, and git first ---
echo "Updating system and installing base dependencies..."
sudo apt update -y
sudo apt upgrade -y -o Dpkg::Options::="--force-confold"
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common jq git

# --- Install Docker ---
echo "=== Installing Docker ==="
# Add Docker's official GPG key and repository
echo "Adding Docker GPG key and repository..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg --yes
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
 | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update apt cache again after adding the new repository
sudo apt-get update -y

# Install Docker packages after the repository has been added
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add ubuntu user to docker group and apply changes
sudo usermod -aG docker ubuntu
newgrp docker
echo "✅ Docker installed and user 'ubuntu' added to the docker group."

# --- Kubernetes Cluster Setup ---
if ! kubectl get pods -n kube-system 2>/dev/null | grep -q 'kube-apiserver'; then
    echo "No Kubernetes control-plane found. Initializing new cluster..."
    
    sudo kubeadm init --cri-socket=unix:///var/run/crio/crio.sock
    
    echo "Configuring kubectl for ubuntu user..."
    sudo mkdir -p /home/ubuntu/.kube
    sudo cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
    sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config
    
    export KUBECONFIG=/home/ubuntu/.kube/config
    
    echo "Applying Weave Net CNI..."
    sudo -u ubuntu kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml
    
    echo "Waiting for node to become Ready..."
    until sudo -u ubuntu kubectl get nodes | grep -q ' Ready '; do
        sleep 5
    done
    
    echo "Removing control-plane taint..."
    sudo -u ubuntu kubectl taint node $(hostname) node-role.kubernetes.io/control-plane:NoSchedule- || true
    
    echo "Waiting for kube-system pods to be Ready..."
    until sudo -u ubuntu kubectl get pods -n kube-system | grep -Ev 'STATUS|Running' | wc -l | grep -q '^0$'; do
        sleep 5
    done
    
    echo "Kubernetes control-plane setup complete."
else
    echo "[INFO] Kubernetes already initialized, skipping kubeadm init."
fi

## Helm and Ingress Installation
# -------------------------------------------------------------
echo "Adding Nginx Ingress Controller Helm repo and installing..."
if ! command -v helm &> /dev/null; then
    echo "Helm is not installed. Installing Helm now..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
fi

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
helm repo update ingress-nginx

if ! helm status ingress-nginx -n ingress-nginx &> /dev/null; then
    echo "Installing Nginx Ingress Controller..."
    helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx --create-namespace || true
else
    echo "Nginx Ingress Controller already deployed. Skipping."
fi

# --- Metrics Server installation ---

if ! kubectl get deployment metrics-server -n kube-system &> /dev/null; then
    echo "[INFO] Installing Metrics Server..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    kubectl -n kube-system patch deploy metrics-server \
        --type='json' \
        -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value":"--kubelet-insecure-tls"},
            {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value":"--kubelet-preferred-address-types=InternalIP"}]'
    # Wait for metrics-server to be ready
    sleep 7
    echo "Metrics Server installation complete."
else
    echo "[INFO] Metrics Server already installed, skipping."
fi

## Prometheus and Grafana Installation
# -------------------------------------------------------------
if ! helm list -n monitoring | grep -q "prometheus"; then
    echo "[INFO] Installing kube-prometheus-stack (Prometheus + Grafana)..."
    if ! helm repo list | grep -q "prometheus-community"; then
        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    fi
    if ! helm repo list | grep -q "grafana"; then
        helm repo add grafana https://grafana.github.io/helm-charts
    fi
    
    helm repo update
    
    if ! kubectl get ns monitoring &> /dev/null; then
      kubectl create namespace monitoring
    fi
    
    helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring
    kubectl patch svc prometheus-grafana -n monitoring -p '{"spec": {"type": "NodePort"}}'
    
    echo "kube-prometheus-stack installation complete."
else
    echo "[INFO] kube-prometheus-stack already installed in namespace monitoring, skipping."
fi