{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": __LAB_GRPC_LISTEN_PORT__,
      "protocol": "vless",
      "settings": {
        "clients": __VLESS_CLIENTS_JSON__,
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {
          "serviceName": "__LAB_GRPC_SERVICE__",
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
