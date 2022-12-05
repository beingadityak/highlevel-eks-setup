##########################################################
#############   Local variable definition   ##############
##########################################################

locals {
  cluster_name             = "assignment-eks-cluster"
  trimmed_cluster_oidc_url = trim(module.eks.cluster_oidc_issuer_url, "https://")
  vpc_name                 = "assignment-vpc"
  vpc_cidr_range           = "10.0.0.0/16"

  ### EKS node group specific locals
  node_group_list = flatten([
    for pool_key, pool in var.node_group_map : {
      name            = pool_key
      use_name_prefix = true
      cluster_version = "1.24"

      subnet_ids                 = module.vpc.private_subnets
      create_security_group      = true
      security_group_tags        = var.resource_tags
      create_iam_role            = true
      iam_role_description       = "EKS managed node group ${pool_key} role"
      iam_role_attach_cni_policy = true
      iam_role_tags              = var.resource_tags

      iam_role_additional_policies = pool.iam_role_additional_policies

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
    "Name"                   = "assignment-public-subnet"
    "kubernetes.io/role/elb" = "1"
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

data "aws_eks_cluster" "default" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "default" {
  name = module.eks.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.default.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.default.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.default.token
}

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
  aws_auth_users            = [
    {
    userarn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/highlevel-readonly"
    username = "highlevel-readonly"
    groups   = ["	system:authenticated"]
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

resource "aws_ecr_repository" "nodejs_app" {
  name                 = "nodejs-app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.resource_tags
}

################################################################################
# aws-lb-controller IAM role and policies
################################################################################
resource "aws_iam_role" "eks_aws_lb_controller_pod_role" {
  name = "${local.cluster_name}--aws-lb-controller--pod-role"

  assume_role_policy = <<-EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Federated": "${module.eks.oidc_provider_arn}"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
          "StringEquals": {
            "${local.trimmed_cluster_oidc_url}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
          }
        }
      }
    ]
  }
  EOF

  tags = var.resource_tags
}

resource "aws_iam_role_policy" "eks_aws_lb_controller_policy" {
  name = "${local.cluster_name}--aws-lb-controller-policy"
  role = aws_iam_role.eks_aws_lb_controller_pod_role.id

  policy = <<-EOF
  {
      "Version": "2012-10-17",
      "Statement": [
          {
              "Effect": "Allow",
              "Action": [
                  "iam:CreateServiceLinkedRole"
              ],
              "Resource": "*",
              "Condition": {
                  "StringEquals": {
                      "iam:AWSServiceName": "elasticloadbalancing.amazonaws.com"
                  }
              }
          },
          {
              "Effect": "Allow",
              "Action": [
                  "ec2:DescribeAccountAttributes",
                  "ec2:DescribeAddresses",
                  "ec2:DescribeAvailabilityZones",
                  "ec2:DescribeInternetGateways",
                  "ec2:DescribeVpcs",
                  "ec2:DescribeVpcPeeringConnections",
                  "ec2:DescribeSubnets",
                  "ec2:DescribeSecurityGroups",
                  "ec2:DescribeInstances",
                  "ec2:DescribeNetworkInterfaces",
                  "ec2:DescribeTags",
                  "ec2:GetCoipPoolUsage",
                  "ec2:DescribeCoipPools",
                  "elasticloadbalancing:DescribeLoadBalancers",
                  "elasticloadbalancing:DescribeLoadBalancerAttributes",
                  "elasticloadbalancing:DescribeListeners",
                  "elasticloadbalancing:DescribeListenerCertificates",
                  "elasticloadbalancing:DescribeSSLPolicies",
                  "elasticloadbalancing:DescribeRules",
                  "elasticloadbalancing:DescribeTargetGroups",
                  "elasticloadbalancing:DescribeTargetGroupAttributes",
                  "elasticloadbalancing:DescribeTargetHealth",
                  "elasticloadbalancing:DescribeTags"
              ],
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": [
                  "cognito-idp:DescribeUserPoolClient",
                  "acm:ListCertificates",
                  "acm:DescribeCertificate",
                  "iam:ListServerCertificates",
                  "iam:GetServerCertificate",
                  "waf-regional:GetWebACL",
                  "waf-regional:GetWebACLForResource",
                  "waf-regional:AssociateWebACL",
                  "waf-regional:DisassociateWebACL",
                  "wafv2:GetWebACL",
                  "wafv2:GetWebACLForResource",
                  "wafv2:AssociateWebACL",
                  "wafv2:DisassociateWebACL",
                  "shield:GetSubscriptionState",
                  "shield:DescribeProtection",
                  "shield:CreateProtection",
                  "shield:DeleteProtection"
              ],
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": [
                  "ec2:AuthorizeSecurityGroupIngress",
                  "ec2:RevokeSecurityGroupIngress"
              ],
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": [
                  "ec2:CreateSecurityGroup"
              ],
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": [
                  "ec2:CreateTags"
              ],
              "Resource": "arn:aws:ec2:*:*:security-group/*",
              "Condition": {
                  "StringEquals": {
                      "ec2:CreateAction": "CreateSecurityGroup"
                  },
                  "Null": {
                      "aws:RequestTag/elbv2.k8s.aws/cluster": "false"
                  }
              }
          },
          {
              "Effect": "Allow",
              "Action": [
                  "ec2:CreateTags",
                  "ec2:DeleteTags"
              ],
              "Resource": "arn:aws:ec2:*:*:security-group/*",
              "Condition": {
                  "Null": {
                      "aws:RequestTag/elbv2.k8s.aws/cluster": "true",
                      "aws:ResourceTag/elbv2.k8s.aws/cluster": "false"
                  }
              }
          },
          {
              "Effect": "Allow",
              "Action": [
                  "ec2:AuthorizeSecurityGroupIngress",
                  "ec2:RevokeSecurityGroupIngress",
                  "ec2:DeleteSecurityGroup"
              ],
              "Resource": "*",
              "Condition": {
                  "Null": {
                      "aws:ResourceTag/elbv2.k8s.aws/cluster": "false"
                  }
              }
          },
          {
              "Effect": "Allow",
              "Action": [
                  "elasticloadbalancing:CreateLoadBalancer",
                  "elasticloadbalancing:CreateTargetGroup"
              ],
              "Resource": "*",
              "Condition": {
                  "Null": {
                      "aws:RequestTag/elbv2.k8s.aws/cluster": "false"
                  }
              }
          },
          {
              "Effect": "Allow",
              "Action": [
                  "elasticloadbalancing:CreateListener",
                  "elasticloadbalancing:DeleteListener",
                  "elasticloadbalancing:CreateRule",
                  "elasticloadbalancing:DeleteRule"
              ],
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": [
                  "elasticloadbalancing:AddTags",
                  "elasticloadbalancing:RemoveTags"
              ],
              "Resource": [
                  "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
                  "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
                  "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
              ],
              "Condition": {
                  "Null": {
                      "aws:RequestTag/elbv2.k8s.aws/cluster": "true",
                      "aws:ResourceTag/elbv2.k8s.aws/cluster": "false"
                  }
              }
          },
          {
              "Effect": "Allow",
              "Action": [
                  "elasticloadbalancing:AddTags",
                  "elasticloadbalancing:RemoveTags"
              ],
              "Resource": [
                  "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
                  "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
                  "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
                  "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*"
              ]
          },
          {
              "Effect": "Allow",
              "Action": [
                  "elasticloadbalancing:ModifyLoadBalancerAttributes",
                  "elasticloadbalancing:SetIpAddressType",
                  "elasticloadbalancing:SetSecurityGroups",
                  "elasticloadbalancing:SetSubnets",
                  "elasticloadbalancing:DeleteLoadBalancer",
                  "elasticloadbalancing:ModifyTargetGroup",
                  "elasticloadbalancing:ModifyTargetGroupAttributes",
                  "elasticloadbalancing:DeleteTargetGroup"
              ],
              "Resource": "*",
              "Condition": {
                  "Null": {
                      "aws:ResourceTag/elbv2.k8s.aws/cluster": "false"
                  }
              }
          },
          {
              "Effect": "Allow",
              "Action": [
                  "elasticloadbalancing:RegisterTargets",
                  "elasticloadbalancing:DeregisterTargets"
              ],
              "Resource": "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
          },
          {
              "Effect": "Allow",
              "Action": [
                  "elasticloadbalancing:SetWebAcl",
                  "elasticloadbalancing:ModifyListener",
                  "elasticloadbalancing:AddListenerCertificates",
                  "elasticloadbalancing:RemoveListenerCertificates",
                  "elasticloadbalancing:ModifyRule"
              ],
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": [
                  "s3:PutObject"
              ],
              "Resource": "*"
          }
      ]
  }
  EOF
}

resource "aws_iam_role" "eks_keda_operator_role" {
  name = "${local.cluster_name}--keda--operator-role"

  assume_role_policy = <<-EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Federated": "${module.eks.oidc_provider_arn}"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
          "StringEquals": {
            "${local.trimmed_cluster_oidc_url}:aud": "sts.amazonaws.com",
            "${local.trimmed_cluster_oidc_url}:sub": "system:serviceaccount:keda:keda-operator"
          }
        }
      }
    ]
  }
  EOF

  tags = var.resource_tags
}

resource "aws_iam_role_policy" "eks_keda_policy" {
  name = "${local.cluster_name}--keda-policy"
  role = aws_iam_role.eks_keda_operator_role.id

  policy = <<-EOF
  {
      "Version": "2012-10-17",
      "Statement": [
          {
              "Effect": "Allow",
              "Action": [
                  "autoscaling:Describe*",
                  "cloudwatch:Describe*",
                  "cloudwatch:Get*",
                  "cloudwatch:List*",
                  "logs:Get*",
                  "logs:List*",
                  "logs:StartQuery",
                  "logs:StopQuery",
                  "logs:Describe*",
                  "logs:TestMetricFilter",
                  "logs:FilterLogEvents",
                  "oam:ListSinks",
                  "sns:Get*",
                  "sns:List*"
              ],
              "Resource": "*"
          },
          {
            "Effect": "Allow",
            "Action": [
                "oam:ListAttachedLinks"
            ],
            "Resource": "arn:aws:oam:*:*:sink/*"
          }
      ]
  }
  EOF
}