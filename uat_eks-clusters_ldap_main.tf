terraform {
  required_version = ">= 0.13"
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    helm = {
      source = "hashicorp/helm"
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
  name                   = "${var.cluster_name}-${var.context}-EKS-LT"
  description            = "Launch Template for ${var.cluster_name}-${var.context} EKS Cluster Nodes"
  image_id               = data.aws_ssm_parameter.ami.value
  key_name               = var.ec2_key_pairs
  instance_type          = "t3a.xlarge"
  vpc_security_group_ids = [
    var.mx_management_sg_id,
    var.mx_ldap_sg_id,
    aws_eks_cluster.mscripts.vpc_config[0].cluster_security_group_id
  ]

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 20
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

    --//--
  EOF
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name        = "${var.cluster_name}-${var.context}-eksManagedNode"
      ManagedBy   = "Terraform"
      Apmid       = "27533"
      Costcenter  = "8290000016"
      Environment = var.context
      OS_Version  = "AmazonLinux2"
    }
  }
}

resource "aws_eks_cluster" "mscripts" {
  name     = "${var.cluster_name}-${var.context}"
  role_arn = aws_iam_role.cluster.arn
  version  = var.eks_version

  vpc_config {
    security_group_ids = [aws_security_group.eks_security_group.id]
    subnet_ids         = var.aws_subnets
  }

  depends_on = [
    aws_iam_role_policy_attachment.AmazonEKSCluster_ManagedPolicies,
  ]

  tags = {
    Name        = "${var.cluster_name}-${var.context}/aws_eks_cluster"
    Environment = var.context
    ManagedBy   = "Terraform"
  }
}


# TODO: assign node groups across azs
resource "aws_eks_node_group" "mscripts" {
  cluster_name    = aws_eks_cluster.mscripts.name
  node_group_name = "${var.cluster_name}-${var.context}"
  node_role_arn   = aws_iam_role.worker.arn
  subnet_ids      = var.aws_subnets

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  launch_template {
    name    = aws_launch_template.eks_launch_template.name
    version = aws_launch_template.eks_launch_template.latest_version
  }

  depends_on = [
    aws_iam_role_policy_attachment.AmazonEKSWorkerNode_ManagedPolicies,
  ]
}

resource "aws_security_group" "eks_security_group" {
  name        = "SG-${var.cluster_name}-${var.context}-eks"
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
    from_port   = 2049
    to_port     = 2049
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

resource "aws_efs_file_system" "efs_ldap" {
  count          = length(var.efs_root_directories)
  creation_token = "${element(var.efs_root_directories, count.index)}-ldap"
  encrypted      = true
  tags = {
    Name = "eks-${var.cluster_name}-${element(var.efs_root_directories, count.index)}-efs"
  }
  protection {
    replication_overwrite = "ENABLED"
  }
}

locals {
  efs_mount_targets = flatten([
    for efs in aws_efs_file_system.efs_ldap : [
      for subnet in var.aws_subnets : {
        file_system_id = efs.id
        subnet_id      = subnet
      }
    ]
  ])
}

resource "aws_efs_mount_target" "ldap_mounttarget" {
  for_each = { for idx, mt in local.efs_mount_targets : idx => mt }

  file_system_id  = each.value.file_system_id
  subnet_id       = each.value.subnet_id
  security_groups = [aws_security_group.efs_security_group.id]
}

# access point for each EFS file system if needed
#resource "aws_efs_access_point" "ldap_access_point" {
#  count          = length(aws_efs_file_system.efs_ldap) # One access point for each EFS
#  file_system_id = aws_efs_file_system.efs_ldap[count.index].id
#  posix_user {
#    gid = 1000
#    uid = 1000
#  }
#  root_directory {
#    path = "/opt/opendj"
#    creation_info {
#      owner_gid   = 1000
#      owner_uid   = 1000
#      permissions = "755"
#    }
#  }
#  tags = {
#    Name = "ldap-${element(var.efs_root_directories, count.index)}-access-point"
#  }
#}

resource "aws_efs_backup_policy" "backup_policy" {
  for_each      = { for idx, fs in aws_efs_file_system.efs_ldap : idx => fs }
  file_system_id = each.value.id
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
    aws_iam_role_policy_attachment.AmazonEFS_ManagedPolicies,
    aws_iam_role_policy_attachment.Amazon_EFS_KMS_Policy_Attachment,
  ]
}

resource "aws_security_group" "load_balancer_security_group" {
  name        = "${var.cluster_name}_${var.context}_lb_frontend_sg"
  description = "[k8s] Shared Security Group for Frontend Load Balancer"
  vpc_id      = var.aws_vpc_id
  ingress {
    from_port   = 389
    to_port     = 389
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }
  ingress {
    from_port   = 636
    to_port     = 636
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    "service.k8s.aws/resource"   = "TerrafornManagedLBSecurityGroup"
    "elbv2.k8s.aws/cluster"      = "${var.cluster_name}-${var.context}"
    "shared"                     = "true"
  }
}

resource "aws_eks_addon" "addons" {
  for_each = toset(var.eks_addons)
  cluster_name                = aws_eks_cluster.mscripts.name
  addon_name                  = each.key
  resolve_conflicts_on_update = "PRESERVE"
  depends_on = [aws_eks_node_group.mscripts]
}

# kubernetes resources
provider "kubernetes" {
  alias                  = "mscripts-ldap"
  host                   = aws_eks_cluster.mscripts.endpoint
  token                  = data.aws_eks_cluster_auth.mscripts.token
  cluster_ca_certificate = base64decode(aws_eks_cluster.mscripts.certificate_authority[0].data)
  config_path            = "~/.kube/config"
}

data "aws_eks_cluster_auth" "mscripts" {
  name = aws_eks_cluster.mscripts.name
}

#resource "kubernetes_service_account" "aws_load_balancer_controller" {
#  metadata {
#    name      = "aws-load-balancer-controller"
#    namespace = "kube-system"
#    annotations = {
#      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
#    }
#    labels = {
#      "app.kubernetes.io/component" = "controller"
#      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
#    }
#  }
#
#  depends_on = [aws_eks_cluster.mscripts]
#}

provider "helm" {}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.helm_charts["aws-load-balancer-controller"]
  values = [
    <<EOF
clusterName: "${aws_eks_cluster.mscripts.name}"
serviceAccount:
  create: true
  name: aws-load-balancer-controller
  annotations:
    eks.amazonaws.com/role-arn: "${aws_iam_role.alb_controller.arn}"
  labels:
    app.kubernetes.io/component: "controller"
    app.kubernetes.io/name: "aws-load-balancer-controller"
region: "${var.aws_region}"
vpcId: "${aws_eks_cluster.mscripts.vpc_config[0].vpc_id}"
EOF
  ]
}

# resource "helm_release" "karpenter" {
#   name             = "karpenter"
#   namespace        = "karpenter"
#   repository       = "oci://public.ecr.aws/karpenter"
#   chart            = "karpenter"
#   version          = var.helm_charts["karpenter"]
#   create_namespace = true
#   values = [
#     <<EOF
# serviceAccount:
#   create: true
#   name: karpenter
#   annotations:
#     eks.amazonaws.com/role-arn: "${aws_iam_role.karpenter.arn}"
# settings:
#   clusterName: "${aws_eks_cluster.mscripts.name}"
#   #interruptionQueue: "${aws_eks_cluster.mscripts.name}"
# EOF
#   ]
#   depends_on = [
#     aws_iam_role_policy_attachment.AmazonEKSWorkerNode_ManagedPolicies,
#   ]
# }

# resource "kubernetes_manifest" "karpenter_ec2nodeclass" {
#   manifest = {
#     apiVersion = "karpenter.k8s.aws/v1"
#     kind       = "EC2NodeClass"
#     metadata = {
#       name = "al2023"
#       annotations = {
#         "kubernetes.io/description" = "EC2NodeClass for Amazon Linux 2023 nodes with existing Launch Template"
#       }
#     }
#     spec = {
#       role = "${aws_eks_cluster.mscripts.name}-worker"
#       amiFamily = "Custom"
#       amiSelectorTerms = [{
#         tags = {
#           "karpenter.sh/discovery" = "true"
#         }
#       }]
#       subnetSelectorTerms = [{
#         tags = {
#           "karpenter.sh/discovery/${aws_eks_cluster.mscripts.name}" = "true"
#         }
#       }]
#       securityGroupSelectorTerms = [{
#         tags = {
#           "karpenter.sh/discovery/${aws_eks_cluster.mscripts.name}" = "true"
#         }
#       }]
#       blockDeviceMappings = [{
#         deviceName = "/dev/xvda"
#         ebs = {
#           volumeSize = "20Gi"
#           volumeType = "gp3"
#           encrypted  = true
#         }
#       }]
#       tags = {
#         ManagedBy  = "Karpenter"
#         OS_Version = "AmazonLinux2023"
#       }
#       userData = <<EOT
# MIME-Version: 1.0
# Content-Type: multipart/mixed; boundary="//"

# --//
# Content-Type: application/node.eks.aws

# ---
# apiVersion: node.eks.aws/v1alpha1
# kind: NodeConfig
# spec:
#   cluster:
#     name: ${aws_eks_cluster.mscripts.name}
#     apiServerEndpoint: ${aws_eks_cluster.mscripts.endpoint}
#     certificateAuthority: ${aws_eks_cluster.mscripts.certificate_authority[0].data}
#     cidr: ${aws_eks_cluster.mscripts.kubernetes_network_config[0].service_ipv4_cidr}

# --//--
# EOT
#     }
#   }
# }

# resource "kubernetes_manifest" "karpenter_nodepool" {
#   manifest = {
#     apiVersion = "karpenter.sh/v1"
#     kind       = "NodePool"
#     metadata = {
#       name = "default"
#       annotations = {
#         "kubernetes.io/description" = "General purpose NodePool for generic workloads"
#       }
#     }
#     spec = {
#       template = {
#         spec = {
#           requirements = [
#             {
#               key      = "kubernetes.io/arch"
#               operator = "In"
#               values   = ["amd64"]
#             },
#             {
#               key      = "kubernetes.io/os"
#               operator = "In"
#               values   = ["linux"]
#             },
#             {
#               key      = "karpenter.sh/capacity-type"
#               operator = "In"
#               values   = ["on-demand"]
#             },
#             {
#               key      = "node.kubernetes.io/instance-type"
#               operator = "In"
#               values   = ["m5.xlarge"]
#             }
#           ]
#           nodeClassRef = {
#             group = "karpenter.k8s.aws"
#             kind  = "EC2NodeClass"
#             name  = "al2023"
#           }
#         }
#       }
#     }
#   }
# }

# # Tagging resources
# resource "aws_ec2_tag" "karpenter_tags" {
#   for_each    = toset(var.aws_subnets)
#   resource_id = each.value
#   key         = "karpenter.sh/discovery/${aws_eks_cluster.mscripts.name}"
#   value       = "true"
# }
# resource "aws_ec2_tag" "karpenter_sg_management" {
#   resource_id = var.mx_management_sg_id
#   key         = "karpenter.sh/discovery/${aws_eks_cluster.mscripts.name}"
#   value       = "true"
# }
# resource "aws_ec2_tag" "karpenter_sg_ldap" {
#   resource_id = var.mx_ldap_sg_id
#   key         = "karpenter.sh/discovery/${aws_eks_cluster.mscripts.name}"
#   value       = "true"
# }
# resource "aws_ec2_tag" "karpenter_sg_eks" {
#   resource_id = aws_eks_cluster.mscripts.vpc_config[0].cluster_security_group_id
#   key         = "karpenter.sh/discovery/${aws_eks_cluster.mscripts.name}"
#   value       = "true"
# }
