################################################################################
# VPC and subnets
################################################################################

# VPC
resource "aws_vpc" "mic_vpc" {
    cidr_block = var.vpc_cidr
    enable_dns_support = "true" #gives you an internal domain name
    enable_dns_hostnames = "true" #gives you an internal host name
    enable_classiclink = "false"
    instance_tenancy = "default"

    tags = {
        Name = "mic_vpc"
    }
}

# Internet Gateway
resource "aws_internet_gateway" "mic_internet_gateway" {
  vpc_id = aws_vpc.mic_vpc.id

  tags = {
    Name = "mic_internet_gateway"
  }
}

# Subnets : private
resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.mic_vpc.id
  cidr_block        = element(var.private_subnets, count.index)
  availability_zone = element(var.azs,count.index)

  tags = {
    Name        = "Private-Subnet-${count.index+1}"
  }
}

# Subnets : public
resource "aws_subnet" "public" {
    count = length(var.public_subnets)
    vpc_id = aws_vpc.mic_vpc.id
    cidr_block = element(var.public_subnets,count.index)
    map_public_ip_on_launch = true //it makes this a public subnet
    availability_zone = element(var.azs,count.index)

    tags = {
        Name = "Public-Subnet-${count.index+1}"
    }
}

# Route table: attach Internet Gateway 
resource "aws_route_table" "mic_public_route_table" {
  vpc_id = aws_vpc.mic_vpc.id
  route {
    # Associated subet can reach public internet
    cidr_block = "0.0.0.0/0"
    # Which internet gateway to use
    gateway_id = aws_internet_gateway.mic_internet_gateway.id
  }

  tags = {
    Name = "mic-public-route-table"
  }
}

# Route table association with public subnets
resource "aws_route_table_association" "public_route_table_association" {
  count          = length(var.public_subnets)
  route_table_id = aws_route_table.mic_public_route_table.id
  subnet_id      = element(aws_subnet.public.*.id,count.index)
}

resource "aws_nat_gateway" "main" {
  count         = length(var.private_subnets)
  allocation_id = element(aws_eip.nat.*.id, count.index)
  subnet_id     = element(aws_subnet.public.*.id, count.index)
  depends_on    = [aws_internet_gateway.mic_internet_gateway]
  tags = {
    Name        = "nat-${count.index+1}"
  }
}

resource "aws_eip" "nat" {
  count = length(var.private_subnets)
  vpc = true
  tags = {
    Name        = "eip-${count.index+1}"
  }
}


################################################################################
# Security Group Config
################################################################################

# security group for ECS task, which will contain our container, allowing access to the exposed port on the task.
resource "aws_security_group" "alb" {
  name        = "app_alb_security_group"
  description = "App load balancer security group"
  vpc_id = aws_vpc.mic_vpc.id

  ingress {
    protocol         = "tcp"
    from_port        = 443
    to_port          = 443
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    protocol         = "tcp"
    from_port        = 80
    to_port          = 80
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    protocol    = "tcp"
    from_port   = var.containerport
    to_port     = var.containerport
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic.
  egress {
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name        = "app_alb_security_group"
  }
}


# Traffic to the ECS cluster should only come from the ALB
resource "aws_security_group" "ecs_tasks" {
  name        = "cb-ecs-tasks-security-group"
  description = "allow inbound access from the ALB only"
  vpc_id      = aws_vpc.mic_vpc.id

  ingress {
    protocol        = "tcp"
    from_port       = var.containerport
    to_port         = var.containerport
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}



################################################################################
# ALB
################################################################################

# Application load balancer
resource "aws_alb" "alb" {
  name            = "alb"
  security_groups = [aws_security_group.alb.id]
  subnets         = aws_subnet.public.*.id
  tags = {
    Name = "app-alb"
  }
}


# New target group for the application load balancer
resource "aws_alb_target_group" "group" {
  name     = "alb-target"
  port     = 80
  protocol = "HTTP"
  target_type = "ip"
  vpc_id   = aws_vpc.mic_vpc.id

  health_check {
    healthy_threshold   = "3"
    interval            = "30"
    protocol            = "HTTP"
    matcher             = "200"
    timeout             = "3"
    path                = "/emp/controller/getDetails"
    unhealthy_threshold = "2"
  }
}

# application load balancer listener-1
resource "aws_alb_listener" "listener_http" {
  load_balancer_arn = "${aws_alb.alb.arn}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.group.arn}"
    type             = "forward"
  }
}


################################################################################
# Autoscaling
################################################################################

resource "aws_appautoscaling_target" "ecs_target" {
  max_capacity       = 4
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.mic-ecs-cluster.name}/${aws_ecs_service.mic-ecs-service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_policy_memory" {
  name               = "memory-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }

    target_value       = 80
    scale_in_cooldown  = 300
    scale_out_cooldown = 300
  }
}

resource "aws_appautoscaling_policy" "ecs_policy_cpu" {
  name               = "cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 300
  }
}

################################################################################
# ECS Cluster and fargate
################################################################################

resource "aws_ecs_cluster" "mic-ecs-cluster" {
  name = "mic-ecs-cluster"
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_task_definition" "mic-ecs-task-definition" {
  family                   = "ecs-task-definition-mic"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  memory                   = "512"
  cpu                      = "256"
  execution_role_arn       = "arn:aws:iam::323144884758:role/ecsTaskExecutionRole"
  container_definitions    = <<DEFINITION
[
  {
    "name": "mic-container",
    "image": "323144884758.dkr.ecr.ap-south-1.amazonaws.com/dt-dev:mic-test",
    "memory": 512,
    "cpu": 256,
    "essential": true,
    "portMappings": [
      {
        "containerPort": 8090,
        "hostPort": 8090,
        "protocol": "tcp"
      }
    ]
  }
]
DEFINITION
}

resource "aws_ecs_service" "mic-ecs-service" {
  name            = "mic-app"
  cluster         = aws_ecs_cluster.mic-ecs-cluster.id
  task_definition = aws_ecs_task_definition.mic-ecs-task-definition.arn
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.public.*.id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }
  desired_count = 1

  load_balancer {
    target_group_arn = aws_alb_target_group.group.id
    container_name   = "mic-container"
    container_port   = var.containerport
  }
}
