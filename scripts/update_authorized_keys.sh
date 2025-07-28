chmod 600 ~/.ssh/authorized_keys

printf '\nPUBLIC_KEY_VALUE\n' >> ~/.ssh/authorized_keys

chmod 400 ~/.ssh/authorized_keys
