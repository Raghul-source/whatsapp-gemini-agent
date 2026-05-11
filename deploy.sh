#!/usr/bin/env bash
# Tells the system to use the Bash shell to run this script.
set -euo pipefail
# Safety feature: stops the script immediately if an error occurs or a required variable is missing.

DEPLOY_CONFIG="${DEPLOY_CONFIG:-./deploy.env}"
# Reads deploy.env at the beginning so its values take priority over script fallbacks and auto-detection.
if [ -f "${DEPLOY_CONFIG}" ]; then
  # Source: https://www.gnu.org/software/bash/manual/bash.html#index-source
  # shellcheck disable=SC1090
  source "${DEPLOY_CONFIG}"
fi

# ==============================================================================
# Deploy WhatsApp Gemini Agent from a laptop to a Google Cloud Compute Engine VM.
#
# Usage from Windows CMD:
#   "C:\Program Files\Git\bin\bash.exe" ./deploy.sh
#
# Optional:
#   cp deploy.env.example deploy.env
#   # edit deploy.env only when auto-detection is not enough
# ==============================================================================

# Initialize empty as a fallback. If deploy.env does not provide the VM name,
# the script will try to auto-detect it from Compute Engine later.
GCP_INSTANCE="${GCP_INSTANCE:-}"

# Initialize empty as a fallback. If deploy.env does not provide the VM zone,
# the script will try to find the zone for the selected VM later.
GCP_ZONE="${GCP_ZONE:-}"

# Initialize empty as a fallback. If deploy.env does not provide the project ID,
# the script will read the active project from the local gcloud configuration.
GCP_PROJECT="${GCP_PROJECT:-}"

REPO_URL="${REPO_URL:-}"
# Defines the GitHub repository link; if empty, the script reads the current git remote URL.
APP_DIR="${APP_DIR:-/opt/whatsapp-agent}"
# Sets the install destination under /opt so the app is not installed inside a personal login folder.
APP_USER="${APP_USER:-}"
# Defines the Linux user that runs the app service; if empty, the remote script detects it with whoami.
SSH_USER="${SSH_USER:-}"
# Defines the SSH username; if empty, the script derives it from the active Google account.
SERVICE_NAME="${SERVICE_NAME:-whatsapp-agent}"
# Defines the background service name used to start, stop, restart, and check the app.
APP_ENV_FILE="${APP_ENV_FILE:-./.env}"
# Defines the local env file to upload to the server as APP_DIR/.env.
APP_MODULE="${APP_MODULE:-main:app}"
# Defines the Python ASGI app loaded by uvicorn.
APP_HOST="${APP_HOST:-0.0.0.0}"
# Defines the host address uvicorn listens on.
APP_PORT="${APP_PORT:-8085}"
# Defines the port uvicorn listens on.

USE_IAP_TUNNEL="false"
# Direct SSH only: this script connects to the VM external IP on standard port 22.
SSH_PORT="${SSH_PORT:-22}"
# Standard SSH port used for the direct "front door" connection.
SSH_SOURCE_RANGE="${SSH_SOURCE_RANGE:-0.0.0.0/0}"
# Source range allowed for direct SSH. Use your public IP CIDR for tighter security.

GCLOUD_QUICK_TIMEOUT="${GCLOUD_QUICK_TIMEOUT:-120s}"
# Maximum time allowed for quick gcloud checks before the script stops with a clear error.
GCLOUD_CONNECT_TIMEOUT="${GCLOUD_CONNECT_TIMEOUT:-240s}"
# Maximum time allowed for upload/download style connection steps.
GCLOUD_DEPLOY_TIMEOUT="${GCLOUD_DEPLOY_TIMEOUT:-40m}"
# Maximum time allowed for the real remote deployment step.
SSH_CHECK_TIMEOUT="${SSH_CHECK_TIMEOUT:-300s}"
# Extra time for SSH connectivity checks on slow networks.

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
# Defines the Linux systemd path where the service file must be saved.

require_command() {
  local tool="$1"
  local purpose="$2"

  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "ERROR: Missing required tool: ${tool}"
    echo "Why the script stopped: ${tool} is required for this deployment step."
    echo "What it is used for: ${purpose}"
    echo "Install/configure ${tool}, open a fresh terminal, then run deploy.sh again."
    exit 1
  fi
}

require_command gcloud "reads Google Cloud project/VM details and manages firewall rules"
require_command git "detects the repository URL and lets the VM clone or pull the code"
require_command ssh "connects to the VM through direct SSH on port 22"
require_command scp "uploads .env and the temporary remote install script to the VM"

run_with_timeout() {
  local duration="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    timeout "${duration}" "$@"
  else
    "$@"
  fi
}

echo "Preparing deployment..."

if [ -z "${GCP_PROJECT}" ]; then
  # Source: https://cloud.google.com/sdk/gcloud/reference/config/get-value
  # Auto-detects the active Google Cloud project only when deploy.env did not provide GCP_PROJECT.
  echo "Detecting active Google Cloud project..."
  GCP_PROJECT="$(run_with_timeout "${GCLOUD_QUICK_TIMEOUT}" gcloud config get-value project 2>/dev/null || true)"
  if [ -z "${GCP_PROJECT}" ] || [ "${GCP_PROJECT}" = "(unset)" ]; then
    echo "ERROR: GCP_PROJECT was not provided and no active gcloud project is configured."
    echo "Fix: set GCP_PROJECT in deploy.env or run: gcloud config set project <project-id>"
    exit 1
  fi
fi

if [ -z "${REPO_URL}" ]; then
  # Source: https://git-scm.com/docs/git-config
  # Detects the GitHub repository URL from the repo already downloaded on the laptop.
  REPO_URL="$(git config --get remote.origin.url || true)"
  if [ -z "${REPO_URL}" ]; then
    echo "ERROR: REPO_URL was not provided and git remote origin was not found."
    echo "Fix: set REPO_URL in deploy.env."
    exit 1
  fi
fi

if [ -z "${GCP_INSTANCE}" ] || [ -z "${GCP_ZONE}" ]; then
  # Source: https://cloud.google.com/sdk/gcloud/reference/compute/instances/list
  # Auto-detection runs only for values missing from deploy.env.
  echo "Detecting Compute Engine VM..."
  VM_LIST="$(run_with_timeout "${GCLOUD_QUICK_TIMEOUT}" gcloud compute instances list --project "${GCP_PROJECT}" --format='value(name,zone)' 2>/dev/null || true)"
  if [ -z "${VM_LIST}" ]; then
    echo "ERROR: No Compute Engine VM instances found in project: ${GCP_PROJECT}"
    echo "Fix: check GCP_PROJECT or create/start the VM in Google Cloud Console."
    exit 1
  fi

  if [ -n "${GCP_INSTANCE}" ] && [ -z "${GCP_ZONE}" ]; then
    GCP_ZONE="$(printf '%s\n' "${VM_LIST}" | awk -v instance="${GCP_INSTANCE}" '$1 == instance { print $2; exit }')"
    if [ -z "${GCP_ZONE}" ]; then
      echo "ERROR: Could not detect the zone for VM instance: ${GCP_INSTANCE}"
      echo "Fix: set GCP_ZONE in deploy.env."
      exit 1
    fi
  elif [ -z "${GCP_INSTANCE}" ] && [ -z "${GCP_ZONE}" ]; then
    VM_COUNT="$(printf '%s\n' "${VM_LIST}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    if [ "${VM_COUNT}" != "1" ]; then
      echo "ERROR: More than one VM found. The script cannot safely choose one."
      echo "Set GCP_INSTANCE and GCP_ZONE in deploy.env. Available VMs:"
      printf '%s\n' "${VM_LIST}"
      exit 1
    fi
    GCP_INSTANCE="$(printf '%s\n' "${VM_LIST}" | awk '{ print $1; exit }')"
    GCP_ZONE="$(printf '%s\n' "${VM_LIST}" | awk '{ print $2; exit }')"
  elif [ -z "${GCP_INSTANCE}" ] && [ -n "${GCP_ZONE}" ]; then
    ZONE_VM_LIST="$(printf '%s\n' "${VM_LIST}" | awk -v zone="${GCP_ZONE}" '$2 == zone { print $1 }')"
    ZONE_VM_COUNT="$(printf '%s\n' "${ZONE_VM_LIST}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    if [ "${ZONE_VM_COUNT}" != "1" ]; then
      echo "ERROR: Could not uniquely detect a VM in zone: ${GCP_ZONE}"
      echo "Set GCP_INSTANCE in deploy.env. Available VMs:"
      printf '%s\n' "${VM_LIST}"
      exit 1
    fi
    GCP_INSTANCE="$(printf '%s\n' "${ZONE_VM_LIST}" | awk '{ print $1; exit }')"
  fi
fi

if [ -z "${SSH_USER}" ]; then
  # SSH user auto-detection:
  # 1. Runs `gcloud config get-value account` to read the active Google login email.
  # 2. Removes everything after @, so `person@example.com` becomes `person`.
  # 3. Converts to lowercase and replaces characters Linux usernames dislike with underscores.
  # This avoids using the Windows local username, which may contain spaces.
  ACTIVE_ACCOUNT="$(run_with_timeout "${GCLOUD_QUICK_TIMEOUT}" gcloud config get-value account 2>/dev/null || true)"
  SSH_USER="$(printf '%s' "${ACTIVE_ACCOUNT%%@*}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9_-]/_/g')"

  if [ -z "${SSH_USER}" ] || [ "${SSH_USER}" = "(unset)" ]; then
    echo "ERROR: Could not automatically detect SSH username."
    echo "Fix: login with gcloud auth login, or set SSH_USER in deploy.env."
    exit 1
  fi
fi

SSH_TARGET="${SSH_USER}@${GCP_INSTANCE}"
# Uses the configured SSH user with the VM instance name for gcloud-managed SSH key sync.

# Source: https://cloud.google.com/sdk/gcloud/reference/compute/instances/describe
# Checks that the selected VM exists, is running, and has an external IP before deployment starts.
echo "Checking VM status..."
VM_INFO="$(run_with_timeout "${GCLOUD_QUICK_TIMEOUT}" gcloud compute instances describe "${GCP_INSTANCE}" \
  --zone "${GCP_ZONE}" \
  --project "${GCP_PROJECT}" \
  --format='value(status,networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"

if [ -z "${VM_INFO}" ]; then
  echo "ERROR: VM not found or not accessible."
  echo "Fix: check GCP_PROJECT, GCP_ZONE, GCP_INSTANCE, and your Google Cloud permissions."
  exit 1
fi

read -r VM_STATUS VM_EXTERNAL_IP <<EOF
${VM_INFO}
EOF

if [ "${VM_STATUS}" != "RUNNING" ]; then
  echo "ERROR: VM is not ready for deployment."
  echo "Expected VM status: RUNNING"
  echo "Actual VM status  : ${VM_STATUS}"
  echo "Fix: start the VM in Google Cloud Console, then run deploy.sh again."
  exit 1
fi

if [ -z "${VM_EXTERNAL_IP}" ]; then
  echo "ERROR: VM has no external public IP address."
  echo "Direct SSH mode requires a public IP so this laptop can connect to port 22."
  echo "Fix: attach an external IP in the VM network settings, then run deploy.sh again."
  exit 1
fi

DIRECT_SSH_TARGET="${SSH_USER}@${VM_EXTERNAL_IP}"
# Uses the VM external IP for direct SSH because the VM instance name is not a DNS hostname.

# Source: https://cloud.google.com/sdk/gcloud/reference/compute/firewall-rules/list
# Checks whether the project has a firewall rule that allows SSH on TCP port 22.
echo "Checking SSH firewall rules..."
SSH_FIREWALL_RULES="$(run_with_timeout "${GCLOUD_QUICK_TIMEOUT}" gcloud compute firewall-rules list \
  --project "${GCP_PROJECT}" \
  --filter='allowed.tcp:22' \
  --format='value(name)' 2>/dev/null || true)"

if [ -z "${SSH_FIREWALL_RULES}" ]; then
  echo "WARNING: The script could not detect a firewall rule allowing TCP port 22."
  echo "Continuing anyway because firewall visibility can be limited by permissions."
  echo "If SSH fails next, confirm an existing rule like default-allow-ssh or allow-direct-ssh allows tcp:22."
else
  echo "Found SSH firewall rule(s):"
  printf '%s\n' "${SSH_FIREWALL_RULES}"
fi

diagnose_ssh_failure() {
  local output="$1"

  if printf '%s\n' "${output}" | grep -qi 'Permission denied\|publickey'; then
    echo "Reason: SSH key/user authentication failed."
    echo "Fix: make sure your Google Cloud account can SSH to this VM, or set SSH_USER correctly in deploy.env."
  elif printf '%s\n' "${output}" | grep -qi 'Connection timed out\|Operation timed out'; then
    echo "Reason: direct SSH port 22 is blocked or silently dropped."
    echo "Fix 1: confirm an existing GCP firewall rule allows tcp:22 from ${SSH_SOURCE_RANGE}."
    echo "Fix 2: if GCP firewall is already correct, try another network/mobile hotspot because VPN/company Wi-Fi may block outbound SSH."
  elif printf '%s\n' "${output}" | grep -qi 'Connection refused'; then
    echo "Reason: the VM is reachable, but SSH service is not accepting connections on port ${SSH_PORT}."
    echo "Fix: check sshd on the VM."
  elif printf '%s\n' "${output}" | grep -qi 'No route to host\|Network is unreachable'; then
    echo "Reason: your laptop/network cannot route to the VM external IP."
    echo "Fix: check internet/VPN/network access to ${VM_EXTERNAL_IP}."
  elif printf '%s\n' "${output}" | grep -qi 'Could not resolve hostname'; then
    echo "Reason: SSH target could not be resolved."
    echo "Fix: this script should use the VM external IP; check VM_EXTERNAL_IP detection."
  else
    echo "Reason: SSH failed, but the exact cause was not matched. Verbose details:"
    printf '%s\n' "${output}"
  fi
}

echo "Auto-syncing Google Cloud SSH keys..."
# Source: https://cloud.google.com/sdk/gcloud/reference/compute/ssh
# Uses gcloud once to add/sync the Google-managed SSH key for the resolved VM user.
if ! KEY_SYNC_OUTPUT="$(run_with_timeout "${GCLOUD_CONNECT_TIMEOUT}" gcloud compute ssh "${SSH_TARGET}" \
  --zone="${GCP_ZONE}" \
  --project="${GCP_PROJECT}" \
  --command="echo 'Keys synced successfully!'" \
  --strict-host-key-checking=no \
  --quiet 2>&1)"; then
  echo "WARNING: Google Cloud SSH key sync did not complete."
  echo "The script will still try direct SSH next and print the real connection error if it fails."
  printf '%s\n' "${KEY_SYNC_OUTPUT}"
else
  printf '%s\n' "${KEY_SYNC_OUTPUT}"
fi

# Source: https://man.openbsd.org/ssh
# Tests direct SSH connectivity with verbose output so failures identify blocked ports, bad keys, or network drops.
echo "Checking SSH connectivity..."
SSH_CHECK_COMMAND=(ssh -i ~/.ssh/google_compute_engine -vvv -p "${SSH_PORT}" \
  -o BatchMode=yes \
  -o ConnectTimeout=45 \
  -o StrictHostKeyChecking=accept-new \
  "${DIRECT_SSH_TARGET}" \
  "echo SSH_OK")

if ! SSH_CHECK_OUTPUT="$(run_with_timeout "${SSH_CHECK_TIMEOUT}" "${SSH_CHECK_COMMAND[@]}" 2>&1)"; then
  echo "ERROR: Could not connect to the VM using direct SSH."
  diagnose_ssh_failure "${SSH_CHECK_OUTPUT}"
  exit 1
fi

echo "GCP instance : ${GCP_INSTANCE}"
echo "SSH target   : ${DIRECT_SSH_TARGET}"
echo "GCP zone     : ${GCP_ZONE}"
echo "GCP project  : ${GCP_PROJECT}"
echo "VM external IP: ${VM_EXTERNAL_IP}"
echo "Install path : ${APP_DIR}"
echo "Service name : ${SERVICE_NAME}"
echo "Direct SSH   : true"
echo "SSH port     : ${SSH_PORT}"
echo "App command  : uvicorn ${APP_MODULE} --host ${APP_HOST} --port ${APP_PORT}"

if [ ! -f "${APP_ENV_FILE}" ]; then
  echo "ERROR: Local env file not found: ${APP_ENV_FILE}"
  echo "Fix: create ${APP_ENV_FILE} from .env.example and fill the real values."
  exit 1
fi

# Source: https://man.openbsd.org/scp
# Copies the local .env file to /tmp first because writing directly to /opt usually needs sudo.
echo "Uploading .env to VM..."
if ! ENV_UPLOAD_OUTPUT="$(run_with_timeout "${GCLOUD_CONNECT_TIMEOUT}" scp -i ~/.ssh/google_compute_engine -P "${SSH_PORT}" "${APP_ENV_FILE}" "${DIRECT_SSH_TARGET}:/tmp/${SERVICE_NAME}.env" 2>&1)"; then
  echo "ERROR: Could not upload .env to the VM."
  diagnose_ssh_failure "${ENV_UPLOAD_OUTPUT}"
  exit 1
fi

REMOTE_DEPLOY_SCRIPT="$(mktemp)"
# Source: https://www.gnu.org/software/coreutils/manual/html_node/mktemp-invocation.html
# Creates a temporary local script file, uploads it, and executes it on the VM.
trap 'rm -f "${REMOTE_DEPLOY_SCRIPT}"' EXIT

cat >"${REMOTE_DEPLOY_SCRIPT}" <<REMOTE_SCRIPT
# Builds the remote install script locally, then uploads and runs it on the VM.
set -euo pipefail

REPO_URL="${REPO_URL}"
APP_DIR="${APP_DIR}"
APP_USER="${APP_USER}"
SERVICE_NAME="${SERVICE_NAME}"
APP_MODULE="${APP_MODULE}"
APP_HOST="${APP_HOST}"
APP_PORT="${APP_PORT}"
SERVICE_FILE="${SERVICE_FILE}"

echo "Running remote deployment on \$(hostname)"

if [ -z "\${APP_USER}" ]; then
  APP_USER="\$(whoami)"
fi
echo "Service user : \${APP_USER}"

# Source: https://git-scm.com/docs/git-clone
# Source: https://git-scm.com/docs/git-pull
# Creates /opt/whatsapp-agent from GitHub if missing; otherwise updates it with git pull.
if [ ! -d "\${APP_DIR}/.git" ]; then
  echo "Repository not found. Cloning into \${APP_DIR}..."
  sudo mkdir -p "\${APP_DIR}"
  sudo chown "\${APP_USER}:\${APP_USER}" "\${APP_DIR}"
  git clone "\${REPO_URL}" "\${APP_DIR}"
else
  echo "Repository exists. Pulling latest code..."
  cd "\${APP_DIR}"
  git pull
fi

cd "\${APP_DIR}"

# Source: https://docs.python.org/3/library/venv.html
# Creates a Python virtual environment inside /opt/whatsapp-agent so runtime tools stay with the app.
if [ ! -d ".venv" ]; then
  python3 -m venv .venv
fi

# Source: https://pip.pypa.io/en/stable/user_guide/#requirements-files
# Installs Python dependencies from requirements.txt into the project virtual environment.
.venv/bin/python -m pip install -r requirements.txt

# Source: https://man7.org/linux/man-pages/man1/install.1.html
# Moves the uploaded env file into /opt/whatsapp-agent/.env with restricted permissions.
sudo install -m 600 -o "\${APP_USER}" -g "\${APP_USER}" "/tmp/\${SERVICE_NAME}.env" "\${APP_DIR}/.env"

# Source: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
# Writes the systemd service so the app runs in the background from /opt/whatsapp-agent.
sudo tee "\${SERVICE_FILE}" >/dev/null <<SERVICE_UNIT
[Unit]
Description=WhatsApp Gemini Agent Service
After=network.target

[Service]
User=\${APP_USER}
WorkingDirectory=\${APP_DIR}
Environment=PATH=\${APP_DIR}/.venv/bin:/usr/bin:/bin
ExecStart=\${APP_DIR}/.venv/bin/uvicorn \${APP_MODULE} --host \${APP_HOST} --port \${APP_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_UNIT

# Source: https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
# Reloads systemd, enables the service on boot, and restarts the app with the new code.
sudo systemctl daemon-reload
sudo systemctl enable "\${SERVICE_NAME}"
sudo systemctl restart "\${SERVICE_NAME}"

echo "Waiting for service startup..."
sleep 5

sudo systemctl status "\${SERVICE_NAME}" --no-pager || {
  echo "Service failed. Showing recent logs..."
  # Source: https://www.freedesktop.org/software/systemd/man/latest/journalctl.html
  # Prints recent service logs for quick debugging when deployment fails.
  journalctl -u "\${SERVICE_NAME}" -n 50 --no-pager
  exit 1
}

echo "Deployment completed successfully."
REMOTE_SCRIPT

# Source: https://man.openbsd.org/scp
# Uploads the generated remote install script to /tmp on the VM.
echo "Uploading remote install script..."
if ! SCRIPT_UPLOAD_OUTPUT="$(run_with_timeout "${GCLOUD_CONNECT_TIMEOUT}" scp -i ~/.ssh/google_compute_engine -P "${SSH_PORT}" "${REMOTE_DEPLOY_SCRIPT}" "${DIRECT_SSH_TARGET}:/tmp/${SERVICE_NAME}-deploy.sh" 2>&1)"; then
  echo "ERROR: Could not upload remote install script to the VM."
  diagnose_ssh_failure "${SCRIPT_UPLOAD_OUTPUT}"
  exit 1
fi

# Source: https://man.openbsd.org/ssh
# Runs the uploaded install script on the VM without manually logging in to the server.
echo "Running remote deployment script..."
if ! REMOTE_DEPLOY_OUTPUT="$(run_with_timeout "${GCLOUD_DEPLOY_TIMEOUT}" ssh -o ServerAliveInterval=60 -i ~/.ssh/google_compute_engine -p "${SSH_PORT}" "${DIRECT_SSH_TARGET}" "bash /tmp/${SERVICE_NAME}-deploy.sh" 2>&1)"; then
  echo "ERROR: Remote deployment failed or timed out."
  printf '%s\n' "${REMOTE_DEPLOY_OUTPUT}"
  exit 1
fi

printf '%s\n' "${REMOTE_DEPLOY_OUTPUT}"
