##################################################################################
# VARIABLES
##################################################################################

variable "aws_access_key" {}
variable "aws_secret_key" {}
variable "private_key_path" {}
variable "key_name" {}
variable "region" {
  default = "eu-west-2"
}

variable "network_address_space" {
  default = "10.1.0.0/16"
}

variable "project_tag" {}
variable "environment_tag" {}

variable "nifi_count" {
  default = 2
}

variable "zookeeper_count" {
  default = 3
}

# As ELB cannot cover two subnets in AV, subnet count should equal AV count.
variable "subnet_av_count" {
  default = 2
}

##################################################################################
# LOCALS
##################################################################################

locals {
  common_tags = {
    Project = var.project_tag
    Environment = var.environment_tag
  }
}

##################################################################################
# PROVIDERS
##################################################################################

provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = var.region
}

##################################################################################
# DATA
##################################################################################

data "aws_ami" "aws-linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn-ami-hvm*"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_availability_zones" "available" {}

##################################################################################
# RESOURCES
##################################################################################

# NETWORKING #
resource "aws_vpc" "vpc" {
  cidr_block = var.network_address_space
  enable_dns_hostnames = "true"

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-vpc" })

}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-igw" })

}

resource "aws_subnet" "subnet" {
  count                   = var.subnet_av_count
  cidr_block              = cidrsubnet(var.network_address_space, 8, count.index)
  vpc_id                  = aws_vpc.vpc.id
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[count.index % var.subnet_av_count]

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-subnet${count.index + 1}" })

}

# ROUTING #
resource "aws_route_table" "rtb" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-rtb" })
}

resource "aws_route_table_association" "rta-subnet" {
  count          = var.subnet_av_count
  subnet_id      = aws_subnet.subnet[count.index].id
  route_table_id = aws_route_table.rtb.id
}

# SECURITY GROUPS #
resource "aws_security_group" "elb-sg" {
  name   = "nifi_elb_sg"
  vpc_id = aws_vpc.vpc.id

  #Allow HTTP from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  #allow all outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-elb-sg" })
}

# Nginx security group
resource "aws_security_group" "nifi-sg" {
  name   = "nifi_sg"
  vpc_id = aws_vpc.vpc.id

  # SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP access from the VPC
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.network_address_space]
  }

  # HTTP Access from anywhere, for checking.
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  #Allow individual box access on 8080, so that can pick which NiFi instance to develop on.
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-nifi-sg" })
}

# LOAD BALANCER #
resource "aws_elb" "zoo-web" {
  name = "zoo-elb"

  subnets         = aws_subnet.subnet[*].id
  security_groups = [aws_security_group.elb-sg.id]
  instances       = aws_instance.zoo[*].id


  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-elb" })
}

# LOAD BALANCER #
resource "aws_elb" "nifi-web" {
  name = "nifi-elb"

  subnets         = aws_subnet.subnet[*].id
  security_groups = [aws_security_group.elb-sg.id]
  instances       = aws_instance.nifi[*].id


  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-elb" })
}

# INSTANCES #
resource "aws_instance" "nifi" {
  count = var.nifi_count
  ami = data.aws_ami.aws-linux.id
  instance_type = "t2.micro"
  subnet_id = aws_subnet.subnet[count.index % var.subnet_av_count].id
  vpc_security_group_ids = [
    aws_security_group.nifi-sg.id]
  key_name = var.key_name

  connection {
    type = "ssh"
    host = self.public_ip
    user = "ec2-user"
    private_key = file(var.private_key_path)

  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-nifi-${count.index + 1}" })

  # Provisioners
  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /opt/go",
      "sudo chmod 777 /opt/go/",
      "sudo yum install go -y"
    ]
  }

  provisioner "file" {
    source      = "./index.html"
    destination = "/opt/go/index.html"
  }

  provisioner "file" {
    source      = "./server.go"
    destination = "/opt/go/server.go"
  }

  provisioner "remote-exec" {
    inline = [
      "go build /opt/go/server.go",
      "sudo go run /opt/go/server.go &",
    ]
  }
}

# INSTANCES #
resource "aws_instance" "zoo" {
  count = var.zookeeper_count
  ami = data.aws_ami.aws-linux.id
  instance_type = "t2.micro"
  subnet_id = aws_subnet.subnet[count.index % var.subnet_av_count].id
  vpc_security_group_ids = [
    aws_security_group.nifi-sg.id]
  key_name = var.key_name

  connection {
    type = "ssh"
    host = self.public_ip
    user = "ec2-user"
    private_key = file(var.private_key_path)

  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-zoo-${count.index + 1}" })

  # Provisioners
  provisioner "remote-exec" {
    inline = [
      "sudo yum install nginx -y",
      "sudo service nginx start",
      "echo '<html><head><title>Green Team Server</title></head><body style=\"background-color:#77A032\"><p style=\"text-align: center;\"><span style=\"color:#FFFFFF;\"><span style=\"font-size:28px;\">Green Team</span></span></p></body></html>' | sudo tee /usr/share/nginx/html/index.html"
    ]
  }
}

##################################################################################
# OUTPUT
##################################################################################

output "nifi_public_dns" {
  value = aws_instance.nifi[*].public_dns
}

output "zookeeper_public_dns" {
  value = aws_instance.zoo[*].public_dns
}


output "aws_zooelb_public_dns" {
  value = aws_elb.zoo-web.dns_name
}

output "aws_nifielb_public_dns" {
  value = aws_elb.nifi-web.dns_name
}




