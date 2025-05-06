#!/bin/bash

# 1. 安装基础软件
apt update
apt install -y git curl wget vim socat nginx

# 2. 安装 Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
systemctl enable --now docker

# 3. 安装 acme.sh
curl https://get.acme.sh | sh -s
export PATH="$HOME/.acme.sh:$PATH"

# 4. 创建证书验证目录
mkdir -p /opt/ppanel/.well-known/acme-challenge
mkdir -p /opt/ppanel/certs

# 5. 配置临时 nginx 以支持 ACME 验证
cat > /etc/nginx/conf.d/ppanel.conf <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name admin.xty.baby user.xty.baby api.xty.baby;

    location /.well-known/acme-challenge {
        root /opt/ppanel;
    }
}
EOF

nginx -t && nginx -s reload

# 6. 申请 SSL 证书
~/.acme.sh/acme.sh --issue --server letsencrypt -d admin.xty.baby -d user.xty.baby -d api.xty.baby -w /opt/ppanel

# 7. 安装证书
~/.acme.sh/acme.sh --install-cert -d admin.xty.baby \
--key-file /opt/ppanel/certs/key.pem \
--fullchain-file /opt/ppanel/certs/cert.pem \
--reloadcmd "systemctl reload nginx"

# 8. 添加自动续期
echo "10 1 * * * ~/.acme.sh/acme.sh --renew -d admin.xty.baby -d user.xty.baby -d api.xty.baby --force &> /dev/null" >> /etc/cron.d/ppanel_domain
chmod +x /etc/cron.d/ppanel_domain

# 9. 配置正式 Nginx
cat > /etc/nginx/conf.d/ppanel.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name admin.xty.baby user.xty.baby;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name admin.xty.baby;
    ssl_certificate /opt/ppanel/certs/cert.pem;
    ssl_certificate_key /opt/ppanel/certs/key.pem;
    location / {
        proxy_pass http://127.0.0.1:3000;
        include proxy_params;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name user.xty.baby;
    ssl_certificate /opt/ppanel/certs/cert.pem;
    ssl_certificate_key /opt/ppanel/certs/key.pem;
    location / {
        proxy_pass http://127.0.0.1:3001;
        include proxy_params;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name api.xty.baby;
    ssl_certificate /opt/ppanel/certs/cert.pem;
    ssl_certificate_key /opt/ppanel/certs/key.pem;
    location / {
        proxy_pass http://127.0.0.1:8080;
        include proxy_params;
    }
}
EOF

nginx -t && nginx -s reload

# 10. 克隆并配置 ppanel 项目
cd /opt/ppanel
git clone https://github.com/perfect-panel/ppanel-script.git
cd ppanel-script

cat > docker-compose.yml <<EOF
version: '3.8'

services:
  ppanel-server:
    image: ppanel/ppanel-server:beta
    container_name: ppanel-server-beta
    ports:
      - '8080:8080'
    volumes:
      - ./config/ppanel.yaml:/opt/ppanel/ppanel-script/config/ppanel.yaml
    restart: always
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - ppanel-network

  mysql:
    image: mysql:8.0.23
    container_name: mysql_db
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: aws123456
      MYSQL_DATABASE: my_database
      MYSQL_USER: user
      MYSQL_PASSWORD: aws123456
    ports:
      - "3306:3306"
    volumes:
      - ./docker/mysql:/var/lib/mysql
    command: --default-authentication-plugin=mysql_native_password --bind-address=0.0.0.0
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-paws123456"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - ppanel-network

  redis:
    image: redis:7
    container_name: redis_cache
    restart: always
    ports:
      - "6379:6379"
    volumes:
      - ./docker/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - ppanel-network

  ppanel-admin-web:
    image: ppanel/ppanel-admin-web:beta
    container_name: ppanel-admin-web
    ports:
      - '3000:3000'
    environment:
      NEXT_PUBLIC_DEFAULT_LANGUAGE: en-US
      NEXT_PUBLIC_SITE_URL: https://admin.xty.baby
      NEXT_PUBLIC_API_URL: https://api.xty.baby
      NEXT_PUBLIC_DEFAULT_USER_EMAIL: user@user.xty.baby
      NEXT_PUBLIC_DEFAULT_USER_PASSWORD: password123

  ppanel-user-web:
    image: ppanel/ppanel-user-web:beta
    container_name: ppanel-user-web
    ports:
      - '3001:3000'
    environment:
      NEXT_PUBLIC_DEFAULT_LANGUAGE: en-US
      NEXT_PUBLIC_SITE_URL: https://user.xty.baby
      NEXT_PUBLIC_API_URL: https://api.xty.baby
      NEXT_PUBLIC_EMAIL: contact@user.xty.baby
      NEXT_PUBLIC_TELEGRAM_LINK: https://t.me/example
      NEXT_PUBLIC_TWITTER_LINK: https://twitter.com/example
      NEXT_PUBLIC_DISCORD_LINK: https://discord.com/example
      NEXT_PUBLIC_INSTAGRAM_LINK: https://instagram.com/example
      NEXT_PUBLIC_LINKEDIN_LINK: https://linkedin.com/example
      NEXT_PUBLIC_FACEBOOK_LINK: https://facebook.com/example
      NEXT_PUBLIC_GITHUB_LINK: https://github.com/example/repository
      NEXT_PUBLIC_DEFAULT_USER_EMAIL: user@user.xty.baby
      NEXT_PUBLIC_DEFAULT_USER_PASSWORD: password123

networks:
  ppanel-network:
    driver: bridge
EOF

# 11. 启动容器
docker compose up -d
