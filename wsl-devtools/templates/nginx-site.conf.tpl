# Managed by wsl-devtools: created {{CREATED}} by scripts/nginx-site.sh
# Remove with: sudo rm /etc/nginx/sites-enabled/{{SERVER_NAME}} /etc/nginx/sites-available/{{SERVER_NAME}}
#              sudo nginx -t && sudo systemctl reload nginx
server {
    # Same listen form as Ubuntu's default site, so existing sites keep working.
    listen 80;
    listen [::]:80;

    server_name {{SERVER_NAME}};
    root {{DOCUMENT_ROOT}};
    index index.php index.html;

    access_log /var/log/nginx/{{SERVER_NAME}}.access.log;
    error_log /var/log/nginx/{{SERVER_NAME}}.error.log;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:{{PHP_FPM_SOCKET}};
    }

    # Hide dotfiles such as .env and .git, but allow .well-known.
    location ~ /\.(?!well-known) {
        deny all;
    }
}
