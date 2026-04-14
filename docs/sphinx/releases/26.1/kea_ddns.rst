========
Kea DDNS
========

.. warning::

   **USE AT YOUR OWN RISK.** This plugin interacts directly with the
   ``kea-dhcp-ddns`` daemon and modifies Kea configuration files. No OPNsense
   core files are modified — the plugin uses the standard ``plugins_configure()``
   hook mechanism and survives OPNsense firmware updates without reinstallation.

   Starting with OPNsense 26.1.5, the core includes built-in DDNS support. This
   plugin can be installed alongside core DDNS but only one should be active at
   a time. See `Coexistence with core DDNS`_ for details.

.. contents:: Index
    :local:
    :depth: 3

The Kea DDNS plugin adds Dynamic DNS (DDNS) support for the Kea DHCP server in
OPNsense. It manages the ``kea-dhcp-ddns`` daemon and injects per-subnet DDNS
parameters into both ``kea-dhcp4.conf`` and ``kea-dhcp6.conf`` using the
OPNsense ``plugins_configure()`` hook mechanism. Since OPNsense 26.1.5, the
core also includes DDNS support — the plugin can run side by side with it and
offers additional features such as global DDNS defaults, shared TSIG keys, a
status dashboard, and DHCPv6 Rapid Commit (see
`Coexistence with core DDNS`_).

When enabled, Kea automatically creates forward (A/AAAA) and reverse (PTR) DNS
records as DHCP leases are assigned, and removes them when leases expire.
Updates are sent as RFC 2136 DNS UPDATE requests, optionally authenticated with
TSIG keys (RFC 2845).

:Package: ``os-kea-ddns``
:Navigation: :menuselection:`Services --> Kea Dynamic DNS --> Settings`

**Key features:**

- TSIG key management with auto-generation (HMAC-MD5 through HMAC-SHA512)
- Forward and reverse DNS zone configuration with reverse zone auto-derive
- Per-subnet DDNS policy for both DHCPv4 and DHCPv6
- Automatic overlay injection into ``kea-dhcp4.conf`` and ``kea-dhcp6.conf``
- DHCID conflict resolution modes (RFC 4703)
- DDNS status dashboard with daemon statistics and per-lease DDNS info
- Log file viewer for ``kea-dhcp-ddns``


Prerequisites
-------------

Before configuring this plugin, ensure:

- **OPNsense 26.1** or later. No core patches required — the plugin uses the
  standard ``kea_sync`` configure hook.
- **Kea DHCP** is installed and enabled (DHCPv4 and/or DHCPv6) with at least
  one subnet configured.
- A **DNS server** (e.g. BIND, PowerDNS, Knot) that accepts RFC 2136 dynamic
  updates for your forward and reverse zones.
- A **TSIG key** shared between the DNS server and OPNsense. You can generate
  one using the built-in **Generate** button in the TSIG Keys tab, or on the
  DNS server with::

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

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - **Option**
              - **Description**
            * - **Enabled**
              - Enable the ``kea-dhcp-ddns`` daemon and activate DDNS overlays for
                Kea DHCPv4 and DHCPv6.
            * - **Manual config**
              - Disable automatic generation of ``kea-dhcp-ddns.conf`` and manage the file
                manually at ``/usr/local/etc/kea/kea-dhcp-ddns.conf``.

        **DDNS Defaults**

        These global defaults are emitted as Kea root-level parameters and inherited by all subnets.
        Per-subnet DDNS assignments default to "Use global default" — only explicitly set values
        override these globals.

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - **Option**
              - **Description**
            * - **Qualifying suffix**
              - Default FQDN suffix appended to bare hostnames (e.g. ``dyn.example.com.``).
                Must end with a dot. Can be overridden per subnet.
            * - **Send updates**
              - Default for sending DDNS updates. Default: enabled. Can be overridden per subnet.
            * - **Update on renew**
              - Default for sending DNS updates on lease renewals. Default: enabled.
                Can be overridden per subnet.
            * - **Replace client name**
              - Default for replacing client-sent hostnames. Options: ``Never`` (default),
                ``Always``, ``When present``, ``When not present``.
                Can be overridden per subnet.
            * - **Conflict resolution**
              - Default DHCID conflict resolution mode. Options: ``Check with DHCID`` (default),
                ``No check, store DHCID``, ``Check exists with DHCID``, ``No check, no DHCID``.
                Can be overridden per subnet.
            * - **Generated prefix**
              - Default prefix for auto-generated hostnames when replacing client name
                (Kea default: ``myhost``). Can be overridden per subnet.

    .. tab:: TSIG Keys

        TSIG keys provide authentication for DNS UPDATE requests (RFC 2845). The key name, algorithm, and
        secret must match the configuration on your DNS server.

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - **Option**
              - **Description**
            * - **Name**
              - TSIG key name. Must match the key name on the DNS server exactly
                (e.g. ``ddns-key.dyn.example.com``). May include dots and an optional
                trailing dot.
            * - **Algorithm**
              - HMAC algorithm. Options: ``HMAC-MD5``, ``HMAC-SHA1``, ``HMAC-SHA224``,
                ``HMAC-SHA256`` (default), ``HMAC-SHA384``, ``HMAC-SHA512``.
            * - **Secret**
              - Base64-encoded shared secret. Click **Generate** to create a
                cryptographically random secret of the correct length for the
                selected algorithm. Alternatively, generate on the DNS server
                with ``tsig-keygen -a hmac-sha256 keyname``.

        .. tip::

            The **Generate** button creates a random secret using the correct key length for the
            selected algorithm (e.g. 32 bytes for HMAC-SHA256, 64 bytes for HMAC-SHA512). Copy
            the generated Base64 value to your DNS server configuration. This eliminates the need
            to run ``tsig-keygen`` or ``dnssec-keygen`` externally.

    .. tab:: Forward Zones

        Forward zones define where to send DNS UPDATE requests for forward (A/AAAA) records.
        Each zone maps a DNS domain to a server and optional TSIG key.

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - **Option**
              - **Description**
            * - **Zone name**
              - The DNS zone for forward records (e.g. ``dyn.example.com``). The ``kea-dhcp-ddns`` daemon
                matches client FQDNs to zones by longest suffix match.
            * - **DNS server**
              - IP address of the authoritative DNS server for this zone.
            * - **Port**
              - DNS server port (default: ``53``).
            * - **TSIG key**
              - TSIG key for authenticating updates. Select ``None (unsecured)`` to send
                unauthenticated updates.

        .. note::

            The ``kea-dhcp-ddns`` daemon matches each client's FQDN to the configured forward zone by suffix.
            For example, ``laptop.lan.dyn.example.com`` matches zone ``dyn.example.com``. If no zone
            matches, the update is silently dropped with a ``DHCP_DDNS_NO_MATCH`` warning in the logs.
            Ensure your qualifying suffixes and client FQDNs match a configured forward zone.

    .. tab:: Reverse Zones

        Reverse zones define where to send DNS UPDATE requests for reverse (PTR) records.

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - **Option**
              - **Description**
            * - **Zone name**
              - The reverse DNS zone name. For IPv4, use ``in-addr.arpa`` format
                (e.g. ``168.192.in-addr.arpa``). For IPv6, use ``ip6.arpa`` nibble format
                (e.g. ``6.5.4.3.2.1.d.f.ip6.arpa`` for ``fd12:3456::/32``).
                Use the **Derive** button below the zone name field to auto-derive
                the zone name from a configured Kea subnet.
            * - **DNS server**
              - IP address of the authoritative DNS server for this zone.
            * - **Port**
              - DNS server port (default: ``53``).
            * - **TSIG key**
              - TSIG key for authenticating updates.

        .. tip::

            The **Derive zone name from subnet** dropdown lists all configured Kea DHCPv4 and
            DHCPv6 subnets with their corresponding reverse zone names. Select a subnet and click
            **Derive** (or double-click the entry) to populate the zone name field automatically.
            This eliminates the error-prone manual construction of ``in-addr.arpa`` and ``ip6.arpa``
            zone names.

        .. tip::

            IPv6 reverse zone names use nibble format with the hex digits of the prefix reversed.
            For a ``/48`` prefix ``fd12:3456:789a::/48``, the zone is ``a.9.8.7.6.5.4.3.2.1.d.f.ip6.arpa``.
            The auto-derive feature handles this conversion automatically.

    .. tab:: Subnet DDNS (DHCPv4)

        Per-subnet DDNS assignments control which DHCPv4 subnets get dynamic DNS updates and how
        hostnames are handled. All fields except Subnet default to "Use global default",
        inheriting the value from the Settings tab. Only explicitly set values are
        emitted in the per-subnet configuration.

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - **Option**
              - **Description**
            * - **Subnet**
              - The Kea DHCPv4 subnet to enable DDNS for. Only subnets configured in
                :menuselection:`Services --> KEA DHCP --> KEA DHCPv4 --> Subnets` appear here.
            * - **Qualifying suffix**
              - FQDN suffix appended to bare hostnames. For example, if a client sends
                hostname ``laptop`` and the suffix is ``lan.dyn.example.com.``, the resulting
                FQDN is ``laptop.lan.dyn.example.com.``. Must end with a dot.
            * - **Send updates**
              - Enable sending DDNS updates for this subnet. Default: enabled.
            * - **Update on renew**
              - Send DNS updates when leases are renewed, not just on initial assignment.
            * - **Replace client name**
              - Controls whether Kea replaces the client-provided hostname.

                - ``Never`` (default): use the hostname the client sends.
                - ``Always``: replace with a generated name (prefix + IP). Rarely desired.
                - ``When present``: replace only if the client sends a hostname.
                - ``When not present``: generate a name only if the client doesn't send one.
            * - **Conflict resolution**
              - How to handle conflicting DNS records using DHCID (RFC 4703).

                - ``Check with DHCID`` (default): strict RFC 4703 — only update if DHCID matches.
                - ``No check, store DHCID``: update regardless, but still store DHCID.
                  Use this when hosts have pre-existing static DNS records without DHCID.
                - ``Check exists with DHCID``: update only if any DHCID record exists.
                - ``No check, no DHCID``: update without any DHCID handling.

    .. tab:: Subnet6 DDNS (DHCPv6)

        Per-subnet DDNS assignments for DHCPv6 subnets. The fields are identical to the DHCPv4 tab
        but reference Kea DHCPv6 subnets, with an additional Rapid Commit option. All fields
        default to "Use global default" unless explicitly overridden.

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - **Option**
              - **Description**
            * - **Subnet**
              - The Kea DHCPv6 subnet to enable DDNS for.
            * - **Qualifying suffix**
              - FQDN suffix appended to bare hostnames. Must end with a dot.
            * - **Send updates**
              - Enable sending DDNS updates for this subnet.
            * - **Update on renew**
              - Send DNS updates on lease renewals.
            * - **Replace client name**
              - Controls hostname replacement (see DHCPv4 tab for details).
            * - **Conflict resolution**
              - DHCID conflict handling mode (see DHCPv4 tab for details).
            * - **Rapid commit**
              - Enable DHCPv6 Rapid Commit (RFC 8415). When enabled, the server
                can complete the DHCPv6 exchange in two messages instead of four.
                Required for macOS clients.

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


Status
------

Navigate to :menuselection:`Services --> Kea Dynamic DNS --> Status`.

The status page provides real-time visibility into the ``kea-dhcp-ddns`` daemon
and DDNS-registered leases. It has three tabs:

.. tabs::

    .. tab:: Daemon Status

        Shows the current state of the ``kea-dhcp-ddns`` daemon, queried via its
        Unix control socket (``/var/run/kea/kea-ddns-ctrl-socket``).

        **Daemon info:**

        - **Version** — Kea DDNS daemon version
        - **PID** — process ID
        - **Uptime** — how long the daemon has been running

        **Update Statistics** — global counters for DDNS operations:

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - **Statistic**
              - **Description**
            * - **NCR received**
              - Name Change Requests received from DHCPv4/v6 daemons
            * - **NCR invalid**
              - Malformed NCRs rejected
            * - **NCR error**
              - NCRs that could not be processed
            * - **Queue full**
              - NCRs dropped because the internal queue was full
            * - **Updates sent**
              - DNS UPDATE requests sent to DNS servers
            * - **Updates successful**
              - DNS updates that completed successfully
            * - **Updates error**
              - DNS updates that failed (check the log for RCODEs)
            * - **Updates timeout**
              - DNS updates that timed out (DNS server did not respond)
            * - **Updates signed**
              - DNS updates authenticated with TSIG
            * - **Updates unsigned**
              - DNS updates sent without TSIG authentication

        **Per-Key Statistics** — if TSIG keys are in use, shows sent/success/error/timeout
        counters broken down by TSIG key name.

        Click **Refresh** to reload the daemon status.

        .. note::

            If the daemon is not running, a warning is displayed. Start it by enabling
            DDNS in the Settings tab and clicking **Apply**.

    .. tab:: DDNS DHCPv4

        Shows active DHCPv4 leases that have DDNS registrations, grouped by
        subnet. A lease appears here if it has a forward DNS update, a reverse
        DNS update, or both.

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - **Column**
              - **Description**
            * - **Hostname**
              - The FQDN registered in DNS for this lease
            * - **Address**
              - The IPv4 address assigned to the client
            * - **MAC**
              - The client's hardware (MAC) address
            * - **Forward**
              - Check mark if a forward (A) DNS record was registered
            * - **Reverse**
              - Check mark if a reverse (PTR) DNS record was registered
            * - **Expires**
              - Lease expiration timestamp

        Select one or more rows and click **Force DDNS Update** to trigger an
        immediate Name Change Request for those leases via the Kea
        ``lease4-resend-ddns`` API. This is useful to re-register a lease
        after a DNS zone change or TSIG key rotation without waiting for the
        lease to renew.

        Click **Refresh** to reload the lease data.

        .. tip::

            Use this tab to verify that DDNS is working correctly for your
            clients. If a client appears with a forward check but no reverse
            check, verify that a matching reverse zone is configured. If a
            client is missing entirely, check the log file for
            ``DHCP_DDNS_NO_MATCH`` messages.

    .. tab:: DDNS DHCPv6

        Shows active DHCPv6 leases that have DDNS registrations, grouped by
        subnet. Identical columns to the DHCPv4 tab, with **Address** showing
        the IPv6 address and **Forward** indicating an AAAA record registration.

        Select one or more rows and click **Force DDNS Update** to trigger an
        immediate Name Change Request via the Kea ``lease6-resend-ddns`` API.

        Click **Refresh** to reload the lease data.

        .. note::

            This tab is only populated when Kea DHCPv6 is enabled and at least
            one DHCPv6 subnet has DDNS updates enabled.


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

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - Option
              - Value
            * - **Enabled**
              - ``X``
            * - **Qualifying suffix**
              - ``dyn.example.com.``
            * - **Send updates**
              - ``X``
            * - **Conflict resolution**
              - ``Check with DHCID (RFC 4703)``

    .. tab:: TSIG Keys

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - Option
              - Value
            * - **Name**
              - ``ddns-key.dyn.example.com``
            * - **Algorithm**
              - ``HMAC-SHA256``
            * - **Secret**
              - Click **Generate** to create a random secret, then copy it to your DNS server

        Press **Save**.

    .. tab:: Forward Zones

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - Option
              - Value
            * - **Zone name**
              - ``dyn.example.com``
            * - **DNS server**
              - ``192.168.1.53``
            * - **Port**
              - ``53``
            * - **TSIG key**
              - ``ddns-key.dyn.example.com``

        Press **Save**.

    .. tab:: Reverse Zones

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - Option
              - Value
            * - **Zone name**
              - ``1.168.192.in-addr.arpa``
            * - **DNS server**
              - ``192.168.1.53``
            * - **Port**
              - ``53``
            * - **TSIG key**
              - ``ddns-key.dyn.example.com``

        Press **Save**.

    .. tab:: Subnet DDNS

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - Option
              - Value
            * - **Subnet**
              - ``192.168.1.0/24``
            * - **Qualifying suffix**
              - ``lan.dyn.example.com.`` (overrides the global default)

        The remaining fields (send updates, conflict resolution, etc.) inherit from the global
        DDNS defaults on the Settings tab. Press **Save**.

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

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - Option
              - Value
            * - **Zone name**
              - ``a.9.8.7.6.5.4.3.2.1.d.f.ip6.arpa``
            * - **DNS server**
              - ``192.168.1.53``
            * - **Port**
              - ``53``
            * - **TSIG key**
              - ``ddns-key.dyn.example.com``

        Press **Save**.

    .. tab:: Subnet6 DDNS

        .. list-table::
            :header-rows: 1
            :widths: 30 70

            * - Option
              - Value
            * - **Subnet**
              - ``fd12:3456:789a:feed::/64``
            * - **Qualifying suffix**
              - ``lan.dyn.example.com.``
            * - **Send updates**
              - ``X``
            * - **Conflict resolution**
              - ``No check, store DHCID``

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

The plugin integrates with the core Kea DHCP service using the standard
``plugins_configure()`` mechanism. When Kea is started, restarted, or
reconfigured, the ``kea_sync`` event fires. OPNsense processes all registered
plugins alphabetically:

1. **Core** (``kea.inc``) runs ``kea_configure_do()`` — generates
   ``kea-dhcp4.conf`` and ``kea-dhcp6.conf`` as JSON files.

2. **This plugin** (``kea_ddns.inc``) runs ``kea_ddns_configure_do()`` — reads
   those JSON files, merges DDNS parameters (global settings and per-subnet
   overlays), writes them back, generates ``kea-dhcp-ddns.conf``, and enables
   the DDNS daemon in ``keactrl.conf``.

This approach requires no modifications to OPNsense core files. The plugin
survives OPNsense firmware updates without reinstallation.

The ``kea-dhcp-ddns`` daemon listens on ``127.0.0.1:53001`` and receives Name
Change Requests (NCRs) from the DHCPv4 and DHCPv6 daemons over a local
connection. It then translates these into RFC 2136 DNS UPDATE requests sent to
the configured DNS servers.


Coexistence with core DDNS
--------------------------

Starting with OPNsense 26.1.5, the core includes built-in DDNS support for Kea
(see `core PR #9923 <https://github.com/opnsense/core/pull/9923>`_). The plugin
can be installed alongside core DDNS — use **one or the other**, not both at the
same time.

Both the core and the plugin register on the ``kea_sync`` hook. Alphabetical
ordering (``kea.inc`` < ``kea_ddns.inc``) means the plugin always runs second,
post-processing the core's generated configuration. If both are enabled
simultaneously, the plugin takes precedence.

**Recommended usage:**

- **Plugin only** — keep core DDNS disabled (the default at
  :menuselection:`Services --> KEA DHCP --> Settings`). The plugin handles
  everything independently.
- **Core only** — disable the plugin in
  :menuselection:`Services --> Kea Dynamic DNS --> Settings`. A disabled plugin
  is fully inert and does not interfere with core DDNS.
- **Switching** — you can switch between the two at any time. Disable one before
  enabling the other, then click **Apply**.

The plugin offers additional features not available in the core implementation:

- Global DDNS defaults (qualifying suffix, send updates, conflict resolution,
  etc.) that all subnets inherit, with per-subnet overrides where needed
- Shared TSIG keys across multiple subnets and zones (core requires a separate
  TSIG key per subnet)
- Reverse zone auto-derive from Kea subnets
- DDNS status dashboard with daemon statistics and per-lease DDNS info
- Log file viewer for the ``kea-dhcp-ddns`` daemon
- DHCPv6 DDNS support with Rapid Commit

.. note::

    These interaction scenarios have been tested on OPNsense 26.7.a_328 using
    the automated interaction test suite
    (``scripts/ddns_interaction_test.sh``). The test covers five scenarios:
    core-only, plugin-only, both enabled, plugin disabled with core active, and
    cleanup after plugin removal. All 56 tests pass.


Uninstall
---------

Remove the package::

    pkg delete os-kea-ddns

This removes all plugin files, disables DDNS in ``keactrl.conf``, and removes
``kea-dhcp-ddns.conf``. No core files are modified or need to be restored.


API
---

All configuration is available via the REST API under
``/api/keaddns/general/``.

.. tabs::

    .. tab:: General

        .. list-table::
            :header-rows: 1
            :widths: 50 10 40

            * - **Endpoint**
              - **Method**
              - **Description**
            * - ``/api/keaddns/general/get``
              - GET
              - Get general settings (enabled, manual_config)
            * - ``/api/keaddns/general/set``
              - POST
              - Save general settings

    .. tab:: TSIG Keys

        .. list-table::
            :header-rows: 1
            :widths: 50 10 40

            * - **Endpoint**
              - **Method**
              - **Description**
            * - ``/api/keaddns/general/searchTsigKey``
              - GET
              - List all TSIG keys
            * - ``/api/keaddns/general/getTsigKey/{uuid}``
              - GET
              - Get a single TSIG key
            * - ``/api/keaddns/general/addTsigKey``
              - POST
              - Create a TSIG key
            * - ``/api/keaddns/general/setTsigKey/{uuid}``
              - POST
              - Update a TSIG key
            * - ``/api/keaddns/general/delTsigKey/{uuid}``
              - POST
              - Delete a TSIG key
            * - ``/api/keaddns/general/generateTsigSecret``
              - POST
              - Generate a random TSIG secret (param: ``algorithm``)

    .. tab:: Zones

        .. list-table::
            :header-rows: 1
            :widths: 50 10 40

            * - **Endpoint**
              - **Method**
              - **Description**
            * - ``/api/keaddns/general/searchForwardZone``
              - GET
              - List forward zones
            * - ``/api/keaddns/general/getForwardZone/{uuid}``
              - GET
              - Get a forward zone
            * - ``/api/keaddns/general/addForwardZone``
              - POST
              - Create a forward zone
            * - ``/api/keaddns/general/setForwardZone/{uuid}``
              - POST
              - Update a forward zone
            * - ``/api/keaddns/general/delForwardZone/{uuid}``
              - POST
              - Delete a forward zone
            * - ``/api/keaddns/general/searchReverseZone``
              - GET
              - List reverse zones
            * - ``/api/keaddns/general/getReverseZone/{uuid}``
              - GET
              - Get a reverse zone
            * - ``/api/keaddns/general/addReverseZone``
              - POST
              - Create a reverse zone
            * - ``/api/keaddns/general/setReverseZone/{uuid}``
              - POST
              - Update a reverse zone
            * - ``/api/keaddns/general/delReverseZone/{uuid}``
              - POST
              - Delete a reverse zone
            * - ``/api/keaddns/general/suggestReverseZones``
              - POST
              - Suggest reverse zone names from Kea subnets

    .. tab:: Status

        .. list-table::
            :header-rows: 1
            :widths: 50 10 40

            * - **Endpoint**
              - **Method**
              - **Description**
            * - ``/api/keaddns/general/ddnsStatus``
              - POST
              - Get D2 daemon status and statistics
            * - ``/api/keaddns/general/searchDdnsLeases``
              - POST
              - Search DDNS-registered leases (paginated)

    .. tab:: Subnet DDNS

        .. list-table::
            :header-rows: 1
            :widths: 50 10 40

            * - **Endpoint**
              - **Method**
              - **Description**
            * - ``/api/keaddns/general/searchSubnetDdns``
              - GET
              - List DHCPv4 subnet DDNS assignments
            * - ``/api/keaddns/general/getSubnetDdns/{uuid}``
              - GET
              - Get a DHCPv4 DDNS assignment
            * - ``/api/keaddns/general/addSubnetDdns``
              - POST
              - Create a DHCPv4 DDNS assignment
            * - ``/api/keaddns/general/setSubnetDdns/{uuid}``
              - POST
              - Update a DHCPv4 DDNS assignment
            * - ``/api/keaddns/general/delSubnetDdns/{uuid}``
              - POST
              - Delete a DHCPv4 DDNS assignment
            * - ``/api/keaddns/general/searchSubnet6Ddns``
              - GET
              - List DHCPv6 subnet DDNS assignments
            * - ``/api/keaddns/general/getSubnet6Ddns/{uuid}``
              - GET
              - Get a DHCPv6 DDNS assignment
            * - ``/api/keaddns/general/addSubnet6Ddns``
              - POST
              - Create a DHCPv6 DDNS assignment
            * - ``/api/keaddns/general/setSubnet6Ddns/{uuid}``
              - POST
              - Update a DHCPv6 DDNS assignment
            * - ``/api/keaddns/general/delSubnet6Ddns/{uuid}``
              - POST
              - Delete a DHCPv6 DDNS assignment
