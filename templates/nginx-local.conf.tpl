user nginx;
worker_processes auto;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;

events {
  worker_connections 1024;
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log /dev/stdout;
  sendfile on;

  server {
    listen 127.0.0.1:__WEB_LOCAL_PORT__;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location / {
      try_files $uri $uri/ /index.html;
    }
  }
}
