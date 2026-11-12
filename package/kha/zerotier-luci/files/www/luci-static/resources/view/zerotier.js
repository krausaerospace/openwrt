'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require poll';
'require dom';

/*
 * ZeroTier - LuCI page (VPN > ZeroTier).
 * Maintained in the buildroot repo at
 * package/kha/zerotier-luci/files/www/luci-static/resources/view/zerotier.js.
 * Settings are plain uci (/etc/config/zerotier) edited with the form below;
 * the zerotier init script reloads itself when that config changes. Live
 * state and start/stop go through the rpcd ucode plugin
 * /usr/share/rpcd/ucode/zerotier.uc (ubus object luci.zerotier).
 */

const OBJ = 'luci.zerotier';
const callStatus = rpc.declare({ object: OBJ, method: 'status' });
const callAction = rpc.declare({ object: OBJ, method: 'action', params: [ 'name' ] });

/* The public "Earth" network. ZeroTier interfaces sit in the LAN zone on this
 * image, so joining it would hand every Earth member full LAN access. */
const EARTH = '8056c2e21c000001';

const NET_STATUS = {
	'OK':                       [ true,  _('Connected') ],
	'REQUESTING_CONFIGURATION': [ null,  _('Requesting configuration') ],
	'ACCESS_DENIED':            [ false, _('Access denied - authorize this node on the network controller') ],
	'NOT_FOUND':                [ false, _('Network not found') ],
	'PORT_ERROR':               [ false, _('Port error (could not create the interface)') ],
	'CLIENT_TOO_OLD':           [ false, _('Client too old for this network') ],
	'AUTHENTICATION_REQUIRED':  [ false, _('Authentication required (SSO)') ]
};

function mark(ok, text) {
	const color = (ok === true) ? '#2a8a4a' : (ok === false) ? '#c0392b' : '#b7791f';
	return E('strong', { 'style': 'color:' + color }, text);
}

function row(label, cell) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, label),
		cell
	]);
}

function table(headers, rows, empty) {
	const t = E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' },
			headers.map(function(h) { return E('th', { 'class': 'th' }, h); }))
	]);
	if (!rows.length)
		t.appendChild(E('tr', { 'class': 'tr placeholder' },
			E('td', { 'class': 'td', 'colspan': headers.length }, E('em', empty))));
	rows.forEach(function(r) {
		t.appendChild(E('tr', { 'class': 'tr' },
			r.map(function(c) { return E('td', { 'class': 'td' }, c); })));
	});
	return t;
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	render: function(status) {
		/* ---- live status + controls ------------------------------------ */
		const cells = {
			service: E('td', { 'class': 'td' }),
			node:    E('td', { 'class': 'td' }),
			online:  E('td', { 'class': 'td' }),
			version: E('td', { 'class': 'td' })
		};
		const netBox = E('div');
		const peerBox = E('div');
		const logPre = E('pre', { 'style': 'max-height:14em;overflow:auto;font-size:90%;margin-top:.5em;white-space:pre-wrap' }, '');

		function update(st) {
			st = st || {};

			if (st.running)
				dom.content(cells.service, [ mark(true, _('Running')), (st.pid != null) ? ' (pid %d)'.format(st.pid) : '' ]);
			else if (st.enabled)
				dom.content(cells.service, mark(false, _('Stopped')));
			else
				dom.content(cells.service, [ mark(false, _('Disabled')), ' ', E('em', _('- tick "Enable" below and click Save & Apply')) ]);

			dom.content(cells.node, st.address
				? [ E('code', { 'style': 'font-size:110%' }, st.address), ' ',
				    E('em', _('(authorize this ID on the network controller, e.g. ZeroTier Central)')) ]
				: E('em', _('(only shown while running)')));

			if (!st.running)
				dom.content(cells.online, '-');
			else if (st.online)
				dom.content(cells.online, [ mark(true, _('Online')), st.tcp_fallback ? ' ' + _('(TCP relay fallback - UDP is blocked)') : '' ]);
			else
				dom.content(cells.online, [ mark(false, _('Offline')), ' ', E('em', _('- cannot reach the ZeroTier roots; check WAN and that UDP 9993 out is allowed')) ]);

			dom.content(cells.version, st.version
				? '%s%s'.format(st.version, (st.port != null) ? ', ' + _('UDP port %d').format(st.port) : '')
				: '-');

			const nets = (st.networks || []).map(function(n) {
				const s = NET_STATUS[n.status] || [ null, n.status || '?' ];
				let dev = '-';
				if (n.device)
					dev = [ E('code', n.device), ' ',
						(n.link_up === false) ? mark(false, _('DOWN')) : (n.link_up === true) ? mark(true, _('UP')) : '' ];
				return [
					E('code', n.id || '?'),
					n.name || E('em', '-'),
					mark(s[0], s[1]),
					dev,
					(n.addresses && n.addresses.length) ? n.addresses.join(', ') : E('em', _('none')),
					n.type || '-'
				];
			});
			dom.content(netBox, table(
				[ _('Network ID'), _('Name'), _('Status'), _('Interface'), _('Assigned addresses'), _('Type') ],
				nets,
				st.running ? _('Not joined to any network') : _('ZeroTier is not running')));

			const peers = (st.peers || []).slice().sort(function(a, b) {
				/* members (LEAF) first, then roots / moons */
				return ((a.role == 'LEAF') ? 0 : 1) - ((b.role == 'LEAF') ? 0 : 1) ||
					String(a.address).localeCompare(String(b.address));
			}).map(function(p) {
				return [
					E('code', p.address || '?'),
					p.role || '-',
					p.path ? p.path : E('em', _('relayed')),
					(p.latency != null && p.latency >= 0) ? '%d ms'.format(p.latency) : '-',
					p.version || '-'
				];
			});
			dom.content(peerBox, table(
				[ _('Peer'), _('Role'), _('Direct path'), _('Latency'), _('Version') ],
				peers,
				st.running ? _('No peers yet') : _('ZeroTier is not running')));

			dom.content(logPre, st.log || _('(no log lines)'));
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
				row(_('Service'), cells.service),
				row(_('Node ID'), cells.node),
				row(_('Connection'), cells.online),
				row(_('Version'), cells.version)
			]),
			E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-positive', 'click': ui.createHandlerFn(this, act('start')) }, _('Start')), ' ',
				E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, act('stop')) }, _('Stop')), ' ',
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, act('restart')) }, _('Restart'))
			]),
			E('div', { 'class': 'cbi-value-description' },
				_('Stop lasts until the next reboot or Save & Apply; to keep ZeroTier off, untick "Enable" below. Applying changed settings restarts ZeroTier, which briefly drops every ZeroTier connection - including this page if you reached it over ZeroTier.')),
			E('h4', { 'style': 'margin-top:1.5em' }, _('Joined networks')),
			netBox,
			E('h4', { 'style': 'margin-top:1.5em' }, _('Peers')),
			peerBox,
			E('div', { 'class': 'cbi-value-description', 'style': 'margin-top:1em' }, _('ZeroTier log (last lines):')),
			logPre
		]);

		update(status);
		poll.add(refresh, 5);

		/* ---- settings (uci zerotier) ----------------------------------- */
		const m = new form.Map('zerotier');
		let s, o;

		s = m.section(form.NamedSection, 'global', 'zerotier', _('Settings'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable'),
			_('Run ZeroTier, now and at every boot.'));
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('Listen port'),
			_('UDP port ZeroTier listens on. Leave empty for the default (9993); 0 picks a random port.'));
		o.datatype = 'port';
		o.placeholder = '9993';

		s = m.section(form.GridSection, 'network', _('Networks'),
			_('Networks this router joins. The node must also be authorized on each network\'s controller before traffic flows. Removing a network here makes the router leave it.'));
		s.addremove = true;
		s.anonymous = true;
		s.nodescriptions = true;

		o = s.option(form.Value, 'id', _('Network ID'));
		o.rmempty = false;
		o.placeholder = '16 hex digits';
		o.validate = function(section_id, value) {
			if (value == null || value === '')
				return _('Enter the 16-digit network ID');
			if (!/^[0-9a-fA-F]{16}$/.test(value))
				return _('A network ID is 16 hexadecimal digits');
			if (value.toLowerCase() == EARTH)
				return _('This is the public "Earth" network. ZeroTier interfaces are in the LAN zone on this router, so every Earth member would get full LAN access - remove this entry.');
			return true;
		};
		o.write = function(section_id, value) {
			return form.Value.prototype.write.call(this, section_id, value.toLowerCase());
		};

		o = s.option(form.Flag, 'allow_managed', _('Managed IPs'),
			_('Accept the addresses and routes assigned by the network controller.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'allow_global', _('Global IPs'),
			_('Allow the controller to assign or route public (global) IP ranges.'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Flag, 'allow_default', _('Default route'),
			_('Allow the network to override this router\'s default route (send all traffic through ZeroTier).'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Flag, 'allow_dns', _('DNS'),
			_('Accept DNS settings pushed by the network controller.'));
		o.default = '0';
		o.rmempty = false;

		return m.render().then(function(formNode) {
			return E([], [
				E('h2', _('ZeroTier')),
				E('div', { 'class': 'cbi-map-descr' },
					_('ZeroTier virtual network. Its interfaces (<code>zt+</code>) are in the LAN firewall zone, so members of the joined networks get the same access as wired LAN hosts. Settings are stored in /etc/config/zerotier and survive reboots and sysupgrades.')),
				statusSection,
				formNode
			]);
		});
	}
});
