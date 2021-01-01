# builder image

FROM ubuntu:latest as base

SHELL ["/bin/bash", "-c"]

COPY meta-start.sh /usr/local/bin/

RUN apt-get update -q -y && apt-get upgrade -q -y
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata
RUN apt-get install -y --no-install-recommends build-essential ca-certificates curl git gnupg libjemalloc-dev liblz4-dev libsnappy-dev libzstd-dev libudev-dev net-tools ssh sudo vim less locales
RUN locale-gen --purge en_US.UTF-8

# golang
RUN curl -sL -o /tmp/go.tar.gz https://dl.google.com/go/$(curl -sL https://golang.org/VERSION?m=text).linux-amd64.tar.gz && \
    pushd /usr/local/ && \
    tar xfz /tmp/go.tar.gz && \
    cd /usr/local/bin/ && \
    ln -sf ../go/bin/* . && \
    popd && \
    rm /tmp/go.tar.gz

# nodejs & yarn
RUN curl -sL https://deb.nodesource.com/setup_12.x | bash - && \
    apt-get install -y nodejs && \
    curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" > /etc/apt/sources.list.d/yarn.list && \
    apt-get update -q -y && sudo apt-get install -y yarn

# python3 & brownie

# see http://bugs.python.org/issue19846
ENV LANG C.UTF-8

RUN apt-get install -y python3 python3-pip python3-venv && \
    python3 -m pip install --system eth-brownie

RUN apt autoremove && apt autoclean

# delta stuff
RUN chmod a+x /usr/local/bin/meta-start.sh && \
    chmod a=rwx /home && chmod o+t /home && \
    sed -i -e "s/^UsePAM yes/UsePAM no/" /etc/ssh/sshd_config && \
    /usr/local/bin/meta-start.sh setup-skel

ENTRYPOINT ["/usr/local/bin/meta-start.sh"]

# EOF
