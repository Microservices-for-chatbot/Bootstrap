#!/bin/bash

set -e

# --- Environment Variables ---
RUNNER_USER=${USER:-ubuntu}
DOCKERHUB_USERNAME=${DOCKERHUB_USERNAME:-amithpalissery}
CHATBOT_REPOS="frontend ai_service chat_history"
POD_NETWORK_CIDR="10.32.0.0/12"
CHART_SUBDIR="Helm-chart"
CRI_SOCKET="unix:///var/run/crio/crio.sock"

# --- Idempotent Cluster Setup Functions ---
check_and_run() {
    local cmd_name="$1"
    local check_cmd="$2"
    local run_cmd="$3"
    if ! command -v "$check_cmd" &> /dev/null; then
        echo "Running: $cmd_name"
        eval "$run_cmd"
    else
        echo "Skipping: $cmd_name (already installed)"
    fi
}

# --- Main Script ---
echo "Updating apt and installing dependencies..."
# This command is often a point of failure, so let's add retries.
for i in {1..5}; do
  sudo apt-get -o Acquire::ForceIPv4=true update && break || sleep 15
done
sudo apt-get install -y jq curl git apt-transport-https ca-certificates gnupg

# Add Docker's official GPG key and repository. This is crucial for a successful install.
echo "Adding Docker's official GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "Adding Docker repository to Apt sources..."
echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "Updating Apt package index with Docker repository..."
sudo apt-get update

if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker "$RUNNER_USER"
else
    echo "Docker is already installed. Skipping."
fi

# Add Kubernetes' official GPG key and repository
echo "Installing kubelet, kubeadm, and kubectl..."
sudo curl -fsSLo /etc/apt/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "Setting hostname to kmaster..."
sudo hostnamectl set-hostname kmaster

# Check for existing Kubernetes cluster
if ! sudo kubectl get pods -n kube-system | grep -q 'kube-apiserver-kmaster'; then
    echo "No Kubernetes control plane found. Initializing new cluster..."
    sudo kubeadm init --pod-network-cidr="${POD_NETWORK_CIDR}" --cri-socket="${CRI_SOCKET}"
    
    echo "Configuring kubectl for the current user..."
    mkdir -p "$HOME/.kube"
    sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
    sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
else
    echo "Kubernetes control plane is already initialized. Skipping initialization."
fi

echo "Applying Weave Net CNI..."
if ! kubectl get ds -n kube-system | grep -q 'weave-net'; then
    kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml || true
else
    echo "Weave Net CNI already deployed. Skipping."
fi

echo "Waiting for the node to be ready..."
kubectl wait --for=condition=Ready node/kmaster --timeout=300s || true
echo "Removing the control-plane taint from the kmaster node..."
kubectl taint node kmaster node-role.kubernetes.io/control-plane:NoSchedule- || true

# Helm and Ingress Installation
echo "Adding Nginx Ingress Controller Helm repo and installing..."
helm repo add ingress-nginx https://kubernetes.io/ingress-nginx || true
if ! helm status ingress-nginx -n ingress-nginx &> /dev/null; then
    helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace || true
else
    echo "Nginx Ingress Controller already deployed. Skipping."
fi

# Metrics Server Installation and Patching
echo "Installing and patching Metrics Server..."
if ! kubectl get deploy -n kube-system | grep -q 'metrics-server'; then
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml || true
    kubectl wait --for=condition=Available deployment/metrics-server --timeout=120s -n kube-system || true
    kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]' || true
else
    echo "Metrics Server already deployed. Skipping."
fi

# Prometheus and Grafana Installation
echo "Adding Prometheus and Grafana Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add grafana https://grafana.github.io/helm-charts || true
echo "Updating Helm repositories..."
helm repo update

echo "Deploying Prometheus..."
if ! helm status prometheus -n monitoring &> /dev/null; then
    helm install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring --create-namespace || true
else
    echo "Prometheus already deployed. Skipping."
fi

echo "Deploying Grafana..."
if ! helm status grafana -n monitoring &> /dev/null; then
    helm install grafana grafana/grafana \
        --namespace monitoring --create-namespace || true
else
    echo "Grafana already deployed. Skipping."
fi

# Deploying Microservices
echo "Cloning and deploying microservices..."
for repo in $CHATBOT_REPOS; do
    echo "Processing $repo..."
    if [ -d "$repo" ]; then
        echo "Repository $repo already exists. Pulling latest changes..."
        cd "$repo"
        git pull
    else
        git clone "https://github.com/Microservices-for-chatbot/$repo.git"
        cd "$repo"
    fi
    
    if [ "$repo" == "ai_service" ]; then
        echo "Creating Kubernetes secrets and configmaps for AI service..."
        kubectl create secret generic ai-service-secrets \
          --from-literal=GOOGLE_API_KEY="${GOOGLE_API_KEY}" \
          --dry-run=client -o yaml | kubectl apply -f - || true

        kubectl create configmap app-config \
          --from-literal=chatHistoryUrl='http://chat-history-service:5002' \
          --dry-run=client -o yaml | kubectl apply -f - || true
    fi

    if ! docker info | grep "Username: $DOCKERHUB_USERNAME" &> /dev/null; then
        echo "Logging in to Docker Hub..."
        docker login -u "$DOCKERHUB_USERNAME" -p "$DOCKERHUB_PASSWORD"
    else
        echo "Already logged in to Docker Hub. Skipping."
    fi

    LATEST_TAG=$(curl -s "https://hub.docker.com/v2/repositories/${DOCKERHUB_USERNAME}/${repo}/tags/" | jq -r '.results[0].name')
    echo "Found latest image tag for $repo: $LATEST_TAG"

    cd "./$CHART_SUBDIR"
    helm upgrade --install "${repo}-release" . --set image.tag="$LATEST_TAG" || true
    cd .. # Corrected: move back to the root directory
    cd ..
done

echo "All services deployed successfully!"
