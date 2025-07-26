# Client Tools

We need to install all the relevant binaries to your jumpbox (you _could_ install all this locally, but it's just as easy to download them to an ephemeral remote workstation, and saves the need to clean up later).

## Setting up the jumpbox server

First, we need to get the ID of the playground that has the jumpbox.

```sh
JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')
```

and then we need to copy over the file with the installation URLs.

```sh
labctl cp ./downloads.txt $JUMPBOX_PLAYGROUND_ID:~/downloads.txt
```

and now we're ready to jump on there and install some tools.

```sh
wget -q --show-progress \
  --https-only \
  --timestamping \
  -P downloads \
  -i downloads.txt
```
