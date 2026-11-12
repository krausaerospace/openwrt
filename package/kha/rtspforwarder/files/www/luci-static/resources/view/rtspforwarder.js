'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require poll';
'require dom';

/*
 * RTSP Forwarder - LuCI page for the GStreamer UDP MPEG-TS -> RTSP forwarder.
 * Maintained in the buildroot repo at
 * package/kha/rtspforwarder/files/www/luci-static/resources/view/rtspforwarder.js.
 * Settings are plain uci (/etc/config/rtspforwarder) edited with the form
 * below; status and start/stop go through the rpcd ucode plugin
 * /usr/share/rpcd/ucode/rtspforwarder.uc (ubus object luci.rtspforwarder).
 */

const OBJ = 'luci.rtspforwarder';
const callStatus = rpc.declare({ object: OBJ, method: 'status' });
const callAction = rpc.declare({ object: OBJ, method: 'action', params: [ 'name' ] });

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
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	render: function(status) {
		/* ---- live status + controls ------------------------------------ */
		const cells = {
			state:     E('td', { 'class': 'td' }),
			url:       E('td', { 'class': 'td' }),
			command:   E('td', { 'class': 'td' }),
			autostart: E('td', { 'class': 'td' })
		};
		const logPre = E('pre', { 'style': 'max-height:18em;overflow:auto;font-size:90%;margin-top:.5em;white-space:pre-wrap' }, '');

		function update(st) {
			st = st || {};
			dom.content(cells.state, st.running
				? [ mark(true, _('Running')), (st.pid != null) ? ' (pid %d)'.format(st.pid) : '' ]
				: mark(false, _('Stopped')));
			dom.content(cells.url, st.url ? E('code', st.url) : E('em', _('not set - the forwarder will not start')));
			dom.content(cells.command, st.command
				? E('code', { 'style': 'word-break:break-all' }, st.command)
				: E('em', _('(only shown while running)')));
			dom.content(cells.autostart, st.autostart ? _('on') : _('off'));
			dom.content(logPre, st.log || _('(no log lines yet)'));
		}

		function refresh() {
			return L.resolveDefault(callStatus(), {}).then(update);
		}

		/* ui.createHandlerFn disables the button until the promise settles. */
		function act(name) {
			return function() {
				return L.resolveDefault(callAction(name), null).then(function(res) {
					const ok = !!(res && res.ok);
					ui.addNotification(null,
						E('p', (res && res.message) ? res.message : _('No response from the router')),
						ok ? 'info' : 'error');
				}).then(refresh);
			};
		}

		const statusSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Status')),
			E('table', { 'class': 'table' }, [
				row(_('Forwarder'), cells.state),
				row(_('RTSP endpoint (saved)'), cells.url),
				row(_('Running command'), cells.command),
				row(_('Start at boot'), cells.autostart)
			]),
			E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-positive', 'click': ui.createHandlerFn(this, act('start')) }, _('Start')), ' ',
				E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, act('stop')) }, _('Stop')), ' ',
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, act('restart')) }, _('Restart'))
			]),
			E('div', { 'class': 'cbi-value-description' },
				_('Start and Restart use the saved settings: click Save & Apply first after changing anything below. Applying new settings restarts a running forwarder; it never starts a stopped one.')),
			E('div', { 'class': 'cbi-value-description', 'style': 'margin-top:1em' }, _('Forwarder log (last lines):')),
			logPre
		]);

		update(status);
		poll.add(refresh, 5);

		/* ---- settings (uci rtspforwarder.main) ------------------------- */
		/* No map title: the heading is placed above the status block below. */
		const m = new form.Map('rtspforwarder');

		const s = m.section(form.NamedSection, 'main', 'rtspforwarder', _('Settings'));
		s.addremove = false;
		s.tab('general', _('General'));
		s.tab('advanced', _('Advanced'));

		let o;

		/* General */
		o = s.taboption('general', form.Value, 'url', _('RTSP endpoint URL'),
			_('Where the stream is published, e.g. <code>rtsp://server:554/path</code>. The forwarder does not start while this is empty.'));
		o.placeholder = 'rtsp://host:554/path';
		o.validate = function(section_id, value) {
			if (value == null || value === '')
				return true;
			return /^rtsps?:\/\/[^\s"\\]+$/.test(value) ? true : _('Must start with rtsp:// or rtsps:// and contain no spaces, quotes or backslashes');
		};

		o = s.taboption('general', form.Flag, 'autostart', _('Start at boot'),
			_('Start the forwarder when the router boots (only if an endpoint URL is set).'));
		o.default = '1';
		o.rmempty = false;

		/* Advanced */
		o = s.taboption('advanced', form.Value, 'listen_ip', _('Listen IP'),
			_('Address the UDP input is received on. <code>127.0.0.1</code> accepts only streams sent from this router; <code>0.0.0.0</code> accepts them on every interface; a multicast group address (e.g. <code>239.0.0.1</code>) joins that group.'));
		o.datatype = 'ip4addr("nomask")';
		o.default = '0.0.0.0';
		o.placeholder = '0.0.0.0';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'listen_port', _('Listen UDP port'));
		o.datatype = 'port';
		o.default = '15004';
		o.placeholder = '15004';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'buffer_size', _('Receive buffer (bytes)'),
			_('Kernel socket buffer for the UDP input (udpsrc <code>buffer-size</code>). 4194304 is 4 MiB.'));
		o.datatype = 'and(uinteger,min(65536))';
		o.default = '4194304';
		o.placeholder = '4194304';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'queue_time', _('Queue (ms)'),
			_('How much stream is held in memory while the RTSP connection catches up after a short network stall (queue <code>max-size-time</code>).'));
		o.datatype = 'and(uinteger,min(100))';
		o.default = '2000';
		o.placeholder = '2000';
		o.rmempty = false;

		o = s.taboption('advanced', form.ListValue, 'rtsp_transport', _('RTSP transport'),
			_('How the RTP stream is carried to the server (rtspclientsink <code>protocols</code>). TCP gets through NAT and firewalls more reliably.'));
		o.value('tcp', 'TCP');
		o.value('udp', 'UDP');
		o.default = 'tcp';

		o = s.taboption('advanced', form.Value, 'respawn_delay', _('Restart delay (s)'),
			_('Seconds to wait before restarting the pipeline after it exits, for example when the RTSP server drops the connection or refuses the stream.'));
		o.datatype = 'uinteger';
		o.default = '5';
		o.placeholder = '5';
		o.rmempty = false;

		o = s.taboption('advanced', form.ListValue, 'loglevel', _('Log level'),
			_('GStreamer messages sent to the system log (<code>GST_DEBUG</code>). Info and Debug are very chatty; use them only while troubleshooting.'));
		o.value('error', _('Errors'));
		o.value('warning', _('Warnings'));
		o.value('info', _('Info'));
		o.value('debug', _('Debug'));
		o.default = 'warning';

		return m.render().then(function(formNode) {
			return E([], [
				E('h2', _('RTSP Forwarder')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Pushes the MPEG-TS stream arriving on a UDP port to an RTSP server with GStreamer. The whole transport stream, including video and KLV metadata, is sent untouched as one RTP stream (MP2T). Settings are stored in /etc/config/rtspforwarder and survive reboots and sysupgrades.')),
				statusSection,
				formNode
			]);
		});
	}
});
