#!/bin/sh
set -xe
if [ "$( id -u )" -eq 0 ]; then
    mkdir --mode=0700 -p /run/sshd
    /usr/bin/ssh-keygen -A
    /usr/sbin/sshd -t
    /usr/sbin/sshd
fi

# if the environment variable PUBLIC_KEY is set write the content to authorized_keys
if [ -n "${PUBLIC_KEY}" ]; then
    mkdir --mode 0700 -p ~/.ssh
    /usr/bin/echo -e "${PUBLIC_KEY}" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi

exec dumb-init -- "$@"
