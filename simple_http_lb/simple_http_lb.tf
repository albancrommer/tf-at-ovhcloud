########################################################################################
# This script requires the following variables to be defined for the OVH provider :
# OVH_ENDPOINT
# OVH_APPLICATION_KEY
# OVH_APPLICATION_SECRET
# OVH_CONSUMER_KEY
# The following is required specifically for this script:
# TF_VAR_OVH_PUBLIC_CLOUD_PROJECT_ID that shall be filled with your public cloud project id or it will be requested on script startup
########################################################################################


########################################################################################
#     Variables
########################################################################################

variable "ovh_public_cloud_project_id" {
  type = string
}

variable "openstack_region" {
  type    = string
  default = "GRA9"
}

variable "resource_prefix" {
  type    = string
  default = "tf_lb_"
}
variable "image_name" {
  type    = string
  default = "Ubuntu 22.04"
}
variable "instance_type" {
  type    = string
  default = "d2-2"
}
variable "external_network" {
  type    = string
  default = "Ext-Net"
}

variable "instance_nb" {
  default = 2
}


#######################################################################################
#     Providers
########################################################################################
# Define providers and set versions
terraform {
  required_version = ">= 0.14.0" # Takes into account Terraform versions from 0.14.0
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.50.0"
    }
    ovh = {
      source  = "ovh/ovh"
      version = "~> 0.28.1"
    }
  }
}

# Configure the OpenStack expoprovider hosted by OVHcloud
provider "openstack" {
  auth_url         = "https://auth.cloud.ovh.net/v3/" # Authentication URL
  domain_name      = "Default"                        # Domain name - Always at 'default' for OVHcloud
  user_domain_name = "Default"
  user_name        = ovh_cloud_project_user.user.username
  password         = ovh_cloud_project_user.user.password
  region           = var.openstack_region
  tenant_id        = var.ovh_public_cloud_project_id
  use_octavia      = true
}


########################################################################################
#     User
########################################################################################
resource "ovh_cloud_project_user" "user" {
  service_name = var.ovh_public_cloud_project_id
  description  = "User created by terraform loadbalancer script"
  role_name    = "administrator"
}

########################################################################################
#     Instances
########################################################################################


# Creating the instance, no SSH keys 
resource "openstack_compute_instance_v2" "http_server" {
  count       = var.instance_nb
  name        = "${var.resource_prefix}http_server_${count.index}" # Instance name
  image_name  = var.image_name                                     # Image name
  flavor_name = var.instance_type                                  # Instance type name
  network {
    name = openstack_networking_network_v2.tf_lb_network.name
  }
  user_data = <<EOF
#!/bin/bash
echo 'user data begins'
sudo apt-get update
sudo apt-get install -y nginx
echo '<html><head><title>Load Balanced Member 1</title></head><body><h1>You did it ! You hit your OVHCloud load balancer member #${count.index} ! </p></body></html>' | sudo tee /var/www/html/index.html
echo 'user data end'
EOF
  # Add dependency on router itf to be sure the instance can access internet to retrieve package in user data
  depends_on = [openstack_networking_router_interface_v2.tf_lb_router_itf_priv]
}

########################################################################################
#     Network
########################################################################################
data "openstack_networking_network_v2" "ext_net" {
  name     = var.external_network
  external = true
  depends_on = [
    ovh_cloud_project_user.user
  ]
}

resource "openstack_networking_network_v2" "tf_lb_network" {
  name           = "tf_lb_network"
  admin_state_up = "true"
}


resource "openstack_networking_subnet_v2" "tf_lb_subnet" {
  name            = "tf_lb_subnet"
  network_id      = openstack_networking_network_v2.tf_lb_network.id
  cidr            = "10.0.0.0/24"
  gateway_ip      = "10.0.0.254"
  dns_nameservers = ["1.1.1.1", "1.0.0.1"]
  ip_version      = 4

}

resource "openstack_networking_router_v2" "tf_lb_router" {
  name                = "tf_lb_router"
  external_network_id = data.openstack_networking_network_v2.ext_net.id
}

resource "openstack_networking_floatingip_v2" "tf_lb_floatingip" {
  pool = data.openstack_networking_network_v2.ext_net.name
}

resource "openstack_networking_router_interface_v2" "tf_lb_router_itf_priv" {
  router_id = openstack_networking_router_v2.tf_lb_router.id
  subnet_id = openstack_networking_subnet_v2.tf_lb_subnet.id
}

resource "openstack_networking_floatingip_associate_v2" "association" {
  floating_ip = openstack_networking_floatingip_v2.tf_lb_floatingip.address
  port_id     = openstack_lb_loadbalancer_v2.tf_lb.vip_port_id

}

########################################################################################
#     Loadbalancers
########################################################################################
resource "openstack_lb_loadbalancer_v2" "tf_lb" {
  name           = "terraform_lb"
  vip_network_id = openstack_networking_network_v2.tf_lb_network.id
  vip_subnet_id  = openstack_networking_subnet_v2.tf_lb_subnet.id
}


resource "openstack_lb_listener_v2" "listener_http" {
  protocol        = "HTTP"
  protocol_port   = 80
  loadbalancer_id = openstack_lb_loadbalancer_v2.tf_lb.id
}

resource "openstack_lb_pool_v2" "pool_1" {
  name        = "tf_lb_pool"
  protocol    = "HTTP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.listener_http.id

}

resource "openstack_lb_monitor_v2" "monitor_1" {
  pool_id     = openstack_lb_pool_v2.pool_1.id
  type        = "HTTP"
  url_path    = "/index.html"
  delay       = 5
  timeout     = 10
  max_retries = 4
}

resource "openstack_lb_member_v2" "member" {
  count         = var.instance_nb
  name          = "member_${count.index}"
  pool_id       = openstack_lb_pool_v2.pool_1.id
  address       = openstack_compute_instance_v2.http_server[count.index].access_ip_v4
  protocol_port = 80
  subnet_id     = openstack_networking_subnet_v2.tf_lb_subnet.id
}


########################################################################################
#     Outputs
########################################################################################
output "lb_ip" {
  value       = openstack_networking_floatingip_v2.tf_lb_floatingip.address
  description = "The loadbalancer public ip "
}
