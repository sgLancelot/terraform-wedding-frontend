variable "aws_region" {}
variable "bucket_name" {}
variable "apex_domain_name" {}
variable "domain_name" {}

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
  domain_name = "*.${var.apex_domain_name}"
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
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"] # need clean up
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = var.domain_name
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
    ssl_support_method = "sni-only"
  }
}

resource "aws_route53_record" "r53_website" {
  name = var.domain_name
  zone_id = data.aws_route53_zone.r53_zone.id
  type = "A"

  alias {
    name = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id = aws_cloudfront_distribution.s3_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}