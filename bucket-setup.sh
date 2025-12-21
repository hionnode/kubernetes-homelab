#!/bin/bash

AWS_REGION="ap-south-1"

# Create Bucket
BUCKET_NAME="homelab-tfstate-$(whoami)-$(date +%s)"
aws s3 mb s3://${BUCKET_NAME} --region ${AWS_REGION}

#Block public access(security)

aws s3api put-public-access-block \
  --bucket ${BUCKET_NAME} \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Print bucket name

echo "Your bucket name: ${BUCKET_NAME}"
