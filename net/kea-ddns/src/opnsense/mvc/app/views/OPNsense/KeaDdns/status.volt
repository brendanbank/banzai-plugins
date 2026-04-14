<script>
    $( document ).ready(function() {
        /* Daemon Status tab */
        function loadDaemonStatus() {
            $.post('/api/keaddns/general/ddnsStatus', function(data) {
                var html = '';
                if (!data.running) {
                    html = '<div class="alert alert-warning">' +
                        '<i class="fa fa-exclamation-triangle"></i> ' +
                        '{{ lang._("DDNS daemon is not running.") }}</div>';
                    $('#daemon-status-content').html(html);
                    return;
                }

                /* Daemon info */
                html += '<h3>{{ lang._("Daemon") }}</h3>';
                html += '<table class="table table-condensed">';
                html += '<tbody>';
                if (data.version) {
                    html += '<tr><td style="width:200px;"><b>{{ lang._("Version") }}</b></td>' +
                        '<td>' + $('<span>').text(data.version).html() + '</td></tr>';
                }
                if (data.status) {
                    html += '<tr><td><b>{{ lang._("PID") }}</b></td>' +
                        '<td>' + data.status.pid + '</td></tr>';
                    var uptime = data.status.uptime;
                    var days = Math.floor(uptime / 86400);
                    var hours = Math.floor((uptime % 86400) / 3600);
                    var mins = Math.floor((uptime % 3600) / 60);
                    var secs = uptime % 60;
                    var uptimeStr = '';
                    if (days > 0) uptimeStr += days + 'd ';
                    if (hours > 0 || days > 0) uptimeStr += hours + 'h ';
                    uptimeStr += mins + 'm ' + secs + 's';
                    html += '<tr><td><b>{{ lang._("Uptime") }}</b></td><td>' + uptimeStr + '</td></tr>';
                }
                html += '</tbody></table>';

                /* Statistics */
                if (data.statistics) {
                    var stats = data.statistics;

                    html += '<h3>{{ lang._("Update Statistics") }}</h3>';
                    html += '<table class="table table-condensed table-striped">';
                    html += '<thead><tr><th>{{ lang._("Statistic") }}</th>' +
                        '<th style="width:120px;text-align:right;">{{ lang._("Value") }}</th></tr></thead>';
                    html += '<tbody>';
                    var globalStats = [
                        ['ncr-received', '{{ lang._("NCR received") }}'],
                        ['ncr-invalid', '{{ lang._("NCR invalid") }}'],
                        ['ncr-error', '{{ lang._("NCR error") }}'],
                        ['queue-mgr-queue-full', '{{ lang._("Queue full") }}'],
                        ['update-sent', '{{ lang._("Updates sent") }}'],
                        ['update-success', '{{ lang._("Updates successful") }}'],
                        ['update-error', '{{ lang._("Updates error") }}'],
                        ['update-timeout', '{{ lang._("Updates timeout") }}'],
                        ['update-signed', '{{ lang._("Updates signed") }}'],
                        ['update-unsigned', '{{ lang._("Updates unsigned") }}']
                    ];
                    $.each(globalStats, function(i, pair) {
                        var val = stats[pair[0]];
                        if (val !== undefined) {
                            html += '<tr><td>' + pair[1] + '</td>' +
                                '<td style="text-align:right;">' + val + '</td></tr>';
                        }
                    });
                    html += '</tbody></table>';

                    /* Per-key statistics */
                    var keyStats = {};
                    $.each(stats, function(name, val) {
                        var m = name.match(/^key\[(.+)\]\.(.+)$/);
                        if (m) {
                            if (!keyStats[m[1]]) keyStats[m[1]] = {};
                            keyStats[m[1]][m[2]] = val;
                        }
                    });
                    if (Object.keys(keyStats).length > 0) {
                        html += '<h3>{{ lang._("Per-Key Statistics") }}</h3>';
                        html += '<table class="table table-condensed table-striped">';
                        html += '<thead><tr><th>{{ lang._("TSIG Key") }}</th>' +
                            '<th style="text-align:right;">{{ lang._("Sent") }}</th>' +
                            '<th style="text-align:right;">{{ lang._("Success") }}</th>' +
                            '<th style="text-align:right;">{{ lang._("Error") }}</th>' +
                            '<th style="text-align:right;">{{ lang._("Timeout") }}</th></tr></thead>';
                        html += '<tbody>';
                        $.each(keyStats, function(keyName, kv) {
                            html += '<tr><td>' + $('<span>').text(keyName).html() + '</td>' +
                                '<td style="text-align:right;">' + (kv['update-sent'] || 0) + '</td>' +
                                '<td style="text-align:right;">' + (kv['update-success'] || 0) + '</td>' +
                                '<td style="text-align:right;">' + (kv['update-error'] || 0) + '</td>' +
                                '<td style="text-align:right;">' + (kv['update-timeout'] || 0) + '</td></tr>';
                        });
                        html += '</tbody></table>';
                    }
                }

                $('#daemon-status-content').html(html);
            });
        }

        /* DDNS Leases tabs */
        var leasesGridOptions = {
            tabulatorOptions: {
                groupBy: 'subnet',
                groupHeader: function(value, count) {
                    var label = value ? value : '{{ lang._("Unknown") }}';
                    var badge = '<span class="badge chip">' + count + '</span>';
                    return '<i class="fa fa-fw fa-sitemap fa-sm text-info"></i> ' + label + ' ' + badge;
                },
            },
            options: {
                selection: false,
                multiSelect: false,
                formatters: {
                    fqdnCheck: function(column, row) {
                        return row[column.id] === '1' ?
                            '<i class="fa fa-check text-success"></i>' :
                            '<i class="fa fa-times text-muted"></i>';
                    },
                    expireDate: function(column, row) {
                        var ts = parseInt(row[column.id]);
                        if (!ts) return '';
                        var d = new Date(ts * 1000);
                        return d.toLocaleString();
                    }
                }
            }
        };

        var leases4GridInitialized = false;
        var leases6GridInitialized = false;

        function initLeases4Grid() {
            if (leases4GridInitialized) {
                $('#gridDdnsLeases4').bootgrid('reload');
                return;
            }
            leases4GridInitialized = true;
            $('#gridDdnsLeases4').UIBootgrid($.extend(true, {}, leasesGridOptions, {
                search: '/api/keaddns/general/searchDdnsLeases4'
            }));
        }

        function initLeases6Grid() {
            if (leases6GridInitialized) {
                $('#gridDdnsLeases6').bootgrid('reload');
                return;
            }
            leases6GridInitialized = true;
            $('#gridDdnsLeases6').UIBootgrid($.extend(true, {}, leasesGridOptions, {
                search: '/api/keaddns/general/searchDdnsLeases6'
            }));
        }

        /* Load daemon status on page load */
        loadDaemonStatus();

        $('#btnRefreshDaemon').on('click', function() {
            loadDaemonStatus();
        });

        $('a[href="#ddns-leases4"]').on('shown.bs.tab', function() {
            initLeases4Grid();
        });

        $('a[href="#ddns-leases6"]').on('shown.bs.tab', function() {
            initLeases6Grid();
        });

        $('#btnRefreshLeases').on('click', function() {
            var activeTab = $('.nav-tabs .active a').attr('href');
            if (activeTab === '#ddns-leases4' && leases4GridInitialized) {
                $('#gridDdnsLeases4').bootgrid('reload');
            } else if (activeTab === '#ddns-leases6' && leases6GridInitialized) {
                $('#gridDdnsLeases6').bootgrid('reload');
            }
        });
    });
</script>

<ul class="nav nav-tabs" data-tabs="tabs" id="maintabs">
    <li class="active"><a data-toggle="tab" href="#daemon-status" id="tab_daemon">{{ lang._('Daemon Status') }}</a></li>
    <li><a data-toggle="tab" href="#ddns-leases4" id="tab_leases4">{{ lang._('DDNS DHCPv4') }}</a></li>
    <li><a data-toggle="tab" href="#ddns-leases6" id="tab_leases6">{{ lang._('DDNS DHCPv6') }}</a></li>
</ul>
<div class="tab-content content-box">
    <div id="daemon-status" class="tab-pane fade in active">
        <div class="col-md-12" style="padding: 16px;">
            <button class="btn btn-default btn-sm pull-right" id="btnRefreshDaemon">
                <i class="fa fa-refresh"></i> {{ lang._('Refresh') }}
            </button>
            <div id="daemon-status-content">
                <p class="text-muted"><i class="fa fa-spinner fa-spin"></i> {{ lang._('Loading...') }}</p>
            </div>
        </div>
    </div>
    <div id="ddns-leases4" class="tab-pane fade in">
        <table id="gridDdnsLeases4" class="table table-condensed table-hover table-striped table-responsive" data-editDialog="">
            <thead>
                <tr>
                    <th data-column-id="subnet" data-type="string" data-visible="false">{{ lang._('Subnet') }}</th>
                    <th data-column-id="hostname" data-type="string" data-identifier="true">{{ lang._('Hostname') }}</th>
                    <th data-column-id="address" data-type="string">{{ lang._('Address') }}</th>
                    <th data-column-id="hwaddr" data-type="string">{{ lang._('MAC') }}</th>
                    <th data-column-id="fqdn_fwd" data-type="string" data-formatter="fqdnCheck" data-width="80px" data-css-class="text-center" data-header-css-class="text-center">{{ lang._('Forward') }}</th>
                    <th data-column-id="fqdn_rev" data-type="string" data-formatter="fqdnCheck" data-width="80px" data-css-class="text-center" data-header-css-class="text-center">{{ lang._('Reverse') }}</th>
                    <th data-column-id="expire" data-type="string" data-formatter="expireDate">{{ lang._('Expires') }}</th>
                </tr>
            </thead>
            <tbody>
            </tbody>
        </table>
    </div>
    <div id="ddns-leases6" class="tab-pane fade in">
        <table id="gridDdnsLeases6" class="table table-condensed table-hover table-striped table-responsive" data-editDialog="">
            <thead>
                <tr>
                    <th data-column-id="subnet" data-type="string" data-visible="false">{{ lang._('Subnet') }}</th>
                    <th data-column-id="hostname" data-type="string" data-identifier="true">{{ lang._('Hostname') }}</th>
                    <th data-column-id="address" data-type="string">{{ lang._('Address') }}</th>
                    <th data-column-id="hwaddr" data-type="string">{{ lang._('MAC') }}</th>
                    <th data-column-id="fqdn_fwd" data-type="string" data-formatter="fqdnCheck" data-width="80px" data-css-class="text-center" data-header-css-class="text-center">{{ lang._('Forward') }}</th>
                    <th data-column-id="fqdn_rev" data-type="string" data-formatter="fqdnCheck" data-width="80px" data-css-class="text-center" data-header-css-class="text-center">{{ lang._('Reverse') }}</th>
                    <th data-column-id="expire" data-type="string" data-formatter="expireDate">{{ lang._('Expires') }}</th>
                </tr>
            </thead>
            <tbody>
            </tbody>
        </table>
    </div>
</div>
