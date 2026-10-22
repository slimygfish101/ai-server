#!/usr/bin/env bash
# One-time setup of the "ClaudePC" Windows cloud computer.
# Run this inside AWS CloudShell (the terminal built into the AWS website):
#
#   curl -fsSL https://raw.githubusercontent.com/slimygfish101/ai-server/refs/heads/claude/aws-cloud-computer-setup-jin2ax/setup/aws-setup.sh -o aws-setup.sh
#   bash aws-setup.sh YOUR-EMAIL@example.com [CREDIT_DOLLARS]
#
# It is safe to run again: anything that already exists is left alone.
set -euo pipefail

EMAIL="${1:-}"
CREDITS="${2:-100}"            # how many dollars of Amazon credits you have
REGION="us-east-1"             # N. Virginia, closest to Brooklyn
INSTANCE_TYPE="${INSTANCE_TYPE:-m7i-flex.large}"
DISK_GB=80
NAME="ClaudePC"
DESK_USER="ClaudeDesk"
PW_PARAM="/claude-pc/desk-password"
REPO_RAW="https://raw.githubusercontent.com/slimygfish101/ai-server/refs/heads/claude/aws-cloud-computer-setup-jin2ax"

export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION" AWS_PAGER=""

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mSTOPPED: %s\033[0m\n' "$*"; exit 1; }

[[ "$EMAIL" == *@*.* ]] || fail "Put your email after the command, e.g.: bash aws-setup.sh you@gmail.com"
[[ "$CREDITS" =~ ^[0-9]+$ ]] && (( CREDITS > 50 )) || fail "Credits must be a whole dollar amount above 50."

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
say "Amazon account $ACCOUNT, location $REGION, server size $INSTANCE_TYPE"

# ---------------------------------------------------------------- password
say "Desktop password (kept in Amazon's secure Parameter Store)"
if ! aws ssm get-parameter --name "$PW_PARAM" >/dev/null 2>&1; then
  PW="Cp-$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-18)-7x"
  aws ssm put-parameter --name "$PW_PARAM" --type SecureString --value "$PW" >/dev/null
  echo "Created a new random password."
else
  echo "Password already exists, keeping it."
fi

# ---------------------------------------------------------------- role for the computer itself
say "Permissions for the computer (remote maintenance + reading its own password)"
ROLE="${NAME}-Role"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam put-role-policy --role-name "$ROLE" --policy-name ReadDeskPassword --policy-document "{
    \"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"ssm:GetParameter\",
    \"Resource\":\"arn:aws:ssm:$REGION:$ACCOUNT:parameter$PW_PARAM\"}]}"
  aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
  echo "Waiting 15 seconds for Amazon to register the new permissions..."
  sleep 15
else
  echo "Already set up."
fi

# ---------------------------------------------------------------- firewall
say "Firewall: only allow Remote Desktop (Windows App) connections"
VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
[[ "$VPC" != "None" ]] || fail "This account has no default network (VPC). Tell Claude."
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values="${NAME}-RDP" Name=vpc-id,Values="$VPC" \
     --query 'SecurityGroups[0].GroupId' --output text)
if [[ "$SG" == "None" ]]; then
  SG=$(aws ec2 create-security-group --group-name "${NAME}-RDP" --vpc-id "$VPC" \
       --description "Remote Desktop to ClaudePC" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 3389 --cidr 0.0.0.0/0 >/dev/null
fi
echo "Firewall: $SG"

# ---------------------------------------------------------------- the computer
say "Creating the Windows computer"
INSTANCE=$(aws ec2 describe-instances \
  --filters Name=tag:Project,Values="$NAME" Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [[ "$INSTANCE" == "None" ]]; then
  AMI=$(aws ssm get-parameter --name /aws/service/ami-windows-latest/Windows_Server-2025-English-Full-Base \
        --query Parameter.Value --output text)
  # Pick a data-center zone that actually offers this server size.
  ZONES=$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
          --filters Name=instance-type,Values="$INSTANCE_TYPE" --query 'InstanceTypeOfferings[].Location' --output text)
  SUBNET=""
  for z in $ZONES; do
    SUBNET=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=availability-zone,Values="$z" Name=default-for-az,Values=true \
             --query 'Subnets[0].SubnetId' --output text)
    [[ "$SUBNET" != "None" ]] && break
  done
  [[ -n "$SUBNET" && "$SUBNET" != "None" ]] || fail "No zone offers $INSTANCE_TYPE here. Tell Claude."

  USERDATA=$(cat <<EOF
<powershell>
\$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force C:\\ClaudePC | Out-Null
Invoke-WebRequest -UseBasicParsing "$REPO_RAW/windows/bootstrap.ps1" -OutFile C:\\ClaudePC\\bootstrap.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\ClaudePC\\bootstrap.ps1 -RepoRaw "$REPO_RAW" -DeskUser "$DESK_USER" -PasswordParam "$PW_PARAM" -Region "$REGION"
</powershell>
EOF
)
  if ! INSTANCE=$(aws ec2 run-instances \
        --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --subnet-id "$SUBNET" \
        --security-group-ids "$SG" --iam-instance-profile Name="$ROLE" \
        --cpu-options "NestedVirtualization=enabled" \
        --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$DISK_GB,\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]" \
        --metadata-options HttpTokens=required,HttpEndpoint=enabled \
        --instance-initiated-shutdown-behavior stop \
        --user-data "$USERDATA" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=Project,Value=$NAME}]" \
                             "ResourceType=volume,Tags=[{Key=Name,Value=$NAME-disk},{Key=Project,Value=$NAME}]" \
        --query 'Instances[0].InstanceId' --output text 2>/tmp/launch-error.txt); then
    cat /tmp/launch-error.txt
    fail "Amazon refused to create the computer (message above). Copy that message to Claude. Nothing was charged."
  fi
  echo "Created $INSTANCE. Waiting for it to start..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE"
else
  echo "Computer already exists: $INSTANCE"
fi

# ---------------------------------------------------------------- fixed internet address
say "Fixed internet address (so the Windows App always finds it)"
EIP_ALLOC=$(aws ec2 describe-addresses --filters Name=tag:Project,Values="$NAME" --query 'Addresses[0].AllocationId' --output text)
if [[ "$EIP_ALLOC" == "None" ]]; then
  EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$NAME},{Key=Project,Value=$NAME}]" \
      --query AllocationId --output text)
fi
aws ec2 associate-address --allocation-id "$EIP_ALLOC" --instance-id "$INSTANCE" >/dev/null
IP=$(aws ec2 describe-addresses --allocation-ids "$EIP_ALLOC" --query 'Addresses[0].PublicIp' --output text)

# ---------------------------------------------------------------- safety-net auto-off
say "Safety net: switch off if the computer sits idle for 2 hours"
aws cloudwatch put-metric-alarm --alarm-name "${NAME}-idle-safety-stop" \
  --alarm-description "Stops ClaudePC if CPU stays under 4% for 2 hours (backup for the 60-minute idle timer inside Windows)" \
  --namespace AWS/EC2 --metric-name CPUUtilization --dimensions Name=InstanceId,Value="$INSTANCE" \
  --statistic Average --period 300 --evaluation-periods 24 --threshold 4 --comparison-operator LessThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "arn:aws:automate:$REGION:ec2:stop"

# ---------------------------------------------------------------- money alerts
say "Money alerts to $EMAIL"
START=$(date -u +%Y-%m-01T00:00:00Z)
END=$(date -u -d "$(date -u +%Y-%m-01) +2 years" +%Y-%m-01T00:00:00Z)
SUB="[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$EMAIL\"}]"
note() { echo "{\"Notification\":{\"NotificationType\":\"$1\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":$2,\"ThresholdType\":\"ABSOLUTE_VALUE\"},\"Subscribers\":$SUB}"; }

make_budget() { # name limit include_credit notifications-json
  if aws budgets describe-budget --account-id "$ACCOUNT" --budget-name "$1" >/dev/null 2>&1; then
    echo "Alert '$1' already exists."
    return
  fi
  aws budgets create-budget --account-id "$ACCOUNT" \
    --budget "{\"BudgetName\":\"$1\",\"BudgetType\":\"COST\",\"TimeUnit\":\"CUSTOM\",
               \"BudgetLimit\":{\"Amount\":\"$2\",\"Unit\":\"USD\"},
               \"TimePeriod\":{\"Start\":\"$START\",\"End\":\"$END\"},
               \"CostTypes\":{\"IncludeCredit\":$3}}" \
    --notifications-with-subscribers "$4"
  echo "Created alert '$1'."
}

# 1) Real money: counts what you'd actually pay after credits.
make_budget "ClaudePC-real-charges" 10 true \
  "[$(note ACTUAL 0.01),$(note ACTUAL 8),$(note FORECASTED 10)]"
# 2) Credits: counts total usage before credits, so it tells you how much credit is used up.
make_budget "ClaudePC-credits-used" "$CREDITS" false \
  "[$(note ACTUAL $((CREDITS - 50))),$(note ACTUAL $((CREDITS - 20)))]"

# ---------------------------------------------------------------- Claude's on/off key
say "Limited key for Claude (on/off + maintenance of this one computer only)"
BOT="claude-pc-switch"
aws iam get-user --user-name "$BOT" >/dev/null 2>&1 || aws iam create-user --user-name "$BOT" >/dev/null
aws iam put-user-policy --user-name "$BOT" --policy-name ClaudePCControl --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
   {\"Effect\":\"Allow\",\"Action\":[\"ec2:DescribeInstances\",\"ec2:DescribeInstanceStatus\",\"ec2:DescribeAddresses\",
     \"ssm:DescribeInstanceInformation\",\"ssm:GetCommandInvocation\",\"ssm:ListCommandInvocations\",\"budgets:ViewBudget\"],\"Resource\":\"*\"},
   {\"Effect\":\"Allow\",\"Action\":[\"ec2:StartInstances\",\"ec2:StopInstances\",\"ec2:RebootInstances\"],
     \"Resource\":\"arn:aws:ec2:$REGION:$ACCOUNT:instance/*\",\"Condition\":{\"StringEquals\":{\"aws:ResourceTag/Project\":\"$NAME\"}}},
   {\"Effect\":\"Allow\",\"Action\":\"ssm:SendCommand\",
     \"Resource\":\"arn:aws:ec2:$REGION:$ACCOUNT:instance/*\",\"Condition\":{\"StringEquals\":{\"aws:ResourceTag/Project\":\"$NAME\"}}},
   {\"Effect\":\"Allow\",\"Action\":\"ssm:SendCommand\",\"Resource\":\"arn:aws:ssm:$REGION::document/AWS-RunPowerShellScript\"}]}"

if [[ "$(aws iam list-access-keys --user-name "$BOT" --query 'length(AccessKeyMetadata)' --output text)" == "0" ]]; then
  read -r KEY_ID KEY_SECRET < <(aws iam create-access-key --user-name "$BOT" \
       --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
  NEW_KEY=1
else
  NEW_KEY=0
fi

# ---------------------------------------------------------------- summary
PW=$(aws ssm get-parameter --name "$PW_PARAM" --with-decryption --query Parameter.Value --output text)
cat <<EOF


==================================================================
 DONE. The computer is installing its software now (about 20-30 min,
 it restarts itself once). Leave it alone until then.
==================================================================

 FOR THE WINDOWS APP (save these in the Windows App, nowhere else):
   PC name / address : $IP
   User name         : $DESK_USER
   Password          : $PW

EOF
if [[ "$NEW_KEY" == "1" ]]; then
cat <<EOF
 FOR CLAUDE'S ENVIRONMENT SETTINGS (NOT the chat!)
 Add these three as environment variables / secrets:
   AWS_ACCESS_KEY_ID     = $KEY_ID
   AWS_SECRET_ACCESS_KEY = $KEY_SECRET
   AWS_DEFAULT_REGION    = $REGION

 This key is shown only once. If you lose it, tell Claude and it
 will give you a command to make a new one.
EOF
else
  echo " Claude's on/off key already exists (not shown again)."
fi
echo
echo " Now close this window and tell Claude: \"setup script finished\"."
