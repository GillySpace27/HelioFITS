#!/usr/bin/env python3
"""Dump the full header cards of every HDU in a FITS file.

Pure Python standard library only -- no astropy, numpy, or cfitsio. Runs under
/usr/bin/python3. Bundled into HelioFITS.app/Contents/Resources and invoked
by the "View HDU header" Quick Action.

FITS layout: a file is a sequence of HDUs. Each HDU is a header made of one or
more 2880-byte blocks (36 cards x 80 chars) terminated by an 'END' card,
followed by an optional data segment of

    |BITPIX|/8 * GCOUNT * (PCOUNT + product(NAXIS1..NAXISn))

bytes rounded up to the next multiple of 2880. Verified card-for-card against
astropy (disable_image_compression=True) on AIA/HMI files.

    fitsdump.py FILE.fits            # plain text to stdout
    fitsdump.py --html FILE.fits     # styled, Cmd-F-searchable HTML to stdout
"""

import html
import os
import sys

BLOCK = 2880
CARD = 80
CARDS_PER_BLOCK = BLOCK // CARD  # 36


def parse_value(card):
    if card[8:10] != '= ':
        return None
    field = card[10:]
    in_str = False
    out = []
    i = 0
    while i < len(field):
        ch = field[i]
        if ch == "'":
            if in_str and i + 1 < len(field) and field[i + 1] == "'":
                out.append("''")
                i += 2
                continue
            in_str = not in_str
            out.append(ch)
        elif ch == '/' and not in_str:
            break
        else:
            out.append(ch)
        i += 1
    return ''.join(out).strip()


def parse_int(card):
    v = parse_value(card)
    if v is None:
        return None
    try:
        return int(v)
    except ValueError:
        return None


def read_header(f):
    cards = []
    first = True
    while True:
        block = f.read(BLOCK)
        if not block:
            if first:
                return None, False
            return cards, False
        first = False
        if len(block) < BLOCK:
            block = block + b' ' * (BLOCK - len(block))
        try:
            text = block.decode('ascii')
        except UnicodeDecodeError:
            text = block.decode('latin-1')
        for i in range(CARDS_PER_BLOCK):
            card = text[i * CARD:(i + 1) * CARD]
            if card[:8] == 'END     ' or card.rstrip() == 'END':
                return cards, True
            cards.append(card)


def header_dict(cards):
    d = {}
    for card in cards:
        kw = card[:8].rstrip()
        if kw in ('BITPIX', 'NAXIS', 'PCOUNT', 'GCOUNT') or (
            kw.startswith('NAXIS') and kw[5:].isdigit()
        ):
            val = parse_int(card)
            if val is not None:
                d[kw] = val
    return d


def data_size(d):
    naxis = d.get('NAXIS', 0)
    if naxis == 0:
        return 0
    bitpix = d.get('BITPIX', 8)
    gcount = d.get('GCOUNT', 1)
    pcount = d.get('PCOUNT', 0)
    nelem = 1
    for i in range(1, naxis + 1):
        nelem *= d.get('NAXIS%d' % i, 0)
    nbytes = abs(bitpix) // 8 * gcount * (pcount + nelem)
    if nbytes % BLOCK:
        nbytes += BLOCK - (nbytes % BLOCK)
    return nbytes


def extname(cards):
    for card in cards:
        if card[:8].rstrip() == 'EXTNAME':
            v = parse_value(card)
            if v:
                return v.strip().strip("'").strip()
    return ''


def read_all_hdus(path):
    """Return a list of (index, extname, cards) for every HDU."""
    hdus = []
    n = 0
    with open(path, 'rb') as f:
        while True:
            cards, found_end = read_header(f)
            if cards is None:
                break
            hdus.append((n, extname(cards), cards))
            if not found_end:
                break
            skip = data_size(header_dict(cards))
            if skip:
                f.seek(skip, 1)
            n += 1
    return hdus


def emit_text(path, out):
    for n, name, cards in read_all_hdus(path):
        title = 'HDU %d' % n + (' [%s]' % name if name else '')
        out.write('=' * 70 + '\n%s\n' % title + '=' * 70 + '\n')
        for card in cards:
            out.write(card.rstrip() + '\n')
        out.write('\n')


def emit_html(path, out):
    name = os.path.basename(path)
    hdus = read_all_hdus(path)
    esc = html.escape
    out.write('<!doctype html><html><head><meta charset="utf-8">')
    out.write('<title>%s — FITS header</title><style>' % esc(name))
    out.write("""
    body{background:#0d0d0d;color:#9fe3b0;font:13px/1.5 ui-monospace,Menlo,monospace;margin:0}
    header{position:sticky;top:0;background:#0d0d0d;border-bottom:1px solid #2a2a2a;
           padding:12px 20px;display:flex;gap:14px;align-items:baseline;flex-wrap:wrap}
    h1{color:#e8dcb8;font-size:15px;margin:0;font-weight:600}
    nav a{color:#8ab;text-decoration:none;font-size:12px}
    nav a:hover{color:#cde}
    section{padding:0 20px}
    h2{color:#e8dcb8;font-size:13px;border-top:1px solid #2a2a2a;margin:18px 0 6px;
       padding-top:14px;scroll-margin-top:56px}
    pre{white-space:pre-wrap;word-break:break-word;margin:0 0 10px}
    """)
    out.write('</style></head><body><header><h1>%s</h1><nav>' % esc(name))
    for n, ename, _ in hdus:
        lbl = 'HDU %d%s' % (n, (' ' + ename) if ename else '')
        out.write('<a href="#hdu%d">%s</a>&ensp;' % (n, esc(lbl)))
    out.write('</nav></header>')
    for n, ename, cards in hdus:
        title = 'HDU %d' % n + (' — %s' % ename if ename else '')
        out.write('<section><h2 id="hdu%d">%s <span style="color:#777">(%d cards)</span></h2><pre>'
                  % (n, esc(title), len(cards)))
        out.write(esc('\n'.join(c.rstrip() for c in cards)))
        out.write('</pre></section>')
    out.write('</body></html>')


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('-')]
    as_html = '--html' in argv
    if not args:
        sys.stderr.write('usage: %s [--html] FILE.fits ...\n' % argv[0])
        return 2
    for path in args:
        (emit_html if as_html else emit_text)(path, sys.stdout)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
