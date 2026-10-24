## Repository Configuration and Deployment Setup

This repository uses specific configuration variables, secrets, and deployment environments to manage automation safely.

### Required Repository Variables
You must configure the following variables under your repository settings in the Actions section.
* AWS_REGION defines the target geographic region for cloud infrastructure.
* ZONE_NAME specifies your root domain name.
* SUBDOMAIN sets the application route prefix.
* UNIQUE_ID prevents naming conflicts across deployed resources.
* ENV_TAG identifies the deployment environment stage.
* ACME_EMAIL provides the contact address for SSL certificates.
* ACME_ISSUER selects the certificate authority provider.

### Required Repository Secrets
* SONAR_TOKEN stores the authentication key for code quality reporting.

### GitHub Environments
Deployments use two gated environments requiring manual approval before jobs start.
* infra-apply controls production resource creation and updates.
* infra-destroy controls teardown workflows.

# First-Run Bootstrap Runbook

This runbook guides new contributors through standing up the project infrastructure from scratch using a two-stage deployment process.

## Step 1: Local State Initialization & Variable Setup

Before creating remote resources, configure your local environment variables and initialize Terraform locally.

1. **Configure Environment Variables:**
   Create or copy a `terraform.tfvars` file (or set `TF_VAR_*` environment variables) with your deployment parameters. Parameters listed in the following:

  ```
  ./terraform/backend/variables.tf
  ```

2. **Initialize Terraform Locally:**
  Run
   ```
   terraform init
   
   ```
  in `./terraform/backend`

## Step 2: S3 State Bucket Provisioning

1. **Create the S3 State Bucket (if not already existing):**
  Run
   ```
   terraform validate
   terraform plan
   terraform apply   
   ```
  in `./terraform/backend`

## Step 3: Modify Backend Configuration

1. **Update `backend.conf`:**
   Edit the properties below in the file `backend.conf` in `./terraform` to point to your state bucket created in step 2, use the same region as well. e.g.:

   ```
   bucket         = "ironhack-project-2-state-<YOUR_UNIQUE_ID>"
   region         = "us-east-1"   
   ```

## Step 4: Execute Infrastructure Bootstrap

1. **Configure Environment Variables:**
   Create or copy a `terraform.tfvars` file (or set `TF_VAR_*` environment variables) with your deployment parameters. Parameters listed in the following:

  ```
  ./terraform/bootstrap/variables.tf
  ```
  Make sure they match the ones used for the backend.
2. **Initialize Terraform:**
  Run
   ```
   terraform init -backend-config=../backend.conf
   
   ```
  in `./terraform/bootstrap`. The state will be saved remotely in the bucket created at step 2.
3. **Run the bootstrap:**
  Run
   ```
   terraform validate
   terraform plan
   terraform apply   
   ```
  in `./terraform/bootstrap`

## Step 5: Configure GitHub Variables and Secrets

Once `terraform apply` completes, copy the generated Terraform outputs into your GitHub repository settings (**Settings > Secrets and variables > Actions**).

1. **Fetch Terraform Outputs:**

   ```
   terraform output
   
   ```

2. **Set Repository Variables / Secrets:**

   | Output Name | GitHub Location | Variable / Secret Name | Description | 
   | ----- | ----- | ----- | ----- | 
   | `tf_plan_role_arn` | Variables | `AWS_ROLE_TF_PLAN` | IAM Role ARN for PR Planning | 
   | `tf_apply_role_arn` | Variables (Environment: `infra-apply`) | `AWS_ROLE_TF_APPLY` | IAM Role ARN for Infrastructure Apply | 
      | `tf_apply_role_arn` | Variables (Environment: `infra-destroy`) | `AWS_ROLE_TF_APPLY` | IAM Role ARN for Infrastructure Destroy | 
   | `ecr_push_role_arn` | Variables | `AWS_ROLE_ECR_PUSH` | IAM Role ARN for ECR Container Push | 
   | `ecr_repository_urls` | Variables | `ECR_REPOSITORIES` | Container repository endpoints | 

3. **Verify Connection:**
   Open a test Pull Request to trigger the `tf-plan` workflow and verify that the GitHub OIDC provider successfully assumes the role and runs `terraform plan`.

Original repo: https://github.com/Pokfinner/ironhack-project-1
