# ===================== 變數 =====================

variable "postgres_password" {
  description = "PostgreSQL 資料庫密碼"
  type        = string
  sensitive   = true
}

variable "n8n_encryption_key" {
  description = "n8n 用來加密 credentials 的金鑰"
  type        = string
  sensitive   = true
}

# ===================== PostgreSQL =====================

# 儲存 PostgreSQL 密碼為 Kubernetes Secret
resource "kubernetes_secret" "postgresql" {
  metadata {
    name      = "postgresql-secret"
    namespace = "staging"
  }
  data = {
    password = var.postgres_password
  }
}

# PostgreSQL PersistentVolumeClaim（資料持久化）
resource "kubernetes_persistent_volume_claim" "postgresql" {
  metadata {
    name      = "postgresql-pvc"
    namespace = "staging"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
  wait_until_bound = false  # local-path StorageClass 採 WaitForFirstConsumer，PVC 要等 Pod 掛載後才會 Bound
}

# 部署 PostgreSQL（使用官方 image）
resource "kubernetes_stateful_set" "postgresql" {
  metadata {
    name      = "postgresql"
    namespace = "staging"
    labels = {
      app = "postgresql"
    }
  }

  spec {
    service_name = "postgresql"
    replicas     = 1

    selector {
      match_labels = {
        app = "postgresql"
      }
    }

    template {
      metadata {
        labels = {
          app = "postgresql"
        }
      }

      spec {
        container {
          name  = "postgresql"
          image = "postgres:16-alpine"  # 官方 image，穩定且輕量

          port {
            container_port = 5432
          }

          env {
            name  = "POSTGRES_USER"
            value = "n8n"
          }
          env {
            name  = "POSTGRES_DB"
            value = "n8n"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgresql.metadata[0].name
                key  = "password"
              }
            }
          }
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.postgresql.metadata[0].name
          }
        }
      }
    }
  }
}

# PostgreSQL Service（讓 n8n 可以透過 DNS 連線）
resource "kubernetes_service" "postgresql" {
  metadata {
    name      = "postgresql"
    namespace = "staging"
  }

  spec {
    selector = {
      app = "postgresql"
    }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}

# ===================== n8n =====================

# 部署 n8n（使用社群 Helm chart）
resource "helm_release" "n8n" {
  name       = "n8n"
  namespace  = "staging"
  repository = "https://8gears.container-registry.com/chartrepo/library"
  chart      = "n8n"
  version    = "0.25.2"

  # 資料庫連線設定
  set {
    name  = "db.type"
    value = "postgresdb"
  }
  set {
    name  = "db.postgresdb.host"
    value = "postgresql.staging.svc.cluster.local"  # K8s 內部 DNS
  }
  set {
    name  = "db.postgresdb.port"
    value = "5432"
  }
  set {
    name  = "db.postgresdb.database"
    value = "n8n"
  }
  set {
    name  = "db.postgresdb.user"
    value = "n8n"
  }
  set {
    name  = "db.postgresdb.password"
    value = var.postgres_password
  }

  # n8n 加密金鑰（用來保護 workflow credentials）
  set {
    name  = "n8n.encryption_key"
    value = var.n8n_encryption_key
  }

  # 對外存取的 URL
  set {
    name  = "n8n.webhookUrl"
    value = "http://n8n.martinlee.lab"
  }

  depends_on = [kubernetes_stateful_set.postgresql]  # 確保 PostgreSQL 先啟動
}

# ===================== Ingress =====================

# 建立 Traefik Ingress，讓外部可以透過 domain 存取 n8n
resource "kubernetes_ingress_v1" "n8n" {
  metadata {
    name      = "n8n-ingress"
    namespace = "staging"
    annotations = {
      "kubernetes.io/ingress.class" = "traefik"
    }
  }

  spec {
    rule {
      host = "n8n.martinlee.lab"

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "n8n"       # n8n 的 Service 名稱
              port {
                number = 5678   # n8n 預設 port
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.n8n]
}
