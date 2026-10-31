#!/usr/bin/env python3
"""Convert locally without printing source values, filenames or credentials."""
import argparse
import os
from pathlib import Path
import re
import sys


def read_config(path):
    sections = {}
    section = None
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('[') and line.endswith(']'):
            section = sections.setdefault(line[1:-1], {})
        elif section is not None and ' = ' in line:
            key, value = line.split(' = ', 1)
            if value == 'null':
                continue  # inherit the server default
            if value.startswith('"') and value.endswith('"'):
                value = re.sub(r'\\(["\\])', r'\1', value[1:-1])
            section[key] = value
    return sections


def quote(value):
    if any(ord(c) < 32 for c in str(value)):
        raise ValueError('control character')
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def record(values):
    return '{ ' + ' '.join(quote(k) + ' = ' + quote(v) + ';' for k, v in values.items()) + ' }'


def convert(source, target):
    os.umask(0o077)
    sections = read_config(source / 'irc.conf') if (source / 'irc.conf').exists() else {}
    defaults = sections.get('server_default', {})
    networks, servers, channels = {}, [], []
    grouped = {}
    for key, value in sections.get('server', {}).items():
        name, sep, option = key.rpartition('.')
        if sep:
            grouped.setdefault(name, {})[option] = value
    review = False
    for name, overrides in grouped.items():
        options = dict(defaults, **overrides)
        unresolved = any('${' in value for value in options.values())
        # Never open sec.conf, evaluate expressions, or execute connect commands.
        options = {k: v for k, v in options.items() if '${' not in v}
        manual = unresolved or bool(options.get('command')) or bool(options.get('proxy'))
        net = {'type': 'IRC'}
        for old, new in [('username', 'user'), ('realname', 'realname'), ('usermode', 'usermode')]:
            if options.get(old):
                net[new] = options[old]
        nicks = options.get('nicks', '').split(',')
        if nicks[0]:
            net['nick'] = nicks[0]
            if len(nicks) > 1:
                net['alternate_nick'] = nicks[1]
        mechanism = options.get('sasl_mechanism', 'plain').upper()
        if options.get('sasl_username') or options.get('sasl_password') or mechanism == 'EXTERNAL':
            if mechanism in ('PLAIN', 'EXTERNAL'):
                net['sasl_mechanism'] = mechanism
                for option in ('sasl_username', 'sasl_password'):
                    if options.get(option):
                        net[option] = options[option]
            else:
                manual = True
        networks[name] = net
        addresses = options.get('addresses', '').split(',')
        for index, address in enumerate(addresses):
            if not address:
                continue
            host, slash, port = address.rpartition('/')
            if not slash:
                host, port = address, ''
            tls = options.get('tls', options.get('ssl', 'off')) == 'on' or port.startswith('+')
            port = port.lstrip('+') or ('6697' if tls else '6667')
            if not port.isdigit() or not 0 < int(port) < 65536:
                raise ValueError('invalid port')
            server = {'address': host.strip('[]'), 'chatnet': name, 'port': port,
                      'use_tls': 'yes' if tls else 'no', 'tls_verify': 'yes'}
            if options.get('password'):
                server['password'] = options['password']
            # Avoid silently sending copied authentication over plaintext.
            if not tls and (server.get('password') or net.get('sasl_password')):
                manual = True
            server['autoconnect'] = 'yes' if index == 0 and not manual and options.get('autoconnect') == 'on' else 'no'
            servers.append(server)
        review |= manual
        autojoin, _, keys = options.get('autojoin', '').partition(' ')
        keys = keys.split(',') if keys else []
        for index, channel in enumerate(filter(None, autojoin.split(','))):
            entry = {'name': channel, 'chatnet': name, 'autojoin': 'yes'}
            if index < len(keys) and keys[index]:
                entry['password'] = keys[index]
            channels.append(entry)
    settings = {
        'core': {'nick': 'soju', 'user_name': 'soju', 'real_name': '',
                 'settings_autosave': 'yes', 'log_create_mode': '600', 'quit_message': ''},
        'irc/core': {'ctcp_version_reply': '', 'ctcp_userinfo_reply': '',
                     'max_ctcp_queue': '0', 'part_message': '',
                     'join_auto_chans_on_invite': 'no'},
        'irc/dcc': {'dcc_autoget': 'no', 'dcc_autoresume': 'no',
                    'dcc_autoaccept_lowports': 'no', 'dcc_autochat_masks': ''},
        'fe-text': {'scrollback_lines': '500'},
        'fe-common/core': {'autolog': 'yes', 'autolog_level': 'MSGS PUBLIC NOTICES ACTIONS',
                           'autolog_path': '~/irssi/logs/$tag/$0.log'},
    }
    text = 'servers = (\n' + ',\n'.join(record(s) for s in servers) + '\n);\n'
    text += 'chatnets = {\n' + '\n'.join(quote(k) + ' = ' + record(v) + ';' for k, v in networks.items()) + '\n};\n'
    text += 'channels = (\n' + ',\n'.join(record(c) for c in channels) + '\n);\n'
    text += 'settings = {\n' + '\n'.join(quote(k) + ' = ' + record(v) + ';' for k, v in settings.items()) + '\n};\n'
    text += 'ignores = ( { mask = "*"; level = "CTCPS DCC DCCMSGS"; } );\n'
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Exclusive creation prevents overwriting a configuration edited in Irssi.
    with target.open('x') as output:
        output.write(text)
    target.chmod(0o600)
    print('Irssi config created privately; source files unchanged.')
    if review:
        print('Manual review needed for unsupported expressions, connect commands, proxies, SASL, or plaintext authentication; affected autoconnect disabled.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('target', type=Path)
    args = parser.parse_args()
    try:
        convert(args.source, args.target)
    except Exception:
        # Config parsing exceptions must never echo source data or values.
        print('Conversion failed; no source data displayed. Check input format and ensure the target does not already exist.', file=sys.stderr)
        sys.exit(1)
