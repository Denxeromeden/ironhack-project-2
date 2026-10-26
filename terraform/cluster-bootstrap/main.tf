# Run initialization with terraform init -backend-config=../backend.conf (make sure it reflects the bucket name 
# and region used when creating the backend)
locals {
  name_prefix       = "${var.unique_id}-${var.env_tag}"
  state_bucket_name = "ironhack-project-2-state-${var.unique_id}"
  common_tags = {
    Project   = var.project_name
    Env       = var.env_tag
    Owner     = var.unique_id
    ManagedBy = "terraform"
  }
  normalized_zone_name = lower(trimsuffix(var.zone_name, "."))
  normalized_subdomain = lower(trimsuffix(var.subdomain, "."))

  base_domain = "${local.normalized_subdomain}.${local.normalized_zone_name}"
}

data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = local.state_bucket_name
    key    = "infra/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "selected" {
  name         = var.zone_name
  private_zone = false
}
# =============================================================================
#  Install ArgoCD
# =============================================================================
# Create namespace for ArgoCD
resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

# Create ArgoCD instance
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.11.1"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  values = [jsonencode({
    controller = {
      replicas = 1
    }
    server = {
      replicas = 1
      service = {
        type = "ClusterIP"
      }
    }
    repoServer = {
      replicas = 1
    }
  })]
}
# =============================================================================
#  Cluster Secret and root ApplicationSet
# =============================================================================
resource "kubernetes_secret_v1" "argocd_cluster_in_cluster" {
  metadata {
    name      = "cluster-in-cluster"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      "cluster-bootstrap-root"         = "true"
    }
    annotations = {
      "cluster_name" = data.terraform_remote_state.infra.outputs.cluster_name
      "region"       = var.aws_region
      "account_id"   = data.aws_caller_identity.current.account_id
      "ecr_registry" = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
      "base_domain"  = local.base_domain
      "zone_name"    = local.normalized_zone_name
      "zone_id"      = data.aws_route53_zone.selected.zone_id
      "acme_email"   = var.acme_email
      "acme_issuer"  = var.acme_issuer
      "name_prefix"  = local.name_prefix
      "env_tag"      = var.env_tag
    }
  }

  data = {
    name   = "in-cluster"
    server = "https://kubernetes.default.svc"
  }

  type       = "Opaque"
  depends_on = [helm_release.argocd]
}

resource "kubernetes_manifest" "root_applicationset" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "ApplicationSet"
    metadata = {
      name      = "root"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      generators = [
        {
          clusters = {
            selector = {
              matchLabels = {
                "cluster-bootstrap-root" = "true"
              }
            }
          }
        }
      ]
      template = {
        metadata = {
          name = "root-app"
          finalizers = [
            "resources-finalizer.argocd.argoproj.io"
          ]
        }
        spec = {
          project = "default"
          source = {
            repoURL        = var.repo_url
            targetRevision = var.repo_revision
            path           = "gitops/argocd"
            helm = {
              parameters = [
                {
                  name  = "clusterName"
                  value = "{{metadata.annotations.cluster_name}}"
                },
                {
                  name  = "region"
                  value = "{{metadata.annotations.region}}"
                },
                {
                  name  = "accountId"
                  value = "{{metadata.annotations.account_id}}"
                },
                {
                  name  = "ecrRegistry"
                  value = "{{metadata.annotations.ecr_registry}}"
                },
                {
                  name  = "baseDomain"
                  value = "{{metadata.annotations.base_domain}}"
                },
                {
                  name  = "zoneName"
                  value = "{{metadata.annotations.zone_name}}"
                },
                {
                  name  = "zoneId"
                  value = "{{metadata.annotations.zone_id}}"
                },
                {
                  name  = "acmeEmail"
                  value = "{{metadata.annotations.acme_email}}"
                },
                {
                  name  = "acmeIssuer"
                  value = "{{metadata.annotations.acme_issuer}}"
                },
                {
                  name  = "namePrefix"
                  value = "{{metadata.annotations.name_prefix}}"
                },
                {
                  name  = "envTag"
                  value = "{{metadata.annotations.env_tag}}"
                }
              ]
            }
          }
          destination = {
            server    = "{{server}}"
            namespace = "argocd"
          }
          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_secret_v1.argocd_cluster_in_cluster]
}
# =============================================================================
#  Outputs
# =============================================================================
output "argocd_namespace" {
  value       = kubernetes_namespace_v1.argocd.metadata[0].name
  description = "Namespace where ArgoCD is installed"
}