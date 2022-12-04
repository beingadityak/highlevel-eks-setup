##########################################################
#############   Local variable definition   ##############
##########################################################

locals {
  cluster_name   = "assignment-eks-cluster"
  vpc_name       = "assignment-vpc"
  vpc_cidr_range = "10.0.0.0/16"

  ### EKS node group specific locals
  node_group_list = flatten([
    for pool_key, pool in var.node_group_map : {
      name            = pool_key
      use_name_prefix = true
      cluster_version = "1.24"

      subnet_ids                 = module.vpc.private_subnets
      vpc_security_group_ids     = [aws_security_group.additional.id]
      create_security_group      = true
      security_group_tags        = var.resource_tags
      create_iam_role            = true
      iam_role_description       = "EKS managed node group ${pool_key} role"
      iam_role_attach_cni_policy = true
      iam_role_tags              = var.resource_tags

      capacity_type  = pool.capacity_type
      instance_types = pool.instance_types
      desired_size   = pool.desired_size
      max_size       = pool.max_size
      min_size       = pool.min_size
      disk_size      = pool.disk_size

      pre_bootstrap_user_data = <<-EOT
      #!/bin/bash
      set -ex
      cat <<-EOF > /etc/profile.d/bootstrap.sh
      export CONTAINER_RUNTIME="containerd"
      ### Following settings are only useful if ami-id is specified in launch-template
      # export USE_MAX_PODS=false
      # export KUBELET_EXTRA_ARGS="--max-pods=110"
      EOF
      # Source extra environment variables in bootstrap script
      sed -i '/^set -o errexit/a\\nsource /etc/profile.d/bootstrap.sh' /etc/eks/bootstrap.sh
      EOT

      labels = pool.labels
      tags   = var.resource_tags

      update_config                   = pool.update_config
      enable_monitoring               = true
      create_launch_template          = pool.create_launch_template
      launch_template_name            = "${pool_key}--eks-node-group"
      launch_template_use_name_prefix = true

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = pool.disk_size
            volume_type           = "gp2"
            delete_on_termination = true
          }
        }
      }
    }
  ])
}

##########################################################
#############      VPC Definition      ###################
##########################################################

module "vpc" {
  source               = "terraform-aws-modules/vpc/aws"
  version              = "3.18.1"
  name                 = local.vpc_name
  cidr                 = local.vpc_cidr_range
  azs                  = data.aws_availability_zones.azs.names
  public_subnets       = [cidrsubnet(local.vpc_cidr_range, 8, 1), cidrsubnet(local.vpc_cidr_range, 8, 2), cidrsubnet(local.vpc_cidr_range, 8, 3)]
  private_subnets      = [cidrsubnet(local.vpc_cidr_range, 8, 4), cidrsubnet(local.vpc_cidr_range, 8, 5), cidrsubnet(local.vpc_cidr_range, 8, 6)]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  tags = var.resource_tags

  public_subnet_tags = {
    "Name" = "assignment-public-subnet"
  }

  private_subnet_tags = {
    "Name" = "assignment-private-subnet"
  }

  vpc_tags = {
    "Name" = local.vpc_name
  }
}


##########################################################
#############  EKS Cluster Definition  ###################
##########################################################

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "18.31.2"
  cluster_name    = local.cluster_name
  cluster_version = "1.24"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = concat(module.vpc.public_subnets, module.vpc.private_subnets)

  create_cluster_security_group        = true
  cluster_endpoint_private_access      = false
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

  enable_irsa = true

  manage_aws_auth_configmap = true
  aws_auth_users = [
    {
      userarn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/k8s-user"
      username = "k8s-user"
      groups   = ["system:masters"]
    }
  ]

  cluster_addons = {
    coredns = {
      resolve_conflicts = "OVERWRITE"
    }
    kube-proxy = {}
    vpc-cni = {
      resolve_conflicts = "OVERWRITE"
    }
  }

  cluster_enabled_log_types              = []
  cloudwatch_log_group_retention_in_days = 0

  eks_managed_node_groups = {
    for pool in local.node_group_list : "${pool.name}" => pool
  }

  node_security_group_additional_rules = {
    ingress_nginx_http = {
      description              = "ALB SG to ingress-nginx service"
      protocol                 = "tcp"
      from_port                = 80
      to_port                  = 80
      type                     = "ingress"
      source_security_group_id = aws_security_group.alb-ingress-sg.id
    }
    ingress_nginx_healthcheck = {
      description              = "ALB SG to ingress-nginx healthcheck"
      protocol                 = "tcp"
      from_port                = 10254
      to_port                  = 10254
      type                     = "ingress"
      source_security_group_id = aws_security_group.alb-ingress-sg.id
    }
    ingress_aws_lb_controller_webhook = {
      description                   = "Cluster API to aws-lb-controller-webhook"
      protocol                      = "tcp"
      from_port                     = 9443
      to_port                       = 9443
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  tags = var.resource_tags
}

resource "aws_security_group" "additional" {
  name_prefix = "${local.cluster_name}-additional-eks-node-group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
    cidr_blocks = [
      "10.0.0.0/8"
    ]
  }

  tags = var.resource_tags
}

resource "aws_security_group" "alb-ingress-sg" {
  name        = "${local.cluster_name}--alb-ingress-sg"
  description = "Accepts ingress traffic from Cloudflare"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "All traffic"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"

    cidr_blocks = [
      "0.0.0.0/0"
    ]

  }

  egress {
    description      = "LB all egress"
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    cidr_blocks      = []
    description      = "ALB to EKS nodes all TCP"
    from_port        = 0
    to_port          = 65535
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    protocol         = "tcp"
    security_groups = [
      module.eks.node_security_group_id
    ]
    self = false
  }

  tags = {
    Name = "${local.cluster_name}--alb-ingress-sg"
  }
}