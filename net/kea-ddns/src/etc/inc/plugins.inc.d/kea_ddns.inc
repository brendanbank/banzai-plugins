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

function kea_ddns_run()
{
    kea_ddns_check_core_patch();

    return [
        'kea_dhcpv4_config' => 'kea_ddns_get_dhcpv4_overlay',
        'kea_dhcpv6_config' => 'kea_ddns_get_dhcpv6_overlay',
        'kea_ddns_generate' => 'kea_ddns_generate_config',
    ];
}

function kea_ddns_check_core_patch()
{
    $kea_inc = '/usr/local/etc/inc/plugins.inc.d/kea.inc';
    $keav6_php = '/usr/local/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.php';
    if (
        strpos(@file_get_contents($kea_inc), 'kea_ddns_generate') !== false &&
        strpos(@file_get_contents($keav6_php), 'kea_dhcpv6_config') !== false
    ) {
        return;
    }

    $version_file = '/usr/local/opnsense/version/core';
    $patch_dir = '/usr/local/opnsense/data/kea-ddns/patches';

    $series = '';
    $version_json = @file_get_contents($version_file);
    if ($version_json !== false) {
        $version = @json_decode($version_json, true);
        if (isset($version['product_series'])) {
            $series = $version['product_series'];
        }
    }

    if (empty($series)) {
        syslog(LOG_WARNING, 'kea-ddns: cannot detect OPNsense series, skipping core patch check');
        return;
    }

    $patch = sprintf('%s/%s.patch', $patch_dir, $series);
    if (!file_exists($patch)) {
        syslog(LOG_WARNING, sprintf('kea-ddns: no patch file for OPNsense series %s (%s)', $series, $patch));
        return;
    }

    syslog(LOG_NOTICE, sprintf('kea-ddns: core patch missing, testing patch for OPNsense %s', $series));
    $dry = mwexec(sprintf('/usr/bin/patch --dry-run --forward --strip=1 --directory=/usr/local < %s', escapeshellarg($patch)));
    if ($dry != 0) {
        syslog(LOG_ERR, 'kea-ddns: core patch does not apply cleanly, manual intervention required');
        return;
    }
    syslog(LOG_NOTICE, 'kea-ddns: core patch dry-run passed, applying...');
    $ret = mwexec(sprintf('/usr/bin/patch --forward --strip=1 --directory=/usr/local < %s', escapeshellarg($patch)));
    if ($ret == 0) {
        syslog(LOG_NOTICE, 'kea-ddns: core patch applied successfully');
    } else {
        syslog(LOG_ERR, 'kea-ddns: core patch failed unexpectedly after dry-run');
    }
}

function kea_ddns_get_dhcpv4_overlay()
{
    $mdl = new \OPNsense\KeaDdns\KeaDdns();
    if (!$mdl->general->enabled->isEqual('1')) {
        return [];
    }
    return $mdl->getDhcpv4Overlay();
}

function kea_ddns_get_dhcpv6_overlay()
{
    $mdl = new \OPNsense\KeaDdns\KeaDdns();
    if (!$mdl->general->enabled->isEqual('1')) {
        return [];
    }
    return $mdl->getDhcpv6Overlay();
}

function kea_ddns_generate_config()
{
    $mdl = new \OPNsense\KeaDdns\KeaDdns();
    if (!$mdl->general->enabled->isEqual('1')) {
        return [];
    }
    if ($mdl->general->manual_config->isEmpty()) {
        $mdl->generateD2Config();
    }
    return ['enabled' => true];
}

function kea_ddns_services()
{
    $services = [];
    $mdl = new \OPNsense\KeaDdns\KeaDdns();
    if ($mdl->general->enabled->isEqual('1')) {
        $services[] = [
            'configd' => [
                'restart' => ['kea restart'],
                'start' => ['kea start'],
                'stop' => ['kea stop'],
            ],
            'name' => 'kea-dhcp',
            'description' => gettext('KEA DHCP DDNS server'),
            'pidfile' => '/var/run/kea/kea-dhcp-ddns.kea-dhcp-ddns.pid',
            'id' => 'ddns',
        ];
    }
    return $services;
}

function kea_ddns_syslog()
{
    return ['keaddns' => ['facility' => ['kea-dhcp-ddns']]];
}
