#!/usr/bin/env bash
# Claude's remote control for ClaudePC (used from Claude's cloud chat sessions).
# Needs AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_DEFAULT_REGION from the
# environment settings (the limited "claude-pc-switch" key).
#
#   tools/pc.sh status | start | stop | reboot
#   tools/pc.sh run '<PowerShell commands>'     # runs as SYSTEM on the PC
#   tools/pc.sh helper muse|grok
#   tools/pc.sh setup-status
#   tools/pc.sh money
set -euo pipefail
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}" AWS_PAGER=""

if ! command -v aws >/dev/null; then
  pip install --quiet awscli >/dev/null 2>&1 || pip install --quiet --break-system-packages awscli >/dev/null
fi

instance_id() {
  aws ec2 describe-instances \
    --filters Name=tag:Project,Values=ClaudePC Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

run_ps() { # runs PowerShell on the PC and prints the output
  local id cmd params
  id=$(instance_id)
  params=$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]]}))' "$1")
  cmd=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunPowerShellScript \
        --parameters "$params" --query Command.CommandId --output text)
  aws ssm wait command-executed --command-id "$cmd" --instance-id "$id" 2>/dev/null || true
  aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
}

case "${1:-status}" in
  status)
    aws ec2 describe-instances --instance-ids "$(instance_id)" \
      --query 'Reservations[0].Instances[0].[InstanceId,InstanceType,State.Name,PublicIpAddress]' --output text ;;
  start)  id=$(instance_id); aws ec2 start-instances --instance-ids "$id" >/dev/null
          aws ec2 wait instance-running --instance-ids "$id"; echo "running" ;;
  stop)   id=$(instance_id); aws ec2 stop-instances --instance-ids "$id" >/dev/null; echo "stopping" ;;
  reboot) aws ec2 reboot-instances --instance-ids "$(instance_id)"; echo "rebooting" ;;
  run)    run_ps "$2" ;;
  helper) [[ "${2:-}" =~ ^(muse|grok)$ ]] || { echo "use: helper muse|grok"; exit 1; }
          run_ps "Set-Content C:\\ClaudePC\\helper.txt '$2'; Get-Content C:\\ClaudePC\\helper.txt" ;;
  setup-status) run_ps 'Get-Content C:\ClaudePC\setup-status.txt -ErrorAction SilentlyContinue; Get-Content C:\ClaudePC\logs\bootstrap.log -Tail 40 -ErrorAction SilentlyContinue' ;;
  money)
    acct=$(aws sts get-caller-identity --query Account --output text)
    aws budgets describe-budgets --account-id "$acct" \
      --query 'Budgets[].[BudgetName,BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount,CalculatedSpend.ForecastedSpend.Amount]' \
      --output table ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
