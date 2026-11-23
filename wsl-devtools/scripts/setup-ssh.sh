#!/usr/bin/env bash
set -e

# --- Configuration ---
KEY_TYPE="ed25519"
SSH_DIR="$HOME/.ssh"
PRIVATE_KEY="$SSH_DIR/id_$KEY_TYPE"
PUBLIC_KEY="$SSH_DIR/id_$KEY_TYPE.pub"

echo "=== 1. Installing and Enabling OpenSSH Server ==="
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh

echo "=== 2. Configuring UFW Firewall ==="
if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow ssh
    echo "Allowed SSH through UFW."
else
    echo "UFW not installed, skipping firewall rule."
fi

echo "=== 3. Setting Up ~/.ssh Directory and Permissions ==="
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

echo "=== 4. Generating SSH Key Pair ==="
if [ -f "$PRIVATE_KEY" ]; then
    echo "SSH key already exists at $PRIVATE_KEY. Skipping generation."
else
    ssh-keygen -t ed25519 -N "" -f "$PRIVATE_KEY"
fi

echo "=== 5. Applying Strict File Permissions ==="
chmod 600 "$PRIVATE_KEY"
if [ -f "$PUBLIC_KEY" ]; then
    chmod 644 "$PUBLIC_KEY"
fi
[ -f "$SSH_DIR/authorized_keys" ] && chmod 600 "$SSH_DIR/authorized_keys"
[ -f "$SSH_DIR/config" ] && chmod 600 "$SSH_DIR/config"

echo "=== 6. Starting SSH Agent & Adding Key ==="
eval "$(ssh-agent -s)"
ssh-add "$PRIVATE_KEY"

echo "========================================================"
echo "Setup complete! Copy the public key below for GitHub:"
echo "--------------------------------------------------------"
cat "$PUBLIC_KEY"
echo "========================================================"
echo "Next step: Paste the key above into GitHub -> Settings -> SSH and GPG keys,"
echo "then run: ssh -T git@github.com"

