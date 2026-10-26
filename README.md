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
   | `tf_plan_role_arn` | Secrets | `TF_PLAN_ROLE_ARN` | IAM Role ARN for PR Planning | 
   | `tf_apply_role_arn` | Secrets (Environment: `infra-apply`) | `TF_APPLY_ROLE_ARN` | IAM Role ARN for Infrastructure Apply | 
   | `tf_apply_role_arn` | Secrets (Environment: `infra-destroy`) | `TF_APPLY_ROLE_ARN` | IAM Role ARN for Infrastructure Destroy | 
   | `ecr_push_role_arn` | Secrets | `ECR_PUSH_ROLE_ARN` | IAM Role ARN for ECR Container Push | 
   | `ecr_repository_urls` | Variables | `ECR_REPOSITORIES` | Container repository endpoints | 
   |  | Secrets  | `ADDITIONAL_CLUSTER_ADMINS` | List of ARNs for additional K8s admin | 

Add also as variables
- ACME_EMAIL
- ACME_ISSUER
- AWS_REGION
- ENV_TAG
- SUBDOMAIN
- UNIQUE_ID
- ZONE_NAME


## Step 5: Configure GitHub Variables and Secrets
1. **Run the infrastructure pipeline:**
    In GitHub actions run the `Terraform Pipeline` selecting the `apply` action

2. **Run the Cluster bootstrap pipeline:**
    In GitHub actions run the `Cluster bootstrap Pipeline` selecting the `apply-prerequisite` action (locally would be terraform apply -target=helm_release.argocd).
    Once done, in GitHub actions run the `Cluster bootstrap Pipeline` selecting the `apply-full` action.

3. **Access ArgoCD dashboard:**
    Run
    ```
    aws eks update-kubeconfig --region <your aws region> --name <your-cluster-name>
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
    echo
    kubectl port-forward svc/argocd-server -n argocd 8080:443
    ```
    Access `https://localhost:8080` usign the retrieved password and `admin` as user 

4. **Access Headlamp dashboard:**
    Run
    ```
    aws eks update-kubeconfig --region <your aws region> --name <your-cluster-name>
    kubectl create token headlamp-viewer -n platform-infra --duration=1h
    echo
    kubectl port-forward -n kube-system service/platform-infra-headlamp  8081:80
    ```
    Access `https://localhost:8081` using the retrieved token.
Original repo: https://github.com/Pokfinner/ironhack-project-1

