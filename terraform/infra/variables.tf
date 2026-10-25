variable "aws_region" {
  type        = string
  description = "The region where the resources will be located"
  default     = "us-east-1"
}
variable "unique_id" {
  type        = string
  description = "Unique id to attach to the created resources"
  default     = "dvd"
}

variable "env_tag" {
  type        = string
  description = "Deployment environment tag"
  default     = "dev"
}

variable "project_name" {
  type        = string
  description = "Name prefix used for resources and scoped IAM permissions"
  default     = "voting-app"
}

variable "az" {
  type        = list(string)
  description = "Availability zones where to deploy the resources, must be compatible with region and EKS"
  default     = null
  validation {
    condition     = var.az == null ? true : (length(var.az) == 2)
    error_message = "Choose 2 AZs available in the aws_region}"
  }
}

variable "vpc_cidr" {
  type        = string
  description = "IPv4 CIDR for the VPC"
  default     = "10.0.0.0/16"
  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "The vpc_cidr value must be a valid IPv4 CIDR block, such as 10.0.0.0/16."
  }
}

variable "zone_name" {
  type        = string
  description = "Name of the hosted zone in AWS. The hosted zone needs to be already available. It won't be created"
}

variable "subdomain" {
  type        = string
  description = "Name of the subdomain to add under the hosted zone in AWS."
  default     = "dvd"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version for EKS. Choose among the standard support ones to avoid extra charges (https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)"
  default     = "1.37"
}

variable "node_architecture" {
  type        = string
  description = "Architecture type for the K8s nodes"
  default     = "arm64"
  validation {
    condition     = contains(["arm64", "amd64"], var.node_architecture)
    error_message = "Values must be either 'arm64' or 'amd64'"
  }
}

variable "node_instance_types" {
  type        = string
  description = "Type of instance for the node. Make sure is compatible with the node architecture and is big enough for the stack (at least 4gb RAM, better more)"
  default     = "t4g.medium"
}

variable "node_min_size" {
  type        = number
  description = "Minimum number of nodes to have (per AZ)"
  default     = 1
}

variable "node_desired_size" {
  type        = number
  description = "Desired number of nodes to have (per AZ)"
  default     = 1
}

variable "node_max_size" {
  type        = number
  description = "Maximum number of nodes to have (per AZ)"
  default     = 3
}

variable "capacity_type" {
  type        = string
  description = "Type of requested capacity"
  default     = "ON_DEMAND"
  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "Values must be either 'ON_DEMAND' or 'SPOT'"
  }
}

variable "nat_per_az" {
  type        = bool
  description = "true to deploy one NAT gateway per AZ (costlier, more resilient)"
  default     = false
}

variable "endpoint_public_access_cidrs" {
  type        = list(string)
  description = "Endpoint access for GitHub runners (they don't have a stable ip)"
  default     = ["0.0.0.0/0"]
}

variable "db_name" {
  type        = string
  description = "Name to use for the Postgres database"
  default     = "votes"
}

variable "db_user" {
  type        = string
  description = "Name to use for the Postgres database user"
  default     = "voting_app"
}

variable "secrets_recovery_window_days" {
  type        = number
  description = "0 to let a destroyed environment be recreated immediately"
  default     = 0
}

variable "acme_email" {
  type        = string
  description = "Let's Encrypt account email"
  default     = "email@email.com"
}

variable "acme_issuer" {
  type        = string
  description = "Let's Encrypt issuer type"
  default     = "letsencrypt-staging"
  validation {
    condition     = contains(["letsencrypt-staging", "letsencrypt-prod"], var.acme_issuer)
    error_message = "Values must be either 'letsencrypt-staging' or 'letsencrypt-prod'"
  }
}

variable "additional_cluster_admins" {
  type        = list(string)
  description = "Additional admins to add to the cluster. Default is tf_apply role."
}

variable "secret_string_version" {
  type        = number
  description = "Increment to allow creation of a new Postgres random password."
  default     = 1
}