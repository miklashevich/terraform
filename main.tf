# Указываем, что мы хотим разворачивать окружение в AWS
provider "aws" { 
  
  region = "eu-central-1"
}

# Узнаём, какие есть Дата центры в выбранном регионе
data "aws_availability_zones" "available" {}

# Ищем образ с последней версией Ubuntu
data "aws_ami" "ubuntu" {
  owners      = ["099720109477"]
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
}


# Создаём security group - правило, которое будет разрешать трафик к нашим серверам
resource "aws_security_group" "web" {
  name = "Dynamic Security Group"

  dynamic "ingress" {
    for_each = ["22", "80"]
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name  = "Web access for Application"
  }
}

# Создаём Launch template- это сущность, которая определяет конфигурацию запускаемых серверов.
resource "aws_launch_template" "web" {
  name_prefix     = "Web-server-"
  # какой будет использоваться образ
  image_id        = data.aws_ami.ubuntu.id
  # Размер машины (CPU и память)
  instance_type   = "t3.micro"
  # какие права доступа
  vpc_security_group_ids = [aws_security_group.web.id]
  # какой SSH ключ будет использоваться 
  key_name = "HP-ProBook"
  # Ппрежде, чем удалится старый инстанс, должен запуститься новый
  lifecycle {
    create_before_destroy = true
  }
}

# AWS Autoscaling Group для указания, сколько нам понадобится инстансов 
resource "aws_autoscaling_group" "web" {
  name                 = "ASG-${aws_launch_template.web.name}"
# AWS launch template for instances 
  launch_template  {
    id = aws_launch_template.web.id
  }
  min_size             = 1
  max_size             = 1
  min_elb_capacity     = 1
  #health_check_type    = "ELB"
  # В каких подсетях, каких Дата центрах их следует разместить
  vpc_zone_identifier  = [aws_default_subnet.availability_zone_1.id, aws_default_subnet.availability_zone_2.id]
  # Ссылка на балансировщик нагрузки, который следует использовать 
  load_balancers       = [aws_elb.web.name]
  
  dynamic "tag" {
    for_each = {
      Name   = "WebServer in Auto Scalling Group"
    }
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
  
  lifecycle {
    create_before_destroy = true
  }
}

# Создаем Elastic Load Balancer 
resource "aws_elb" "web" {
  name               = "ELB"
  # перенаправляет трафик на несколько Дата центров
  availability_zones = [data.aws_availability_zones.available.names[0], data.aws_availability_zones.available.names[1]]
  security_groups    = [aws_security_group.web.id]
  
  # слушает на порту 80
  listener {
    lb_port           = 80
    lb_protocol       = "http"
    instance_port     = 80
    instance_protocol = "http"
  }
  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:80/"
    interval            = 10
  }
  tags = {
    Name = "ELB"
  }
}

# Созаём subnets в разных Дата центрах
resource "aws_default_subnet" "availability_zone_1" {
  availability_zone = data.aws_availability_zones.available.names[0]
}

resource "aws_default_subnet" "availability_zone_2" {
  availability_zone = data.aws_availability_zones.available.names[1]
}

# Выведем в консоль DNS имя нашего loadbalancer 
output "web_loadbalancer_url" {
  value = aws_elb.web.dns_name
}

# Выведем в консоль zone_id loadbalancer
output "web_zone_id" {
  value = aws_elb.web.zone_id
}


data "aws_elb_hosted_zone_id" "main" {}

# Данные по hosted zone - там наш домен припаркован
data "aws_route53_zone" "selected" {
    name = "miklashevich.site"  
}

# В AWS route53 вносим записи
resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = "www.miklashevich.site"
  type    = "A"
  
  alias {
    name                   = aws_elb.web.dns_name
    zone_id                = aws_elb.web.zone_id
    evaluate_target_health = true
  }
}   