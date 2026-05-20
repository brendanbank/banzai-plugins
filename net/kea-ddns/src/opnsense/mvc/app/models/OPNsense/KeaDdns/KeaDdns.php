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
     * Build the global DDNS defaults array from general settings.
     */
    private function buildGlobalDdnsDefaults()
    {
        $globals = [
            'dhcp-ddns' => [
                'enable-updates' => true,
                'server-ip' => '127.0.0.1',
                'server-port' => 53001,
            ],
            'hostname-char-set' => '[^A-Za-z0-9.-]',
            'hostname-char-replacement' => '-',
            'ddns-send-updates' => (string)$this->general->send_updates === '1',
            'ddns-update-on-renew' => (string)$this->general->update_on_renew === '1',
            'ddns-override-no-update' => (string)$this->general->override_no_update === '1',
            'ddns-override-client-update' => (string)$this->general->override_client_update === '1',
            'ddns-replace-client-name' => (string)$this->general->replace_client_name,
            'ddns-conflict-resolution-mode' => (string)$this->general->conflict_resolution,
        ];

        $suffix = (string)$this->general->qualifying_suffix;
        if ($suffix !== '') {
            if (substr($suffix, -1) !== '.') {
                $suffix .= '.';
            }
            $globals['ddns-qualifying-suffix'] = $suffix;
        }

        $prefix = (string)$this->general->generated_prefix;
        if ($prefix !== '') {
            $globals['ddns-generated-prefix'] = $prefix;
        }

        return $globals;
    }

    /**
     * Build per-subnet DDNS entry from an assignment, only including
     * fields that have explicit overrides (non-empty values).
     */
    private function buildSubnetDdnsEntry($assignment)
    {
        $entry = [];

        $val = (string)$assignment->send_updates;
        if ($val !== '') {
            $entry['ddns-send-updates'] = ($val === '1');
        }

        $val = (string)$assignment->update_on_renew;
        if ($val !== '') {
            $entry['ddns-update-on-renew'] = ($val === '1');
        }

        $val = (string)$assignment->override_no_update;
        if ($val !== '') {
            $entry['ddns-override-no-update'] = ($val === '1');
        }

        $val = (string)$assignment->override_client_update;
        if ($val !== '') {
            $entry['ddns-override-client-update'] = ($val === '1');
        }

        $val = (string)$assignment->replace_client_name;
        if ($val !== '') {
            $entry['ddns-replace-client-name'] = $val;
        }

        $val = (string)$assignment->conflict_resolution;
        if ($val !== '') {
            $entry['ddns-conflict-resolution-mode'] = $val;
        }

        if (!$assignment->qualifying_suffix->isEmpty()) {
            $suffix = $assignment->qualifying_suffix->getValue();
            if (substr($suffix, -1) !== '.') {
                $suffix .= '.';
            }
            $entry['ddns-qualifying-suffix'] = $suffix;
        }

        if (!$assignment->generated_prefix->isEmpty()) {
            $entry['ddns-generated-prefix'] = $assignment->generated_prefix->getValue();
        }

        return $entry;
    }

    /**
     * Return the DDNS overlay for kea-dhcp6.conf. Contains global DDNS settings
     * and per-subnet parameters keyed by CIDR string.
     */
    public function getDhcpv6Overlay()
    {
        $result = [
            'global' => $this->buildGlobalDdnsDefaults(),
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

            $entry = $this->buildSubnetDdnsEntry($assignment);
            $entry['rapid-commit'] = $assignment->rapid_commit->isEqual('1');

            $result['subnets'][$cidr] = $entry;
        }

        return $result;
    }

    /**
     * Return the DDNS overlay for kea-dhcp4.conf. Contains global DDNS settings
     * and per-subnet parameters keyed by CIDR string.
     */
    public function getDhcpv4Overlay()
    {
        $result = [
            'global' => $this->buildGlobalDdnsDefaults(),
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

            $result['subnets'][$cidr] = $this->buildSubnetDdnsEntry($assignment);
        }

        return $result;
    }
}
