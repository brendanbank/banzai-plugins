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
}
