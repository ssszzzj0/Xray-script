#!/bin/bash

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Read environment variables with defaults
DOMAIN="${DOMAIN:-}"
XRAY_PORT="${XRAY_PORT:-443}"
NGINX_HTTP_PORT="${NGINX_HTTP_PORT:-80}"
XRAY_UUID="${XRAY_UUID:-}"
XRAY_PROTOCOL="${XRAY_PROTOCOL:-vless}"
XRAY_FLOW="${XRAY_FLOW:-xtls-rprx-vision}"
ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"

# Validate required environment variables
if [ -z "$DOMAIN" ]; then
    log_error "DOMAIN environment variable is required!"
    log_error "Usage: docker run -e DOMAIN=your.domain.com ..."
    exit 1
fi

log_info "Starting Xray-script Docker container"
log_info "Domain: $DOMAIN"
log_info "Xray Port: $XRAY_PORT"
log_info "Nginx HTTP Port: $NGINX_HTTP_PORT"

# Generate UUID if not provided
if [ -z "$XRAY_UUID" ]; then
    XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)
    log_info "Generated UUID: $XRAY_UUID"
else
    log_info "Using provided UUID: $XRAY_UUID"
fi

# SSL certificate management
CERT_DIR="/usr/local/etc/xray/cert"
CERT_FILE="$CERT_DIR/${DOMAIN}.crt"
KEY_FILE="$CERT_DIR/${DOMAIN}.key"

mkdir -p "$CERT_DIR"

# Check if certificate exists and is valid
if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    log_info "SSL certificate found for $DOMAIN"
else
    log_info "SSL certificate not found. Applying for new certificate..."
    
    # Create temporary nginx configuration for acme challenge
    mkdir -p /var/www/html/.well-known/acme-challenge
    
    cat > /etc/nginx/nginx.conf <<EOF
events {
    worker_connections 1024;
}

http {
    server {
        listen ${NGINX_HTTP_PORT};
        server_name ${DOMAIN};
        
        location /.well-known/acme-challenge/ {
            root /var/www/html;
        }
        
        location / {
            return 200 'acme challenge server';
        }
    }
}
EOF
    
    # Start temporary nginx for acme validation
    log_info "Starting temporary nginx for ACME validation..."
    nginx
    sleep 2
    
    # Apply for certificate using acme.sh
    log_info "Applying for SSL certificate..."
    /root/.acme.sh/acme.sh --issue -d "$DOMAIN" \
        --webroot /var/www/html \
        --keylength ec-256 \
        --server letsencrypt \
        --email "$ACME_EMAIL" \
        --force || {
        log_error "Failed to obtain SSL certificate"
        nginx -s stop
        exit 1
    }
    
    # Install certificate
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --ecc \
        --cert-file "$CERT_FILE" \
        --key-file "$KEY_FILE" \
        --fullchain-file "$CERT_DIR/${DOMAIN}.fullchain.crt"
    
    # Stop temporary nginx
    nginx -s stop
    sleep 2
    
    log_info "SSL certificate obtained successfully"
fi

# Generate Xray configuration
log_info "Generating Xray configuration..."
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${XRAY_PORT},
      "protocol": "${XRAY_PROTOCOL}",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": "${XRAY_FLOW}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "certificates": [
            {
              "certificateFile": "${CERT_FILE}",
              "keyFile": "${KEY_FILE}"
            }
          ],
          "alpn": ["h2", "http/1.1"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

log_info "Xray configuration generated"

# Generate Nginx configuration
log_info "Generating Nginx configuration..."
cat > /etc/nginx/nginx.conf <<EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # Brotli compression
    brotli on;
    brotli_comp_level 6;
    brotli_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml font/truetype font/opentype application/vnd.ms-fontobject image/svg+xml;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml font/truetype font/opentype application/vnd.ms-fontobject image/svg+xml;

    # HTTP server
    server {
        listen ${NGINX_HTTP_PORT};
        server_name ${DOMAIN};

        location /.well-known/acme-challenge/ {
            root /var/www/html;
        }

        location / {
            return 301 https://\$host\$request_uri;
        }
    }
}
EOF

log_info "Nginx configuration generated"

# Setup crontab for certificate renewal
log_info "Setting up crontab for certificate auto-renewal..."
cat > /tmp/crontab.txt <<EOF
0 3 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh > /var/log/acme.log 2>&1
EOF
crontab /tmp/crontab.txt
rm /tmp/crontab.txt

# Update GeoIP and GeoSite data
log_info "Updating GeoIP and GeoSite data..."
GEODATA_DIR="/usr/local/etc/xray"

# Download geoip.dat
wget -q -O "${GEODATA_DIR}/geoip.dat" \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" || \
    log_warn "Failed to download geoip.dat"

# Download geosite.dat
wget -q -O "${GEODATA_DIR}/geosite.dat" \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" || \
    log_warn "Failed to download geosite.dat"

log_info "GeoIP/GeoSite data updated"

# Create mime.types for Nginx if it doesn't exist
if [ ! -f /etc/nginx/mime.types ]; then
    cat > /etc/nginx/mime.types <<'EOF'
types {
    text/html                             html htm shtml;
    text/css                              css;
    text/xml                              xml;
    image/gif                             gif;
    image/jpeg                            jpeg jpg;
    application/javascript                js;
    application/atom+xml                  atom;
    application/rss+xml                   rss;

    text/mathml                           mml;
    text/plain                            txt;
    text/vnd.sun.j2me.app-descriptor      jad;
    text/vnd.wap.wml                      wml;
    text/x-component                      htc;

    image/png                             png;
    image/tiff                            tif tiff;
    image/vnd.wap.wbmp                    wbmp;
    image/x-icon                          ico;
    image/x-jng                           jng;
    image/x-ms-bmp                        bmp;
    image/svg+xml                         svg svgz;
    image/webp                            webp;

    application/font-woff                 woff;
    application/java-archive              jar war ear;
    application/json                      json;
    application/mac-binhex40              hqx;
    application/msword                    doc;
    application/pdf                       pdf;
    application/postscript                ps eps ai;
    application/rtf                       rtf;
    application/vnd.apple.mpegurl         m3u8;
    application/vnd.ms-excel              xls;
    application/vnd.ms-fontobject         eot;
    application/vnd.ms-powerpoint         ppt;
    application/vnd.wap.wmlc              wmlc;
    application/vnd.google-earth.kml+xml  kml;
    application/vnd.google-earth.kmz      kmz;
    application/x-7z-compressed           7z;
    application/x-cocoa                   cco;
    application/x-java-archive-diff       jardiff;
    application/x-java-jnlp-file          jnlp;
    application/x-makeself                run;
    application/x-perl                    pl pm;
    application/x-pilot                   prc pdb;
    application/x-rar-compressed          rar;
    application/x-redhat-package-manager  rpm;
    application/x-sea                     sea;
    application/x-shockwave-flash         swf;
    application/x-stuffit                 sit;
    application/x-tcl                     tcl tk;
    application/x-x509-ca-cert            der pem crt;
    application/x-xpinstall               xpi;
    application/xhtml+xml                 xhtml;
    application/xspf+xml                  xspf;
    application/zip                       zip;

    application/octet-stream              bin exe dll;
    application/octet-stream              deb;
    application/octet-stream              dmg;
    application/octet-stream              iso img;
    application/octet-stream              msi msp msm;

    application/vnd.openxmlformats-officedocument.wordprocessingml.document    docx;
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet          xlsx;
    application/vnd.openxmlformats-officedocument.presentationml.presentation  pptx;

    audio/midi                            mid midi kar;
    audio/mpeg                            mp3;
    audio/ogg                             ogg;
    audio/x-m4a                           m4a;
    audio/x-realaudio                     ra;

    video/3gpp                            3gpp 3gp;
    video/mp2t                            ts;
    video/mp4                             mp4;
    video/mpeg                            mpeg mpg;
    video/quicktime                       mov;
    video/webm                            webm;
    video/x-flv                           flv;
    video/x-m4v                           m4v;
    video/x-mng                           mng;
    video/x-ms-asf                        asx asf;
    video/x-ms-wmv                        wmv;
    video/x-msvideo                       avi;
}
EOF
fi

# Print connection information
log_info "============================================"
log_info "Xray Connection Information:"
log_info "============================================"
log_info "Protocol: ${XRAY_PROTOCOL}"
log_info "Address: ${DOMAIN}"
log_info "Port: ${XRAY_PORT}"
log_info "UUID: ${XRAY_UUID}"
log_info "Flow: ${XRAY_FLOW}"
log_info "TLS: tls"
log_info "SNI: ${DOMAIN}"
log_info "ALPN: h2,http/1.1"
log_info "============================================"
log_info "Please save this information for your client configuration"
log_info "============================================"

# Execute the main command
log_info "Starting services with supervisord..."
exec "$@"
