"""Build small OOXML packages (standard library only) for the document
helper's tests: just enough parts for image extraction, plus a few hostile
ones (a zip-slip member and target, an external link).

    python3 make_ooxml.py <out_dir>
"""

import os
import struct
import sys
import zipfile
import zlib

R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
IMG = R + "/image"
SLIDE = R + "/slide"
SHEET = R + "/worksheet"
DRAWING = R + "/drawing"
PKG = "http://schemas.openxmlformats.org/package/2006/relationships"


def png(w, h, color):
    raw = b"".join(b"\x00" + bytes(color) * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def rels(items):
    out = ['<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="%s">' % PKG]
    for rid, typ, target, external in items:
        out.append(
            '<Relationship Id="%s" Type="%s" Target="%s"%s/>' % (rid, typ, target, ' TargetMode="External"' if external else "")
        )
    out.append("</Relationships>")
    return "".join(out)


def ppic(rid, descr):
    return (
        '<p:pic><p:nvPicPr><p:cNvPr id="4" name="Picture 3" descr="%s"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>'
        '<p:blipFill><a:blip r:embed="%s"/></p:blipFill></p:pic>' % (descr, rid)
    )


def slide(pics):
    return (
        '<?xml version="1.0" encoding="UTF-8"?><p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:r="%s" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>%s'
        "</p:spTree></p:cSld></p:sld>" % (R, "".join(pics))
    )


def pptx(path):
    red, blue = png(4, 3, (255, 0, 0)), png(2, 2, (0, 0, 255))
    with zipfile.ZipFile(path, "w") as z:
        # slide2.xml is shown FIRST (presentation order, not file names)
        z.writestr(
            "ppt/presentation.xml",
            '<?xml version="1.0"?><p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
            'xmlns:r="%s"><p:sldIdLst><p:sldId id="256" r:id="rId3"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst>'
            "</p:presentation>" % R,
        )
        z.writestr(
            "ppt/_rels/presentation.xml.rels",
            rels([("rId2", SLIDE, "slides/slide1.xml", False), ("rId3", SLIDE, "slides/slide2.xml", False)]),
        )
        z.writestr("ppt/slides/slide2.xml", slide([ppic("rId1", "Shown first")]))
        z.writestr("ppt/slides/_rels/slide2.xml.rels", rels([("rId1", IMG, "../media/image1.png", False)]))
        z.writestr(
            "ppt/slides/slide1.xml",
            slide([ppic("rId1", "Blue square"), ppic("rId2", "escape"), ppic("rId3", "remote"), ppic("rId4", "again")]),
        )
        z.writestr(
            "ppt/slides/_rels/slide1.xml.rels",
            rels(
                [
                    ("rId1", IMG, "../media/image2.png", False),
                    ("rId2", IMG, "../../../evil.png", False),
                    ("rId3", IMG, "http://example.invalid/x.png", True),
                    ("rId4", IMG, "../media/image1.png", False),
                ]
            ),
        )
        z.writestr("ppt/media/image1.png", red)
        z.writestr("ppt/media/image2.png", blue)
        z.writestr("../evil.png", red)  # a zip-slip member: never written anywhere


def docx(path):
    def drawing(rid, descr):
        return (
            '<w:r><w:drawing><wp:inline><wp:docPr id="1" name="Picture 1" descr="%s"/><a:graphic><a:graphicData>'
            '<pic:pic><pic:blipFill><a:blip r:embed="%s"/></pic:blipFill></pic:pic></a:graphicData></a:graphic>'
            "</wp:inline></w:drawing></w:r>" % (descr, rid)
        )

    doc = (
        '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" xmlns:r="%s"><w:body>'
        "<w:p><w:r><w:t>Text</w:t></w:r></w:p><w:p>%s</w:p><w:p>%s</w:p></w:body></w:document>"
        % (R, drawing("rId8", "Logo"), drawing("rId7", "Chart"))
    )
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("word/document.xml", doc)
        z.writestr(
            "word/_rels/document.xml.rels",
            rels([("rId7", IMG, "media/chart.jpeg", False), ("rId8", IMG, "media/logo.png", False)]),
        )
        z.writestr("word/media/logo.png", png(3, 3, (0, 255, 0)))
        z.writestr("word/media/chart.jpeg", b"\xff\xd8\xff\xe0" + b"\x00" * 40)


def xlsx(path):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(
            "xl/workbook.xml",
            '<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
            'xmlns:r="%s"><sheets><sheet name="Data" sheetId="1" r:id="rId1"/><sheet name="Charts" sheetId="2" r:id="rId2"/>'
            "</sheets></workbook>" % R,
        )
        z.writestr(
            "xl/_rels/workbook.xml.rels",
            rels([("rId1", SHEET, "worksheets/sheet1.xml", False), ("rId2", SHEET, "worksheets/sheet2.xml", False)]),
        )
        z.writestr("xl/worksheets/sheet1.xml", "<worksheet/>")
        z.writestr("xl/worksheets/sheet2.xml", "<worksheet/>")
        z.writestr("xl/worksheets/_rels/sheet2.xml.rels", rels([("rId1", DRAWING, "../drawings/drawing1.xml", False)]))
        z.writestr(
            "xl/drawings/drawing1.xml",
            '<?xml version="1.0"?><xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" '
            'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="%s"><xdr:twoCellAnchor><xdr:pic>'
            '<xdr:nvPicPr><xdr:cNvPr id="2" name="Picture 1" descr="Sales chart"/></xdr:nvPicPr>'
            '<xdr:blipFill><a:blip r:embed="rId1"/></xdr:blipFill></xdr:pic></xdr:twoCellAnchor></xdr:wsDr>' % R,
        )
        z.writestr("xl/drawings/_rels/drawing1.xml.rels", rels([("rId1", IMG, "../media/image1.png", False)]))
        z.writestr("xl/media/image1.png", png(5, 2, (9, 9, 9)))


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    pptx(os.path.join(out, "deck.pptx"))
    docx(os.path.join(out, "report.docx"))
    xlsx(os.path.join(out, "book.xlsx"))
    with zipfile.ZipFile(os.path.join(out, "plain.docx"), "w") as z:
        z.writestr("word/document.xml", "<w:document xmlns:w='x'/>")
