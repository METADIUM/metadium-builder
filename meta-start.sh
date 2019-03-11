#!/bin/bash

function setup_user ()
{
    if [ "$1" = "root" ]; then
        return 0;
    elif [ $(id -u) = 0 ]; then
        id $1 > /dev/null 2>&1;
        if [ ! $? = 0 ]; then
            if [ -d "/home/$1" ]; then
                useradd -M -p "$1" "$1"
            else
                useradd -m -p "$1" "$1"
            fi
            chown $1.$1 /home/$1
        fi
        if [ ! -d "/home/$1" -o ! -d "/home/$1/.ssh" ]; then
            mkdir -p /home/$1
            (cd /etc/skel; tar -cf - .) | (cd /home/"$1"; tar -xf -)
        fi
        if [ ! "$(/bin/ls -ld /home/$1/.ssh > /dev/null  2>&1)" = "drwx------" ]; then
            chown $1.$1 /home/$1/
            chown -R $1.$1 /home/$1/.[a-zA-Z]*
            chmod 0700 /home/$1/.ssh
            chmod 0600 /home/$1/.ssh/authorized_keys /home/$1/.ssh/id_rsa.do-not@use
            echo "$1 ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/1-users
        fi
    else
        if [ ! -d "/home/$1" -o ! -d "/home/$1/.ssh" ]; then
            mkdir -p /home/$1
            (cd /etc/skel; tar -cf - .) | (cd /home/"$1"; tar -xf -)
        fi
        if [ ! "$(/bin/ls -ld /home/$1/.ssh > /dev/null  2>&1)" = "drwx------" ]; then
            chown $1.$1 /home/$1/
            chown -R $1.$1 /home/$1/.[a-zA-Z]*
            chmod 0700 /home/$1/.ssh
            chmod 0600 /home/$1/.ssh/authorized_keys /home/$1/.ssh/id_rsa.do-not@use
        fi
    fi
}

case "$1" in
"setup-skel")   # internal command
    grep -q PROMPT_DIRTRIM /etc/skel/.bashrc
    if [ ! $? = 0 ]; then
        echo "PROMPT_DIRTRIM=2;
if [ ! \"\$-\" = \"\${-/i/}\" ]; then
    bind \"\\C-p\":history-search-backward;
    bind '\"\\e[A\":history-search-backward';
    bind \"\\C-n\":history-search-forward;
    bind '\"\\e[B\":history-search-forward';
fi
" >> /etc/skel/.bashrc
        echo "set noswapfile nobackup nowritebackup" >> /etc/skel/.vimrc
        mkdir /etc/skel/.ssh
        chmod 0755 /etc/skel/.ssh
        ssh-keygen -t rsa -b 4096 -C "do-not@use" -q -N "" -f /etc/skel/.ssh/id_rsa.do-not@use
        cp /etc/skel/.ssh/id_rsa.do-not@use.pub /etc/skel/.ssh/authorized_keys
        chmod 0644 /etc/skel/.ssh/*
        (cd /etc/skel/.ssh; ln -sf id_rsa.do-not@use id_rsa)
    fi
    ;;
"setup-user")   # internal command
    if [ ! $# = 2 ]; then
        echo "Usage: meta-start.sh setup-user <user>"
        exit 1
    fi
    setup_user $2
    ;;
"build-image")
    docker build -t metadium/bobthe:0.4 .
    ;;
"truffle")
    shift
    exec /usr/bin/nodejs /data/node_modules/.bin/truffle $*
    ;;
"npm")
    shift
    exec /usr/bin/npm $*
    ;;
"nodejs")
    shift
    exec /usr/bin/nodejs $*
    ;;
"solc")
    shift
    exec /usr/local/bin/solc $*
    ;;
"gmet"|"metadium")
    shift
    exec /opt/meta/bin/gmet $*
    ;;
"make")
    shift
    exec /usr/bin/make $*
    ;;
"sh"|"bash"|"shell"|*)
    shift
    exec /bin/bash $*
    ;;
esac

# EOF
