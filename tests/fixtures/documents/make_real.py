"""Build real documents for documents_integration_spec (run with the Python
that has MarkItDown: python-pptx and openpyxl come with its pptx / xlsx
extras; DOCX and PDF are written with the standard library).

    python make_real.py <out_dir>
"""

import io
import os
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_ooxml import png  # noqa: E402


def pdf(path):
    """Two pages of text; one image (raw RGB, Flate) drawn on both pages."""
    import zlib

    pages = ["Page one says hello", "Page two says goodbye"]
    pixels = zlib.compress(bytes((255, 0, 0)) * (4 * 3)).decode("latin-1")
    objs = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        None,
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Type /XObject /Subtype /Image /Width 4 /Height 3 /ColorSpace /DeviceRGB /BitsPerComponent 8 "
        "/Filter /FlateDecode /Length %d >>\nstream\n%s\nendstream" % (len(pixels), pixels),
    ]
    kids = []
    for text in pages:
        stream = "BT /F1 18 Tf 72 720 Td (%s) Tj ET q 40 0 0 30 72 600 cm /Im1 Do Q" % text
        objs.append("<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream))
        content = len(objs)
        objs.append(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents %d 0 R "
            "/Resources << /Font << /F1 3 0 R >> /XObject << /Im1 4 0 R >> >> >>" % content
        )
        kids.append("%d 0 R" % len(objs))
    objs[1] = "<< /Type /Pages /Kids [%s] /Count %d >>" % (" ".join(kids), len(kids))
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n")
    offsets = []
    for i, o in enumerate(objs, 1):
        offsets.append(out.tell())
        out.write(("%d 0 obj\n%s\nendobj\n" % (i, o)).encode("latin-1"))
    xref = out.tell()
    out.write(("xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)).encode())
    for off in offsets:
        out.write(("%010d 00000 n \n" % off).encode())
    out.write(("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)).encode())
    with open(path, "wb") as f:
        f.write(out.getvalue())


def docx(path):
    R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    body = (
        '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Quarterly report</w:t></w:r></w:p>'
        "<w:p><w:r><w:t>Revenue grew by twelve percent.</w:t></w:r></w:p>"
        # Japanese: on macOS, headless LibreOffice drops it from the page
        # unless the helper points fontconfig at the system fonts
        "<w:p><w:r><w:t>売上は十二パーセント増えました。</w:t></w:r></w:p>"
        '<w:p><w:r><w:drawing><wp:inline><wp:extent cx="95250" cy="95250"/><wp:docPr id="1" name="Picture 1" descr="Company logo"/>'
        '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>'
        '<pic:nvPicPr><pic:cNvPr id="0" name="logo.png"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill><pic:spPr/></pic:pic></a:graphicData></a:graphic>'
        "</wp:inline></w:drawing></w:r></w:p>"
    )
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(
            "[Content_Types].xml",
            '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>'
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
            "</Types>",
        )
        z.writestr(
            "_rels/.rels",
            '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="%s/officeDocument" Target="word/document.xml"/></Relationships>' % R,
        )
        z.writestr(
            "word/document.xml",
            '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
            'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
            'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
            'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" xmlns:r="%s"><w:body>%s</w:body></w:document>' % (R, body),
        )
        z.writestr(
            "word/_rels/document.xml.rels",
            '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId5" Type="%s/image" Target="media/logo.png"/></Relationships>' % R,
        )
        z.writestr("word/media/logo.png", png(10, 10, (0, 128, 0)))


def pptx(path, img):
    from pptx import Presentation
    from pptx.util import Inches

    prs = Presentation()
    s = prs.slides.add_slide(prs.slide_layouts[1])
    s.shapes.title.text = "Introduction"
    s.placeholders[1].text = "The plan for next year"
    s = prs.slides.add_slide(prs.slide_layouts[5])
    s.shapes.title.text = "Architecture"
    pic = s.shapes.add_picture(img, Inches(1), Inches(2))
    pic._element.nvPicPr.cNvPr.set("descr", "System diagram")
    prs.save(path)


def xlsx(path, img):
    import openpyxl

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Sales"
    ws.append(["region", "amount"])
    ws.append(["north", 120])
    ws.append(["south", 80])
    try:
        from openpyxl.drawing.image import Image

        ws.add_image(Image(img), "D2")
    except Exception:
        pass  # needs Pillow; the image part of the test then skips
    wb.create_sheet("Notes").append(["checked", "yes"])
    wb.save(path)


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    img = os.path.join(out, "red.png")
    with open(img, "wb") as f:
        f.write(png(40, 30, (255, 0, 0)))
    pdf(os.path.join(out, "paper.pdf"))
    try:
        from PIL import Image

        Image.new("RGB", (64, 32), (10, 200, 10)).save(os.path.join(out, "shot.tiff"))
    except ImportError:
        sys.stderr.write("skipped shot.tiff: Pillow is not installed\n")
    docx(os.path.join(out, "report.docx"))
    for name, fn in (("deck.pptx", pptx), ("book.xlsx", xlsx)):
        try:
            fn(os.path.join(out, name), img)
        except ImportError as e:
            sys.stderr.write("skipped %s: %s\n" % (name, e))
