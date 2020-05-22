#!/bin/sh
# Copyright (c) 2020 Ali Cherry <cmcrc@alicherry.net>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -ex

private_port="8080"
passwd_location="/users.passwd"

usage="Copy passswd usage:
    `basename "$0"` OPTIONS
OPTIONS:
    --help                  prints this
    -n, --dry-run           do not /etc/passwd, just print the diff
    -f, --fallback <url>    HTTP URL that will return the local hostname of the
                            master node. This is required if we are not able to
                            infer the master's hostname
    -u, --passwd-url <url>  an HTTP URL of the passwd file. if this is provided,
                            then no other arguments are required.
    -h <hostname>           the local hostname of the master node, if specified
                            there won't be any use to the -d option
    -q <port>               the master node's nginx private vhost listening port.
                            Defaults to ${private_port}
    -l <location>           the HTTP location (excluding the host part) of the
                            passwd file. Defaults to ${passwd_location}"
printusage () {
    echo "${usage}"
}

isempty () {
    local arg
    for arg in "$@"
    do
        [ -z "${arg}" ] && return 0
    done
    return 1
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

valcl () {
    # $@
    while [ "$#" -gt 0 ]
    do
        case "$1" in
            --help)
                printusage
                exit 0
                ;;
            -n|--dry-run)
                dry=1
                shift 1
                ;;
            -f|--fallback)
                fallback="$2"
                shift `maxshift 2 "$#"`
                ;;
            -u|--passwd-url)
                passwd_url="$2"
                shift `maxshift 2 "$#"`
                ;;
            -h|--master-hostname)
                master_hostname="$2"
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
            *)
                echo "error: valcl - invalid option '${1}'" 1>&2
                return 1
                ;;
        esac
    done
    return 0
}

getmasterhostname () {
    # $1 fallback
    # @echo hostname
    local fb
    local res
    local ret
    fb="$1"
    if [ -n "${SGE_O_HOST}" ]; then
        echo "${SGE_O_HOST}"
        return 0
    fi
    if [ -z "${fb}" ]; then
        echo "error: getmasterhostname - no other options to try!" 1>&2
        return 1
    fi
    res=`curl -L "${fb}"`
    ret=$?
    if [ "${ret}" -ne 0 ]; then
        echo "error: getmasterhostname - fallback '${fb}' \
failed (${ret})" 1>&2
        return "$ret"
    fi
    echo "${res}"
    return 0
}

getpasswdurl () {
    # $1 masterhostname
    # $2 privateport
    # $3 passwdlocation
    # @echo passwdurl
    if [ -z "${1}" ]; then
        echo "error: getpasswdurl - master hostname is not defined or empty" 1>&2
        return 1
    fi
    if [ -z "${2}" ]; then
        echo "error: getpasswdurl - master private port is not defined or empty" 1>&2
        return 1
    fi
    if ! ctype_digit "${2}"; then
        echo "error: getpasswdurl - private port '${2}' is not valid" 1>&2
        return 1
    fi
    echo "$1:$2$3"
}

validatepasswd () {
    # $1 passwdfile
    local passwd
    passwd="$1"
    if [ -z "${passwd}" ]; then
        echo "error: validatepasswd - passwd is empty or not defined" 1>&2
        return 1
    fi
    if [ ! -f "${passwd}" ]; then
        echo "error: validatepasswd - passwd '${passwd}' does not exists!" 1>&2
        return 1
    fi
    while IFS=: read -r user x uid gid comment home shell
    do
        # Those variables can be empty in case there wasnt 7
        # fields. If the shell value is not empty, then there
        # has to be 6 delims -- which takes care of the case
        # of checking there are 7 fields
        if isempty "${user}" "${uid}" "${shell}"; then
            echo "error: validpasswd - invalid passwd :-(" 1>&2
            return 1
        fi
    done < "$1"
    return 0
}

syncpasswd () {
    # $1 - passwdurl
    # $2 - dry (*|1)
    local url
    local norun
    local min_uid
    local max_uid
    local tmpfile
    url="${1}"
    norun="${2}"
    if [ -z "${url}" ]; then
        echo "error: syncpasswd - url is not defined or empty" 1>&2
        return 1
    fi
    min_uid=`grep -E '^UID_MIN' /etc/login.defs | awk '{print $2};'`
    max_uid=`grep -E '^UID_MAX' /etc/login.defs | awk '{print $2};'`
    # delete all user entries > MIn_UID && <= MAX_UID
    # then paste whatever we got, keep it simple :)
    users=`curl -L "${url}"`
    ret=$?
    if [ $ret -ne 0 ]; then
        echo "error: syncpasswd - unable to retrieve passwd ($ret) from ${passwd_url}" 1>&2
        return $ret
    fi
    tmpfile=`mktemp`
    awk -F : -v min="${min_uid}" -v max="${max_guid}" \
        '$3 <= min || $3 >= max {print};' /etc/passwd > "${tmpfile}"
    echo "${users}" >> "${tmpfile}"
    validatepasswd "${tmpfile}"
    diff "${tmpfile}" /etc/passwd || true

    if [ "${dry}" = "1" ]; then
        rm "${tmpfile}"
        return 0
    fi

    cp "${tmpfile}" /etc/passwd
    rm "${tmpfile}"
}

run () {
    # $@ the cl
    valcl "$@"
    if [ -z "${passwd_url}" ]; then
        if [ -z "${master_hostname}" ]; then
            master_hostname=`getmasterhostname "${fallback}"`
        fi
        passwd_url=`getpasswdurl "${master_hostname}" "${private_port}" \
            "${passwd_location}"`
    fi
    syncpasswd "${passwd_url}" "${dry}"
}

run "$@"
