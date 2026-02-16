<?php

/*
 * Copyright (C) 2026 Brendan Bank <brendan.bank@gmail.com>
 * Copyright (C) 2026 Yip Rui Fung <rf@yrf.me>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
 * OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

namespace OPNsense\KeaDdns;

use OPNsense\Base\BaseModel;
use OPNsense\Core\File;

class KeaDdns extends BaseModel
{
    /**
     * Generate the kea-dhcp-ddns.conf (D2 daemon) configuration file.
     */
    public function generateD2Config($target = '/usr/local/etc/kea/kea-dhcp-ddns.conf')
    {
        /* collect TSIG keys */
        $tsigKeys = [];
        $tsigNameMap = [];
        foreach ($this->tsig_keys->tsig_key->iterateItems() as $uuid => $key) {
            $tsigKeys[] = [
                'name' => $key->name->getValue(),
                'algorithm' => $key->algorithm->getValue(),
                'secret' => $key->secret->getValue(),
            ];
            $tsigNameMap[$uuid] = $key->name->getValue();
        }

        /* build forward domains */
        $forwardDomains = [];
        foreach ($this->forward_zones->zone->iterateItems() as $zone) {
            $name = $zone->name->getValue();
            if (substr($name, -1) !== '.') {
                $name .= '.';
            }
            $server = [
                'ip-address' => $zone->server->getValue(),
                'port' => $zone->port->asInt(),
            ];
            $keyUuid = (string)$zone->tsig_key;
            if (!empty($keyUuid) && isset($tsigNameMap[$keyUuid])) {
                $server['key-name'] = $tsigNameMap[$keyUuid];
            }
            $forwardDomains[] = [
                'name' => $name,
                'dns-servers' => [$server],
            ];
        }

        /* build reverse domains */
        $reverseDomains = [];
        foreach ($this->reverse_zones->zone->iterateItems() as $zone) {
            $name = $zone->name->getValue();
            if (substr($name, -1) !== '.') {
                $name .= '.';
            }
            $server = [
                'ip-address' => $zone->server->getValue(),
                'port' => $zone->port->asInt(),
            ];
            $keyUuid = (string)$zone->tsig_key;
            if (!empty($keyUuid) && isset($tsigNameMap[$keyUuid])) {
                $server['key-name'] = $tsigNameMap[$keyUuid];
            }
            $reverseDomains[] = [
                'name' => $name,
                'dns-servers' => [$server],
            ];
        }

        $cnf = [
            'DhcpDdns' => [
                'ip-address' => '127.0.0.1',
                'port' => 53001,
                'control-socket' => [
                    'socket-type' => 'unix',
                    'socket-name' => '/var/run/kea/kea-ddns-ctrl-socket',
                ],
                'loggers' => [[
                    'name' => 'kea-dhcp-ddns',
                    'output_options' => [['output' => 'syslog']],
                    'severity' => 'INFO',
                ]],
                'tsig-keys' => $tsigKeys,
                'forward-ddns' => ['ddns-domains' => $forwardDomains],
                'reverse-ddns' => ['ddns-domains' => $reverseDomains],
            ]
        ];

        File::file_put_contents($target, json_encode($cnf, JSON_PRETTY_PRINT), 0600);
        return true;
    }

    /**
     * Return the overlay array that core's generateConfig() merges into kea-dhcp6.conf.
     * Keyed by subnet CIDR string.
     */
    public function getDhcpv6Overlay()
    {
        $result = [
            'global' => [
                'dhcp-ddns' => [
                    'enable-updates' => true,
                    'server-ip' => '127.0.0.1',
                    'server-port' => 53001,
                ],
                'hostname-char-set' => '[^A-Za-z0-9.-]',
                'hostname-char-replacement' => '-',
            ],
            'subnets' => [],
        ];

        /* resolve subnet UUIDs to CIDR strings */
        $keav6 = new \OPNsense\Kea\KeaDhcpv6();
        $subnetCidrMap = [];
        foreach ($keav6->subnets->subnet6->iterateItems() as $uuid => $subnet) {
            $subnetCidrMap[$uuid] = $subnet->subnet->getValue();
        }

        foreach ($this->subnet6_ddns->assignment->iterateItems() as $assignment) {
            $subnetUuid = (string)$assignment->subnet;
            if (empty($subnetUuid) || !isset($subnetCidrMap[$subnetUuid])) {
                continue;
            }
            $cidr = $subnetCidrMap[$subnetUuid];

            $entry = [
                'ddns-send-updates' => $assignment->send_updates->isEqual('1'),
                'ddns-update-on-renew' => $assignment->update_on_renew->isEqual('1'),
                'ddns-conflict-resolution-mode' => $assignment->conflict_resolution->getValue(),
                'ddns-replace-client-name' => $assignment->replace_client_name->getValue(),
            ];
            if (!$assignment->qualifying_suffix->isEmpty()) {
                $suffix = $assignment->qualifying_suffix->getValue();
                if (substr($suffix, -1) !== '.') {
                    $suffix .= '.';
                }
                $entry['ddns-qualifying-suffix'] = $suffix;
            }
            $result['subnets'][$cidr] = $entry;
        }

        return $result;
    }

    /**
     * Return the overlay array that core's generateConfig() merges into kea-dhcp4.conf.
     * Keyed by subnet CIDR string.
     */
    public function getDhcpv4Overlay()
    {
        $result = [
            'global' => [
                'dhcp-ddns' => [
                    'enable-updates' => true,
                    'server-ip' => '127.0.0.1',
                    'server-port' => 53001,
                ],
                'hostname-char-set' => '[^A-Za-z0-9.-]',
                'hostname-char-replacement' => '-',
            ],
            'subnets' => [],
        ];

        /* resolve subnet UUIDs to CIDR strings */
        $keav4 = new \OPNsense\Kea\KeaDhcpv4();
        $subnetCidrMap = [];
        foreach ($keav4->subnets->subnet4->iterateItems() as $uuid => $subnet) {
            $subnetCidrMap[$uuid] = $subnet->subnet->getValue();
        }

        foreach ($this->subnet_ddns->assignment->iterateItems() as $assignment) {
            $subnetUuid = (string)$assignment->subnet;
            if (empty($subnetUuid) || !isset($subnetCidrMap[$subnetUuid])) {
                continue;
            }
            $cidr = $subnetCidrMap[$subnetUuid];

            $entry = [
                'ddns-send-updates' => $assignment->send_updates->isEqual('1'),
                'ddns-update-on-renew' => $assignment->update_on_renew->isEqual('1'),
                'ddns-conflict-resolution-mode' => $assignment->conflict_resolution->getValue(),
                'ddns-replace-client-name' => $assignment->replace_client_name->getValue(),
            ];
            if (!$assignment->qualifying_suffix->isEmpty()) {
                $suffix = $assignment->qualifying_suffix->getValue();
                if (substr($suffix, -1) !== '.') {
                    $suffix .= '.';
                }
                $entry['ddns-qualifying-suffix'] = $suffix;
            }
            $result['subnets'][$cidr] = $entry;
        }

        return $result;
    }
}
