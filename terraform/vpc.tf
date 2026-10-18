resource "aws_vpc" "this" {
  cidr_block = "192.168.0.0/22"
}

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "192.168.0.0/24"
  availability_zone       = local.az
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
}


resource "aws_route_table" "public" {
  # Enable obtaining public IPs in subnets. If later a private subnet is needed, use default vpc route table.
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table_association" "public" { # ← is this present, and did it apply cleanly?
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

# Security group - public
resource "aws_security_group" "zomboid" {
  description = "Allow Project Zomboid server traffic"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "zomboid" {
  security_group_id = aws_security_group.zomboid.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 16261
  to_port           = 16262
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_egress_rule" "egress" {
  security_group_id = aws_security_group.zomboid.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Security group - admin
data "aws_ssm_parameter" "admin_cidrs_raw" {
  name = "/zomboid/${local.env}/admin_cidrs"
}

locals {
  admin_cidrs = [for c in split(",", data.aws_ssm_parameter.admin_cidrs_raw.value) : trimspace(c)]
}

resource "aws_ec2_managed_prefix_list" "trusted" {
  name           = "zomboid_admin_cidrs_${local.env}"
  address_family = "IPv4"
  max_entries    = length(local.admin_cidrs)

  dynamic "entry" {
    for_each = local.admin_cidrs
    content {
      cidr = entry.value
    }
  }
}

resource "aws_security_group" "private_access" {
  description = "Allow access to Zomboid server from limited IP range"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.private_access.id
  prefix_list_id    = aws_ec2_managed_prefix_list.trusted.id
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}
