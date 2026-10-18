provider "aws" {
  region = local.region

  default_tags {
    tags = {
      Project = "zomboid"
      Env     = local.env
    }
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*"]
  }

  owners = ["099720109477"]
}

resource "aws_ebs_volume" "data" {
  availability_zone = local.az
  size              = 10
  type              = "gp3"

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  volume_path    = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data.id, "-", "")}"
  partition_path = "${local.volume_path}-part1"
}

resource "aws_instance" "server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = local.instance_type
  subnet_id              = aws_subnet.public_1.id
  vpc_security_group_ids = [aws_security_group.zomboid.id, aws_security_group.private_access.id]
  key_name               = local.key_pair_name
  user_data              = <<-EOT
  #cloud-config
  bootcmd:
  - |
    for i in $(seq 1 60); do  # Wait for the data drive to be connected
      [ -e ${local.volume_path} ] && break
      sleep 2
    done
  disk_setup:
    ${local.volume_path}: {table_type: gpt, layout: true, overwrite: false}
  fs_setup:
    - {device: ${local.partition_path}, filesystem: btrfs, overwrite: false}
  mounts:
    - [${local.partition_path}, /btrfs, btrfs, defaults, "0", "0"]
  EOT

  root_block_device {
    volume_size = 15
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf" # It is required by AWS API, but the OS will name it differently with modern instance types.
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.server.id
}
