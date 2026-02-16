========
Kea DDNS
========

.. warning::

   **USE AT YOUR OWN RISK.** This plugin patches core OPNsense Kea files and
   interacts directly with the ``kea-dhcp-ddns`` daemon. Applying this plugin
   modifies files that may be overwritten by OPNsense firmware updates. See
   :ref:`kea-ddns-patch-rollback` for instructions on how to manually reverse
   the core patch if needed.

.. contents:: Index
    :local:
    :depth: 2

The Kea DDNS plugin adds Dynamic DNS (DDNS) support for the Kea DHCP server in
OPNsense. It manages the ``kea-dhcp-ddns`` daemon and injects per-subnet DDNS
parameters into both ``kea-dhcp4.conf`` and ``kea-dhcp6.conf`` using the
OPNsense ``plugins_run()`` hook mechanism.

When enabled, Kea automatically creates forward (A/AAAA) and reverse (PTR) DNS
records as DHCP leases are assigned, and removes them when leases expire.
Updates are sent as RFC 2136 DNS UPDATE requests, optionally authenticated with
TSIG keys (RFC 2845).

:Package: ``os-kea-ddns``
:Navigation: :menuselection:`Services --> Kea Dynamic DNS --> Settings`

**Key features:**

- TSIG key management (HMAC-MD5 through HMAC-SHA512)
- Forward and reverse DNS zone configuration
- Per-subnet DDNS policy for both DHCPv4 and DHCPv6
- Automatic overlay injection into ``kea-dhcp4.conf`` and ``kea-dhcp6.conf``
- DHCID conflict resolution modes (RFC 4703)
- Log file viewer for ``kea-dhcp-ddns``


Prerequisites
-------------

Before configuring this plugin, ensure:

- **OPNsense 26.1** (tested on 26.1.2). The plugin includes per-release core
  patches. The package auto-detects the running OPNsense series and applies the
  correct patch.
- **Kea DHCP** is installed and enabled (DHCPv4 and/or DHCPv6) with at least
  one subnet configured.
- A **DNS server** (e.g. BIND, PowerDNS, Knot) that accepts RFC 2136 dynamic
  updates for your forward and reverse zones.
- A **TSIG key** shared between the DNS server and OPNsense. Generate one
  with::

    tsig-keygen -a hmac-sha256 ddns-key.example.com

- For IPv4 reverse DNS: an ``in-addr.arpa`` zone on the DNS server
  (e.g. ``168.192.in-addr.arpa``).
- For IPv6 reverse DNS: an ``ip6.arpa`` zone on the DNS server
  (e.g. ``6.5.4.3.2.1.d.f.ip6.arpa`` for ``fd12:3456::/32``).


Settings
--------

Navigate to :menuselection:`Services --> Kea Dynamic DNS --> Settings`.

The interface has six tabs: Settings, TSIG Keys, Forward Zones, Reverse Zones,
Subnet DDNS, and Subnet6 DDNS.

.. tabs::

    .. tab:: Settings

        ========================================= ====================================================================================
        **Option**                                **Description**
        ========================================= ====================================================================================
        **Enabled**                               Enable the ``kea-dhcp-ddns`` daemon and activate DDNS overlays for
                                                  Kea DHCPv4 and DHCPv6.
        **Manual config**                         Disable automatic generation of ``kea-dhcp-ddns.conf`` and manage the file
                                                  manually at ``/usr/local/etc/kea/kea-dhcp-ddns.conf``.
        ========================================= ====================================================================================

    .. tab:: TSIG Keys

        TSIG keys provide authentication for DNS UPDATE requests (RFC 2845). The key name, algorithm, and
        secret must match the configuration on your DNS server.

        ========================================= ====================================================================================
        **Option**                                **Description**
        ========================================= ====================================================================================
        **Name**                                  TSIG key name. Must match the key name on the DNS server exactly
                                                  (e.g. ``ddns-key.dyn.example.com``). May include dots and an optional
                                                  trailing dot.
        **Algorithm**                             HMAC algorithm. Options: ``HMAC-MD5``, ``HMAC-SHA1``, ``HMAC-SHA224``,
                                                  ``HMAC-SHA256`` (default), ``HMAC-SHA384``, ``HMAC-SHA512``.
        **Secret**                                Base64-encoded shared secret. Generate with
                                                  ``tsig-keygen -a hmac-sha256 keyname`` on your DNS server.
        ========================================= ====================================================================================

    .. tab:: Forward Zones

        Forward zones define where to send DNS UPDATE requests for forward (A/AAAA) records.
        Each zone maps a DNS domain to a server and optional TSIG key.

        ========================================= ====================================================================================
        **Option**                                **Description**
        ========================================= ====================================================================================
        **Zone name**                             The DNS zone for forward records (e.g. ``dyn.example.com``). The ``kea-dhcp-ddns`` daemon
                                                  matches client FQDNs to zones by longest suffix match.
        **DNS server**                            IP address of the authoritative DNS server for this zone.
        **Port**                                  DNS server port (default: ``53``).
        **TSIG key**                              TSIG key for authenticating updates. Select ``None (unsecured)`` to send
                                                  unauthenticated updates.
        ========================================= ====================================================================================

        .. note::

            The ``kea-dhcp-ddns`` daemon matches each client's FQDN to the configured forward zone by suffix.
            For example, ``laptop.lan.dyn.example.com`` matches zone ``dyn.example.com``. If no zone
            matches, the update is silently dropped with a ``DHCP_DDNS_NO_MATCH`` warning in the logs.
            Ensure your qualifying suffixes and client FQDNs match a configured forward zone.

    .. tab:: Reverse Zones

        Reverse zones define where to send DNS UPDATE requests for reverse (PTR) records.

        ========================================= ====================================================================================
        **Option**                                **Description**
        ========================================= ====================================================================================
        **Zone name**                             The reverse DNS zone name. For IPv4, use ``in-addr.arpa`` format
                                                  (e.g. ``168.192.in-addr.arpa``). For IPv6, use ``ip6.arpa`` nibble format
                                                  (e.g. ``6.5.4.3.2.1.d.f.ip6.arpa`` for ``fd12:3456::/32``).
        **DNS server**                            IP address of the authoritative DNS server for this zone.
        **Port**                                  DNS server port (default: ``53``).
        **TSIG key**                              TSIG key for authenticating updates.
        ========================================= ====================================================================================

        .. tip::

            IPv6 reverse zone names use nibble format with the hex digits of the prefix reversed.
            For a ``/48`` prefix ``fd12:3456:789a::/48``, the zone is ``a.9.8.7.6.5.4.3.2.1.d.f.ip6.arpa``.
            You can compute this with: ``python3 -c "import ipaddress; print(ipaddress.ip_network('fd12:3456:789a::/48').network_address.reverse_pointer)"``
            and trim to the appropriate prefix length.

    .. tab:: Subnet DDNS (DHCPv4)

        Per-subnet DDNS assignments control which DHCPv4 subnets get dynamic DNS updates and how
        hostnames are handled.

        ========================================= ====================================================================================
        **Option**                                **Description**
        ========================================= ====================================================================================
        **Subnet**                                The Kea DHCPv4 subnet to enable DDNS for. Only subnets configured in
                                                  :menuselection:`Services --> KEA DHCP --> KEA DHCPv4 --> Subnets` appear here.
        **Forward zone**                          Optional association with a forward zone (informational).
        **Qualifying suffix**                     FQDN suffix appended to bare hostnames. For example, if a client sends
                                                  hostname ``laptop`` and the suffix is ``lan.dyn.example.com.``, the resulting
                                                  FQDN is ``laptop.lan.dyn.example.com.``. Must end with a dot.
        **Send updates**                          Enable sending DDNS updates for this subnet. Default: enabled.
        **Update on renew**                       Send DNS updates when leases are renewed, not just on initial assignment.
        **Replace client name**                   Controls whether Kea replaces the client-provided hostname.

                                                  - ``Never`` (default): use the hostname the client sends.
                                                  - ``Always``: replace with a generated name (prefix + IP). Rarely desired.
                                                  - ``When present``: replace only if the client sends a hostname.
                                                  - ``When not present``: generate a name only if the client doesn't send one.
        **Conflict resolution**                   How to handle conflicting DNS records using DHCID (RFC 4703).

                                                  - ``Check with DHCID`` (default): strict RFC 4703 — only update if DHCID matches.
                                                  - ``No check, store DHCID``: update regardless, but still store DHCID.
                                                    Use this when hosts have pre-existing static DNS records without DHCID.
                                                  - ``Check exists with DHCID``: update only if any DHCID record exists.
                                                  - ``No check, no DHCID``: update without any DHCID handling.
        ========================================= ====================================================================================

    .. tab:: Subnet6 DDNS (DHCPv6)

        Per-subnet DDNS assignments for DHCPv6 subnets. The fields are identical to the DHCPv4 tab
        but reference Kea DHCPv6 subnets.

        ========================================= ====================================================================================
        **Option**                                **Description**
        ========================================= ====================================================================================
        **Subnet**                                The Kea DHCPv6 subnet to enable DDNS for.
        **Forward zone**                          Optional association with a forward zone.
        **Qualifying suffix**                     FQDN suffix appended to bare hostnames. Must end with a dot.
        **Send updates**                          Enable sending DDNS updates for this subnet.
        **Update on renew**                       Send DNS updates on lease renewals.
        **Replace client name**                   Controls hostname replacement (see DHCPv4 tab for details).
        **Conflict resolution**                   DHCID conflict handling mode (see DHCPv4 tab for details).
        ========================================= ====================================================================================

        .. note::

            DHCPv6 clients typically send their full FQDN (e.g. ``laptop.example.com.``) via DHCPv6
            Option 39 (Client FQDN), unlike DHCPv4 clients which send bare hostnames. This means the
            qualifying suffix is often not appended for v6 clients. Ensure the FQDN the client sends
            matches a configured forward zone.

        .. attention::

            If hosts have pre-existing static A records without DHCID records (common in dual-stack
            environments), the default ``Check with DHCID`` conflict resolution will cause forward DDNS
            updates to fail with RCODE 8 (NXRRSET). When the forward update fails, the reverse (PTR)
            update is also aborted. Set conflict resolution to ``No check, store DHCID`` to resolve this.


Log File
--------

The ``kea-dhcp-ddns`` daemon logs are available at
:menuselection:`Services --> Kea Dynamic DNS --> Log File`.

Common log messages:

- ``DHCP_DDNS_NO_MATCH``: A client's FQDN did not match any configured forward
  zone. Check your forward zone configuration and qualifying suffixes.
- ``DHCP_DDNS_FORWARD_ADD_OK``: Forward DNS record successfully added.
- ``DHCP_DDNS_REVERSE_ADD_OK``: Reverse DNS record successfully added.
- ``DHCP_DDNS_FORWARD_REPLACE_REJECTED``: DNS server rejected the update
  (check TSIG key, zone permissions, or DHCID conflicts).


Configuration examples
----------------------


DHCPv4 DDNS with BIND
~~~~~~~~~~~~~~~~~~~~~

This example configures DDNS for a DHCPv4 subnet ``192.168.1.0/24`` with
updates sent to a BIND DNS server at ``192.168.1.53`` for the forward zone
``dyn.example.com`` and reverse zone ``1.168.192.in-addr.arpa``.

**On the DNS server**, create the TSIG key and configure the zones to allow
dynamic updates::

    # Generate TSIG key
    tsig-keygen -a hmac-sha256 ddns-key.dyn.example.com

    # In named.conf, add the key and allow-update for both zones:
    key "ddns-key.dyn.example.com" {
        algorithm hmac-sha256;
        secret "<base64-secret>";
    };

    zone "dyn.example.com" {
        type master;
        file "dyn.example.com.zone";
        allow-update { key ddns-key.dyn.example.com; };
    };

    zone "1.168.192.in-addr.arpa" {
        type master;
        file "1.168.192.in-addr.arpa.zone";
        allow-update { key ddns-key.dyn.example.com; };
    };

**On OPNsense**, go to :menuselection:`Services --> Kea Dynamic DNS --> Settings`
and configure:

.. tabs::

    .. tab:: Settings

        ==================================  =======================================================================================================
        Option                              Value
        ==================================  =======================================================================================================
        **Enabled**                         ``X``
        ==================================  =======================================================================================================

    .. tab:: TSIG Keys

        ==================================  =======================================================================================================
        Option                              Value
        ==================================  =======================================================================================================
        **Name**                            ``ddns-key.dyn.example.com``
        **Algorithm**                       ``HMAC-SHA256``
        **Secret**                          (paste the base64 secret from ``tsig-keygen`` output)
        ==================================  =======================================================================================================

        Press **Save**.

    .. tab:: Forward Zones

        ==================================  =======================================================================================================
        Option                              Value
        ==================================  =======================================================================================================
        **Zone name**                       ``dyn.example.com``
        **DNS server**                      ``192.168.1.53``
        **Port**                            ``53``
        **TSIG key**                        ``ddns-key.dyn.example.com``
        ==================================  =======================================================================================================

        Press **Save**.

    .. tab:: Reverse Zones

        ==================================  =======================================================================================================
        Option                              Value
        ==================================  =======================================================================================================
        **Zone name**                       ``1.168.192.in-addr.arpa``
        **DNS server**                      ``192.168.1.53``
        **Port**                            ``53``
        **TSIG key**                        ``ddns-key.dyn.example.com``
        ==================================  =======================================================================================================

        Press **Save**.

    .. tab:: Subnet DDNS

        ==================================  =======================================================================================================
        Option                              Value
        ==================================  =======================================================================================================
        **Subnet**                          ``192.168.1.0/24``
        **Qualifying suffix**                ``lan.dyn.example.com.``
        **Send updates**                    ``X``
        **Conflict resolution**             ``Check with DHCID (RFC 4703)``
        ==================================  =======================================================================================================

        Press **Save**.

Press **Apply** to activate. The ``kea-dhcp-ddns`` daemon starts and Kea DHCPv4
begins sending DDNS updates.

A client named ``laptop`` obtaining a lease at ``192.168.1.100`` will get:

- Forward: ``laptop.lan.dyn.example.com`` → ``192.168.1.100`` (A record)
- Reverse: ``100.1.168.192.in-addr.arpa`` → ``laptop.lan.dyn.example.com`` (PTR record)


DHCPv6 DDNS
~~~~~~~~~~~~

This example adds DHCPv6 DDNS for a ``fd12:3456:789a:feed::/64`` subnet,
reusing the same DNS server, TSIG key, and forward zone from the DHCPv4 example
above.

**On the DNS server**, add the IPv6 reverse zone::

    zone "a.9.8.7.6.5.4.3.2.1.d.f.ip6.arpa" {
        type master;
        file "fd12-3456-789a.ip6.arpa.zone";
        allow-update { key ddns-key.dyn.example.com; };
    };

**On OPNsense**, add a reverse zone and subnet6 DDNS assignment:

.. tabs::

    .. tab:: Reverse Zones

        Add a new reverse zone:

        ==================================  =======================================================================================================
        Option                              Value
        ==================================  =======================================================================================================
        **Zone name**                       ``a.9.8.7.6.5.4.3.2.1.d.f.ip6.arpa``
        **DNS server**                      ``192.168.1.53``
        **Port**                            ``53``
        **TSIG key**                        ``ddns-key.dyn.example.com``
        ==================================  =======================================================================================================

        Press **Save**.

    .. tab:: Subnet6 DDNS

        ==================================  =======================================================================================================
        Option                              Value
        ==================================  =======================================================================================================
        **Subnet**                          ``fd12:3456:789a:feed::/64``
        **Qualifying suffix**                ``lan.dyn.example.com.``
        **Send updates**                    ``X``
        **Conflict resolution**             ``No check, store DHCID``
        ==================================  =======================================================================================================

        Press **Save**.

Press **Apply**. DHCPv6 clients on this subnet will now get AAAA and ip6.arpa
PTR records.

.. tip::

    For dual-stack environments where hosts have both DHCPv4 and DHCPv6 leases,
    use ``No check, store DHCID`` for the DHCPv6 conflict resolution. DHCPv4 and
    DHCPv6 generate different DHCID records for the same hostname, so the strict
    ``Check with DHCID`` mode will cause v6 updates to fail if v4 already
    created a DHCID for that name.


Multiple forward zones
~~~~~~~~~~~~~~~~~~~~~~

If clients on different subnets use different DNS zones, create multiple forward
zones and set the appropriate qualifying suffix on each subnet DDNS assignment.

For example, with subnets for LAN (``lan.dyn.example.com``) and corporate
(``corp.dyn.example.com``), both under the parent zone ``dyn.example.com``:

- Create one forward zone: ``dyn.example.com`` (the parent zone handles both
  subdomains).
- On the LAN subnet, set qualifying suffix to ``lan.dyn.example.com.``
- On the corporate subnet, set qualifying suffix to ``corp.dyn.example.com.``

Both ``laptop.lan.dyn.example.com`` and ``printer.corp.dyn.example.com`` will
match the ``dyn.example.com`` forward zone.


Troubleshooting
---------------


DDNS updates not appearing
~~~~~~~~~~~~~~~~~~~~~~~~~~

1. Check the ``kea-dhcp-ddns`` daemon log at
   :menuselection:`Services --> Kea Dynamic DNS --> Log File`.

2. Look for ``DHCP_DDNS_NO_MATCH`` — this means the client's FQDN doesn't
   match any forward zone. Ensure the qualifying suffix produces an FQDN that is
   a subdomain of a configured forward zone.

3. Verify the ``kea-dhcp-ddns`` daemon is running::

    keactrl status

4. Check that ``dhcp_ddns=yes`` in ``/usr/local/etc/kea/keactrl.conf``.


Forward updates fail, reverse never attempted
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

When a forward DNS update fails, Kea aborts the entire transaction including the
reverse update. Check the ``kea-dhcp-ddns`` log for the RCODE:

- **RCODE 8 (NXRRSET)**: The DNS name already exists with a different DHCID or
  no DHCID at all. This happens when static DNS records exist without DHCID
  records. Change the conflict resolution to ``No check, store DHCID``.

- **RCODE 9 (NOTAUTH)**: The DNS server is not authoritative for the zone, or
  TSIG authentication failed. Verify the zone name, TSIG key name, algorithm,
  and secret match exactly.

- **RCODE 5 (REFUSED)**: The DNS server refused the update. Check that
  ``allow-update`` is configured for the zone on the DNS server.


DHCPv6 clients send full FQDNs
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Unlike DHCPv4 clients which typically send a bare hostname (e.g. ``laptop``),
DHCPv6 clients send their full FQDN via Option 39 (e.g.
``laptop.example.com.``). This means:

- The qualifying suffix is **not** appended when the client already sends a
  complete FQDN.
- The FQDN the client sends must match a configured forward zone.
- If clients send FQDNs in a different domain than your DDNS forward zone, you
  may need to add that domain as an additional forward zone.


Stale DNS records after hostname changes
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

When a DHCP reservation hostname is changed, existing leases retain the old
hostname until the client renews. To force an immediate update:

1. Delete the lease via the Kea control socket or the Leases page.
2. Re-add the lease with the new hostname (or wait for the client to renew).
3. Trigger a DDNS resend.

The old DNS records (A/AAAA, PTR, DHCID) are not automatically cleaned up.
Remove them manually using ``nsupdate`` or your DNS server's management
interface.


How it works
------------

The plugin integrates with the core Kea DHCP plugin through three
``plugins_run()`` hooks:

``kea_ddns_generate``
    Called during ``kea_configure_do()``. Generates
    ``/usr/local/etc/kea/kea-dhcp-ddns.conf`` with the ``kea-dhcp-ddns`` daemon
    configuration (TSIG keys, forward/reverse zones, control socket). Also
    enables ``dhcp_ddns=yes`` in ``keactrl.conf``.

``kea_dhcpv4_config``
    Called during ``KeaDhcpv4::generateConfig()``. Returns an overlay array that
    is merged into ``kea-dhcp4.conf``. The overlay adds global DDNS settings
    (``dhcp-ddns`` block, hostname character set) and per-subnet parameters
    (``ddns-send-updates``, ``ddns-qualifying-suffix``,
    ``ddns-conflict-resolution-mode``, etc.).

``kea_dhcpv6_config``
    Same as above, but for ``KeaDhcpv6::generateConfig()`` and
    ``kea-dhcp6.conf``.

The ``kea-dhcp-ddns`` daemon listens on ``127.0.0.1:53001`` and receives Name
Change Requests (NCRs) from the DHCPv4 and DHCPv6 daemons over a local
connection. It then translates these into RFC 2136 DNS UPDATE requests sent to
the configured DNS servers.


.. _kea-ddns-patch-rollback:

Patch rollback
--------------

This plugin patches three core OPNsense Kea files to add ``plugins_run()``
hooks. If you need to remove the plugin and restore the original files,
uninstall the package or follow the manual steps below.

Uninstall
~~~~~~~~~

Remove the package using ``pkg``::

    pkg remove os-kea-ddns

This removes all plugin files and reverses the core patch.

Manual rollback
~~~~~~~~~~~~~~~

If ``pkg remove`` does not cleanly reverse the patch, manually remove the
patched hooks from these three files:

1. ``/usr/local/etc/inc/plugins.inc.d/kea.inc`` — remove the
   ``plugins_run('kea_ddns_generate')`` call and the ``keactrl.conf`` DDNS lines
   added by the patch.

2. ``/usr/local/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv4.php`` — remove
   the ``plugins_run('kea_dhcpv4_config')`` overlay block before
   ``File::file_put_contents()``.

3. ``/usr/local/opnsense/mvc/app/models/OPNsense/Kea/KeaDhcpv6.php`` — remove
   the ``plugins_run('kea_dhcpv6_config')`` overlay block before
   ``File::file_put_contents()``.

Then remove the plugin files::

    rm -f /usr/local/etc/inc/plugins.inc.d/kea_ddns.inc
    rm -rf /usr/local/opnsense/mvc/app/controllers/OPNsense/KeaDdns
    rm -rf /usr/local/opnsense/mvc/app/models/OPNsense/KeaDdns
    rm -rf /usr/local/opnsense/mvc/app/views/OPNsense/KeaDdns
    rm -rf /usr/local/opnsense/data/kea-ddns

Finally, restart Kea::

    configctl kea restart

.. note::

    OPNsense firmware updates may overwrite the patched core files, effectively
    reverting the patch. After a firmware update, reinstall the package to
    reapply the hooks.


API
---

All configuration is available via the REST API under
``/api/keaddns/general/``.

.. tabs::

    .. tab:: General

        ==================================================  ==========  ==================================================
        **Endpoint**                                        **Method**  **Description**
        ==================================================  ==========  ==================================================
        ``/api/keaddns/general/get``                        GET         Get general settings (enabled, manual_config)
        ``/api/keaddns/general/set``                        POST        Save general settings
        ==================================================  ==========  ==================================================

    .. tab:: TSIG Keys

        ==================================================  ==========  ==================================================
        **Endpoint**                                        **Method**  **Description**
        ==================================================  ==========  ==================================================
        ``/api/keaddns/general/searchTsigKey``              GET         List all TSIG keys
        ``/api/keaddns/general/getTsigKey/{uuid}``          GET         Get a single TSIG key
        ``/api/keaddns/general/addTsigKey``                 POST        Create a TSIG key
        ``/api/keaddns/general/setTsigKey/{uuid}``          POST        Update a TSIG key
        ``/api/keaddns/general/delTsigKey/{uuid}``          POST        Delete a TSIG key
        ==================================================  ==========  ==================================================

    .. tab:: Zones

        ==================================================  ==========  ==================================================
        **Endpoint**                                        **Method**  **Description**
        ==================================================  ==========  ==================================================
        ``/api/keaddns/general/searchForwardZone``          GET         List forward zones
        ``/api/keaddns/general/getForwardZone/{uuid}``      GET         Get a forward zone
        ``/api/keaddns/general/addForwardZone``             POST        Create a forward zone
        ``/api/keaddns/general/setForwardZone/{uuid}``      POST        Update a forward zone
        ``/api/keaddns/general/delForwardZone/{uuid}``      POST        Delete a forward zone
        ``/api/keaddns/general/searchReverseZone``          GET         List reverse zones
        ``/api/keaddns/general/getReverseZone/{uuid}``      GET         Get a reverse zone
        ``/api/keaddns/general/addReverseZone``             POST        Create a reverse zone
        ``/api/keaddns/general/setReverseZone/{uuid}``      POST        Update a reverse zone
        ``/api/keaddns/general/delReverseZone/{uuid}``      POST        Delete a reverse zone
        ==================================================  ==========  ==================================================

    .. tab:: Subnet DDNS

        ==================================================  ==========  ==================================================
        **Endpoint**                                        **Method**  **Description**
        ==================================================  ==========  ==================================================
        ``/api/keaddns/general/searchSubnetDdns``           GET         List DHCPv4 subnet DDNS assignments
        ``/api/keaddns/general/getSubnetDdns/{uuid}``       GET         Get a DHCPv4 DDNS assignment
        ``/api/keaddns/general/addSubnetDdns``              POST        Create a DHCPv4 DDNS assignment
        ``/api/keaddns/general/setSubnetDdns/{uuid}``       POST        Update a DHCPv4 DDNS assignment
        ``/api/keaddns/general/delSubnetDdns/{uuid}``       POST        Delete a DHCPv4 DDNS assignment
        ``/api/keaddns/general/searchSubnet6Ddns``          GET         List DHCPv6 subnet DDNS assignments
        ``/api/keaddns/general/getSubnet6Ddns/{uuid}``      GET         Get a DHCPv6 DDNS assignment
        ``/api/keaddns/general/addSubnet6Ddns``             POST        Create a DHCPv6 DDNS assignment
        ``/api/keaddns/general/setSubnet6Ddns/{uuid}``      POST        Update a DHCPv6 DDNS assignment
        ``/api/keaddns/general/delSubnet6Ddns/{uuid}``      POST        Delete a DHCPv6 DDNS assignment
        ==================================================  ==========  ==================================================
