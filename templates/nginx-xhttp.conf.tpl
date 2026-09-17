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

  server {
    listen 0.0.0.0:__VLESS_LISTEN_PORT__ ssl;
    http2 on;
    server_name __WEB_DOMAIN__;

    ssl_certificate /etc/nginx/tls/server.crt;
    ssl_certificate_key /etc/nginx/tls/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Match both the configured XHTTP path itself and any XHTTP subpaths.
    # stream-up uses HTTP/2 requests with gRPC-like headers by default.
    # Xray upstream docs recommend grpc_pass for this Nginx topology.
    location ^~ __VLESS_XHTTP_PATH__ {
      grpc_pass grpc://127.0.0.1:__VLESS_XHTTP_BACKEND_PORT__;
      grpc_set_header Host $host;
      grpc_set_header X-Real-IP $remote_addr;
      grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      grpc_read_timeout 300s;
      grpc_send_timeout 300s;
    }

    location / {
      root /usr/share/nginx/html;
      index index.html;
      try_files $uri $uri/ /index.html;
    }
  }
}
