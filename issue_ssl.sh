#!/bin/bash

# -----------------------------
# Paths
# -----------------------------
DOMAINS_FILE="./domains.list"
CERTS_DIR="./data/certs"

# -----------------------------
# Email for Let's Encrypt
# -----------------------------
EMAIL="micromodern.ah@gmail.com"

# -----------------------------
# Create certs directory
# -----------------------------
mkdir -p "$CERTS_DIR"

# -----------------------------
# Issue SSL certificates with standalone
# -----------------------------
while read -r line; do
    DOMAIN=$(echo $line | awk '{print $1}')

    if [[ ! -d "$CERTS_DIR/live/$DOMAIN" ]]; then
        echo "Issuing SSL for $DOMAIN..."
        docker run -it --rm \
          -v "$PWD/data/certs:/etc/letsencrypt" \
          certbot/certbot certonly \
          --standalone \
          --non-interactive \
          --agree-tos \
          --email "$EMAIL" \
          -d "$DOMAIN"
    else
        echo "SSL already exists for $DOMAIN."
    fi
done < "$DOMAINS_FILE"

echo "All initial SSL certificates issued."
