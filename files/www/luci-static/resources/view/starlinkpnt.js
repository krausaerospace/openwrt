'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require poll';
'require network';
'require dom';

/*
 * Starlink PNT - LuCI page for the Starlink->MAVLink position bridge.
 * Maintained in the buildroot repo at
 * files/www/luci-static/resources/view/starlinkpnt.js. The backend is the
 * rpcd ucode plugin /usr/share/rpcd/ucode/starlinkpnt.uc (ubus object
 * luci.starlinkpnt); settings live in uci starlink_mavlink, shared with the
 * starlink-start / starlink-stop shell helpers.
 */

const OBJ = 'luci.starlinkpnt';
const SETTINGS_PARAMS = [ 'mode', 'fc_ip', 'fc_port', 'serial_dev', 'baud', 'custom', 'interval', 'gps_input', 'autostart' ];

const callStatus      = rpc.declare({ object: OBJ, method: 'status' });
const callGetSettings = rpc.declare({ object: OBJ, method: 'get_settings' });
const callCheckDeps   = rpc.declare({ object: OBJ, method: 'check_deps' });
const callSetSettings = rpc.declare({ object: OBJ, method: 'set_settings', params: SETTINGS_PARAMS });
const callStart       = rpc.declare({ object: OBJ, method: 'start', params: SETTINGS_PARAMS });
const callStop        = rpc.declare({ object: OBJ, method: 'stop' });
const callGpsAux      = rpc.declare({ object: OBJ, method: 'gps_aux', params: [ 'fc_ip', 'fc_port', 'action' ] });

/* Default flight-controller address: the board's LAN address with 11 as the
 * third octet, so a board at 10.221.0.21 pairs with an FC at 10.221.11.21. */
function defaultFcIp(lanIp) {
	const o = String(lanIp || '').split('.');
	if (o.length != 4)
		return '10.221.11.1';
	return o[0] + '.' + o[1] + '.11.' + o[3];
}

function notify(res, fallback) {
	const ok = !!(res && res.ok);
	const msg = (res && res.message) ? res.message : (fallback || _('No response from the router'));
	ui.addNotification(null, E('p', { 'style': 'white-space:pre-wrap' }, msg), ok ? 'info' : 'error');
	return ok;
}

function mark(ok, text) {
	return E('strong', { 'style': 'color:' + (ok ? '#2a8a4a' : '#c0392b') }, text);
}

function row(label, cell) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, label),
		cell
	]);
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			L.resolveDefault(callGetSettings(), {}),
			L.resolveDefault(callStatus(), {}),
			L.resolveDefault(network.getNetwork('lan'), null)
		]);
	},

	render: function(data) {
		const settings = data[0] || {};
		const status = data[1] || {};
		const lan = data[2];
		const lanIp = (lan && typeof(lan.getIPAddr) == 'function') ? lan.getIPAddr() : null;
		const fcDefault = defaultFcIp(lanIp);
		let statusState = {};

		/* ---- live status ---------------------------------------------- */
		const cells = {
			bridge:    E('td', { 'class': 'td' }),
			target:    E('td', { 'class': 'td' }),
			fc:        E('td', { 'class': 'td' }),
			dish:      E('td', { 'class': 'td' }),
			autostart: E('td', { 'class': 'td' })
		};
		const logPre = E('pre', { 'style': 'max-height:18em;overflow:auto;font-size:90%;margin-top:.5em' }, '');

		function updateStatus(st) {
			st = st || {};
			statusState = st;
			dom.content(cells.bridge, st.running
				? [ mark(true, _('Running')), (st.pid != null) ? ' (pid %d)'.format(st.pid) : '' ]
				: mark(false, _('Stopped')));
			dom.content(cells.target, st.target ? E('code', st.target) : E('em', _('none saved yet')));
			dom.content(cells.fc, st.last_fc ? E('code', st.last_fc) : E('em', _('not discovered yet')));
			dom.content(cells.dish, st.dish_reachable
				? mark(true, _('reachable'))
				: [ mark(false, _('not reachable')), ' ', E('em', _('(no WAN lease from the dish yet?)')) ]);
			dom.content(cells.autostart, st.autostart ? _('on') : _('off'));
			dom.content(logPre, st.log || _('(no log yet)'));
		}

		function refresh() {
			return L.resolveDefault(callStatus(), {}).then(updateStatus);
		}

		const statusSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Status')),
			E('table', { 'class': 'table' }, [
				row(_('Bridge'), cells.bridge),
				row(_('Configured target'), cells.target),
				row(_('Last discovered flight controller'), cells.fc),
				row(_('Starlink dish (%s)').format(status.dish || '192.168.100.1'), cells.dish),
				row(_('Start at boot'), cells.autostart)
			]),
			E('div', { 'class': 'cbi-value-description' }, _('Bridge log (last lines):')),
			logPre
		]);

		/* ---- settings form (JSON-backed, saved through the plugin) ----- */
		const m = new form.JSONMap({ settings: Object.assign({}, settings) });
		const s = m.section(form.NamedSection, 'settings', 'settings', _('Bridge configuration'),
			_('Where the bridge sends Starlink position fixes. Saved to the same uci config that the starlink-start command uses, so both stay in step.'));
		let o;

		o = s.option(form.ListValue, 'mode', _('Flight controller link'));
		o.value('udp', _('UDP to the flight controller IP'));
		o.value('serial', _('Serial port'));
		o.value('auto', _('Auto-discover on the network'));
		o.value('custom', _('Custom pymavlink connection string'));

		o = s.option(form.Value, 'fc_ip', _('Flight controller IP'),
			lanIp
				? _('Defaults to this board\'s LAN address (%s) with 11 as the third octet: %s.').format(lanIp, fcDefault)
				: _('Default: %s.').format(fcDefault));
		o.depends('mode', 'udp');
		o.datatype = 'ip4addr';
		o.default = fcDefault;
		o.placeholder = fcDefault;
		o.rmempty = false;

		o = s.option(form.Value, 'fc_port', _('UDP port'));
		o.depends('mode', 'udp');
		o.datatype = 'port';
		o.default = '14550';
		o.rmempty = false;

		o = s.option(form.Value, 'serial_dev', _('Serial device'));
		o.depends('mode', 'serial');
		o.placeholder = '/dev/ttyAMA10';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return /^\/dev\/[A-Za-z0-9_-]+$/.test(value) || _('Enter a /dev/... device');
		};

		o = s.option(form.Value, 'baud', _('Baud rate'));
		o.depends('mode', 'serial');
		o.datatype = 'uinteger';
		o.default = '921600';

		o = s.option(form.Value, 'custom', _('Connection string'),
			_('Any pymavlink string, e.g. udpin:0.0.0.0:14550 or tcp:10.221.11.1:5760.'));
		o.depends('mode', 'custom');
		o.rmempty = false;

		o = s.option(form.Value, 'interval', _('Poll interval (seconds)'));
		o.datatype = 'ufloat';
		o.default = '2.0';

		o = s.option(form.Flag, 'gps_input', _('Send as GPS_INPUT'),
			_('Appear as a MAVLink GPS instance (the FC needs GPS_TYPE2=14) instead of sending MAV_CMD_EXTERNAL_POSITION_ESTIMATE.'));

		o = s.option(form.Flag, 'autostart', _('Start at boot'),
			_('Off by default: the bridge is otherwise started from this page or with starlink-start after each boot.'));

		function showError(err) {
			ui.addNotification(null, E('p', (err && err.message) ? err.message : String(err)), 'error');
		}

		function collect() {
			return m.save(null, true).then(function() {
				const d = (m.data && m.data.data && m.data.data.settings) || {};
				return SETTINGS_PARAMS.map(function(k) {
					return (d[k] == null) ? '' : String(d[k]);
				});
			});
		}

		function handleSave() {
			return collect()
				.then(function(p) { return callSetSettings.apply(null, p); })
				.then(function(res) {
					if (notify(res) && statusState.running)
						ui.addNotification(null, E('p', _('The bridge is still running with its previous settings. Press Start / Restart to apply them.')), 'warning');
					return refresh();
				})
				.catch(showError);
		}

		function handleStart() {
			return collect()
				.then(function(p) { return callStart.apply(null, p); })
				.then(function(res) { notify(res); return refresh(); })
				.catch(showError);
		}

		function handleStop() {
			return callStop()
				.then(function(res) { notify(res); return refresh(); })
				.catch(showError);
		}

		const actions = E('div', { 'class': 'cbi-page-actions' }, [
			E('button', { 'class': 'cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, handleSave) }, _('Save')),
			' ',
			E('button', { 'class': 'cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, handleStart) }, _('Save & Start / Restart')),
			' ',
			E('button', { 'class': 'cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, handleStop) }, _('Stop'))
		]);

		/* ---- flight-controller GPS toggle ------------------------------ */
		const gpsIp = new ui.Textfield((settings.mode == 'udp' && settings.fc_ip) ? settings.fc_ip : fcDefault,
			{ placeholder: fcDefault, datatype: 'ip4addr' });
		const gpsPort = new ui.Textfield(settings.fc_port || '14550', { placeholder: '14550', datatype: 'port' });

		function sendAux(action) {
			if (!gpsIp.isValid() || !gpsPort.isValid()) {
				notify({ ok: false, message: _('Enter a valid flight controller IP and UDP port.') });
				return Promise.resolve();
			}
			ui.showModal(_('Contacting the flight controller'), [
				E('p', { 'class': 'spinning' }, _('Sending the %s GPS command...').format(action))
			]);
			return callGpsAux(gpsIp.getValue(), gpsPort.getValue(), action).then(function(res) {
				ui.hideModal();
				notify(res);
			}, function(err) {
				ui.hideModal();
				showError(err);
			});
		}

		const gpsSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Flight controller GPS')),
			E('div', { 'class': 'cbi-section-descr' },
				_('Sends the ArduPilot aux function 65 (GPS Disable) over MAVLink UDP: Disable switches it HIGH, Enable switches it LOW. Acts immediately; it is not part of the saved settings.')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Flight controller IP')),
				E('div', { 'class': 'cbi-value-field' }, gpsIp.render())
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('UDP port')),
				E('div', { 'class': 'cbi-value-field' }, gpsPort.render())
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', { 'class': 'cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, function() { return sendAux('disable'); }) }, _('Disable GPS')),
				' ',
				E('button', { 'class': 'cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, function() { return sendAux('enable'); }) }, _('Enable GPS'))
			])
		]);

		/* ---- assemble -------------------------------------------------- */
		const depsBox = E('div');

		return m.render().then(function(formNode) {
			const node = E('div', { 'class': 'cbi-map' }, [
				E('h2', _('Starlink PNT')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Starlink-to-MAVLink position bridge: polls the dish for its location and feeds it to the flight controller as an external position estimate.')),
				depsBox,
				statusSection,
				formNode,
				actions,
				gpsSection
			]);

			updateStatus(status);
			poll.add(refresh, 5);

			/* Dependency check is slow (imports grpc), so run it after render. */
			L.resolveDefault(callCheckDeps(), null).then(function(deps) {
				if (deps && deps.ok === false)
					dom.content(depsBox, E('div', { 'class': 'alert-message warning' },
						_('The bridge\'s Python dependencies are not installed yet. The first-boot installer may still be running; otherwise run starlink-install-deps over SSH. Starting the bridge from this page also installs them.')));
			});

			return node;
		});
	}
});
