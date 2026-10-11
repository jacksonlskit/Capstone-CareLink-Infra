# Create-Capstone-CareLink-Infra

# Capstone CareLink Infrastructure (`Capstone-CareLink-Infra`)

This repository contains the Terraform Infrastructure as Code (IaC) and CI/CD automation pipelines for the **CareLink** platform on AWS.

---

## 1. Architecture & Security Overview

### AWS IAM OIDC Authentication (Keyless CI/CD)
To eliminate long-lived AWS access keys in GitHub Secrets, this project uses **AWS IAM OpenID Connect (OIDC)** identity federation. GitHub Actions runners obtain short-lived JSON Web Tokens (JWT) signed by `token.actions.githubusercontent.com` and exchange them via AWS STS (`sts:AssumeRoleWithWebIdentity`) for temporary credentials.

- **OIDC Provider URL:** `token.actions.githubusercontent.com`
- **Audience (`aud`):** `sts.amazonaws.com`
- **Default AWS Region:** `us-east-1`

### Shared Role Matrix

| Role Name | Purpose | Assigned Repo Variable | Attached AWS Policy |
| :--- | :--- | :--- | :--- |
| `carelink-github-sa-role` | Solutions Architect / Terraform CI/CD (Plan & Apply) | `vars.SA_ROLE_ARN` | `AdministratorAccess` |
| `carelink-github-devops-role` | Container Build & ECR Push | `vars.DEVOPS_ROLE_ARN` | `AmazonEC2ContainerRegistryPowerUser` |
| `carelink-github-sre-role` | Observability & Reliability Monitoring | `vars.SRE_ROLE_ARN` | `CloudWatchFullAccess` |

> **Note on OIDC Subject (`sub`) Claims:** GitHub Actions includes internal numeric IDs in token subjects (e.g., `repo:jacksonlskit@<ID>/Capstone-CareLink-Infra@<ID>:ref:...`). All IAM trust policies use `StringLike` wildcards (`repo:jacksonlskit*Capstone-CareLink-Infra*:*`) to accommodate these claims.

---

## 2. Repository Variables

The following repository variables are automatically provisioned and managed by `oicd-bootstrap/main.tf`:

- `AWS_REGION`: `us-east-1`
- `SA_ROLE_ARN`: `arn:aws:iam::<ACCOUNT_ID>:role/carelink-github-sa-role`
- `DEVOPS_ROLE_ARN`: `arn:aws:iam::<ACCOUNT_ID>:role/carelink-github-devops-role`
- `SRE_ROLE_ARN`: `arn:aws:iam::<ACCOUNT_ID>:role/carelink-github-sre-role`

---

## 3. GitHub Actions Workflows

All workflows are located under `.github/workflows/`.

1. **`test-oicd.yaml`**: Multi-role verification suite that checks OIDC token generation and caller identities for SA, SRE, and DevOps roles in parallel.
2. **`terraform.yaml`**: Continuous integration and deployment pipeline for infrastructure provisioning.

---

## 4. Solutions Architect CI/CD Workflow Template

Place this template in `.github/workflows/terraform.yaml` to enable automated pull request planning and push-to-main deployment:

```yaml
name: "Terraform CI/CD"

on:
  pull_request:
    branches:
      - main
    paths:
      - "terraform/**"
      - "*.tf"
  push:
    branches:
      - main
    paths:
      - "terraform/**"
      - "*.tf"

permissions:
  id-token: write        # Required: mints OIDC JWT token
  contents: read         # Required: repository checkout
  pull-requests: write   # Required: posts plan summary to PR comments

jobs:
  # ===========================================================================
  # 1. TERRAFORM PLAN (Executes on Pull Requests)
  # ===========================================================================
  terraform-plan:
    name: "Terraform Plan"
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: . # Adjust if root module is in a subfolder (e.g., ./terraform)

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
          aws-region: ${{ vars.AWS_REGION }}
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

      - name: Publish Plan Summary to PR
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const fs = require('fs');
            let planOutput = '';
            try {
              planOutput = fs.readFileSync('${{ github.workspace }}/tfplan.txt', 'utf8');
              if (planOutput.length > 60000) {
                planOutput = planOutput.substring(0, 60000) + '\n... [Plan output truncated due to GitHub character limit]';
              }
            } catch (err) {
              planOutput = 'Unable to read tfplan.txt output.';
            }

            const comment = `#### Terraform Format Check: \\`${{ steps.fmt.outcome }}\\`
            #### Terraform Initialization: \\`${{ steps.init.outcome }}\\`
            #### Terraform Validation: \\`${{ steps.validate.outcome }}\\`
            #### Terraform Plan: \\`${{ steps.plan.outcome }}\\`

            <details><summary>Click to view Plan details</summary>

            \\`\\`\\`hcl
            ${planOutput}
            \\`\\`\\`

            </details>

            *Triggered by: @${{ github.actor }} | Branch: \\`${{ github.head_ref }}\\`*`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: comment
            });

  # ===========================================================================
  # 2. TERRAFORM APPLY (Executes on Push to Main)
  # ===========================================================================
  terraform-apply:
    name: "Terraform Apply"
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: . # Adjust if root module is in a subfolder (e.g., ./terraform)

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
          aws-region: ${{ vars.AWS_REGION }}
          audience: sts.amazonaws.com

      - name: Terraform Init
        run: terraform init

      - name: Terraform Apply
        run: terraform apply -auto-approve -input=false
```

---

## 5. Local Development & Bootstrap

To update base OIDC roles or GitHub settings:
1. Navigate to `oicd-bootstrap/`.
2. Ensure AWS CLI authentication is active in `us-east-1`.
3. Run `terraform plan` and `terraform apply`.