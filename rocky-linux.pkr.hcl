# ================================================================
# 1. PACKER: Define required plugins and settings
# ================================================================
packer {
  required_plugins {
    amazon = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# ================================================================
# 2. VARIABLES: Input variables from GitHub Actions
# ================================================================

# Injected by GHA: -var "ami_name=..."
variable "ami_name" {
  type    = string
  default = "rocky-custom-ami-default"
}

# Injected by GHA: env PKR_VAR_aws_region
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# MODIFIED: Added this new variable
# Injected by GHA: env PKR_VAR_build_uuid
variable "build_uuid" {
  type = string
  # No default, must be provided by the workflow
}

# Injected by GHA: env PKR_VAR_awx_host
variable "awx_host" {
  type    = string
  default = "awx.example.com"
}

# Injected by GHA: env PKR_VAR_awx_token
variable "awx_token" {
  type      = string
  sensitive = true
}

# Injected by GHA: env PKR_VAR_awx_job_template_id
variable "awx_job_template_id" {
  type    = string
  default = "0"
}

# ================================================================
# 3. BUILDER: How to build the AMI
# ================================================================
source "amazon-ebs" "rocky-linux" {
  # --- AWS Connection ---
  region = var.aws_region

  # --- Base AMI Filter (Finds latest official Rocky 9) ---
  source_ami_filter {
    filters = {
      "name"                = "Rocky-9-EC2-Base-9.6-20250531.0.*"
      "virtualization-type" = "hvm"
      "root-device-type"    = "ebs"
    }
    owners      = ["679593333241"] # Rocky Linux official owner
    most_recent = true
  }

  # --- Instance & SSH ---
  instance_type        = "t3.medium"
  ssh_username         = "rocky"
  ssh_private_key_file = "~/.ssh/ubuntu.pem"
  ssh_timeout          = "10m"

  # --- AMI Naming ---
  ami_name = "${var.ami_name}-{{timestamp}}"

  # --- FINAL AMI TAGS ---
  tags = {
    "Name"              = var.ami_name
    "PipelineBuildDate" = "{{isotime \"2006-01-02\"}}"
    "Purpose"           = "GoldenAMI"
    "Environment"       = "Test"
    "BuiltBy"           = "GitHubActions"
  }

  # --- TEMPORARY INSTANCE TAGS ---
  run_tags = {
    "Name" = "packer-build-${var.ami_name}"
  }
}

# ================================================================
# 4. BUILD: Provisioners and Post-Processors
# ================================================================
build {
  name = "rocky-linux-build"
  sources = [
    "source.amazon-ebs.rocky-linux"
  ]

  # --- PROVISIONER 1: Call AWX Job Template (FIXED LOGIC) ---
  provisioner "shell-local" {
    environment_vars = [
      "AWX_TOKEN=${var.awx_token}",
      "AWX_HOST=${var.awx_host}",
      "TEMPLATE_ID=${var.awx_job_template_id}",
      "AWS_REGION=${var.aws_region}",
      "AMI_NAME_VAR=${var.ami_name}"
    ]
    inline = [
      # 1. GET INSTANCE ID
      "echo '==> Finding instance ID...'",
      # We escape $AMI_NAME_VAR with $$ so Packer doesn't parse it as its own
      "INSTANCE_ID=$(aws ec2 describe-instances --region $AWS_REGION --filters \"Name=tag:Name,Values=packer-build-$${AMI_NAME_VAR}\" \"Name=instance-state-name,Values=pending,running\" --query \"Reservations[*].Instances[*].InstanceId\" --output text | tr -d '[:space:]')",
      "if [ -z \"$INSTANCE_ID\" ]; then echo '!!> Could not find running instance to tag!'; exit 1; fi",
      "echo \"==> Found instance: $INSTANCE_ID\"",

      # 2. ADD UNIQUE TAG
      "echo '==> Applying unique tag to instance $INSTANCE_ID...'",
      # MODIFIED: Use the variable ${var.build_uuid} passed from GHA
      "aws ec2 create-tags --region $AWS_REGION --resources $INSTANCE_ID --tags Key=packer-provision,Value=packer-${var.build_uuid}",
      "echo '==> Tag applied.'",

      # 3. PREPARE AWX CALL
      "echo '==> Launching Ansible AWX Job Template...'",
      # MODIFIED: Use the variable ${var.build_uuid} passed from GHA
      "TARGET_HOST=\"tag_packer_provision_packer_${var.build_uuid}\"",
      "echo \"==> Target host for AWX: $TARGET_HOST\"",

      # 4. Launch the job
      "JOB_RESPONSE=$(curl -ksSf -H \"Authorization: Bearer $AWX_TOKEN\" -H \"Content-Type: application/json\" -X POST -d \"{ \\\"limit\\\": \\\"$TARGET_HOST\\\" }\" https://$AWX_HOST/api/v2/job_templates/$TEMPLATE_ID/launch/)",

      # 5. Get the Job ID and start polling
      "JOB_ID=$(echo $JOB_RESPONSE | jq -r .job)",
      "if [ \"$JOB_ID\" == \"null\" ] || [ -z \"$JOB_ID\" ]; then echo 'Failed to launch AWX job! Check config/credentials.'; echo \"AWX Response: $JOB_RESPONSE\"; exit 1; fi",
      "echo \"==> AWX Job launched successfully. Job ID: $JOB_ID\"",
      "echo \"==> Waiting for job to complete...\"",
      "JOB_STATUS=\"running\"",
      "while [ \"$JOB_STATUS\" == \"running\" ] || [ \"$JOB_STATUS\" == \"pending\" ] || [ \"$JOB_STATUS\" == \"waiting\" ]; do sleep 20; JOB_STATUS_RESPONSE=$(curl -ksSf -H \"Authorization: Bearer $AWX_TOKEN\" https://$AWX_HOST/api/v2/jobs/$JOB_ID/); JOB_STATUS=$(echo $JOB_STATUS_RESPONSE | jq -r .status); echo \"... current job status: $JOB_STATUS\"; done",

      # 6. Check for success or failure
      "echo \"==> AWX Job finished with status: $JOB_STATUS\"",
      "if [ \"$JOB_STATUS\" != \"successful\" ]; then echo '!!> Ansible AWX job failed! Failing Packer build.'; echo '!!> AWX Job stdout:'; curl -ksSf -H \"Authorization: Bearer $AWX_TOKEN\" https://$AWX_HOST/api/v2/jobs/$JOB_ID/stdout/; exit 1; else echo '==> AWX provisioning complete.'; fi"
    ]
  }

  # --- POST-PROCESSOR: Create manifest file ---
  post-processor "manifest" {
    output     = "rocky-manifest.json"
    strip_path = true
  }
}
