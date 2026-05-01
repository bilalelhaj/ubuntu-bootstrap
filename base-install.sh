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

# --- Banner ------------------------------------------------------------------

CYAN=$'\033[1;36m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m' #No Color
cat <<EOF

${CYAN}=============================================================${NC}
${YELLOW}Installation Steps:${NC}
${CYAN}=============================================================${NC}
1. Create a new default user named 'chef'.
2. Install and configure UFW.
3. Update and upgrade all packages.
4. Create a projects directory and set permissions.
5. Install the z-jump script.
6. Add bash aliases.
7. Install Docker.
8. Add Docker to UFW rules.
9. Install the Docker main-caddy-proxy.

${CYAN}=============================================================${NC}
The installation will begin in 5 seconds...
EOF

sleep 5

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

# Generate a random secure password for the new user
PASSWORD=$(openssl rand -base64 16)
USERNAME="chef"

# Step 1: User Creation
log "Step 1: Creating a new default user."

if id "$USERNAME" &>/dev/null; then
    log "User $USERNAME already exists. Skipping creation."
else
    sudo adduser --disabled-password --gecos "" $USERNAME
    echo "$USERNAME:$PASSWORD" | sudo chpasswd
    sudo usermod -aG sudo $USERNAME
    log "User '$USERNAME' created."
fi

# Install basics
sudo apt-get update
sudo apt-get install -y unzip htop btop micro nano git curl

# Install ctop
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && sudo wget "https://github.com/bcicen/ctop/releases/download/v0.7.7/ctop-0.7.7-linux-$ARCH" -O /usr/local/bin/ctop
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
sudo wget https://raw.githubusercontent.com/rupa/z/master/z.sh -O $Z_SCRIPT_PATH
sudo chown $USERNAME:$USERNAME $Z_SCRIPT_PATH
sudo sh -c "echo . $Z_SCRIPT_PATH >> /home/$USERNAME/.bashrc"

# Step 6: Aliases
log "Step 6: Adding bash aliases."
if ! grep -q "alias dc=" /home/"$USERNAME"/.bashrc; then
    sudo tee -a /home/"$USERNAME"/.bashrc >/dev/null <<'EOF'
alias dc="docker compose"
alias randpw="openssl rand -base64 32 | tr '+/=' '___'"
alias sshkeygen-best="ssh-keygen -t ed25519 -a 100"
EOF
fi

# Step 7: Installing Docker
log "Step 7: Installing Docker."

# Clean up broken install attempts (ignore errors for packages that aren't installed)
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    sudo apt-get remove -y "$pkg" || true
done

# Use official get-docker script
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
rm get-docker.sh

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

# Step 9: Main Caddy Proxy
log "Step 9: Installing Docker main-caddy-proxy."

if [ -d "/var/www/main-caddy-proxy" ]; then
    rm -rf /var/www/main-caddy-proxy
fi

cd /var/www && git clone --depth=1 --branch=main https://github.com/jonaaix/main-caddy-proxy.git
sudo rm -rf /var/www/main-caddy-proxy/.git

cd /var/www/main-caddy-proxy && docker network create main-proxy || true

read -p "Enter your email for certificate notifications: " USER_EMAIL
sudo sed -i "s/CADDY_DOCKER_EMAIL=[^ ]*/CADDY_DOCKER_EMAIL=$USER_EMAIL/" /var/www/main-caddy-proxy/compose.yaml

cd /var/www/main-caddy-proxy && docker compose up -d

log "Fixing permissions after git clone..."
sudo chown -R www-data:www-data $PROJECTS_DIR
sudo chmod -R 775 $PROJECTS_DIR

# SSH Setup (Creating empty folder only)
log "Add SSH base config"
mkdir -p /home/$USERNAME/.ssh
chmod 700 /home/$USERNAME/.ssh
touch /home/$USERNAME/.ssh/authorized_keys
chmod 600 /home/$USERNAME/.ssh/authorized_keys
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh

# Add symlink
if [ ! -L "/home/$USERNAME/www" ]; then
    ln -s /var/www /home/$USERNAME/www
    chown -h $USERNAME:$USERNAME /home/$USERNAME/www
fi

log "Setup complete. Displaying credentials."
print_green "Username: $USERNAME"
print_green "Password: $PASSWORD"

exit 0
