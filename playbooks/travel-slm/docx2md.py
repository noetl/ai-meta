#!/usr/bin/env python3
"""Minimal docx -> text/markdown converter using stdlib only.

Handles paragraphs, headings (via pStyle), lists, tables, and hyperlinks.
"""
import sys, zipfile, re
import xml.etree.ElementTree as ET

W = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'


def para_text(p):
    parts = []
    for node in p.iter():
        tag = node.tag
        if tag == W + 't':
            parts.append(node.text or '')
        elif tag == W + 'tab':
            parts.append('\t')
        elif tag == W + 'br':
            parts.append('\n')
    return ''.join(parts)


def para_style(p):
    ppr = p.find(W + 'pPr')
    if ppr is None:
        return None, None
    style = ppr.find(W + 'pStyle')
    sval = style.get(W + 'val') if style is not None else None
    numpr = ppr.find(W + 'numPr')
    ilvl = None
    if numpr is not None:
        lv = numpr.find(W + 'ilvl')
        ilvl = int(lv.get(W + 'val')) if lv is not None else 0
    return sval, ilvl


def render_table(tbl):
    rows = []
    for tr in tbl.findall(W + 'tr'):
        cells = []
        for tc in tr.findall(W + 'tc'):
            txt = ' '.join(
                para_text(p).strip() for p in tc.findall(W + 'p')
            ).strip()
            cells.append(txt.replace('|', '\\|').replace('\n', '<br>'))
        rows.append(cells)
    if not rows:
        return ''
    out = []
    ncol = max(len(r) for r in rows)
    for i, r in enumerate(rows):
        r = r + [''] * (ncol - len(r))
        out.append('| ' + ' | '.join(r) + ' |')
        if i == 0:
            out.append('|' + '---|' * ncol)
    return '\n'.join(out)


def convert(path):
    z = zipfile.ZipFile(path)
    xml = z.read('word/document.xml')
    root = ET.fromstring(xml)
    body = root.find(W + 'body')
    out = []
    for child in body:
        if child.tag == W + 'p':
            txt = para_text(child)
            style, ilvl = para_style(child)
            if not txt.strip():
                out.append('')
                continue
            if style and re.match(r'^Heading(\d)$', style or ''):
                lvl = int(re.match(r'^Heading(\d)$', style).group(1))
                out.append('#' * lvl + ' ' + txt.strip())
            elif style and style.lower().startswith('title'):
                out.append('# ' + txt.strip())
            elif ilvl is not None:
                out.append('  ' * ilvl + '- ' + txt.strip())
            else:
                out.append(txt)
        elif child.tag == W + 'tbl':
            out.append('')
            out.append(render_table(child))
            out.append('')
    return '\n'.join(out)


if __name__ == '__main__':
    for p in sys.argv[1:]:
        print(convert(p))
