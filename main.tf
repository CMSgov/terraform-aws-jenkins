
locals {
  ebs_volume_name = "${var.prefix}-persistent-data-${var.name}"
}

data "aws_vpc" "vpc" {
  id = var.vpc_id
}

resource "aws_security_group" "ecs_host" {
  name        = "${var.prefix}-ecs-host-${var.name}"
  description = "Allows 8080 traffic"
  vpc_id      = var.vpc_id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = [
      "0.0.0.0/0",
    ]
  }
}

resource "aws_ecs_cluster" "cluster" {
  name = "${var.prefix}-${var.name}"
}

data "aws_ami" "ecs_optimized" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name = "name"
    values = [
      "amzn2-ami-ecs-hvm-*-x86_64-ebs",
    ]
  }
  filter {
    name = "owner-alias"
    values = [
      "amazon",
    ]
  }
}

data "aws_region" "this" {}

data "template_file" "user_data" {
  template = file("${path.module}/templates/user_data.tpl")
  vars = {
    ecs_cluster_name = "${var.prefix}-${var.name}"
    ebs_region       = data.aws_region.this.name
  }
}

resource "aws_iam_role" "ecs_host" {
  name               = "${var.prefix}-ecs-host-${var.name}"
  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": [
          "ec2.amazonaws.com"
        ]
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "ecs_host" {
  name   = "${var.prefix}-ecs-host-${var.name}"
  role   = aws_iam_role.ecs_host.id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeTags",
        "ecs:CreateCluster",
        "ecs:DeregisterContainerInstance",
        "ecs:DiscoverPollEndpoint",
        "ecs:Poll",
        "ecs:RegisterContainerInstance",
        "ecs:StartTelemetrySession",
        "ecs:UpdateContainerInstancesState",
        "ecs:Submit*",
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DetachVolume",
        "ec2:AttachVolume",
        "ec2:CopySnapshot",
        "ec2:DeleteSnapshot",
        "ec2:ModifyVolumeAttribute",
        "ec2:DescribeInstances",
        "ec2:DescribeTags",
        "ec2:DescribeSnapshotAttribute",
        "ec2:CreateTags",
        "ec2:DescribeSnapshots",
        "ec2:DescribeVolumeAttribute",
        "ec2:CreateVolume",
        "ec2:DeleteVolume",
        "ec2:DescribeVolumeStatus",
        "ec2:ModifySnapshotAttribute",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeVolumes",
        "ec2:CreateSnapshot"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "ecs_host" {
  name = "${var.prefix}-ecs-host${var.name}"
  path = "/"
  role = aws_iam_role.ecs_host.name
}


resource "aws_launch_configuration" "ecs_host" {
  name_prefix                 = "${var.prefix}-${var.name}"
  image_id                    = data.aws_ami.ecs_optimized.id
  instance_type               = var.instance_type
  security_groups             = flatten([aws_security_group.ecs_host.id, var.host_security_groups])
  key_name                    = var.host_key_name
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.ecs_host.name
  user_data                   = data.template_file.user_data.rendered
  root_block_device {
    volume_type = "gp2"
    volume_size = 500
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "ecs_host" {
  name                      = "${var.prefix}-${var.name}"
  min_size                  = 1
  max_size                  = 2
  desired_capacity          = 1
  health_check_type         = "EC2"
  health_check_grace_period = 300
  launch_configuration      = aws_launch_configuration.ecs_host.name
  vpc_zone_identifier       = var.auto_scaling_subnets

  lifecycle {
    create_before_destroy = true
  }

  tags = [
    {
      key                 = "Name"
      value               = "${var.prefix}-${var.name}"
      propagate_at_launch = true
    },
  ]
}

resource "aws_iam_role" "ecs_task" {
  name               = "${var.prefix}-ecs-task-${var.name}"
  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": [
          "ecs-tasks.amazonaws.com"
        ]
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

data "template_file" "ecs_task_policy" {
  template = file("${path.module}/templates/ecs-task-policy.json.tpl")
}

resource "aws_iam_role_policy" "ecs_task" {
  name   = "${var.prefix}-ecs-task-${var.name}"
  policy = data.template_file.ecs_task_policy.rendered
  role   = aws_iam_role.ecs_host.id
}

data "template_file" "ecs_task" {
  template = file("${path.module}/templates/ecs-task.json.tpl")
  vars = {
    image           = var.image
    ebs_volume_name = local.ebs_volume_name
  }
}

resource "aws_ebs_volume" "jenkins_home" {
  availability_zone = var.auto_scaling_availability_zone
  size              = var.jenkins_home_size
  snapshot_id       = var.jenkins_home_snapshot_id
  tags = {
    Name = local.ebs_volume_name
  }
}

resource "aws_ecs_task_definition" "ecs_task" {
  family                = "${var.prefix}-${var.name}"
  container_definitions = data.template_file.ecs_task.rendered
  network_mode          = "host"
  volume {
    name = local.ebs_volume_name
    docker_volume_configuration {
      scope         = "shared"
      autoprovision = false
      driver        = "rexray/ebs"
    }
  }
  volume {
    name      = "docker_sock"
    host_path = "/var/run/docker.sock"
  }
  volume {
    name      = "docker_bin"
    host_path = "/usr/bin/docker"
  }
  volume {
    name      = "docker_compose_bin"
    host_path = "/usr/local/bin/docker-compose"
  }
}

resource "aws_ecs_service" "ecs_service" {
  name                              = "${var.prefix}-${var.name}"
  cluster                           = aws_ecs_cluster.cluster.id
  task_definition                   = aws_ecs_task_definition.ecs_task.arn
  desired_count                     = 1
  health_check_grace_period_seconds = 600

  load_balancer {
    target_group_arn = aws_alb_target_group.target_group.id
    container_name   = "jenkins"
    container_port   = "8080"
  }

  depends_on = [aws_autoscaling_group.ecs_host]
}

resource "aws_security_group" "alb" {
  name        = "${var.prefix}-alb-${var.name}"
  description = "Allow 443 and 80"
  vpc_id      = var.vpc_id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = [
      "0.0.0.0/0",
    ]
  }
}

resource "aws_alb_target_group" "target_group" {
  name                 = "${var.prefix}-${var.name}"
  port                 = 8080
  protocol             = "HTTP"
  deregistration_delay = "10"
  vpc_id               = var.vpc_id
  health_check {
    path                = "/"
    port                = "8080"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 5
    timeout             = 4
    matcher             = "200,403"
  }
  depends_on = [aws_alb.alb]
}

resource "aws_alb" "alb" {
  name            = "${var.prefix}-${var.name}"
  subnets         = var.load_balancer_subnets
  security_groups = [aws_security_group.alb.id]
}

resource "aws_alb_listener" "front_end" {
  load_balancer_arn = aws_alb.alb.id
  port              = "443"
  protocol          = "HTTPS"
  certificate_arn   = var.certificate_arn
  default_action {
    target_group_arn = aws_alb_target_group.target_group.id
    type             = "forward"
  }
}

resource "aws_alb_listener" "http_to_https_redirect" {
  load_balancer_arn = aws_alb.alb.id
  port              = "80"
  protocol          = "HTTP"
  default_action {
    target_group_arn = aws_alb_target_group.target_group.id
    type             = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_302"
    }
  }
}

data "aws_route53_zone" "zone" {
  name = var.hosted_zone
}

resource "aws_route53_record" "record" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = var.url
  type    = "CNAME"
  ttl     = "5"
  records = [aws_alb.alb.dns_name]
}





resource "aws_iam_role" "dlm_lifecycle_role" {
  name               = "${var.prefix}-dlm-lifecycle-role-${var.name}"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "dlm.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "dlm_lifecycle" {
  name   = "${var.prefix}-dlm-lifecycle-policy-${var.name}"
  role   = aws_iam_role.dlm_lifecycle_role.id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateSnapshot",
        "ec2:CreateSnapshots",
        "ec2:DeleteSnapshot",
        "ec2:DescribeInstances",
        "ec2:DescribeVolumes",
        "ec2:DescribeSnapshots",
        "ec2:EnableFastSnapshotRestores",
        "ec2:DescribeFastSnapshotRestores",
        "ec2:DisableFastSnapshotRestores",
        "ec2:CopySnapshot"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateTags"
      ],
      "Resource": "arn:aws:ec2:*::snapshot/*"
    }
  ]
}
EOF
}

resource "aws_dlm_lifecycle_policy" "example" {
  description        = "example DLM lifecycle policy"
  execution_role_arn = aws_iam_role.dlm_lifecycle_role.arn
  state              = "ENABLED"
  policy_details {
    resource_types = ["VOLUME"]
    schedule {
      name = "2 weeks of daily snapshots"
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["00:31"]
      }
      retain_rule {
        count = 14
      }
      tags_to_add = {
        SnapshotCreator = "DLM"
        SourceVolume    = local.ebs_volume_name
      }
      copy_tags = true
    }
    target_tags = {
      Name = local.ebs_volume_name
    }
  }
}
