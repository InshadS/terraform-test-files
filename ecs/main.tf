# Define inputs for the module
variable "cluster_name" {
  type = string
}

variable "container_name" {
  type = string
}

variable "image" {
  type = string
}

variable "port" {
  type = number
}

# Create the ECS cluster
resource "aws_ecs_cluster" "cluster" {
  name = var.cluster_name
}

# Default subnets
resource "aws_default_subnet" "default_as1" {
  availability_zone = "ap-south-1a"

  tags = {
    Name = "Default subnet for ap-south-1a"
  }
}

resource "aws_default_subnet" "default_as2" {
  availability_zone = "ap-south-1b"

  tags = {
    Name = "Default subnet for ap-south-1b"
  }
}

# Security group for ALB
resource "aws_security_group" "alb" {
  name   = "${var.container_name}-sg-alb"
  vpc_id = aws_default_subnet.default_as1.vpc_id
 
  ingress {
   protocol         = "tcp"
   from_port        = 80
   to_port          = 80
   cidr_blocks      = ["0.0.0.0/0"]
   ipv6_cidr_blocks = ["::/0"]
  }
 
  ingress {
   protocol         = "tcp"
   from_port        = 443
   to_port          = 443
   cidr_blocks      = ["0.0.0.0/0"]
   ipv6_cidr_blocks = ["::/0"]
  }
 
  egress {
   protocol         = "-1"
   from_port        = 0
   to_port          = 0
   cidr_blocks      = ["0.0.0.0/0"]
   ipv6_cidr_blocks = ["::/0"]
  }
}

# Scurity group for ECS
resource "aws_security_group" "ecs_tasks" {
  name   = "${var.container_name}-sg-task"
  vpc_id = aws_default_subnet.default_as1.vpc_id
 
  ingress {
   protocol         = "tcp"
   from_port        = var.port
   to_port          = var.port
   cidr_blocks      = ["0.0.0.0/0"]
   ipv6_cidr_blocks = ["::/0"]
  }
 
  egress {
   protocol         = "-1"
   from_port        = 0
   to_port          = 0
   cidr_blocks      = ["0.0.0.0/0"]
   ipv6_cidr_blocks = ["::/0"]
  }
}

# Application load balancer
resource "aws_lb" "main" {
  name               = "${var.container_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    =  [aws_security_group.alb.id]
  subnets            = [aws_default_subnet.default_as1.id, aws_default_subnet.default_as2.id]
 
  enable_deletion_protection = false
}

# Target group
resource "aws_alb_target_group" "main" {
  name        = "${var.container_name}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_default_subnet.default_as1.vpc_id
  target_type = "ip"
 
  health_check {
   healthy_threshold   = "3"
   interval            = "30"
   protocol            = "HTTP"
   matcher             = "200"
   timeout             = "3"
   path                = "/"
   unhealthy_threshold = "2"
  }
}

#create listener
resource "aws_alb_listener" "http" {
  load_balancer_arn = aws_lb.main.id
  port              = 80
  protocol          = "HTTP"
 
  default_action {
    target_group_arn = aws_alb_target_group.main.id
    type             = "forward"
  }
}

# Set up execution role
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.container_name}-ecsTaskExecutionRole"
  assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Action": "sts:AssumeRole",
     "Principal": {
       "Service": "ecs-tasks.amazonaws.com"
     },
     "Effect": "Allow",
     "Sid": ""
   }
 ]
}
EOF
}
 
resource "aws_iam_role_policy_attachment" "ecs-task-execution-role-policy-attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Setup task role
resource "aws_iam_role" "ecs_task_role" {
  name = "${var.container_name}-ecsTaskRole"
 
  assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Action": "sts:AssumeRole",
     "Principal": {
       "Service": "ecs-tasks.amazonaws.com"
     },
     "Effect": "Allow",
     "Sid": ""
   }
 ]
}
EOF
}
 
resource "aws_iam_role_policy_attachment" "ecs-task-role-policy-attachment" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

# Define the ECS task definition
resource "aws_ecs_task_definition" "task" {
  family                   = var.container_name
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  container_definitions    = jsonencode([
    {
      name            = var.container_name
      image           = var.image
      essential       = true
      portMappings    = [
        {
          containerPort = var.port
          hostPort = var.port
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name = "LOGSTREAM"
          value = var.container_name
        }
      ]
    }
  ])
  network_mode             = "awsvpc"
  memory = 512
  cpu = 256
  requires_compatibilities = ["FARGATE"]
}

# Define the ECS service to run the task
resource "aws_ecs_service" "service" {
  name                = var.container_name
  task_definition     = aws_ecs_task_definition.task.arn
  desired_count       = 1
  launch_type         = "FARGATE"
  platform_version    = "LATEST"
  cluster             = aws_ecs_cluster.cluster.arn
  network_configuration {
    subnets = [aws_default_subnet.default_as1.id]
    assign_public_ip = true
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  load_balancer {
   target_group_arn = aws_alb_target_group.main.arn
   container_name   = "${var.container_name}"
   container_port   = var.port
 }
}

# Define the output for the module
output "service_name" {
  value = aws_ecs_service.service.name
}

output "url" {
  value = aws_lb.main.dns_name
}
