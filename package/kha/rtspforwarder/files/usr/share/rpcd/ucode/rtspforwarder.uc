#!/usr/bin/env ucode
'use strict';

// rpcd ucode plugin behind the LuCI "RTSP Forwarder" page
// (www/luci-static/resources/view/rtspforwarder.js). Maintained in the
// buildroot repo at package/kha/rtspforwarder/files/usr/share/rpcd/ucode/rtspforwarder.uc.
//
// Settings are edited by the page directly through uci (rtspforwarder.main);
// this plugin only reports the service state and log and starts / stops the
// procd service. Nothing user-supplied reaches a shell.

import { cursor } from 'uci';
import { connect } from 'ubus';
import { popen } from 'fs';

const NAME = 'rtspforwarder';
const LOG_LINES = 40;

function run(cmd) {
	const p = popen(cmd + ' 2>&1', 'r');
	if (!p)
		return { rc: -1, out: 'cannot run ' + cmd };
	const out = p.read('all') ?? '';
	const rc = p.close();
	return { rc: rc, out: trim(out) };
}

function saved_url() {
	return trim(cursor().get(NAME, 'main', 'url') ?? '');
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

const methods = {
	status: {
		call: function() {
			const i = instance();
			const m = cursor().get_all(NAME, 'main') ?? {};
			const log = run("logread | grep -E '(^|[^a-z])" + NAME + "(\\[|:)' | tail -n " + LOG_LINES);
			return {
				running: !!i?.running,
				pid: i?.pid ?? null,
				command: (i?.running && type(i?.command) == 'array') ? join(' ', i.command) : '',
				url: trim(m.url ?? ''),
				autostart: (m.autostart ?? '1') == '1',
				log: log.out,
			};
		}
	},

	action: {
		args: { name: '' },
		call: function(req) {
			const name = req.args?.name;
			if (!(name in [ 'start', 'stop', 'restart' ]))
				return { ok: false, message: 'action must be start, stop or restart' };
			if (name != 'stop' && saved_url() == '')
				return { ok: false, message: 'Set the RTSP endpoint URL and click Save & Apply first.' };
			const r = run('/etc/init.d/' + NAME + ' ' + name);
			if (r.rc != 0)
				return { ok: false, message: r.out || (name + ' failed') };
			return { ok: true, message: 'Forwarder ' + (name == 'stop' ? 'stopped' : name + 'ed') };
		}
	},
};

return { 'luci.rtspforwarder': methods };
