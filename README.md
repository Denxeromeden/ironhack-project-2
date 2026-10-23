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

Original repo: https://github.com/Pokfinner/ironhack-project-1
