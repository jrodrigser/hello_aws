# Common use case: 
# You have to test a python repository in a EC2 instance. 
# The script should launch the instance, clone the repo, install a venv,
# install requirements.txt and ssh to the instance

# To get started: first make sure you have the AWS CLI installed and configured.
# Also, ensure you have 'jq' installed for JSON parsing.
# Modify the variables below as needed.

AWS_EXEC=aws  # Path to your AWS CLI executable, e.g., /usr/local/bin/aws
REPOSITORY_URL= # Your git repository URL
AMI_ID= # An AMI ID for an Ubuntu image in your region (e.g. ami-0b6c6ebed2801a5cb)
APP_NAME=my_app  # The security group and key pair will be named after this and can be reused
VOLUME_SIZE=20  # Size in GB for the root volume

set -euo pipefail

# Check if AWS CLI is available and credentials are valid

if ! command -v "$AWS_EXEC" >/dev/null 2>&1; then
    echo "Error: aws executable not found at $AWS_EXEC"
    exit 1
fi

# Check AWS credentials

${AWS_EXEC} sts get-caller-identity >/dev/null 2>&1 || {
    echo "AWS credentials invalid or expired. Do aws login"
    exit 1
}

# Create key pair and security group if they don't exist

if ${AWS_EXEC} ec2 describe-key-pairs --key-names ${APP_NAME}_key >/dev/null 2>&1; then
    echo "Key exists, continue..."
    # rest of your script
else
    echo "Key not found, running alternative command..."
    ${AWS_EXEC} ec2 create-key-pair \
        --key-name ${APP_NAME}_key \
        --query 'KeyMaterial' \
        --output text > ${APP_NAME}_key.pem

    chmod 600 ${APP_NAME}_key.pem
fi

# Security group

if ${AWS_EXEC} ec2 describe-security-groups \
    --group-names "${APP_NAME}_SG" \
    >/dev/null 2>&1; then
    echo "Security group exists, continue..."
else
    ${AWS_EXEC} ec2 create-security-group \
    --group-name ${APP_NAME}_SG \
    --description "Security group for ${APP_NAME}"
fi

SG_ID=$(${AWS_EXEC} ec2 describe-security-groups \
    --group-names "${APP_NAME}_SG" \
    --query "SecurityGroups[0].GroupId" \
    --output text)

echo "Security Group ID: $SG_ID"

# Authorize ingress for ssh 
if ${AWS_EXEC} ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 >/dev/null 2>&1; then
    echo "SSH ingress rule created"
else
    echo "SSH ingress rule already exists or failed to create"
fi  

# Create user data
cat > user-data.sh <<EOF
#!/bin/bash
set -e
git clone ${REPOSITORY_URL} /opt/myapp
sudo apt update
sudo apt install -y python3-venv python3-pip
cd /opt/myapp
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
EOF

# Launch (with default storage)
${AWS_EXEC} ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type t3.micro \
    --key-name ${APP_NAME}_key \
    --security-group-ids $SG_ID \
    --block-device-mappings '[
      {
        "DeviceName": "/dev/xvda",
        "Ebs": {
          "VolumeSize": '"$VOLUME_SIZE"',
          "VolumeType": "gp3",
          "DeleteOnTermination": true
        }
      }
    ]' \
    --user-data file://user-data.sh \
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

echo "You can now SSH into the instance using:"
echo "ssh -i ${APP_NAME}_key.pem ubuntu@${PUBLIC_IP}"

# Create a cleanup script
cat > tmp_cleanup.sh <<EOF
#!/bin/bash
set -e
${AWS_EXEC} ec2 terminate-instances --instance-ids $INSTANCE_ID
${AWS_EXEC} ec2 wait instance-terminated --instance-ids $INSTANCE_ID
echo "Instance terminated."
${AWS_EXEC} ec2 delete-security-group --group-id $SG_ID
echo "Security group deleted."
${AWS_EXEC} ec2 delete-key-pair --key-name ${APP_NAME}_key
rm -f ${APP_NAME}_key.pem
echo "Key pair deleted."
rm -f user-data.sh
echo "User data script deleted."
EOF

chmod +x tmp_cleanup.sh
