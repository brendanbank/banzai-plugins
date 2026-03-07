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

import csv
import json
import os
import socket
import sys
import time

SOCKET_PATH = '/var/run/kea/kea-ddns-ctrl-socket'
LEASE4_FILE = '/var/db/kea/kea-leases4.csv'
LEASE6_FILE = '/var/db/kea/kea-leases6.csv'
RECV_BUF = 65536
TIMEOUT = 5


def send_command(sock_path, command):
    """Send a JSON command to a Kea control socket and return the parsed response."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    try:
        s.connect(sock_path)
        s.sendall(json.dumps({'command': command}).encode())
        s.shutdown(socket.SHUT_WR)
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
    result = {'running': False}

    if not os.path.exists(SOCKET_PATH):
        print(json.dumps(result))
        return

    try:
        status = send_command(SOCKET_PATH, 'status-get')
        if status.get('result') == 0:
            result['running'] = True
            result['status'] = status.get('arguments', {})

        version = send_command(SOCKET_PATH, 'version-get')
        if version.get('result') == 0:
            result['version'] = version.get('text', '')

        stats = send_command(SOCKET_PATH, 'statistic-get-all')
        if stats.get('result') == 0:
            raw = stats.get('arguments', {})
            # Flatten: each stat is [[value, timestamp]] — extract value
            statistics = {}
            for key, values in raw.items():
                if isinstance(values, list) and len(values) > 0 and isinstance(values[0], list):
                    statistics[key] = values[0][0]
                else:
                    statistics[key] = values
            result['statistics'] = statistics
    except (OSError, json.JSONDecodeError, KeyError):
        pass

    print(json.dumps(result))


if __name__ == '__main__':
    main()
