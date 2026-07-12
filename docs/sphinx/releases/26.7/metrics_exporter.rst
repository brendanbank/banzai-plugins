================
Metrics Exporter
================

Prometheus exporter for OPNsense-specific metrics. Runs a daemon that collects
gateway, firewall, and DNS resolver metrics at a configurable interval and
writes them in Prometheus exposition format to the ``node_exporter`` textfile
collector directory.

Requires the ``os-node_exporter`` plugin.

:Package: ``os-metrics_exporter``
:Navigation: :menuselection:`Services --> Metrics Exporter --> Settings`

Settings
--------

.. list-table::
   :header-rows: 1
   :widths: 20 60 20

   * - Setting
     - Description
     - Default
   * - Enabled
     - Enable the Metrics Exporter service.
     - On
   * - Interval
     - Collection interval in seconds (5--300).
     - ``15``
   * - Output Directory
     - Directory for ``.prom`` files (must be absolute, ending in ``/``).
     - ``/var/tmp/node_exporter/``
   * - Collectors
     - Per-collector enable/disable toggles.
     - All enabled

Collectors
----------

Gateway
~~~~~~~

Monitors gateway status, latency, and packet loss via the OPNsense configd
backend.

.. list-table::
   :header-rows: 1
   :widths: 40 10 50

   * - Metric
     - Type
     - Description
   * - ``opnsense_gateway_status``
     - gauge
     - Gateway status (0=down, 1=up, 2=loss, 3=delay, 4=delay+loss, 5=unknown).
   * - ``opnsense_gateway_delay_seconds``
     - gauge
     - Gateway round-trip time in seconds.
   * - ``opnsense_gateway_stddev_seconds``
     - gauge
     - Gateway RTT standard deviation in seconds.
   * - ``opnsense_gateway_loss_ratio``
     - gauge
     - Gateway packet loss ratio (0.0--1.0).
   * - ``opnsense_gateway_info``
     - gauge
     - Informational metric with ``status`` and ``monitor`` labels.

All gateway metrics carry ``name`` and ``description`` labels.

PF Firewall
~~~~~~~~~~~~

Collects PF firewall state table and counter statistics.

.. list-table::
   :header-rows: 1
   :widths: 40 10 50

   * - Metric
     - Type
     - Description
   * - ``opnsense_pf_states``
     - gauge
     - Current number of PF state table entries.
   * - ``opnsense_pf_states_limit``
     - gauge
     - Hard limit on PF state table entries.
   * - ``opnsense_pf_state_searches_total``
     - counter
     - Total PF state table searches.
   * - ``opnsense_pf_state_inserts_total``
     - counter
     - Total PF state table inserts.
   * - ``opnsense_pf_state_removals_total``
     - counter
     - Total PF state table removals.
   * - ``opnsense_pf_counter_total``
     - counter
     - PF counter by type (``name`` label).

Unbound DNS
~~~~~~~~~~~

Collects Unbound DNS resolver statistics including query counts, cache
performance, memory usage, and DNSSEC validation.

.. list-table::
   :header-rows: 1
   :widths: 45 10 45

   * - Metric
     - Type
     - Description
   * - ``opnsense_unbound_queries_total``
     - counter
     - Total DNS queries received.
   * - ``opnsense_unbound_cache_hits_total``
     - counter
     - Total cache hits.
   * - ``opnsense_unbound_cache_misses_total``
     - counter
     - Total cache misses.
   * - ``opnsense_unbound_prefetch_total``
     - counter
     - Total prefetch actions.
   * - ``opnsense_unbound_recursive_replies_total``
     - counter
     - Total recursive replies.
   * - ``opnsense_unbound_answer_rcode_total``
     - counter
     - DNS answers by ``rcode`` label.
   * - ``opnsense_unbound_query_type_total``
     - counter
     - DNS queries by ``type`` label.
   * - ``opnsense_unbound_query_opcode_total``
     - counter
     - DNS queries by ``opcode`` label.
   * - ``opnsense_unbound_memory_bytes``
     - gauge
     - Memory usage in bytes (``cache``, ``module``, or ``type`` label).
   * - ``opnsense_unbound_requestlist_avg``
     - gauge
     - Average request list size.
   * - ``opnsense_unbound_requestlist_max``
     - gauge
     - Maximum request list size.
   * - ``opnsense_unbound_requestlist_overwritten_total``
     - counter
     - Overwritten request list entries.
   * - ``opnsense_unbound_requestlist_exceeded_total``
     - counter
     - Exceeded request list entries.
   * - ``opnsense_unbound_requestlist_current``
     - gauge
     - Current request list size.
   * - ``opnsense_unbound_recursion_time_avg_seconds``
     - gauge
     - Average recursion time in seconds.
   * - ``opnsense_unbound_recursion_time_median_seconds``
     - gauge
     - Median recursion time in seconds.
   * - ``opnsense_unbound_tcp_usage``
     - gauge
     - Current TCP buffer usage.
   * - ``opnsense_unbound_answer_secure_total``
     - counter
     - DNSSEC secure answers.
   * - ``opnsense_unbound_answer_bogus_total``
     - counter
     - DNSSEC bogus answers.
   * - ``opnsense_unbound_rrset_bogus_total``
     - counter
     - DNSSEC bogus RRsets.
   * - ``opnsense_unbound_unwanted_queries_total``
     - counter
     - Total unwanted queries.
   * - ``opnsense_unbound_unwanted_replies_total``
     - counter
     - Total unwanted replies.
