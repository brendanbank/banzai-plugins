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
import os
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


def get_subnets(sock_path, service):
    """Return {subnet_id: cidr} from the Kea daemon config."""
    resp = send_command(sock_path, 'config-get')
    if not isinstance(resp, dict) or resp.get('result') != 0:
        return {}
    cfg_key = 'Dhcp4' if service == 'dhcp4' else 'Dhcp6'
    subnet_key = 'subnet4' if service == 'dhcp4' else 'subnet6'
    return {
        s['id']: s.get('subnet', '')
        for s in resp.get('arguments', {}).get(cfg_key, {}).get(subnet_key, [])
        if 'id' in s
    }


def collect_fqdn_leases(service, lease_cmd):
    """Return leases with FQDN updates for one Kea service."""
    sock_path = SOCKETS[service]
    if not os.path.exists(sock_path):
        return []

    try:
        subnets = get_subnets(sock_path, service)
        resp = send_command(sock_path, lease_cmd, {'subnets': list(subnets.keys())})
        if not isinstance(resp, dict) or resp.get('result') != 0:
            return []
        leases = resp.get('arguments', {}).get('leases', [])
    except (OSError, json.JSONDecodeError, KeyError):
        return []

    records = []
    for lease in leases:
        fqdn_fwd = lease.get('fqdn-fwd', False)
        fqdn_rev = lease.get('fqdn-rev', False)
        if not fqdn_fwd and not fqdn_rev:
            continue
        subnet_id = lease.get('subnet-id')
        records.append({
            'hostname': lease.get('hostname', ''),
            'address': lease.get('ip-address', ''),
            'hwaddr': lease.get('hw-address', ''),
            'fqdn_fwd': '1' if fqdn_fwd else '0',
            'fqdn_rev': '1' if fqdn_rev else '0',
            'state': str(lease.get('state', 0)),
            'expire': str(lease.get('cltt', 0) + lease.get('valid-lft', 0)),
            'subnet': subnets.get(subnet_id, ''),
        })
    return records


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--proto', choices=['inet', 'inet6'], default='inet')
    args = parser.parse_args()

    if args.proto == 'inet':
        records = collect_fqdn_leases('dhcp4', 'lease4-get-all')
    else:
        records = collect_fqdn_leases('dhcp6', 'lease6-get-all')

    print(json.dumps({'records': records}))


if __name__ == '__main__':
    main()
