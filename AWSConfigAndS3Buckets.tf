provider "aws" {
  region = "us-east-1"
}

# ------------------------------
# ACCESS LOGGING BUCKET
# ------------------------------
resource "aws_s3_bucket" "access_logs" {
  bucket        = "mscriptsproduction-config-logs-access-logs"
  force_destroy = true
}

resource "aws_s3_bucket_acl" "access_logs_acl" {
  bucket = aws_s3_bucket.access_logs.id
  acl    = "log-delivery-write"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs_encryption" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs_lifecycle" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    id     = "ExpireAccessLogs"
    status = "Enabled"
    expiration {
      days = 791
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs_policy" {
  bucket = aws_s3_bucket.access_logs.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "AllowS3LoggingServiceWrite",
        Effect    = "Allow",
        Principal = {
          Service = "logging.s3.amazonaws.com"
        },
        Action = "s3:PutObject",
        Resource = "arn:aws:s3:::mscriptsproduction-config-logs-access-logs/AWSLogs/013856208911/*",
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid       = "AllowS3LoggingServiceAclCheck",
        Effect    = "Allow",
        Principal = {
          Service = "logging.s3.amazonaws.com"
        },
        Action   = "s3:GetBucketAcl",
        Resource = "arn:aws:s3:::mscriptsproduction-config-logs-access-logs"
      }
    ]
  })
}

resource "aws_s3_bucket_versioning" "access_logs_versioning" {
  bucket = aws_s3_bucket.access_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs_block_public" {
  bucket = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------
# CONFIG BUCKET
# ------------------------------
resource "aws_s3_bucket" "config_logs" {
  bucket        = "mscriptsproduction-config-logs-central"
  force_destroy = true
}

resource "aws_s3_bucket_acl" "config_logs_acl" {
  bucket = aws_s3_bucket.config_logs.id
  acl    = "private"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config_logs_encryption" {
  bucket = aws_s3_bucket.config_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "config_logs_lifecycle" {
  bucket = aws_s3_bucket.config_logs.id
  rule {
    id     = "ExpireConfigLogs"
    status = "Enabled"
    expiration {
      days = 396
    }
  }
}

resource "aws_s3_bucket_logging" "config_logs_logging" {
  bucket        = aws_s3_bucket.config_logs.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "AWSConfigBucketLogs/"
}

resource "aws_s3_bucket_policy" "config_logs_policy" {
  bucket = aws_s3_bucket.config_logs.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "AWSConfigBucketPermissionsCheck",
        Effect    = "Allow",
        Principal = {
          Service = "config.amazonaws.com"
        },
        Action   = "s3:GetBucketAcl",
        Resource = "arn:aws:s3:::mscriptsproduction-config-logs-central"
      },
      {
        Sid       = "AWSConfigBucketDelivery",
        Effect    = "Allow",
        Principal = {
          Service = "config.amazonaws.com"
        },
        Action   = "s3:PutObject",
        Resource = "arn:aws:s3:::mscriptsproduction-config-logs-central/AWSLogs/013856208911/*",
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_versioning" "config_logs_versioning" {
  bucket = aws_s3_bucket.config_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "config_logs_block_public" {
  bucket = aws_s3_bucket.config_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------
# AWS CONFIG SETUP
# ------------------------------
resource "aws_iam_role" "config_service_role" {
  name = "AWSConfigServiceRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "config.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "config_service_policy" {
  role       = aws_iam_role.config_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSConfigRole"
}

resource "aws_config_configuration_recorder" "config_recorder" {
  name     = "default"
  role_arn = aws_iam_role.config_service_role.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "config_delivery" {
  name           = "default"
  s3_bucket_name = aws_s3_bucket.config_logs.bucket
  s3_key_prefix  = "AWSLogs/013856208911/config/"

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.config_recorder]
}

resource "aws_config_configuration_recorder_status" "recorder_status" {
  name       = aws_config_configuration_recorder.config_recorder.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.config_delivery]
}
