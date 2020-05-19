##################################################################################
# VARIABLES
##################################################################################

variable "aws_access_key" {}
variable "aws_secret_key" {}
variable "private_key_path" {}
variable "key_name" {}
variable "application_version" {}
variable "region" {
  default = "eu-west-2"
}

variable "network_address_space" {
  default = "10.1.0.0/16"
}

variable "subnet1_address_space" {
  default = "10.1.0.0/24"
}

variable "project_tag" {}
variable "environment_tag" {}


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
  cidr_block           = var.network_address_space
  enable_dns_hostnames = "true"

}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_subnet" "subnet1" {
  cidr_block              = var.subnet1_address_space
  vpc_id                  = aws_vpc.vpc.id
  map_public_ip_on_launch = "true"
  availability_zone       = data.aws_availability_zones.available.names[0]

}

# ROUTING #
resource "aws_route_table" "rtb" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "rta-subnet1" {
  subnet_id      = aws_subnet.subnet1.id
  route_table_id = aws_route_table.rtb.id
}

# SECURITY GROUPS #

resource "aws_security_group" "doc" {
  name   = "${var.project_tag}-doc"
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

  #Stub runs on 8080 by default.
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

  tags = merge(local.common_tags, { Name = "${var.project_tag}-${var.environment_tag}-doc-sg" })
}

# INSTANCES #
resource "aws_instance" "doc" {
  ami = data.aws_ami.aws-linux.id
  # Could be nano in a paid env
  instance_type = "t2.micro"
  subnet_id = aws_subnet.subnet1.id
  vpc_security_group_ids = [
    aws_security_group.doc.id]
  key_name = var.key_name

  connection {
    type = "ssh"
    host = self.public_ip
    user = "ec2-user"
    private_key = file(var.private_key_path)

  }

  tags = merge(local.common_tags, { Name = "${var.project_tag}-${var.environment_tag}-doc" })

  # Provisioners
  provisioner "remote-exec" {
    inline = [
      "sudo yum update -y",
      "sudo yum remove java-1.7.0-openjdk-1.7.0.251-2.6.21.0.82.amzn1.x86_64 -y",
      "sudo yum install java-1.8.0-openjdk-devel -y",
      "sudo adduser document",
      "sudo mkdir -p /opt/document/data",
      "sudo chown document:document /opt/document",
      "sudo chown document:document /opt/document/data",
    ]
  }

  # Copies the myapp.conf file to /etc/myapp.conf
  provisioner "file" {
    source      = "C:\\Users\\andriley\\workspace\\document\\target\\document-${var.application_version}.jar"
    destination = "/opt/document/document-${var.application_version}.jar"
  }

  # Copies the myapp.conf file to /etc/myapp.conf
  provisioner "file" {
    source      = "files/document.application.properties"
    destination = "/opt/document/application.properties"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo ln -s /opt/document/document-${var.application_version}.jar /etc/init.d/document",
      "sudo -u document service document start"
    ]
  }



}


##################################################################################
# OUTPUT
##################################################################################

output "nifi_public_dns" {
  value = aws_instance.doc[*].public_dns
}

