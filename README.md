# Metadium Builder

## Docker Image: `metadium/bobthe`

`metadium/bobthe:latest` is the image name in the Docker repository. The following command builds the same image that's uploaded.

    $ docker build -t <tag> .

This image is used for following purposes

* To build the semi-official ubuntu `go-metadium` build using `make gmet-linux`.
* To compile `solidity` when `solc` is not installed or on non-linux systems. Just like `solc` docker image.
* As `nodejs` and `truffle` image when `nodejs` is not available.
* To build `go-metadium` docker cluster for test purposes.

## Build the Semi-official `Ubuntu` Image

In `go-metadium` directory, running the following

    $ make gmet-linux

creates the semi-official `ubuntu` image that we use in the Metadium mainnet.

## Local `go-metadium` cluster

The following command will create `docker-compose.yml` in the given directory, and copy `bobthe.sh` and `rc.js` in the `bin` directory under it. The example below creates three miners, named `bob10`, `bob11` and `bob12`, and one non-mining full node, named `bob13`.

    $ ./bobthe.sh setup-cluster [-d <dir> -f <first-node> -m <miner-count> -n <non-miner-count> -a <metadium-tarfile>
    e.g.
    $ ./bobthe.sh setup-cluster -d /data/regression -f bob10 -m 3 -n 1 -a metadium.tar.gz

Once `docker-compose.yml` is ready, run `docker-compose` as follows

    $ docker-compose up -d

and check the logs using

    $ docker-compose lofs -f

Once `All is good` is shown, the network is good to go.

To stop it

    $ docker-compose down

## `go-metadium` cluster over multiple hosts using `host` network

&lt;TBD&gt;

## Automated Build and Regression / Stress Test

`meta-builder.py` is the very rough-around-edges script to do automated build. It does

* check if there's any update in `go-metadium`
* if any, `git clone` `go-metadium`, then build
* initialize a 4 node cluster, including the governance contracts
* send 1,000 transactions
* save the result in `db.json` file.

To set it up, copy `meta-builder.py`, `bobthe.sh` and `rc.js` in `bin` directory under build directory. For example,

    $ mkdir -p /data/meta-build/bin
    $ cp meta-builder.py bobthe.sh rc.js /data/meta-build/bin/

To start a new build

    $ /data/meta-build/bin/meta-builder.py build <directory> <repository> <branch>
    e.g.
    $ /data/meta-build/bin/meta-builder.py build /data/meta-build https://github.com/metadium/go-metadium master

Logs go to `<dir>/logs/log.<build-number>`, which is `symlink`'ed to `<dir>/log`.

To run it regularly, set up `crontab` something like the following

    $ crontab -e
    0,10,20,30,40,50 * * * * PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin /data/meta-build/bin/meta-builder.py build /data/meta-build github.com:/metadium/go-metadium master
    5,15,25,35,45,55 * * * * PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin /data/meta-build/bin/meta-builder.py build /data/meta-build github.com:/metadium/go-metadium <other-branch>

Only one session is allowed to run at any given time.

If you want to run tests with the existing image,

    $ /data/meta-build/bin/meta-builder.py run-tests <dir> <metadium-tar.gz>
    e.g.
    $ /data/meta-build/bin/meta-builder.py run-tests /data/meta-build metadium-tar.gz

## `bobthe.sh` commands

To create `bobthe` docker bridge network

    $ bobthe.sh new-network

To create a new docker container

    $ bobthe.sh launch <name>

If `<name>` is `bob[0-9]+` or `fak[0-9]+`, it's going to assign pre-determined ip addresses and published ports. Ip address is `172.18.100.1<index>`, and port mappings are `2<index>22` -> `22` and `2<index>88-89` -> `8588-89`.e.g `bob50` is going to get `172.18.100.150` and port mappings of `25022` -> `22` and `25088-25089` -> `8588-8589`.

User settings are replicated in the container as well to avoid jumbled `uid`s in files created by the container.

Volume mappings are as follows

    /home/<user>/src        -> /home/<user>/src
    /home/<user>/opt/<name> -> /opt
    .                       -> /data

To access shell using `docker exec` as the current user, not as `root`

    $ bobthe.sh shell <name>
