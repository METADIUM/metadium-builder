FROM ubuntu:latest

COPY meta-start.sh /usr/local/bin/

RUN /bin/bash -c '\
    apt-get update -q -y && apt-get upgrade -q -y && \
    apt-get install -y --no-install-recommends build-essential ca-certificates curl git gnupg libjemalloc-dev liblz4-dev libsnappy-dev libzstd-dev libudev-dev net-tools ssh sudo vim && \
    curl -sL -o /tmp/go.tar.gz https://dl.google.com/go/go1.12.linux-amd64.tar.gz && \
    pushd /usr/local/ && \
    tar xfz /tmp/go.tar.gz && \
    cd /usr/local/bin/ && \
    ln -sf ../go/bin/* . && \
    popd && \
    curl -sL https://deb.nodesource.com/setup_8.x | bash - && \
    apt-get install -y nodejs && \
    curl -sL -o /usr/local/bin/solc https://github.com/ethereum/solidity/\releases/download/v0.4.24/solc-static-linux && \
    chmod a+x /usr/local/bin/solc && \
    chmod a+x /usr/local/bin/meta-start.sh && \
    chmod a=rwx /home && chmod o+t /home && \
    /usr/local/bin/meta-start.sh setup-skel'

ENTRYPOINT ["/usr/local/bin/meta-start.sh"]
