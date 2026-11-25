"""coagent.nvim document helper: converts a document to Markdown with
MarkItDown and extracts the images embedded in OOXML files.

Started by lua/coagent/agent/documents.lua with an argv list (never through a
shell), in a private, empty working directory, with a timeout. It only reads
the input file and writes into the --out directory it is given.

  probe                       print {"markitdown": "<version>" | null, ...} as JSON
  convert --input F --out D --format EXT [--images] [--soffice PATH] [limits]
                              write D/content.md and D/meta.json (+ D/images/)
  images  --input F --out D --format EXT [limits]
                              image extraction only (OOXML: standard library
                              only; PDF: pdfminer.six, MarkItDown's [pdf] extra)
  pages   --input F --out D --format EXT --pages 3,4,5 [--soffice PATH] [--max-side N]
                              pages / slides as PNG with their text: D/pages/pNNNN.png
                              and D/pages.json. PDF directly (pypdfium2); PPTX,
                              DOCX, DOC through LibreOffice's PDF (D/rendered.pdf)
  topng   --input IMG --out PNG [--soffice PATH] [--max-side N]
                              an image the model cannot take (EMF, WMF, TIFF,
                              BMP, JPEG 2000, CMYK JPEG) as PNG: Pillow, else
                              LibreOffice for EMF / WMF

On failure, prints {"error": "...", "kind": "..."} as JSON and exits 2.

What it never does: install anything, use the network, call an LLM to
describe images (no llm_client is passed), enable MarkItDown plugins
(OCR and others), run macros, or follow links to external images.

MarkItDown is used through its public API only: MarkItDown(enable_plugins=False)
and convert_local() (convert() on versions without it), and the result's
markdown / text_content. Embedded images are read straight from the OOXML
zip parts with the standard library (zipfile, xml.etree), not through any
MarkItDown internals. PDF images are read with pdfminer.six's public
parser classes (PDFParser, PDFDocument, PDFPage, PDFStream.get_data).
"""

import argparse
import hashlib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET

HELPER_VERSION = "3"

NS = {
    "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "p": "http://schemas.openxmlformats.org/presentationml/2006/main",
    "wp": "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    "pic": "http://schemas.openxmlformats.org/drawingml/2006/picture",
    "xdr": "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing",
    "s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "rel": "http://schemas.openxmlformats.org/package/2006/relationships",
}
R_EMBED = "{%s}embed" % NS["r"]
R_ID = "{%s}id" % NS["r"]
IMAGE_REL = "/image"
DRAWING_REL = "/drawing"

# a zip with more entries than this is not searched for images
MAX_ZIP_ENTRIES = 20000
# XML parts larger than this are not parsed for image placement
MAX_XML_BYTES = 64 * 1024 * 1024
# image file extensions kept as they are (others become .bin)
SAFE_EXT = re.compile(r"^[a-z0-9]{1,5}$")


class HelperError(Exception):
    def __init__(self, message, kind="conversion"):
        Exception.__init__(self, message)
        self.kind = kind


def fail(message, kind="conversion"):
    sys.stdout.write(json.dumps({"error": str(message), "kind": kind}))
    sys.stdout.flush()
    sys.exit(2)


# ---------------------------------------------------------------------------
# probe
# ---------------------------------------------------------------------------


def markitdown_version():
    """Version of the installed MarkItDown, None when it is not installed."""
    import importlib.util

    if importlib.util.find_spec("markitdown") is None:
        return None
    try:
        from importlib import metadata

        return metadata.version("markitdown")
    except Exception:
        pass
    try:
        import markitdown

        return str(getattr(markitdown, "__version__", "unknown"))
    except Exception:
        return "unknown"


def module_version(name):
    """Version of an optional module (pypdfium2, Pillow), None when missing."""
    import importlib.util

    if importlib.util.find_spec(name) is None:
        return None
    try:
        from importlib import metadata

        return metadata.version({"PIL": "pillow"}.get(name, name))
    except Exception:
        return "unknown"


def cmd_probe(_args):
    sys.stdout.write(
        json.dumps(
            {
                "markitdown": markitdown_version(),
                "pypdfium2": module_version("pypdfium2"),
                "pillow": module_version("PIL"),
                "pdfminer": module_version("pdfminer"),
                "python": "%d.%d.%d" % sys.version_info[:3],
                "helper": HELPER_VERSION,
            }
        )
    )


# ---------------------------------------------------------------------------
# images embedded in OOXML (docx / pptx / xlsx)
# ---------------------------------------------------------------------------


class Limits(object):
    def __init__(self, args):
        self.max_count = max(0, int(args.max_images))
        self.max_bytes = max(0, int(args.max_image_bytes))
        self.max_total = max(0, int(args.max_total_image_bytes))


def read_member(zf, name, limit):
    """Bytes of a zip member, refused when larger than `limit` (the declared
    size is checked first; the read stops past the limit in case it lies)."""
    info = zf.getinfo(name)
    if info.file_size > limit:
        return None
    with zf.open(info) as f:
        data = f.read(limit + 1)
    if len(data) > limit:
        return None
    return data


def parse_xml(zf, name):
    try:
        data = read_member(zf, name, MAX_XML_BYTES)
    except KeyError:
        return None
    if data is None:
        return None
    try:
        return ET.fromstring(data)
    except ET.ParseError:
        return None


def rels_path(part):
    d, base = posixpath.split(part)
    return posixpath.join(d, "_rels", base + ".rels")


def resolve_target(part, target):
    """Zip member name a relationship target points to, None when it leaves
    the package (absolute, "..", external)."""
    if not target or "\\" in target or ":" in target:
        return None
    if target.startswith("/"):
        name = posixpath.normpath(target.lstrip("/"))
    else:
        name = posixpath.normpath(posixpath.join(posixpath.dirname(part), target))
    if name.startswith("../") or name == ".." or name.startswith("/"):
        return None
    return name


def read_rels(zf, part):
    """rId -> {"type", "target" (member name or None), "external"}"""
    root = parse_xml(zf, rels_path(part))
    out = {}
    if root is None:
        return out
    for rel in root.findall("rel:Relationship", NS):
        rid = rel.get("Id")
        external = (rel.get("TargetMode") or "").lower() == "external"
        out[rid] = {
            "type": rel.get("Type") or "",
            "target": None if external else resolve_target(part, rel.get("Target") or ""),
            "external": external,
        }
    return out


def alt_text(nv):
    """descr, else title, else name of a cNvPr element."""
    if nv is None:
        return ""
    for attr in ("descr", "title", "name"):
        v = (nv.get(attr) or "").strip()
        if v:
            return v
    return ""


def pictures(root, cnvpr_paths):
    """(rId, alt) of each picture in document order. `cnvpr_paths` maps a
    picture container tag to the relative path of its cNvPr element."""
    out = []
    # walk in document order: every a:blip with r:embed, the alt text from the
    # nearest enclosing picture / drawing element
    parents = {c: p for p in root.iter() for c in p}

    def find_alt(el):
        cur = el
        while cur is not None:
            for _, path in cnvpr_paths:
                nv = cur.find(path, NS)
                if nv is not None:
                    return alt_text(nv)
            cur = parents.get(cur)
        return ""

    for blip in root.iter("{%s}blip" % NS["a"]):
        rid = blip.get(R_EMBED)
        if rid:
            out.append((rid, find_alt(blip)))
    return out


PPTX_ALT = [("pic", "p:nvPicPr/p:cNvPr")]
DOCX_ALT = [("inline", "wp:docPr")]
XLSX_ALT = [("pic", "xdr:nvPicPr/xdr:cNvPr")]


def pptx_locations(zf):
    """[(part, label, section)] for the slides in presentation order."""
    pres = "ppt/presentation.xml"
    root = parse_xml(zf, pres)
    if root is None:
        return []
    rels = read_rels(zf, pres)
    out = []
    lst = root.find("p:sldIdLst", NS)
    for i, sld in enumerate(lst.findall("p:sldId", NS) if lst is not None else [], 1):
        rel = rels.get(sld.get(R_ID))
        if rel and rel["target"]:
            out.append((rel["target"], "slide %d" % i, str(i)))
    return out


def xlsx_locations(zf):
    """[(drawing part, label, sheet name)] in workbook order."""
    wb = "xl/workbook.xml"
    root = parse_xml(zf, wb)
    if root is None:
        return []
    rels = read_rels(zf, wb)
    out = []
    sheets = root.find("s:sheets", NS)
    for sh in sheets.findall("s:sheet", NS) if sheets is not None else []:
        name = sh.get("name") or ""
        rel = rels.get(sh.get(R_ID))
        if not (rel and rel["target"]):
            continue
        for srel in read_rels(zf, rel["target"]).values():
            if srel["type"].endswith(DRAWING_REL) and srel["target"]:
                out.append((srel["target"], 'sheet "%s"' % name, name))
    return out


def sheet_names(zf):
    root = parse_xml(zf, "xl/workbook.xml")
    sheets = root.find("s:sheets", NS) if root is not None else None
    return [sh.get("name") or "" for sh in (sheets.findall("s:sheet", NS) if sheets is not None else [])]


def extract_images(path, fmt, out_dir, limits):
    """Write the embedded images to out_dir/images/ and return their list:
    [{"n", "file", "ext", "bytes", "member", "alt", "locations": [{"label", "section"}]}]
    plus notes (skipped images, external links)."""
    notes = []
    images = []
    if fmt == "pdf":
        images, notes = pdf_images(path, out_dir, limits)
        return images, notes, []
    if fmt not in ("docx", "pptx", "xlsx"):
        return images, notes, []
    try:
        zf = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError) as e:
        return images, ["not a valid %s package: %s" % (fmt, e)], []
    with zf:
        if len(zf.infolist()) > MAX_ZIP_ENTRIES:
            return images, ["too many entries in the package; images not extracted"], []
        if fmt == "pptx":
            places = [(part, label, sec, PPTX_ALT) for part, label, sec in pptx_locations(zf)]
        elif fmt == "xlsx":
            places = [(part, label, sec, XLSX_ALT) for part, label, sec in xlsx_locations(zf)]
        else:
            places = [("word/document.xml", "document", None, DOCX_ALT)]
        by_member = {}
        external = 0
        escaped = 0
        total = 0
        img_dir = os.path.join(out_dir, "images")
        for part, label, section, alt_paths in places:
            root = parse_xml(zf, part)
            if root is None:
                continue
            rels = read_rels(zf, part)
            for rid, alt in pictures(root, alt_paths):
                rel = rels.get(rid)
                if not rel or not rel["type"].endswith(IMAGE_REL):
                    continue
                if rel["external"]:
                    external += 1
                    continue
                if not rel["target"]:
                    escaped += 1  # "../../x": outside the package (zip slip)
                    continue
                member = rel["target"]
                loc = {"label": label}
                if section is not None:
                    loc["section"] = section
                if member in by_member:
                    entry = by_member[member]
                    if loc not in entry["locations"]:
                        entry["locations"].append(loc)
                    if not entry["alt"] and alt:
                        entry["alt"] = alt
                    continue
                if len(images) >= limits.max_count:
                    notes.append("more than %d images: the rest were not extracted (documents.max_images)" % limits.max_count)
                    by_member[member] = {"locations": [], "alt": ""}  # counted once
                    continue
                try:
                    data = read_member(zf, member, limits.max_bytes)
                except KeyError:
                    notes.append("%s refers to a missing part %s" % (label, member))
                    continue
                if data is None:
                    notes.append("an image on %s is larger than documents.max_image_bytes; not extracted" % label)
                    by_member[member] = {"locations": [], "alt": ""}
                    continue
                if total + len(data) > limits.max_total:
                    notes.append("images past documents.max_images_total_bytes were not extracted")
                    by_member[member] = {"locations": [], "alt": ""}
                    continue
                total += len(data)
                ext = posixpath.splitext(member)[1].lstrip(".").lower()
                if not SAFE_EXT.match(ext or ""):
                    ext = "bin"
                # stable and collision free: position + content hash; never the
                # member name (no path from the package reaches the file system)
                entry = save_image(img_dir, images, data, ext, alt, loc)
                by_member[member] = entry
        if external:
            notes.append("%d linked (external) image(s) were not fetched" % external)
        if escaped:
            notes.append("%d image reference(s) pointing outside the package were ignored" % escaped)
        sheets = sheet_names(zf) if fmt == "xlsx" else []
    return images, sorted(set(notes)), sheets


# ---------------------------------------------------------------------------
# images in PDFs (pdfminer.six)
# ---------------------------------------------------------------------------

# decoded pixel data larger than this is not turned into a PNG
MAX_RAW_PIXELS_BYTES = 128 * 1024 * 1024


def lit_name(x):
    """The name of a PDF name object (PSLiteral), else None."""
    name = getattr(x, "name", None)
    if isinstance(name, bytes):
        name = name.decode("latin-1")
    return name


def png_bytes(width, height, color_type, bit_depth, rows):
    """A PNG from unfiltered scanlines (standard library only)."""
    import struct
    import zlib

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + r for r in rows)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, bit_depth, color_type, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b"")
    )


def pdf_colorspace(cs, resolve1):
    """("gray" | "rgb" | "cmyk" | "indexed" | None, extra)"""
    cs = resolve1(cs)
    name = lit_name(cs)
    if name in ("DeviceGray", "G", "CalGray"):
        return "gray", None
    if name in ("DeviceRGB", "RGB", "CalRGB"):
        return "rgb", None
    if name in ("DeviceCMYK", "CMYK"):
        return "cmyk", None
    if isinstance(cs, list) and cs:
        kind = lit_name(resolve1(cs[0]))
        if kind == "ICCBased" and len(cs) > 1:
            n = resolve1(resolve1(cs[1]).attrs.get("N")) if hasattr(resolve1(cs[1]), "attrs") else None
            return {1: "gray", 3: "rgb", 4: "cmyk"}.get(n, None), None
        if kind in ("CalGray", "CalRGB"):
            return ("gray" if kind == "CalGray" else "rgb"), None
        if kind in ("Indexed", "I") and len(cs) >= 4:
            base, _ = pdf_colorspace(cs[1], resolve1)
            table = resolve1(cs[3])
            if hasattr(table, "get_data"):
                table = table.get_data()
            if isinstance(table, str):
                table = table.encode("latin-1")
            return "indexed", (base, table)
    return None, None


def pdf_image_file(stream, resolve1):
    """(bytes, ext, needs_png) of an image XObject, or (None, reason, None)."""
    attrs = stream.attrs
    filters = [lit_name(f) for f, _ in stream.get_filters()]
    last = filters[-1] if filters else None
    width = int(resolve1(attrs.get("Width", attrs.get("W", 0))) or 0)
    height = int(resolve1(attrs.get("Height", attrs.get("H", 0))) or 0)
    if width <= 0 or height <= 0:
        return None, "no size", None
    if last in ("JBIG2Decode", "CCITTFaxDecode", "CCF"):
        return None, "encoding", None
    if last in ("DCTDecode", "DCT"):
        cs, _ = pdf_colorspace(attrs.get("ColorSpace", attrs.get("CS")), resolve1)
        return stream.get_data(), "jpg", cs == "cmyk"
    if last == "JPXDecode":
        return stream.get_data(), "jp2", True
    bpc = int(resolve1(attrs.get("BitsPerComponent", attrs.get("BPC", 8))) or 8)
    if resolve1(attrs.get("ImageMask", attrs.get("IM"))):
        cs, extra, bpc = "gray", None, 1
    else:
        cs, extra = pdf_colorspace(attrs.get("ColorSpace", attrs.get("CS")), resolve1)
    comps = {"gray": 1, "rgb": 3, "cmyk": 4, "indexed": 1}.get(cs)
    if comps is None or bpc not in (1, 8) or (bpc == 1 and cs != "gray"):
        return None, "colorspace", None
    rowbytes = (width * comps * bpc + 7) // 8
    if rowbytes * height > MAX_RAW_PIXELS_BYTES:
        return None, "large", None
    data = stream.get_data()
    if len(data) < rowbytes * height:
        return None, "short", None
    rows = [data[i * rowbytes:(i + 1) * rowbytes] for i in range(height)]
    if cs == "gray":
        return png_bytes(width, height, 0, bpc, rows), "png", False
    if cs == "rgb":
        return png_bytes(width, height, 2, 8, rows), "png", False
    if cs == "cmyk":
        out = []
        for r in rows:
            px = bytearray()
            for i in range(0, len(r) - 3, 4):
                c, m, y, k = r[i], r[i + 1], r[i + 2], r[i + 3]
                px += bytes(((255 - c) * (255 - k) // 255, (255 - m) * (255 - k) // 255, (255 - y) * (255 - k) // 255))
            out.append(bytes(px))
        return png_bytes(width, height, 2, 8, out), "png", False
    # indexed: expand through the palette (gray or RGB base)
    base, table = extra
    step = {"gray": 1, "rgb": 3}.get(base)
    if not step or not isinstance(table, (bytes, bytearray)):
        return None, "colorspace", None
    out = []
    for r in rows:
        px = bytearray()
        for v in r[:width]:
            px += table[v * step:v * step + step].ljust(step, b"\x00")
        out.append(bytes(px))
    return png_bytes(width, height, 0 if step == 1 else 2, 8, out), "png", False


def pdf_images(path, out_dir, limits):
    """Image XObjects of each page (and of the forms it draws), in page order.
    Inline images (BI ... EI) and soft masks are not taken."""
    try:
        from pdfminer.pdfdocument import PDFDocument
        from pdfminer.pdfpage import PDFPage
        from pdfminer.pdfparser import PDFParser
        from pdfminer.pdftypes import PDFStream, resolve1
    except ImportError:
        return [], ["pdfminer.six is not installed with MarkItDown: PDF images were not extracted (pip install 'markitdown[pdf]')"]
    images, notes = [], []
    skipped = {}
    by_key = {}
    state = {"total": 0, "limited": False}
    img_dir = os.path.join(out_dir, "images")

    def add(stream, key, page):
        loc = {"label": "page %d" % page}
        if key in by_key:
            entry = by_key[key]
            if entry is not None and loc not in entry["locations"]:
                entry["locations"].append(loc)
            return
        by_key[key] = None
        if len(images) >= limits.max_count:
            state["limited"] = True
            return
        try:
            data, ext, needs_png = pdf_image_file(stream, resolve1)
        except Exception:
            data, ext = None, "unreadable"
        if data is None:
            skipped[ext] = skipped.get(ext, 0) + 1
            return
        if len(data) > limits.max_bytes:
            notes.append("an image on page %d is larger than documents.max_image_bytes; not extracted" % page)
            return
        if state["total"] + len(data) > limits.max_total:
            notes.append("images past documents.max_images_total_bytes were not extracted")
            return
        state["total"] += len(data)
        entry = save_image(img_dir, images, data, ext, "", loc)
        if needs_png:
            entry["convert"] = True
        by_key[key] = entry

    def walk(res, page, depth, forms):
        res = resolve1(res)
        if not isinstance(res, dict):
            return
        xobjs = resolve1(res.get("XObject"))
        if not isinstance(xobjs, dict):
            return
        for ref in xobjs.values():
            obj = resolve1(ref)
            if not isinstance(obj, PDFStream):
                continue
            key = getattr(ref, "objid", None) or id(obj)
            sub = lit_name(resolve1(obj.attrs.get("Subtype")))
            if sub == "Image":
                add(obj, key, page)
            elif sub == "Form" and depth < 8 and key not in forms:
                forms.add(key)
                walk(obj.attrs.get("Resources"), page, depth + 1, forms)

    try:
        with open(path, "rb") as f:
            doc = PDFDocument(PDFParser(f))
            for page_no, page in enumerate(PDFPage.create_pages(doc), 1):
                walk(page.resources, page_no, 0, set())
    except Exception as e:
        notes.append("images could not be read from the PDF (%s: %s)" % (type(e).__name__, str(e)[:200]))
    if state["limited"]:
        notes.append("more than %d images: the rest were not extracted (documents.max_images)" % limits.max_count)
    reasons = {
        "encoding": "JBIG2 / CCITT fax encoded (scans)",
        "colorspace": "in color spaces or bit depths not handled",
        "large": "too large to decode",
        "short": "with truncated data",
        "no size": "without a size",
        "unreadable": "unreadable",
    }
    for k, n in sorted(skipped.items()):
        notes.append("%d PDF image(s) %s were not extracted" % (n, reasons.get(k, k)))
    return images, sorted(set(notes))


def save_image(img_dir, images, data, ext, alt, loc):
    """Write one image as images/NNN-<sha>.<ext> and append its entry."""
    n = len(images) + 1
    name = "%03d-%s.%s" % (n, hashlib.sha256(data).hexdigest()[:10], ext)
    if not os.path.isdir(img_dir):
        os.makedirs(img_dir, mode=0o700)
    with open(os.path.join(img_dir, name), "xb") as f:
        f.write(data)
    entry = {"n": n, "file": "images/" + name, "ext": ext, "bytes": len(data), "alt": alt, "locations": [loc]}
    images.append(entry)
    return entry


# ---------------------------------------------------------------------------
# topng
# ---------------------------------------------------------------------------


def soffice_argv(soffice, work, outdir, fmt, path):
    from urllib.request import pathname2url

    return [
        soffice,
        "-env:UserInstallation=file://" + pathname2url(os.path.join(work, "lo-profile")),
        "--headless",
        "--norestore",
        "--nolockcheck",
        "--convert-to",
        fmt,
        "--outdir",
        outdir,
        path,
    ]


MAC_FONT_DIRS = ("/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts", "~/Library/Fonts")


def soffice_env(work):
    """The environment for LibreOffice. On macOS, --headless lays text out
    with the bundled fontconfig, which knows no system fonts: Japanese and
    other scripts the bundled fonts lack would silently vanish from the page.
    A throwaway fonts.conf in `work` lists the macOS font folders (a
    FONTCONFIG_FILE the user set is left alone)."""
    env = dict(os.environ)
    if sys.platform == "darwin" and not env.get("FONTCONFIG_FILE"):
        from xml.sax.saxutils import escape

        conf = os.path.join(work, "fonts.conf")
        dirs = "".join("<dir>%s</dir>" % escape(d) for d in MAC_FONT_DIRS)
        with open(conf, "w", encoding="utf-8") as f:
            f.write(
                '<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd"><fontconfig>%s<cachedir>%s</cachedir></fontconfig>\n'
                % (dirs, escape(os.path.join(work, "fc-cache")))
            )
        env["FONTCONFIG_FILE"] = conf
    return env


def run_soffice(soffice, work, outdir, fmt, path):
    return subprocess.run(
        soffice_argv(soffice, work, outdir, fmt, path),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=work,
        env=soffice_env(work),
    )


def trim_page(im, pad=8):
    """The picture without the blank page around it (the colour of the top
    left corner counts as blank)."""
    from PIL import Image, ImageChops

    rgb = im.convert("RGB")
    box = ImageChops.difference(rgb, Image.new("RGB", rgb.size, rgb.getpixel((0, 0)))).getbbox()
    if not box:
        return im
    l, t, r, b = box
    return im.crop((max(0, l - pad), max(0, t - pad), min(im.width, r + pad), min(im.height, b + pad)))


def save_png(im, dst, max_side):
    if im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info):
        im = im.convert("RGBA")
    elif im.mode != "RGB":
        im = im.convert("RGB")
    if max_side > 0 and max(im.size) > max_side:
        im.thumbnail((max_side, max_side))
    im.save(dst, "PNG")


def cmd_topng(args):
    src, dst = args.input, args.out
    max_side = int(args.max_side)
    try:
        from PIL import Image
    except ImportError:
        Image = None
    pil_error = None
    if Image is not None:
        try:
            with Image.open(src) as im:
                im.load()
                save_png(im, dst, max_side)
            return
        except Exception as e:  # e.g. WMF / EMF outside Windows
            pil_error = "%s: %s" % (type(e).__name__, str(e)[:200])
    ext = os.path.splitext(src)[1].lstrip(".").lower()
    if ext in ("emf", "wmf"):
        if not args.soffice:
            raise HelperError(
                "%s needs LibreOffice (soffice) to become PNG%s" % (ext.upper(), "" if Image else "; Pillow is not installed either"),
                "missing_soffice",
            )
        # in the working directory (coagent runs the helper in a private
        # temporary one and deletes it, even after a kill), not next to dst
        work = tempfile.mkdtemp(prefix="png-", dir=os.getcwd())
        try:
            outdir = os.path.join(work, "out")
            os.makedirs(outdir, mode=0o700)
            # LibreOffice places the picture on a whole (A4 / Letter) page at
            # screen resolution. With pypdfium2 the page goes through PDF and
            # is rendered at 300 dpi; either way the blank page is trimmed.
            try:
                import pypdfium2 as pdfium
            except ImportError:
                pdfium = None
            vector = Image is not None and pdfium is not None
            target = "pdf" if vector else "png"
            res = run_soffice(args.soffice, work, outdir, target, src)
            out = os.path.join(outdir, os.path.splitext(os.path.basename(src))[0] + "." + target)
            if res.returncode != 0 or not os.path.isfile(out):
                msg = (res.stderr or res.stdout or b"").decode("utf-8", "replace").strip()[:300]
                raise HelperError("LibreOffice could not convert the %s image (exit %s)%s" % (ext.upper(), res.returncode, (": " + msg) if msg else ""))
            if vector:
                pdf = pdfium.PdfDocument(out)
                try:
                    im = pdf[0].render(scale=300 / 72).to_pil()
                finally:
                    pdf.close()
                save_png(trim_page(im), dst, max_side)
            elif Image is not None:
                with Image.open(out) as im:
                    im.load()
                    save_png(trim_page(im), dst, max_side)
            else:
                shutil.move(out, dst)
        finally:
            shutil.rmtree(work, ignore_errors=True)
        return
    if Image is None:
        raise HelperError("converting %s images to PNG needs Pillow" % (ext.upper() or "these"), "missing_pillow")
    raise HelperError("Pillow cannot read this %s image (%s)" % (ext.upper() or "", pil_error), "unconvertible")


# ---------------------------------------------------------------------------
# pages
# ---------------------------------------------------------------------------

# LibreOffice's PDF export leaves hidden slides out unless told otherwise
# (JSON filter options: LibreOffice 7.4+; older versions get plain "pdf")
IMPRESS_PDF_ALL = 'pdf:impress_pdf_Export:{"ExportHiddenSlides":{"type":"boolean","value":"true"}}'


def render_pdf_with_soffice(src, fmt, soffice, out):
    """out/rendered.pdf from a PPTX / DOCX / DOC, laid out by LibreOffice."""
    work = tempfile.mkdtemp(prefix="render-", dir=out)
    try:
        outdir = os.path.join(work, "out")
        os.makedirs(outdir, mode=0o700)
        stem = os.path.splitext(os.path.basename(src))[0]
        produced = os.path.join(outdir, stem + ".pdf")
        last = None
        for target in ([IMPRESS_PDF_ALL, "pdf"] if fmt == "pptx" else ["pdf"]):
            try:
                last = run_soffice(soffice, work, outdir, target, src)
            except OSError as e:
                raise HelperError("could not start LibreOffice (%s): %s" % (soffice, e), "missing_soffice")
            if last.returncode == 0 and os.path.isfile(produced):
                break
        if not os.path.isfile(produced):
            msg = (last.stderr or last.stdout or b"").decode("utf-8", "replace").strip()[:400] if last else ""
            raise HelperError("LibreOffice could not lay out the document as PDF%s" % ((": " + msg) if msg else ""))
        os.replace(produced, os.path.join(out, "rendered.pdf"))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def cmd_pages(args):
    out, fmt = args.out, args.format
    want = sorted(set(int(x) for x in str(args.pages).split(",") if x.strip().isdigit()))
    if fmt == "pdf":
        pdf, source = args.input, "pdf"
    else:
        pdf, source = os.path.join(out, "rendered.pdf"), "libreoffice"
        if not os.path.isfile(pdf):
            if not args.soffice:
                raise HelperError("pages of a .%s file are laid out by LibreOffice (soffice), which was not found" % fmt, "missing_soffice")
            render_pdf_with_soffice(args.input, fmt, args.soffice, out)
    try:
        import pypdfium2 as pdfium
    except ImportError:
        raise HelperError("rendering pages needs pypdfium2", "missing_pdfium")
    try:
        import PIL  # noqa: F401  (pypdfium2's to_pil)
    except ImportError:
        raise HelperError("rendering pages needs Pillow", "missing_pillow")
    index_path = os.path.join(out, "pages.json")
    index = {}
    if os.path.isfile(index_path):
        with open(index_path, encoding="utf-8") as f:
            index = json.load(f)
    pages = index.get("pages") or {}
    pages_dir = os.path.join(out, "pages")
    if not os.path.isdir(pages_dir):
        os.makedirs(pages_dir, mode=0o700)
    max_side = float(args.max_side)
    doc = pdfium.PdfDocument(pdf)
    try:
        count = len(doc)
        for n in want:
            if n < 1 or n > count:
                continue
            page = doc[n - 1]
            try:
                w, h = page.get_size()
                scale = min(max_side / max(w, h, 1.0), 4.0)
                im = page.render(scale=scale).to_pil()
                name = "p%04d.png" % n
                tmp = os.path.join(pages_dir, "." + name + ".tmp")
                im.save(tmp, "PNG")
                os.replace(tmp, os.path.join(pages_dir, name))
                text = page.get_textpage().get_text_range()
                pages[str(n)] = {"file": "pages/" + name, "text": text[:20000], "width": im.width, "height": im.height}
            finally:
                page.close()
    finally:
        doc.close()
    index = {"count": count, "source": source, "pages": pages}
    tmp = index_path + ".tmp"
    write_json(tmp, index)
    os.replace(tmp, index_path)


def cmd_images(args):
    out = args.out
    images, notes, sheets = extract_images(args.input, args.format, out, Limits(args))
    write_json(os.path.join(out, "meta.json"), {"images": images, "notes": notes, "sheets": sheets})


# ---------------------------------------------------------------------------
# convert
# ---------------------------------------------------------------------------


def write_json(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)


def doc_to_docx(path, soffice, work):
    """Convert a legacy .doc with LibreOffice (headless, a fresh throwaway
    profile: default macro security, no recovery, no running instance used)."""
    outdir = os.path.join(work, "lo-out")
    os.makedirs(outdir, mode=0o700)
    try:
        res = run_soffice(soffice, work, outdir, "docx", path)
    except OSError as e:
        raise HelperError("could not start LibreOffice (%s): %s" % (soffice, e), "missing_soffice")
    stem = os.path.splitext(os.path.basename(path))[0]
    out = os.path.join(outdir, stem + ".docx")
    if res.returncode != 0 or not os.path.isfile(out):
        msg = (res.stderr or res.stdout or b"").decode("utf-8", "replace").strip()[:400]
        raise HelperError("LibreOffice could not convert the .doc file (exit %s)%s" % (res.returncode, (": " + msg) if msg else ""))
    return out


def run_markitdown(path):
    try:
        from markitdown import MarkItDown
    except ImportError as e:
        raise HelperError("MarkItDown is not installed for this Python (%s): %s" % (sys.executable, e), "missing_markitdown")
    # no llm_client (no image descriptions), no plugins (no OCR), no docintel
    md = MarkItDown(enable_plugins=False)
    try:
        conv = getattr(md, "convert_local", None) or md.convert
        result = conv(path)
    except Exception as e:  # MarkItDown raises its own exception types
        name = type(e).__name__
        msg = str(e).strip()
        if "MissingDependency" in name or ("missing" in msg.lower() and "depend" in msg.lower()):
            raise HelperError(msg[:800], "missing_dependency")
        if "UnsupportedFormat" in name:
            raise HelperError(msg[:800], "unsupported")
        raise HelperError("%s: %s" % (name, msg[:800]))
    text = getattr(result, "markdown", None)
    if text is None:
        text = getattr(result, "text_content", "") or ""
    return text


def cmd_convert(args):
    out = args.out
    src = args.input
    fmt = args.format
    work = tempfile.mkdtemp(prefix="work-", dir=out)
    try:
        if fmt == "doc":
            if not args.soffice:
                raise HelperError("reading .doc needs LibreOffice (soffice)", "missing_soffice")
            src = doc_to_docx(src, args.soffice, work)
            fmt = "docx"
        text = run_markitdown(src)
        images, notes, sheets = [], [], []
        if args.images:
            images, notes, sheets = extract_images(src, fmt, out, Limits(args))
        elif fmt == "xlsx":
            try:
                with zipfile.ZipFile(src) as zf:
                    sheets = sheet_names(zf)
            except (zipfile.BadZipFile, OSError):
                sheets = []
        with open(os.path.join(out, "content.md"), "w", encoding="utf-8") as f:
            f.write(text)
        write_json(
            os.path.join(out, "meta.json"),
            {
                "markitdown": markitdown_version(),
                "helper": HELPER_VERSION,
                "converted_from": "docx (LibreOffice)" if args.format == "doc" else None,
                "images": images,
                "notes": notes,
                "sheets": sheets,
            },
        )
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    ap = argparse.ArgumentParser(prog="coagent_markitdown")
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("probe")
    p = sub.add_parser("pages")
    p.add_argument("--input", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--format", required=True, choices=["pdf", "docx", "pptx", "doc"])
    p.add_argument("--pages", required=True)
    p.add_argument("--soffice")
    p.add_argument("--max-side", default=1568)
    p = sub.add_parser("topng")
    p.add_argument("--input", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--soffice")
    p.add_argument("--max-side", default=2048)
    for name in ("convert", "images"):
        p = sub.add_parser(name)
        p.add_argument("--input", required=True)
        p.add_argument("--out", required=True)
        p.add_argument("--format", required=True, choices=["pdf", "docx", "pptx", "xlsx", "xls", "doc"])
        p.add_argument("--images", action="store_true")
        p.add_argument("--soffice")
        p.add_argument("--max-images", default=100)
        p.add_argument("--max-image-bytes", default=20 * 1024 * 1024)
        p.add_argument("--max-total-image-bytes", default=100 * 1024 * 1024)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "probe":
            cmd_probe(args)
        elif args.cmd == "convert":
            cmd_convert(args)
        elif args.cmd == "images":
            cmd_images(args)
        elif args.cmd == "pages":
            cmd_pages(args)
        elif args.cmd == "topng":
            cmd_topng(args)
        else:
            fail("unknown command", "usage")
    except HelperError as e:
        fail(str(e), e.kind)
    except Exception as e:
        fail("%s: %s" % (type(e).__name__, e))


if __name__ == "__main__":
    main(sys.argv[1:])
