===========
Hello World
===========

A minimal MVC plugin demonstrating the OPNsense plugin framework. Provides a
settings page with an enabled toggle and a configurable greeting message.

:Package: ``os-hello_world``
:Navigation: :menuselection:`Services --> Hello World --> Settings`

Settings
--------

.. list-table::
   :header-rows: 1
   :widths: 20 60 20

   * - Setting
     - Description
     - Default
   * - Enabled
     - Enable the Hello World plugin.
     - Off
   * - Greeting Message
     - A greeting message to display (1--255 characters).
     - ``Hello, World!``

API Endpoints
-------------

The plugin exposes a standard OPNsense model API under ``/api/helloworld/general/``:

.. list-table::
   :header-rows: 1

   * - Method
     - Endpoint
     - Description
   * - GET
     - ``/api/helloworld/general/get``
     - Retrieve current settings
   * - POST
     - ``/api/helloworld/general/set``
     - Update settings
