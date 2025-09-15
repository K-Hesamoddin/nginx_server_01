#!/bin/bash

DOMAINS_FILE="./domains.list"
CONF_DIR="./data/conf"
CERTS_DIR="./data/certs"
LOG_DIR="./logs/nginx"

mkdir -p "$CONF_DIR" "$CERTS_DIR" "$LOG_DIR"

EMAIL="micromodern.ah@gmail.com"  # ایمیل واقعی خودت

# خواندن لیست دامنه‌ها به آرایه
mapfile -t DOMAINS_LIST < "$DOMAINS_FILE"

# -----------------------------
# حذف کانفیگ‌های auto_ که در domains.list نیستند
# -----------------------------
for f in "$CONF_DIR"/auto_*.conf; do
    [[ -e "$f" ]] || continue
    FILENAME=$(basename "$f")
    DOMAIN=${FILENAME#auto_}
    DOMAIN=${DOMAIN%.conf}

    if [[ ! " ${DOMAINS_LIST[@]%% *} " =~ " $DOMAIN " ]]; then
        echo "کانفیگ $DOMAIN در لیست نیست، حذف می‌شود."
        rm -f "$f"
        # می‌توان فایل‌های لاگ مربوطه را هم حذف کرد (اختیاری)
        rm -f "$LOG_DIR/$DOMAIN.access.log" "$LOG_DIR/$DOMAIN.error.log"
    fi
done

# -----------------------------
# ساخت یا به‌روزسانی کانفیگ‌ها و SSL
# -----------------------------
while read -r line; do
    DOMAIN=$(echo $line | awk '{print $1}')
    TARGET_IP=$(echo $line | awk '{print $2}')
    CONF_FILE="$CONF_DIR/auto_$DOMAIN.conf"
    ACCESS_LOG="$LOG_DIR/$DOMAIN.access.log"
    ERROR_LOG="$LOG_DIR/$DOMAIN.error.log"

    # کانفیگ HTTP -> HTTPS
    NEW_HTTP_CONF="server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    return 301 https://\$host\$request_uri;
}"
    if [[ ! -f "$CONF_FILE" || "$(head -n 20 "$CONF_FILE")" != "$NEW_HTTP_CONF" ]]; then
        echo "$NEW_HTTP_CONF" > "$CONF_FILE"
        echo "کانفیگ HTTP برای $DOMAIN ساخته شد/به‌روز شد."
    else
        echo "کانفیگ HTTP برای $DOMAIN تغییر نکرد، نادیده گرفته شد."
    fi

    # صدور یا تمدید SSL با certbot
    if [[ ! -d "$CERTS_DIR/live/$DOMAIN" ]]; then
        docker run -it --rm \
            -v "$CERTS_DIR:/etc/letsencrypt" \
            -v "$CONF_DIR:/var/www/html" \
            certbot/certbot certonly \
            --standalone \
            --non-interactive \
            --agree-tos \
            --email "$EMAIL" \
            -d "$DOMAIN"
        echo "گواهی SSL برای $DOMAIN صادر شد."
    else
        docker run -it --rm \
            -v "$CERTS_DIR:/etc/letsencrypt" \
            certbot/certbot renew --non-interactive
        echo "گواهی SSL برای $DOMAIN بررسی و در صورت نیاز تمدید شد."
    fi

    # کانفیگ HTTPS با پراکسی کامل و فایل لاگ اختصاصی
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

    if ! grep -q "listen 443 ssl http2;" "$CONF_FILE"; then
        echo -e "\n$NEW_HTTPS_CONF" >> "$CONF_FILE"
        echo "کانفیگ HTTPS برای $DOMAIN اضافه شد."
    else
        echo "کانفیگ HTTPS برای $DOMAIN قبلاً موجود است، نادیده گرفته شد."
    fi

done < "$DOMAINS_FILE"

echo "کانفیگ Nginx و SSL برای تمام دامنه‌ها بررسی و به‌روز شد."
