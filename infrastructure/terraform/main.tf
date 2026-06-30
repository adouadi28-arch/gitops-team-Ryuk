terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "kubernetes" {
  # Utilise la configuration in-cluster (token du ServiceAccount du contrôleur)
  config_path = null
}

resource "kubernetes_namespace" "monitoring_iac" {
  metadata {
    name = "monitoring-iac"
    labels = {
      managed-by  = "terraform"
      environment = "production"
    }
  }
}

resource "kubernetes_role" "todo_api_reader" {
  metadata {
    name      = "todo-api-reader"
    namespace = kubernetes_namespace.monitoring_iac.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "services", "endpoints"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "todo_api_reader_binding" {
  metadata {
    name      = "todo-api-reader-binding"
    namespace = kubernetes_namespace.monitoring_iac.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.todo_api_reader.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace.monitoring_iac.metadata[0].name
  }
}
