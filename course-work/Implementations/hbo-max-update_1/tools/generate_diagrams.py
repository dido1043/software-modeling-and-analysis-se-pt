#!/usr/bin/env python3
"""
Generate the course-work diagrams straight from the SQL DDL, so the diagrams can
never drift from the scripts:

    docs/diagrams/02-logical-crowsfoot.drawio   logical model, Crow's Foot notation
    docs/diagrams/03-dw-physical-uml.drawio     DW physical model, UML notation
                                                (constellation + one star per fact + ETL)

Usage
    python tools/generate_diagrams.py                 # defaults: src/ -> docs/diagrams/
    python tools/generate_diagrams.py SRC_DIR OUT_DIR

Open the .drawio files in draw.io / diagrams.net (desktop, web or the VS Code
extension). Standard library only.
"""
import sys
from html import escape
from xml.sax.saxutils import quoteattr
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / "src")
OUT = sys.argv[2] if len(sys.argv) > 2 else str(ROOT / "docs" / "diagrams")

# ---- DDL parser -------------------------------------------------------------
def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    return re.sub(r"--[^\n]*", "", t)


def split_commas(body):
    out, depth, cur = [], 0, ""
    for ch in body:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip()); cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def body_after(text, i):
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return text[i + 1:j]
    raise ValueError


def cols_of(s):
    return [c.strip().strip("[]") for c in s.split(",")]


def parse(paths):
    tables = {}
    for p in paths:
        txt = strip_comments(Path(p).read_text(encoding="utf-8"))
        for m in re.finditer(r"CREATE\s+TABLE\s+([\[\]\w]+)\.([\[\]\w]+)\s*\(", txt, re.I):
            schema, name = m.group(1).strip("[]"), m.group(2).strip("[]")
            body = body_after(txt, m.end() - 1)
            t = {"schema": schema, "name": name, "columns": [], "pk": [], "fks": [], "uniques": []}
            for part in split_commas(body):
                up = part.upper()
                cm = re.match(r"CONSTRAINT\s+\w+\s+(.*)", part, re.I | re.S)
                rest = cm.group(1) if cm else part
                ru = rest.upper()
                if ru.startswith("PRIMARY KEY"):
                    t["pk"] = cols_of(re.search(r"\(([^)]*)\)", rest).group(1))
                elif ru.startswith("FOREIGN KEY"):
                    fm = re.match(r"FOREIGN\s+KEY\s*\(([^)]*)\)\s*REFERENCES\s+([\[\]\w]+)\.([\[\]\w]+)\s*\(([^)]*)\)",
                                  rest, re.I | re.S)
                    t["fks"].append({"cols": cols_of(fm.group(1)),
                                     "ref": f"{fm.group(2).strip('[]')}.{fm.group(3).strip('[]')}",
                                     "refcols": cols_of(fm.group(4)),
                                     "cascade": "ON DELETE CASCADE" in ru})
                elif ru.startswith("UNIQUE"):
                    t["uniques"].append(cols_of(re.search(r"\(([^)]*)\)", rest).group(1)))
                elif ru.startswith(("CHECK", "INDEX")) or cm:
                    continue
                else:
                    cmatch = re.match(r"([\[\]\w]+)\s+(.*)", part, re.S)
                    cname = cmatch.group(1).strip("[]")
                    spec = " ".join(cmatch.group(2).split())
                    if spec.upper().startswith("AS "):
                        ctype, nullable, computed = "computed", True, True
                    else:
                        tm = re.match(r"(\w+(?:\s*\([^)]*\))?)", spec)
                        ctype = tm.group(1).replace(" ", "").upper()
                        nullable = "NOT NULL" not in spec.upper()
                        computed = False
                    t["columns"].append({"name": cname, "type": ctype, "nullable": nullable,
                                         "computed": computed,
                                         "identity": "IDENTITY" in spec.upper()})
            tables[f"{schema}.{name}"] = t
    return tables


# ---- drawing ----------------------------------------------------------------
ROW_H = 20
HEAD_H = 30

SCHEMA_COLORS = {          # fill, stroke  (header)
    "geo":   ("#dae8fc", "#6c8ebf"),
    "acct":  ("#d5e8d4", "#82b366"),
    "cat":   ("#fff2cc", "#d6b656"),
    "play":  ("#f8cecc", "#b85450"),
    "bill":  ("#e1d5e7", "#9673a6"),
    "audit": ("#f5f5f5", "#666666"),
}


class Page:
    def __init__(self, name, pid):
        self.name, self.pid, self.cells, self.n = name, pid, [], 0

    def nid(self, prefix="c"):
        self.n += 1
        return f"{self.pid}-{prefix}{self.n}"

    def add(self, xml):
        self.cells.append(xml)

    def xml(self, w=4000, h=3000):
        body = "\n".join(self.cells)
        return (f'<diagram id="{self.pid}" name={quoteattr(self.name)}>'
                f'<mxGraphModel dx="1600" dy="1000" grid="1" gridSize="10" guides="1" tooltips="1" '
                f'connect="1" arrows="1" fold="1" page="0" pageScale="1" pageWidth="{w}" '
                f'pageHeight="{h}" math="0" shadow="0"><root><mxCell id="0"/>'
                f'<mxCell id="1" parent="0"/>\n{body}\n</root></mxGraphModel></diagram>')


def write_file(path, pages):
    with open(path, "w", encoding="utf-8") as f:
        f.write('<mxfile host="app.diagrams.net" agent="generated from DDL" version="24.7.17">\n')
        for p in pages:
            f.write(p.xml() + "\n")
        f.write("</mxfile>\n")


def text_cell(page, value, x, y, w, h, style):
    page.add(f'<mxCell id="{page.nid("t")}" value={quoteattr(value)} style="{style}" vertex="1" parent="1">'
             f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')


# --------------------------------------------------------------------------
# Crow's Foot (logical model)
# --------------------------------------------------------------------------
def crow_table(page, t, x, y, w=270):
    """draw.io ER table. Returns {column name: row id} and the box height."""
    fill, stroke = SCHEMA_COLORS.get(t["schema"], ("#ffffff", "#000000"))
    fkcols = {c for fk in t["fks"] for c in fk["cols"]}
    cols = [c for c in t["columns"] if not c["computed"]]
    h = HEAD_H + ROW_H * len(cols)
    tid = page.nid("tbl")
    page.add(f'<mxCell id="{tid}" value={quoteattr(t["name"].upper())} style="shape=table;startSize={HEAD_H};'
             f'container=1;collapsible=0;childLayout=tableLayout;fixedRows=1;rowLines=0;fontStyle=1;'
             f'align=center;resizeLast=1;html=1;fillColor={fill};strokeColor={stroke};fontSize=12;" '
             f'vertex="1" parent="1"><mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')
    rows = {}
    for i, c in enumerate(cols):
        rid = page.nid("r")
        rows[c["name"]] = rid
        is_pk = c["name"] in t["pk"]
        key = "PK,FK" if is_pk and c["name"] in fkcols else "PK" if is_pk else "FK" if c["name"] in fkcols else ""
        bottom = "1" if is_pk and (i + 1 == len(cols) or cols[i + 1]["name"] not in t["pk"]) else "0"
        label = escape(c["name"])
        if is_pk:
            label = f"<u>{label}</u>"
        if not c["nullable"] and not is_pk:
            label = f"<b>{label}</b>"
        label += f' <font color="#808080">{escape(c["type"].lower())}</font>'
        page.add(f'<mxCell id="{rid}" value="" style="shape=tableRow;horizontal=0;startSize=0;swimlaneHead=0;'
                 f'swimlaneBody=0;fillColor=none;collapsible=0;dropTarget=0;points=[[0,0.5],[1,0.5]];'
                 f'portConstraint=eastwest;top=0;left=0;right=0;bottom={bottom};html=1;" vertex="1" parent="{tid}">'
                 f'<mxGeometry y="{HEAD_H + i * ROW_H}" width="{w}" height="{ROW_H}" as="geometry"/></mxCell>')
        page.add(f'<mxCell id="{page.nid("k")}" value={quoteattr(key)} style="shape=partialRectangle;connectable=0;'
                 f'fillColor=none;top=0;left=0;bottom=0;right=0;fontStyle=1;overflow=hidden;html=1;fontSize=10;" '
                 f'vertex="1" parent="{rid}"><mxGeometry width="44" height="{ROW_H}" as="geometry">'
                 f'<mxRectangle width="44" height="{ROW_H}" as="alternateBounds"/></mxGeometry></mxCell>')
        page.add(f'<mxCell id="{page.nid("v")}" value={quoteattr(label)} style="shape=partialRectangle;connectable=0;'
                 f'fillColor=none;top=0;left=0;bottom=0;right=0;align=left;spacingLeft=6;overflow=hidden;html=1;'
                 f'fontSize=11;" vertex="1" parent="{rid}"><mxGeometry x="44" width="{w - 44}" height="{ROW_H}" '
                 f'as="geometry"><mxRectangle width="{w - 44}" height="{ROW_H}" as="alternateBounds"/>'
                 f'</mxGeometry></mxCell>')
    return rows, h


def crow_edge(page, src_row, dst_row, child_end, parent_end):
    page.add(f'<mxCell id="{page.nid("e")}" style="edgeStyle=entityRelationEdgeStyle;fontSize=12;html=1;'
             f'endArrow={parent_end};startArrow={child_end};endFill=0;startFill=0;rounded=0;'
             f'strokeColor=#555555;" edge="1" parent="1" source="{src_row}" target="{dst_row}">'
             f'<mxGeometry relative="1" as="geometry"/></mxCell>')


def logical_diagram(tables):
    page = Page("02 Logical (Crow's Foot)", "logical")
    layout = [
        ["cat.Genre", "cat.Person", "cat.Studio"],
        ["cat.TitleGenre", "cat.Credit", "cat.TitleLanguageTrack", "cat.Language"],
        ["cat.Title", "cat.Season", "cat.Episode", "cat.TitleAvailability"],
        ["play.WatchSession", "play.Watchlist", "play.Review", "play.Download"],
        ["acct.Profile", "acct.Device", "geo.Country"],
        ["acct.Subscriber", "acct.Plan", "audit.SubscriptionChangeLog"],
        ["acct.Subscription", "bill.SubscriptionCoupon", "bill.Coupon"],
        ["bill.PaymentMethod", "bill.Invoice", "bill.Payment"],
    ]
    placed = {t for col in layout for t in col}
    assert placed == set(tables), set(tables) ^ placed
    text_cell(page, "<b>HBO Max - Logical data model (Crow's Foot notation)</b><br>"
              "27 entities - 3NF - generated from src/oltp/02_tables.sql. "
              "<u>Underlined</u> = primary key, <b>bold</b> = mandatory (NOT NULL), grey = SQL Server type.",
              40, 0, 1400, 50, "text;html=1;align=left;verticalAlign=middle;fontSize=16;")
    legend_y = 60
    for i, (s, (fill, stroke)) in enumerate(SCHEMA_COLORS.items()):
        text_cell(page, s, 40 + i * 110, legend_y, 100, 26,
                  f"rounded=1;whiteSpace=wrap;html=1;fillColor={fill};strokeColor={stroke};fontStyle=1;")
    text_cell(page, "Relationship ends:  ||  exactly one    o|  zero or one    o&lt;  zero or many",
              720, legend_y, 520, 26, "text;html=1;align=left;fontSize=12;")
    rows = {}
    col_w, gap_x, gap_y, top = 270, 170, 50, 130
    for ci, col in enumerate(layout):
        y = top
        for name in col:
            r, h = crow_table(page, tables[name], 40 + ci * (col_w + gap_x), y, col_w)
            rows[name] = r
            y += h + gap_y
    for name, t in tables.items():
        for fk in t["fks"]:
            child_col = fk["cols"][0]
            parent = fk["ref"]
            parent_row = rows[parent][fk["refcols"][0]]
            nullable = any(c["nullable"] for c in t["columns"] if c["name"] in fk["cols"])
            parent_end = "ERzeroToOne" if nullable else "ERmandOne"
            one_to_one = fk["cols"] == t["pk"] or fk["cols"] in t["uniques"]
            child_end = "ERzeroToOne" if one_to_one else "ERzeroToMany"
            crow_edge(page, rows[name][child_col], parent_row, child_end, parent_end)
    return page


# --------------------------------------------------------------------------
# UML (DW physical model)
# --------------------------------------------------------------------------
KIND_STYLE = {
    "fact":      ("#ffe6cc", "#d79b00", "fact table"),
    "dimension": ("#dae8fc", "#6c8ebf", "dimension"),
    "etl":       ("#f5f5f5", "#666666", "etl table"),
}


def uml_kind(t):
    if t["schema"] == "etl":
        return "etl"
    return "fact" if t["name"].startswith("Fact") else "dimension"


ATTR_H = 16


def uml_class(page, t, x, y, w=330, show_cols=None, role=""):
    """UML class box: one child cell per attribute. Returns (box id, height, {col: cell id})."""
    kind = uml_kind(t)
    fill, stroke, stereo = KIND_STYLE[kind]
    fkcols = {c for fk in t["fks"] for c in fk["cols"]}
    uq = {c for u in t["uniques"] for c in u}
    cols = t["columns"] if show_cols is None else [c for c in t["columns"] if c["name"] in show_cols]
    head = 44
    h = head + ATTR_H * len(cols) + 6
    cid = page.nid("cls")
    title = f"«{stereo}»<br><b>{escape(t['schema'])}.{escape(t['name'])}</b>"
    if role:
        title += f' <font color="#1a4d8f">as «{escape(role)}»</font>'
    page.add(f'<mxCell id="{cid}" value={quoteattr(title)} style="swimlane;fontStyle=0;align=center;'
             f'verticalAlign=top;childLayout=stackLayout;horizontal=1;startSize={head};horizontalStack=0;'
             f'resizeParent=1;resizeParentMax=0;resizeLast=0;collapsible=0;marginBottom=6;html=1;'
             f'fillColor={fill};strokeColor={stroke};swimlaneFillColor=#ffffff;fontSize=12;" vertex="1" '
             f'parent="1"><mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')
    cells = {}
    for i, c in enumerate(cols):
        tags = []
        if c["name"] in t["pk"]:
            tags.append("PK")
        if c["name"] in fkcols:
            tags.append("FK")
        if c["name"] in uq and c["name"] not in t["pk"]:
            tags.append("UQ")
        tag = f"«{','.join(tags)}» " if tags else ""
        vis = "+" if c["name"] in t["pk"] else "#" if c["name"] in fkcols else "-"
        typ = "computed, persisted" if c["computed"] else c["type"]
        nn = "" if c["nullable"] or c["computed"] else " NOT NULL"
        line = escape(f"{vis} {tag}{c['name']} : {typ}{nn}")
        if c["name"] in t["pk"] or c["name"] in fkcols:
            line = f"<b>{line}</b>"
        aid = page.nid("a")
        cells[c["name"]] = aid
        page.add(f'<mxCell id="{aid}" value={quoteattr(line)} style="text;strokeColor=none;fillColor=none;'
                 f'align=left;verticalAlign=middle;spacingLeft=6;spacingRight=4;overflow=hidden;rotatable=0;'
                 f'points=[[0,0.5],[1,0.5]];portConstraint=eastwest;html=1;fontSize=11;'
                 f'fontFamily=Courier New;" vertex="1" parent="{cid}">'
                 f'<mxGeometry y="{head + i * ATTR_H}" width="{w}" height="{ATTR_H}" as="geometry"/></mxCell>')
    return cid, h, cells


def uml_edge(page, src, dst, role, style_extra, points, label_x=0.8):
    eid = page.nid("as")
    pts = "".join(f'<mxPoint x="{px}" y="{py}"/>' for px, py in points)
    pts = f'<Array as="points">{pts}</Array>' if pts else ""
    page.add(f'<mxCell id="{eid}" value="" style="endArrow=none;html=1;edgeStyle=orthogonalEdgeStyle;'
             f'rounded=0;strokeColor=#6c8ebf;{style_extra}" edge="1" parent="1" source="{src}" target="{dst}">'
             f'<mxGeometry relative="1" as="geometry">{pts}</mxGeometry></mxCell>')
    fact_label = "0..*" if not role else f"0..* «{escape(role)}»"
    page.add(f'<mxCell id="{page.nid("m")}" value={quoteattr(fact_label)} style="edgeLabel;resizable=0;html=1;fontSize=10;'
             f'labelBackgroundColor=#ffffff;" connectable="0" vertex="1" parent="{eid}">'
             f'<mxGeometry x="-0.85" relative="1" as="geometry"><mxPoint as="offset"/></mxGeometry></mxCell>')
    dim_label = "1"
    page.add(f'<mxCell id="{page.nid("m")}" value={quoteattr(dim_label)} style="edgeLabel;resizable=0;html=1;'
             f'fontSize=10;labelBackgroundColor=#ffffff;fontColor=#1a4d8f;" connectable="0" vertex="1" '
             f'parent="{eid}"><mxGeometry x="{label_x}" relative="1" as="geometry"><mxPoint as="offset"/>'
             f'</mxGeometry></mxCell>')


DIM_PK = {}


def role_name(fk, dim):
    """A role is named only when the fact's FK column is not the dimension's own key name."""
    col = fk["cols"][0]
    return "" if col == DIM_PK.get(dim) else col.replace("Key", "")


def dw_overview(tables):
    page = Page("03 DW physical (UML) - constellation", "dwall")
    dims_top = ["dw.DimDate", "dw.DimTimeOfDay", "dw.DimProfile", "dw.DimSubscriber", "dw.DimTitle"]
    dims_bot = ["dw.DimGenre", "dw.DimDevice", "dw.DimGeography", "dw.DimPlan", "dw.DimPaymentMethod"]
    facts = ["dw.FactViewingSession", "dw.FactSubscriptionMonthlySnapshot", "dw.FactRevenue",
             "dw.FactTitleRating", "dw.FactCatalogAvailabilitySnapshot"]
    text_cell(page, "<b>HBO Max - Data Warehouse physical model (UML database notation)</b><br>"
              "Fact constellation: 5 fact tables (orange) share 10 conformed dimensions (blue). Generated from "
              "src/dw/11_dw_dimensions.sql and 12_dw_facts.sql.<br>"
              "+ primary key, # foreign key, - attribute. Multiplicity: each fact row references exactly 1 row "
              "of a dimension; a dimension row is referenced by 0..* fact rows. «Role» names a role-playing "
              "dimension (DimDate is used several times by the same fact).",
              40, 0, 2300, 70, "text;html=1;align=left;verticalAlign=middle;fontSize=15;whiteSpace=wrap;")
    w, gx = 400, 100
    col_x = [40 + i * (w + gx) for i in range(5)]
    geo, ids, cells = {}, {}, {}
    top_y = 110
    for i, n in enumerate(dims_top):
        ids[n], h, cells[n] = uml_class(page, tables[n], col_x[i], top_y, w)
        geo[n] = (col_x[i], top_y, w, h)
    # edge plan --------------------------------------------------------------
    edges = []   # (fact, dim, fk)
    for f in facts:
        for fk in tables[f]["fks"]:
            edges.append((f, fk["ref"], fk))
    top_edges = [e for e in edges if e[1] in dims_top]
    bot_edges = [e for e in edges if e[1] in dims_bot]
    band = 16
    max_top = max(geo[n][1] + geo[n][3] for n in dims_top)
    fy = max_top + 60 + band * (len(top_edges) + 1)
    for i, n in enumerate(facts):
        ids[n], h, cells[n] = uml_class(page, tables[n], col_x[i], fy, w)
        geo[n] = (col_x[i], fy, w, h)
    max_fact = max(geo[n][1] + geo[n][3] for n in facts)
    by = max_fact + 60 + band * (len(bot_edges) + 1)
    for i, n in enumerate(dims_bot):
        ids[n], h, cells[n] = uml_class(page, tables[n], col_x[i], by, w)
        geo[n] = (col_x[i], by, w, h)

    def ports(group, end_index, key, lo, hi):
        """distribute attachment points along a box edge, ordered by the other end's x."""
        out = {}
        by_box = {}
        for e in group:
            by_box.setdefault(e[end_index], []).append(e)
        for box, es in by_box.items():
            es.sort(key=key)
            for k, e in enumerate(es):
                out[(id(e), end_index)] = lo + (hi - lo) * (k + 1) / (len(es) + 1)
        return out

    for group, top in ((top_edges, True), (bot_edges, False)):
        # fact and dimension in the same column must not share an x position
        ex = ports(group, 0, lambda e: geo[e[1]][0], *((0.5, 1.0) if top else (0.0, 0.5)))
        en = ports(group, 1, lambda e: geo[e[0]][0], *((0.0, 0.5) if top else (0.5, 1.0)))
        # horizontal lanes: longest spans furthest from the facts, so verticals cross fewer lanes
        order = sorted(group, key=lambda e: abs(geo[e[0]][0] - geo[e[1]][0]), reverse=not top)
        for lane, e in enumerate(order):
            f, d, fk = e
            fx_, fy_, fw, fh = geo[f]
            dx_, dy_, dw_, dh_ = geo[d]
            exf, enf = ex[(id(e), 0)], en[(id(e), 1)]
            if top:
                lane_y = max_top + 30 + band * (lane + 1)
                style = f"exitX={exf:.3f};exitY=0;exitDx=0;exitDy=0;entryX={enf:.3f};entryY=1;entryDx=0;entryDy=0;"
            else:
                lane_y = max_fact + 30 + band * (lane + 1)
                style = f"exitX={exf:.3f};exitY=1;exitDx=0;exitDy=0;entryX={enf:.3f};entryY=0;entryDx=0;entryDy=0;"
            pts = [(round(fx_ + fw * exf), lane_y), (round(dx_ + dw_ * enf), lane_y)]
            uml_edge(page, ids[f], ids[d], role_name(fk, d), style, pts)
    return page


def dw_star(tables, fact, idx):
    """One fact in the middle; one box per FK (a role-playing dimension gets a box per role)."""
    short = fact.split(".")[1]
    page = Page(f"03.{idx} Star - {short}", f"star{idx}")
    text_cell(page, f"<b>Star schema - dw.{short}</b><br>Each line joins a foreign key of the fact to the "
              f"primary key of a dimension. A dimension used in several roles (role-playing) is drawn once per "
              f"role. Dimensions show their keys, natural key and SCD columns only - full definitions are on "
              f"the constellation page.", 40, 0, 1700, 50,
              "text;html=1;align=left;verticalAlign=middle;fontSize=14;whiteSpace=wrap;")
    fks = tables[fact]["fks"]
    fw, dw_ = 420, 380
    left, right = fks[0::2], fks[1::2]
    left_x = 40
    fx = left_x + dw_ + 140
    right_x = fx + fw + 140
    fy = 90
    fid, fh, fcells = uml_class(page, tables[fact], fx, fy, fw)
    fcols = [c["name"] for c in tables[fact]["columns"]]
    spacing = 100 / max(len(left), len(right), 1)
    for side, xs in ((left, left_x), (right, right_x)):
        y = fy
        for i, fk in enumerate(side):
            d = fk["ref"]
            t = tables[d]
            keep = set(t["pk"])
            keep |= {c["name"] for c in t["columns"] if c["name"] in
                     ("RowEffectiveFrom", "RowEffectiveTo", "IsCurrent", "RowVersion", "FullDate",
                      "MonthKey", "MonthYearLabel", "Hour24", "DayPart")}
            keep |= set([c["name"] for c in t["columns"] if c["name"] not in t["pk"]][:2])
            role = role_name(fk, d)
            _, h, dc = uml_class(page, t, xs, y, dw_, keep, role)
            if side is left:
                style = "exitX=0;exitY=0.5;exitDx=0;exitDy=0;entryX=1;entryY=0.5;entryDx=0;entryDy=0;"
            else:
                style = "exitX=1;exitY=0.5;exitDx=0;exitDy=0;entryX=0;entryY=0.5;entryDx=0;entryDy=0;"
            kept = [c["name"] for c in t["columns"] if c["name"] in keep]
            ty = y + 44 + ATTR_H * kept.index(t["pk"][0]) + ATTR_H / 2
            sy = fy + 44 + ATTR_H * fcols.index(fk["cols"][0]) + ATTR_H / 2
            lane = (left_x + dw_ + 20 + spacing * i) if side is left else (right_x - 20 - spacing * i)
            uml_edge(page, fcells[fk["cols"][0]], dc[t["pk"][0]], "", style,
                     [(round(lane), round(sy)), (round(lane), round(ty))])
            y += h + 30
    return page


def etl_page(tables):
    page = Page("03.6 ETL control and staging", "etl")
    text_cell(page, "<b>ETL schema</b> - load audit, incremental watermarks and staging tables "
              "(src/dw/13_etl_staging.sql). No foreign keys by design: staging is truncated every run.",
              40, 0, 1500, 40, "text;html=1;align=left;verticalAlign=middle;fontSize=14;whiteSpace=wrap;")
    names = list(tables)
    x, y, w = 40, 70, 380
    for i, n in enumerate(names):
        cid, h, _ = uml_class(page, tables[n], 40 + (i % 4) * (w + 60), 70 + (i // 4) * 620, w)
    return page


if __name__ == "__main__":
    oltp = parse([f"{SRC}/oltp/02_tables.sql"])
    write_file(f"{OUT}/02-logical-crowsfoot.drawio", [logical_diagram(oltp)])
    dw = parse([f"{SRC}/dw/11_dw_dimensions.sql", f"{SRC}/dw/12_dw_facts.sql"])
    DIM_PK.update({n: t["pk"][0] for n, t in dw.items() if n.startswith("dw.Dim")})
    etl = parse([f"{SRC}/dw/13_etl_staging.sql"])
    facts = [n for n in dw if n.startswith("dw.Fact")]
    pages = [dw_overview(dw)] + [dw_star(dw, f, i + 1) for i, f in enumerate(facts)] + [etl_page(etl)]
    write_file(f"{OUT}/03-dw-physical-uml.drawio", pages)
    print("ok")
