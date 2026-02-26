#!/bin/bash

set -e

echo "Updating system..."
sudo apt update && sudo apt upgrade -y

echo "Installing Git..."
sudo apt install -y git

echo "Installing Docker..."
curl -fsSL https://get.docker.com | sh

echo "Adding current user to docker group..."
sudo usermod -aG docker $USER

echo "Enabling Docker..."
sudo systemctl enable docker
sudo systemctl start docker

echo "Docker version:"
docker --version

echo "Git version:"
git --version

echo "Setup complete!"
echo "You may need to log out and back in for docker group changes to apply."