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

use OPNsense\Core\File;

/**
 * Register for the kea_sync configure event. Alphabetical ordering
 * (kea.inc < kea_ddns.inc) guarantees core generates configs first,
 * then this plugin post-processes them.
 */
function kea_ddns_configure()
{
    return [
        'kea_sync' => ['kea_ddns_configure_do'],
    ];
}

/**
 * Post-process Kea configs to add DDNS parameters. Runs after core's
 * kea_configure_do() generates kea-dhcp4.conf and kea-dhcp6.conf.
 */
function kea_ddns_configure_do($verbose = false)
{
    try {
        $mdl = new \OPNsense\KeaDdns\KeaDdns();
        if (!$mdl->general->enabled->isEqual('1')) {
            return;
        }

        service_log('Sync KEA DDNS config...', $verbose);

        kea_ddns_merge_config($mdl, '/usr/local/etc/kea/kea-dhcp4.conf', 'Dhcp4', 'subnet4', 'getDhcpv4Overlay');
        kea_ddns_merge_config($mdl, '/usr/local/etc/kea/kea-dhcp6.conf', 'Dhcp6', 'subnet6', 'getDhcpv6Overlay');

        if ($mdl->general->manual_config->isEmpty()) {
            $mdl->generateD2Config();
        }

        kea_ddns_update_keactrl(true);

        service_log("done.\n", $verbose);
    } catch (\Throwable $e) {
        @syslog(LOG_ERR, 'kea-ddns: configure failed: ' . $e->getMessage());
    }
}

/**
 * Read a Kea JSON config, merge DDNS overlay, write it back.
 */
function kea_ddns_merge_config($mdl, $target, $rootKey, $subnetKey, $overlayMethod)
{
    $json = @file_get_contents($target);
    if ($json === false) {
        return;
    }
    $cnf = json_decode($json, true);
    if (!is_array($cnf) || !isset($cnf[$rootKey])) {
        return;
    }

    $overlay = $mdl->$overlayMethod();

    if (isset($overlay['global'])) {
        $cnf[$rootKey] = array_merge($cnf[$rootKey], $overlay['global']);
    }

    if (isset($overlay['subnets']) && isset($cnf[$rootKey][$subnetKey])) {
        foreach ($cnf[$rootKey][$subnetKey] as &$subnet) {
            if (isset($overlay['subnets'][$subnet['subnet']])) {
                $subnet = array_merge($subnet, $overlay['subnets'][$subnet['subnet']]);
            }
        }
        unset($subnet);
    }

    File::file_put_contents($target, json_encode($cnf, JSON_PRETTY_PRINT), 0600);
}

/**
 * Enable or disable the DDNS daemon in keactrl.conf.
 */
function kea_ddns_update_keactrl($enabled)
{
    $keactrl = '/usr/local/etc/kea/keactrl.conf';
    $content = @file_get_contents($keactrl);
    if ($content === false) {
        return;
    }
    $content = preg_replace(
        '/^dhcp_ddns=.*$/m',
        'dhcp_ddns=' . ($enabled ? 'yes' : 'no'),
        $content
    );
    @file_put_contents($keactrl, $content);
}

function kea_ddns_services()
{
    try {
        $services = [];
        $mdl = new \OPNsense\KeaDdns\KeaDdns();
        if (!$mdl->general->enabled->isEqual('1')) {
            return $services;
        }
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
        return $services;
    } catch (\Throwable $e) {
        @syslog(LOG_ERR, 'kea-ddns: services failed: ' . $e->getMessage());
        return [];
    }
}

function kea_ddns_xmlrpc_sync()
{
    return [[
        'description' => gettext('Kea DDNS'),
        'section' => 'OPNsense.KeaDdns',
        'id' => 'keaddns',
        'services' => ['kea-dhcp-ddns'],
    ]];
}

function kea_ddns_syslog()
{
    return ['keaddns' => ['facility' => ['kea-dhcp-ddns']]];
}
