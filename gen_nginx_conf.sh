#!/bin/bash

# -----------------------------
# Paths
# -----------------------------
DOMAINS_FILE="./domains.list"
CONF_DIR="./data/conf"
CERTS_DIR="./data/certs"
LOG_DIR="./logs/nginx"
WEBROOT_DIR="./webroot"

# -----------------------------
# Create required directories
# -----------------------------
mkdir -p "$CONF_DIR" "$LOG_DIR" "$WEBROOT_DIR"

# -----------------------------
# Read domains into array
# -----------------------------
mapfile -t DOMAINS_LIST < "$DOMAINS_FILE"

# -----------------------------
# Remove old configs not in domains.list
# -----------------------------
for f in "$CONF_DIR"/auto_*.conf; do
    [[ -e "$f" ]] || continue
    FILENAME=$(basename "$f")
    DOMAIN=${FILENAME#auto_}
    DOMAIN=${DOMAIN%.conf}

    if [[ ! " ${DOMAINS_LIST[@]%% *} " =~ " $DOMAIN " ]]; then
        echo "Config $DOMAIN is not in list, removing."
        rm -f "$f"
        rm -f "$LOG_DIR/$DOMAIN.access.log" "$LOG_DIR/$DOMAIN.error.log"
    fi
done

# -----------------------------
# Create/update configs and renewal
# -----------------------------
while read -r line; do
    DOMAIN=$(echo $line | awk '{print $1}')
    TARGET_IP=$(echo $line | awk '{print $2}')
    CONF_FILE="$CONF_DIR/auto_$DOMAIN.conf"
    ACCESS_LOG="$LOG_DIR/$DOMAIN.access.log"
    ERROR_LOG="$LOG_DIR/$DOMAIN.error.log"

    # -----------------------------
    # HTTP -> HTTPS redirect
    # -----------------------------
    NEW_HTTP_CONF="server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    return 301 https://\$host\$request_uri;
}"

    echo "$NEW_HTTP_CONF" > "$CONF_FILE"
    echo "HTTP config for $DOMAIN created/updated."

    # -----------------------------
    # Renewal (webroot)
    # -----------------------------
    docker run -it --rm \
      -v "$PWD/data/certs:/etc/letsencrypt" \
      -v "$PWD/webroot:/var/www/html" \
      certbot/certbot renew --webroot -w /var/www/html --non-interactive
    echo "SSL certificates checked/renewed for $DOMAIN."

    # -----------------------------
    # HTTPS config with proxy
    # -----------------------------
    NEW_HTTPS_CONF="server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    access_log $ACCESS_LOG;
    error_log $ERROR_LOG;

    location / {
        proxy_pass http://$TARGET_IP;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Server \$host;
    }
}"

    echo -e "\n$NEW_HTTPS_CONF" >> "$CONF_FILE"
    echo "HTTPS config for $DOMAIN added."

done < "$DOMAINS_FILE"

echo "All Nginx configs and SSL certificates checked and updated."
