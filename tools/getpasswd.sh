#!/bin/sh
min_uid=`grep -E '^UID_MIN' /etc/login.defs | awk '{print $2};'`
max_uid=`grep -E '^UID_MAX' /etc/login.defs | awk '{print $2};'`
#grep -F '/bin/bash' /etc/passwd | \
awk -F : -v min="${min_uid}" -v max="${max_uid}" '$3 > min && $3 <= max {print};' /etc/passwd
