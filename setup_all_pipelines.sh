#!/usr/bin/env bash
set -e

echo "=== 1. Creating README.md ==="
cat << 'README_EOF' > README.md
# Capstone CareLink Infrastructure & Pipelines (`Capstone-CareLink`)

This document outlines the architecture, AWS IAM OIDC security model, and CI/CD workflow templates for the CareLink platform across both repositories:
- **`Capstone-CareLink-Infra`**: Infrastructure as Code (Terraform), foundational cloud provisioning, and observability baselines.
- **`Capstone-CareLink-App`**: Application codebase, containerization, and service deployment pipelines.

---

## 1. Architecture & Security Overview

### AWS IAM OIDC Authentication (Keyless CI/CD)
To eliminate static, long-lived AWS secret access keys in GitHub Actions, this project uses **AWS IAM OpenID Connect (OIDC)** identity federation. Runners retrieve short-lived JSON Web Tokens (JWT) issued by `token.actions.githubusercontent.com` and exchange them for temporary AWS credentials via AWS STS (`sts:AssumeRoleWithWebIdentity`).

- **OIDC Provider URL:** `token.actions.githubusercontent.com`
- **Audience (`aud`):** `sts.amazonaws.com`
- **Default AWS Region:** `us-east-1`

### Shared IAM Role Matrix

| Role Name | Responsible Persona | GitHub Repo Variable | AWS Policy Attachment | Primary Scope |
| :--- | :--- | :--- | :--- | :--- |
| `carelink-github-sa-role` | Solutions Architect (SA) | `vars.SA_ROLE_ARN` | `AdministratorAccess` | Automated Terraform Plan & Apply pipelines |
| `carelink-github-devops-role` | DevSecOps / App Engineer | `vars.DEVOPS_ROLE_ARN` | `AmazonEC2ContainerRegistryPowerUser` | Docker image build, scan, and Amazon ECR push |
| `carelink-github-sre-role` | Site Reliability Engineer (SRE) | `vars.SRE_ROLE_ARN` | `CloudWatchFullAccess` | CloudWatch alarms, health checks, synthetic monitoring |

> **OIDC Subject (`sub`) Claim Note:** GitHub Actions appends internal account and repository IDs to claims (e.g., `repo:jacksonlskit@<ID>/Capstone-CareLink-Infra@<ID>:ref:...`). All IAM trust policies use wildcard pattern matching (`repo:jacksonlskit*Capstone-CareLink-Infra*:*` and `repo:jacksonlskit*Capstone-CareLink-App*:*`) to ensure stable authentication.

---

## 2. Global Repository Variables

Provisioned and managed via `oicd-bootstrap/main.tf` across both repositories:

- `AWS_REGION`: `us-east-1`
- `SA_ROLE_ARN`: `arn:aws:iam::<ACCOUNT_ID>:role/carelink-github-sa-role`
- `DEVOPS_ROLE_ARN`: `arn:aws:iam::<ACCOUNT_ID>:role/carelink-github-devops-role`
- `SRE_ROLE_ARN`: `arn:aws:iam::<ACCOUNT_ID>:role/carelink-github-sre-role`
README_EOF

echo "=== 2. Creating Workflow Directories ==="
mkdir -p .github/workflows
mkdir -p app-workflow-template

echo "=== 3. Generating SA Pipeline (.github/workflows/terraform.yaml) ==="
cat << 'SA_EOF' > .github/workflows/terraform.yaml
name: "Terraform CI/CD"

on:
  pull_request:
    branches: [main]
    paths:
      - "terraform/**"
      - "*.tf"
  push:
    branches: [main]
    paths:
      - "terraform/**"
      - "*.tf"

permissions:
  id-token: write
  contents: read
  pull-requests: write

jobs:
  terraform-plan:
    name: "Terraform Plan"
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: .

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.5.7"

      - name: Configure AWS Credentials (SA Role via OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.SA_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }} # us-east-1
          audience: sts.amazonaws.com

      - name: Terraform Format Check
        id: fmt
        run: terraform fmt -check
        continue-on-error: true

      - name: Terraform Init
        id: init
        run: terraform init

      - name: Terraform Validate
        id: validate
        run: terraform validate -no-color

      - name: Terraform Plan
        id: plan
        run: |
          terraform plan -no-color -out=tfplan \
            && terraform show -no-color tfplan > tfplan.txt
        continue-on-error: false

      - name: Publish Plan to PR
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const fs = require('fs');
            let planOutput = '';
            try {
              planOutput = fs.readFileSync('${{ github.workspace }}/tfplan.txt', 'utf8');
              if (planOutput.length > 60000) {
                planOutput = planOutput.substring(0, 60000) + '\n... [Truncated due to size limit]';
              }
            } catch (err) {
              planOutput = 'Error reading plan output.';
            }

            const comment = `#### Terraform Format: \`${{ steps.fmt.outcome }}\`
            #### Terraform Init: \`${{ steps.init.outcome }}\`
            #### Terraform Validate: \`${{ steps.validate.outcome }}\`
            #### Terraform Plan: \`${{ steps.plan.outcome }}\`

            <details><summary>Show Plan Output</summary>

            \`\`\`hcl
            ${planOutput}
            \`\`\`

            </details>

            *Actor: @${{ github.actor }} | Branch: \`${{ github.head_ref }}\`*`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: comment
            });

  terraform-apply:
    name: "Terraform Apply"
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: .

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.5.7"

      - name: Configure AWS Credentials (SA Role via OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.SA_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }} # us-east-1
          audience: sts.amazonaws.com

      - name: Terraform Init
        run: terraform init

      - name: Terraform Apply
        run: terraform apply -auto-approve -input=false
SA_EOF

echo "=== 4. Generating SRE Pipeline (.github/workflows/sre-health-check.yaml) ==="
cat << 'SRE_EOF' > .github/workflows/sre-health-check.yaml
name: "SRE: Infrastructure Health & Metric Check"

on:
  schedule:
    - cron: "0 */6 * * *"
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  cloudwatch-health-audit:
    name: "Audit CloudWatch Alarms & System Health"
    runs-on: ubuntu-latest

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials (SRE Role via OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.SRE_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }} # us-east-1
          audience: sts.amazonaws.com

      - name: Verify Assumed SRE Identity
        run: |
          aws sts get-caller-identity

      - name: Check CloudWatch Alarms in ALARM State
        run: |
          echo "=== Querying Active Alarms in ALARM State (us-east-1) ==="
          ALARMS=$(aws cloudwatch describe-alarms \
            --state-value ALARM \
            --query 'MetricAlarms[*].[AlarmName,MetricName,Namespace,StateUpdatedTimestamp]' \
            --output table)
          
          echo "$ALARMS"
          
          COUNT=$(aws cloudwatch describe-alarms --state-value ALARM --query 'length(MetricAlarms)')
          echo "Total active alarms: $COUNT"
          if [ "$COUNT" -gt "0" ]; then
            echo "::warning title=Active Alarms Detected::There are $COUNT alarms currently triggered in us-east-1."
          fi

      - name: Query Recent System Log Groups
        run: |
          echo "Checking CloudWatch Log Groups status in us-east-1..."
          aws logs describe-log-groups --limit 10 \
            --query 'logGroups[*].[logGroupName,storedBytes]' --output table
SRE_EOF

echo "=== 5. Generating DevOps Pipeline Template (for Capstone-CareLink-App) ==="
cat << 'DEVOPS_EOF' > app-workflow-template/deploy-app.yaml
name: "DevOps: Build & Push Container to ECR"

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

env:
  ECR_REPOSITORY: "carelink-app"

jobs:
  build-and-push:
    name: "Build and Push Image"
    runs-on: ubuntu-latest

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Configure AWS Credentials (DevOps Role via OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.DEVOPS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }} # us-east-1
          audience: sts.amazonaws.com

      - name: Log in to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Set Image Tag Metadata
        id: meta
        run: |
          IMAGE_TAG="${{ github.sha }}"
          REGISTRY="${{ steps.login-ecr.outputs.registry }}"
          echo "IMAGE_URI=$REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_ENV
          echo "LATEST_URI=$REGISTRY/$ECR_REPOSITORY:latest" >> $GITHUB_ENV

      - name: Build, Tag, and Push Docker Image
        run: |
          echo "Building image: $IMAGE_URI"
          docker build -t $IMAGE_URI -t$LATEST_URI .
          
          echo "Pushing images to Amazon ECR..."
          docker push $IMAGE_URI
          docker push $LATEST_URI

      - name: Deployment Verification
        run: |
          echo "Successfully pushed Docker image to us-east-1:"
          echo " - Commit SHA Tag: $IMAGE_URI"
          echo " - Latest Tag: $LATEST_URI"
DEVOPS_EOF

echo ""
echo "=========================================================="
echo " All templates have been generated successfully!"
echo "=========================================================="
echo " Created files:"
echo "   1. README.md"
echo "   2. .github/workflows/terraform.yaml        (SA Pipeline)"
echo "   3. .github/workflows/sre-health-check.yaml (SRE Pipeline)"
echo "   4. app-workflow-template/deploy-app.yaml   (DevOps Pipeline for App repo)"
echo "=========================================================="
