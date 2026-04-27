resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "ssh_private_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = pathexpand(var.ssh_key_path)
  file_permission = "0600"
}

resource "local_file" "ssh_public_key" {
  content         = tls_private_key.ssh.public_key_openssh
  filename        = "${pathexpand(var.ssh_key_path)}.pub"
  file_permission = "0644"
}

resource "aws_key_pair" "bench" {
  key_name   = "${local.name_prefix}-key"
  public_key = tls_private_key.ssh.public_key_openssh
  tags       = local.tags
}

# Ubuntu 24.04 LTS (Noble) — Canonical's official AMI, x86_64, gp3-backed
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Registry VM: m6id.2xlarge — 8 vCPU / 32 GiB / 474 GB NVMe instance store.
# The NVMe instance store (/dev/nvme1n1) is detected and formatted by
# registry-setup-aws.yml using the same disk detection logic as the Azure run.
# IAM instance profile grants S3 access for the distribution S3 storage driver.
resource "aws_instance" "registry" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type_registry
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.bench.id]
  key_name               = aws_key_pair.bench.key_name
  placement_group        = aws_placement_group.bench.id
  iam_instance_profile   = aws_iam_instance_profile.registry.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 64
    iops        = 3000
    throughput  = 125
    encrypted   = false
    tags        = merge(local.tags, { Name = "${local.name_prefix}-registry-root" })
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-registry" })
}

# Loadtester VM: c6i.large — 2 vCPU / 4 GiB. HTTP-bound load gen;
# no local storage needed. cargo build is ~5-7 min one-time.
resource "aws_instance" "loadtester" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type_loadtester
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.bench.id]
  key_name               = aws_key_pair.bench.key_name
  placement_group        = aws_placement_group.bench.id

  root_block_device {
    volume_type = "gp3"
    volume_size = 64
    iops        = 3000
    throughput  = 125
    encrypted   = false
    tags        = merge(local.tags, { Name = "${local.name_prefix}-loadtester-root" })
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-loadtester" })
}
