#!/bin/bash
#
# Bash script that illustrates how to deploy  a Python web application to 
# a EC2 instance using CLI commands.
#
# The script creates  the security group and key pair,
# launches the instance, installs dependencies from requirements.txt,
# copies the app folder, and runs the Dash app in background.

# To get started: first make sure you have the AWS CLI installed and configured.
# Also, ensure you have 'jq' installed for JSON parsing.
# Add all the code inside the folder "app", with a requirements.txt file.
# Modify the variables below as needed.

AWS_EXEC=~/localcode/aws-ware/aws-cli/aws
APP_NAME=ExplainerApp6
PORT=8050
AMI_ID=ami-0b6c6ebed2801a5cb
APP_FILE=app.py

set -euo pipefail

if ! command -v "$AWS_EXEC" >/dev/null 2>&1; then
    echo "Error: aws executable not found at $AWS_EXEC"
    exit 1
fi

${AWS_EXEC} sts get-caller-identity >/dev/null 2>&1 || {
    echo "AWS credentials invalid or expired. Do aws login"
    exit 1
}

${AWS_EXEC} ec2 create-key-pair \
    --key-name ${APP_NAME}_key \
    --query 'KeyMaterial' \
    --output text > ${APP_NAME}_key.pem

chmod 600 ${APP_NAME}_key.pem

${AWS_EXEC} ec2 create-security-group \
    --group-name ${APP_NAME}_SG \
    --description "Security group for ${APP_NAME}"

# Get the security group ID
SG_ID=$(${AWS_EXEC} ec2 describe-security-groups \
    --group-names ${APP_NAME}_SG \
    --query "SecurityGroups[0].GroupId" \
    --output text)

echo "Security Group ID: $SG_ID"

# HTTP port 80
${AWS_EXEC} ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0

# Dash port 8050
${AWS_EXEC} ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port ${PORT} \
    --cidr 0.0.0.0/0

# Optional: SSH port 22 for administration
${AWS_EXEC} ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0

# Launch (with default storage)
${AWS_EXEC} ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type t3.micro \
    --key-name ${APP_NAME}_key \
    --security-group-ids $SG_ID \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${APP_NAME}}]" > created_instance.log

# Get IP address
PUBLIC_IP=$(${AWS_EXEC} ec2 describe-instances \
    --filters "Name=tag:Name,Values=${APP_NAME}" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)
PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '[:space:]')

echo $PUBLIC_IP
INSTANCE_ID=$(jq -r '.Instances[0].InstanceId' created_instance.log)
echo $INSTANCE_ID

# Wait until the instance is running
${AWS_EXEC} ec2 wait instance-running --instance-ids $INSTANCE_ID

echo "Instance is running."

${AWS_EXEC} ec2 wait instance-status-ok --instance-ids $INSTANCE_ID
echo "Instance status is OK."


# Scp the "app" folder to the instance
scp -T -i ${APP_NAME}_key.pem -o StrictHostKeyChecking=no -r app ubuntu@${PUBLIC_IP}:/home/ubuntu

# Run commands on the EC2 instance
ssh -T -i ${APP_NAME}_key.pem -o StrictHostKeyChecking=no ubuntu@${PUBLIC_IP} << EOF
set -e
# Install dependencies
sudo apt update
sudo apt install -y python3-pip python3-venv
cd app
python3 -m venv .env_dash
source .env_dash/bin/activate
pip install -r requirements.txt
# Run Dash app in background
nohup python "$APP_FILE" > dash.log 2>&1 &
# echo "Dash app started in background. Logs: dash.log"
EOF

echo "Deployment complete. Access the app at http://$PUBLIC_IP:$PORT"