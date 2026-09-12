listen: :__HY2_LISTEN_PORT__

tls:
  cert: /etc/hysteria/certs/server.crt
  key: /etc/hysteria/certs/server.key

obfs:
  type: salamander
  salamander:
    password: "__HY2_OBFS_PASSWORD__"

auth:
  type: userpass
  userpass:
__HY2_USERPASS_YAML__

quic:
  maxIdleTimeout: 60s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

masquerade:
  type: proxy
  proxy:
    url: "__HY2_MASQUERADE__"
    rewriteHost: true
