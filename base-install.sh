#!/bin/bash
set -euo pipefail

# --- Pre-flight checks -------------------------------------------------------

# OS check: this script targets Debian/Ubuntu (apt-based)
if ! command -v apt-get >/dev/null 2>&1; then
    echo "Error: apt-get not found. This script supports Debian/Ubuntu only." >&2
    exit 1
fi

if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *)
            echo "Error: unsupported OS '${ID:-unknown}'. Tested on Ubuntu / Debian." >&2
            exit 1
            ;;
    esac
fi

# Sudo check: prime credentials up-front so the run is non-interactive afterwards
if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Error: must run as root or have sudo installed." >&2
        exit 1
    fi
    sudo -v || { echo "Error: sudo authentication failed." >&2; exit 1; }
fi

# --- Configuration -----------------------------------------------------------

# System user to create. Override with: TARGET_USER=foo ./base-install.sh
TARGET_USER="${TARGET_USER:-chef}"

# ctop version. Latest release: https://github.com/bcicen/ctop/releases
CTOP_VERSION="${CTOP_VERSION:-0.7.7}"

# Pinned commit of main-caddy-proxy for reproducible installs.
# Update by checking https://github.com/jonaaix/main-caddy-proxy/commits/main
CADDY_PROXY_COMMIT="${CADDY_PROXY_COMMIT:-282186022b75e20588f49cf45e79434df4cb00cc}"

# --- Inputs ------------------------------------------------------------------

read -rp "Email for Let's Encrypt certificate notifications: " USER_EMAIL
if [ -z "$USER_EMAIL" ] || ! [[ "$USER_EMAIL" == *@*.* ]]; then
    echo "Error: a valid email address is required for Caddy / Let's Encrypt." >&2
    exit 1
fi

read -rp "GitHub username to import SSH public keys from (optional, press Enter to skip): " GITHUB_USER
GITHUB_USER="${GITHUB_USER:-}"

read -rp "Hostname for this server (e.g. myacme-prod, optional, press Enter to keep current): " SERVER_HOSTNAME
SERVER_HOSTNAME="${SERVER_HOSTNAME:-}"
if [ -n "$SERVER_HOSTNAME" ] && ! [[ "$SERVER_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    echo "Error: invalid hostname '$SERVER_HOSTNAME'. Use lowercase letters, digits and hyphens (max 63 chars, no leading/trailing hyphen)." >&2
    exit 1
fi

# --- Banner ------------------------------------------------------------------

CYAN=$'\033[1;36m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m' #No Color
cat <<EOF

${CYAN}=============================================================${NC}
${YELLOW}Installation Plan:${NC}
${CYAN}=============================================================${NC}
  Target user      : $TARGET_USER
  Hostname         : ${SERVER_HOSTNAME:-<unchanged>}
  Caddy email      : $USER_EMAIL
  SSH keys from GH : ${GITHUB_USER:-<none>}

Steps:
  1. Create system user '$TARGET_USER'
  2. Install and configure UFW
  3. Update and upgrade all packages
  4. Create a projects directory
  5. Install the z-jump script
  6. Add shell aliases (managed .bashrc block)
  7. Install Docker
  8. Add Docker to UFW rules
  9. Install main-caddy-proxy + docker-autoheal cron${GITHUB_USER:+
 10. Import SSH keys from github.com/$GITHUB_USER}

${CYAN}=============================================================${NC}
EOF

read -rp "Continue? [y/N] " CONFIRM
case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
esac

# Function to print log messages with timestamps
log() {
    LIGHT_BLUE='\033[1;36m'
    NC='\033[0m' # No Color
    echo -e "${LIGHT_BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# Function to print text in green
print_green() {
    GREEN='\033[1;32m'
    NC='\033[0m' # No Color
    echo -e "${GREEN}$1${NC}"
}

# The user's password is generated only when the account is actually created
# (see Step 1), so re-runs never print a password that was never applied.
USERNAME="$TARGET_USER"
PASSWORD=""

# Set hostname (optional; skipped when left blank)
if [ -n "$SERVER_HOSTNAME" ]; then
    log "Setting hostname to '$SERVER_HOSTNAME'."
    sudo hostnamectl set-hostname "$SERVER_HOSTNAME"
    if grep -q "^127.0.1.1" /etc/hosts; then
        sudo sed -i "s/^127.0.1.1.*/127.0.1.1\t$SERVER_HOSTNAME/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$SERVER_HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
    fi
fi

# Step 1: User Creation
log "Step 1: Creating a new default user."

if id "$USERNAME" &>/dev/null; then
    log "User $USERNAME already exists. Skipping creation."
else
    PASSWORD=$(openssl rand -base64 16)
    sudo adduser --disabled-password --gecos "" "$USERNAME"
    echo "$USERNAME:$PASSWORD" | sudo chpasswd
    sudo usermod -aG sudo "$USERNAME"
    log "User '$USERNAME' created."
fi

# Install basics
sudo apt-get update
sudo apt-get install -y unzip htop btop micro nano git curl ssh-import-id

# Install ctop
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
sudo wget -q "https://github.com/bcicen/ctop/releases/download/v${CTOP_VERSION}/ctop-${CTOP_VERSION}-linux-${ARCH}" -O /usr/local/bin/ctop
sudo chmod +x /usr/local/bin/ctop

# Step 2: UFW
log "Step 2: Installing and configuring UFW."
sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow https
sudo ufw route allow proto tcp from any to any port 80
sudo ufw route allow proto tcp from any to any port 443
echo "y" | sudo ufw enable
sudo ufw status

# Step 3: Updates
log "Step 3: Updating and upgrading all packages."
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get autoremove -y

# Step 4: Projects Directory
log "Step 4: Creating directory for projects."
PROJECTS_DIR="/var/www"
sudo usermod -aG www-data $USERNAME

# Check if group exists before adding
if ! getent group docker-www-data >/dev/null; then
    sudo groupadd -g 82 docker-www-data
    sudo useradd -u 82 -g docker-www-data -s /usr/sbin/nologin -r docker-www-data
fi
sudo usermod -aG docker-www-data $USERNAME

sudo mkdir -p $PROJECTS_DIR
sudo chown -R www-data:www-data $PROJECTS_DIR
sudo chmod -R 775 $PROJECTS_DIR

sudo chmod g+s $PROJECTS_DIR

# Step 5: z-jump
log "Step 5: Installing z-jump script."
Z_SCRIPT_PATH="/home/$USERNAME/z.sh"
sudo wget -q https://raw.githubusercontent.com/rupa/z/master/z.sh -O "$Z_SCRIPT_PATH"
sudo chown "$USERNAME:$USERNAME" "$Z_SCRIPT_PATH"

# Step 6: Shell customizations (z-jump + aliases) as an idempotent managed block.
# The block is delimited by markers and rewritten on every run, so re-running
# never duplicates lines and always reflects the latest aliases.
log "Step 6: Writing managed .bashrc block (z-jump + aliases)."
BASHRC="/home/$USERNAME/.bashrc"
sudo touch "$BASHRC"
# Remove a prior managed block, plus any legacy bare z-jump source line left by
# older script versions that appended without markers.
sudo sed -i \
    -e '/^# BEGIN base-install bashrc$/,/^# END base-install bashrc$/d' \
    -e "\|^\. $Z_SCRIPT_PATH\$|d" \
    "$BASHRC"
sudo tee -a "$BASHRC" >/dev/null <<EOF
# BEGIN base-install bashrc
# Managed by base-install.sh — regenerated on every run; edits inside are lost.
. $Z_SCRIPT_PATH
alias ll="ls -la"
alias dc="docker compose"
alias randpw="openssl rand -base64 32 | tr '+/=' '___'"
alias sshkeygen-best="ssh-keygen -t ed25519 -a 100"
# END base-install bashrc
EOF
sudo chown "$USERNAME:$USERNAME" "$BASHRC"

# Step 7: Installing Docker
log "Step 7: Installing Docker."

if command -v docker >/dev/null 2>&1; then
    log "Docker already installed — skipping installation."
else
    # Clean up broken install attempts (ignore errors for packages that aren't installed)
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        sudo apt-get remove -y "$pkg" || true
    done

    # Use official get-docker script
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm get-docker.sh
fi

# Configure logging
DOCKER_CONFIG_FILE="/etc/docker/daemon.json"
sudo mkdir -p /etc/docker
sudo tee $DOCKER_CONFIG_FILE >/dev/null <<EOF
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
sudo systemctl restart docker

# Add user to docker group
sudo usermod -aG docker $USERNAME
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

# Step 8: UFW for Docker
log "Step 8: Adding Docker to UFW rules."
DOCKER_UFW_RULES="/etc/ufw/after.rules"

if ! grep -q "BEGIN UFW AND DOCKER" "$DOCKER_UFW_RULES"; then
    cat <<EOL | sudo tee -a $DOCKER_UFW_RULES
# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16

-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN

-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 172.16.0.0/12

-A DOCKER-USER -j RETURN

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END UFW AND DOCKER
EOL
    sudo systemctl restart ufw
fi

# Step 9: Main Caddy Proxy (pinned commit for reproducibility)
log "Step 9: Installing Docker main-caddy-proxy at $CADDY_PROXY_COMMIT."

# Clone only when missing so re-runs don't wipe an existing proxy checkout.
# To force a fresh pinned checkout, remove /var/www/main-caddy-proxy first.
if [ ! -d "/var/www/main-caddy-proxy" ]; then
    cd /var/www
    sudo git clone https://github.com/jonaaix/main-caddy-proxy.git
    sudo git -C /var/www/main-caddy-proxy checkout "$CADDY_PROXY_COMMIT"
    sudo rm -rf /var/www/main-caddy-proxy/.git
else
    log "main-caddy-proxy already present — keeping existing checkout."
fi

docker network create main-proxy 2>/dev/null || true

sudo sed -i.bak "s/CADDY_DOCKER_EMAIL=[^ ]*/CADDY_DOCKER_EMAIL=$USER_EMAIL/" /var/www/main-caddy-proxy/compose.yaml
sudo rm -f /var/www/main-caddy-proxy/compose.yaml.bak

cd /var/www/main-caddy-proxy && docker compose up -d

# Install docker-autoheal: restart unhealthy containers via cron (every minute)
log "Installing docker-autoheal cron job."
sudo tee /usr/local/bin/docker-autoheal.sh >/dev/null <<'AUTOHEAL'
#!/bin/bash
LOGFILE="/var/log/docker-autoheal.log"
UNHEALTHY=$(docker ps --filter health=unhealthy --format '{{.Names}}')
if [ -n "$UNHEALTHY" ]; then
    for c in $UNHEALTHY; do
        echo "$(date) - Restarting: $c" | tee -a "$LOGFILE"
        docker restart "$c" >> "$LOGFILE" 2>&1
    done
fi
AUTOHEAL
sudo chmod +x /usr/local/bin/docker-autoheal.sh
sudo touch /var/log/docker-autoheal.log
echo "* * * * * root /usr/local/bin/docker-autoheal.sh" | sudo tee /etc/cron.d/docker-autoheal >/dev/null
sudo chmod 644 /etc/cron.d/docker-autoheal

log "Fixing permissions after git clone..."
sudo chown -R www-data:www-data $PROJECTS_DIR
sudo chmod -R 775 $PROJECTS_DIR

# SSH Setup
log "Setting up SSH directory for $USERNAME."
sudo mkdir -p "/home/$USERNAME/.ssh"
sudo chmod 700 "/home/$USERNAME/.ssh"
sudo touch "/home/$USERNAME/.ssh/authorized_keys"
sudo chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
sudo chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"

# Optional: import SSH public keys from a GitHub user
if [ -n "$GITHUB_USER" ]; then
    log "Importing SSH keys from github.com/$GITHUB_USER"
    sudo -u "$USERNAME" ssh-import-id "gh:$GITHUB_USER" \
        || echo "Warning: ssh-import-id failed for gh:$GITHUB_USER (continuing)." >&2
fi

# Add symlink
if [ ! -L "/home/$USERNAME/www" ]; then
    sudo ln -s /var/www "/home/$USERNAME/www"
    sudo chown -h "$USERNAME:$USERNAME" "/home/$USERNAME/www"
fi

log "Setup complete. Displaying credentials."
print_green "Username: $USERNAME"
if [ -n "$PASSWORD" ]; then
    print_green "Password: $PASSWORD"
else
    print_green "Password: (unchanged — user already existed)"
fi

exit 0
