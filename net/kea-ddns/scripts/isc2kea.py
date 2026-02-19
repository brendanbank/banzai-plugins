#!/usr/bin/env python3

"""
ISC DHCP to Kea DHCP migration script for OPNsense.

Migrates one interface at a time from the legacy ISC DHCP configuration
(stored in config.xml) to Kea DHCP via the OPNsense API.

Usage:
    python isc2kea.py opt1 --api-key KEY --api-secret SECRET
    python isc2kea.py opt1 --api-key KEY --api-secret SECRET --dry-run
    python isc2kea.py opt1 --config-file ./config.xml --api-key KEY --api-secret SECRET
"""

import argparse
import ipaddress
import logging
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import Optional

import requests
import urllib3

# Suppress SSL warnings for self-signed certs
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class StaticMapping:
    mac: str
    ipaddr: str
    hostname: str = ''
    description: str = ''


@dataclass
class NumberOption:
    number: str
    type: str
    value: str


@dataclass
class DhcpInterfaceConfig:
    interface: str          # internal name, e.g. opt1
    enabled: bool = False
    subnet: str = ''        # CIDR, e.g. 10.2.21.0/24
    ipaddr: str = ''        # interface IP
    range_from: str = ''
    range_to: str = ''
    gateway: str = ''
    domain: str = ''
    domain_search: str = ''
    dns_servers: list = field(default_factory=list)
    ntp_servers: list = field(default_factory=list)
    default_lease_time: str = ''
    max_lease_time: str = ''
    # DDNS
    ddns_enable: bool = False
    ddns_domainname: str = ''
    ddns_domainprimary: str = ''
    ddns_domainkey: str = ''
    ddns_domainkeyname: str = ''
    ddns_domainalgorithm: str = 'hmac-md5'
    # Derived DDNS fields
    ddns_forward_zone: str = ''
    ddns_prefix: str = ''
    # Static mappings
    static_mappings: list = field(default_factory=list)
    # Custom options
    number_options: list = field(default_factory=list)


# ---------------------------------------------------------------------------
# Config reader
# ---------------------------------------------------------------------------

class ConfigReader:
    """Reads config.xml from a local file or via SSH."""

    @staticmethod
    def read(host: str, ssh_user: str, config_file: Optional[str] = None) -> ET.Element:
        if config_file:
            log.info('Reading config from local file: %s', config_file)
            tree = ET.parse(config_file)
            return tree.getroot()

        log.info('Fetching config.xml from %s via SSH', host)
        cmd = ['ssh', f'{ssh_user}@{host}', 'cat /conf/config.xml']
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return ET.fromstring(result.stdout)


# ---------------------------------------------------------------------------
# ISC DHCP parser
# ---------------------------------------------------------------------------

class IscDhcpParser:
    """Parses ISC DHCP config for one interface from config.xml."""

    ALGORITHM_MAP = {
        'hmac-md5': 'HMAC-MD5',
        'hmac-sha1': 'HMAC-SHA1',
        'hmac-sha224': 'HMAC-SHA224',
        'hmac-sha256': 'HMAC-SHA256',
        'hmac-sha384': 'HMAC-SHA384',
        'hmac-sha512': 'HMAC-SHA512',
    }

    @staticmethod
    def parse(root: ET.Element, interface: str, forward_zone_override: Optional[str] = None) -> DhcpInterfaceConfig:
        cfg = DhcpInterfaceConfig(interface=interface)

        # Get interface IP/subnet from <interfaces>
        iface_el = root.find(f'interfaces/{interface}')
        if iface_el is None:
            raise SystemExit(f'Interface {interface!r} not found in config.xml <interfaces>')

        ipaddr = iface_el.findtext('ipaddr', '')
        subnet_bits = iface_el.findtext('subnet', '')
        if ipaddr and subnet_bits:
            net = ipaddress.IPv4Network(f'{ipaddr}/{subnet_bits}', strict=False)
            cfg.subnet = str(net)
            cfg.ipaddr = ipaddr

        # Get DHCP config from <dhcpd>
        dhcp_el = root.find(f'dhcpd/{interface}')
        if dhcp_el is None:
            raise SystemExit(f'No ISC DHCP config found for interface {interface!r} in <dhcpd>')

        cfg.enabled = dhcp_el.find('enable') is not None
        cfg.gateway = dhcp_el.findtext('gateway', '')
        cfg.domain = dhcp_el.findtext('domain', '')
        cfg.domain_search = dhcp_el.findtext('domainsearchlist', '')
        cfg.default_lease_time = dhcp_el.findtext('defaultleasetime', '')
        cfg.max_lease_time = dhcp_el.findtext('maxleasetime', '')

        # DNS servers
        for dns_el in dhcp_el.findall('dnsserver'):
            if dns_el.text:
                cfg.dns_servers.append(dns_el.text)

        # NTP servers
        for ntp_el in dhcp_el.findall('ntpserver'):
            if ntp_el.text:
                cfg.ntp_servers.append(ntp_el.text)

        # Range
        range_el = dhcp_el.find('range')
        if range_el is not None:
            cfg.range_from = range_el.findtext('from', '')
            cfg.range_to = range_el.findtext('to', '')

        # DDNS settings
        cfg.ddns_enable = dhcp_el.find('ddnsupdate') is not None
        cfg.ddns_domainname = dhcp_el.findtext('ddnsdomain', '')
        cfg.ddns_domainprimary = dhcp_el.findtext('ddnsdomainprimary', '')
        cfg.ddns_domainkey = dhcp_el.findtext('ddnsdomainkey', '')
        cfg.ddns_domainkeyname = dhcp_el.findtext('ddnsdomainkeyname', '')
        cfg.ddns_domainalgorithm = dhcp_el.findtext('ddnsdomainalgorithm', 'hmac-md5')

        # Derive forward zone and prefix from ddnsdomainname
        # e.g. casa.dyn.bgwlan.nl -> prefix=casa, zone=dyn.bgwlan.nl
        if cfg.ddns_domainname:
            if forward_zone_override:
                cfg.ddns_forward_zone = forward_zone_override
                # Strip the zone suffix to get the prefix
                suffix = '.' + forward_zone_override
                if cfg.ddns_domainname.endswith(suffix):
                    cfg.ddns_prefix = cfg.ddns_domainname[:-len(suffix)]
                else:
                    cfg.ddns_prefix = cfg.ddns_domainname.split('.')[0]
            else:
                parts = cfg.ddns_domainname.split('.', 1)
                if len(parts) == 2:
                    cfg.ddns_prefix = parts[0]
                    cfg.ddns_forward_zone = parts[1]
                else:
                    cfg.ddns_forward_zone = cfg.ddns_domainname

        # Static mappings
        for sm_el in dhcp_el.findall('staticmap'):
            mac = sm_el.findtext('mac', '')
            ipaddr = sm_el.findtext('ipaddr', '')
            if mac:
                cfg.static_mappings.append(StaticMapping(
                    mac=mac,
                    ipaddr=ipaddr,
                    hostname=sm_el.findtext('hostname', ''),
                    description=sm_el.findtext('descr', ''),
                ))

        # Number options (skip empty <item/> placeholders)
        numberopts_el = dhcp_el.find('numberoptions')
        if numberopts_el is not None:
            for item_el in numberopts_el.findall('item'):
                number = item_el.findtext('number', '')
                if number:
                    cfg.number_options.append(NumberOption(
                        number=number,
                        type=item_el.findtext('type', ''),
                        value=item_el.findtext('value', ''),
                    ))

        return cfg


# ---------------------------------------------------------------------------
# OPNsense API client
# ---------------------------------------------------------------------------

class KeaApiClient:
    """Wrapper for the OPNsense Kea DHCP and Kea DDNS APIs."""

    def __init__(self, host: str, api_key: str, api_secret: str):
        self.base_url = f'https://{host}/api'
        self.auth = (api_key, api_secret)
        self.session = requests.Session()
        self.session.auth = self.auth
        self.session.verify = False

    def _get(self, path: str) -> dict:
        url = f'{self.base_url}{path}'
        log.debug('GET %s', url)
        r = self.session.get(url)
        r.raise_for_status()
        return r.json()

    def _post(self, path: str, data: Optional[dict] = None) -> dict:
        url = f'{self.base_url}{path}'
        log.debug('POST %s %s', url, data)
        r = self.session.post(url, json=data or {})
        r.raise_for_status()
        return r.json()

    # -- Kea DHCPv4 general settings ----------------------------------------

    def get_settings(self) -> dict:
        return self._get('/kea/dhcpv4/get')

    def set_settings(self, data: dict) -> dict:
        return self._post('/kea/dhcpv4/set', {'dhcpv4': data})

    # -- Kea DHCPv4 subnets -------------------------------------------------

    def search_subnets(self) -> list:
        resp = self._post('/kea/dhcpv4/searchSubnet', {'rowCount': -1, 'current': 1})
        return resp.get('rows', [])

    def add_subnet(self, data: dict) -> dict:
        return self._post('/kea/dhcpv4/addSubnet', {'subnet4': data})

    def set_subnet(self, uuid: str, data: dict) -> dict:
        return self._post(f'/kea/dhcpv4/setSubnet/{uuid}', {'subnet4': data})

    def get_subnet(self, uuid: str) -> dict:
        return self._get(f'/kea/dhcpv4/getSubnet/{uuid}')

    # -- Kea DHCPv4 reservations --------------------------------------------

    def search_reservations(self) -> list:
        resp = self._post('/kea/dhcpv4/searchReservation', {'rowCount': -1, 'current': 1})
        return resp.get('rows', [])

    def add_reservation(self, data: dict) -> dict:
        return self._post('/kea/dhcpv4/addReservation', {'reservation': data})

    # -- Kea DDNS TSIG keys (via keaddns plugin) ----------------------------

    def search_tsig_keys(self) -> list:
        resp = self._post('/keaddns/general/searchTsigKey', {'rowCount': -1, 'current': 1})
        return resp.get('rows', [])

    def add_tsig_key(self, data: dict) -> dict:
        return self._post('/keaddns/general/addTsigKey', {'tsig_key': data})

    # -- Kea DDNS forward zones (via keaddns plugin) ------------------------

    def search_forward_zones(self) -> list:
        resp = self._post('/keaddns/general/searchForwardZone', {'rowCount': -1, 'current': 1})
        return resp.get('rows', [])

    def add_forward_zone(self, data: dict) -> dict:
        return self._post('/keaddns/general/addForwardZone', {'zone': data})

    # -- Kea DDNS reverse zones (via keaddns plugin) ------------------------

    def search_reverse_zones(self) -> list:
        resp = self._post('/keaddns/general/searchReverseZone', {'rowCount': -1, 'current': 1})
        return resp.get('rows', [])

    def add_reverse_zone(self, data: dict) -> dict:
        return self._post('/keaddns/general/addReverseZone', {'zone': data})

    # -- Kea DDNS subnet assignments (via keaddns plugin) -------------------

    def search_subnet_ddns(self) -> list:
        resp = self._post('/keaddns/general/searchSubnetDdns', {'rowCount': -1, 'current': 1})
        return resp.get('rows', [])

    def add_subnet_ddns(self, data: dict) -> dict:
        return self._post('/keaddns/general/addSubnetDdns', {'assignment': data})

    # -- Service ------------------------------------------------------------

    def reconfigure(self) -> dict:
        return self._post('/kea/service/reconfigure')


# ---------------------------------------------------------------------------
# Migrator
# ---------------------------------------------------------------------------

class KeaMigrator:
    """Orchestrates the migration of one ISC DHCP interface to Kea."""

    def __init__(self, api: KeaApiClient, dry_run: bool = False):
        self.api = api
        self.dry_run = dry_run

    def migrate(self, cfg: DhcpInterfaceConfig, reverse_zone: str = '',
                no_reconfigure: bool = False):
        log.info('=== Migrating interface %s (subnet %s) ===', cfg.interface, cfg.subnet)

        if not cfg.subnet:
            raise SystemExit(f'No subnet could be determined for interface {cfg.interface}')

        self._print_summary(cfg)

        # Step 1: Ensure interface is in Kea general.interfaces
        self._ensure_interface(cfg.interface)

        # Step 2-4: DDNS key, forward zone, reverse zone (if DDNS enabled)
        fwd_zone_uuid = ''
        if cfg.ddns_enable and cfg.ddns_forward_zone:
            key_uuid = self._ensure_ddns_key(cfg)
            fwd_zone_uuid = self._ensure_forward_zone(cfg, key_uuid)
            self._ensure_reverse_zone(cfg, key_uuid, reverse_zone)

        # Step 5: Create subnet
        subnet_uuid = self._create_subnet(cfg)

        # Step 6: Create subnet DDNS assignment
        if fwd_zone_uuid and subnet_uuid:
            self._create_subnet_ddns(cfg, subnet_uuid, fwd_zone_uuid)

        # Step 7: Create static reservations
        self._create_reservations(cfg, subnet_uuid)

        # Step 8: Warn about custom options
        if cfg.number_options:
            log.warning('Interface has %d custom DHCP options that need manual migration:',
                        len(cfg.number_options))
            for opt in cfg.number_options:
                log.warning('  Option %s (type=%s): %s', opt.number, opt.type, opt.value)

        # Step 9: Reconfigure
        if not no_reconfigure:
            if self.dry_run:
                log.info('[DRY RUN] Would reconfigure Kea service')
            else:
                log.info('Reconfiguring Kea service...')
                resp = self.api.reconfigure()
                log.info('Reconfigure response: %s', resp)

        log.info('=== Migration complete for %s ===', cfg.interface)
        log.info('Remember to manually disable ISC DHCP for interface %s', cfg.interface)

    def _print_summary(self, cfg: DhcpInterfaceConfig):
        log.info('Interface: %s', cfg.interface)
        log.info('Subnet: %s', cfg.subnet)
        log.info('IP: %s', cfg.ipaddr)
        log.info('Range: %s - %s', cfg.range_from, cfg.range_to)
        log.info('Gateway: %s', cfg.gateway)
        log.info('DNS: %s', ', '.join(cfg.dns_servers))
        log.info('Domain: %s', cfg.domain)
        log.info('Lease time: default=%s max=%s', cfg.default_lease_time, cfg.max_lease_time)
        if cfg.ddns_enable:
            log.info('DDNS: zone=%s prefix=%s key=%s',
                     cfg.ddns_forward_zone, cfg.ddns_prefix, cfg.ddns_domainkeyname)
        log.info('Static mappings: %d', len(cfg.static_mappings))
        if cfg.number_options:
            log.info('Custom options: %d (will need manual migration)', len(cfg.number_options))

    def _ensure_interface(self, interface: str):
        """Add interface to Kea general.interfaces if not already present."""
        if self.dry_run:
            log.info('[DRY RUN] Would ensure %s is in Kea interfaces', interface)
            return

        settings = self.api.get_settings()
        general = settings.get('dhcpv4', {}).get('general', {})
        interfaces_field = general.get('interfaces', {})

        # interfaces is a dict of iface_name -> {value, selected}
        already_selected = []
        for iface_name, iface_data in interfaces_field.items():
            if isinstance(iface_data, dict) and iface_data.get('selected', 0):
                already_selected.append(iface_name)

        if interface in already_selected:
            log.info('Interface %s already in Kea interfaces', interface)
            return

        already_selected.append(interface)
        new_value = ','.join(already_selected)

        log.info('Adding %s to Kea interfaces (new: %s)', interface, new_value)
        resp = self.api.set_settings({'general': {'interfaces': new_value}})
        self._check_response(resp, 'set interfaces')

    def _ensure_ddns_key(self, cfg: DhcpInterfaceConfig) -> str:
        """Find or create the DDNS TSIG key. Returns UUID."""
        algorithm = IscDhcpParser.ALGORITHM_MAP.get(
            cfg.ddns_domainalgorithm.lower(), 'HMAC-SHA256')

        if self.dry_run:
            log.info('[DRY RUN] Would ensure TSIG key: %s (algo=%s)', cfg.ddns_domainkeyname,
                     algorithm)
            return 'dry-run-key-uuid'

        existing = self.api.search_tsig_keys()
        for key_row in existing:
            if key_row.get('name') == cfg.ddns_domainkeyname:
                log.info('TSIG key %r already exists (uuid=%s)', cfg.ddns_domainkeyname,
                         key_row['uuid'])
                return key_row['uuid']

        key_data = {
            'name': cfg.ddns_domainkeyname,
            'algorithm': algorithm,
            'secret': cfg.ddns_domainkey,
        }

        log.info('Creating TSIG key: %s (algo=%s)', cfg.ddns_domainkeyname, algorithm)
        resp = self.api.add_tsig_key(key_data)
        self._check_response(resp, 'add TSIG key')
        uuid = resp.get('uuid', '')
        log.info('Created TSIG key uuid=%s', uuid)
        return uuid

    def _ensure_forward_zone(self, cfg: DhcpInterfaceConfig, key_uuid: str) -> str:
        """Find or create the forward DNS zone. Returns UUID."""
        if self.dry_run:
            log.info('[DRY RUN] Would ensure forward zone: %s server=%s',
                     cfg.ddns_forward_zone, cfg.ddns_domainprimary)
            return 'dry-run-fwd-zone-uuid'

        existing = self.api.search_forward_zones()
        for row in existing:
            if row.get('name') == cfg.ddns_forward_zone:
                log.info('Forward zone %r already exists (uuid=%s)',
                         cfg.ddns_forward_zone, row['uuid'])
                return row['uuid']

        zone_data = {
            'name': cfg.ddns_forward_zone,
            'server': cfg.ddns_domainprimary,
            'port': '53',
            'tsig_key': key_uuid,
        }

        log.info('Creating forward zone: %s server=%s',
                 cfg.ddns_forward_zone, cfg.ddns_domainprimary)
        resp = self.api.add_forward_zone(zone_data)
        self._check_response(resp, 'add forward zone')
        uuid = resp.get('uuid', '')
        log.info('Created forward zone uuid=%s', uuid)
        return uuid

    def _ensure_reverse_zone(self, cfg: DhcpInterfaceConfig, key_uuid: str,
                             reverse_zone: str) -> str:
        """Find or create the reverse DNS zone. Returns UUID."""
        if not reverse_zone:
            # Derive from subnet: 10.0.10.0/24 -> 10.0.10.in-addr.arpa
            net = ipaddress.IPv4Network(cfg.subnet, strict=False)
            prefix_len = net.prefixlen
            octets = str(net.network_address).split('.')
            if prefix_len >= 24:
                reverse_zone = f'{octets[2]}.{octets[1]}.{octets[0]}.in-addr.arpa'
            elif prefix_len >= 16:
                reverse_zone = f'{octets[1]}.{octets[0]}.in-addr.arpa'
            else:
                reverse_zone = f'{octets[0]}.in-addr.arpa'

        if self.dry_run:
            log.info('[DRY RUN] Would ensure reverse zone: %s server=%s',
                     reverse_zone, cfg.ddns_domainprimary)
            return 'dry-run-rev-zone-uuid'

        existing = self.api.search_reverse_zones()
        for row in existing:
            if row.get('name') == reverse_zone:
                log.info('Reverse zone %r already exists (uuid=%s)',
                         reverse_zone, row['uuid'])
                return row['uuid']

        zone_data = {
            'name': reverse_zone,
            'server': cfg.ddns_domainprimary,
            'port': '53',
            'tsig_key': key_uuid,
        }

        log.info('Creating reverse zone: %s server=%s',
                 reverse_zone, cfg.ddns_domainprimary)
        resp = self.api.add_reverse_zone(zone_data)
        self._check_response(resp, 'add reverse zone')
        uuid = resp.get('uuid', '')
        log.info('Created reverse zone uuid=%s', uuid)
        return uuid

    def _create_subnet(self, cfg: DhcpInterfaceConfig) -> str:
        """Create the Kea subnet. Returns UUID."""
        pool = f'{cfg.range_from} - {cfg.range_to}' if cfg.range_from and cfg.range_to else ''

        if not self.dry_run:
            # Check for existing subnet with same CIDR
            existing = self.api.search_subnets()
            for row in existing:
                if row.get('subnet') == cfg.subnet:
                    log.warning('Subnet %s already exists (uuid=%s) — skipping creation',
                                cfg.subnet, row['uuid'])
                    return row['uuid']

        subnet_data = {
            'subnet': cfg.subnet,
            'pools': pool,
            'option_data_autocollect': '0' if cfg.gateway else '1',
            'option_data': {},
        }

        # Option data
        if cfg.gateway:
            subnet_data['option_data']['routers'] = cfg.gateway
        if cfg.dns_servers:
            subnet_data['option_data']['domain_name_servers'] = ','.join(cfg.dns_servers)
        if cfg.domain:
            subnet_data['option_data']['domain_name'] = cfg.domain
        if cfg.domain_search:
            # ISC uses space/semicolon separated, Kea uses comma separated
            search_list = cfg.domain_search.replace(';', ',').replace(' ', ',')
            # Clean up multiple commas
            while ',,' in search_list:
                search_list = search_list.replace(',,', ',')
            search_list = search_list.strip(',')
            subnet_data['option_data']['domain_search'] = search_list
        if cfg.ntp_servers:
            subnet_data['option_data']['ntp_servers'] = ','.join(cfg.ntp_servers)

        if self.dry_run:
            log.info('[DRY RUN] Would create subnet: %s', cfg.subnet)
            log.info('[DRY RUN]   Pool: %s', pool)
            log.info('[DRY RUN]   Options: %s', subnet_data.get('option_data', {}))
            return 'dry-run-subnet-uuid'

        log.info('Creating subnet: %s (pool: %s)', cfg.subnet, pool)
        resp = self.api.add_subnet(subnet_data)
        self._check_response(resp, 'add subnet')
        uuid = resp.get('uuid', '')
        log.info('Created subnet uuid=%s', uuid)
        return uuid

    def _create_subnet_ddns(self, cfg: DhcpInterfaceConfig, subnet_uuid: str,
                            fwd_zone_uuid: str):
        """Create subnet DDNS assignment linking subnet to forward zone."""
        qualifying_suffix = f'{cfg.ddns_domainname}.' if cfg.ddns_domainname else ''

        if self.dry_run:
            log.info('[DRY RUN] Would create subnet DDNS assignment: subnet=%s zone=%s suffix=%s',
                     cfg.subnet, cfg.ddns_forward_zone, qualifying_suffix)
            return

        assignment_data = {
            'subnet': subnet_uuid,
            'forward_zone': fwd_zone_uuid,
            'qualifying_suffix': qualifying_suffix,
            'send_updates': '1',
        }

        log.info('Creating subnet DDNS assignment: subnet=%s zone=%s suffix=%s',
                 cfg.subnet, cfg.ddns_forward_zone, qualifying_suffix)
        resp = self.api.add_subnet_ddns(assignment_data)
        self._check_response(resp, 'add subnet DDNS assignment')
        log.info('Created subnet DDNS assignment uuid=%s', resp.get('uuid', ''))

    def _create_reservations(self, cfg: DhcpInterfaceConfig, subnet_uuid: str):
        """Create static reservations for the subnet."""
        if not cfg.static_mappings:
            log.info('No static mappings to migrate')
            return

        # Get existing reservations to avoid duplicates
        existing_macs = set()
        if not self.dry_run:
            existing = self.api.search_reservations()
            for row in existing:
                if row.get('subnet') == subnet_uuid:
                    existing_macs.add(row.get('hw_address', '').lower())

        created = 0
        skipped = 0
        for sm in cfg.static_mappings:
            # Normalize MAC to colon-separated lowercase
            mac = sm.mac.lower().replace('-', ':')

            if mac in existing_macs:
                log.info('Reservation for %s already exists — skipping', mac)
                skipped += 1
                continue

            res_data = {
                'subnet': subnet_uuid,
                'hw_address': mac,
            }
            if sm.ipaddr:
                res_data['ip_address'] = sm.ipaddr
            if sm.hostname:
                res_data['hostname'] = sm.hostname
            if sm.description:
                res_data['description'] = sm.description

            if self.dry_run:
                log.info('[DRY RUN] Would create reservation: mac=%s ip=%s host=%s',
                         mac, sm.ipaddr, sm.hostname)
                created += 1
                continue

            log.info('Creating reservation: mac=%s ip=%s host=%s', mac, sm.ipaddr, sm.hostname)
            resp = self.api.add_reservation(res_data)
            validations = resp.get('validations', {})
            if validations:
                log.warning('Reservation failed for mac=%s ip=%s: %s', mac, sm.ipaddr, validations)
                skipped += 1
                continue
            created += 1

        log.info('Reservations: %d created, %d skipped (duplicates/errors)', created, skipped)

    @staticmethod
    def _check_response(resp: dict, action: str):
        """Check API response for errors."""
        result = resp.get('result', '')
        if result == 'saved':
            return
        # Some endpoints return validation errors
        validations = resp.get('validations', {})
        if validations:
            log.error('Validation errors for %s:', action)
            for fld, msg in validations.items():
                log.error('  %s: %s', fld, msg)
            raise SystemExit(f'API validation failed for {action}')
        # If no 'result' field but has 'uuid', it's OK (some endpoints)
        if resp.get('uuid'):
            return
        # Reconfigure returns status
        if resp.get('status', '').lower() == 'ok':
            return
        log.warning('Unexpected API response for %s: %s', action, resp)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Migrate ISC DHCP interface config to Kea DHCP via OPNsense API')
    parser.add_argument('interface', help='Interface name in config.xml (e.g. opt1, opt13, lan)')
    parser.add_argument('--host', default='casa.bgwlan.nl', help='Firewall hostname')
    parser.add_argument('--api-key', default='', help='OPNsense API key')
    parser.add_argument('--api-secret', default='', help='OPNsense API secret')
    parser.add_argument('--config-file', help='Local config.xml file (skip SSH)')
    parser.add_argument('--ssh-user', default='brendan', help='SSH user (default: brendan)')
    parser.add_argument('--dry-run', action='store_true', help='Show what would be done')
    parser.add_argument('--no-reconfigure', action='store_true',
                        help='Skip Kea service reconfigure')
    parser.add_argument('--forward-zone', help='Override forward DNS zone')
    parser.add_argument('--reverse-zone', default='', help='Override reverse DNS zone')
    parser.add_argument('-v', '--verbose', action='store_true', help='Verbose logging')
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format='%(levelname)s: %(message)s',
    )

    if not args.dry_run and (not args.api_key or not args.api_secret):
        parser.error('--api-key and --api-secret are required (unless --dry-run)')

    # Read and parse config
    root = ConfigReader.read(args.host, args.ssh_user, args.config_file)
    cfg = IscDhcpParser.parse(root, args.interface, args.forward_zone)

    if not cfg.enabled:
        log.warning('DHCP is not enabled for interface %s in ISC config', args.interface)

    # API client and migrator
    api = KeaApiClient(args.host, args.api_key, args.api_secret)
    migrator = KeaMigrator(api, dry_run=args.dry_run)
    migrator.migrate(cfg, reverse_zone=args.reverse_zone, no_reconfigure=args.no_reconfigure)


if __name__ == '__main__':
    main()
