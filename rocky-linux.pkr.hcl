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

variable "ami_name" {
  type    = string
  default = "rocky-custom-ami-default"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "build_uuid" {
  type = string
}

variable "awx_host" {
  type    = string
  default = "awx.example.com"
}

# MODIFIED: Removed sensitive = true
# This is the fix for the 401 error
variable "awx_token" {
  type = string
}

variable "awx_job_template_id" {
  type    = string
  default = "0"
}

# MODIFIED: Removed sensitive = true
# This is the fix for the 401 error
variable "awx_public_key" {
  type = string
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
      "name"                = "Rocky-9-EC2-Base-9.5-20241118.0.x86_64-*"
      "virtualization-type" = "hvm"
      "root-device-type"    = "ebs"
    }
    owners      = ["679593333241"] # Rocky Linux official owner
    most_recent = true
  }

  # --- Instance & SSH ---
  instance_type = "t3.medium"
  ssh_username  = "rocky"
  # Packer will generate its own temporary key
  ssh_timeout = "10m"

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
  
  # --- User Data to inject AWX public key ---
  user_data = <<-EOF
    #cloud-config
    users:
      - name: rocky
        ssh_authorized_keys:
          - ${var.awx_public_key}
  EOF
}

# ================================================================
# 4. BUILD: Provisioners and Post-Processors
# ================================================================
build {
  name = "rocky-linux-build"
  sources = [
    "source.amazon-ebs.rocky-linux"
  ]

  # --- PROVISIONER 1: Call AWX Job Template ---
  provisioner "shell-local" {
    environment_vars = [
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
      "aws ec2 create-tags --region $AWS_REGION --resources $INSTANCE_ID --tags Key=packer-provision,Value=packer-${var.build_uuid}",
      "echo '==> Tag applied.'",
      
      # 3. VERIFY SSH (Wait for cloud-init to finish)
      "echo '==> Waiting for SSH and cloud-init (key injection) to be ready...'",
      "sleep 60",
      "echo '==> Ready to call AWX.'",

      # 4. PREPARE AWX CALL
      "echo '==> Launching Ansible AWX Job Template...'",
      "TARGET_HOST=\"tag_packer_provision_packer_${var.build_uuid}\"",
      "echo \"==> Target host for AWX: $TARGET_HOST\"",

      # 5. Launch the job (Using http:// as you confirmed)
      #    We inject ${var.awx_token} directly, and it works
      #    because we removed 'sensitive = true'
      "JOB_RESPONSE=$(curl -ksSf -H \"Authorization: Bearer ${var.awx_token}\" -H \"Content-Type: application/json\" -X POST -d \"{ \\\"limit\\\": \\\"$TARGET_HOST\\\" }\" http://$AWX_HOST/api/v2/job_templates/$TEMPLATE_ID/launch/)",

      # 6. Get the Job ID and start polling
      "JOB_ID=$(echo $JOB_RESPONSE | jq -r .job)",
      "if [ \"$JOB_ID\" == \"null\" ] || [ -z \"$JOB_ID\" ]; then echo 'Failed to launch AWX job! Check config/credentials.'; echo \"AWX Response: $JOB_RESPONSE\"; exit 1; fi",
      "echo \"==> AWX Job launched successfully. Job ID: $JOB_ID\"",
      "echo \"==> Waiting for job to complete...\"",
      "JOB_STATUS=\"running\"",
      "while [ \"$JOB_STATUS\" == \"running\" ] || [ \"$JOB_STATUS\" == \"pending\" ] || [ \"$JOB_STATUS\" == \"waiting\" ]; do sleep 20; JOB_STATUS_RESPONSE=$(curl -ksSf -H \"Authorization: Bearer ${var.awx_token}\" http://$AWX_HOST/api/v2/jobs/$JOB_ID/); JOB_STATUS=$(echo $JOB_STATUS_RESPONSE | jq -r .status); echo \"... current job status: $JOB_STATUS\"; done",

      # 7. Check for success or failure
      "echo \"==> AWX Job finished with status: $JOB_STATUS\"",
      "if [ \"$JOB_STATUS\" != \"successful\" ]; then echo '!!> Ansible AWX job failed! Failing Packer build.'; echo '!!> AWX Job stdout:'; curl -ksSf -H \"Authorization: Bearer ${var.awx_token}\" http://$AWX_HOST/api/v2/jobs/$JOB_ID/stdout/; exit 1; else echo '==> AWX provisioning complete.'; fi"
    ]
  }

  # --- POST-PROCESSOR: Create manifest file ---
  post-processor "manifest" {
    output     = "rocky-manifest.json"
    strip_path = true
  }
}
