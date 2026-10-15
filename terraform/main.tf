terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock_key"
  secret_key                  = "mock_secret"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    sqs      = "http://localhost:4566"
    s3       = "http://localhost:4566"
    dynamodb = "http://localhost:4566"
    kms      = "http://localhost:4566"
    iam      = "http://localhost:4566"
  }
}

# --- KMS KEY ---
resource "aws_kms_key" "pipeline_key" {
  description             = "KMS Key for SQS encryption"
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyExternal"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action   = "kms:*"
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "aws:PrincipalAccount" = "000000000000"
          }
        }
      }
    ]
  })
}

# --- SQS & DLQ ---
resource "aws_sqs_queue" "transactions_dlq" {
  name                      = "transactions-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "transactions_queue" {
  name = "transactions-queue"

  visibility_timeout_seconds = 10

  kms_master_key_id                 = aws_kms_key.pipeline_key.id
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = "arn:aws:sqs:us-east-1:123456789012:transactions-dlq"
    maxReceiveCount     = 3
  })
}

# --- S3 STORAGE ---
resource "aws_s3_bucket" "payload_bucket" {
  bucket = "corporate-transactions-raw-payloads"

  acl = "private"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}


# --- DYNAMODB ---
resource "aws_dynamodb_table" "transactions" {
  name         = "transactions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "transaction_id"

  attribute {
    name = "transaction_id"
    type = "S"
  }
}

# --- IAM ROLE & POLICIES ---
resource "aws_iam_role" "worker_role" {
  name = "pipeline-worker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "worker_policy" {
  name = "pipeline-worker-permissive-policy"
  role = aws_iam_role.worker_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      }
    ]
  })
}

# // ¿Qué problemas tiene esta implementación?
#
# resource "aws_s3_bucket_acl" "payload_public" {
#   bucket = aws_s3_bucket.payload_bucket.id
#   acl    = "public-read"
# }
#
# resource "aws_sqs_queue" "transactions_queue_v2" {
#   name                       = "transactions-queue"
#   visibility_timeout_seconds = 0
#   message_retention_seconds  = 60
# }
#
# resource "aws_iam_user" "worker" {
#   name = "worker"
# }
#
# resource "aws_iam_access_key" "worker" {
#   user = aws_iam_user.worker.name
# }
#
# output "worker_secret" {
#   value = aws_iam_access_key.worker.secret
# }
