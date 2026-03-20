resource "kubernetes_namespace" "staging" {
  metadata {
    name = "staging"
    labels = {
      env = "staging"
    }
  }
}

resource "kubernetes_namespace" "production" {
  metadata {
    name = "production"
    labels = {
      env = "production"
    }
  }
}
