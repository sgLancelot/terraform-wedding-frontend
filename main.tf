variable "aws_region" {}
variable "bucket_name" {}
variable "apex_domain_name" {}
variable "domain_name" {}
variable "codepipeline_bucket_name" {}
variable "codecommit_repo" {}
variable "codecommit_branch" {}
variable "codecommit_repo_arn" {}

provider "aws" {
  region = var.aws_region
}

# s3 bucket static website
resource "aws_s3_bucket" "website_bucket" {
  bucket = var.bucket_name
  acl    = "public-read"
  #policy = "${file("policy.json")}"
  policy = <<EOF
{
  "Version":"2012-10-17",
  "Statement":[{
        "Sid":"PublicReadForGetBucketObjects",
        "Effect":"Allow",
          "Principal": "*",
      "Action":["s3:GetObject"],
      "Resource":["arn:aws:s3:::${var.bucket_name}/*"]
    }
  ]
}
EOF

  force_destroy = true # perhaps this should be set so that TF can destroy this bucket easier?

  website {
    index_document = "index.html"
    error_document = "index.html"
  }
}

# aws certificate manager 
resource "aws_acm_certificate" "acm_cert" {
  domain_name       = "*.${var.apex_domain_name}"
  validation_method = "DNS"

  # It's recommended to specify to replace a certificate which is currently in use
  lifecycle {
    create_before_destroy = true
  }
}

# aws certificate validation
resource "aws_acm_certificate_validation" "acm_cert_valid" {
  certificate_arn         = aws_acm_certificate.acm_cert.arn
  validation_record_fqdns = ["${aws_route53_record.r53_cert_valid.fqdn}"]
}

# aws route 53 DNS entries for ACM cert validation
data "aws_route53_zone" "r53_zone" {
  name         = "${var.apex_domain_name}."
  private_zone = false
}

resource "aws_route53_record" "r53_cert_valid" {
  name    = aws_acm_certificate.acm_cert.domain_validation_options.0.resource_record_name
  type    = aws_acm_certificate.acm_cert.domain_validation_options.0.resource_record_type
  zone_id = data.aws_route53_zone.r53_zone.id
  records = ["${aws_acm_certificate.acm_cert.domain_validation_options.0.resource_record_value}"]
  ttl     = 60
}

# cloudfront distro
resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name = aws_s3_bucket.website_bucket.bucket_regional_domain_name
    origin_id   = var.domain_name
  }

  enabled             = true
  default_root_object = "index.html"

  aliases = [var.domain_name]

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"] # need clean up
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = var.domain_name
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  price_class = "PriceClass_200"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # cert must be in us-east-1
  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate.acm_cert.arn
    ssl_support_method  = "sni-only"
  }
}

# route 53 dns record for to point to cloudfront.
resource "aws_route53_record" "r53_website" {
  name    = var.domain_name
  zone_id = data.aws_route53_zone.r53_zone.id
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.s3_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

# artifact bucket for both codepipeline and codebuild
resource "aws_s3_bucket" "artifact_bucket" {
  bucket = var.codepipeline_bucket_name
  acl    = "private"
}

# codebuild project for codepipeline
resource "aws_iam_role" "codebuild_role" {
  name = "codebuild_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

# adapted from AWS generated service role
resource "aws_iam_role_policy" "codebuild_role" {
  role = "codebuild_role"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Effect": "Allow",
          "Resource": [
              "*"
          ],
          "Action": [
              "logs:CreateLogGroup",
              "logs:CreateLogStream",
              "logs:PutLogEvents"
          ]
      },
      {
          "Effect": "Allow",
          "Resource": [
            "${aws_s3_bucket.artifact_bucket.arn}",
            "${aws_s3_bucket.artifact_bucket.arn}/*"
          ],
          "Action": [
              "s3:PutObject",
              "s3:GetObject",
              "s3:GetObjectVersion",
              "s3:GetBucketAcl",
              "s3:GetBucketLocation"
          ]
      },
      {
          "Effect": "Allow",
          "Action": [
              "codebuild:CreateReportGroup",
              "codebuild:CreateReport",
              "codebuild:UpdateReport",
              "codebuild:BatchPutTestCases"
          ],
          "Resource": [
              "*"
          ]
      }
  ]
}
EOF
}

resource "aws_codebuild_project" "codebuild_project" {
  name           = "codebuild_project"
  build_timeout  = "5"
  queued_timeout = "5"
  service_role   = aws_iam_role.codebuild_role.arn
  artifacts {
    type = "CODEPIPELINE"
  }
  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:3.0"
    type         = "LINUX_CONTAINER"
  }
  source {
    type = "CODEPIPELINE"
  }
}

# codepipeline for the s3 static website bucket
resource "aws_iam_role" "codepipeline_role" {
  name = "codepipeline_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codepipeline.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "codepipeline_policy"
  role = aws_iam_role.codepipeline_role.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect":"Allow",
      "Action": [
        "s3:*"
      ],
      "Resource": [
        "${aws_s3_bucket.artifact_bucket.arn}",
        "${aws_s3_bucket.artifact_bucket.arn}/*",
        "${aws_s3_bucket.website_bucket.arn}",
        "${aws_s3_bucket.website_bucket.arn}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codecommit:CancelUploadArchive",
        "codecommit:GetBranch",
        "codecommit:GetCommit",
        "codecommit:GetUploadArchiveStatus",
        "codecommit:UploadArchive"
      ],
      "Resource": "${var.codecommit_repo_arn}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_codepipeline" "codepipeline" {
  name     = "tf-test-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.artifact_bucket.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["SourceOutput"]

      configuration = {
        RepositoryName = var.codecommit_repo
        BranchName     = var.codecommit_branch
        # CodePipeline polls CodeCommit. Not recommended. Should switch to CloudWatch events.
        PollForSourceChanges = false
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["SourceOutput"]
      output_artifacts = ["BuildOutput"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.codebuild_project.name
      }
    }
  }
  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "S3"
      input_artifacts = ["BuildOutput"]
      version         = "1"

      configuration = {
        Extract    = true
        BucketName = var.bucket_name
      }
    }
  }
}

# CloudWatch Event on CodeCommit repo
resource "aws_iam_role" "cloudwatchevent_role" {
  name = "cloudwatchevent_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "events.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "cloudwatchevent_policy" {
  name = "cloudwatchevent_policy"
  role = aws_iam_role.cloudwatchevent_role.id

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "codepipeline:StartPipelineExecution"
            ],
            "Resource": [
                "${aws_codepipeline.codepipeline.arn}"
            ]
        }
    ]
}
EOF
}


resource "aws_cloudwatch_event_rule" "watch_codecommit" {
  event_pattern = <<PATTERN
	{
  "source": [
    "aws.codecommit"
  ],
  "detail-type": [
    "CodeCommit Repository State Change"
  ],
  "resources": [
    "${var.codecommit_repo_arn}"
  ],
  "detail": {
    "event": [
      "referenceCreated",
      "referenceUpdated"
    ],
    "referenceType": [
      "branch"
    ],
    "referenceName": [
      "master"
    ]
  }
}
PATTERN
}

resource "aws_cloudwatch_event_target" "target_codepipeline" {
  rule      = aws_cloudwatch_event_rule.watch_codecommit.name
  arn       = aws_codepipeline.codepipeline.arn
  role_arn = aws_iam_role.cloudwatchevent_role.arn
}