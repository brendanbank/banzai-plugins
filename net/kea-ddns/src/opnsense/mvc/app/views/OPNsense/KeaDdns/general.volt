<script>
    $( document ).ready(function() {
        const data_get_map = {'frm_generalsettings':"/api/keaddns/general/get"};
        mapDataToFormUI(data_get_map).done(function(data){
            updateServiceControlUI('kea');
        });

        $("#gridTsigKeys").UIBootgrid({
            search:'/api/keaddns/general/searchTsigKey',
            get:'/api/keaddns/general/getTsigKey/',
            set:'/api/keaddns/general/setTsigKey/',
            add:'/api/keaddns/general/addTsigKey/',
            del:'/api/keaddns/general/delTsigKey/'
        });

        $('#dialog_gridTsigKeys').on('shown.bs.modal', function() {
            var secretInput = $(this).find('input[id$="tsig_key.secret"]');
            if (secretInput.length && !secretInput.next('.btn-generate-secret').length) {
                var btn = $('<button type="button" class="btn btn-default btn-generate-secret" style="margin-left: 8px;">' +
                    '<i class="fa fa-random"></i> {{ lang._("Generate") }}</button>');
                secretInput.after(btn);
                secretInput.css('display', 'inline-block').css('width', 'calc(100% - 110px)');
                btn.on('click', function() {
                    var algorithm = $('#dialog_gridTsigKeys select[id$="tsig_key.algorithm"]').val();
                    $.post('/api/keaddns/general/generateTsigSecret', {algorithm: algorithm}, function(data) {
                        if (data.secret) {
                            secretInput.val(data.secret);
                        }
                    });
                });
            }
        });

        $("#gridForwardZones").UIBootgrid({
            search:'/api/keaddns/general/searchForwardZone',
            get:'/api/keaddns/general/getForwardZone/',
            set:'/api/keaddns/general/setForwardZone/',
            add:'/api/keaddns/general/addForwardZone/',
            del:'/api/keaddns/general/delForwardZone/'
        });

        $("#gridReverseZones").UIBootgrid({
            search:'/api/keaddns/general/searchReverseZone',
            get:'/api/keaddns/general/getReverseZone/',
            set:'/api/keaddns/general/setReverseZone/',
            add:'/api/keaddns/general/addReverseZone/',
            del:'/api/keaddns/general/delReverseZone/'
        });

        $("#gridSubnetDdns").UIBootgrid({
            search:'/api/keaddns/general/searchSubnetDdns',
            get:'/api/keaddns/general/getSubnetDdns/',
            set:'/api/keaddns/general/setSubnetDdns/',
            add:'/api/keaddns/general/addSubnetDdns/',
            del:'/api/keaddns/general/delSubnetDdns/'
        });

        $("#gridSubnet6Ddns").UIBootgrid({
            search:'/api/keaddns/general/searchSubnet6Ddns',
            get:'/api/keaddns/general/getSubnet6Ddns/',
            set:'/api/keaddns/general/setSubnet6Ddns/',
            add:'/api/keaddns/general/addSubnet6Ddns/',
            del:'/api/keaddns/general/delSubnet6Ddns/'
        });

        function toggleGeneratedPrefix(dialogId) {
            var replaceVal = $('#' + dialogId + ' select[id$="assignment.replace_client_name"]').val();
            var row = $('#' + dialogId + ' *[id$="assignment.generated_prefix"]').closest('tr');
            if (replaceVal === 'never') {
                row.hide();
            } else {
                row.show();
            }
        }

        $('#dialogSubnetDdns').on('shown.bs.modal', function() {
            toggleGeneratedPrefix('dialogSubnetDdns');
            $(this).find('select[id$="assignment.replace_client_name"]').on('change', function() {
                toggleGeneratedPrefix('dialogSubnetDdns');
            });
        });

        $('#dialogSubnet6Ddns').on('shown.bs.modal', function() {
            toggleGeneratedPrefix('dialogSubnet6Ddns');
            $(this).find('select[id$="assignment.replace_client_name"]').on('change', function() {
                toggleGeneratedPrefix('dialogSubnet6Ddns');
            });
        });

        $("#reconfigureAct").SimpleActionButton({
            onPreAction: function() {
                const dfObj = new $.Deferred();
                saveFormToEndpoint("/api/keaddns/general/set", 'frm_generalsettings', function () {
                    dfObj.resolve();
                }, true, function () {
                    dfObj.reject();
                });
                return dfObj;
            },
            onAction: function(data, status) {
                updateServiceControlUI('kea');
            }
        });
    });
</script>

<ul class="nav nav-tabs" data-tabs="tabs" id="maintabs">
    <li class="active"><a data-toggle="tab" href="#settings" id="tab_settings">{{ lang._('Settings') }}</a></li>
    <li><a data-toggle="tab" href="#tsig-keys" id="tab_tsig">{{ lang._('TSIG Keys') }}</a></li>
    <li><a data-toggle="tab" href="#forward-zones" id="tab_forward">{{ lang._('Forward Zones') }}</a></li>
    <li><a data-toggle="tab" href="#reverse-zones" id="tab_reverse">{{ lang._('Reverse Zones') }}</a></li>
    <li><a data-toggle="tab" href="#subnet-ddns" id="tab_subnet">{{ lang._('Subnet DDNS') }}</a></li>
    <li><a data-toggle="tab" href="#subnet6-ddns" id="tab_subnet6">{{ lang._('Subnet6 DDNS') }}</a></li>
</ul>
<div class="tab-content content-box">
    <div id="settings" class="tab-pane fade in active">
        {{ partial("layout_partials/base_form",['fields':formGeneralSettings,'id':'frm_generalsettings'])}}
    </div>
    <div id="tsig-keys" class="tab-pane fade in">
        {{ partial('layout_partials/base_bootgrid_table', formGridTsigKey)}}
    </div>
    <div id="forward-zones" class="tab-pane fade in">
        {{ partial('layout_partials/base_bootgrid_table', formGridForwardZone)}}
    </div>
    <div id="reverse-zones" class="tab-pane fade in">
        {{ partial('layout_partials/base_bootgrid_table', formGridReverseZone)}}
    </div>
    <div id="subnet-ddns" class="tab-pane fade in">
        {{ partial('layout_partials/base_bootgrid_table', formGridSubnetDdns)}}
    </div>
    <div id="subnet6-ddns" class="tab-pane fade in">
        {{ partial('layout_partials/base_bootgrid_table', formGridSubnet6Ddns)}}
    </div>
</div>

<section class="page-content-main">
    <div class="content-box">
        <div class="col-md-12">
            <br/>
            <button class="btn btn-primary" id="reconfigureAct"
                    data-endpoint="/api/kea/service/reconfigure"
                    data-label="{{ lang._('Apply') }}"
                    data-error-title="{{ lang._('Error reconfiguring Kea') }}"
                    type="button">
            </button>
            <br/><br/>
        </div>
    </div>
</section>

{{ partial("layout_partials/base_dialog",['fields':formDialogTsigKey,'id':formGridTsigKey['edit_dialog_id'],'label':lang._('Edit TSIG Key')])}}
{{ partial("layout_partials/base_dialog",['fields':formDialogForwardZone,'id':formGridForwardZone['edit_dialog_id'],'label':lang._('Edit Forward Zone')])}}
{{ partial("layout_partials/base_dialog",['fields':formDialogReverseZone,'id':formGridReverseZone['edit_dialog_id'],'label':lang._('Edit Reverse Zone')])}}
{{ partial("layout_partials/base_dialog",['fields':formDialogSubnetDdns,'id':formGridSubnetDdns['edit_dialog_id'],'label':lang._('Edit Subnet DDNS')])}}
{{ partial("layout_partials/base_dialog",['fields':formDialogSubnet6Ddns,'id':formGridSubnet6Ddns['edit_dialog_id'],'label':lang._('Edit Subnet6 DDNS')])}}
