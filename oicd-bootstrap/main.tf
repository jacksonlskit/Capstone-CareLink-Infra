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
  repo_app     = "Capstone-CareLink-App" # Set to Capstone-CareLink-Health if using that name
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
# 1. AWS IAM ROLES (OIDC TRUST POLICIES)
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
              "repo:${local.github_owner}*${local.repo_app}*:*",
              "repo:${local.github_owner}*${local.repo_infra}*:*"
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

# Role 2: SA Role (Terraform planning and read operations)
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
              "repo:${local.github_owner}/${local.repo_infra}:*",
              "repo:${local.github_owner}/${local.repo_app}:*"
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "sa_readonly" {
  role       = aws_iam_role.sa.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
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
              "repo:${local.github_owner}/${local.repo_infra}:*",
              "repo:${local.github_owner}/${local.repo_app}:*"
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
# 2. GITHUB ENVIRONMENTS (APP REPO)
# -----------------------------------------------------------------------------

resource "github_repository_environment" "staging" {
  repository  = local.repo_app
  environment = "staging"
}

resource "github_repository_environment" "production" {
  repository  = local.repo_app
  environment = "production"

  reviewers {
    users = [data.github_user.current.id]
  }
}

# -----------------------------------------------------------------------------
# 3. GLOBAL REPOSITORY VARIABLES (AVAILABLE TO ALL ACTIONS)
# -----------------------------------------------------------------------------

# Variables for App Repository
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

# Variables for Infra Repository
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

# -----------------------------------------------------------------------------
# 4. GITHUB BRANCH PROTECTION RULESETS
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
        context = "terraform-plan"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# OUTPUTS
# -----------------------------------------------------------------------------

output "devops_role_arn" {
  value = aws_iam_role.devops.arn
}

output "sa_role_arn" {
  value = aws_iam_role.sa.arn
}

output "sre_role_arn" {
  value = aws_iam_role.sre.arn
}
