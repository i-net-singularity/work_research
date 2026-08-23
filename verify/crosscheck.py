"""VBA実装のクロスチェック用Python移植.

modTextParser / modPlan のアルゴリズム(インデントスタック解析・
排他時間計算・主要ヒューリスティクス)をPythonで忠実に再実装し、
サンプル実行計画に対して期待値検証を行う。

VBAコードそのものはWindows Excel環境でしか実行できないため、
ここではアルゴリズムの正しさを担保する(ルール1.2.4.2 クロスチェック)。
"""

import json
import re
import sys
from pathlib import Path

SAMPLES = Path(__file__).resolve().parent.parent / "samples"


class Node:
    def __init__(self):
        self.node_type = ""
        self.relation = ""
        self.alias = ""
        self.index = ""
        self.startup_cost = 0.0
        self.total_cost = 0.0
        self.plan_rows = 0.0
        self.actual_total = 0.0
        self.actual_rows = 0.0
        self.loops = 1.0
        self.has_actual = False
        self.rows_removed = 0.0
        self.filter = ""
        self.sort_method = ""
        self.sort_space_type = ""
        self.sort_space_kb = 0.0
        self.children = []
        self.depth = 0
        self.inclusive_ms = 0.0
        self.exclusive_ms = 0.0


def val(s):
    """VBAのVal()相当: 先頭の数値部分のみ解釈する.

    Args:
        s: 対象文字列.

    Returns:
        float: 解釈した数値(なければ0).
    """
    m = re.match(r"\s*[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?", s)
    return float(m.group(0)) if m else 0.0


def after_token(s, token):
    p = s.find(token)
    return "" if p < 0 else s[p + len(token):]


def seg_between(s, marker, closer):
    p = s.find(marker)
    if p < 0:
        return ""
    st = p + len(marker)
    e = s.find(closer, st)
    if e < 0:
        e = len(s)
    return s[st:e]


def clean_line(line):
    """modTextParser.cleanLine のPython移植."""
    s = line.rstrip("\r")
    t = s.strip()
    if t == "QUERY PLAN":
        return ""
    if t and t.replace("-", "") == "":
        return ""
    if t.startswith("(") and "cost=" not in t and "actual" not in t:
        if "row)" in t or "rows)" in t or "行)" in t:
            return ""
    r = s.rstrip()
    if r.endswith("+"):
        s = r[:-1]
    return s


def parse_node_line(line):
    node = Node()
    s = line.strip()
    if s.startswith("->"):
        s = s[2:].strip()

    c_pos = s.find("(cost=")
    a_pos = s.find("(actual")
    cut = c_pos if c_pos >= 0 else a_pos
    head = s[:cut].rstrip() if cut >= 0 else s

    using_pos = head.find(" using ")
    on_pos = head.find(" on ")
    if using_pos >= 0 and on_pos > using_pos:
        node.node_type = head[:using_pos]
        node.index = head[using_pos + 7:on_pos]
        rel = head[on_pos + 4:].split()
        node.relation = rel[0] if rel else ""
        node.alias = rel[1] if len(rel) > 1 else ""
    elif on_pos >= 0:
        node.node_type = head[:on_pos]
        rel = head[on_pos + 4:].split()
        node.relation = rel[0] if rel else ""
        node.alias = rel[1] if len(rel) > 1 else ""
    else:
        node.node_type = head

    seg = seg_between(s, "(cost=", ")")
    if seg:
        node.startup_cost = val(seg)
        node.total_cost = val(after_token(seg, ".."))
        node.plan_rows = val(after_token(seg, "rows="))
    seg = seg_between(s, "(actual ", ")")
    if seg:
        node.has_actual = True
        if "time=" in seg:
            node.actual_total = val(after_token(after_token(seg, "time="), ".."))
        node.actual_rows = val(after_token(seg, "rows="))
        node.loops = val(after_token(seg, "loops="))
    return node


def parse_text_plan(raw):
    """modTextParser.parseTextPlan のPython移植."""
    root = None
    stack = []  # (indent, node)
    planning_ms = execution_ms = -1.0
    footer = False

    for line in raw.replace("\r\n", "\n").split("\n"):
        line = clean_line(line)
        t = line.strip()
        if not t:
            continue
        if t.startswith("Planning Time:"):
            planning_ms = val(after_token(t, "Planning Time:"))
            continue
        if t.startswith("Execution Time:"):
            execution_ms = val(after_token(t, "Execution Time:"))
            continue
        if t.startswith(("Planning:", "JIT:", "Triggers:", "Query Identifier:")):
            footer = True
            continue
        if footer:
            continue

        if root is None:
            root = parse_node_line(line)
            stack = [(1, root)]
        elif t.startswith("->"):
            ind = line.find("->") + 1  # VBAのInStrは1始まり
            while stack and stack[-1][0] >= ind:
                stack.pop()
            assert stack, "インデント構造の解釈に失敗"
            parent = stack[-1][1]
            node = parse_node_line(line)
            node.depth = parent.depth + 1
            parent.children.append(node)
            stack.append((ind, node))
        else:
            node = stack[-1][1]
            if t.startswith("Rows Removed by Filter:"):
                node.rows_removed = val(after_token(t, "Rows Removed by Filter:"))
            elif t.startswith("Filter:"):
                node.filter = after_token(t, "Filter:").strip()
            elif t.startswith("Sort Method"):
                node.sort_method = after_token(t, ":").strip()
                if "Disk:" in t:
                    node.sort_space_type = "Disk"
                    node.sort_space_kb = val(after_token(t, "Disk:"))

    return root, planning_ms, execution_ms


def compute_metrics(node):
    node.inclusive_ms = node.actual_total * node.loops if node.has_actual else 0.0
    child_ms = 0.0
    for c in node.children:
        compute_metrics(c)
        child_ms += c.inclusive_ms
    node.exclusive_ms = max(0.0, node.inclusive_ms - child_ms)


def flatten(node, out):
    out.append(node)
    for c in node.children:
        flatten(c, out)


def check(cond, msg):
    status = "OK " if cond else "NG "
    print(f"  [{status}] {msg}")
    return cond


def main():
    ok = True
    print("=== テキスト形式パーサ検証 ===")
    raw = (SAMPLES / "sample_text_plan.txt").read_text(encoding="utf-8")
    root, planning, execution = parse_text_plan(raw)
    flat = []
    flatten(root, flat)
    compute_metrics(root)

    ok &= check(root.node_type == "Sort", f"ルート=Sort (実際: {root.node_type})")
    ok &= check(len(flat) == 4, f"ノード数=4 (実際: {len(flat)})")
    ok &= check(root.children[0].node_type == "Nested Loop",
                f"Sortの子=Nested Loop (実際: {root.children[0].node_type})")
    nl = root.children[0]
    ok &= check(len(nl.children) == 2, f"Nested Loopの子=2 (実際: {len(nl.children)})")
    ok &= check(nl.children[0].relation == "orders" and nl.children[0].alias == "o",
                f"外側=orders o (実際: {nl.children[0].relation} {nl.children[0].alias})")
    ok &= check(nl.children[1].relation == "customers",
                f"内側=customers (実際: {nl.children[1].relation})")
    ok &= check(nl.children[1].loops == 185000,
                f"内側loops=185000 (実際: {nl.children[1].loops})")
    ok &= check(nl.children[0].rows_removed == 815000,
                f"ordersの除去行=815000 (実際: {nl.children[0].rows_removed})")
    ok &= check(root.sort_space_type == "Disk" and root.sort_space_kb == 18432,
                f"Sortディスクスピル18432kB (実際: {root.sort_space_type} {root.sort_space_kb})")
    ok &= check(planning == 0.512 and execution == 1350.882,
                f"Planning/Execution Time (実際: {planning}/{execution})")
    ok &= check(root.plan_rows == 40000 and root.actual_rows == 185000,
                f"ルート見積40000/実際185000 (実際: {root.plan_rows}/{root.actual_rows})")

    # 排他時間: Sort = 1305.334*1 - 980.221*1 = 325.113
    ok &= check(abs(root.exclusive_ms - 325.113) < 0.001,
                f"Sort排他時間=325.113ms (実際: {root.exclusive_ms:.3f})")
    # 内側SeqScan累積 = 0.003 * 185000 = 555ms
    ok &= check(abs(nl.children[1].inclusive_ms - 555.0) < 0.001,
                f"内側SeqScan累積=555ms (実際: {nl.children[1].inclusive_ms:.3f})")
    # NestedLoop排他 = 980.221 - 250.115 - 555.0 = 175.106
    ok &= check(abs(nl.exclusive_ms - 175.106) < 0.001,
                f"NestedLoop排他=175.106ms (実際: {nl.exclusive_ms:.3f})")

    print("\n=== ヒューリスティクス発火検証(テキスト形式由来のツリー) ===")
    # 見積誤差: root 185000/40000 = 4.6倍 → 10倍未満で非発火,
    #           orders 185000/4000 = 46.25倍 → 発火(中)
    orders = nl.children[0]
    factor = orders.actual_rows / orders.plan_rows
    ok &= check(10 <= factor < 100, f"orders見積誤差46.25倍→重大度中の帯域 (実際: {factor:.2f})")
    # SeqScanフィルタ: 815000除去/採用185000 → 除去率81.5% ≥ 50% & ≥10000行 → 発火
    sel = orders.rows_removed / (orders.rows_removed + orders.actual_rows)
    ok &= check(sel >= 0.5 and orders.rows_removed >= 10000,
                f"SeqScanフィルタ指摘発火条件 (除去率: {sel:.1%})")
    # NestedLoop内側SeqScan: loops=185000 ≥ 1000 → 発火(高)
    ok &= check(nl.children[1].loops >= 1000 and "Seq Scan" in nl.children[1].node_type,
                "NestedLoop内側SeqScan指摘発火条件")
    # Sortディスクスピル → 発火(高), work_mem提案 = 18432/1024*1.5 = 27MB
    wm = max(8, round(18432 / 1024 * 1.5))
    ok &= check(wm == 27, f"work_mem提案=27MB (実際: {wm})")

    print("\n=== JSON形式の等価性検証 ===")
    jraw = (SAMPLES / "sample_json_plan.json").read_text(encoding="utf-8")
    jdata = json.loads(jraw)
    top = jdata[0]
    ok &= check("Plan" in top and "Execution Time" in top, "JSONルート構造(Plan/Execution Time)")

    def walk_json(d, depth=0):
        n = Node()
        n.node_type = d.get("Node Type", "")
        n.relation = d.get("Relation Name", "")
        n.alias = d.get("Alias", "")
        n.plan_rows = float(d.get("Plan Rows", 0))
        n.actual_total = float(d.get("Actual Total Time", 0))
        n.actual_rows = float(d.get("Actual Rows", 0))
        n.loops = float(d.get("Actual Loops", 1))
        n.has_actual = "Actual Loops" in d or "Actual Rows" in d
        n.rows_removed = float(d.get("Rows Removed by Filter", 0))
        n.sort_space_type = d.get("Sort Space Type", "")
        n.sort_space_kb = float(d.get("Sort Space Used", 0))
        n.depth = depth
        for cd in d.get("Plans", []):
            n.children.append(walk_json(cd, depth + 1))
        return n

    jroot = walk_json(top["Plan"])
    compute_metrics(jroot)
    jflat = []
    flatten(jroot, jflat)

    # テキスト版とJSON版で同一クエリのツリーが一致するか
    ok &= check(len(jflat) == len(flat), f"ノード数一致 text={len(flat)} json={len(jflat)}")
    for a, b in zip(flat, jflat):
        pair_ok = (a.node_type == b.node_type and a.relation == b.relation
                   and a.plan_rows == b.plan_rows and a.loops == b.loops
                   and abs(a.exclusive_ms - b.exclusive_ms) < 0.001)
        ok &= check(pair_ok, f"ノード等価: {a.node_type} "
                             f"(excl {a.exclusive_ms:.3f} vs {b.exclusive_ms:.3f})")

    # psql整形出力からのJSON貼り付け("+"継続行)の除去ロジック検証
    print("\n=== psql整形出力ノイズ除去の検証 ===")
    psql_style = ("      QUERY PLAN      \n"
                  "----------------------\n"
                  ' [                   +\n'
                  '   {                 +\n'
                  '     "Plan": {       +\n'
                  '       "Node Type": "Result"+\n'
                  "     }               +\n"
                  "   }                 +\n"
                  " ]\n"
                  "(1 row)\n")
    cleaned = "\n".join(clean_line(l) for l in psql_style.split("\n") if clean_line(l))
    try:
        j = json.loads(cleaned)
        ok &= check(j[0]["Plan"]["Node Type"] == "Result", "psql貼り付けJSONの復元")
    except json.JSONDecodeError as e:
        ok &= check(False, f"psql貼り付けJSONの復元失敗: {e}")

    print()
    if ok:
        print("★ 全チェックOK")
        return 0
    print("★ 失敗あり — VBA側の該当ロジックを修正すること")
    return 1


if __name__ == "__main__":
    sys.exit(main())
