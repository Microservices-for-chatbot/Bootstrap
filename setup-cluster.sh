#!/bin/bash

# --- Install Dependencies ---
echo "Updating apt and installing jq..."
sudo apt-get update
sudo apt-get install -y jq

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
while [ $(kubectl get nodes | grep "kmaster" | awk '{print $2}') != "Ready" ]; do
  echo "Node not ready yet. Waiting 5 seconds..."
  sleep 5
done

echo "Removing the control-plane taint from the kmaster node..."
kubectl taint node kmaster node-role.kubernetes.io/control-plane:NoSchedule- || true

# --- Helm and Ingress Installation ---
echo "Installing Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "Adding Nginx Ingress Controller Helm repo and installing..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace

# --- Metrics Server Installation and Patching ---
echo "Installing Metrics Server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# This section automates the 'kubectl edit' step
echo "Patching Metrics Server deployment to enable kubelet-insecure-tls..."
kubectl wait --for=condition=Available deployment/metrics-server --timeout=120s -n kube-system

kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

# --- Deploying Microservices ---
echo "Cloning microservice repositories and deploying with Helm..."
# NOTE: The runner must have SSH keys configured for private repos.
git clone git@github.com:Microservices-for-chatbot/frontend.git
git clone git@github.com:Microservices-for-chatbot/ai_service.git
git clone git@github.com:Microservices-for-chatbot/chat_history.git

# Log in to Docker Hub using secrets
docker login -u "$DOCKERHUB_USERNAME" -p "$DOCKERHUB_PASSWORD"

# Deploy the Frontend service
echo "Deploying Frontend service..."
LATEST_TAG=$(curl -s "https://hub.docker.com/v2/repositories/microservices-for-chatbot/frontend/tags/" | jq -r '.results[0].name')
echo "Found latest frontend image tag: $LATEST_TAG"
cd ./frontend
helm upgrade --install frontend-release . --set image.tag=$LATEST_TAG
cd ..

# Deploy the AI service
echo "Deploying AI service..."
LATEST_TAG=$(curl -s "https://hub.docker.com/v2/repositories/microservices-for-chatbot/ai_service/tags/" | jq -r '.results[0].name')
echo "Found latest AI service image tag: $LATEST_TAG"
cd ./ai_service
helm upgrade --install ai-service . --set image.tag=$LATEST_TAG
cd ..

# Deploy the Chat History service
echo "Deploying Chat History service..."
LATEST_TAG=$(curl -s "https://hub.docker.com/v2/repositories/microservices-for-chatbot/chat_history/tags/" | jq -r '.results[0].name')
echo "Found latest Chat History service image tag: $LATEST_TAG"
cd ./chat_history
helm upgrade --install chat-history-service . --set image.tag=$LATEST_TAG
cd ..

echo "All services deployed successfully!"