#!/bin/sh
set -ex

simulate=0
fallback=0
master_domain="_"
passwd_location="/users.passwd"
nginx_conf_url="https://raw.githubusercontent.com/alichry/simple-hpcluster/master/templates/nginx.conf"
nginx_vhost_url="https://raw.githubusercontent.com/alichry/simple-hpcluster/master/templates/nginx-vhost.conf"
getpasswd_url="https://raw.githubusercontent.com/alichry/simple-hpcluster/master/tools/getpasswd.sh"
copypasswd_url="https://raw.githubusercontent.com/alichry/simple-hpcluster/master/tools/copypasswd.sh"
cfnconfig="/etc/parallelcluster/cfnconfig"
public_port=80
private_port=8080
root=""

getpasswd_path="/root/scripts/getpasswd.sh"
copypasswd_path="/root/scripts/copypasswd.sh"

usage="Simple AWS ParallelCluster bootstrapper usage:
    `basename "$0"` [OPTIONS]
OPTIONS:
    -h, --help          prints this
    -s ROOT TYPE, --simulate ROOT TYPE
                        simulate this script, package installs will be disabled,
                        crontab will not be modified. esulting files will be
                        saved in ROOT. TYPE is either MasterServer or ComputeFleet
    -p PORT, --public-port PORT
                        port to use for the master's public nginx vhosts.
                        Defaults to ${public_port}
    -q PORT, --private-port PORT
                        port to use for the master's private nginx vhost
                        (only accessible from the VPC). Defaults to ${private_port}
    -l LOC, --passwd-location LOC
                        Use LOC as the HTTP location for the generated passwd
                        file. Defaults to ${passwd_location}
    -f LOC, --enable-fallback LOC
                        fallback is required if the compute node was not able
                        to infer the master node's hostname. Disabled by default.
                        LOC is the HTTP location that will point to the passwd
                        file.
    -d DOMAIN, --domain DOMAIN
                        domain name that will point to the master node. This
                        is required if the -f option is used. If this is used
                        without the -f option, this will simply be used in the
                        nginx's vhost configuration directive 'server_name'
Note: HTTP location must start with a leading slash.
e.g. -l ${passwd_location} -f /master.simplehpc"

printusage () {
    echo "${usage}"
    return 0
}

pkgmngr () {
    # @env * PKG_MANAGER
    if [ -n "${PKG_MANAGER}" ]; then
        echo "${PKG_MANAGER}"
        return 0
    fi
    if command -v yum > /dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v apt > /dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v zypper > /dev/null 2>&1; then
        PKG_MANAGER="zypper"
    else
        echo "error: pkgmngr - unable to determine package manager" 1>&2
        return 1
    fi
    echo "${PKG_MANAGER}"
}

ctype_digit () {
    case "${1}" in
        ''|*[!0-9]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
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
    # @env nginx_conf_url
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
    curl -L -o "${newroot}/etc/nginx/nginx.conf" "${nginx_conf_url}"
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
    # @out master_hostname_location
    # @out master_hostname_url
    # @out public_root
    # @out private_root
    # @out public_confname
    # @out private_confname
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
    [ -z "${master_hostname_file}" ] && \
        master_hostname_filename="master.${cluster_name}"
    master_hostname_url="http://${master_domain}/${master_hostname_filename}"
    public_root="/usr/share/nginx/${cluster_name}-pub"
    private_root="/usr/share/nginx/${cluster_name}-priv"
    public_confname="${cluster_name}-pub.conf"
    private_confname="${cluster_name}-priv.conf"
}


stupnginx () {
    # $1 - newroot
    # $2 - pubdomain
    # $3 - nginxconfurl
    # $4 - nginxvhosturl
    # $5 - publicconfname
    # $6 - privateconfname
    # $7 - publicport
    # $8 - privateport
    # ${9} - publicroot
    # ${10} - privateroot
    local newroot
    local nginxconf
    local nginxvhost
    local pubconfname
    local privconfname
    local pubport
    local privport
    local pubroot
    local privroot
    local masterec2hostname
    local nginx
    local nginxwebroot
    local awkprg
    if [ "$#" -lt 10 ]; then
        echo "error: stupnginx - expecting 10 arguments, received $#" 1>&2
        return 1
    fi
    newroot="$1"
    pubdomain="$2"
    nginxconf="$3"
    nginxvhost="$4"
    pubconfname="$5"
    privconfname="$6"
    pubport="$7"
    privport="$8"
    pubroot="$9"
    privroot="${10}"

    if [ -z "${pubdomain}" ]; then
        echo "error: stupnginx - pubdomain argument is empty" 1>&2
        return 1
    fi
    if [ -z "${nginxconf}" ]; then
        echo "error: stupnginx - nginxconf argument is empty" 1>&2
        return 1
    fi
    if [ -z "${nginxvhost}" ]; then
        echo "error: stupnginx - nginxvhost argument is empty" 1>&2
        return 1
    fi
    if [ -z "${pubconfname}" ]; then
        echo "error: stupnginx - pubconfname argument is empty" 1>&2
        return 1
    fi
    if [ -z "${privconfname}" ]; then
        echo "error: stupnginx - privconfname argument is empty" 1>&2
        return 1
    fi
    if [ -z "${pubport}" ]; then
        echo "error: stupnginx - pubport argument is empty" 1>&2
        return 1
    fi
    if [ -z "${privport}" ]; then
        echo "error: stupnginx - privport argument is empty" 1>&2
        return 1
    fi
    if [ -z "${pubroot}" ]; then
        echo "error: stupnginx - pubroot argument is empty" 1>&2
        return 1
    fi
    if [ -z "${privroot}" ]; then
        echo "error: stupnginx - privroot argument is empty" 1>&2
        return 1
    fi
    if ! ctype_digit "${pubport}"; then
        echo "error: stupnginx - pubport is not numeric" 1>&2
        return 1
    fi
    if ! ctype_digit "${privport}"; then
        echo "error: stupnginx - privport iis not numeric" 1>&2
        return 1
    fi
    if [ "${pubport}" -lt 1 -o "${pubport}" -gt 65535 ]; then
        echo "error: stupnginx - pubport '${pubport}' is invalid" 1>&2
        return 1
    fi
    if [ "${privport}" -lt 1 -o "${privport}" -gt 65535 ]; then
        echo "error: stupnginx - privport '${privport}' is invalid" 1>&2
        return 1
    fi
    nginx="${newroot}/etc/nginx"
    pubroot="${newroot}${pubroot}"
    privroot="${newroot}${privroot}"
    nginxconf=`curl -L "${nginxconf}"`
    nginxvhost=`curl -L "${nginxvhost}"`
    masterec2hostname="${HOSTNAME}.ec2.internal"
    critical_exec `pkgmngr` install -y nginx
    mkdir -p "${nginx}/vhosts"
    mkdir -p "${pubroot}"
    mkdir -p "${privroot}"
    cp "${nginx}/nginx.conf" \
        "${nginx}/nginx.conf.bak"
    echo "${nginxconf}" > "${nginx}/nginx.conf"
    echo "${nginxvhost}" | \
        sed "s|{PORT}|${pubport}|g;
             s|{DEFAULT_SERVER}|default_server|g;
             s|{SERVER_NAME}|${pubdomain}|g;
             s|{ROOT}|${pubroot}|g;" \
        > "${nginx}/vhosts/${pubconfname}"
    echo "${nginxvhost}" | \
        sed "s|{PORT}|${privport}|g;
             s| {DEFAULT_SERVER}||g;
             s|{SERVER_NAME}|${HOSTNAME} ${masterec2hostname}|g;
             s|{ROOT}|${privroot}|g;" \
        > "${nginx}/vhosts/${privconfname}"
    critical_exec nginx -t -c "${nginx}/nginx.conf"
    if command -v systemctl > /dev/null 2>&1; then
        critical_exec systemctl start nginx
        critical_exec systemctl enable nginx
    elif command -v service > /dev/null 2>&1; then
        critical_exec service nginx start
    else
        echo "warning: stupnginx - unable to determine service manager \
to start nginx" 1>&2
        echo "warning: running nginx in daemon mode"
        critical_exec nginx
    fi
}

putfb () {
    # $1 - newroot
    # $2 - fb
    # $3 - pubroot
    # $4 - masterhostnamefn
    # @env $HOSTNAME
    local newroot
    local fb
    local pubroot
    local fn
    if [ "$#" -lt 3 ]; then
        echo "error: putfb - expecting 3 arguments, received $#" 1>&2
        return 1
    fi
    newroot="$1"
    fb="$2"
    pubroot="$3"
    fn="$4"
    if [ -z "${fb}" ]; then
        echo "error: putfb - fallback is empty" 1>&2
        return 1
    fi
    if [ -z "${pubroot}" ]; then
        echo "error: putfb - pubroot is empty" 1>&2
        return 1
    fi
    if [ -z "${fn}" ]; then
        echo "error: putfb - master host filename is empty" 1>&2
        return 1
    fi
    if [ "${fb}" -eq 1 ]; then
        # Put hostname on public vhost
        echo "${HOSTNAME}.ec2.internal" \
            > "${newroot}${pubroot}/${fn}"
    fi
}

putscript () {
    # $1 newroot
    # $2 scriptpath
    # $3 scripturl
    local newroot
    local scriptpath
    local scripturl
    if [ "$#" -lt 3 ]; then
        echo "error: putscript - expecting 3 arguments, received $#" 1>&2
        return 1
    fi
    newroot="$1"
    scriptpath="$2"
    scripturl="$3"
    if [ -z "${scriptpath}" ]; then
        echo "error: putpsync - scriptpath is empty" 1>&2
        return 1
    fi
    if [ -z "${scripturl}" ]; then
        echo "error: putpsync - scripturl is empty" 1>&2
        return 1
    fi
    scriptpath="${newroot}${scriptpath}"
    mkdir -p "`dirname "${scriptpath}"`"
    curl -L -o "${scriptpath}" "${scripturl}"
    chmod +x "${scriptpath}"
    return 0
}
addcronjob () {
    # $1 - crontab entry
    local tmpfile
    tmpfile=`mktemp`
    crontab -l > "${tmpfile}" 2> /dev/null || true
    echo "${1}" >> "${tmpfile}"
    critical_exec crontab "${tmpfile}"
    rm "${tmpfile}"
}

putsgeutils () {
    # $1 newroot
    local newroot
    local tmpdir
    newroot="$1"
    tmpdir=`mktemp -d`
    git clone --depth=1 https://github.com/alichry/sge-utils.git "${tmpdir}"
    "${tmpdir}/install.sh" -i "${root}/usr/local/bin" -c "${root}/etc/sge-utils"
    rm -rf "${tmpdir}"
    return 0
}

stupsge () {
    local tmpfile
    if qconf -spl | grep -q '^smp$'; then
        return 0
    fi
    tmpfile=`mktemp`
    critical_exec qconf -sp mpi | sed -E 's/^(pe_name[ \t]*)(.*)$/\1smp/g;
            s/^(allocation_rule[ \t]*)(.*)$/\1\$pe_slots/g' > "${tmpfile}"
    critical_exec qconf -Ap "${tmpfile}"
    rm "${tmpfile}"
    return 0
}

run () {
    # $@ the cl
    valcl "$@"

    if [ "${simulate}" -eq 1 ]; then
        preparesim "${cluster_name}" "${root}"
    fi

    copypasswd_args="-q ${private_port} -l ${passwd_location}"
    if [ "${fallback}" -eq 1 ]; then
        copypasswd_args="${copypasswd_args} -f \"${master_hostname_url}\""
    fi

    case "${cfn_node_type}" in
        MasterServer)
            stupnginx "${root}" "${master_domain}" "${nginx_conf_url}" \
                "${nginx_vhost_url}" "${public_confname}" "${private_confname}" \
                "${public_port}" "${private_port}" "${public_root}" \
                "${private_root}" "${master_hostname_location}"
            putfb "${root}" "${fallback}" "${public_root}" "${master_hostname_filename}"
            putscript "${root}" "${getpasswd_path}" "${getpasswd_url}"
            addcronjob "*/10 * * * * \"${getpasswd_path}\" \
> \"${private_root}/${passwd_location}\""
            putsgeutils "${root}"
            stupsge
            ;;
        ComputeFleet)
            critical_exec `pkgmngr` install -y valgrind
            putscript "${root}" "${copypasswd_path}" "${copypasswd_url}"
            addcronjob "*/5 * * * * ${copypasswd_path} ${copypasswd_args}"
            ;;
        *)
            echo "error: invalid node type '${cfn_node_type}'" 1>&2
            return 1
            ;;
    esac
}

run "$@"
