# Run initialization with terraform init -backend-config=../backend.conf (make sure it reflects the bucket name 
# and region used when creating the backend)
data "aws_caller_identity" "current" {}
data "aws_route53_zone" "primary" {
  name = var.zone_name
}

locals {
  services                  = ["vote", "result", "worker"]
  state_bucket_name         = "ironhack-project-2-state-${var.unique_id}"
  state_bucket_arn          = "arn:aws:s3:::${local.state_bucket_name}"
  state_bucket_arn_wildcard = "arn:aws:s3:::${local.state_bucket_name}/*"
  oidc_provider_arn         = var.manage_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
  name_prefix               = "${var.unique_id}-${var.env_tag}"
  common_tags = {
    Project   = var.project_name
    Env       = var.env_tag
    Owner     = var.unique_id
    ManagedBy = "terraform"
  }
  github_subject_prefix = var.github_use_immutable_subject ? (
    "repo:${var.github_org}@${var.github_owner_id}/${var.github_repo}@${var.github_repository_id}"
    ) : (
    "repo:${var.github_org}/${var.github_repo}"
  )
  account_id                   = data.aws_caller_identity.current.account_id
  region                       = var.aws_region
  project_role_arn             = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*"
  project_instance_profile_arn = "arn:aws:iam::${local.account_id}:instance-profile/${local.name_prefix}-*"
  project_policy_arn           = "arn:aws:iam::${local.account_id}:policy/${local.name_prefix}-*"
  project_ecr_arn              = "arn:aws:ecr:${local.region}:${local.account_id}:repository/${local.name_prefix}-*"
  project_secret_arn           = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${local.name_prefix}-*"
  project_kms_alias_arn        = "arn:aws:kms:${local.region}:${local.account_id}:alias/${local.name_prefix}-*"
  project_kms_key_arn          = "arn:aws:kms:${local.region}:${data.aws_caller_identity.current.account_id}:key/*"

}

# -----------------------------------------------------------------------------
# ECR Repositories
# -----------------------------------------------------------------------------
#Create a repository for each image that will be built (vote and result for the frontend, worker for the backend)
resource "aws_ecr_repository" "repos" {
  for_each             = toset(local.services)
  name                 = "${local.name_prefix}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_delete
  tags                 = local.common_tags

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Add policy to keep a limited amount of images
resource "aws_ecr_lifecycle_policy" "retention" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last ${var.image_retention_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.image_retention_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# GitHub OIDC Provider
# -----------------------------------------------------------------------------
#Create or retrieve the oidc provider
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.manage_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.manage_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

# -----------------------------------------------------------------------------
# tf-plan Role 
# -----------------------------------------------------------------------------
# Define iam trust policy for GitHub, allowing to assume the role if the target 
# audience is AWS and the workflow triggering event is a pull request from the specified repo
data "aws_iam_policy_document" "tf_plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_subject_prefix}:pull_request", "${local.github_subject_prefix}:ref:refs/heads/main"]
    }
  }
}

#Create role and attach role policy
resource "aws_iam_role" "tf_plan" {
  name               = "${local.name_prefix}-tf-plan-role"
  assume_role_policy = data.aws_iam_policy_document.tf_plan_trust.json
  tags               = local.common_tags
}

#Attach default read-only permission policy
resource "aws_iam_role_policy_attachment" "tf_plan_readonly" {
  role       = aws_iam_role.tf_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Define permission policy to access the remote state files
data "aws_iam_policy_document" "state_bucket_read" {
  statement {
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      local.state_bucket_arn,
      local.state_bucket_arn_wildcard
    ]
  }
}

# Create the actual permission policy
resource "aws_iam_policy" "tf_plan_state" {
  name   = "${local.name_prefix}-tf-plan-state-policy"
  policy = data.aws_iam_policy_document.state_bucket_read.json
  tags   = local.common_tags
}

# Attach the permission policy to the role
resource "aws_iam_role_policy_attachment" "tf_plan_state_attach" {
  role       = aws_iam_role.tf_plan.name
  policy_arn = aws_iam_policy.tf_plan_state.arn
}

# -----------------------------------------------------------------------------
# tf-apply Role
# -----------------------------------------------------------------------------
# EC2, EKS and CloudWatch Logs permissions are broad enough to avoid having
# to enumerate every resource-level action used by the infrastructure.
# IAM, Route 53, ECR, Secrets Manager and KMS are scoped more narrowly.
#
# This role is protected by the GitHub infra-apply / infra-destroy environments.
# -----------------------------------------------------------------------------
# Define iam trust policy for GitHub, allowing to assume the role if the target 
# audience is AWS and the workflow triggering event is a pull request from the specified repo
data "aws_iam_policy_document" "tf_apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"

      values = [
        "${local.github_subject_prefix}:environment:infra-apply",
        "${local.github_subject_prefix}:environment:infra-destroy"
      ]
    }
  }
}

resource "aws_iam_role" "tf_apply" {
  name               = "${local.name_prefix}-tf-apply-role"
  assume_role_policy = data.aws_iam_policy_document.tf_apply_trust.json
  tags               = local.common_tags
}

# -----------------------------------------------------------------------------
# Permissions policy
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "tf_apply_permissions" {

  # ---------------------------------------------------------------------------
  # Terraform S3 backend
  # ---------------------------------------------------------------------------
  statement {
    sid = "ReadTerraformStateBucket"

    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning"
    ]

    resources = [local.state_bucket_arn]
  }

  statement {
    sid = "ManageTerraformStateObjects"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = [local.state_bucket_arn_wildcard]
  }

  # ---------------------------------------------------------------------------
  # EC2 and EKS
  # ---------------------------------------------------------------------------
  statement {
    sid = "ManageEc2AndEks"

    actions = [
      "ec2:*",
      "eks:*"
    ]

    resources = ["*"]
  }

  # ---------------------------------------------------------------------------
  # CloudWatch Logs
  # ---------------------------------------------------------------------------
  statement {
    sid       = "ManageCloudWatchLogs"
    actions   = ["logs:*"]
    resources = ["*"]
  }

  # ---------------------------------------------------------------------------
  # Route 53
  # ---------------------------------------------------------------------------
  statement {
    sid = "ManageProjectDnsRecords"

    actions = [
      "route53:GetHostedZone",
      "route53:ListResourceRecordSets",
      "route53:ChangeResourceRecordSets",
      "route53:ListTagsForResource",
      "route53:ChangeTagsForResource"
    ]

    resources = [
      "arn:aws:route53:::hostedzone/${data.aws_route53_zone.primary.zone_id}"
    ]
  }

  statement {
    sid = "ReadRoute53HostedZones"

    actions = [
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName"
    ]

    resources = ["*"]
  }

  statement {
    sid       = "ReadRoute53ChangeStatus"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  # ---------------------------------------------------------------------------
  # ECR
  # ---------------------------------------------------------------------------
  statement {
    sid       = "GetEcrAuthorizationToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid     = "ManageProjectEcrRepositories"
    actions = ["ecr:*"]

    resources = [
    local.project_ecr_arn]
  }

  # ---------------------------------------------------------------------------
  # Secrets Manager
  # ---------------------------------------------------------------------------
  statement {
    sid = "ManageProjectSecrets"

    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:RestoreSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:PutResourcePolicy",
      "secretsmanager:DeleteResourcePolicy",
      "secretsmanager:ListSecretVersionIds"
    ]

    resources = [
    local.project_secret_arn]
  }

  # ---------------------------------------------------------------------------
  # KMS
  # ---------------------------------------------------------------------------
  # New keys must be created with the same Project tag used by common_tags.
  statement {
    sid       = "CreateTaggedProjectKmsKeys"
    actions   = ["kms:CreateKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [var.project_name]
    }
  }

  statement {
    sid = "DiscoverKmsKeysAndAliases"

    actions = [
      "kms:ListKeys",
      "kms:ListAliases"
    ]

    resources = ["*"]
  }

  # Manage and use keys tagged for this project.
  statement {
    sid = "ManageTaggedProjectKmsKeys"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:PutKeyPolicy",
      "kms:EnableKey",
      "kms:DisableKey",
      "kms:EnableKeyRotation",
      "kms:DisableKeyRotation",
      "kms:GetKeyRotationStatus",
      "kms:UpdateKeyDescription",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ListResourceTags",
      "kms:ListKeyPolicies",
      "kms:ListGrants",
      "kms:CreateGrant",
      "kms:RevokeGrant",
      "kms:RetireGrant",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion"
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_name]
    }
  }

  # KMS aliases are separate resources and do not inherit the key's tags.
  # Alias names are restricted to the project prefix. The key ARN pattern
  # allows alias creation/update to reference the target key.
  statement {
    sid = "ManageProjectKmsAliases"

    actions = [
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:UpdateAlias"
    ]

    resources = [
      local.project_kms_alias_arn,
      local.project_kms_key_arn
    ]
  }

  # ---------------------------------------------------------------------------
  # IAM: project roles
  # ---------------------------------------------------------------------------
  statement {
    sid = "ManageProjectRoles"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole"
    ]

    resources = [
    local.project_role_arn]
  }

  # ---------------------------------------------------------------------------
  # IAM: project instance profiles
  # ---------------------------------------------------------------------------
  statement {
    sid = "ManageProjectInstanceProfiles"

    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile"
    ]

    resources = [
      local.project_instance_profile_arn
    ]
  }

  # ---------------------------------------------------------------------------
  # IAM: project-managed policies
  # ---------------------------------------------------------------------------
  # Required because this Terraform configuration creates and updates its
  # tf-plan-state, tf-apply and ecr-push customer-managed policies.
  statement {
    sid = "ManageProjectIamPolicies"

    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy"
    ]

    resources = [
    local.project_policy_arn]
  }

  # IAM list APIs that require account-wide resource scope.
  statement {
    sid = "DiscoverIamResources"

    actions = [
      "iam:ListRoles",
      "iam:ListPolicies",
      "iam:ListInstanceProfiles",
      "iam:ListOpenIDConnectProviders",
      "iam:GetAccountSummary"
    ]

    resources = ["*"]
  }

  # Attach only expected AWS-managed policies or this project's own policies
  # to project roles. Extend the list if another role in your Terraform needs
  # a different AWS-managed policy.
  statement {
    sid = "AttachApprovedPoliciesToProjectRoles"

    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy"
    ]

    resources = [
    local.project_role_arn]

    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"

      values = [
        "arn:aws:iam::aws:policy/ReadOnlyAccess",
        "arn:aws:iam::aws:policy/AmazonEKS*",
        "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
        "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
        "arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicy",
      local.project_policy_arn]
    }
  }

  statement {
    sid     = "PassProjectRolesToAwsServices"
    actions = ["iam:PassRole"]

    resources = [
    local.project_role_arn]

  }

  statement {
    sid       = "CreateRequiredServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
  }

}

# Create the actual permission policy
resource "aws_iam_policy" "tf_apply_custom" {
  name   = "${local.name_prefix}-tf-apply-policy"
  policy = data.aws_iam_policy_document.tf_apply_permissions.json
  tags   = local.common_tags
}

# Attach the permission policy to the role
resource "aws_iam_role_policy_attachment" "tf_apply_attach" {
  role       = aws_iam_role.tf_apply.name
  policy_arn = aws_iam_policy.tf_apply_custom.arn
}

# -----------------------------------------------------------------------------
# ecr-push Role
# -----------------------------------------------------------------------------
# Define iam trust policy for GitHub, allowing to assume the role if the target 
# audience is AWS and the workflow triggering event is a push coming from the specified repo
data "aws_iam_policy_document" "ecr_push_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_subject_prefix}:ref:refs/heads/main"]
    }
  }
}

#Create role and attach role policy
resource "aws_iam_role" "ecr_push" {
  name               = "${local.name_prefix}-ecr-push-role"
  assume_role_policy = data.aws_iam_policy_document.ecr_push_trust.json
  tags               = local.common_tags
}

# Define permissions to push images to ECR
data "aws_iam_policy_document" "ecr_push_permissions" {
  statement {
    actions = [
      "ecr:GetAuthorizationToken"
    ]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:CompleteLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:InitiateLayerUpload",
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:DescribeImages"
    ]
    resources = [for repo in aws_ecr_repository.repos : repo.arn]
  }
}

# Create the actual permission policy
resource "aws_iam_policy" "ecr_push_custom" {
  name   = "${local.name_prefix}-ecr-push-policy"
  policy = data.aws_iam_policy_document.ecr_push_permissions.json
  tags   = local.common_tags
}

# Attach the permission policy to the role
resource "aws_iam_role_policy_attachment" "ecr_push_attach" {
  role       = aws_iam_role.ecr_push.name
  policy_arn = aws_iam_policy.ecr_push_custom.arn
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "tf_plan_role_arn" {
  value       = aws_iam_role.tf_plan.arn
  description = "ARN for the tf-plan IAM role"
}

output "tf_apply_role_arn" {
  value       = aws_iam_role.tf_apply.arn
  description = "ARN for the tf-apply / infra-destroy IAM role"
}

output "ecr_push_role_arn" {
  value       = aws_iam_role.ecr_push.arn
  description = "ARN for the ecr-push IAM role"
}

output "ecr_repository_urls" {
  value       = { for k, repo in aws_ecr_repository.repos : k => repo.repository_url }
  description = "URLs of the provisioned ECR repositories"
}