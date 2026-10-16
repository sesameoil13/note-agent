"""Small independent PDF fixtures: known Unicode text and explicit coordinates.

No production extractor is used to construct expected results. Run with Python 3.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / 'test' / 'fixtures'
ROOT.mkdir(parents=True, exist_ok=True)

def pdf(name, pages, drawings=None):
    chars = ''.join(dict.fromkeys(''.join(t for page in pages for _, _, t in page)))
    codes = {char: i + 1 for i, char in enumerate(chars)}
    cmap = ('/CIDInit /ProcSet findresource begin 12 dict begin begincmap\n'
            '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n'
            '/CMapName /Fixture def /CMapType 2 def\n1 begincodespacerange <0000> <FFFF> endcodespacerange\n'
            f'{len(chars)} beginbfchar\n' + '\n'.join(f'<{codes[c]:04X}> <{c.encode("utf-16-be").hex()}>' for c in chars) +
            '\nendbfchar endcmap CMapName currentdict /CMap defineresource pop end end')
    def stream(data):
        data = data.encode('ascii')
        return f'<< /Length {len(data)} >>\nstream\n'.encode() + data + b'\nendstream'
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'',
               b'<< /Type /Font /Subtype /Type0 /BaseFont /Fixture /Encoding /Identity-H /DescendantFonts [4 0 R] /ToUnicode 5 0 R >>',
               b'<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Fixture /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 500 >>', stream(cmap)]
    kids=[]
    for page_index, page in enumerate(pages):
        page_id=len(objects)+1
        kids.append(f'{page_id} 0 R')
        content='\n'.join(f'BT /F1 12 Tf {x} {y} Td <'+''.join(f'{codes[c]:04X}' for c in text)+'> Tj ET' for x,y,text in page)
        if drawings:
            content += '\n' + drawings[page_index]
        objects.extend([f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {page_id+1} 0 R >>'.encode(),stream(content)])
    objects[1]=f'<< /Type /Pages /Count {len(kids)} /Kids [{" ".join(kids)}] >>'.encode()
    output=bytearray(b'%PDF-1.7\n')
    offsets=[0]
    for i,obj in enumerate(objects,1):
        offsets.append(len(output)); output.extend(f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n')
    xref=len(output)
    output.extend(f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode())
    output.extend(''.join(f'{n:010} 00000 n \n' for n in offsets[1:]).encode())
    output.extend(f'trailer << /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    (ROOT/name).write_bytes(output)

pdf('chinese.pdf', [[(40, 730, '中文资料：保留原文。 Latin 42')]])

grid='\n'.join([f'{x} 560 m {x} 680 l S' for x in [40,160,280,400]] + [f'40 {y} m 400 {y} l S' for y in [560,600,640,680]])
pdf('table.pdf', [[(40,730,'采购资料'),(50,660,'产品'),(170,660,'数量'),(290,660,'备注'),(50,620,'苹果'),(170,620,'2'),(290,620,'A|B'),(50,580,'茶叶'),(290,580,'第一行'),(290,568,'第二行'),(40,500,'表格后的原文。')]], [grid])
