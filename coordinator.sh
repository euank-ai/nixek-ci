#!/usr/bin/env bash
# nixek-ci coordinator: evaluate, build, and launch CI jobs
# Usage: ./coordinator.sh <repo-url> <commit> [job-name]
#
# For local QEMU testing:
#   NIXEK_MODE=qemu ./coordinator.sh /path/to/repo HEAD hello-world
#
# For EC2:
#   NIXEK_MODE=ec2 ./coordinator.sh https://github.com/user/repo abc123 hello-world
set -eu -o pipefail

export PATH="/run/current-system/sw/bin:$PATH"
NIX="nix --extra-experimental-features nix-command\ flakes"

REPO="${1:?Usage: coordinator.sh <repo> <commit> [job]}"
COMMIT="${2:?Usage: coordinator.sh <repo> <commit> [job]}"
JOB_NAME="${3:-}"
MODE="${NIXEK_MODE:-qemu}"
API_URL="${NIXEK_API_URL:-}"
WORKDIR="${NIXEK_WORKDIR:-/tmp/nixek-ci-work}"

mkdir -p "$WORKDIR"

# Clone or use local repo
if [[ "$REPO" == http* ]] || [[ "$REPO" == git@* ]]; then
  REPO_DIR="$WORKDIR/repo"
  rm -rf "$REPO_DIR"
  git clone --depth 1 --branch "${COMMIT}" "$REPO" "$REPO_DIR" 2>/dev/null || {
    git clone "$REPO" "$REPO_DIR"
    cd "$REPO_DIR" && git checkout "$COMMIT"
  }
else
  REPO_DIR="$REPO"
fi

cd "$REPO_DIR"

# Discover jobs if no specific job given
if [ -z "$JOB_NAME" ]; then
  echo "=== Discovering jobs ==="
  JOBS=$($NIX eval --impure --json '.#ci.jobs' --apply 'x: builtins.attrNames x' 2>/dev/null)
  echo "Available jobs: $JOBS"
  # Run all jobs
  for job in $(echo "$JOBS" | jq -r '.[]'); do
    echo "=== Running job: $job ==="
    NIXEK_MODE="$MODE" NIXEK_API_URL="$API_URL" "$0" "$REPO_DIR" "$COMMIT" "$job"
  done
  exit 0
fi

echo "=== Processing job: ${JOB_NAME} ==="

# Step 1: Evaluate steps
echo "--- Evaluating steps ---"
STEPS=$($NIX eval --impure --json ".#ci.jobs.${JOB_NAME}" \
  --apply 'f: let job = f {}; in builtins.map (s: { inherit (s) name command; }) job.steps')
echo "Steps: $STEPS"

# Step 2: Build machine image
echo "--- Building machine image (${MODE}) ---"
if [ "$MODE" = "ec2" ]; then
  $NIX build --impure \
    --expr "let flake = builtins.getFlake (builtins.toString ./.); job = flake.ci.jobs.\"${JOB_NAME}\" {}; in job.machine.aws" \
    -o "$WORKDIR/machine-image"
  echo "AWS image built at: $WORKDIR/machine-image"
  
  # Step 3: Register AMI and launch EC2 instance
  echo "--- Registering AMI ---"
  # Upload to S3
  BUCKET="nixek-ci-images-$(aws sts get-caller-identity --query Account --output text)"
  aws s3 mb "s3://${BUCKET}" 2>/dev/null || true
  IMAGE_KEY="nixek-ci/${JOB_NAME}-$(date +%s).raw"
  aws s3 cp "$WORKDIR/machine-image/"*.raw "s3://${BUCKET}/${IMAGE_KEY}"
  
  # Import as snapshot
  IMPORT_TASK=$(aws ec2 import-snapshot --disk-container "{
    \"Format\": \"raw\",
    \"UserBucket\": {
      \"S3Bucket\": \"${BUCKET}\",
      \"S3Key\": \"${IMAGE_KEY}\"
    }
  }" --query 'ImportTaskId' --output text)
  
  echo "Import task: $IMPORT_TASK"
  echo "Waiting for import..."
  while true; do
    STATUS=$(aws ec2 describe-import-snapshot-tasks --import-task-ids "$IMPORT_TASK" --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.Status' --output text)
    if [ "$STATUS" = "completed" ]; then break; fi
    echo "  Status: $STATUS"
    sleep 10
  done
  
  SNAPSHOT_ID=$(aws ec2 describe-import-snapshot-tasks --import-task-ids "$IMPORT_TASK" --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId' --output text)
  
  # Register AMI
  AMI_ID=$(aws ec2 register-image \
    --name "nixek-ci-${JOB_NAME}-$(date +%s)" \
    --architecture x86_64 \
    --root-device-name /dev/xvda \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"SnapshotId\":\"${SNAPSHOT_ID}\",\"VolumeType\":\"gp3\"}}]" \
    --virtualization-type hvm \
    --ena-support \
    --query 'ImageId' --output text)
  
  echo "AMI: $AMI_ID"
  
  # Create userdata with job config
  USERDATA=$(cat <<EOF | base64 -w0
{
  "name": "${JOB_NAME}",
  "job_id": "ec2-$(date +%s)",
  "api_url": "${API_URL}",
  "steps": ${STEPS}
}
EOF
)
  
  # Launch instance
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type t3.micro \
    --user-data "$USERDATA" \
    --instance-initiated-shutdown-behavior terminate \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=nixek-ci-${JOB_NAME}},{Key=nixek-ci,Value=true}]" \
    --query 'Instances[0].InstanceId' --output text)
  
  echo "Instance launched: $INSTANCE_ID"
  echo "Instance will auto-terminate after job completes."
  
else
  # QEMU mode
  $NIX build --impure \
    --expr "let flake = builtins.getFlake (builtins.toString ./.); job = flake.ci.jobs.\"${JOB_NAME}\" {}; in job.machine.qemu" \
    -o "$WORKDIR/qemu-image"
  
  mkdir -p "$WORKDIR/config"
  cat > "$WORKDIR/config/config.json" <<EOF
{
  "name": "${JOB_NAME}",
  "job_id": "qemu-$(date +%s)",
  "steps": ${STEPS}
}
EOF
  
  rm -f "$WORKDIR/overlay.qcow2"
  $NIX shell nixpkgs#qemu_kvm -c bash -c "
    qemu-img create -b $WORKDIR/qemu-image/nixos.qcow2 -F qcow2 -f qcow2 $WORKDIR/overlay.qcow2
    timeout 120 qemu-system-x86_64 -enable-kvm \
      -drive file=$WORKDIR/overlay.qcow2,if=virtio \
      -m 2048 -smp 2 \
      -fsdev local,security_model=none,id=fsdev0,path=$WORKDIR/config,readonly=on \
      -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=nixek-config \
      -nographic -no-reboot
  "
  rm -f "$WORKDIR/overlay.qcow2"
fi

echo "=== Job ${JOB_NAME} complete ==="
