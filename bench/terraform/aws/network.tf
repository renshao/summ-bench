data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "bench" {
  cidr_block           = "10.30.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.tags, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.bench.id
  tags   = merge(local.tags, { Name = "${local.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.bench.id
  cidr_block        = "10.30.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = merge(local.tags, { Name = "${local.name_prefix}-subnet" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.bench.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge(local.tags, { Name = "${local.name_prefix}-rt" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Cluster placement group: same rack, lowest possible VM-to-VM latency.
# Both instances land in the same AZ (subnet) so this works without spread constraints.
resource "aws_placement_group" "bench" {
  name     = "${local.name_prefix}-pg"
  strategy = "cluster"
  tags     = local.tags
}

resource "aws_security_group" "bench" {
  name        = "${local.name_prefix}-sg"
  description = "Bench: SSH from operator, registry ports intra-VPC, all egress"
  vpc_id      = aws_vpc.bench.id
  tags        = merge(local.tags, { Name = "${local.name_prefix}-sg" })

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }

  ingress {
    description = "Registry ports from VPC - loadtester to registry"
    from_port   = 5000
    to_port     = 5001
    protocol    = "tcp"
    cidr_blocks = ["10.30.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_eip" "registry" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${local.name_prefix}-registry-eip" })
}

resource "aws_eip" "loadtester" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${local.name_prefix}-loadtester-eip" })
}

resource "aws_eip_association" "registry" {
  instance_id   = aws_instance.registry.id
  allocation_id = aws_eip.registry.id
}

resource "aws_eip_association" "loadtester" {
  instance_id   = aws_instance.loadtester.id
  allocation_id = aws_eip.loadtester.id
}
