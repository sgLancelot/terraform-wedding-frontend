variable "aws_region" {}
variable "bucket_name" {}

provider "aws" {
  region = "${var.aws_region}"
}

resource "aws_s3_bucket" "wedding-website" {
  bucket = "${var.bucket_name}"
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

  force_destroy = true

  website {
    index_document = "index.html"
    error_document = "index.html"
  }
}