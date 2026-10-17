terraform {
  required_version = ">= 1.10.0"
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

provider "aws" {
  region = local.aws_region
}

provider "github" {
  owner = local.github_owner
}

# -----------------------------------------------------------------------------
# LOCALS & DATA SOURCES
# -----------------------------------------------------------------------------

locals {
  github_owner = "jacksonlskit"
  repo_infra   = "Capstone-CareLink-Infra"
  repo_app     = "Capstone-CareLink-App"
  aws_region   = "us-east-1"
  oidc_url     = "https://token.actions.githubusercontent.com"
}

data "aws_caller_identity" "current" {}

data "github_user" "current" {
  username = local.github_owner
}

# -----------------------------------------------------------------------------
# OIDC IDENTITY PROVIDER
# -----------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = local.oidc_url
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]
}

# -----------------------------------------------------------------------------
# 1. S3 BACKEND STORAGE (NATIVE S3 LOCKFILE - NO DYNAMODB)
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "tf_state" {
  bucket        = "carelink-infra-state-${local.aws_region}-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state_versioning" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state_crypto" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state_block_public" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# 2. ENVIRONMENT-BASED IAM ROLES & POLICIES
# -----------------------------------------------------------------------------

# Staging IAM Role
resource "aws_iam_role" "staging" {
  name = "carelink-github-staging-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = [
              "repo:${local.github_owner}/${local.repo_infra}:environment:staging",
              "repo:${local.github_owner}/${local.repo_app}:environment:staging"
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "staging_admin" {
  role       = aws_iam_role.staging.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Production IAM Role
resource "aws_iam_role" "production" {
  name = "carelink-github-production-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = [
              "repo:${local.github_owner}/${local.repo_infra}:environment:production",
              "repo:${local.github_owner}/${local.repo_app}:environment:production"
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "production_admin" {
  role       = aws_iam_role.production.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# -----------------------------------------------------------------------------
# 3. GITHUB ENVIRONMENTS (STAGING & PRODUCTION)
# -----------------------------------------------------------------------------

# Infra Repo Environments
resource "github_repository_environment" "infra_staging" {
  repository  = local.repo_infra
  environment = "staging"
}

resource "github_repository_environment" "infra_production" {
  repository  = local.repo_infra
  environment = "production"

  # Production requires manual reviewer approval before deployment
  reviewers {
    users = [data.github_user.current.id]
  }
}

# App Repo Environments
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
}

# -----------------------------------------------------------------------------
# 4. ENVIRONMENT-SCOPED VARIABLES (AWS_ROLE_ARN AUTO-SELECTION)
# -----------------------------------------------------------------------------

# Infra Repo Environment Variables
resource "github_actions_environment_variable" "infra_staging_role" {
  repository    = local.repo_infra
  environment   = github_repository_environment.infra_staging.environment
  variable_name = "AWS_ROLE_ARN"
  value         = aws_iam_role.staging.arn
}

resource "github_actions_environment_variable" "infra_production_role" {
  repository    = local.repo_infra
  environment   = github_repository_environment.infra_production.environment
  variable_name = "AWS_ROLE_ARN"
  value         = aws_iam_role.production.arn
}

# App Repo Environment Variables
resource "github_actions_environment_variable" "app_staging_role" {
  repository    = local.repo_app
  environment   = github_repository_environment.app_staging.environment
  variable_name = "AWS_ROLE_ARN"
  value         = aws_iam_role.staging.arn
}

resource "github_actions_environment_variable" "app_production_role" {
  repository    = local.repo_app
  environment   = github_repository_environment.app_production.environment
  variable_name = "AWS_ROLE_ARN"
  value         = aws_iam_role.production.arn
}

# -----------------------------------------------------------------------------
# 5. GLOBAL REPOSITORY VARIABLES
# -----------------------------------------------------------------------------

# App Repo Variables
resource "github_actions_variable" "app_aws_region" {
  repository    = local.repo_app
  variable_name = "AWS_REGION"
  value         = local.aws_region
}

# Infra Repo Variables
resource "github_actions_variable" "infra_aws_region" {
  repository    = local.repo_infra
  variable_name = "AWS_REGION"
  value         = local.aws_region
}

resource "github_actions_variable" "infra_state_bucket" {
  repository    = local.repo_infra
  variable_name = "TF_STATE_BUCKET"
  value         = aws_s3_bucket.tf_state.bucket
}

# -----------------------------------------------------------------------------
# 6. GITHUB BRANCH PROTECTION RULESETS
# -----------------------------------------------------------------------------

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
      require_last_push_approval      = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true
      required_check {
        context = "lint-and-typecheck"
      }
      required_check {
        context = "test"
      }
    }
  }
}

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
      require_last_push_approval      = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true
      required_check {
        context = "Terraform Plan (staging)"
      }
      required_check {
        context = "Terraform Plan (production)"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# OUTPUTS
# -----------------------------------------------------------------------------

output "tf_state_bucket_name" {
  description = "The name of the S3 bucket configured for Terraform native state locking"
  value       = aws_s3_bucket.tf_state.bucket
}

output "staging_role_arn" {
  description = "IAM Role ARN for Staging environment workflows"
  value       = aws_iam_role.staging.arn
}

output "production_role_arn" {
  description = "IAM Role ARN for Production environment workflows"
  value       = aws_iam_role.production.arn
}
