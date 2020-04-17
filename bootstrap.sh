#!/bin/sh
set -ex

master_domain="_"
passwd_location="/users.passwd"
nginx_conf_url="https://raw.githubusercontent.com/alichry/simple-hpcluster/master/templates/nginx.conf"
nginx_vhost_url="https://raw.githubusercontent.com/alichry/simple-hpcluster/master/templates/nginx-vhost.conf"
getpasswd_url="https://raw.githubusercontent.com/alichry/simple-hpcluster/master/tools/getpasswd.sh"
copypasswd_url="https://raw.githubusercontent.com/alichry/simple-hpcluster/master/tools/copypasswd.sh"
cfnconfig="/etc/parallelcluster/cfnconfig2"
public_port=80
private_port=8080
root=""

getpasswd_path="/root/scripts/getpasswd.sh"
copypasswd_path="/root/scripts/copypasswd.sh"

usage="Simple parallel cluster bootstrapper usage:
    `basename "$0"` [OPTIONS] <domain>
OPTIONS:
    -h, --help                      prints this
    -s, --simulate <root> <type>    simulate this script, package installs will be
                                    disabled, crontab will not be modified.
                                    Resulting files will be saved in <root>
                                    <type> is either MasterServer or ComputeFleet
    -p, --public-port <port>        port to use for the master's public nginx
                                    vhost. Defaults to ${public_port}
    -q, --private-port <port>       port to use for the master's private nginx
                                    vhost (only accessible from the VPC). Defaults
                                    to ${private_port}
    -l, --passwd-location <loc>     Use <loc> as the HTTP location for
                                    the generated passwd file. Defaults to
                                    ${passwd_location}
    -f, --enable-fallback <loc>     fallback is required if the compute node was
                                    not able to infer the master node's hostname.
                                    Disabled by default. <loc> is the HTTP
                                    location that will point to the passwd file.
    -d, --domain <domain>           domain name that will point to the master
                                    node. This is required if the -f option is
                                    used. If this is used without the -f option,
                                    this will simply be used in the nginx's vhost
                                    configuration directive 'server_name'"

printusage () {
    echo "${usage}"
    return 0
}

maxshift () {
    # $1 - the desired shift
    # $2 - the "$#" of the caller
    local desired
    local nargs
    desired="${1}"
    nargs="${2}"
    if [ -z "${desired}" ]; then
        echo "error: maxshift - desired is not defined or empty" 1>&2
        return 1
    fi
    if [ -z "${nargs}" ]; then
        echo "error: maxshift - nargs is not defiend or empty" 1>&2
        return 1
    fi
    if [ "${desired}" -gt "${nargs}" ]; then
        echo "${nargs}"
    else
        echo "${desired}"
    fi
}

preparesim () {
    # $1 clustername
    # $2 newroot
    local clustername
    local newroot
    clustername="$1"
    newroot="$2"
    if [ -z "${clustername}" ]; then
        echo "error: preparesim - clustername is not defined or empty" 1>&2
        return 1
    fi
    if [ -z "${newroot}" ]; then
        echo "error: preparesim - newroot is not defined or empty" 1>&2
        return 1
    fi
    read -p "Using root='${newroot}', continue ? (y/n) " yn
    case "$yn" in
        y|Y)
            ;;
        *)
            echo "OK, bye"
            exit 0
            ;;
    esac
    mkdir -p "${newroot}"
    mkdir -p "${newroot}/tmp"
    mkdir -p "${newroot}/usr/local/bin"
    mkdir -p "${newroot}/etc/nginx"
    touch "${newroot}/etc/nginx/nginx.conf"
}

critical_exec () {
    # we use critical_exec on commands we can't simulate
    local command
    if [ "${simulate}" -eq 1 ]; then
        echo "$@"
        return 0
    fi
    command="${1}"
    shift 1
    "${command}" "$@"
    return $?
}

valcl () {
    # $@ - the cl
    # @env cfnconfig
    # @out * script_url
    # @out * master_domain
    # @out * public_port
    # @out cluster_name
    # @out * fallback
    if [ -f "${cfnconfig}" ]; then
        if [ "$1" = "-h" -o "$1" = "--help" ]; then
            printusage
            exit 0
        fi
        script_url="${1}"
        shift 1
        . "${cfnconfig}"
        if [ -z "${stack_name}" ]; then
            echo "Error: valargs - cfnconfig '${cfnconfig}' did not contain \
stack_name variable" 1>&2
            return 1
        fi
        cluster_name=`echo "${stack_name}" | sed 's/^parallelcluster-//'`
    fi

    while [ "$#" -gt 0 ]
    do
        case "$1" in
            -h|--help)
                printusage
                exit 0
                ;;
            -s|--simulate)
                simulate=1
                cluster_name="simulated-pc"
                root="$2"
                cfn_node_type="$3"
                shift `maxshift 3 "$#"`
                ;;
            -p|--public-port)
                public_port="$2"
                shift `maxshift 2 "$#"`
                ;;
            -q|--private-port)
                private_port="$2"
                shift `maxshift 2 "$#"`
                ;;
            -l|--passwd-location)
                passwd_location="$2"
                shift `maxshift 2 "$#"`
                ;;
            -f|--enable-fallback)
                fallback=1
                master_hostname_location="$2"
                shift `maxshift 2 "$#"`
                ;;
            -d|--domain)
                master_domain="$2"
                shift `maxshift 2 "$#"`
                ;;
            *)
                echo "error: valcl - invalid option '${1}'" 1>&2
                return 1
                ;;
        esac
    done

    if [ "${simulate}" -ne 1 -a -z "${script_url}" ]; then
        echo "Error: valcl - cfnconfig file was not found. This indicate \
the script is ran not on a cluster node. To run this locally, you must use\
the -s <name> <root> option"
        printusage
        exit 1
    fi
}


valcl "$@"

if [ "${simulate}" -eq 1 ]; then
    preparesim "${cluster_name}" "${root}"
fi

[ -z "${master_hostname_file}" ] && \
    master_hostname_filename="master.${cluster_name}"
master_hostname_url="http://${master_domain}/${master_hostname_filename}"
public_root="${root}/usr/share/nginx/${cluster_name}-pub"
private_root="${root}/usr/share/nginx/${cluster_name}-priv"
public_confname="${cluster_name}-pub.conf"
private_confname="${cluster_name}-priv.conf"

nginx_conf=`curl -L "${nginx_conf_url}"`
nginx_vhost=`curl -L "${nginx_vhost_url}"`
getpasswd=`curl -L "${getpasswd_url}"`
copypasswd=`curl -L "${copypasswd_url}"`

copypasswd_args="-q ${private_port} -l ${passwd_location}"
if [ "${fallback}" -eq 1 ]; then
    copypasswd_args="${copypasswd_args} -f \"${master_hostname_url}\""
fi
echo "#######################################START"
case "${cfn_node_type}" in
    MasterServer)
        master_ec2_hostname="${HOSTNAME}.ec2.internal"
        critical_exec yum install -y nginx
	    mkdir -p "${root}/etc/nginx/sites-available"
	    mkdir -p "${root}/etc/nginx/sites-enabled"
	    mkdir -p "${public_root}"
	    mkdir -p "${private_root}"
        cp "${root}/etc/nginx/nginx.conf" \
            "${root}/etc/nginx/nginx.conf.bak"
	    echo "${nginx_conf}" > "${root}/etc/nginx/nginx.conf"
	    echo "${nginx_vhost}" | \
		    sed "s|{PORT}|${public_port}|g;
			     s|{DEFAULT_SERVER}|default_server|g;
			     s|{SERVER_NAME}|${master_domain}|g;
			     s|{ROOT}|${public_root}|g;" \
			> "${root}/etc/nginx/sites-available/${public_confname}"
	    echo "${nginx_vhost}" | \
		    sed "s|{PORT}|${private_port}|g;
			     s| {DEFAULT_SERVER}||g;
			     s|{SERVER_NAME}|${HOSTNAME} ${master_ec2_hostname}|g;
			     s|{ROOT}|${private_root}|g;" \
			> "${root}/etc/nginx/sites-available/${private_confname}"
	    ln -sf "${root}/etc/nginx/sites-available/${private_confname}" \
            "${root}/etc/nginx/sites-enabled"
	    ln -sf "${root}/etc/nginx/sites-available/${public_confname}" \
            "${root}/etc/nginx/sites-enabled"
        if [ "${fallback}" -eq 1 ]; then
            # Put hostname on public vhost
            echo "${master_ec2_hostname}" \
                > "${public_root}/${master_hostname_filename}"
        fi
        critical_exec nginx -t -c "${root}/etc/nginx/nginx.conf"
        critical_exec systemctl start nginx
        critical_exec systemctl enable nginx
	    mkdir -p "`dirname "${root}${getpasswd_path}"`"
	    echo "${getpasswd}" > "${root}${getpasswd_path}"
	    chmod +x "${root}${getpasswd_path}"
	    tmpfile=`mktemp`
	    crontab -l > "${tmpfile}" 2> /dev/null || true
	    echo "*/10 * * * * \"${root}${getpasswd_path}\" \
> \"${private_root}/${passwd_location}\"" >> "${tmpfile}"
        critical_exec crontab "${tmpfile}"
	    rm "${tmpfile}"
        tmpdir=`mktemp -d`
        git clone https://github.com/alichry/sge-utils.git "${tmpdir}"
        "${tmpdir}/install.sh" "${root}/usr/local/bin"
        rm -r "${tmpdir}"
	    # add parallel environments
	    # maybe add sge manager/operator..
        ;;
    ComputeFleet)
        critical_exec yum install -y valgrind
        cronjob_line="*/5 * * * * ${root}${copypasswd_path}"
	    mkdir -p "`dirname "${root}${copypasswd_path}"`"
	    echo "${copypasswd}" > "${root}${copypasswd_path}"
	    chmod +x "${root}${copypasswd_path}"
        tmpfile=`mktemp`
        crontab -l 2> /dev/null | \
            sed "/^.*`basename "${copypasswd_path}" .sh`.*\$/d" > "${tmpfile}"
        echo "${cronjob_line} ${copypasswd_args}" >> "${tmpfile}"
        critical_exec crontab "${tmpfile}"
        rm "${tmpfile}"
        ;;
    *)
        echo "error: invalid node type '${cfn_node_type}'" 1>&2
        exit 1
        ;;
esac

