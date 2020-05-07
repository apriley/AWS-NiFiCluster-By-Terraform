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

  tags = merge(local.common_tags, { Name = "${var.project_tag}-${var.environment_tag}-vpc" })

}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = merge(local.common_tags, { Name = "${var.project_tag}-${var.environment_tag}-igw" })

}

resource "aws_subnet" "subnet" {
  count                   = var.subnet_av_count
  cidr_block              = cidrsubnet(var.network_address_space, 8, count.index)
  vpc_id                  = aws_vpc.vpc.id
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[count.index % var.subnet_av_count]

  tags = merge(local.common_tags, { Name = "${var.project_tag}-${var.environment_tag}-subnet${count.index + 1}" })

}

# ROUTING #
resource "aws_route_table" "rtb" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(local.common_tags, { Name = "${var.project_tag}-${var.environment_tag}-rtb" })
}

resource "aws_route_table_association" "rta-subnet" {
  count          = var.subnet_av_count
  subnet_id      = aws_subnet.subnet[count.index].id
  route_table_id = aws_route_table.rtb.id
}

# SECURITY GROUPS #

# Zookeeper security group
resource "aws_security_group" "zoo-sg" {
  name   = "${var.project_tag}-zoo_sg"
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

  #Allow individual box access on 8080, so that can pick which NiFi instance to develop on.
  ingress {
    from_port   = 2888
    to_port     = 2888
    protocol    = "tcp"
    cidr_blocks = [var.network_address_space]
  }

  #Allow individual box access on 8080, so that can pick which NiFi instance to develop on.
  ingress {
    from_port   = 3888
    to_port     = 3888
    protocol    = "tcp"
    cidr_blocks = [var.network_address_space]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_tag}-${var.environment_tag}-nifi-sg" })
}

resource "aws_security_group" "nifi-sg" {
  name   = "${var.project_tag}-nifi_sg"
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

  tags = merge(local.common_tags, { Name = "${var.project_tag}-${var.environment_tag}-nifi-sg" })
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

  tags = merge(local.common_tags, { Name = "${var.project_tag}-${var.environment_tag}-nifi-${count.index + 1}" })

  # Provisioners
  provisioner "remote-exec" {
    inline = [
      "sudo yum update -y",
      "sudo yum remove java-1.7.0-openjdk-1.7.0.251-2.6.21.0.82.amzn1.x86_64 -y",
      "sudo yum install java-1.8.0-openjdk-devel -y",
      "sudo adduser nifi",
      "sudo mkdir -p /opt/nifi-download",
      "sudo mkdir -p /opt/nifi",
      "sudo chown nifi:nifi /opt/nifi",
      "sudo chown nifi:nifi /opt/nifi-download",
      "sudo -u nifi curl http://mirror.ox.ac.uk/sites/rsync.apache.org/nifi/1.11.4/nifi-1.11.4-bin.tar.gz --output /opt/nifi-download/nifi-1.11.4-bin.tar.gz",
      "sudo -u nifi curl http://apache.mirror.anlx.net/nifi/1.11.4/nifi-toolkit-1.11.4-bin.tar.gz --output /opt/nifi-download/nifi-toolkit-1.11.4-bin.tar.gz",
      "sudo -u nifi tar -xf /opt/nifi-download/nifi-1.11.4-bin.tar.gz -C /opt/nifi",
      "sudo -u nifi tar -xf /opt/nifi-download/nifi-toolkit-1.11.4-bin.tar.gz -C /opt/nifi",
      "sudo -u nifi /opt/nifi/nifi-1.11.4/bin/nifi.sh start"
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

  tags = merge(local.common_tags, { Name = "${var.project_tag}-${var.environment_tag}-zoo-${count.index + 1}" })

  # Provisioners
  provisioner "remote-exec" {
    inline = [
      "sudo yum update -y",
      "sudo yum remove java-1.7.0-openjdk-1.7.0.251-2.6.21.0.82.amzn1.x86_64 -y",
      "sudo yum install java-1.8.0-openjdk-devel -y",
      "sudo adduser zookeeper",
      "sudo mkdir -p /opt/zookeeper-download",
      "sudo mkdir -p /opt/zookeeper",
      "sudo chown zookeeper:zookeeper /opt/zookeeper",
      "sudo chown zookeeper:zookeeper /opt/zookeeper-download",
      "sudo -u zookeeper curl http://apache.mirror.anlx.net/zookeeper/zookeeper-3.6.1/apache-zookeeper-3.6.1-bin.tar.gz --output /opt/zookeeper-download/apache-zookeeper-3.6.1-bin.tar.gz",
      "sudo -u zookeeper tar -xf /opt/zookeeper-download/apache-zookeeper-3.6.1-bin.tar.gz -C /opt/zookeeper"
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

