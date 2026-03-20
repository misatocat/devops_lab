# GitHub PAT（Personal Access Token），用於向 GitHub API 取得 runner registration token
# sensitive = true 表示 terraform plan/apply 輸出時不會顯示內容
variable "github_token" {
  description = "GitHub runner registration token"
  type        = string
  sensitive   = true
}

# 將 GitHub PAT 存入 Kubernetes Secret，避免明文寫在設定檔裡
resource "kubernetes_secret" "runner_token" {
  metadata {
    name      = "github-runner-token"
    namespace = "default"
  }

  data = {
    token = var.github_token  # 從變數讀入，不會寫死在程式碼中
  }
}

# 部署 GitHub Actions Self-hosted Runner 到 K3s
resource "kubernetes_deployment" "github_runner" {
  metadata {
    name      = "github-runner"
    namespace = "default"
    labels = {
      app = "github-runner"
    }
  }

  spec {
    replicas = 1  # 只跑一個 runner 實例，需要更多並行 job 時可以增加

    # 用 label 選擇器綁定 Pod
    selector {
      match_labels = {
        app = "github-runner"
      }
    }

    template {
      metadata {
        labels = {
          app = "github-runner"
        }
      }

      spec {
        container {
          name  = "runner"
          image = "myoung34/github-runner:latest"  # 社群維護的 runner image，支援 K8s 環境

          # 指定要監聽哪個 GitHub repo 的 job
          env {
            name  = "REPO_URL"
            value = "https://github.com/misatocat/devops_lab"
          }
          # Runner 在 GitHub 介面顯示的名稱
          env {
            name  = "RUNNER_NAME"
            value = "k3s-runner"
          }
          # Runner 執行 job 時的工作目錄
          env {
            name  = "RUNNER_WORKDIR"
            value = "/tmp/runner/work"
          }
          # 設定 runner 範圍為單一 repo（也可設為 org）
          env {
            name  = "RUNNER_SCOPE"
            value = "repo"
          }
          # 在 workflow 中用 runs-on 指定這些 label 來使用此 runner
          env {
            name  = "LABELS"
            value = "k3s,self-hosted,linux"
          }
          # 從 Kubernetes Secret 讀取 PAT，容器啟動時會用它向 GitHub 換取 registration token
          env {
            name = "ACCESS_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.runner_token.metadata[0].name
                key  = "token"
              }
            }
          }

          # 資源配置：requests 是保證分配量，limits 是最大用量
          resources {
            requests = {
              cpu    = "100m"   # 0.1 核心
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"   # 最多 0.5 核心
              memory = "512Mi"
            }
          }
        }

        restart_policy = "Always"  # Pod 掛掉時自動重啟，確保 runner 持續上線
      }
    }
  }
}
