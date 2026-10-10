terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

# ------------------------------------------------------------------------------
# Provider Configurations
# ------------------------------------------------------------------------------
provider "aws" {
  region = local.aws_region
}

provider "github" {
  owner = local.github_owner
  # Authenticates automatically via GITHUB_TOKEN environment variable
}

# ------------------------------------------------------------------------------
# Locals & Shared Parameters
# ------------------------------------------------------------------------------
locals {
  github_owner = "jacksonlskit"

  # Two distinct repositories
  repo_infra = "Capstone-CareLink-Infra"
  repo_app   = "Capstone-CareLink-App"

  path_infra = "${local.github_owner}/${local.repo_infra}"
  path_app   = "${local.github_owner}/${local.repo_app}"

  aws_region = "us-east-1"
  oidc_url   = "https://token.actions.githubusercontent.com"
  audience   = "sts.amazonaws.com"
}

# Look up current user for approval assignment
data "github_user" "current" {
  username = local.github_owner
}

# ==============================================================================
# 1. Look up existing AWS IAM OIDC Provider
# ==============================================================================
data "aws_iam_openid_connect_provider" "github" {
  url = local.oidc_url
}

# ==============================================================================
# 2. DevOps Role: Bound strictly to the APP Repository Environments
# ==============================================================================
data "aws_iam_policy_document" "devops_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = [local.audience]
    }

    # Only GitHub Actions runs originating from the App repository can assume this role
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.path_app}:environment:staging",
        "repo:${local.path_app}:environment:production"
      ]
    }
  }
}

resource "aws_iam_role" "devops" {
  name               = "carelink-github-devops-role"
  assume_role_policy = data.aws_iam_policy_document.devops_trust.json

  tags = {
    Role       = "DevOps"
    Repository = local.repo_app
    Project    = "CareLink-Health"
  }
}

resource "aws_iam_role_policy_attachment" "devops_ecr" {
  role       = aws_iam_role.devops.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# ==============================================================================
# 3. Solutions Architect (SA) Role: Bound strictly to the INFRA Repository
# ==============================================================================
data "aws_iam_policy_document" "sa_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = [local.audience]
    }

    # Only PRs and branches inside the Infra repository can assume this role
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.path_infra}:ref:refs/heads/*",
        "repo:${local.path_infra}:pull_request"
      ]
    }
  }
}

resource "aws_iam_role" "sa" {
  name               = "carelink-github-sa-role"
  assume_role_policy = data.aws_iam_policy_document.sa_trust.json

  tags = {
    Role       = "SolutionsArchitect"
    Repository = local.repo_infra
    Project    = "CareLink-Health"
  }
}

resource "aws_iam_role_policy_attachment" "sa_readonly" {
  role       = aws_iam_role.sa.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ==============================================================================
# 4. SRE Role: Bound to maintenance workflow in the INFRA Repository
# ==============================================================================
data "aws_iam_policy_document" "sre_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = [local.audience]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values = [
        "${local.path_infra}/.github/workflows/sre-ops.yml@*"
      ]
    }
  }
}

resource "aws_iam_role" "sre" {
  name               = "carelink-github-sre-role"
  assume_role_policy = data.aws_iam_policy_document.sre_trust.json

  tags = {
    Role       = "SRE"
    Repository = local.repo_infra
    Project    = "CareLink-Health"
  }
}

resource "aws_iam_role_policy_attachment" "sre_cloudwatch" {
  role       = aws_iam_role.sre.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
}

# ==============================================================================
# 5. APP REPO CONFIGURATION (Capstone-CareLink-App)
# ==============================================================================

# Environments for App Deployment
resource "github_repository_environment" "app_staging" {
  repository  = local.repo_app
  environment = "staging"
}

resource "github_repository_environment" "app_production" {
  repository  = local.repo_app
  environment = "production"

  reviewers {
    users = [data.github_user.current.id]
  }

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "app_production_branch" {
  repository     = local.repo_app
  environment    = github_repository_environment.app_production.environment
  branch_pattern = "main"
}

# Environment-Scoped DEVOPS_ROLE_ARN Variables in App Repo
resource "github_actions_environment_variable" "app_staging_devops_role" {
  repository    = local.repo_app
  environment   = github_repository_environment.app_staging.environment
  variable_name = "DEVOPS_ROLE_ARN"
  value         = aws_iam_role.devops.arn
}

resource "github_actions_environment_variable" "app_prod_devops_role" {
  repository    = local.repo_app
  environment   = github_repository_environment.app_production.environment
  variable_name = "DEVOPS_ROLE_ARN"
  value         = aws_iam_role.devops.arn
}

resource "github_actions_variable" "app_aws_region" {
  repository    = local.repo_app
  variable_name = "AWS_REGION"
  value         = local.aws_region
}

# Ruleset for App Repo: Requires unit tests, linting, and PR review
resource "github_repository_ruleset" "app_main_protection" {
  name        = "app-main-protection"
  repository  = local.repo_app
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      required_approving_review_count = 1
      dismiss_stale_reviews_on_push   = true
      require_code_owner_review       = false
      require_last_push_approval      = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true

      required_check { context = "test" }
      required_check { context = "lint-and-typecheck" }
    }
  }
}

# ==============================================================================
# 6. INFRA REPO CONFIGURATION (Capstone-CareLink-Infra)
# ==============================================================================

# Repository Variables in Infra Repo
resource "github_actions_variable" "infra_sa_role" {
  repository    = local.repo_infra
  variable_name = "SA_ROLE_ARN"
  value         = aws_iam_role.sa.arn
}

resource "github_actions_variable" "infra_sre_role" {
  repository    = local.repo_infra
  variable_name = "SRE_ROLE_ARN"
  value         = aws_iam_role.sre.arn
}

resource "github_actions_variable" "infra_aws_region" {
  repository    = local.repo_infra
  variable_name = "AWS_REGION"
  value         = local.aws_region
}

# Ruleset for Infra Repo: Requires terraform plan check and PR review
resource "github_repository_ruleset" "infra_main_protection" {
  name        = "infra-main-protection"
  repository  = local.repo_infra
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      required_approving_review_count = 1
      dismiss_stale_reviews_on_push   = true
      require_code_owner_review       = false
      require_last_push_approval      = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true

      # Workflow check in Infra repository verifying terraform plan
      required_check { context = "terraform-plan" }
    }
  }
}

# ==============================================================================
# Outputs
# ==============================================================================
output "oidc_provider_arn" {
  value = data.aws_iam_openid_connect_provider.github.arn
}

output "devops_role_arn" {
  description = "Assumed by App repo for deployment"
  value       = aws_iam_role.devops.arn
}

output "sa_role_arn" {
  description = "Assumed by Infra repo for PR checks & plans"
  value       = aws_iam_role.sa.arn
}

output "sre_role_arn" {
  description = "Assumed by Infra repo for SRE ops"
  value       = aws_iam_role.sre.arn
}
