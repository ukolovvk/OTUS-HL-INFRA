terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

output "private_key" {
  value = tls_private_key.ssh_key.private_key_pem
  sensitive=true
}

output "public_key" {
  value = tls_private_key.ssh_key.public_key_openssh
  sensitive=true
}

resource "local_file" "private_key" {
  content = "${tls_private_key.ssh_key.private_key_pem}"
  filename = "private_key"
}

resource null_resource "pr_key_chmod" {
  provisioner "local-exec" {
    command = "chmod 700 private_key"
  }

  depends_on = [local_file.private_key]
}

provider "yandex" {
  # auth via env vars:
  # export YC_TOKEN=$(yc iam create-token)
  # export YC_CLOUD_ID=$(yc config get cloud-id)
  # export YC_FOLDER_ID=$(yc config get folder-id)
  
  zone = "ru-central1-a"
  max_retries = "3"
}

resource yandex_vpc_security_group vm_group_sg {
  network_id = "enpm3u225evb8b1al0u7" # default network

  ingress {
    description    = "Allow all ssh connections"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Allow all http connections"
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Permit ANY"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_compute_disk" "boot_disk" {
  name     = "boot-hdd-20"
  type     = "network-hdd"
  zone     = "ru-central1-a"
  image_id = "fd8gqkbp69nel2ibb5pr"  # Ubuntu 24.04 LTS
  size     = "20"
}

resource "yandex_vpc_address" "test_ip" {
  name = "test_ip"
  external_ipv4_address {
    zone_id = "ru-central1-a"
  }
}

resource "yandex_compute_instance" "test_vm" {
  name        = "test-vm-1"
  platform_id = "standard-v1"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 4
  }

  boot_disk {
    disk_id = "${yandex_compute_disk.boot_disk.id}"
  }

  network_interface {
    index  = 1
    subnet_id = "e9bik5sca0i62bn5v8ta" # default-ru-central1-a subnet
    nat = true
    nat_ip_address = "${yandex_vpc_address.test_ip.external_ipv4_address[0].address}"
    security_group_ids = [yandex_vpc_security_group.vm_group_sg.id]
  }

  metadata = {
    ssh-keys = "vmuser:${tls_private_key.ssh_key.public_key_openssh}"
  }

  depends_on = [yandex_vpc_address.test_ip, yandex_compute_disk.boot_disk]
}

resource "local_file" "hosts_cfg" {
  content = templatefile("inv_template",
    {
      yc_vm_ips = yandex_compute_instance.test_vm.network_interface.*.nat_ip_address
    }
  )
  filename = "inv"

  depends_on = [yandex_compute_instance.test_vm]
}

resource null_resource "ansible" {
  provisioner "local-exec" {
    command = "ansible-playbook -T 300 -i inv playbook.yml --extra-vars=ansible_ssh_private_key_file=private_key"
  }

  depends_on = [local_file.hosts_cfg]
}
