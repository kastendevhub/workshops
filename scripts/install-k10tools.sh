#!/usr/bin/env bash

 # Exit immediately if a command exits with a non-zero status
set -e

echo "Detecting operating system and architecture..."

# Detect OS
OS=$(uname -s)
case "${OS}" in
    Linux*)     OS_STR="linux";;
    Darwin*)    OS_STR="macOS";;
    *)          echo "Error: Unsupported OS '${OS}'"; exit 1;;
esac

# Detect Architecture
ARCH=$(uname -m)
case "${ARCH}" in
    x86_64)          ARCH_STR="amd64";;
    arm64|aarch64)   ARCH_STR="arm64";;
    ppc64le)         ARCH_STR="ppc64le";;
    *)               echo "Error: Unsupported Architecture '${ARCH}'"; exit 1;;
esac

RELEASE="${OS_STR}_${ARCH_STR}"

# Validate against the list of available Kasten releases
case "${RELEASE}" in
    linux_amd64|linux_arm64|linux_ppc64le|macOS_amd64|macOS_arm64)
        echo "Target platform identified: ${RELEASE}"
        ;;
    *)
        echo "Error: No pre-compiled k10tools release available for '${RELEASE}'."
        exit 1
        ;;
esac

# Check for required dependencies
for cmd in helm jq curl tar; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' is not installed or not in PATH."
        exit 1
    fi
done

# Check if kasten helm repo is configured
echo "Checking if Kasten helm repository is configured..."
if ! helm repo list | grep -q kasten; then
    echo "Kasten helm repository not found. Adding it now..."
    helm repo add kasten https://charts.kasten.io/
    helm repo update
fi

echo "Fetching the latest K10 version using helm..."
K10_VERSION=$(helm search repo kasten/k10 --output json | jq -r '.[0].app_version')

if [ -z "${K10_VERSION}" ] || [ "${K10_VERSION}" == "null" ]; then
    echo "Error: Failed to retrieve K10 version. Ensure the kasten/k10 helm repo is added and updated."
    echo "You can add it via: helm repo add kasten https://charts.kasten.io/ && helm repo update"
    exit 1
fi

echo "Downloading k10tools version ${K10_VERSION} for ${RELEASE}..."
DOWNLOAD_URL="https://github.com/kastenhq/external-tools/releases/download/${K10_VERSION}/k10tools_${K10_VERSION}_${RELEASE}.tar.gz"

# Download and extract to /tmp/
curl -sL "${DOWNLOAD_URL}" | tar -xz -C /tmp/ k10tools

echo "Installing k10tools to /usr/local/bin/ (this may prompt for your sudo password)..."
sudo install -m 0755 /tmp/k10tools /usr/local/bin/k10tools

# Clean up the extracted binary from /tmp/ just to be tidy
rm -f /tmp/k10tools

k10tools --version # Verify installation by checking the version

echo "✅ k10tools has been successfully installed!"
