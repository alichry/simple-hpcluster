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

script_name="$(basename "${0}")"
login_defs="/etc/login.defs"

if [ ! -f "${login_defs}" ]; then
    echo "${script_name}: error - '${login_defs}' does not exists" 1>&2
    exit 1
fi
if [ ! -r "${login_defs}" ]; then
    echo "${script_name}: error - '${login_defs}' is not readable" 1>&2
    exit 2
fi

min_uid="$(sed -En 's/^UID_MIN[ \t]+([0-9]+).*$/\1/p' "${login_defs}")"
max_uid="$(sed -En 's/^UID_MAX[ \t]+([0-9]+).*$/\1/p' "${login_defs}")"

if [ -z "${min_uid}" ]; then
    echo "${script_name}: error - unable to retrieve UID_MIN from \
'${login_defs}'" 1>&2
    exit 3
fi

if [ -z "${max_uid}" ]; then
    echo "${script_name}: error - unable to retrieve UID_MAX from \
'${login_defs}'" 1>&2
    exit 4
fi

awk -F : -v min="${min_uid}" -v max="${max_uid}" '$3 > min && $3 <= max {print};' /etc/passwd
