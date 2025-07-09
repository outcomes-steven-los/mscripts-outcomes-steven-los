terraform {
  required_version = ">= 0.13"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.0"
    }
    
  }
  backend "s3" {}
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_db_instance" "rds-server" {
  identifier        = var.identifier
  engine            = "mysql"
  publicly_accessible = false   # <-- NEW: RDS.2 RDS DB Instances should prohibit public access
  monitoring_interval = 60      # <-- NEW: RDS.6 Enhanced monitoring should be configured for RDS DB instances
  monitoring_role_arn = var.enhanced_monitoring_role_arn # <-- NEW: RDS.6 Enhanced monitoring should be configured for RDS DB instances
  backup_retention_period = 7
  instance_class    = var.instance_class
  storage_type      = "gp3"
  allocated_storage = var.allocated_storage
  engine_version    = var.engine_version
  parameter_group_name = var.parameter_group_name
  option_group_name = var.option_group_name
  storage_encrypted = true
  apply_immediately = true
  vpc_security_group_ids = split(",", var.security_group_ids)
  db_subnet_group_name = var.db_subnet_group_name
  skip_final_snapshot = false
  final_snapshot_identifier = "${var.identifier}-final-snapshot"
  allow_major_version_upgrade = true
  auto_minor_version_upgrade = true  # <-- NEW: RDS.13 – Automatic minor version upgrades should be enabled
  username             = "dbadmin"   # <-- NEW: RDS.25 - RDS database instances should use a custom administrator username
  password             = var.password
  iam_database_authentication_enabled = true
  deletion_protection = true
  performance_insights_enabled = true
  performance_insights_kms_key_id = var.performance_insights_kms_key_id
  copy_tags_to_snapshot        = true
  multi_az = true # <-- NEW: RDS.15 - RDS DB clusters should be configured for multiple Availability Zones
  enabled_cloudwatch_logs_exports = ["audit", "error", "general", "slowquery"] # <-- NEW: RDS.9 – RDS DB instances should publish logs to CloudWatch Logs
  
lifecycle {
    create_before_destroy = true
  }
}
