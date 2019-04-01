#!/bin/bash

# volume mapping
# 1. ${HOME}/src        -> ${HOME}/src
# 2. ${HOME}/opt/<name> -> /opt
# 3. ${PWD}             -> /data


DEPOT_DIR=${HOME}

if [ "$(uname -s)" = "Linux" ]; then
    USERID="$(id -u):$(id -g)"
    PASSWD_OPT="-u ${USERID} -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro"
else
    USERID="${USER}"
    PASSWD_OPT=
fi

function die ()
{
    echo $*
    exit 1
}

# port mapping
# bob1  | fak1:  20122 -> 22, 20188-20189 -> 8588-8589
# ...
# bob99 | fak99: 29922 -> 22, 29988-29989 -> 8588-8589
function get_opts ()
{
    case $1 in
    bob[0-9]*|fak[0-9]*)
	if [ ! "${1#fak}" = "$1" ]; then
            IX=$(printf "%02d" ${1#fak})
	else
            IX=$(printf "%02d" ${1#bob})
	fi
        echo "-p 2${IX}22:22 -p 2${IX}88-2${IX}89:8588-8589 --ip 172.18.100.1${IX}"
        ;;
    *)
        echo ""
        ;;
    esac
}

# bool prep_keys(string docker_instance_name, string dir, string count)
function prep_keys ()
{
    local name=$1
    local dir=$2
    local count=$3
    [ -d "${dir}" ] || die "Cannot find ${dir}"
    [ "$count" = "" -o "$count" -lt 0 ] && die "Invalid count $count"
    [ -d "${dir}/keystore" ] || mkdir -p "${dir}/keystore"

    docker exec -it -u ${USERID} ${name} bash -c "echo password > /tmp/junk"
    for i in $(seq 1 $((${count} + 2))); do
	nn=$(printf "nodekey-%02d" $i)
	kn=$(printf "account-%02d" $i)
	if [ ! -f "${dir}/keystore/${nn}" -a $i -le $count ]; then
	    docker exec -it -u ${USERID} ${name} /opt/meta/bin/gmet metadium new-nodekey --out "/opt/meta/keystore/${nn}" || die "Cannot create a new nodekey ${nn}"
	fi
	if [ ! -f "${dir}/keystore/${kn}" ]; then
	    docker exec -it -u ${USERID} ${name} /opt/meta/bin/gmet metadium new-account --password /tmp/junk --out "/opt/meta/keystore/${kn}" || die "Cannot create a new account ${kn}"
	fi
    done
    docker exec -it -u ${USERID} ${name} /bin/rm /tmp/junk
}

# string get_address(string file_name)
function get_address ()
{
    cat "$1" | sed -e 's/^{"address":"//' -e 's/","crypto".*$//'
}

# string get_docker_ip(string name)
function get_docker_ip ()
{
    docker inspect $1 | awk '/IPAddress.*172.18/ { ip=$2; gsub("\"", "", ip); sub(",", "", ip); print ip; }'
}

# bool setupCluster(string firstNodeName, int minerCount, int nonMinerCount, string tarFile)
# set up a local cluster on bobthe network
function setup_cluster ()
{
    local node_prefix=$1
    local miner_count=$2
    local non_miner_count=$3
    local tar_file=$4
    local dir
    local node_index
    local node_last
    local node_count

    node_prefix=$(echo $1 | awk '{if ((ix=match($0,"[0-9]+$")) == 0) print $0; else print substr($0, 0, ix-1);}')
    node_index=$(echo $1 | awk '{if ((ix=match($0,"[0-9]+$")) == 0) print 1; else print substr($0, ix);}')
    [ "$node_prefix" = "" -o "$node_index" = "" -o "$node_index" -le 0 ] && die "Cannot figure out node prefix and index"

    # sanity checks
    [ "${miner_count}" = "" -o "${miner_count}" -le 0 ] && die "Invalid miner count ${miner_count}"
    [ "${non_miner_count}" = "" -o "${non_miner_count}" -lt 0 ] && die "Invalid non miner count ${miner_count}"
    [ -f "$tar_file" ] || die "Cannot find $tar_file"

    node_count=$(($miner_count + $non_miner_count))
    node_last=$(($node_index + $node_count - 1))

    # set up directories
    sudo mkdir -p ${HOME}/opt
    for i in $(seq $node_index $node_last); do
	dir=${HOME}/opt/${node_prefix}$(printf "%d" $i)
	echo -n "setting up ${dir} directory..."
	sudo mkdir -p ${dir}/meta;
	sudo chown $(id -u):$(id -g) ${dir}/meta
	mkdir -p ${dir}/meta/geth ${dir}/meta/logs
	(cd ${dir}/meta; tar xfz ${tar_file}) || die "Cannot untar ${tar_file} in ${dir}/meta"
	echo "done."
    done

    # launch docker instances
    for i in $(seq $node_index $node_last); do
	local name=${node_prefix}${i}
	docker inspect $name > /dev/null 2>&1
	if [ $? = 0 ]; then
	    echo "${node_prefix}${i}: docker instance already launched..."
	    docker start ${node_prefix}${i}
	else
	    echo "${node_prefix}${i}: launching..."
	    $0 launch ${node_prefix}${i}
	fi
    done

    # set up node ids and keys in the first node
    dir=${HOME}/opt/${node_prefix}$(printf "%d" $node_index)/meta
    echo -n "prepping node ids and keys in ${dir}..."
    prep_keys ${node_prefix}$(printf "%d" ${node_index}) ${dir} $node_count
    echo "done."

    for i in $(seq 1 $node_count); do
	local ddir=${HOME}/opt/${node_prefix}$(printf "%d" $(($node_index + $i - 1)))/meta
	nn=nodekey-$(printf "%02d" $i)
	if [ $i = 1 ]; then
	    echo -n "  ${node_prefix}$(($node_index + $i - 1)): copying node key..."
	    cp -f $dir/keystore/$nn $ddir/geth/nodekey
	else
	    echo -n "  ${node_prefix}$(($node_index + $i - 1)): copying node key and accounts..."
	    cp -f $dir/keystore/$nn $ddir/geth/nodekey
	    cp -rf $dir/keystore $ddir/
	fi
	echo "done."
    done

    # config.json file
    echo -n "creating config.json..."
    local cfg=${dir}/config.json
    local pool
    local maintenance

    echo "{
  \"extraData\": \"Our vision is to create a free world through self-sovereign identity. / When I discover who I am, I'll be free. -- Ralph Ellison, Invisible Man\"," > ${cfg}

    pool=$(get_address ${dir}/keystore/account-$(printf "%02d" $(($node_count + 1))))
    [ $? = 0 ] || die "Cannot get reward pool address"
    maintenance=$(get_address ${dir}/keystore/account-$(printf "%02d" $(($node_count + 1))))
    [ $? = 0 ] || die "Cannot get maintenance address"

    echo "  \"pool\": \"0x${pool}\"," >> ${cfg}
    echo "  \"maintenance\": \"0x${maintenance}\"," >> ${cfg}

    # members
    echo "  \"members\": [" >> ${cfg}
    for i in $(seq 1 $miner_count); do
	local name=${node_prefix}$(printf "%d" $(($node_index + $i - 1)))
	local ddir=${HOME}/opt/${name}/meta
	local nn=${ddir}/geth/nodekey
	local kn=${ddir}/keystore/account-$(printf "%02d" $i)
	local addr=$(get_address $kn)
	[ $? = 0 ] || die "Cannot get the address of $kn"
	local id=$(docker exec -it -u ${USERID} ${name} /opt/meta/bin/gmet metadium nodeid /opt/meta/geth/nodekey | awk '/^idv5/ {id=$2; gsub("\r","",id); gsub("\n","",id); print id}')
	[ $? = 0 ] || die "Cannot get the node id of $nn"
	local ip=$(get_docker_ip $name) || die "Cannot get the IP address of $name"
	[ $? = 0 ] || die "Cannot get IP address of $name"
	local bootnode=
	[ $i = 1 ] && bootnode=",
      \"bootnode\": true"
	local comma=
	[ $i = $miner_count ] || comma=,

	echo "    {
      \"addr\": \"0x${addr}\",
      \"stake\": 1000000,
      \"name\": \"${name}\",
      \"ip\": \"${ip}\",
      \"port\": 8589,
      \"id\": \"0x${id}\"${bootnode}
    }${comma}" >> ${cfg}
    done

    echo "  ],
  \"accounts\": [" >> ${cfg}

    # accounts
    for i in $(seq 1 $(($node_count + 2))); do
	local ddir=${HOME}/opt/${node_prefix}${node_index}/meta
	local kn=${ddir}/keystore/account-$(printf "%02d" $i)
	local addr=$(get_address $kn)
	local comma=
	[ $i = $(($node_count + 2)) ] || comma=,
	echo "    {
      \"addr\": \"0x${addr}\",
      \"balance\": 10000000000000000000000000000
    }${comma}" >> ${cfg}
    done

    echo "  ]
}" >> ${cfg}
    echo "done."

    # stop and wipe data
    echo -n "stop and wiping data..."
    for i in $(seq $node_index $node_last); do
	docker exec -it -u ${USERID} ${node_prefix}${i} bash -c '/opt/meta/bin/gmet.sh stop; /opt/meta/bin/gmet.sh wipe;'
    done
    echo "done."

    # start gmet in the first instance
    echo "initializing gmet in ${node_prefix}${node_index}..."
    docker exec -it -u ${USERID} ${node_prefix}${node_index} /opt/meta/bin/gmet.sh init meta /opt/meta/config.json || die "Init failed"

    echo "starting gmet in ${node_prefix}${node_index}..."
    docker exec -it -u ${USERID} ${node_prefix}${node_index} /usr/bin/nohup /opt/meta/bin/gmet.sh start > /dev/null 2>&1

    echo "giving gmet 3 seconds to start..."
    sleep 3

    # initialize governance
    echo "initializing governance"
    docker exec -it -u ${USERID} ${node_prefix}${node_index} /opt/meta/bin/gmet.sh init-gov meta /opt/meta/config.json /opt/meta/keystore/account-01 || die "Governance initialization failed"

    # run admin.etcdInit() if governance is initialized
    echo -n "initializing etcd..."
    out=$(docker exec -it -u ${USERID} ${node_prefix}${node_index} /opt/meta/bin/gmet attach ipc:/opt/meta/geth.ipc --exec '(function() { for (var i=0; i<120; i++) { if (admin.metadiumInfo && admin.metadiumInfo.self) { admin.etcdInit(); return true; } else { admin.sleep(1) } } return false; })()')
    [ "${out#true}" = "$out" ] || die "admin.etcdInit() seemed failed: ${out}".
    echo "done."

    # start gmet in the other instances
    for i in $(seq 2 $node_count); do
	local ix=$(printf "%d" $(($node_index + $i - 1)))
	local name=${node_prefix}${ix}
	local ddir=${HOME}/opt/${name}/meta

	# copy genesis.json
	cp ${dir}/genesis.json ${ddir}/genesis.json

	# copy .ethash
	if [ ! -d "${ddir}/.ethash" -o ! -f "${ddir}/.ethash/full-R23-0000000000000000" ]; then
	    mkdir -p "${ddir}/.ethash"
	    rsync -a "${dir}/.ethash/full-R23-0000000000000000" "${ddir}/.ethash/full-R23-0000000000000000"
	fi

	# setup .rc
	if [ $i -le $miner_count ]; then
	    cp ${dir}/.rc ${ddir}/.rc
	else
	    local name=${node_prefix}${node_index}
	    local nn=${ddir}/geth/nodekey
	    local id=$(docker exec -it -u ${USERID} ${name} /opt/meta/bin/gmet metadium nodeid /opt/meta/geth/nodekey | awk '/^idv5/ {id=$2; gsub("\r","",id); gsub("\n","",id); print id}')
	    [ $? = 0 ] || die "Cannot get the node id of $nn"
	    local ip=$(get_docker_ip $name) || die "Cannot get the IP address of $name"
	    [ $? = 0 ] || die "Cannot get IP address of $name"

	    echo "PORT=8588
BOOT_NODES=enode://${id}@${ip}:8589
DISCOVER=1" > ${ddir}/.rc
	fi

	# start
	echo -n "starting gmet in ${node_prefix}${ix}..."
	docker exec -it -u ${USERID} ${node_prefix}${ix} /usr/bin/nohup /opt/meta/bin/gmet.sh start > /dev/null 2>&1 || die "Cannot start gmet in ${node_prefix}${ix}"
	echo "done."
    done

    # make sure all the miners are up and running
    echo "checking if all the miners are up and running (will take a few minutes)..."
    docker exec -it -u ${USERID} ${node_prefix}${node_index} /opt/meta/bin/gmet attach ipc:/opt/meta/geth.ipc --exec '(function() { var etcdcnt=0; for (var i=0; i <= 300; i++) { if (etcdcnt != admin.metadiumInfo.etcd.members.length) { console.log("  miners=" + admin.metadiumInfo.nodes.length + " vs. etcd-connected=" + (etcdcnt=admin.metadiumInfo.etcd.members.length)); } if (admin.metadiumInfo.etcd.members.length == admin.metadiumInfo.nodes.length) return true; else admin.sleep(1); } return false; })()'
    local out=$(docker exec -it -u ${USERID} ${node_prefix}${node_index} /opt/meta/bin/gmet attach ipc:/opt/meta/geth.ipc --exec 'return admin.metadiumInfo.etcd.members.length == admin.metadiumInfo.nodes.length')
    [ "${out#true}" = "$out" ] || die "  miner network might not be up: $out".

    echo "All is good."
    return 0
}

function usage ()
{
    echo "$(basename $0) new-network | launch <name> | launch-host <name> [port] | shell <name>
	setup-cluster <first-node> <miner-count> <non-miner-count> <tar-file>"
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
        docker exec -it -u root ${NAME} /usr/local/bin/meta-start.sh setup-user ${USER} && \
        docker exec -it -u root ${NAME} service ssh start
    ;;
"launch-host")
    [ $# -lt 2 ] && usage 1
    [ $# -gt 2 ] && PORT=$3
    NAME=$2
    docker run ${PASSWD_OPT} --network host ${OPTS} \
        -v ${DEPOT_DIR}/src:/home/${USER}/src \
        -v ${DEPOT_DIR}/opt/${NAME}:/opt -v ${PWD}:/data \
        --hostname ${NAME} --name ${NAME} \
        -id metadium/bobthe:latest && \
        docker exec -it -u root ${NAME} /usr/local/bin/meta-start.sh setup-user ${USER} && \
        docker exec -it -u root ${NAME} /bin/bash -c 'echo "127.0.0.1 '${NAME}'" >> /etc/hosts'
    if [ ! "$PORT" = "" ]; then
        docker exec -it -u root ${NAME} /bin/sed -ie 's/^#Port 22/Port '$(($PORT-1))'/' /etc/ssh/sshd_config && \
            docker exec -it -u root ${NAME} service ssh start
    fi
    ;;
"setup-cluster")
    shift
    [ $# = 4 ] || usage 1
    setup_cluster $*
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
