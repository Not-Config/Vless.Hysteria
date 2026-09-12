{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": __VLESS_LISTEN_PORT__,
      "protocol": "vless",
      "settings": {
        "clients": __VLESS_CLIENTS_JSON__,
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "__REALITY_DEST__:443",
          "xver": 0,
          "serverNames": [
            "__REALITY_SNI__"
          ],
          "privateKey": "__REALITY_PRIVATE_KEY__",
          "shortIds": [
            "__REALITY_SHORT_ID__"
          ]
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
