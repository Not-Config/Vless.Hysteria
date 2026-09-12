{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": __VLESS_GRPC_BACKEND_PORT__,
      "protocol": "vless",
      "settings": {
        "clients": __VLESS_CLIENTS_JSON__,
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {
          "serviceName": "__VLESS_GRPC_SERVICE__",
          "multiMode": false
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
