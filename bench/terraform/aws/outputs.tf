output "registry_public_ip" {
  value = aws_eip.registry.public_ip
}

output "registry_private_ip" {
  value = aws_instance.registry.private_ip
}

output "loadtester_public_ip" {
  value = aws_eip.loadtester.public_ip
}

output "loadtester_private_ip" {
  value = aws_instance.loadtester.private_ip
}

output "admin_username" {
  value = var.admin_username
}

output "ssh_private_key_path" {
  value = pathexpand(var.ssh_key_path)
}

output "s3_registry_bucket" {
  value = aws_s3_bucket.registry.bucket
}

output "s3_reports_bucket" {
  value = aws_s3_bucket.reports.bucket
}

output "aws_region" {
  value = var.region
}
