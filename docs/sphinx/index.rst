===============
banzai-plugins
===============

Over the last four years of running OPNsense I've built various scripts and
tools to manage and monitor my firewalls and the networks they serve. With each
new release I do a clean install to avoid maintenance issues, which meant
reinstalling all of these tools by hand every time.

Some of them have become essential to my workflow. The Prometheus metrics
exporter, for example, feeds dpinger output into Prometheus and on to Grafana
alerting, giving me visibility into my VPN overlay network so I know the moment
something breaks.

This repository collects those tools and packages them as proper OPNsense
plugins so they survive upgrades. Packages are signed and served from a
per-release pkg repository via GitHub Pages, so installation is just a
``pkg install`` or a click in the Firmware UI.

**Why a separate repo?** These plugins sometimes involve a fair amount of code
that would be difficult for the OPNsense team to validate and maintain,
especially when adoption is likely to be limited. The OPNsense developers are
focused on building a great product and shouldn't be distracted by niche tools
that serve a small audience. This is not criticism -- it's simply the reality
that you can't do it all. If a plugin here matures to the point where it
belongs in the official `opnsense/plugins <https://github.com/opnsense/plugins>`_
repository, great -- it will follow the standards and requirements set by the
OPNsense project. Until then, contributions are welcome here.

I'm an `amateur <https://winningmindtraining.com/remaining-an-amateur-a-lover-of-the-work/>`_
Python developer -- a lover of the work rather than a professional software
engineer. I do have a long history with FreeBSD from my days as a sysadmin
(DevOps before it had a name), when I built and ran products like imap4all.com.
These plugins lean heavily on LLM-assisted development -- particularly
`Claude Code <https://claude.ai/claude-code>`_ -- for the MVC boilerplate,
build infrastructure, and FreeBSD packaging. The code works, but it may not
always follow every OPNsense convention to the letter. Suggestions and
contributions are very welcome -- feel free to open an issue or pull request
on `GitHub <https://github.com/brendanbank/banzai-plugins>`_.

.. warning::

   These plugins are provided as-is. **Use at your own risk.**

Plugins
-------

.. list-table::
   :header-rows: 1

   * - Plugin
     - Package
     - Description
   * - Hello World
     - ``os-hello_world``
     - Hello World example plugin

Links
-----

- `GitHub repository <https://github.com/brendanbank/banzai-plugins>`_
- `License (BSD 2-Clause) <https://github.com/brendanbank/banzai-plugins/blob/main/LICENSE>`_

.. toctree::
   :caption: Plugin Releases

   releases/26.1/index
