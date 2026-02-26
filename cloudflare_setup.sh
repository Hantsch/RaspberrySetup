#!/bin/bash
set -e

### Install cloudflared
### Install cloudflared
if ! command -v cloudflared &> /dev/null
then
    echo "Installing cloudflared..."
    ARCH=$(uname -m)

    if [[ "$ARCH" == "aarch64" ]]; then
        CF_ARCH="arm64"
    elif [[ "$ARCH" == "armv7l" ]]; then
        CF_ARCH="arm"
    else
        echo "Unsupported architecture: $ARCH"
        exit 1
    fi

    wget -O cloudflared.deb \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH.deb

    sudo dpkg -i cloudflared.deb
    rm cloudflared.deb
    echo "Cloudflared installed."
fi

echo ""
echo "Login to Cloudflare (browser will be required):"
cloudflared tunnel login

echo ""
echo "Creating tunnel..."
read -p "Enter tunnel name: " TUNNEL_NAME
cloudflared tunnel create $TUNNEL_NAME

echo ""
echo "Creating config..."

TUNNEL_ID=$(cloudflared tunnel list | grep $TUNNEL_NAME | awk '{print $1}')

sudo mkdir -p /etc/cloudflared

sudo tee /etc/cloudflared/config.yml > /dev/null <<EOF
tunnel: $TUNNEL_ID
credentials-file: /home/$USER/.cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: yourdomain.com
    service: http://localhost:3000
  - service: http_status:404
EOF

echo ""
echo "Installing tunnel as service..."
sudo cloudflared service install

sudo systemctl enable cloudflared
sudo systemctl start cloudflared

echo "Cloudflare Tunnel setup complete!"