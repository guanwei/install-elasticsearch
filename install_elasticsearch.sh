#!/usr/bin/env bash
#====================================================================
# install_elasticsearch.sh
#
# Linux ElasticSearch Auto Install Script
#
# Copyright (c) 2016, Edward Guan <edward.guan@mkcorp.com>
# All rights reserved.
# Distributed under the GNU General Public License, version 3.0.
#
# Intro: 
#
#====================================================================

# defind functions
msg() {
    printf '%b\n' "$1" >&2
}

title() {
    msg "\e[1;36m${1}\e[0m"
}

success() {
    msg "\e[1;32m[✔]\e[0m ${1}"
}

warning() {
    msg "\e[1;33m${1}\e[0m"
}

error() {
    msg "\e[1;31m[✘]\e[0m ${1}"
    exit 1
}

program_exists() {
    command -v $1 >/dev/null 2>&1
}

function print_usage() {
    echo "Usage: $(basename "$0") [OPTIONS...]"
    echo ""
    echo "Options"
    echo "  [-h|--help]                                 Prints a short help text and exists"
    echo "  [-c|--cluster] <cluster_name>               Set cluster name"
    echo "  [-n|--name] <node_name>                     Set node name"
    echo "  [-s|--nodes] <node01_ip,node02_ip,...>      Nodes ip in the cluster"
}

warning "Note: This tiny script has been hardcoded specifically for RHEL/CentOS.\n"

if [ $(id -u) != "0" ]; then
    error "You must be root to run this script!"
fi

# read the options
TEMP=`getopt -o hc:n:s: --long help,cluster:,name:,nodes: -n $(basename "$0") -- "$@"`
eval set -- "$TEMP"

# extract options and their arguments into variables.
while true; do
    case "$1" in
        -h|--help) print_usage ; exit 0 ;;
        -c|--cluster) CLUSTER_NAME=$2 ; shift 2 ;;
        -n|--name) NODE_NAME=$2 ; shift 2 ;;
        -s|--nodes) NODES_IP=$2 ; shift 2 ;;
        --) shift ; break ;;
        *) error "Internal error!" ;;
    esac
done

if [ -z "$CLUSTER_NAME" ] || [ -z "$NODES_IP" ]; then
    error "$(basename "$0"): missing operand.\nTry '$(basename "$0") --help' for more information."
fi

# verify nodes ip
for ip in ${NODES_IP//,/ }; do
    if [[ ! $ip =~ ^([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$ ]]; then
        error "'$ip' not match IP address."
    fi
done

# get script path
SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# load settings
source "$SCRIPT_PATH/settings.conf" || exit 1

# check system type
case $(uname -r) in
    *el7*|*el6*|*amzn1*) ;;
    *) error "Your system is not RHEL/CentOS." ;;
esac

# install required package
program_exists wget || yum -y install wget >/dev/null 2>&1

# install oracle jdk rpm
title "Installing Oracle JDK..."
JDK_RPM_PATH="$SCRIPT_PATH/${JDK_RPM_URL##*/}"
if [ ! -f "$JDK_RPM_PATH" ]; then
    warning "WARNING: '$JDK_RPM_PATH' not exists."
    msg "Try to download and install from $JDK_RPM_URL..."
    wget --no-check-certificate --no-cookies --header "Cookie: oraclelicense=accept-securebackup-cookie" $JDK_RPM_URL -P $SCRIPT_PATH || return 1
fi
install_result=$(rpm -U $JDK_RPM_PATH 2>&1 | awk '{gsub(/^[ \t]+/,"");print}')
if [ -z "$install_result" ]; then
    success "Installed '$JDK_RPM_PATH'."
else
    msg "$install_result"
fi

# uninstall openjdk
title "Uninstalling openJDK..."
if [ $(rpm -qa | grep openjdk) ]; then
    rpm -qa | grep openjdk | xargs rpm -e || exit 1
    success "Uninstalled openJDK."
else
    msg "openJDK not found."
fi

# deploy elasticsearch to ES_HOME path and set bin folder files executable
title "Deploying ElasticSearch..."
ES_PKG="$SCRIPT_PATH/elasticsearch-rtf"
if [ -d "$ES_PKG" ]; then
    mkdir -p "$ES_HOME" && cp -r $ES_PKG/* "$ES_HOME" || exit 1
    chmod +x $ES_HOME/bin/* || exit 1
    success "Deployed to '$ES_HOME'."
else
    error "ElasticSearch package 'ES_PKG' not exists."
fi

# add elasticsearch user
title "Adding ElasticSearch user 'elasticsearch'..."
if [ -z "$(cat /etc/passwd | grep elasticsearch)" ]; then
    useradd -c "elasticsearch user" -M -s /sbin/nologin elasticsearch
    success "Added user 'elasticsearch'."
else
    msg "User 'elasticsearch' already exists."
fi

# creat elasticsearch data and logs folder and change owner to elasticsearch
title "Creating ElasticSearch data and logs folder..."
mkdir -p "$ES_DATA_PATH" && chown -R elasticsearch:elasticsearch "$ES_DATA_PATH" || exit 1
success "Created data folder '$ES_DATA_PATH'."
mkdir -p $ES_LOGS_PATH && chown -R elasticsearch:elasticsearch "$ES_LOGS_PATH" || exit 1
success "Created logs folder '$ES_LOGS_PATH'."

# update elasticsearch config file
title "Updating ElasticSearch config file..."
ES_CONFIG_PATH="$ES_HOME/config/elasticsearch.yml"
if [ -f "$ES_CONFIG_PATH" ]; then
    sed -i -e "s|[ #]*cluster.name: .*|cluster.name: $CLUSTER_NAME|g" \
        -i -e "s|[ #]*path.data: .*|path.data: $ES_DATA_PATH|g" \
        -i -e "s|[ #]*path.logs: .*|path.logs: $ES_LOGS_PATH|g" \
        -i -e "s|[ #]*discovery.zen.ping.unicast.hosts: .*|discovery.zen.ping.unicast.hosts: [$NODES_IP]|g" "$ES_CONFIG_PATH"
    if [ -n "$NODE_NAME" ]; then
        sed -i -e "s|[ #]*node.name: .*|node.name: $NODE_NAME|g" "$ES_CONFIG_PATH"
    fi
    if [ -n "$NETWORK_DEVICE" ]; then
        sed -i -e "s|[ #]*network.host: .*|network.host: [_${NETWORK_DEVICE}_,_local_]|g" "$ES_CONFIG_PATH"
    fi
    num=$(expr $(echo $NODES_IP | tr -cd , | wc -c) + 1)
    if [ $num -gt 3 ]; then
        mins=$(expr $num / 2 + 1)
        sed -i -e "s|[ #]*discovery.zen.minimum_master_nodes: .*|discovery.zen.minimum_master_nodes: $mins|g" "$ES_CONFIG_PATH"
    fi
    success "Updated config file '$ES_CONFIG_PATH'."
else
    error "ElasticSearch config file '$ES_CONFIG_PATH' not exists."
fi

# copy elasticsearch init script to /etc/init.d/
# and set elasticsearch service auto start then start it
title "Setting up ElasticSearch service..."
ES_INIT_SCRIPT="$SCRIPT_PATH/elasticsearch_init_script"
if [ -f "$ES_INIT_SCRIPT" ]; then
    cp "$ES_INIT_SCRIPT" /etc/init.d/elasticsearch
    sed -i -e 's|ES_HOME=.*|ES_HOME="'$ES_HOME'"|g' /etc/init.d/elasticsearch
    chmod +x /etc/init.d/elasticsearch
    chkconfig elasticsearch on
    service elasticsearch start || exit 1
    success "Set up ElasticSearch service."
else
    error "ElasticSearch init script '$ES_INIT_SCRIPT' not exists."
fi

msg "\nThanks for install ElasticSearch."
msg "© `date +%Y`"
