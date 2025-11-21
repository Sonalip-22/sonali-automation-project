#!/bin/bash
set -euo pipefail

echo "🔹 Loading configuration..."

if [[ ! -f config.env ]]; then
  echo "❌ config.env not found!"
  exit 1
fi
source ./config.env

# Shortcut function to use region everywhere
awsr() {
  aws --region "${AWS_REGION}" "$@"
}

# -------------------------------------------------------------
# 1. Validate AWS CLI Installation
# -------------------------------------------------------------
if ! command -v aws &>/dev/null; then
  echo "❌ AWS CLI not installed!"
  exit 1
fi
echo "✅ AWS CLI found"

# -------------------------------------------------------------
# 2. Validate AWS Credentials
# -------------------------------------------------------------
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "❌ Invalid AWS credentials!"
  exit 1
fi
echo "✅ AWS Credentials valid"

# -------------------------------------------------------------
# 3. Create Key Pair (Idempotent)
# -------------------------------------------------------------
if awsr ec2 describe-key-pairs --key-names "${KEY_PAIR_NAME}" >/dev/null 2>&1; then
  echo "ℹ️ Key Pair already exists: ${KEY_PAIR_NAME}"
else
  echo "🔹 Creating Key Pair..."
  awsr ec2 create-key-pair \
    --key-name "${KEY_PAIR_NAME}" \
    --query "KeyMaterial" \
    --output text > "${KEY_PAIR_NAME}.pem"

  chmod 400 "${KEY_PAIR_NAME}.pem"
  echo "✅ Key Pair created: ${KEY_PAIR_NAME}.pem"
fi

# -------------------------------------------------------------
# 4. Create Security Group (Idempotent)
# -------------------------------------------------------------
SG_ID=$(awsr ec2 describe-security-groups \
  --group-names "${SECURITY_GROUP_NAME}" \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null || echo "")

if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
  echo "ℹ️ Security Group already exists: $SECURITY_GROUP_NAME ($SG_ID)"
else
  echo "🔹 Creating Security Group..."
  SG_ID=$(awsr ec2 create-security-group \
            --group-name "${SECURITY_GROUP_NAME}" \
            --description "Auto SG for EC2 creation script" \
            --query "GroupId" --output text)

  awsr ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0
  awsr ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0

  echo "✅ Security Group created: $SG_ID"
fi

# -------------------------------------------------------------
# 5. Create Random S3 Bucket with prefix
# -------------------------------------------------------------
BUCKET_NAME="${S3_BUCKET_PREFIX}-$(date +%s)"

echo "🔹 Creating S3 bucket: $BUCKET_NAME"

awsr s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --create-bucket-configuration LocationConstraint="${AWS_REGION}"

echo "✅ S3 bucket created"

# -------------------------------------------------------------
# 6. Create EC2 Instance (Idempotent)
# -------------------------------------------------------------
# Check if EC2 instance already exists
EXISTING_INSTANCE=$(aws ec2 describe-instances \
 --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
 --query "Reservations[0].Instances[0].InstanceId" \
 --output text)

if [[ "$EXISTING_INSTANCE" != "None" ]]; then
  INSTANCE_ID="$EXISTING_INSTANCE"
  echo "ℹ️ EC2 instance already exists: $INSTANCE_ID"
else
  echo "🔹 Launching new EC2 Instance..."

  INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --count 1 \
        --key-name "$KEY_PAIR_NAME" \
        --security-group-ids "$SG_ID" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
        --query "Instances[0].InstanceId" \
        --output text)

  echo "⏳ Waiting for instance to be ready..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
fi

PUBLIC_IP=$(awsr ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

# -------------------------------------------------------------
# 7. Save Summary Information
# -------------------------------------------------------------
cat <<SUMMARY > summary.txt
EC2 Instance Name: $INSTANCE_NAME
EC2 Instance ID: $INSTANCE_ID
Public IP: $PUBLIC_IP
Security Group ID: $SG_ID
Key Pair: $KEY_PAIR_NAME
S3 Bucket: $BUCKET_NAME
AWS Region: $AWS_REGION
SUMMARY

echo "---------------------------------"
echo "           SUMMARY"
echo "---------------------------------"
cat summary.txt

