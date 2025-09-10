#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Install Dependencies ---
sudo apt update -y


# --- Kubernetes Cluster Setup ---
# Kubeadm initialization
# The checks below are for a Kubernetes API server running on the machine.
# This assumes the script runs on the machine where the control-plane should be.
if ! kubectl get pods -n kube-system 2>/dev/null | grep -q 'kube-apiserver'; then
    echo "No Kubernetes control-plane found. Initializing new cluster..."
    
    # Kubeadm init command
    sudo kubeadm init --cri-socket=unix:///var/run/crio/crio.sock
    
    # Configure kubeconfig for the ubuntu user
    echo "Configuring kubectl for ubuntu user..."
    sudo mkdir -p /home/ubuntu/.kube
    sudo cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
    sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config
    
    # CRITICAL FIX: Set KUBECONFIG variable for the rest of the script.
    export KUBECONFIG=/home/ubuntu/.kube/config
    
    # Install Weave Net CNI
    echo "Applying Weave Net CNI..."
    sudo -u ubuntu kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml
    
    # Wait until node is Ready
    echo "Waiting for node to become Ready..."
    until sudo -u ubuntu kubectl get nodes | grep -q ' Ready '; do
        sleep 5
    done
    
    # Remove control-plane taint
    echo "Removing control-plane taint..."
    sudo -u ubuntu kubectl taint node $(hostname) node-role.kubernetes.io/control-plane:NoSchedule- || true
    
    # Wait for kube-system pods
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
# Check for Helm installation before running the command
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

---
## Metrics Server Installation
# -------------------------------------------------------------
if ! kubectl get deployment metrics-server -n kube-system &> /dev/null; then
    echo "[INFO] Installing Metrics Server..."
    
    # Check if kubectl is configured for the current user (ubuntu)
    if ! sudo -u ubuntu kubectl get nodes &> /dev/null; then
      echo "kubectl is not configured for the ubuntu user. Skipping Metrics Server installation."
    else
      sudo -u ubuntu kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
      
      # Use sudo -u ubuntu to ensure the command runs with the correct permissions
      sudo -u ubuntu kubectl -n kube-system patch deploy metrics-server \
          --type='json' \
          -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value":"--kubelet-insecure-tls"}, {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value":"--kubelet-preferred-address-types=InternalIP"}]'
      
      # Wait for metrics-server to be ready
      echo "Waiting for Metrics Server to be ready..."
      sudo -u ubuntu kubectl wait --for=condition=available deployment/metrics-server --timeout=120s -n kube-system
      
      echo "Metrics Server installation complete."
    fi
else
    echo "[INFO] Metrics Server already installed, skipping."
fi

---
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
    
    # Use kubectl to check if the namespace exists before creating it
    if ! kubectl get ns monitoring &> /dev/null; then
      kubectl create namespace monitoring
    fi
    
    helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring
    kubectl patch svc prometheus-grafana -n monitoring -p '{"spec": {"type": "NodePort"}}'
    
    echo "kube-prometheus-stack installation complete."
else
    echo "[INFO] kube-prometheus-stack already installed in namespace monitoring, skipping."
fi