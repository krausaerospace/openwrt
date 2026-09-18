#!/usr/bin/env ucode
'use strict';

// rpcd ucode plugin behind the LuCI "Starlink PNT" page
// (package/kha/starlinkpnt/files/www/luci-static/resources/view/starlinkpnt.js). Maintained in the
// buildroot repo at package/kha/starlinkpnt/files/usr/share/rpcd/ucode/starlinkpnt.uc.
//
// uci starlink_mavlink.main stays the single source of truth: the target is
// stored as the same pymavlink string starlink-start writes, so the page and
// the SSH helpers never disagree. Starting goes through bare starlink-start
// (reusing the saved target) so its dependency self-heal applies here too.
// Every value that reaches a shell command is validated against a strict
// character set first.

import { cursor } from 'uci';
import { connect } from 'ubus';
import { readfile, popen } from 'fs';

const CFG = 'starlink_mavlink';
const SEC = 'main';
const DISH = '192.168.100.1';
const DEFAULT_LOG_DIR = '/root/starlinkpnt/logs';
const LOG_LINES = 40;

const RE_IPV4 = /^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$/;
const RE_PORT = /^[0-9]{1,5}$/;
const RE_SERIAL = /^\/dev\/[A-Za-z0-9_-]+$/;
const RE_BAUD = /^[0-9]{3,7}$/;
const RE_CUSTOM = /^[A-Za-z0-9_.:\/,-]+$/;
const RE_INTERVAL = /^[0-9]+(\.[0-9]+)?$/;
const RE_PATH = /^[A-Za-z0-9_.\/-]+$/;

function str(v) {
	if (v == null)
		return '';
	return trim(type(v) == 'string' ? v : sprintf('%s', v));
}

function flag(v) {
	const s = str(v);
	return (s == '1' || s == 'true') ? '1' : '0';
}

function fail(msg) {
	return { ok: false, message: msg };
}

// Run a command built only from constants and validated values; capture
// combined output for the page.
function run(cmd) {
	const p = popen(cmd + ' 2>&1', 'r');
	if (!p)
		return { rc: -1, out: 'cannot run ' + cmd };
	const out = p.read('all') ?? '';
	const rc = p.close();
	return { rc: rc, out: trim(out) };
}

function read_main() {
	const uci = cursor();
	return uci.get_all(CFG, SEC) ?? {};
}

// Split the pymavlink connection string into the fields the page shows.
// Unset fields come back as null so the page can apply its defaults.
function parse_target(t) {
	t = str(t);
	const s = { mode: 'udp', fc_ip: null, fc_port: '14550', serial_dev: null, custom: null };
	if (t == '')
		return s;
	if (t == 'auto') {
		s.mode = 'auto';
		return s;
	}
	const m = match(t, /^udp(out)?:([0-9.]+):([0-9]+)$/);
	if (m) {
		s.fc_ip = m[2];
		s.fc_port = m[3];
		return s;
	}
	if (match(t, RE_SERIAL)) {
		s.mode = 'serial';
		s.serial_dev = t;
		return s;
	}
	s.mode = 'custom';
	s.custom = t;
	return s;
}

function compose_target(a) {
	switch (a.mode) {
	case 'udp':
		if (!match(a.fc_ip, RE_IPV4))
			return { err: 'Flight controller IP is not a valid IPv4 address' };
		if (!match(a.fc_port, RE_PORT) || int(a.fc_port) < 1 || int(a.fc_port) > 65535)
			return { err: 'UDP port must be 1-65535' };
		return { target: 'udpout:' + a.fc_ip + ':' + a.fc_port };
	case 'serial':
		if (!match(a.serial_dev, RE_SERIAL))
			return { err: 'Serial device must look like /dev/ttyXXX' };
		return { target: a.serial_dev };
	case 'auto':
		return { target: 'auto' };
	case 'custom':
		if (!match(a.custom, RE_CUSTOM))
			return { err: 'Connection string contains unsupported characters' };
		return { target: a.custom };
	}
	return { err: 'Unknown link mode' };
}

function save_settings(args) {
	const a = {
		mode: str(args.mode) || 'udp',
		fc_ip: str(args.fc_ip),
		fc_port: str(args.fc_port) || '14550',
		serial_dev: str(args.serial_dev),
		baud: str(args.baud),
		custom: str(args.custom),
		interval: str(args.interval) || '2.0',
		gps_input: flag(args.gps_input),
		autostart: flag(args.autostart),
	};
	const t = compose_target(a);
	if (t.err)
		return fail(t.err);
	if (!match(a.interval, RE_INTERVAL))
		return fail('Poll interval must be a number of seconds');
	if (a.baud != '' && !match(a.baud, RE_BAUD))
		return fail('Baud rate must be a number');

	const uci = cursor();
	if (!uci.get(CFG, SEC))
		uci.set(CFG, SEC, 'starlink_mavlink');
	uci.set(CFG, SEC, 'mavlink', t.target);
	uci.set(CFG, SEC, 'interval', a.interval);
	uci.set(CFG, SEC, 'gps_input', a.gps_input);
	uci.set(CFG, SEC, 'autostart', a.autostart);
	if (a.baud != '')
		uci.set(CFG, SEC, 'baud', a.baud);
	else
		uci.delete(CFG, SEC, 'baud');
	if (!uci.commit(CFG))
		return fail('uci commit failed: ' + (uci.error() ?? 'unknown error'));
	return { ok: true, message: 'Settings saved (target ' + t.target + ')', target: t.target };
}

function service_state() {
	const ubus = connect();
	const res = ubus ? ubus.call('service', 'list', { name: 'starlink_mavlink' }) : null;
	const inst = res?.starlink_mavlink?.instances;
	if (inst) {
		for (let name, i in inst)
			return { running: !!i.running, pid: i.pid ?? null };
	}
	return { running: false, pid: null };
}

const SETTINGS_ARGS = {
	mode: 'udp', fc_ip: '', fc_port: '', serial_dev: '', baud: '', custom: '',
	interval: '', gps_input: '', autostart: '',
};

const methods = {
	status: {
		call: function() {
			const m = read_main();
			const st = service_state();
			const log_dir = match(str(m.log_dir), RE_PATH) ? m.log_dir : DEFAULT_LOG_DIR;
			const last_fc = trim(readfile(log_dir + '/last_fc.txt') ?? '');
			const log = run('tail -n ' + LOG_LINES + ' ' + log_dir + '/starlink_mavlink.log');
			const dish_up = (system('ping -c 1 -W 1 ' + DISH + ' >/dev/null 2>&1', 2500) == 0);
			return {
				running: st.running,
				pid: st.pid,
				target: str(m.mavlink),
				autostart: (str(m.autostart) == '1'),
				dish: DISH,
				dish_reachable: dish_up,
				last_fc: last_fc,
				log: (log.rc == 0) ? log.out : '',
			};
		}
	},

	get_settings: {
		call: function() {
			const m = read_main();
			const s = parse_target(m.mavlink);
			s.baud = (str(m.baud) != '') ? str(m.baud) : null;
			s.interval = str(m.interval) || '2.0';
			s.gps_input = flag(m.gps_input);
			s.autostart = flag(m.autostart);
			return s;
		}
	},

	check_deps: {
		call: function() {
			const rc = system('/usr/bin/python3 -c "import grpc, grpc_reflection, google.protobuf, pymavlink" >/dev/null 2>&1', 20000);
			return { ok: (rc == 0) };
		}
	},

	set_settings: {
		args: SETTINGS_ARGS,
		call: function(req) {
			return save_settings(req.args ?? {});
		}
	},

	start: {
		args: SETTINGS_ARGS,
		call: function(req) {
			const saved = save_settings(req.args ?? {});
			if (!saved.ok)
				return saved;
			const r = run('/usr/sbin/starlink-start');
			return { ok: (r.rc == 0), message: r.out, target: saved.target };
		}
	},

	stop: {
		call: function() {
			const r = run('/usr/sbin/starlink-stop');
			return { ok: (r.rc == 0), message: r.out };
		}
	},

	gps_aux: {
		args: { fc_ip: '', fc_port: '', action: '' },
		call: function(req) {
			const ip = str(req.args?.fc_ip);
			const port = str(req.args?.fc_port) || '14550';
			const action = str(req.args?.action);
			if (!match(ip, RE_IPV4))
				return fail('Flight controller IP is not a valid IPv4 address');
			if (!match(port, RE_PORT) || int(port) < 1 || int(port) > 65535)
				return fail('UDP port must be 1-65535');
			if (action != 'enable' && action != 'disable')
				return fail('action must be enable or disable');
			const r = run('/usr/sbin/starlink-gps-aux ' + ip + ' ' + port + ' ' + action);
			return { ok: (r.rc == 0), message: r.out };
		}
	},
};

return { 'luci.starlinkpnt': methods };
