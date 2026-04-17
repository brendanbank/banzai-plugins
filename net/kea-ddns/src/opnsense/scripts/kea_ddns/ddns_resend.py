#!/usr/local/bin/python3

"""
Copyright (C) 2026 Brendan Bank <brendan.bank@gmail.com>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
"""

import argparse
import json
import socket

SOCKETS = {
    'dhcp4': '/var/run/kea/kea4-ctrl-socket',
    'dhcp6': '/var/run/kea/kea6-ctrl-socket',
}
RECV_BUF = 65536
TIMEOUT = 10


def send_command(sock_path, command, arguments=None):
    """Send a JSON command to a Kea DHCP control socket."""
    payload = {'command': command}
    if arguments is not None:
        payload['arguments'] = arguments
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    try:
        s.connect(sock_path)
        s.sendall((json.dumps(payload) + '\n').encode())
        chunks = []
        while True:
            data = s.recv(RECV_BUF)
            if not data:
                break
            chunks.append(data)
        return json.loads(b''.join(chunks))
    finally:
        s.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--proto', choices=['inet', 'inet6'], required=True)
    parser.add_argument('--address', required=True)
    args = parser.parse_args()

    # Validate IP address
    family = socket.AF_INET if args.proto == 'inet' else socket.AF_INET6
    try:
        socket.inet_pton(family, args.address)
    except OSError:
        print(json.dumps({'result': 1, 'text': 'invalid IP address'}))
        return

    service = 'dhcp4' if args.proto == 'inet' else 'dhcp6'
    lease_cmd = 'lease4-resend-ddns' if args.proto == 'inet' else 'lease6-resend-ddns'
    sock_path = SOCKETS[service]

    try:
        resp = send_command(sock_path, lease_cmd, {'ip-address': args.address})
        print(json.dumps(resp))
    except (OSError, json.JSONDecodeError) as e:
        print(json.dumps({'result': 1, 'text': str(e)}))


if __name__ == '__main__':
    main()
