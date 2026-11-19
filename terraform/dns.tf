resource "aws_ec2_instance_state" "server" {
  instance_id = aws_instance.server.id
  state       = "running"
}

data "aws_instance" "server" {
  instance_id = aws_instance.server.id
  depends_on  = [aws_ec2_instance_state.server]
}

data "aws_route53_zone" "this" {
  count = local.dns_zone_name != "" ? 1 : 0
  name  = local.dns_zone_name
}

resource "aws_route53_record" "server" {
  count   = local.dns_zone_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = "${local.subdomain}.${local.dns_zone_name}"
  type    = "A"
  ttl     = 60
  records = [data.aws_instance.server.public_ip]
}
