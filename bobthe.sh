#!/bin/bash

# volume mapping
# 1. ${HOME}/src        -> ${HOME}/src
# 2. ${HOME}/opt/<name> -> /opt
# 3. ${PWD}             -> /data


#DEPOT_DIR=${HOME}/depot
DEPOT_DIR=${HOME}

if [ "$(uname -s)" = "Linux" ]; then
    USERID="-u $(id -u):$(id -g)"
    PASSWD_OPT="-u $(id -u):$(id -g) -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro"
else
    USERID="-u ${USER}"
    PASSWD_OPT=
fi

function die ()
{
    echo $*
    exit 1
}

# port mapping
# fak1:  20122 -> 22, 20188-20189 -> 8588-8589
# ...
# fak99: 29922 -> 22, 29988-29989 -> 8588-8589
function get_opts ()
{
    case $1 in
    "fak*")
        IX=$(printf "%d" ${1#fak})
        echo "-p 2${IX}22:22 -p 2${IX}88-2${IX}89:8588-8589 --ip 172.18.100.1${IX}"
        ;;
    *)
        echo ""
        ;;
    esac
}

function usage ()
{
    echo "$(basename $0) new-network | launch <name> | shell <name>"
    [ "$1" = "1" ] && exit 1
}

[ $# -lt 1 ] && usage 1

case "$1" in
"new-network")
    docker network create --subnet 172.18.100.0/24 --gateway 172.18.100.1 bobthe
    ;;
"launch")
    [ $# -lt 2 ] && usage 1
    NAME=$2
    OPTS=$(get_opts ${NAME})
    docker run ${PASSWD_OPT} --network bobthe ${OPTS} \
        -v ${DEPOT_DIR}/src:/home/${USER}/src \
        -v ${DEPOT_DIR}/opt/${NAME}:/opt -v ${PWD}:/data \
        --hostname ${NAME} --name ${NAME} \
        -id metadium/bobthe:latest && \
        docker exec -it -u root ${NAME} /usr/local/bin/meta-start.sh setup-user ${USER}
    ;;
"shell")
    [ $# -lt 2 ] && usage 1
    docker exec -e TERM=xterm-256color -it -u ${USERID} -w /home/${USER} $2 /bin/bash
    ;;
*)
    usage 1
    ;;
esac


# EOF
