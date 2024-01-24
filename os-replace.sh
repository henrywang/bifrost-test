#!/bin/bash
set -exuo pipefail

PLATFORM=${PLATFORM:-"openstack"}

TEMPDIR=$(mktemp -d)

# SSH configurations
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=${TEMPDIR}/id_rsa
ssh-keygen -f "${SSH_KEY}" -N "" -q -t rsa-sha2-256 -b 2048
SSH_KEY_PUB="$(cat "${SSH_KEY}".pub)"
SSH_USER="admin"

INSTALL_CONTAINERFILE=${TEMPDIR}/Containerfile.install
UPGRADE_CONTAINERFILE=${TEMPDIR}/Containerfile.upgrade
QUAY_REPO_TAG="${QUAY_REPO_TAG:-$(tr -dc a-z0-9 < /dev/urandom | head -c 4 ; echo '')}"

# Set os-variant and boot location used by virt-install.
case "$TEST_OS" in
    "rhel-9-4")
        IMAGE_NAME="rhel9-rhel_bootc"
        TIER1_IMAGE_URL="${RHEL_REGISTRY_URL}/${IMAGE_NAME}:rhel-9.4"
        ;;
    "centos-stream-9")
        IMAGE_NAME="centos-bootc"
        TIER1_IMAGE_URL="quay.io/centos-bootc/${IMAGE_NAME}:stream9"
        ;;
    "fedora-eln")
        IMAGE_NAME="fedora-bootc"
        TIER1_IMAGE_URL="quay.io/centos-bootc/${IMAGE_NAME}:eln"
        ;;
    *)
        redprint "Variable TEST_OS has to be defined"
        exit 1
        ;;
esac

# Wait for the ssh server up to be.
wait_for_ssh_up () {
    SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${1}" '/bin/bash -c "echo -n READY"')
    if [[ $SSH_STATUS == READY  ]]; then
        echo 1
    else
        echo 0
    fi
}

TEST_IMAGE_NAME="${IMAGE_NAME}-os_replace"
TEST_IMAGE_URL="quay.io/xiaofwan/${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}"

greenprint "Create installation Containerfile"
tee -a "$INSTALL_CONTAINERFILE" > /dev/null < EOF
FROM "$TIER1_IMAGE_URL"
RUN dnf -y install python3 && \
    dnf -y clean all && \
    echo "$SSH_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/admin
EOF

greenprint "Build installation container image"
podman build -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" -f "$INSTALL_CONTAINERFILE"
podman push --creds "${QUAY_USERNAME}:${QUAY_PASSWORD}" "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

greenprint "Deploy $PLATFORM instance and replace os"
ansible-playbook -i inventory -v -e platform="$PLATFORM" -e test_os="$TEST_OS" -e ssh_user="$SSH_USER" -e ssh_key_pub="$SSH_KEY_PUB" -e test_image_url="$TEST_IMAGE_URL" os-replace.yaml

greenprint "Run ostree checking test on $PLATFORM instance"
ansible-playbook -i inventory -v -e platform="$PLATFORM" check-ostree.yaml

greenprint "Create upgrade Containerfile"
tee -a "$UPGRADE_CONTAINERFILE" > /dev/null < EOF
FROM "$TEST_IMAGE_URL"
RUN dnf -y install wget && \
    dnf -y clean all
EOF

greenprint "Build upgrade container image"
podman build -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" -f "$UPGRADE_CONTAINERFILE"
podman push --creds "${QUAY_USERNAME}:${QUAY_PASSWORD}" "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

greenprint "Upgrade system and reboot"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${INSTANCE_ADDRESS}" "sudo bootc upgrade"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${INSTANCE_ADDRESS}" "nohup sudo systemctl reboot &>/dev/null & exit"

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up "$INSTANCE_ADDRESS")"
    if [[ $RESULTS == 1  ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

greenprint "Run ostree checking test on $PLATFORM instance"
ansible-playbook -i inventory -v -e platform="$PLATFORM" check-ostree.yaml
