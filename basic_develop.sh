#!/bin/bash

set -e

echo "Updating system..."
sudo apt update && sudo apt upgrade -y

echo "Installing Git..."
sudo apt install -y git

# Install prerequisites
sudo apt install -y curl ca-certificates gnupg

# Install Docker if not installed
if ! command -v docker &> /dev/null
then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh

    echo "Adding current user to docker group..."
    sudo usermod -aG docker $USER
else
    echo "Docker already installed."
fi

# Install Docker Compose plugin
if ! docker compose version &> /dev/null
then
    echo "Installing Docker Compose plugin..."
    sudo apt install -y docker-compose-plugin
else
    echo "Docker Compose already installed."
fi

# Enable Docker service
echo "Enabling Docker..."
sudo systemctl enable docker
sudo systemctl start docker

echo "Docker version:"
docker --version

echo "Git version:"
git --version

echo "Setup complete!"
echo "You may need to log out and back in for docker group changes to apply."