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

# Injected by GHA: env PKR_VAR_awx_host
variable "awx_host" {
  type    = string
  default = "awx.example.com" # Default, but will be overridden
}

# Injected by GHA: env PKR_VAR_awx_token
variable "awx_token" {
  type      = string
  sensitive = true # Prevents this from being logged
}

# Injected by GHA: env PKR_VAR_awx_job_template_id
variable "awx_job_template_id" {
  type    = string
  default = "0" # Default, but will be overridden
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
      "name"                = "Rocky-9-ec2-9.*"
      "virtualization-type" = "hvm"
      "root-device-type"    = "ebs"
    }
    owners      = ["679593333241"] # Rocky Linux official owner
    most_recent = true
  }

  # --- Instance & SSH ---
  instance_type        = "t3.medium" # t2.micro can be too slow
  ssh_username         = "rocky"
  #ssh_private_key_file = "~/.ssh/ubuntu.pem" # Uses key from GHA step
  ssh_timeout          = "10m"

  # --- AMI Naming ---
  ami_name = "${var.ami_name}-{{timestamp}}" # Uses GHA name + timestamp

  # --- FINAL AMI TAGS (Replaces your 'aws ec2 create-tags' step) ---
  ami_tags = {
    "Name"              = var.ami_name
    "PipelineBuildDate" = "{{isotime \"2006-01-02\"}}"
    "Purpose"           = "GoldenAMI"
    "Environment"       = "Test"
    "BuiltBy"           = "GitHubActions"
  }

  # --- TEMPORARY INSTANCE TAGS (This is how AWX finds it) ---
  run_tags = {
    # This tag is for the AWX Inventory filter
    "Name" = "packer-build-${var.ami_name}"
    # This tag is for the AWX Job 'limit'
    "packer-provision" = "packer-${build.uuid}"
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

  # --- PROVISIONER 1: Call AWX Job Template ---
  provisioner "shell-local" {
    environment_vars = [
      "AWX_TOKEN=${var.awx_token}",
      "AWX_HOST=${var.awx_host}",
      "TEMPLATE_ID=${var.awx_job_template_id}",
      "BUILD_UUID=${build.uuid}" # Pass Packer's unique ID
    ]
    inline = [
      "echo '==> Launching Ansible AWX Job Template...'",

      # Define the host name AWX will find in its dynamic inventory
      # Based on the 'packer-provision' tag
      "TARGET_HOST=\"tag_packer_provision_packer_${BUILD_UUID}\"",
      "echo \"==> Target host for AWX: $TARGET_HOST\"",

      # 1. Launch the job AND pass the 'limit' variable
      #    We use '-k' to ignore self-signed certs on local AWX
      "JOB_RESPONSE=$(curl -ksSf -H \"Authorization: Bearer $AWX_TOKEN\" -H \"Content-Type: application/json\" -X POST \\",
      "  -d \"{ \\\"limit\\\": \\\"$TARGET_HOST\\\" }\" \\",
      "  https://$AWX_HOST/api/v2/job_templates/$TEMPLATE_ID/launch/)",

      # 2. Get the Job ID and start polling
      "JOB_ID=$(echo $JOB_RESPONSE | jq -r .job)",
      "if [ \"$JOB_ID\" == \"null\" ] || [ -z \"$JOB_ID\" ]; then echo 'Failed to launch AWX job! Check config/credentials.'; echo \"AWX Response: $JOB_RESPONSE\"; exit 1; fi",
      "echo \"==> AWX Job launched successfully. Job ID: $JOB_ID\"",
      "echo \"==> Waiting for job to complete...\"",

      "JOB_STATUS=\"running\"",
      "while [ \"$JOB_STATUS\" == \"running\" ] || [ \"$JOB_STATUS\" == \"pending\" ] || [ \"$JOB_STATUS\" == \"waiting\" ]; do",
      "  sleep 20", # Poll every 20 seconds
      "  JOB_STATUS_RESPONSE=$(curl -ksSf -H \"Authorization: Bearer $AWX_TOKEN\" https://$AWX_HOST/api/v2/jobs/$JOB_ID/)",
      "  JOB_STATUS=$(echo $JOB_STATUS_RESPONSE | jq -r .status)",
      "  echo \"... current job status: $JOB_STATUS\"",
      "done",

      # 3. Check for success or failure
      "echo \"==> AWX Job finished with status: $JOB_STATUS\"",
      "if [ \"$JOB_STATUS\" != \"successful\" ]; then",
      "  echo '!!> Ansible AWX job failed! Failing Packer build.'",
      "  # Get job output from AWX for debugging
      "  echo '!!> AWX Job stdout:'",
      "  curl -ksSf -H \"Authorization: Bearer $AWX_TOKEN\" https://$AWX_HOST/api/v2/jobs/$JOB_ID/stdout/",
      "  exit 1",
      "fi",
      "echo '==> AWX provisioning complete.'"
    ]
  }

  # --- POST-PROCESSOR: Create manifest file ---
  # This creates a JSON file with the AMI ID, which is
  # much safer than trying to 'grep' the build log.
  post-processor "manifest" {
    output     = "rocky-manifest.json"
    strip_path = true
  }
}
