#!/usr/bin/env python3
# A port of LuCI's po2lmo (modules/luci-base/src/po2lmo.c + lib/lmo.c sfh_hash, openwrt-24.10)
# so the stand can install a real translation catalog without the OpenWrt SDK host tools.
#   python3 -I stand/tests/po2lmo.py po/ru/vpnpool.po out.lmo
#   python3 -I stand/tests/po2lmo.py --hash 'text'     -> sfh hash (hex), as cbi.js sfh() prints it
# The format is LuCI's: values (each padded to 4 bytes), then the index sorted by key hash
# (key_id, val_id, offset, length as big-endian u32), then the index offset (u32).
# Like the C tool: a msgid line is taken raw (\" and \\ unescaped, other escapes kept as is),
# entries whose translation hashes equal to the msgid are skipped, the Plural-Forms header goes
# in with key 0. The SDK build (luci.mk) uses the real po2lmo; this port is for the stand only.
import struct
import sys


def sfh(data: bytes) -> int:
    n = len(data)
    if n == 0:
        return 0
    h = n & 0xFFFFFFFF
    rem = n & 3
    off = 0

    def g16(o):
        return data[o] | (data[o + 1] << 8)

    def s8(b):
        return b - 256 if b > 127 else b

    for _ in range(n >> 2):
        h = (h + g16(off)) & 0xFFFFFFFF
        tmp = ((g16(off + 2) << 11) ^ h) & 0xFFFFFFFF
        h = ((h << 16) ^ tmp) & 0xFFFFFFFF
        off += 4
        h = (h + (h >> 11)) & 0xFFFFFFFF
    if rem == 3:
        h = (h + g16(off)) & 0xFFFFFFFF
        h ^= (h << 16) & 0xFFFFFFFF
        h ^= (s8(data[off + 2]) << 18) & 0xFFFFFFFF
        h = (h + (h >> 11)) & 0xFFFFFFFF
    elif rem == 2:
        h = (h + g16(off)) & 0xFFFFFFFF
        h ^= (h << 11) & 0xFFFFFFFF
        h = (h + (h >> 17)) & 0xFFFFFFFF
    elif rem == 1:
        h = (h + s8(data[off])) & 0xFFFFFFFF
        h ^= (h << 10) & 0xFFFFFFFF
        h = (h + (h >> 1)) & 0xFFFFFFFF
    h ^= (h << 3) & 0xFFFFFFFF
    h = (h + (h >> 5)) & 0xFFFFFFFF
    h ^= (h << 4) & 0xFFFFFFFF
    h = (h + (h >> 17)) & 0xFFFFFFFF
    h ^= (h << 25) & 0xFFFFFFFF
    h = (h + (h >> 6)) & 0xFFFFFFFF
    return h


def extract(line: bytes):
    # po2lmo.c extract_string(): text between the first and the closing quote; \" and \\ lose
    # the backslash, any other escape stays verbatim (two bytes)
    if line.startswith(b'#'):
        return None
    q = line.find(b'"')
    if q < 0:
        return None
    out = bytearray()
    i = q + 1
    while i < len(line):
        c = line[i:i + 1]
        if c == b'\\' and i + 1 < len(line):
            d = line[i + 1:i + 2]
            if d in (b'"', b'\\'):
                out += d
            else:
                out += c + d
            i += 2
            continue
        if c == b'"':
            return bytes(out)
        out += c
        i += 1
    return bytes(out)


def convert(src: str, dst: str) -> int:
    entries = []   # (key_id, val_id, offset, length)
    values = bytearray()
    msg = {'ctxt': None, 'id': None, 'plural': None, 'val': {}, 'pn': -1}
    cur = [None]

    def pad(b):
        return b + b'\0' * ((4 - len(b) % 4) % 4)

    def emit():
        nonlocal values
        if msg['id'] is not None and msg['val'].get(0) is not None:
            for i in range(0, msg['pn'] + 1):
                v = msg['val'].get(i)
                if v is None:
                    continue
                if msg['ctxt'] is not None and msg['plural'] is not None:
                    key = msg['ctxt'] + b'\1' + msg['id'] + b'\2' + str(i).encode()
                elif msg['ctxt'] is not None:
                    key = msg['ctxt'] + b'\1' + msg['id']
                elif msg['plural'] is not None:
                    key = msg['id'] + b'\2' + str(i).encode()
                else:
                    key = msg['id']
                kid, vid = sfh(key), sfh(v)
                if kid != vid:
                    entries.append((kid, msg['pn'] + 1, len(values), len(v)))
                    values += pad(v)
        elif msg['val'].get(0) is not None:   # header: only Plural-Forms is kept
            for field in msg['val'][0].split(b'\\n'):
                if field.lower().startswith(b'plural-forms: '):
                    f = field[14:]
                    entries.append((0, 0, len(values), len(f)))
                    values += pad(f)
                    break
        msg.update({'ctxt': None, 'id': None, 'plural': None, 'val': {}, 'pn': -1})

    with open(src, 'rb') as fh:
        lines = fh.read().split(b'\n')
    for line in lines + [None]:
        eof = line is None
        line = b'' if eof else line.rstrip(b'\r')
        # like the C tool, a field stays NULL (None) until a non-empty piece of text is read:
        # `msgid ""` is the header, `msgstr ""` is untranslated (skipped)
        if line.startswith(b'msgctxt "'):
            if msg['id'] is not None or msg['val'].get(0) is not None:
                emit()
            msg['ctxt'] = None
            cur[0] = ('ctxt', None)
        elif eof or line.startswith(b'msgid "'):
            if msg['id'] is not None or msg['val'].get(0) is not None:
                emit()
            msg['id'] = None
            cur[0] = ('id', None)
        elif line.startswith(b'msgid_plural "'):
            msg['plural'] = None
            cur[0] = ('plural', None)
        elif line.startswith(b'msgstr "') or line.startswith(b'msgstr['):
            pn = int(line[7:line.index(b']')]) if line[6:7] == b'[' else 0
            if pn >= 10:
                sys.exit('Error: Too many plural forms')
            msg['pn'] = pn
            msg['val'][pn] = None
            cur[0] = ('val', pn)
        if eof:
            break
        if cur[0] is not None:
            t = extract(line)
            if t:
                k, i = cur[0]
                if k == 'val':
                    msg['val'][i] = (msg['val'].get(i) or b'') + t
                else:
                    msg[k] = (msg[k] or b'') + t
    entries.sort(key=lambda e: e[0])
    with open(dst, 'wb') as out:
        out.write(bytes(values))
        for e in entries:
            out.write(struct.pack('>IIII', *e))
        out.write(struct.pack('>I', len(values)))
    return len(entries)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--hash':
        print('%08x' % sfh(sys.argv[2].encode('utf-8')))
        sys.exit(0)
    if len(sys.argv) != 3:
        sys.exit('usage: po2lmo.py input.po output.lmo | --hash TEXT')
    n = convert(sys.argv[1], sys.argv[2])
    print('PO2LMO: entries=%d -> %s' % (n, sys.argv[2]))
    sys.exit(0 if n > 0 else 1)
