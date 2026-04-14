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

namespace OPNsense\KeaDdns\Api;

use OPNsense\Base\ApiMutableModelControllerBase;
use OPNsense\Core\Backend;

class GeneralController extends ApiMutableModelControllerBase
{
    protected static $internalModelName = 'keaddns';
    protected static $internalModelClass = 'OPNsense\KeaDdns\KeaDdns';

    /* TSIG keys */
    public function searchTsigKeyAction()
    {
        return $this->searchBase('tsig_keys.tsig_key', null, 'name');
    }
    public function getTsigKeyAction($uuid = null)
    {
        return $this->getBase('tsig_key', 'tsig_keys.tsig_key', $uuid);
    }
    public function addTsigKeyAction()
    {
        return $this->addBase('tsig_key', 'tsig_keys.tsig_key');
    }
    public function setTsigKeyAction($uuid)
    {
        return $this->setBase('tsig_key', 'tsig_keys.tsig_key', $uuid);
    }
    public function delTsigKeyAction($uuid)
    {
        return $this->delBase('tsig_keys.tsig_key', $uuid);
    }

    /**
     * Generate a random TSIG secret for the given algorithm.
     */
    public function generateTsigSecretAction()
    {
        if ($this->request->isPost()) {
            $algorithm = $this->request->getPost('algorithm', 'striptags', 'HMAC-SHA256');
            $keyLengths = [
                'HMAC-MD5' => 16,
                'HMAC-SHA1' => 20,
                'HMAC-SHA224' => 28,
                'HMAC-SHA256' => 32,
                'HMAC-SHA384' => 48,
                'HMAC-SHA512' => 64,
            ];
            $len = $keyLengths[$algorithm] ?? 32;
            return ['secret' => base64_encode(random_bytes($len))];
        }
        return ['status' => 'error'];
    }

    /* Forward zones */
    public function searchForwardZoneAction()
    {
        return $this->searchBase('forward_zones.zone', null, 'name');
    }
    public function getForwardZoneAction($uuid = null)
    {
        return $this->getBase('zone', 'forward_zones.zone', $uuid);
    }
    public function addForwardZoneAction()
    {
        return $this->addBase('zone', 'forward_zones.zone');
    }
    public function setForwardZoneAction($uuid)
    {
        return $this->setBase('zone', 'forward_zones.zone', $uuid);
    }
    public function delForwardZoneAction($uuid)
    {
        return $this->delBase('forward_zones.zone', $uuid);
    }

    /* Reverse zones */
    public function searchReverseZoneAction()
    {
        return $this->searchBase('reverse_zones.zone', null, 'name');
    }
    public function getReverseZoneAction($uuid = null)
    {
        return $this->getBase('zone', 'reverse_zones.zone', $uuid);
    }
    public function addReverseZoneAction()
    {
        return $this->addBase('zone', 'reverse_zones.zone');
    }
    public function setReverseZoneAction($uuid)
    {
        return $this->setBase('zone', 'reverse_zones.zone', $uuid);
    }
    public function delReverseZoneAction($uuid)
    {
        return $this->delBase('reverse_zones.zone', $uuid);
    }

    /* Subnet DDNS assignments (DHCPv4) */
    public function searchSubnetDdnsAction()
    {
        return $this->searchBase('subnet_ddns.assignment', null, 'subnet');
    }
    public function getSubnetDdnsAction($uuid = null)
    {
        return $this->getBase('assignment', 'subnet_ddns.assignment', $uuid);
    }
    public function addSubnetDdnsAction()
    {
        return $this->addBase('assignment', 'subnet_ddns.assignment');
    }
    public function setSubnetDdnsAction($uuid)
    {
        return $this->setBase('assignment', 'subnet_ddns.assignment', $uuid);
    }
    public function delSubnetDdnsAction($uuid)
    {
        return $this->delBase('subnet_ddns.assignment', $uuid);
    }

    /* Subnet6 DDNS assignments (DHCPv6) */
    public function searchSubnet6DdnsAction()
    {
        return $this->searchBase('subnet6_ddns.assignment', null, 'subnet');
    }
    public function getSubnet6DdnsAction($uuid = null)
    {
        return $this->getBase('assignment', 'subnet6_ddns.assignment', $uuid);
    }
    public function addSubnet6DdnsAction()
    {
        return $this->addBase('assignment', 'subnet6_ddns.assignment');
    }
    public function setSubnet6DdnsAction($uuid)
    {
        return $this->setBase('assignment', 'subnet6_ddns.assignment', $uuid);
    }
    public function delSubnet6DdnsAction($uuid)
    {
        return $this->delBase('subnet6_ddns.assignment', $uuid);
    }

    /**
     * Suggest reverse zone names derived from configured Kea subnets.
     * Returns all DHCPv4 and DHCPv6 subnets with their corresponding
     * in-addr.arpa / ip6.arpa zone names.
     */
    public function suggestReverseZonesAction()
    {
        $suggestions = [];

        /* DHCPv4 subnets */
        $keav4 = new \OPNsense\Kea\KeaDhcpv4();
        foreach ($keav4->subnets->subnet4->iterateItems() as $subnet) {
            $cidr = $subnet->subnet->getValue();
            if (empty($cidr) || strpos($cidr, '/') === false) {
                continue;
            }
            list($ip, $prefix) = explode('/', $cidr, 2);
            $zone = $this->deriveIpv4ReverseZone($ip, (int)$prefix);
            if ($zone !== null) {
                $suggestions[] = ['subnet' => $cidr, 'zone' => $zone, 'family' => 'IPv4'];
            }
        }

        /* DHCPv6 subnets */
        $keav6 = new \OPNsense\Kea\KeaDhcpv6();
        foreach ($keav6->subnets->subnet6->iterateItems() as $subnet) {
            $cidr = $subnet->subnet->getValue();
            if (empty($cidr) || strpos($cidr, '/') === false) {
                continue;
            }
            list($ip, $prefix) = explode('/', $cidr, 2);
            $zone = $this->deriveIpv6ReverseZone($ip, (int)$prefix);
            if ($zone !== null) {
                $suggestions[] = ['subnet' => $cidr, 'zone' => $zone, 'family' => 'IPv6'];
            }
        }

        return ['suggestions' => $suggestions];
    }

    private function deriveIpv4ReverseZone($ip, $prefix)
    {
        if (!filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
            return null;
        }
        $octets = explode('.', $ip);
        /* round up to nearest octet boundary */
        $significantOctets = (int)ceil($prefix / 8);
        if ($significantOctets < 1) {
            $significantOctets = 1;
        }
        if ($significantOctets > 3) {
            $significantOctets = 3;
        }
        $reversed = array_reverse(array_slice($octets, 0, $significantOctets));
        return implode('.', $reversed) . '.in-addr.arpa';
    }

    private function deriveIpv6ReverseZone($ip, $prefix)
    {
        $packed = @inet_pton($ip);
        if ($packed === false) {
            return null;
        }
        $hex = bin2hex($packed);
        /* round up to nearest nibble boundary (4 bits) */
        $nibbles = (int)ceil($prefix / 4);
        if ($nibbles < 1) {
            $nibbles = 1;
        }
        if ($nibbles > 31) {
            $nibbles = 31;
        }
        $significant = substr($hex, 0, $nibbles);
        $reversed = implode('.', array_reverse(str_split($significant)));
        return $reversed . '.ip6.arpa';
    }

    /* DDNS status dashboard */
    public function ddnsStatusAction()
    {
        $backend = new Backend();
        $response = json_decode(trim($backend->configdRun('kea_ddns status')), true);
        if (!is_array($response)) {
            return ['running' => false];
        }
        return $response;
    }

    public function searchDdnsLeases4Action()
    {
        return $this->searchDdnsLeasesProto('kea_ddns ddns_leases4');
    }

    public function searchDdnsLeases6Action()
    {
        return $this->searchDdnsLeasesProto('kea_ddns ddns_leases6');
    }

    private function searchDdnsLeasesProto($cmd)
    {
        $backend = new Backend();
        $records = [];

        $data = json_decode(trim($backend->configdRun($cmd)), true);
        if (!empty($data['records'])) {
            foreach ($data['records'] as $rec) {
                $records[] = [
                    'hostname' => $rec['hostname'] ?? '',
                    'address' => $rec['address'] ?? '',
                    'hwaddr' => $rec['hwaddr'] ?? '',
                    'fqdn_fwd' => $rec['fqdn_fwd'] ?? '0',
                    'fqdn_rev' => $rec['fqdn_rev'] ?? '0',
                    'state' => $rec['state'] ?? '',
                    'expire' => $rec['expire'] ?? '',
                    'subnet' => $rec['subnet'] ?? '',
                ];
            }
        }

        return $this->searchRecordsetBase($records, null, 'hostname');
    }
}
