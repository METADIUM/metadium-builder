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

# bool setup_cluster_old(string firstNodeName, int minerCount, int nonMinerCount, string tarFile)
# set up a local cluster on bobthe network
function setup_cluster_old ()
{
    local node_prefix=$1
    local miner_count=$2
    local non_miner_count=$3
    local tar_file=$4
    local dir
    local node_index
    local node_last
    local node_count

    node_prefix=$(echo $1 | awk '{if ((ix=match($0,"[0-9]+$")) == 0) print $0; else print substr($0, 1, ix-1);}')
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
#    docker exec -it -u ${USERID} ${node_prefix}${node_index} /opt/meta/bin/gmet attach http://localhost:8588 --preload "/opt/meta/conf/MetadiumGovernance.js,/opt/meta/conf/deploy-governance.js" --exec 'GovernanceDeployer.deploy("/opt/meta/keystore/account-01", "password", "/opt/meta/config.json")' || die "Governance initialization failed"
    docker exec -it -u ${USERID} ${node_prefix}${node_index}		\
	/bin/bash -c 'echo password > /tmp/junk &&			\
/opt/meta/bin/gmet metadium deploy-governance --gas 0xF000000		\
    --gasprice 80000000000 --url http://localhost:8588			\
    --password /tmp/junk /opt/meta/conf/MetadiumGovernance.js		\
    /opt/meta/config.json /opt/meta/keystore/account-01;		\
    EC=$?; rm /tmp/junk; exit $EC' || die "Governance initialization failed"

    # run admin.etcdInit() if governance is initialized
    echo -n "initializing etcd..."
    out=$(docker exec -it -u ${USERID} ${node_prefix}${node_index} /opt/meta/bin/gmet attach ipc:/opt/meta/geth.ipc --exec '(function() { for (var i=0; i<120; i++) { if (admin.metadiumInfo && admin.metadiumInfo.self) { admin.etcdInit(); return true; } else { admin.sleep(1) } } return false; })()')
    [ "${out%true}" = "$out" ] || die "admin.etcdInit() seemed failed: ${out}".
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
    out=$(docker exec -it -u ${USERID} ${node_prefix}${node_index} /opt/meta/bin/gmet attach ipc:/opt/meta/geth.ipc --exec 'admin.metadiumInfo.etcd.members.length == admin.metadiumInfo.nodes.length')
    [ "${out/true}" = "${out}" ] && die "Metadium network might not be up: ${out}"

    echo "All is good."
    return 0
}

#
# cluster commands
#

# bool prep_inner_keys(string count)
function prep_inner_keys ()
{
    local count=$1
    [ "$count" = "" -o "$count" -lt 0 ] && die "Invalid count $count"
    [ -d "/opt/meta/keystore" ] || mkdir -p "/opt/meta/keystore"

    for i in $(seq 1 $((${count} + 2))); do
	nn=$(printf "nodekey-%02d" $i)
	kn=$(printf "account-%02d" $i)
	if [ ! -f "/opt/meta/keystore/${nn}" -a $i -le $count ]; then
	    /opt/meta/bin/gmet metadium new-nodekey --out "/opt/meta/keystore/${nn}" || die "Cannot create a new nodekey ${nn}"
	fi
	if [ ! -f "/opt/meta/keystore/${kn}" ]; then
	    /opt/meta/bin/gmet metadium new-account --password <(echo password) --out "/opt/meta/keystore/${kn}" || die "Cannot create a new account ${kn}"
	fi
    done
}

# string get_inner_address(string file_name)
function get_inner_address ()
{
    cat "$1" | sed -e 's/^{"address":"//' -e 's/","crypto".*$//'
}

# bool setup_inner_cluster(string firstNodeName, int minerCount, int nonMinerCount, string tarFile)
# set up a local cluster on bobthe network
# 1. runs inside the first instance
# 2. directory mapping
#   . -> /data
#   ./<name> -> /opt/meta
#   * i.e. can access other nodes's /opt/meta using /data/<name>
# 3. IP address mapping: <name><index> -> 172.18.100.(200 + <index>)
function setup_inner_cluster ()
{
    local ip_prefix=172.18.100.
    local ip_start=200
    local node_prefix=$1
    local miner_count=$2
    local non_miner_count=$3
    local tar_file=$4
    local dir
    local node_index
    local node_last
    local node_count

    node_prefix=$(echo $1 | awk '{if ((ix=match($0,"[0-9]+$")) == 0) print $0; else print substr($0, 1, ix-1);}')
    node_index=$(echo $1 | awk '{if ((ix=match($0,"[0-9]+$")) == 0) print 1; else print substr($0, ix);}')
    [ "$node_prefix" = "" -o "$node_index" = "" -o "$node_index" -le 0 ] && die "Cannot figure out node prefix and index"

    # sanity checks
    [ "${miner_count}" = "" -o "${miner_count}" -le 0 ] && die "Invalid miner count ${miner_count}"
    [ "${non_miner_count}" = "" -o "${non_miner_count}" -lt 0 ] && die "Invalid non miner count ${miner_count}"
    [ -f "$tar_file" ] || die "Cannot find $tar_file"

    node_count=$(($miner_count + $non_miner_count))
    node_last=$(($node_index + $node_count - 1))

    # set up directories
    for i in $(seq $node_index $node_last); do
	dir=/data/${node_prefix}$(printf "%d" $i)
	echo "setting up ${dir} directory..."
	sudo chown $(id -u):$(id -g) ${dir}
	mkdir -p ${dir}/geth ${dir}/logs
	ln -sf /data/rc.js ${dir}/
	(cd ${dir}; tar xfz ${tar_file}) || die "Cannot untar ${tar_file} in ${dir}"
    done

    # set up node ids and keys in the first node
    dir=/data/${node_prefix}$(printf "%d" $node_index)
    echo "prepping node ids and keys..."
    prep_inner_keys $node_count

    for i in $(seq 0 $(($node_count - 1))); do
	local ddir=/data/${node_prefix}$(printf "%d" $(($node_index + $i)))
	nn=nodekey-$(printf "%02d" $(($i + 1)))
	if [ $i = 0 ]; then
	    echo "  ${node_prefix}$(($node_index + $i)): copying node key..."
	    cp -f $dir/keystore/$nn $ddir/geth/nodekey
	else
	    echo "  ${node_prefix}$(($node_index + $i)): copying node key and accounts..."
	    cp -f $dir/keystore/$nn $ddir/geth/nodekey
	    cp -rf $dir/keystore $ddir/
	fi
    done

    # config.json file
    echo "creating config.json..."
    local cfg=/opt/meta/config.json
    local pool
    local maintenance

    echo "{
  \"extraData\": \"Our vision is to create a free world through self-sovereign identity. / When I discover who I am, I'll be free. -- Ralph Ellison, Invisible Man\"," > ${cfg}

    pool=$(get_inner_address ${dir}/keystore/account-$(printf "%02d" $(($node_count + 1))))
    [ $? = 0 ] || die "Cannot get reward pool address"
    maintenance=$(get_address ${dir}/keystore/account-$(printf "%02d" $(($node_count + 1))))
    [ $? = 0 ] || die "Cannot get maintenance address"

    echo "  \"pool\": \"0x${pool}\"," >> ${cfg}
    echo "  \"maintenance\": \"0x${maintenance}\"," >> ${cfg}

    # members
    echo "  \"members\": [" >> ${cfg}
    for i in $(seq 0 $(($miner_count - 1))); do
	local name=${node_prefix}$(printf "%d" $(($node_index + $i)))
	local ddir=/data/${name}
	local nn=${ddir}/geth/nodekey
	local kn=${ddir}/keystore/account-$(printf "%02d" $(($i + 1)))
	local addr=$(get_inner_address $kn)
	[ $? = 0 ] || die "Cannot get the address of $kn"
	local id=$(/opt/meta/bin/gmet metadium nodeid ${nn} | awk '/^idv5/ {id=$2; gsub("\r","",id); gsub("\n","",id); print id}')
	[ $? = 0 ] || die "Cannot get the node id of $nn"
	local ip=${ip_prefix}$(printf "%d" $(($ip_start + $node_index + $i)))
	local bootnode=
	[ $i = 0 ] && bootnode=",
      \"bootnode\": true"
	local comma=
	[ $i = $(($miner_count - 1)) ] || comma=,

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
	local ddir=/data/${node_prefix}${node_index}
	local kn=${ddir}/keystore/account-$(printf "%02d" $i)
	local addr=$(get_inner_address $kn)
	local comma=
	[ $i = $(($node_count + 2)) ] || comma=,
	echo "    {
      \"addr\": \"0x${addr}\",
      \"balance\": 10000000000000000000000000000
    }${comma}" >> ${cfg}
    done

    echo "  ]
}" >> ${cfg}

    # stop and wipe data
    echo "stopping if gmet is running..."
    /opt/meta/bin/gmet.sh stop > /dev/null 2>&1
    sleep 2

    # start gmet in the first instance
    echo "initializing gmet in ${node_prefix}${node_index}..."
    [ -d /data/.ethash ] && cp -r /data/.ethash /opt/meta/
    /opt/meta/bin/gmet.sh init meta /opt/meta/config.json || die "Init failed"

    # prepare gmet in the other instances
    for i in $(seq 1 $(($node_count - 1))); do
	local ix=$(printf "%d" $(($node_index + $i)))
	local name=${node_prefix}${ix}
	local ddir=/data/${name}

	# copy genesis.json
	cp ${dir}/genesis.json ${ddir}/genesis.json

	# copy .ethash
	if [ ! -d "${ddir}/.ethash" -o ! -f "${ddir}/.ethash/full-R23-0000000000000000" ]; then
	    mkdir -p "${ddir}/.ethash"
	    cp "${dir}/.ethash/full-R23-0000000000000000" "${ddir}/.ethash/full-R23-0000000000000000"
	fi

	# setup .rc
	if [ $i -lt $miner_count ]; then
	    cp ${dir}/.rc ${ddir}/.rc
	else
	    local id=$(/opt/meta/bin/gmet metadium nodeid ${dir}/geth/nodekey | awk '/^idv5/ {id=$2; gsub("\r","",id); gsub("\n","",id); print id}')
	    [ $? = 0 ] || die "Cannot get the node id of $nn"
	    local ip=${ip_prefix}$(printf "%d" $(($ip_start + $node_index)))
	    echo "PORT=8588
BOOT_NODES=enode://${id}@${ip}:8589
DISCOVER=1" > ${ddir}/.rc
	fi
    done

    echo "starting gmet in ${node_prefix}${node_index}..."
    /opt/meta/bin/gmet.sh start

    echo "waiting for gmet to get ready..."
    for i in $(seq 1 10); do
	curl http://localhost:8588 > /dev/null 2>&1 && break
	sleep 1
    done
    sleep 3

    # initialize governance
    echo "initializing governance"
#    docker exec -it -u ${USERID} ${node_prefix}${node_index} /opt/meta/bin/gmet attach http://localhost:8588 --preload "/opt/meta/conf/MetadiumGovernance.js,/opt/meta/conf/deploy-governance.js" --exec 'GovernanceDeployer.deploy("/opt/meta/keystore/account-01", "password", "/opt/meta/config.json")' || die "Governance initialization failed"
    /opt/meta/bin/gmet metadium deploy-governance --gas 0xF000000	 \
	--gasprice 80000000000 --url http://localhost:8588		 \
	--password <(echo password) /opt/meta/conf/MetadiumGovernance.js \
	/opt/meta/config.json /opt/meta/keystore/account-01 ||		 \
	die "Governance initialization failed"

    # run admin.etcdInit() if governance is initialized
    echo "initializing etcd..."
    /opt/meta/bin/gmet attach ipc:/opt/meta/geth.ipc --preload /data/rc.js \
	--exec "init_etcd(120)" 2>&1 | tee /tmp/junk
    out=$(cat /tmp/junk)
    [ "${out/true}" = "${out}" ] && die "admin.etcdInit() failed: ${out}"

    # make sure all the miners are up and running
    echo "checking if all the miners are up and running (will take a few minutes)..."
    /opt/meta/bin/gmet attach ipc:/opt/meta/geth.ipc --preload /data/rc.js \
	--exec "check_all_miners(300)" | tee /tmp/junk
    out=$(cat /tmp/junk)
    [ "${out/true}" = "${out}" ] && die "Metadium network might not be up: ${out}"

    echo "All is good."
    return 0
}

# initialize & start gmet
# bool cluster_leader <options...>
# options:
#   -r:                   reinitialize the cluster
#   -f <name>:            first cluster name, i.e. bob80
#   -m <count>:           mining member count
#   -n <count>:           non-mining member count
#   -a <metadium.tar.gz>: metadium.tar.gz location: /data/metadium.tar.gz
function cluster_leader ()
{
    if [ ! "$HOST_USER" = "" -a ! "$HOST_USER" = "$(id -un)" ]; then
	/usr/local/bin/meta-start.sh setup-user ${HOST_USER}
	exec sudo -H -u ${HOST_USER} $0 cluster-leader $*
    fi

    args=$(getopt a:f:m:n:r $*)
    local do_init=0
    local node_name=
    local miner_count=0
    local non_miner_count=0
    local tar_file=/data/metadium.tar.gz

    set -- $args
    for i; do
	case "$i" in
	-r)
	    do_init=1
	    shift;;
	-f)
	    node_name=$2
	    shift 2;;
	-m)
	    miner_count=$2
	    shift 2;;
	-n)
	    non_miner_count=$2
	    shift 2;;
	-a)
	    tar_file=$2
	    shift 2;;
	esac
    done

    [ "$node_name" = "" -o "$miner_count" -le 0 -o ! -f "${tar_file}" ] && \
	usage 1
    if [ $do_init = 0 ]; then
	[ ! -f /opt/meta/.rc -o ! -d /opt/meta/geth/chaindata ] && do_init=1
    fi
    if [ $do_init = 1 ]; then
	setup_inner_cluster $node_name $miner_count $non_miner_count \
	    $tar_file || die "Cluster setup failed."
    else
	/opt/meta/bin/gmet.sh start meta
    fi

    exec /bin/bash
}

# start gmet if .rc is present
function cluster_member ()
{
    if [ ! "$HOST_USER" = "" -a ! "$HOST_USER" = "$(id -un)" ]; then
	/usr/local/bin/meta-start.sh setup-user ${HOST_USER}
	exec sudo -H -u ${HOST_USER} $0 cluster-member $*
    fi

    args=$(getopt f:r $*)
    local do_init=0
    local node_name=

    set -- $args
    for i; do
	case "$i" in
	-r)
	    do_init=1
	    shift;;
	-f)
	    node_name=$2
	    shift 2;;
	esac
    done

    [ "$node_name" = "" ] && die "Node name is not set"

    while [ true ]; do
	curl http://${node_name}:8588 > /dev/null 2>&1
	if [ $? = 0 -o $? = 52 ]; then
	    # node 1 is ready
	    if [ "$do_init" = "1" ]; then
		/opt/meta/bin/gmet.sh wipe
	    fi
	    /opt/meta/bin/gmet.sh start meta
	    break
	fi
	sleep 1
	continue
    done
    exec /bin/bash
}

function setup_cluster ()
{
    args=$(getopt a:d:f:m:n:r $*)
    local do_init=
    local dir=.
    local node_name=
    local miner_count=0
    local non_miner_count=0
    local node_count=0
    local ip_prefix=172.18.100.
    local ip_start=200
    local port_start=31000
    local node_prefix
    local node_index
    local node_last
    local tar_file=

    docker network inspect bobthe > /dev/null 2>&1 || $0 new-network || \
	die "Cannot create bobthe network"

    set -- $args
    for i; do
	case "$i" in
	    -a)
		tar_file=$2
		shift 2;;
	    -d)
		dir=$2
		shift 2;;
	    -f)
		node_name=$2
		shift 2;;
	    -m)
		miner_count=$2
		shift 2;;
	    -n)
		non_miner_count=$2
		shift 2;;
	    -r)
		do_init="\"-r\", "
		shift;;
	esac
    done

    [ "$node_name" = "" -o "$miner_count" -le 0 -o ! -f "${tar_file}" ] && \
	usage 1
    node_count=$(($miner_count + $non_miner_count))

    node_prefix=$(echo $node_name | awk '{if ((ix=match($0,"[0-9]+$")) == 0) print $0; else print substr($0, 1, ix-1);}')
    node_index=$(echo $node_name | awk '{if ((ix=match($0,"[0-9]+$")) == 0) print 1; else print substr($0, ix);}')
    [ "$node_prefix" = "" -o "$node_index" = "" -o "$node_index" -le 0 ] && die "Cannot figure out node prefix and index"

    [ $(($ip_start + $node_index + $node_count - 1)) -gt 254 ] && die "Last node index ($(($node_index + $node_count - 1))) is too high as IP address base is ${ip_prefix}${ip_start}"

    [ -d "${dir}" ] || mkdir -p "${dir}" || die "Cannot create ${dir}"
    cp $0 ${dir}/
    [ -f "$(dirname $0)/rc.js" ] && cp $(dirname $0)/rc.js ${dir}
    cp ${tar_file} ${dir}/
    [ -d "$(dirname $0)/.ethash" ] && cp -r $(dirname $0)/.ethash ${dir}/

    # create docker-compose.yml
    fn=${dir}/docker-compose.yml

    local map_passwd=
    if [ "$(uname -s)" = "Linux" ]; then
	map_passwd="      - \"/etc/passwd:/etc/passwd:ro\"
      - \"/etc/group:/etc/group:ro\"
"
    fi

    echo "version: \"3\"
services:" > ${fn}
    for i in $(seq 0 $(($node_count - 1))); do
	local name=${node_prefix}$(printf "%d" $(($node_index + $i)))
	local ip=${ip_prefix}$(printf "%d" $(($ip_start + $node_index + $i)))
	local port=$((port_start + ($node_index + $i) * 100 + 8588))

	echo "  ${name}:
    container_name: ${name}
    hostname: ${name}
    stdin_open: true
    tty: true
    image: metadium/bobthe:latest
    volumes:
      - \".:/data\"
      - \"./${name}:/opt/meta\"
${map_passwd}    networks:
      bobthe:
        ipv4_address: ${ip}
    environment:
      - HOST_USER=$(id -un)
    ports:
      - \"${port}-$(($port + 1)):8588-8589\"" >> ${fn}
	if [ $i = 0 ]; then
	    echo '    entrypoint: ["/data/bobthe.sh", "cluster-leader", '${do_init}'"-f", "'${node_name}'", "-m", "'${miner_count}'", "-n", "'${non_miner_count}'"]' >> ${fn}
	else
	    echo '    entrypoint: ["/data/bobthe.sh", "cluster-member", '${do_init}'"-f", "'${node_name}'"]' >> ${fn}
	fi
    done

    echo "
networks:
  bobthe:
    external: true" >> ${fn}

    echo "docker-compose.yml is ready for docker-compose in ${dir}.
Just run 'docker-compose up' in ${dir}."

    return 0
}

# void wipe_cluster(string dir)
function wipe_cluster ()
{
    local dir=$1
    [ -d "${dir}" ] || die "Cannot locate ${dir}"
    for i in $(/bin/ls -1 ${dir}); do
	local d=${dir}/$i
	if [ -x "${d}/bin/gmet" -o -d "${d}/geth" ]; then
	    echo -n "cleaning ${d}..."
	    /bin/rm -rf ${d}/geth/LOCK ${d}/geth/chaindata ${d}/geth/ethash \
		${d}/geth/lightchaindata ${d}/geth/transactions.rlp	    \
		${d}/geth/nodes geth.ipc ${d}/logs/* ${d}/etcd
	    echo "done."
	fi
    done
}

function usage ()
{
    echo "$(basename $0) new-network | launch <name> | launch-host <name> [port] | shell <name> |
	setup-cluster [-r | -d <dir> | -f <first-node> -m <miner-count> -n <non-miner-count> -a <tar-file>] |
	cluster-leader [-r | -f <name> | -m <miner-count> | -n <non-miner-count> -a <metadium.tar.gz>] |
	cluster-member [-r | -f <name> | wipe-cluster <dir>]"
    [ "$1" = "1" ] && exit 1
}

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
    setup_cluster $*
    ;;
"cluster-leader")
    shift
    cluster_leader $*
    ;;
"cluster-member")
    shift
    cluster_member $*
    ;;
"wipe-cluster")
    shift
    [ $# = 1 ] || usage 1
    wipe_cluster $*
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
