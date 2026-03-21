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

# 儲存 n8n 加密金鑰為 Kubernetes Secret
resource "kubernetes_secret" "n8n" {
  metadata {
    name      = "n8n-secret"
    namespace = "staging"
  }
  data = {
    encryption_key    = var.n8n_encryption_key
    postgres_password = var.postgres_password
  }
}

# 部署 n8n（使用官方 n8nio/n8n image）
resource "kubernetes_deployment" "n8n" {
  metadata {
    name      = "n8n"
    namespace = "staging"
    labels = {
      app = "n8n"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "n8n"
      }
    }

    template {
      metadata {
        labels = {
          app = "n8n"
        }
      }

      spec {
        container {
          name  = "n8n"
          image = "n8nio/n8n:latest"

          port {
            container_port = 5678
          }

          # 資料庫連線設定
          env {
            name  = "DB_TYPE"
            value = "postgresdb"
          }
          env {
            name  = "DB_POSTGRESDB_HOST"
            value = "postgresql.staging.svc.cluster.local"
          }
          env {
            name  = "DB_POSTGRESDB_PORT"
            value = "5432"
          }
          env {
            name  = "DB_POSTGRESDB_DATABASE"
            value = "n8n"
          }
          env {
            name  = "DB_POSTGRESDB_USER"
            value = "n8n"
          }
          env {
            name = "DB_POSTGRESDB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.n8n.metadata[0].name
                key  = "postgres_password"
              }
            }
          }

          # n8n 加密金鑰（用來保護 workflow credentials）
          env {
            name = "N8N_ENCRYPTION_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.n8n.metadata[0].name
                key  = "encryption_key"
              }
            }
          }

          # 對外存取的 URL
          env {
            name  = "WEBHOOK_URL"
            value = "http://n8n-staging.martinlee.lab"
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
      }
    }
  }

  depends_on = [kubernetes_stateful_set.postgresql]  # 確保 PostgreSQL 先啟動
}

# n8n Service（讓 Ingress 可以連到 n8n）
resource "kubernetes_service" "n8n" {
  metadata {
    name      = "n8n"
    namespace = "staging"
  }

  spec {
    selector = {
      app = "n8n"
    }
    port {
      port        = 5678
      target_port = 5678
    }
  }
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
      host = "n8n-staging.martinlee.lab"

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

  depends_on = [kubernetes_deployment.n8n]
}
