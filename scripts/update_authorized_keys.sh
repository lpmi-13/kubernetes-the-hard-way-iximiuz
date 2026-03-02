mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

printf '\nPUBLIC_KEY_VALUE\n' >> ~/.ssh/authorized_keys

chmod 600 ~/.ssh/authorized_keys
