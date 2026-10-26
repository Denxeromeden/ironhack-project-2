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

variable "repo_url" {
  type        = string
  description = "Git repository URL for the ArgoCD manifests"
  default     = "https://github.com/Denxeromeden/ironhack-project-2"
}

variable "repo_revision" {
  type        = string
  description = "Git branch or tag to track"
  default     = "main"
}

variable "zone_name" {
  type        = string
  description = "Route 53 hosted zone name"
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

variable "subdomain" {
  type        = string
  description = "Name of the subdomain to add under the hosted zone in AWS."
  default     = "dvd"
}