
terraform {
  required_version = ">= 0.13"
  required_providers {
    aws = {
      source = "hashicorp/aws"
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

resource "aws_eks_cluster" "mscripts" {
  name     = "${var.cluster_name}-${var.context}"
  role_arn = aws_iam_role.cluster.arn
  version  = var.eks_version

  vpc_config {
    security_group_ids = [aws_security_group.eks_security_group.id]
    subnet_ids         = var.aws_subnets
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

data "aws_ssm_parameter" "ami" {
  name = var.eks_ami_namespace
}

resource "aws_launch_template" "eks_launch_template" {
  name          = "${var.cluster_name}-${var.context}-EKS-LT"
  description   = "Launch Template for ${var.cluster_name}-${var.context} EKS Cluster Nodes"
  image_id      = data.aws_ssm_parameter.ami.value
  key_name      = var.ec2_key_pairs
  instance_type = "m5.xlarge"
  vpc_security_group_ids = [
    var.mx_management_sg_ids,
    aws_eks_cluster.mscripts.vpc_config[0].cluster_security_group_id
  ]

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 50
      volume_type = "gp3"
    }
  }

  user_data = base64encode(<<-EOF
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="//"

    --//
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      cluster:
        name: ${aws_eks_cluster.mscripts.name}
        apiServerEndpoint: ${aws_eks_cluster.mscripts.endpoint}
        certificateAuthority: ${aws_eks_cluster.mscripts.certificate_authority[0].data}
        cidr: ${aws_eks_cluster.mscripts.kubernetes_network_config[0].service_ipv4_cidr}
      # kubelet:
      #   config:
      #     maxPods: 58
      #     clusterDNS:
      #     - 172.20.0.10
      #   flags:
      #   - "--node-labels=eks.amazonaws.com/nodegroup-image=${data.aws_ssm_parameter.ami.value},eks.amazonaws.com/capacityType=ON_DEMAND,eks.amazonaws.com/nodegroup=${var.cluster_name}-${var.context}"

    --//
    Content-Type: text/cloud-config; charset="us-ascii"

    #cloud-config
    write_files:
      - path: /etc/systemd/system/docker-cache-clear.service
        content: |
          [Unit]
          Description=Clear Docker Cache

          [Service]
          Type=oneshot
          ExecStart=/usr/bin/docker system prune -af
      - path: /etc/systemd/system/docker-cache-clear.timer
        content: |
          [Unit]
          Description=Run Docker Cache Clear daily

          [Timer]
          OnCalendar=*-*-* 18:30:00
          Persistent=true

          [Install]
          WantedBy=timers.target
    runcmd:
      - systemctl daemon-reload
      - systemctl enable docker-cache-clear.timer
      - systemctl start docker-cache-clear.timer
    --//
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.cluster_name}-${var.context}-EKS-TF-Managed-Node"
    }
  }
}

# TODO: assign node groups across azs
resource "aws_eks_node_group" "mscripts" {
  cluster_name    = aws_eks_cluster.mscripts.name
  node_group_name = "${var.cluster_name}-${var.context}"
  node_role_arn   = aws_iam_role.worker.arn
  subnet_ids      = var.aws_subnets

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  launch_template {
    name    = aws_launch_template.eks_launch_template.name
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

resource "aws_security_group" "efs_security_group" {
  name        = "${var.cluster_name}_${var.context}_eks_efs_sg"
  description = "Allow traffic to the EFS"
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

resource "aws_efs_file_system" "jenkins_efs" {
  creation_token = "adc-jenkins"
  encrypted      = true
  protection {
    replication_overwrite = "ENABLED"
  }
  tags = {
    Name = "jenkins-prod-eks-efs"
  }
}

resource "aws_efs_mount_target" "jenkins_mount_target" {
  count           = length(var.aws_subnets)
  file_system_id  = aws_efs_file_system.jenkins_efs.id
  subnet_id       = var.aws_subnets[count.index]
  security_groups = [aws_security_group.efs_security_group.id]
}

resource "aws_efs_access_point" "jenkins_access_point" {
  file_system_id = aws_efs_file_system.jenkins_efs.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/jenkins"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "777"
    }
  }
}

resource "aws_efs_backup_policy" "policy" {
  file_system_id = aws_efs_file_system.jenkins_efs.id

  backup_policy {
    status = "ENABLED"
  }
}

resource "aws_eks_addon" "efs_csi_driver" {
  cluster_name             = aws_eks_cluster.mscripts.name
  addon_name               = "aws-efs-csi-driver"
  service_account_role_arn = aws_iam_role.efs_csi.arn

  depends_on = [
    aws_eks_node_group.mscripts,
    aws_iam_role_policy_attachment.Amazon_EFS_KMS_Policy_Attachment
  ]
}

/* resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = aws_eks_cluster.mscripts.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  depends_on = [
    aws_iam_role_policy_attachment.Amazon_EBS_KMS_Policy_Attachment
  ]
} */

resource "aws_eks_addon" "addons" {
  for_each = toset(var.eks_addons)

  cluster_name                = aws_eks_cluster.mscripts.name
  addon_name                  = each.key
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.mscripts]
}
