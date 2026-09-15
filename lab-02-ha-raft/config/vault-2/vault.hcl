ui = true

api_addr     = "http://vault-2:8200"
cluster_addr = "http://vault-2:8201"
disable_mlock = true

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-2"

  retry_join {
    leader_api_addr = "http://vault-1:8200"
  }
}
