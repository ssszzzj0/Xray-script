# Multi-stage build for Xray-script Docker image

# Stage 1: Build Nginx with OpenSSL and ngx_brotli
FROM debian:bookworm-slim AS nginx-builder

# Set Nginx and OpenSSL versions
ENV NGINX_VERSION=1.27.3 \
    OPENSSL_VERSION=3.4.1

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    gcc \
    g++ \
    make \
    git \
    perl \
    libpcre2-dev \
    zlib1g-dev \
    libxml2-dev \
    libxslt1-dev \
    libgd-dev \
    libgeoip-dev \
    libgoogle-perftools-dev \
    libperl-dev \
    libbrotli-dev \
    && rm -rf /var/lib/apt/lists/*

# Download and extract sources
WORKDIR /tmp/build

# Download Nginx
RUN wget https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz \
    && tar -xzf nginx-${NGINX_VERSION}.tar.gz

# Download OpenSSL
RUN wget https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz \
    && tar -xzf openssl-${OPENSSL_VERSION}.tar.gz

# Clone ngx_brotli module
RUN git clone --recurse-submodules https://github.com/google/ngx_brotli.git

# Configure and build Nginx
WORKDIR /tmp/build/nginx-${NGINX_VERSION}
RUN ./configure \
    --prefix=/usr/local/nginx \
    --sbin-path=/usr/sbin/nginx \
    --modules-path=/usr/lib/nginx/modules \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/var/run/nginx.pid \
    --lock-path=/var/run/nginx.lock \
    --http-client-body-temp-path=/var/cache/nginx/client_temp \
    --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
    --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
    --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
    --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
    --user=nginx \
    --group=nginx \
    --with-compat \
    --with-file-aio \
    --with-threads \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_mp4_module \
    --with-http_random_index_module \
    --with-http_realip_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_stub_status_module \
    --with-http_sub_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-http_image_filter_module \
    --with-http_geoip_module \
    --with-http_perl_module \
    --with-http_xslt_module \
    --with-google_perftools_module \
    --with-stream \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --with-stream_realip_module \
    --with-stream_geoip_module \
    --with-mail \
    --with-mail_ssl_module \
    --add-module=/tmp/build/ngx_brotli \
    --with-openssl=/tmp/build/openssl-${OPENSSL_VERSION} \
    --with-openssl-opt='enable-tls1_3 enable-ec_nistp_64_gcc_128' \
    --with-cc-opt='-O3 -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector-strong --param=ssp-buffer-size=4 -grecord-gcc-switches -m64 -mtune=generic' \
    && make -j$(nproc) \
    && make install

# Stage 2: Final runtime image
FROM debian:bookworm-slim

LABEL maintainer="Xray-script"
LABEL description="Xray-script Docker image with Nginx, Xray-core, and acme.sh"

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    openssl \
    curl \
    wget \
    unzip \
    jq \
    socat \
    cron \
    iproute2 \
    procps \
    dnsutils \
    qrencode \
    tzdata \
    supervisor \
    libpcre2-8-0 \
    zlib1g \
    libxml2 \
    libxslt1.1 \
    libgd3 \
    libgeoip1 \
    libgoogle-perftools4 \
    libbrotli1 \
    && rm -rf /var/lib/apt/lists/*

# Create nginx user
RUN groupadd -r nginx && useradd -r -g nginx nginx

# Copy Nginx from builder stage
COPY --from=nginx-builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx-builder /usr/local/nginx /usr/local/nginx
COPY --from=nginx-builder /usr/lib/nginx /usr/lib/nginx

# Create required directories
RUN mkdir -p /var/cache/nginx/client_temp \
    /var/cache/nginx/proxy_temp \
    /var/cache/nginx/fastcgi_temp \
    /var/cache/nginx/uwsgi_temp \
    /var/cache/nginx/scgi_temp \
    /var/log/nginx \
    /usr/local/etc/xray \
    /usr/local/etc/xray/cert \
    /usr/local/etc/xray-script \
    /etc/supervisor/conf.d \
    /root/.acme.sh \
    && chown -R nginx:nginx /var/cache/nginx /var/log/nginx

# Install latest Xray-core
RUN XRAY_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name) \
    && wget -O /tmp/Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" \
    && unzip /tmp/Xray-linux-64.zip -d /tmp/xray \
    && mv /tmp/xray/xray /usr/local/bin/xray \
    && chmod +x /usr/local/bin/xray \
    && rm -rf /tmp/Xray-linux-64.zip /tmp/xray

# Install acme.sh
RUN curl https://get.acme.sh | sh -s email=my@example.com \
    && ln -s /root/.acme.sh/acme.sh /usr/local/bin/acme.sh

# Copy project files
COPY . /usr/local/etc/xray-script

# Copy supervisor configuration
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose ports
EXPOSE 80 443

# Set volumes
VOLUME ["/usr/local/etc/xray", "/root/.acme.sh", "/var/log"]

# Set timezone to UTC
ENV TZ=UTC

# Entrypoint and command
ENTRYPOINT ["/entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
