==============
OPNsense 26.1
==============

Supported release: OPNsense 26.1

.. toctree::
   :caption: Plugins

   hello_world
   metrics_exporter

Installation
------------

1. Trust the repository signing key
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

All packages are signed. Set up the signing fingerprint on your firewall:

::

    mkdir -p /usr/local/etc/pkg/fingerprints/banzai-plugins/trusted
    mkdir -p /usr/local/etc/pkg/fingerprints/banzai-plugins/revoked

    cat > /usr/local/etc/pkg/fingerprints/banzai-plugins/trusted/repo.fingerprint <<'EOF'
    function: sha256
    fingerprint: 5d03d774f3fa2926f9e2156b98d261461478f4f5d1332926fa5c7906b29eab87
    EOF

You can verify the fingerprint matches the public key in
`Keys/repo.pub <https://github.com/brendanbank/banzai-plugins/blob/main/Keys/repo.pub>`_
in the repository.

2. Add the repository
~~~~~~~~~~~~~~~~~~~~~

The repo URL includes the ABI (resolved by pkg at runtime) and OPNsense series:

::

    SERIES=$(opnsense-version -a)

    cat > /usr/local/etc/pkg/repos/banzai-plugins.conf <<EOF
    banzai-plugins: {
      url: "https://brendanbank.github.io/banzai-plugins/\${ABI}/${SERIES}/repo",
      signature_type: "fingerprints",
      fingerprints: "/usr/local/etc/pkg/fingerprints/banzai-plugins",
      enabled: yes
    }
    EOF
    pkg update -f -r banzai-plugins

- ``${ABI}`` is a pkg built-in variable (e.g., ``FreeBSD:14:amd64``) resolved at runtime.
- ``${SERIES}`` is the OPNsense series (e.g., ``26.1``) from ``opnsense-version -a``.

3. Install a plugin
~~~~~~~~~~~~~~~~~~~

Navigate to :menuselection:`System --> Firmware --> Plugins` in the OPNsense web UI.
The banzai-plugins will appear in the plugin list and can be installed from there.
