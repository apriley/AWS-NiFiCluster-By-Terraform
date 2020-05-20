
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

variable "subnet1_address_space" {
  default = "10.1.0.0/24"
}

variable "project_tag" {
  default = "document stub"
}
variable "environment_tag" {
  default = "dev"
}


#This will move to ansible.
variable "application" {
  default = "document-0.0.1-SNAPSHOT.jar"
}