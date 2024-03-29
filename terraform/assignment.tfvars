node_group_map = {
  default = {
    capacity_type  = "ON_DEMAND"
    instance_types = ["m5.large"]
    desired_size   = 3
    max_size       = 5
    min_size       = 3
    disk_size      = 32
    labels = {
      role = "application"
    }
    iam_role_additional_policies = ["arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy", "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"]
    taints                       = []
    create_launch_template       = true
    update_config = {
      max_unavailable_percentage = 50
    }
  }
}

resource_tags = {
  "environment" = "assignment"
}