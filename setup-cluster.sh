#!/bin/bash

# --- Install Dependencies ---
echo "Updating apt and installing jq..."
sudo apt-get update
sudo apt-get install -y jq

# --- Kubernetes Cluster Setup (Idempotency Check) ---
echo "Setting hostname to kmaster..."
sudo hostnamectl set-hostname kmaster

# Check if Kubernetes is already initialized before running kubeadm init
if ! kubectl cluster-info &> /dev/null; then
    echo "Initializing Kubernetes control plane..."
    sudo kubeadm init --pod-network-cidr=10.32.0.0/12
    
    echo "Configuring kubectl for the current user..."
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    
    echo "Applying Weave Net CNI..."
    kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml
fi

# Wait for the node to be ready before removing the taint
echo "Waiting for the node to be ready..."
while [ $(kubectl get nodes | grep "kmaster" | awk '{print $2}') != "Ready" ]; do
    echo "Node not ready yet. Waiting 5 seconds..."
    sleep 5
done

echo "Removing the control-plane taint from the kmaster node..."
kubectl taint node kmaster node-role.kubernetes.io/control-plane:NoSchedule- || true

# --- Helm and Ingress Installation (Idempotent) ---
echo "Installing Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "Adding Nginx Ingress Controller Helm repo and installing..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
# Using 'upgrade --install' makes this command safe to rerun
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace

# --- Metrics Server Installation and Patching (Idempotent) ---
echo "Installing Metrics Server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
echo "Patching Metrics Server deployment to enable kubelet-insecure-tls..."
kubectl wait --for=condition=Available deployment/metrics-server --timeout=120s -n kube-system
kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

# --- Deploying Microservices ---
echo "Cloning microservice repositories and deploying with Helm..."

# Idempotency check before cloning each repo
if [ ! -d "frontend" ]; then
    git clone https://github.com/Microservices-for-chatbot/frontend.git
fi
if [ ! -d "ai_service" ]; then
    git clone https://github.com/Microservices-for-chatbot/ai_service.git
fi
if [ ! -d "chat_history" ]; then
    git clone https://github.com/Microservices-for-chatbot/chat_history.git
fi

# Log in to Docker Hub using secrets
docker login -u "$DOCKERHUB_USERNAME" -p "$DOCKERHUB_PASSWORD"

# Deploy the Frontend service
echo "Deploying Frontend service..."
LATEST_TAG=$(curl -s "https://hub.docker.com/v2/repositories/amithpalissery/frontend/tags/" | jq -r '.results[0].name')
echo "Found latest frontend image tag: $LATEST_TAG"
cd ./frontend
helm upgrade --install frontend-release . --set image.tag=$LATEST_TAG
cd ..

# Deploy the AI service
echo "Deploying AI service..."
LATEST_TAG=$(curl -s "https://hub.docker.com/v2/repositories/amithpalissery/ai-service/tags/" | jq -r '.results[0].name')
echo "Found latest AI service image tag: $LATEST_TAG"
cd ./ai_service
helm upgrade --install ai-service . --set image.tag=$LATEST_TAG
cd ..

# Deploy the Chat History service
echo "Deploying Chat History service..."
LATEST_TAG=$(curl -s "https://hub.docker.com/v2/repositories/amithpalissery/chat-history-service/tags/" | jq -r '.results[0].name')
echo "Found latest Chat History service image tag: $LATEST_TAG"
cd ./chat_history
helm upgrade --install chat-history-service . --set image.tag=$LATEST_TAG
cd ..

echo "All services deployed successfully!"