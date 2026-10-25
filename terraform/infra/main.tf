# Run initialization with terraform init -backend-config=../backend.conf (make sure it reflects the bucket name 
# and region used when creating the backend)
data "aws_caller_identity" "current" {}

locals {
  name_prefix       = "${var.unique_id}-${var.env_tag}"
  state_bucket_name = "ironhack-project-2-state-${var.unique_id}"
  common_tags = {
    Project   = var.project_name
    Env       = var.env_tag
    Owner     = var.unique_id
    ManagedBy = "terraform"
  }
  region               = var.aws_region
  account_id           = data.aws_caller_identity.current.account_id
  cluster_name         = "${local.name_prefix}-cluster"
  azs                  = var.az == null ? slice(data.aws_availability_zones.available.names, 0, 2) : var.az
  route53_zone_id      = data.aws_route53_zone.primary.zone_id
  normalized_zone_name = lower(trimsuffix(var.zone_name, "."))
  normalized_subdomain = lower(trimsuffix(var.subdomain, "."))
  full_subdomain       = "${local.normalized_subdomain}.${local.normalized_zone_name}"
  project_secret_arn   = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${local.name_prefix}-*"
}

#Exclude zones that do not work with EKS
data "aws_availability_zones" "available" {
  exclude_zone_ids = ["use1-az3"]

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = local.state_bucket_name
    key    = "bootstrap/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_route53_zone" "primary" {
  name = var.zone_name
}

# -----------------------------------------------------------------------------
# VPC Module 
# -----------------------------------------------------------------------------
# Create vpc with one private and one public subnet per AZ, one or more NAT gateway,
# an S3 gateway endpoint and the tags for Kubernetes discovery, plus the necessary
# connections (e.g. internet gateway, routing tables, etc.)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~>6.7"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 1)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 101)]

  enable_nat_gateway     = true
  single_nat_gateway     = !var.nat_per_az # 1 shared NAT if false; 1 per AZ if true
  one_nat_gateway_per_az = var.nat_per_az
  enable_dns_hostnames   = true

  # Mandatory tags for Kubernetes public and internal load balancer discovery
  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  tags = local.common_tags
}

# Add S3 endpoint, save charges from gateways
module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~>6.7"

  vpc_id = module.vpc.vpc_id

  endpoints = {
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = concat(module.vpc.public_route_table_ids, module.vpc.private_route_table_ids)
      tags            = { Name = "${local.name_prefix}-s3-endpoint" }
    }
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# EKS Cluster, Add-ons, and Managed Node Groups
# -----------------------------------------------------------------------------
# Create EKS cluster in the defined subnets, enable cloudwatch logging, creates access entries
# for the tf_plan and tf_apply role created in bootstrap, add necessary addons, specify node characteristics
# enable node to node communication
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  create_kms_key = true
  kms_key_aliases  = ["${local.name_prefix}-cluster"]

  endpoint_public_access                   = true
  endpoint_private_access                  = true
  endpoint_public_access_cidrs             = var.endpoint_public_access_cidrs
  enable_irsa                              = false
  enable_cluster_creator_admin_permissions = false

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Control plane logging configuration
  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 7

  # Access entries mapping pipeline roles to Kubernetes permissions
  access_entries = merge(
    {
      tf-apply = {
        principal_arn = data.terraform_remote_state.bootstrap.outputs.tf_apply_role_arn
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      },
      tf-plan = {
        principal_arn = data.terraform_remote_state.bootstrap.outputs.tf_plan_role_arn
        policy_associations = {
          view = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    },
    {
      for arn in var.additional_cluster_admins : replace(basename(arn), "/", "-") => {
        principal_arn = arn
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    }
  )

  # Core Add-ons 
  addons = {
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
        enableNetworkPolicy = "true"
      })
    }
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    coredns                = {}
    metrics-server         = {} # Enables `kubectl top nodes`
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  # Managed node groups pinned per availability zone
  eks_managed_node_groups = {
    for i, az in local.azs : "node-${az}" => {
      ami_type       = var.node_architecture == "arm64" ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_types]
      capacity_type  = var.capacity_type

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      subnet_ids = [module.vpc.private_subnets[i]]

      iam_role_name = "${local.name_prefix}-nodegroup-${az}"
    }
  }

  # Open node security group traffic internally to prevent cross-pod timeout issues
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node application communication"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# IAM Role for EBS CSI Driver (Pod Identity)
# -----------------------------------------------------------------------------
# Allow attachment of EBS volumes
module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  name               = "${local.name_prefix}-ebs-csi"
  use_name_prefix    = false
  policy_name_prefix = "${local.name_prefix}-ebs_"

  attach_aws_ebs_csi_policy = true
  tags                      = local.common_tags
}

# -----------------------------------------------------------------------------
# Pod Identity Trust Policy 
# -----------------------------------------------------------------------------
# Define trust policies for controllers
data "aws_iam_policy_document" "external_dns_pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    # Restrict this role to this EKS cluster.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }

    # Restrict this role to the External DNS namespace.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["external-dns"]
    }

    # Restrict this role to the External DNS service account.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["external-dns"]
    }
  }
}

data "aws_iam_policy_document" "cert_manager_pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    # Restrict this role to this EKS cluster.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }

    # Restrict this role to the cert-manager namespace.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["cert-manager"]
    }

    # Restrict this role to the cert-manager service account.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["cert-manager"]
    }
  }
}

data "aws_iam_policy_document" "external_secrets_pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    # Restrict this role to this EKS cluster.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }

    # Restrict this role to the external-secrets namespace.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["external-secrets"]
    }

    # Restrict this role to the external-secrets service account.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["external-secrets"]
    }
  }
}

data "aws_iam_policy_document" "aws_load_balancer_controller_pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    # Restrict this role to this EKS cluster.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [module.eks.cluster_arn]
    }

    # Restrict this role to the kube-system namespace.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["kube-system"]
    }

    # Restrict this role to the aws-load-balancer-controller service account.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["aws-load-balancer-controller"]
    }
  }
}
# =============================================================================
# External DNS
# =============================================================================
# Define permission policy for the external dns controller
data "aws_iam_policy_document" "external_dns" {
  statement {
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets"
    ]
    resources = [
      "arn:aws:route53:::hostedzone/${local.route53_zone_id}"
    ]
    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values = [
        "${local.full_subdomain}",
        "*.${local.full_subdomain}"
      ]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "route53:ListResourceRecordSets",
      "route53:GetChange"
    ]
    resources = [
      "arn:aws:route53:::hostedzone/${local.route53_zone_id}",
      "arn:aws:route53:::change/*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "route53:ListHostedZones"
    ]
    resources = ["*"]
  }
}

# Create the permission policy
resource "aws_iam_policy" "external_dns" {
  name   = "${local.name_prefix}-external-dns"
  policy = data.aws_iam_policy_document.external_dns.json
  tags   = local.common_tags
}

# Create the role
resource "aws_iam_role" "external_dns" {
  name               = "${local.name_prefix}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.external_dns_pod_identity_trust.json
  tags               = local.common_tags
}

# Attach the policy
resource "aws_iam_role_policy_attachment" "external_dns" {
  role       = aws_iam_role.external_dns.name
  policy_arn = aws_iam_policy.external_dns.arn
}

# Associate the role to the cluster service account
resource "aws_eks_pod_identity_association" "external_dns" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-dns"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn
  tags            = local.common_tags
}

# =============================================================================
#  Cert-Manager
# =============================================================================
# Define permission policy for the certification manager controller
data "aws_iam_policy_document" "cert_manager" {
  statement {
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets"
    ]
    resources = [
      "arn:aws:route53:::hostedzone/${local.route53_zone_id}"
    ]
    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values = [
        "_acme-challenge.${local.full_subdomain}",
        "_acme-challenge.*.${local.full_subdomain}"
      ]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "route53:GetChange",
      "route53:ListHostedZonesByName"
    ]
    resources = ["*"]
  }
}

# Create the permission policy
resource "aws_iam_policy" "cert_manager" {
  name   = "${local.name_prefix}-cert-manager"
  policy = data.aws_iam_policy_document.cert_manager.json
  tags   = local.common_tags
}

# Create the role
resource "aws_iam_role" "cert_manager" {
  name               = "${local.name_prefix}-cert-manager"
  assume_role_policy = data.aws_iam_policy_document.cert_manager_pod_identity_trust.json
  tags               = local.common_tags
}

# Attach the policy
resource "aws_iam_role_policy_attachment" "cert_manager" {
  role       = aws_iam_role.cert_manager.name
  policy_arn = aws_iam_policy.cert_manager.arn
}

# Associate the role to the cluster service account
resource "aws_eks_pod_identity_association" "cert_manager" {
  cluster_name    = module.eks.cluster_name
  namespace       = "cert-manager"
  service_account = "cert-manager"
  role_arn        = aws_iam_role.cert_manager.arn
  tags            = local.common_tags
}

# =============================================================================
#  External Secrets
# =============================================================================
# Define permission policy for the external secret access controller
data "aws_iam_policy_document" "external_secrets" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]
    resources = [
      local.project_secret_arn
    ]
  }
}

# Create the permission policy
resource "aws_iam_policy" "external_secrets" {
  name   = "${local.name_prefix}-external-secrets"
  policy = data.aws_iam_policy_document.external_secrets.json
  tags   = local.common_tags
}

# Create the role
resource "aws_iam_role" "external_secrets" {
  name               = "${local.name_prefix}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_pod_identity_trust.json
  tags               = local.common_tags
}

# Attach the policy
resource "aws_iam_role_policy_attachment" "external_secrets" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.external_secrets.arn
}

# Associate the role to the cluster service account
resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
  tags            = local.common_tags
}

# =============================================================================
#  AWS Load Balancer Controller
# =============================================================================
# Using the official upstream policy document for AWS Load Balancer Controller
data "http" "albc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.1/docs/install/iam_policy.json"
}

# Create the permission policy
resource "aws_iam_policy" "aws_load_balancer_controller" {
  name   = "${local.name_prefix}-aws-load-balancer-controller"
  policy = data.http.albc_iam_policy.response_body
  tags   = local.common_tags
}

# Create the role
resource "aws_iam_role" "aws_load_balancer_controller" {
  name               = "${local.name_prefix}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.aws_load_balancer_controller_pod_identity_trust.json
  tags               = local.common_tags
}

# Attach the permission policy
resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  role       = aws_iam_role.aws_load_balancer_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

# Associate the role to the cluster service account
resource "aws_eks_pod_identity_association" "aws_load_balancer_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.aws_load_balancer_controller.arn
  tags            = local.common_tags
}

# =============================================================================
#  DB password secret creation
# =============================================================================
ephemeral "random_password" "postgres" {
  length  = 32
  lower   = true
  upper   = true
  numeric = true
  special = false
}

resource "aws_secretsmanager_secret" "postgres" {
  name                    = "${local.name_prefix}-postgres-app"
  recovery_window_in_days = var.secrets_recovery_window_days
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "postgres" {
  secret_id = aws_secretsmanager_secret.postgres.id

  secret_string_wo = jsonencode({
    username = var.db_user
    password = ephemeral.random_password.postgres.result
    dbname   = var.db_name
  })

  secret_string_wo_version = var.secret_string_version
}

# =============================================================================
#  Outputs
# =============================================================================
output "cluster_name" {
  value       = module.eks.cluster_name
  description = "The name of the EKS cluster"
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "Endpoint for the Kubernetes API server"
}

output "cluster_certificate_authority_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "Nested attribute containing certificate authority data for the cluster"
  sensitive   = true
}

output "ecr_registry_host" {
  value       = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  description = "Registry host for ECR repositories"
}

output "postgres_secret_name" {
  value       = aws_secretsmanager_secret.postgres.name
  description = "Name of the PostgreSQL secret in Secrets Manager"
}