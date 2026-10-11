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
  region = "us-east-1"
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

data "aws_iam_openid_connect_provider" "github" {
  url = local.oidc_url
}

# -----------------------------------------------------------------------------
# 1. S3 BACKEND STORAGE (OPTION 1: NATIVE S3 LOCKFILE - NO DYNAMODB)
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "tf_state" {
  bucket = "carelink-terraform-state-${local.aws_region}-${data.aws_caller_identity.current.account_id}"

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
# 2. AWS IAM ROLES (OIDC TRUST POLICIES WITH WILDCARD CLAIMS)
# -----------------------------------------------------------------------------

# Role 1: DevOps Role (Container build & ECR push)
resource "aws_iam_role" "devops" {
  name = "carelink-github-devops-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              "repo:${local.github_owner}*${local.repo_infra}*:*",
              "repo:${local.github_owner}*${local.repo_app}*:*"
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "devops_ecr" {
  role       = aws_iam_role.devops.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# Role 2: SA Role (Terraform planning and full resource provisioning)
resource "aws_iam_role" "sa" {
  name = "carelink-github-sa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              "repo:${local.github_owner}*${local.repo_infra}*:*",
              "repo:${local.github_owner}*${local.repo_app}*:*"
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "sa_admin" {
  role       = aws_iam_role.sa.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Role 3: SRE Role (Observability and CloudWatch operations)
resource "aws_iam_role" "sre" {
  name = "carelink-github-sre-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              "repo:${local.github_owner}*${local.repo_infra}*:*",
              "repo:${local.github_owner}*${local.repo_app}*:*"
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "sre_cloudwatch" {
  role       = aws_iam_role.sre.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
}

# -----------------------------------------------------------------------------
# 3. GITHUB ENVIRONMENTS (STAGING & PRODUCTION FOR BOTH REPOSITORIES)
# -----------------------------------------------------------------------------

# Infra Repo Environments
resource "github_repository_environment" "infra_staging" {
  repository  = local.repo_infra
  environment = "staging"
}

resource "github_repository_environment" "infra_production" {
  repository  = local.repo_infra
  environment = "production"

  # Production requires manual reviewer approval before apply
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
# 4. GLOBAL REPOSITORY VARIABLES
# -----------------------------------------------------------------------------

# App Repo Variables
resource "github_actions_variable" "app_aws_region" {
  repository    = local.repo_app
  variable_name = "AWS_REGION"
  value         = local.aws_region
}

resource "github_actions_variable" "app_devops_role" {
  repository    = local.repo_app
  variable_name = "DEVOPS_ROLE_ARN"
  value         = aws_iam_role.devops.arn
}

resource "github_actions_variable" "app_sa_role" {
  repository    = local.repo_app
  variable_name = "SA_ROLE_ARN"
  value         = aws_iam_role.sa.arn
}

resource "github_actions_variable" "app_sre_role" {
  repository    = local.repo_app
  variable_name = "SRE_ROLE_ARN"
  value         = aws_iam_role.sre.arn
}

# Infra Repo Variables
resource "github_actions_variable" "infra_aws_region" {
  repository    = local.repo_infra
  variable_name = "AWS_REGION"
  value         = local.aws_region
}

resource "github_actions_variable" "infra_devops_role" {
  repository    = local.repo_infra
  variable_name = "DEVOPS_ROLE_ARN"
  value         = aws_iam_role.devops.arn
}

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

# State Bucket Name Variable for Workflows
resource "github_actions_variable" "infra_state_bucket" {
  repository    = local.repo_infra
  variable_name = "TF_STATE_BUCKET"
  value         = aws_s3_bucket.tf_state.bucket
}

# -----------------------------------------------------------------------------
# 5. GITHUB BRANCH PROTECTION RULESETS
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
  value = aws_s3_bucket.tf_state.bucket
}

output "devops_role_arn" {
  value = aws_iam_role.devops.arn
}

output "sa_role_arn" {
  value = aws_iam_role.sa.arn
}

output "sre_role_arn" {
  value = aws_iam_role.sre.arn
}
