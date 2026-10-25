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

variable "github_org" {
  type        = string
  description = "GitHub organization or username"
  default     = "Denxeromeden"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name"
  default     = "ironhack-project-2"
}

variable "project_name" {
  type        = string
  description = "Name prefix used for resources and scoped IAM permissions"
  default     = "voting-app"
}

variable "image_retention_count" {
  type        = number
  description = "Number of recent images to retain via the ECR lifecycle policy"
  default     = 10
}

variable "force_delete" {
  type        = bool
  description = "Allow deletion of ECR repositories even if they contain images during teardown"
  default     = false
}

variable "manage_oidc_provider" {
  type        = bool
  description = "Set to true to create the provider or false to look up an existing one"
  default     = false
}

variable "github_owner_id" {
  description = "Numeric ID of the GitHub repository owner"
  type        = string
  default     = "130655516"
}

variable "github_repository_id" {
  description = "Numeric ID of the GitHub repository"
  type        = string
  default     = "1431056517"
}

variable "github_use_immutable_subject" {
  description = "Whether the repository emits immutable OIDC subjects"
  type        = bool
  default     = true
}

variable "zone_name" {
  description = "Name of the hosted zone used to reach the app"
  type        = string
}