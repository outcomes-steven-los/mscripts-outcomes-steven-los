terraform {
  required_version = ">= 0.13"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
    }
    
  }
  backend "s3" {}
}

provider "aws" {
  region = "us-east-1"
}

#############
#####EKS#####
#############
data "aws_ssm_parameter" "ami" {
  name = var.eks_ami_namespace
}



resource "aws_launch_template" "eks_launch_template" {
  #image_id = "ami-051de2e7ef084cafa"
  image_id = data.aws_ssm_parameter.ami.value
  key_name = var.ec2_key_pairs
  #instance_type = "t3.medium"
  instance_type = "m5.xlarge"
  vpc_security_group_ids = var.mx_management_sg_ids

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 100
      volume_type = "gp3"
    }
  }

  user_data = base64encode(<<-EOF
    [settings.kubernetes]
    api-server = "${aws_eks_cluster.mscripts.endpoint}"
    cluster-certificate = "${aws_eks_cluster.mscripts.certificate_authority[0].data}"
    cluster-name = "${aws_eks_cluster.mscripts.name}"
 
    [settings.host-containers.admin]
    enabled = true
    superpowered = false
 
  EOF
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.cluster_name}-${var.context}-EKS-MANAGED-NODE"
    }
  }
}

resource "aws_eks_cluster" "mscripts" {
  enabled_cluster_log_types = ["api", "audit"]
  name     = "${var.cluster_name}-${var.context}"
  role_arn = aws_iam_role.cluster.arn
  version  = var.eks_version

  

  vpc_config {
    security_group_ids = [aws_security_group.eks_security_group.id]
    subnet_ids         = var.aws_subnets
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  depends_on = [
    aws_iam_role_policy_attachment.AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.AmazonEKSVPCResourceController,
  ]

  tags = {
    Name        = "${var.cluster_name}-${var.context}/aws_eks_cluster"
    Environment = var.context
  }
}
resource "aws_cloudwatch_log_group" "log_group" {
  # The log group name format is /aws/eks/<cluster-name>/cluster
  # Reference: https://docs.aws.amazon.com/eks/latest/userguide/control-plane-logs.html
  name              = "/aws/eks/${var.cluster_name}-${var.context}/cluster"
  retention_in_days = 400

}
# TODO: assign node groups across azs
resource "aws_eks_node_group" "mscripts" {
  cluster_name    = aws_eks_cluster.mscripts.name
  node_group_name = "${var.cluster_name}-${var.context}"
  node_role_arn   = aws_iam_role.worker.arn
  subnet_ids      = var.aws_subnets
  
  scaling_config {
    desired_size = 3
    max_size     = 5
    min_size     = 1
  }

  launch_template {
   name = aws_launch_template.eks_launch_template.name
   version = aws_launch_template.eks_launch_template.latest_version
  }

  depends_on = [
    aws_iam_role_policy_attachment.AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.workers_autoscaling,
    aws_iam_role_policy_attachment.AmazonSSMManagedInstanceCore,
    aws_iam_role_policy_attachment.AmazonSSMFullAccess,
  ]
}

resource "aws_security_group" "eks_security_group" {
  name        = "${var.cluster_name}_${var.context}_eks_security_group"
  description = "Allow traffic to the EKS cluster"
  vpc_id      = var.aws_vpc_id
  ingress {
    description = "Access From VPC"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name = aws_eks_cluster.mscripts.name
  addon_name   = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  depends_on = [
    aws_iam_role_policy_attachment.Amazon_KMS_Policy_Attachment,
    aws_iam_role_policy_attachment.Amazon_EBS_CSI_DriverPolicy_Attachment,
  ]
}
resource "aws_eks_addon" "addons" {
  for_each = toset(var.eks_addons)

  cluster_name                = aws_eks_cluster.mscripts.name
  addon_name                  = each.key
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.mscripts]
}
