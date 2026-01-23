#!/bin/bash

# Print installation steps
CYAN='[1;36m'
YELLOW='[1;33m'
NC='[0m' # No Color
cat <<EOF

${CYAN}=============================================================${NC}
${YELLOW}Installation Steps:${NC}
${CYAN}=============================================================${NC}
1. Create a new default user named 'chef'.
2. Install and configure UFW.
3. Permit root login via SSH.
4. Update and upgrade all packages.
5. Create a projects directory and set permissions for the www-data user.
6. Install the z-jump script.
7. Add bash aliases.
8. Install Docker.
9. Add Docker to UFW rules.
11. Install the Docker main-caddy-proxy and configure it.

${CYAN}=============================================================${NC}
The installation will begin in 10 seconds...
EOF

sleep 10

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

# Define the new user name
USERNAME="chef"

# Start the server setup
log "Step 1: Creating a new default user instead of root."

# Add a new user and set the password
log "Adding user '$USERNAME'."
sudo adduser --disabled-password --gecos "" $USERNAME

# Set the generated password for the user
log "Setting password for user '$USERNAME'."
echo "$USERNAME:$PASSWORD" | sudo chpasswd

# Add the new user to the sudo group
log "Adding user '$USERNAME' to sudo group."
sudo usermod -aG sudo $USERNAME

log "Step 1 completed: New user '$USERNAME' created."

sudo apt-get install -y unzip htop btop micro nano

# Install ctop
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && sudo wget "https://github.com/bcicen/ctop/releases/download/v0.7.7/ctop-0.7.7-linux-$ARCH" -O /usr/local/bin/ctop
sudo chmod +x /usr/local/bin/ctop

# Step 2: Installing and configuring UFW
log "Step 2: Installing UFW."
sudo apt-get install -y ufw

log "Applying UFW rules."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow https
sudo ufw route allow proto tcp from any to any port 80
sudo ufw route allow proto tcp from any to any port 443

log "Enabling UFW."
echo "y" | sudo ufw enable

log "Verifying UFW status."
sudo ufw status

# Step 3: Permit root login via SSH
log "Step 3: Permitting root login via SSH."
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
sudo sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' $SSH_CONFIG_FILE
sudo systemctl restart ssh

log "Root login via SSH permitted."

# Step 4: Update and upgrade all packages
log "Step 4: Updating and upgrading all packages."
sudo apt-get update -y
sudo apt-get upgrade -y

log "Removing unnecessary packages."
sudo apt-get autoremove -y

# Step 5: Create a directory for the projects and add permissions for the www-data user
log "Step 5: Creating a directory for projects and setting permissions."
PROJECTS_DIR="/var/www"

log "Adding user '$USERNAME' to www-data group."
sudo usermod -aG www-data $USERNAME

log "Create user docker-www-data to map www-data (82) to the docker group."
sudo groupadd -g 82 docker-www-data
sudo useradd -u 82 -g docker-www-data -s /usr/sbin/nologin -r docker-www-data
sudo usermod -aG docker-www-data $USERNAME

log "Creating directory '$PROJECTS_DIR'."
sudo mkdir -p $PROJECTS_DIR

log "Setting ownership of '$PROJECTS_DIR' to www-data."
sudo chown -R www-data:www-data $PROJECTS_DIR

log "Setting permissions for '$PROJECTS_DIR'."
sudo chmod -R 775 $PROJECTS_DIR

# Step 6: Install the z-jump script
log "Step 6: Installing z-jump script."
Z_SCRIPT_PATH="/home/$USERNAME/z.sh"

log "Downloading z-jump script to '$Z_SCRIPT_PATH'."
sudo wget https://raw.githubusercontent.com/rupa/z/master/z.sh -O $Z_SCRIPT_PATH

log "Setting ownership of '$Z_SCRIPT_PATH' to user '$USERNAME'."
sudo chown $USERNAME:$USERNAME $Z_SCRIPT_PATH

log "Adding z-jump script to '$USERNAME' bash profile."
sudo sh -c "echo . $Z_SCRIPT_PATH >> /home/$USERNAME/.bashrc"

# Step 7: Adding bash aliases
log "Step 7: Adding bash aliases."
sudo tee -a /home/"$USERNAME"/.bashrc > /dev/null << 'EOF'
alias dc="docker compose"
alias randpw="openssl rand -base64 32 | tr '+/=' '___'"
alias sshkeygen-best="ssh-keygen -t ed25519 -a 100"
EOF


# Step 8: Installing Docker
log "Step 8: Installing Docker."

log "Removing conflicting packages."
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y $pkg
done

log "Setting up Docker's apt repository."
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

log "Adding Docker repository to Apt sources."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

log "Updating package index."
sudo apt-get update

# Step 8.1: Configure Docker daemon logging before installation
log "Configuring Docker daemon logging options."
DOCKER_CONFIG_FILE="/etc/docker/daemon.json"
sudo mkdir -p /etc/docker
sudo tee $DOCKER_CONFIG_FILE > /dev/null <<EOF
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

log "Installing Docker packages."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "Verifying Docker installation by running hello-world image."
sudo docker run hello-world

log "Setting Docker group permissions."
sudo groupadd docker || true
sudo usermod -aG docker $USERNAME

log "Verifying Docker installation by running hello-world as user '$USERNAME'."
sudo -u $USERNAME docker run hello-world

log "Enabling Docker services to start on boot."
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

# Step 9: Add Docker to UFW rules
log "Step 9: Adding Docker to UFW rules."
DOCKER_UFW_RULES="/etc/ufw/after.rules"

log "Appending Docker UFW rules to '$DOCKER_UFW_RULES'."
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

log "Restarting UFW service."
sudo systemctl restart ufw

# Step 11: Install the Docker main-caddy-proxy
log "Step 11: Installing Docker main-caddy-proxy."

log "Cloning main-caddy-proxy repository."
cd /var/www && git clone --depth=1 --branch=main https://github.com/jonaaix/main-caddy-proxy.git

log "Removing Git directory from main-caddy-proxy."
sudo rm -rf /var/www/main-caddy-proxy/.git

log "Creating Docker network for main-caddy-proxy."
cd /var/www/main-caddy-proxy && docker network create main-proxy

log "Prompting user for email for certificate notifications."
read -p "Enter your email for certificate notifications: " USER_EMAIL

log "Updating Docker compose file with user email."
sudo sed -i "s/CADDY_DOCKER_EMAIL=[^ ]*/CADDY_DOCKER_EMAIL=$USER_EMAIL/" /var/www/main-caddy-proxy/compose.yaml

log "Starting Docker main-caddy-proxy container."
cd /var/www/main-caddy-proxy && docker compose up -d

# Setup SSH directory and known_hosts
log "Add SSH base config"
if [ ! -d "/home/$USERNAME/.ssh" ]; then
  mkdir /home/$USERNAME/.ssh
  chmod 700 /home/$USERNAME/.ssh
  chown $USERNAME:$USERNAME /home/$USERNAME/.ssh
fi

if [ ! -f "/home/$USERNAME/.ssh/authorized_keys" ]; then
  touch /home/$USERNAME/.ssh/authorized_keys
  chmod 600 /home/$USERNAME/.ssh/authorized_keys
  chown $USERNAME:$USERNAME /home/$USERNAME/.ssh/authorized_keys
fi

if [ ! -f "/home/$USERNAME/.ssh/config" ]; then
  touch /home/$USERNAME/.ssh/config
  chmod 600 /home/$USERNAME/.ssh/config
  chown $USERNAME:$USERNAME /home/$USERNAME/.ssh/config
fi

# Add symlink from /var/www to ~/www
if [ ! -L "/home/$USERNAME/www" ]; then
  ln -s /var/www /home/$USERNAME/www
fi

# Print the new user credentials in green
log "Setup complete. Displaying credentials."
print_green "Username: $USERNAME"
print_green "Password: $PASSWORD"

# Exit the script
log "Script finished."
exit 0
