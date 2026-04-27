resource "aws_s3_bucket" "registry" {
  bucket        = "${local.name_prefix}-registry"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "registry" {
  bucket                  = aws_s3_bucket.registry.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "reports" {
  bucket        = "${local.name_prefix}-reports"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM role for the registry VM so the S3 storage driver can authenticate
# via instance metadata without storing credentials in the registry config.
resource "aws_iam_role" "registry" {
  name = "${local.name_prefix}-registry-role"
  tags = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "registry_s3" {
  name = "s3-registry-access"
  role = aws_iam_role.registry.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:AbortMultipartUpload",
        "s3:GetBucketLocation",
      ]
      Resource = [
        aws_s3_bucket.registry.arn,
        "${aws_s3_bucket.registry.arn}/*",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "registry" {
  name = "${local.name_prefix}-registry-profile"
  role = aws_iam_role.registry.name
  tags = local.tags
}
