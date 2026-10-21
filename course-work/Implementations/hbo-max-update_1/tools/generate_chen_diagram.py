#!/usr/bin/env python3
"""
Generate the conceptual model of HBO Max in Chen's notation:

    docs/diagrams/01-conceptual-chen.drawio     editable diagram (draw.io / diagrams.net)
    docs/diagrams/png/01-conceptual-chen.png    image export (needs rsvg-convert)

Unlike the logical and DW diagrams, a conceptual model is not derivable from the
DDL - it hides surrogate keys, junction tables and audit columns and shows the
business view - so the model is written out below as data.

Chen notation used
    rectangle            entity              double rectangle   weak entity
    diamond              relationship        double diamond     identifying relationship
    ellipse              attribute           underlined         key attribute
    dashed ellipse       derived attribute   dashed underline   partial key (weak entity)
    ellipse on ellipse   composite attribute
    single line          partial participation
    double line          total participation
    1 / N / M            cardinality

Usage
    python tools/generate_chen_diagram.py                 # defaults: docs/diagrams/
    python tools/generate_chen_diagram.py OUT_DIR

Standard library only; the PNG step is skipped when rsvg-convert is missing.
"""
import math
import shutil
import subprocess
import sys
from html import escape
from pathlib import Path
from xml.sax.saxutils import quoteattr

ROOT = Path(__file__).resolve().parent.parent
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "docs" / "diagrams"

W, H = 3600, 2450          # canvas
EW, EH = 170, 56           # entity
RW, RH = 150, 76           # relationship diamond
AW, AH = 132, 36           # attribute ellipse

# ---- the model ---------------------------------------------------------------
# entity: name -> (cx, cy, weak, [attributes]); attribute = (label, kind, dx, dy)
# kind: key | partial | plain | derived | composite:<parent label>
E = {
    "COUNTRY":        (1700, 150, False, [("CountryID", "key", -260, -60), ("IsoCode", "plain", -250, 10),
                                           ("CountryName", "plain", 250, -60), ("RegionName", "plain", 250, 10),
                                           ("LaunchDate", "plain", 0, -85)]),
    "SUBSCRIBER":     (800, 520, False, [("SubscriberID", "key", -300, -120), ("Email", "plain", -330, -60),
                                         ("FullName", "plain", -330, 0), ("FirstName", "composite:FullName", -470, 50),
                                         ("LastName", "composite:FullName", -330, 70),
                                         ("DateOfBirth", "plain", -150, -110), ("Age", "derived", -20, -130),
                                         ("RegisteredAt", "plain", 130, -120), ("AccountStatus", "plain", -330, 125)]),
    "PROFILE":        (1650, 760, False, [("ProfileID", "key", -60, -95), ("ProfileName", "plain", 90, -95),
                                          ("IsKidsProfile", "plain", -190, 85), ("MaturityCeiling", "plain", 180, 85)]),
    "SUBSCRIPTION":   (520, 1080, False, [("SubscriptionID", "key", -260, -80), ("StartDate", "plain", -290, -25),
                                          ("EndDate", "plain", -290, 30), ("Status", "plain", -250, 85),
                                          ("BillingCycle", "plain", 220, 60), ("TrialEndsOn", "plain", 200, 115)]),
    "PLAN":           (230, 1560, False, [("PlanID", "key", -110, -75), ("PlanName", "plain", -170, -20),
                                          ("MonthlyPrice", "plain", -170, 35), ("MaxVideoQuality", "plain", -120, 90),
                                          ("MaxProfiles", "plain", 40, 95), ("HasAdvertising", "plain", 190, 95)]),
    "COUPON":         (900, 1560, False, [("CouponID", "key", -120, -80), ("CouponCode", "plain", -240, 40),
                                          ("DiscountPercent", "plain", -170, 95), ("ValidFrom", "plain", 0, 100),
                                          ("ValidTo", "plain", 170, 90)]),
    "INVOICE":        (520, 2020, False, [("InvoiceID", "key", -240, -60), ("InvoiceNumber", "plain", -260, -5),
                                          ("PeriodStart", "plain", -250, 50), ("PeriodEnd", "plain", -110, 95),
                                          ("TotalAmount", "plain", 40, 100), ("InvoiceStatus", "plain", 190, 95)]),
    "PAYMENT":        (1150, 2260, False, [("PaymentID", "key", -250, -20), ("PaidAt", "plain", -220, 50),
                                           ("Amount", "plain", 0, 85), ("PaymentStatus", "plain", 200, 70)]),
    "PAYMENT METHOD": (1300, 1800, False, [("PaymentMethodID", "key", 70, 95), ("MethodType", "plain", 230, 60),
                                           ("CardBrand", "plain", 260, 5), ("Last4Digits", "plain", 240, -50)]),
    "DEVICE":         (1300, 1250, False, [("DeviceID", "key", 130, -80), ("DeviceType", "plain", 250, -30),
                                           ("Manufacturer", "plain", 250, 30), ("OperatingSystem", "plain", 150, 90)]),
    "WATCH SESSION":  (1900, 1450, False, [("WatchSessionID", "key", -280, 95), ("StartedAt", "plain", -140, 110),
                                           ("SecondsWatched", "plain", 0, 120), ("PercentComplete", "plain", 140, 110),
                                           ("VideoQuality", "plain", 280, 95)]),
    "TITLE":          (2650, 760, False, [("TitleID", "key", 230, -100), ("PrimaryTitle", "plain", 230, -50),
                                          ("TitleType", "plain", 380, -50), ("ReleaseYear", "plain", 230, 50),
                                          ("MaturityRating", "plain", 380, 50), ("IsHboOriginal", "plain", 230, 100),
                                          ("AverageUserRating", "derived", 380, 100)]),
    "SEASON":         (2650, 1560, True, [("SeasonNumber", "partial", 230, -40), ("ReleaseYear", "plain", 250, 15),
                                          ("EpisodeCount", "derived", 230, 70)]),
    "EPISODE":        (2650, 2160, True, [("EpisodeNumber", "partial", 230, -50), ("EpisodeTitle", "plain", 260, 5),
                                          ("RuntimeMinutes", "plain", 240, 60), ("AirDate", "plain", 90, 100)]),
    "GENRE":          (3350, 330, False, [("GenreID", "key", -40, -85), ("GenreName", "plain", 110, -80)]),
    "PERSON":         (2650, 150, False, [("PersonID", "key", -230, -50), ("FullName", "plain", 230, -50),
                                          ("BirthDate", "plain", 0, -85)]),
    "STUDIO":         (3420, 760, False, [("StudioID", "key", -40, -95), ("StudioName", "plain", 100, -95),
                                          ("FoundedYear", "plain", 30, 90)]),
    "LANGUAGE":       (3350, 1250, False, [("LanguageID", "key", 50, 95), ("IsoCode", "plain", -110, 95),
                                           ("LanguageName", "plain", 150, -80)]),
}

# relationship: (label, cx, cy, A, cardA, totalA, B, cardB, totalB, identifying, [attrs], waypointsA, waypointsB)
# attrs = (label, dx, dy) relative to the diamond. waypoints: corner points from the diamond to the entity.
R = [
    ("LIVES IN",       1250, 340, "SUBSCRIBER", "N", True,  "COUNTRY", "1", False, False, [], [], []),
    ("HAS",            1230, 640, "SUBSCRIBER", "1", False, "PROFILE", "N", True, False, [], [], []),
    ("HOLDS",           660, 800, "SUBSCRIBER", "1", False, "SUBSCRIPTION", "N", True, False, [], [], []),
    ("IS ON",           375, 1320, "SUBSCRIPTION", "N", True, "PLAN", "1", False, False, [], [], []),
    ("REDEEMS",         900, 1240, "SUBSCRIPTION", "M", False, "COUPON", "N", False, False,
     [("AppliedAt", -170, 40)], [(900, 1080)], []),
    ("BILLED BY",       520, 1560, "SUBSCRIPTION", "1", False, "INVOICE", "N", True, False, [], [], []),
    ("SETTLES",         830, 2140, "INVOICE", "1", False, "PAYMENT", "N", True, False, [], [], []),
    ("PAID WITH",      1225, 2030, "PAYMENT", "N", True, "PAYMENT METHOD", "1", False, False, [], [], []),
    ("OWNS",           1100, 1350, "SUBSCRIBER", "1", False, "PAYMENT METHOD", "N", True, False, [], [], []),
    ("REGISTERS",      1050, 885, "SUBSCRIBER", "1", False, "DEVICE", "N", True, False, [], [], []),
    ("STARTS",         1650, 1130, "PROFILE", "1", False, "WATCH SESSION", "N", True, False, [], [], [(1900, 1130)]),
    ("STREAMED ON",    1550, 1450, "WATCH SESSION", "N", True, "DEVICE", "1", False, False, [], [], [(1300, 1450)]),
    ("PLAYS",          2270, 1130, "WATCH SESSION", "N", True, "TITLE", "1", False, False, [], [(2270, 1450)], []),
    ("COVERS",         2270, 1830, "WATCH SESSION", "N", False, "EPISODE", "1", False, False, [],
     [(2270, 1450)], [(2270, 2160)]),
    ("RATES",          2150, 640, "PROFILE", "M", False, "TITLE", "N", False, False,
     [("Rating", -95, -75), ("ReviewText", 0, -95), ("CreatedAt", 95, -75)], [], []),
    ("SAVES",          2150, 880, "PROFILE", "M", False, "TITLE", "N", False, False,
     [("AddedAt", 0, 85)], [], []),
    ("LICENSED IN",    2200, 330, "TITLE", "M", False, "COUNTRY", "N", False, False,
     [("AvailableFrom", -160, 90), ("AvailableUntil", 130, -80), ("LicenseType", 180, 0)], [], []),
    ("CREDITED IN",    2650, 450, "PERSON", "M", False, "TITLE", "N", False, False,
     [("CreditRole", -200, -25), ("CharacterName", -200, 30)], [], []),
    ("CLASSIFIED AS",  3000, 420, "TITLE", "M", False, "GENRE", "N", False, False,
     [("IsPrimary", 60, 85)], [], []),
    ("PRODUCED BY",    3200, 760, "TITLE", "N", False, "STUDIO", "1", False, False, [], [], []),
    ("SPOKEN IN",      2950, 1000, "TITLE", "N", True, "LANGUAGE", "1", False, False, [], [], []),
    ("OFFERS TRACK",   2850, 1200, "TITLE", "M", False, "LANGUAGE", "N", False, False,
     [("TrackType", 0, 90)], [], []),
    ("HAS SEASON",     2650, 1160, "TITLE", "1", False, "SEASON", "N", True, True, [], [], []),
    ("CONTAINS",       2650, 1860, "SEASON", "1", False, "EPISODE", "N", True, True, [], [], []),
]

TITLE_TEXT = ("<b>HBO Max - Conceptual model (Chen's notation)</b><br>"
              "18 entities, 24 relationships, 7 of them many-to-many. Rectangle = entity, double rectangle = "
              "weak entity, diamond = relationship, double diamond = identifying relationship, ellipse = attribute "
              "(<u>underlined</u> = key, dashed underline = partial key, dashed ellipse = derived, ellipse joined to "
              "an ellipse = composite). Double line = total participation; 1 / N / M = cardinality.")

ENTITY_FILL, ENTITY_STROKE = "#dae8fc", "#6c8ebf"
REL_FILL, REL_STROKE = "#fff2cc", "#d6b656"
ATTR_FILL, ATTR_STROKE = "#ffffff", "#666666"
REL_ATTR_FILL = "#fdf6e3"


def attr_center(ent_or_rel_center, dx, dy):
    return ent_or_rel_center[0] + dx, ent_or_rel_center[1] + dy


def endpoint_on_box(cx, cy, w, h, tx, ty):
    """Point where the segment centre->target leaves an axis-aligned box."""
    dx, dy = tx - cx, ty - cy
    if dx == 0 and dy == 0:
        return cx, cy
    sx = (w / 2) / abs(dx) if dx else math.inf
    sy = (h / 2) / abs(dy) if dy else math.inf
    s = min(sx, sy)
    return cx + dx * s, cy + dy * s


def endpoint_on_diamond(cx, cy, w, h, tx, ty):
    dx, dy = tx - cx, ty - cy
    if dx == 0 and dy == 0:
        return cx, cy
    s = 1 / (abs(dx) / (w / 2) + abs(dy) / (h / 2))
    return cx + dx * s, cy + dy * s


def endpoint_on_ellipse(cx, cy, w, h, tx, ty):
    dx, dy = tx - cx, ty - cy
    if dx == 0 and dy == 0:
        return cx, cy
    s = 1 / math.sqrt((dx / (w / 2)) ** 2 + (dy / (h / 2)) ** 2)
    return cx + dx * s, cy + dy * s


# ---- build a neutral scene, then write it as draw.io XML and as SVG ------------
def build_scene():
    shapes, lines, labels = [], [], []
    ent_c = {n: (v[0], v[1]) for n, v in E.items()}

    for name, (cx, cy, weak, attrs) in E.items():
        shapes.append(("weak" if weak else "entity", name, cx, cy, EW, EH))
        composite_parent = {}
        for label, kind, dx, dy in attrs:
            ax, ay = attr_center((cx, cy), dx, dy)
            if kind.startswith("composite:"):
                parent = kind.split(":", 1)[1]
                px, py = composite_parent[parent]
                shapes.append(("attr", label, ax, ay, AW - 14, AH - 4))
                a = endpoint_on_ellipse(ax, ay, AW - 14, AH - 4, px, py)
                b = endpoint_on_ellipse(px, py, AW, AH, ax, ay)
                lines.append(([a, b], False))
                continue
            shapes.append(({"key": "key", "partial": "partial", "derived": "derived"}.get(kind, "attr"),
                           label, ax, ay, AW, AH))
            composite_parent[label] = (ax, ay)
            a = endpoint_on_ellipse(ax, ay, AW, AH, cx, cy)
            b = endpoint_on_box(cx, cy, EW, EH, ax, ay)
            lines.append(([a, b], False))

    for (label, rx, ry, a, ca, ta, b, cb, tb, ident, rattrs, wpa, wpb) in R:
        shapes.append(("ident" if ident else "rel", label, rx, ry, RW, RH))
        for (ent, card, total, wps) in ((a, ca, ta, wpa), (b, cb, tb, wpb)):
            ex, ey = ent_c[ent]
            first = wps[0] if wps else (ex, ey)
            last = wps[-1] if wps else (rx, ry)
            p0 = endpoint_on_diamond(rx, ry, RW, RH, *first)
            p1 = endpoint_on_box(ex, ey, EW, EH, *last)
            pts = [p0] + list(wps) + [p1]
            lines.append((pts, total))
            # cardinality label: a little way back from the entity along the last segment
            lx, ly = pts[-2]
            ux, uy = p1[0] - lx, p1[1] - ly
            ln = math.hypot(ux, uy) or 1
            off = min(26, ln / 2)
            px, py = p1[0] - ux / ln * off, p1[1] - uy / ln * off
            labels.append((card, px - uy / ln * 12, py + ux / ln * 12))
        for alabel, dx, dy in rattrs:
            ax, ay = rx + dx, ry + dy
            shapes.append(("relattr", alabel, ax, ay, AW, AH))
            p0 = endpoint_on_ellipse(ax, ay, AW, AH, rx, ry)
            p1 = endpoint_on_diamond(rx, ry, RW, RH, ax, ay)
            lines.append(([p0, p1], False))
    return shapes, lines, labels


def drawio(shapes, lines, labels):
    cells, n = [], 0

    def nid():
        nonlocal n
        n += 1
        return f"chen-{n}"

    cells.append(f'<mxCell id="{nid()}" value={quoteattr(TITLE_TEXT)} '
                 f'style="text;html=1;align=left;verticalAlign=top;whiteSpace=wrap;fontSize=13;" vertex="1" parent="1">'
                 f'<mxGeometry x="20" y="-130" width="1500" height="60" as="geometry"/></mxCell>')
    # lines first so that shapes are drawn on top of them
    for pts, total in lines:
        style = ("endArrow=none;html=1;rounded=0;strokeColor=#333333;"
                 + ("shape=link;width=4;" if total else ""))
        (sx, sy), (tx, ty) = pts[0], pts[-1]
        wp = "".join(f'<mxPoint x="{x:.0f}" y="{y:.0f}"/>' for x, y in pts[1:-1])
        wp = f'<Array as="points">{wp}</Array>' if wp else ""
        cells.append(f'<mxCell id="{nid()}" style="{style}" edge="1" parent="1">'
                     f'<mxGeometry relative="1" as="geometry">'
                     f'<mxPoint x="{sx:.0f}" y="{sy:.0f}" as="sourcePoint"/>'
                     f'<mxPoint x="{tx:.0f}" y="{ty:.0f}" as="targetPoint"/>{wp}</mxGeometry></mxCell>')
    for kind, label, cx, cy, w, h in shapes:
        x, y = cx - w / 2, cy - h / 2
        value = escape(label)
        if kind == "entity":
            style = f"rounded=0;whiteSpace=wrap;html=1;fontStyle=1;fontSize=13;fillColor={ENTITY_FILL};strokeColor={ENTITY_STROKE};"
        elif kind == "weak":
            style = f"shape=ext;double=1;rounded=0;whiteSpace=wrap;html=1;fontStyle=1;fontSize=13;fillColor={ENTITY_FILL};strokeColor={ENTITY_STROKE};"
        elif kind == "rel":
            style = f"rhombus;whiteSpace=wrap;html=1;fontSize=11;fontStyle=1;fillColor={REL_FILL};strokeColor={REL_STROKE};"
        elif kind == "ident":
            style = f"rhombus;double=1;whiteSpace=wrap;html=1;fontSize=11;fontStyle=1;fillColor={REL_FILL};strokeColor={REL_STROKE};"
        else:
            fill = REL_ATTR_FILL if kind == "relattr" else ATTR_FILL
            style = f"ellipse;whiteSpace=wrap;html=1;fontSize=11;fillColor={fill};strokeColor={ATTR_STROKE};"
            if kind == "key":
                value = f"&lt;u&gt;{value}&lt;/u&gt;"
            elif kind == "partial":
                value = (f"&lt;span style=&quot;text-decoration: underline dashed;&quot;&gt;"
                         f"{value}&lt;/span&gt;")
            elif kind == "derived":
                style += "dashed=1;"
        cells.append(f'<mxCell id="{nid()}" value="{value}" style="{style}" vertex="1" parent="1">'
                     f'<mxGeometry x="{x:.0f}" y="{y:.0f}" width="{w}" height="{h}" as="geometry"/></mxCell>')
    for text, x, y in labels:
        cells.append(f'<mxCell id="{nid()}" value="{text}" style="text;html=1;align=center;verticalAlign=middle;'
                     f'fontSize=13;fontStyle=1;fontColor=#b85450;" vertex="1" parent="1">'
                     f'<mxGeometry x="{x - 10:.0f}" y="{y - 10:.0f}" width="20" height="20" as="geometry"/></mxCell>')
    body = "\n".join(cells)
    return ('<mxfile host="app.diagrams.net" version="24.7.17">\n'
            '<diagram id="chen" name="01 Conceptual (Chen)">'
            f'<mxGraphModel dx="1600" dy="1000" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" '
            f'arrows="1" fold="1" page="0" pageScale="1" pageWidth="{W}" pageHeight="{H}" math="0" shadow="0">'
            f'<root><mxCell id="0"/><mxCell id="1" parent="0"/>\n{body}\n</root></mxGraphModel></diagram>\n'
            '</mxfile>\n')


def svg(shapes, lines, labels):
    pad_top = 150
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H + pad_top}" '
           f'viewBox="0 {-pad_top} {W} {H + pad_top}" font-family="Helvetica, Arial, sans-serif">',
           f'<rect x="0" y="{-pad_top}" width="{W}" height="{H + pad_top}" fill="#ffffff"/>',
           f'<text x="20" y="-105" font-size="22" font-weight="bold">HBO Max - Conceptual model (Chen\'s notation)</text>']
    legend = ("18 entities, 24 relationships (7 many-to-many). Rectangle = entity, double rectangle = weak entity, "
              "diamond = relationship, double diamond = identifying relationship,")
    legend2 = ("ellipse = attribute (underlined = key, dashed underline = partial key, dashed ellipse = derived, "
               "ellipse joined to an ellipse = composite). Double line = total participation; 1 / N / M = cardinality.")
    out.append(f'<text x="20" y="-75" font-size="15">{escape(legend)}</text>')
    out.append(f'<text x="20" y="-52" font-size="15">{escape(legend2)}</text>')

    for pts, total in lines:
        if total:
            for off in (-2.5, 2.5):
                seg = []
                for i in range(len(pts) - 1):
                    (x1, y1), (x2, y2) = pts[i], pts[i + 1]
                    ln = math.hypot(x2 - x1, y2 - y1) or 1
                    nx, ny = -(y2 - y1) / ln * off, (x2 - x1) / ln * off
                    seg.append(f"M{x1 + nx:.1f},{y1 + ny:.1f} L{x2 + nx:.1f},{y2 + ny:.1f}")
                out.append(f'<path d="{" ".join(seg)}" stroke="#333" stroke-width="1.3" fill="none"/>')
        else:
            d = " ".join(("M" if i == 0 else "L") + f"{x:.1f},{y:.1f}" for i, (x, y) in enumerate(pts))
            out.append(f'<path d="{d}" stroke="#333" stroke-width="1.3" fill="none"/>')

    for kind, label, cx, cy, w, h in shapes:
        x, y = cx - w / 2, cy - h / 2
        if kind in ("entity", "weak"):
            out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{ENTITY_FILL}" stroke="{ENTITY_STROKE}" stroke-width="1.5"/>')
            if kind == "weak":
                out.append(f'<rect x="{x + 5}" y="{y + 5}" width="{w - 10}" height="{h - 10}" fill="none" stroke="{ENTITY_STROKE}" stroke-width="1.5"/>')
            out.append(f'<text x="{cx}" y="{cy + 5}" font-size="14" font-weight="bold" text-anchor="middle">{escape(label)}</text>')
        elif kind in ("rel", "ident"):
            pts = f"{cx},{y} {x + w},{cy} {cx},{y + h} {x},{cy}"
            out.append(f'<polygon points="{pts}" fill="{REL_FILL}" stroke="{REL_STROKE}" stroke-width="1.5"/>')
            if kind == "ident":
                out.append(f'<polygon points="{cx},{y + 8} {x + w - 14},{cy} {cx},{y + h - 8} {x + 14},{cy}" '
                           f'fill="none" stroke="{REL_STROKE}" stroke-width="1.5"/>')
            out.append(f'<text x="{cx}" y="{cy + 4}" font-size="11" font-weight="bold" text-anchor="middle">{escape(label)}</text>')
        else:
            fill = REL_ATTR_FILL if kind == "relattr" else ATTR_FILL
            dash = ' stroke-dasharray="5,3"' if kind == "derived" else ""
            out.append(f'<ellipse cx="{cx}" cy="{cy}" rx="{w / 2}" ry="{h / 2}" fill="{fill}" stroke="{ATTR_STROKE}" stroke-width="1.2"{dash}/>')
            out.append(f'<text x="{cx}" y="{cy + 4}" font-size="11.5" text-anchor="middle">{escape(label)}</text>')
            if kind in ("key", "partial"):
                tw = len(label) * 6.3
                dash = ' stroke-dasharray="3,2"' if kind == "partial" else ""
                out.append(f'<line x1="{cx - tw / 2}" y1="{cy + 7}" x2="{cx + tw / 2}" y2="{cy + 7}" stroke="#000" stroke-width="1"{dash}/>')
    for text, x, y in labels:
        out.append(f'<text x="{x}" y="{y + 5}" font-size="15" font-weight="bold" fill="#b85450" text-anchor="middle">{text}</text>')
    out.append("</svg>")
    return "\n".join(out)


if __name__ == "__main__":
    shapes, lines, labels = build_scene()
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "01-conceptual-chen.drawio").write_text(drawio(shapes, lines, labels), encoding="utf-8")
    svg_text = svg(shapes, lines, labels)
    rsvg = shutil.which("rsvg-convert")
    if rsvg:
        (OUT / "png").mkdir(exist_ok=True)
        subprocess.run([rsvg, "-f", "png", "-o", str(OUT / "png" / "01-conceptual-chen.png")],
                       input=svg_text.encode("utf-8"), check=True)
    else:
        print("rsvg-convert not found - PNG skipped (open the .drawio and export it instead)")
    print("ok")
