# SteamOS 3.0 Btrfs converter (Experimental)

This injector will install the necessary payload to keep a btrfs formatted /home even through system updates (hopefully).
It will allow to mount btrfs formatted sd cards and will also force new sd cards to be formatted as btrfs.

Btrfs with its transparent compression and deduplication capabilities can achieve impressive storage gains but also improve loading times because of less data being read.

**WARNING!!!! It will install a service that will attempt on the next boot to convert the ext4 /home partition into btrfs and depending on the already used storage this operation may fail or take a long time!**

- https://wiki.archlinux.org/title/Btrfs

## Install

(CAUTION: there's no way back if you do this! Unless you reinstall with the recovery image.)

### From SteamOS

Switch into Desktop mode, download the tarball from https://gitlab.com/popsulfr/steamos-btrfs/-/archive/main/steamos-btrfs-main.tar.gz, extract it and launch `./install.sh`

or by opening a terminal and executing

```
mkdir steamos-btrfs
curl -sSL https://gitlab.com/popsulfr/steamos-btrfs/-/archive/main/steamos-btrfs-main.tar.gz | tar -xzf - -C steamos-btrfs --strip-components=1
sudo ./steamos-btrfs/install.sh
```

### From the SteamOS Recovery image

#### Do you want to reimage SteamOS from scratch on your Steam Deck ?

Then the installation is the same as above. The repair script will be patched to format /home as btrfs during the reimaging of SteamOS.

```
sudo ~/tools/repair_reimage.sh
```

#### Do you want to inject the btrfs payload into an SteamOS installation from the Recovery image ?

When invoking the install script supply the rootfs device node as first argument to prevent it from injecting into the Recovery image.

```
sudo ./steamos-btrfs/install.sh /dev/disk/by-partsets/A/rootfs
sudo ./steamos-btrfs/install.sh /dev/disk/by-partsets/B/rootfs
```

(Do the installation twice for both slots)

## Uninstall

TODO

## Btrfs mount options

The following mount options are used:

- `noatime,lazytime`: to keep writes to a minimum
- `compress-force=zstd`: force zstd compression always on. zstd is smart enough to do the right thing on uncompressible data, works better and achieves better results than the normal heuristics for compression.
- `space_cache=v2`: make sure the newer implementation is used
- `autodefrag`: small random writes are queued up for defragmentation
- `subvol=@`: by default it will create a subvolume `@` which is used as real root of the filesystem. SD Cards formatted as btrfs will be searched for the `@` subvolume or fallback to `/`.

## Deduplication

TODO

## TODO

- [ ] Signal btrfs conversion progress using plymouth
- [ ] Make it more robust in many different situations
- [ ] Test more
- [ ] Test with real Steam Deck
