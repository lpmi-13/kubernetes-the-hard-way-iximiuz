curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.gpg | sudo apt-key add -
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.list | sudo tee /etc/apt/sources.list.d/tailscale.list
sudo apt-get update
sudo apt-get install -y tailscale
sudo systemctl start tailscaled

# this gets overriden when we actually run the commands
sudo tailscale up --authkey=TAILSCALE_AUTH_KEY_PLACEHOLDER
