#!/usr/bin/env ucode
'use strict';

// rpcd ucode plugin behind the LuCI "VPN > ZeroTier" page
// (www/luci-static/resources/view/zerotier.js). Maintained in the buildroot
// repo at package/kha/zerotier-luci/files/usr/share/rpcd/ucode/zerotier.uc.
//
// Settings (/etc/config/zerotier) are edited by the page directly through
// uci; the zerotier init script reloads itself on a uci change. This plugin
// only reports live state from zerotier-cli and starts / stops the procd
// service. Nothing user-supplied reaches a shell.

import { cursor } from 'uci';
import { connect } from 'ubus';
import { popen, readfile } from 'fs';

const NAME = 'zerotier';
const CLI = '/usr/bin/zerotier-cli';
const LOG_LINES = 30;

function run(cmd) {
	const p = popen(cmd + ' 2>&1', 'r');
	if (!p)
		return { rc: -1, out: 'cannot run ' + cmd };
	const out = p.read('all') ?? '';
	const rc = p.close();
	return { rc: rc, out: trim(out) };
}

// zerotier-cli -j <verb>, parsed; null when the daemon is not answering.
function cli_json(verb) {
	const p = popen(CLI + ' -j ' + verb + ' 2>/dev/null', 'r');
	if (!p)
		return null;
	const out = p.read('all') ?? '';
	p.close();
	let v = null;
	try { v = json(out); } catch (e) { v = null; }
	return v;
}

function instance() {
	const ubus = connect();
	const res = ubus ? ubus.call('service', 'list', { name: NAME }) : null;
	const inst = res?.[NAME]?.instances;
	if (inst)
		for (let name, i in inst)
			return i;
	return null;
}

function enabled() {
	return (cursor().get(NAME, 'global', 'enabled') ?? '0') == '1';
}

// IFF_UP from /sys/class/net/<dev>/flags. ZeroTier taps that are left down
// silently drop traffic (see /root/status.sh).
function link_up(dev) {
	if (!dev || !match(dev, /^[A-Za-z0-9_.-]+$/))
		return null;
	const f = readfile('/sys/class/net/' + dev + '/flags');
	return f ? ((hex(trim(f)) & 1) == 1) : null;
}

const methods = {
	status: {
		call: function() {
			const i = instance();
			const running = !!i?.running;
			const res = {
				enabled: enabled(),
				running: running,
				pid: i?.pid ?? null,
				online: false,
				address: null,
				version: null,
				port: null,
				tcp_fallback: false,
				networks: [],
				peers: [],
				log: '',
			};

			if (running) {
				const info = cli_json('info');
				if (type(info) == 'object') {
					res.address = info.address;
					res.online = !!info.online;
					res.version = info.version;
					res.port = info.config?.settings?.primaryPort;
					res.tcp_fallback = !!info.tcpFallbackActive;
				}

				const nets = cli_json('listnetworks');
				if (type(nets) == 'array')
					for (let n in nets)
						push(res.networks, {
							id: n.nwid ?? n.id,
							name: n.name,
							status: n.status,
							type: n.type,
							device: n.portDeviceName,
							link_up: link_up(n.portDeviceName),
							addresses: n.assignedAddresses ?? [],
							mac: n.mac,
						});

				const peers = cli_json('peers');
				if (type(peers) == 'array')
					for (let p in peers) {
						let path = null;
						for (let pa in (p.paths ?? []))
							if (pa.active && !pa.expired && (path == null || pa.preferred))
								path = pa.address;
						push(res.peers, {
							address: p.address,
							role: p.role,
							latency: p.latency,
							version: p.version,
							path: path,
						});
					}
			}

			res.log = run("logread | grep -E '(^|[^a-z])zerotier(-one)?(\\[|:)' | tail -n " + LOG_LINES).out;
			return res;
		}
	},

	action: {
		args: { name: '' },
		call: function(req) {
			const name = req.args?.name;
			if (!(name in [ 'start', 'stop', 'restart' ]))
				return { ok: false, message: 'action must be start, stop or restart' };
			if (name != 'stop' && !enabled())
				return { ok: false, message: 'ZeroTier is disabled: tick "Enable" and click Save & Apply first.' };
			const r = run('/etc/init.d/' + NAME + ' ' + name);
			if (r.rc != 0)
				return { ok: false, message: r.out || (name + ' failed') };
			return { ok: true, message: 'ZeroTier ' + (name == 'stop' ? 'stopped' : name + 'ed') };
		}
	},
};

return { 'luci.zerotier': methods };
