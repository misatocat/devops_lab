# 建立 argocd 專用 namespace
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

# 建立 ArgoCD Ingress，讓 Traefik 把流量導向 argocd-server
resource "kubernetes_ingress_v1" "argocd" {
  metadata {
    name      = "argocd-ingress"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    annotations = {
      # 指定使用 Traefik 作為 Ingress Controller
      "kubernetes.io/ingress.class" = "traefik"
    }
  }

  spec {
    rule {
      host = "argocd.martinlee.lab"  # 對應 /etc/hosts 設定的 domain

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "argocd-server"  # ArgoCD 的 Service 名稱
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.argocd]  # 確保 ArgoCD 安裝完才建立 Ingress
}

# 用 Helm 安裝 ArgoCD
resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.0"

  # 停用 TLS（本地練習環境用，正式環境請開啟）
  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }
}
