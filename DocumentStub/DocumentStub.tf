##################################################################################
# VARIABLES
##################################################################################




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

#Define our AWS AMI (Amazon Machine Image), we are getting the lated RHEL 8 image
data "aws_ami" "aws-red_hat" {
  most_recent = true
  name_regex = "RHEL-8.*_HVM-.*x86.*"
  owners     = ["309956199498"] #Red Hat
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
  ami = data.aws_ami.aws-red_hat.id
  # Could be nano in a paid env
  instance_type = "t2.micro"
  subnet_id = aws_subnet.subnet1.id
  vpc_security_group_ids = [
    aws_security_group.doc.id]
  key_name = var.key_name

  tags = merge(local.common_tags, { Name = "${var.project_tag}-${var.environment_tag}-doc" })

}

resource "aws_instance" "ansible_server" {
  ami = data.aws_ami.aws-red_hat.id
  instance_type = "t2.micro"
  key_name = var.key_name
  subnet_id = aws_subnet.subnet1.id
  vpc_security_group_ids = [
    aws_security_group.doc.id]

  tags = { Name = "Ansible Server"}

}

#Install and Run ansible playbook on Ansible Server
resource "null_resource" "ansible-provisioner" {
  //Create directory for the playbook
  provisioner "remote-exec" {
    inline = ["mkdir -p ~/test-playbook"]
  }

  //Create directory for the files
  provisioner "remote-exec" {
    inline = ["mkdir -p ~/test-playbook/files"]
  }

  //Move the playbook over
  provisioner "file" {
    source      = "${path.module}/ansible/playbook.yml"
    destination = "~/test-playbook/playbook.yml"
  }
  //Move the key over so that ansible can connect to the remote boxes
  provisioner "file" {
    source     = var.private_key_path
    destination = "~/test-playbook/key"
  }
  //Lock the key down
  provisioner "remote-exec" {
    inline = [
      "chmod 400 ~/test-playbook/key"
    ]
  }
  //Create a hosts file with the hosts that we just created
  provisioner "file" {
    content = templatefile("${path.module}/ansible/templates/ansible-hosts.tmpl", {
      nifi_nodes : aws_instance.doc.public_dns,
    })
    destination = "~/test-playbook/inventory"
  }

  //Move the application properties file
  provisioner "file" {
    source      = "${path.module}/ansible/files/application.properties"
    destination = "~/test-playbook/files/application.properties"
  }

  //Move the service file
  provisioner "file" {
    source      = "${path.module}/ansible/files/document.service"
    destination = "~/test-playbook/files/document.service"
  }

  //Move the application jar over
  provisioner "file" {
    source      = "${path.module}/ansible/files/${var.application}"
    destination = "~/test-playbook/files/${var.application}"
  }

  //Run the playbook from the bsation onto the deployed hosts
  provisioner "remote-exec" {
    inline = [
      "/usr/libexec/platform-python -m pip install --user ansible",
      "cd ~/test-playbook && ansible-playbook -i inventory --private-key key --ssh-common-args='-o StrictHostKeyChecking=no' playbook.yml"
    ]
  }
  connection {
    type        = "ssh"
    host        = aws_instance.ansible_server.public_ip
    user        = "ec2-user"
    private_key = file(var.private_key_path)
  }

}


##################################################################################
# OUTPUT
##################################################################################

output "nifi_public_dns" {
  value = aws_instance.doc[*].public_dns
}

