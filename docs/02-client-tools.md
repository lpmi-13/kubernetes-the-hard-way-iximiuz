# Client Tools

We need to install all the relevant binaries to your jumpbox (you _could_ install all this locally, but it's just as easy to download them to an ephemeral remote workstation, and saves the need to clean up later).

## Setting up the jumpbox server

```sh
labctl playground start ubuntu-22-04
```
and then we need to copy over the file with the installation URLs.

```
labctl cp ./downloads.txt $(labctl playground list | grep 22 | awk '{print $1}'):~/downloads.txt
```
wget -q --show-progress \
  --https-only \
  --timestamping \
  -P downloads \
  -i downloads.txt
```
