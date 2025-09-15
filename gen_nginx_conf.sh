#!/bin/bash

DOMAINS_FILE="./domains.list"
CONF_DIR="./data/conf"
CERTS_DIR="./data/certs"
LOG_DIR="./logs/nginx"

mkdir -p "$CONF_DIR" "$CERTS_DIR" "$LOG_DIR"

EMAIL="micromodern.ah@gmail.com"  # Your real email

# Read domains into an array
mapfile -t DOMAINS_LIST < "$DOMAINS_FILE"

# -----------------------------
# Remove auto_ configs not in domains.list
# -----------------------------
for f in "$CONF_DIR"/auto_*.conf; do
    [[ -e "$f" ]] || continue
    FILENAME=$(basename "$f")
    DOMAIN=${FILENAME#auto_}
    DOMAIN=${DOMAIN%.conf}

    if [[ ! " ${DOMAINS_LIST[@]%% *} " =~ " $DOMAIN " ]]; then
        echo "Config for $DOMAIN not in list, removing."
        rm -f "$f"
        rm -f "$LOG_DIR/$DOMAIN.access.log" "$LOG_DIR/$DOMAIN.error.log"
    fi
done

# -----------------------------
# Create or update configs and SSL
# -----------------------------
while read -r line; do
    DOMAIN=$(echo $line | awk '{print $1}')
    TARGET_IP=$(echo $line | awk '{print $2}')
    CONF_FILE="$CONF_DIR/auto_$DOMAIN.conf"
    ACCESS_LOG="$LOG_DIR/$DOMAIN.access.log"
    ERROR_LOG="$LOG_DIR/$DOMAIN.error.log"

    # HTTP -> HTTPS redirect
    NEW_HTTP_CONF="server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    return 301 https://\$host\$request_uri;
}"
    if [[ ! -f "$CONF_FILE" || "$(head -n 20 "$CONF_FILE")" != "$NEW_HTTP_CONF" ]]; then
        echo "$NEW_HTTP_CONF" > "$CONF_FILE"
        echo "HTTP config for $DOMAIN created/updated."
    else
        echo "HTTP config for $DOMAIN unchanged, skipped."
    fi

    # Issue or renew SSL with certbot
    if [[ ! -d "$CERTS_DIR/live/$DOMAIN" ]]; then
        docker run --rm \
            -v "$CERTS_DIR:/etc/letsencrypt" \
            -v "$CONF_DIR:/var/www/html" \
            certbot/certbot certonly \
            --standalone \
            --non-interactive \
            --agree-tos \
            --email "$EMAIL" \
            -d "$DOMAIN"
        echo "SSL certificate for $DOMAIN issued."
    else
        docker run --rm \
            -v "$CERTS_DIR:/etc/letsencrypt" \
            certbot/certbot renew --non-interactive
        echo "SSL certificate for $DOMAIN checked/renewed if needed."
    fi

    # HTTPS config with proxy and custom logs (http2 split)
    NEW_HTTPS_CONF="server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    http2 on;

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

    if ! grep -q "listen 443 ssl;" "$CONF_FILE"; then
        echo -e "\n$NEW_HTTPS_CONF" >> "$CONF_FILE"
        echo "HTTPS config for $DOMAIN added."
    else
        echo "HTTPS config for $DOMAIN already exists, skipped."
    fi

done < "$DOMAINS_FILE"

echo "All Nginx configs and SSL certificates checked and updated."
