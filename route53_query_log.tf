provider "aws" {
  region = "us-east-1" # adjust as needed
}

# Step 1: Create CloudWatch Log Group
resource "aws_cloudwatch_log_group" "route53_query_logs" {
  name              = "/route53/query-logs"
  retention_in_days = 90
}

# Step 2: IAM Role for Route 53 to log to CloudWatch
resource "aws_iam_role" "route53_query_logging" {
  name = "Route53QueryLoggingRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "route53.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

# Step 3: IAM Policy to write to CloudWatch Logs
resource "aws_iam_role_policy" "route53_query_logging_policy" {
  name = "Route53QueryLoggingPolicy"
  role = aws_iam_role.route53_query_logging.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      Resource = "${aws_cloudwatch_log_group.route53_query_logs.arn}:*"
    }]
  })
}

# Step 4: Data source to get public zones
data "aws_route53_zones" "public" {
  private_zone = false
}

# Step 5: Enable Query Logging for each public zone
resource "aws_route53_query_log" "this" {
  for_each                 = { for z in data.aws_route53_zones.public.zones : z.id => z }
  zone_id                  = each.key
  cloudwatch_log_group_arn = aws_cloudwatch_log_group.route53_query_logs.arn
  cloudwatch_log_role_arn  = aws_iam_role.route53_query_logging.arn
}
