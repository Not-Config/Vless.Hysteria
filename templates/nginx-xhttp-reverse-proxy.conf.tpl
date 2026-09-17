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

  # Local HTTP endpoint used by the Hysteria2 masquerade.
  server {
    listen 127.0.0.1:__WEB_LOCAL_PORT__;
    server_name _;

    location / {
      # The camouflage endpoint is intentionally read-only. Do not relay form
      # submissions, logins or other state-changing requests to the upstream.
      limit_except GET HEAD {
        deny all;
      }

      proxy_http_version 1.1;
      proxy_ssl_server_name on;
      proxy_set_header Host $proxy_host;
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_hide_header Set-Cookie;
      proxy_pass __CAMOUFLAGE_UPSTREAM__;
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
    location ^~ __VLESS_XHTTP_PATH__ {
      grpc_pass grpc://127.0.0.1:__VLESS_XHTTP_BACKEND_PORT__;
      grpc_set_header Host $host;
      grpc_set_header X-Real-IP $remote_addr;
      grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      grpc_read_timeout 300s;
      grpc_send_timeout 300s;
    }

    location / {
      limit_except GET HEAD {
        deny all;
      }

      proxy_http_version 1.1;
      proxy_ssl_server_name on;
      proxy_set_header Host $proxy_host;
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_hide_header Set-Cookie;
      proxy_pass __CAMOUFLAGE_UPSTREAM__;
    }
  }
}
