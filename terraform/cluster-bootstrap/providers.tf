terraform {
  required_version = ">= 1.16.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.infra.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.infra.outputs.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.infra.outputs.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.terraform_remote_state.infra.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.infra.outputs.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.infra.outputs.cluster_name, "--region", var.aws_region]
    }
  }
}