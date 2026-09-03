# The python clause of check-sugar-surface's template-prop sweep
# (docs/tpl-props-plan.md P2). Reads the CLASS STRUCTURE with `ast`: a
# file-scoped grep cannot tell a method on `Widget` from one a node can
# reach. Takes the binding path, so the gate keeps its one list of paths.
#
# TWO STRUCTURES, NOT ONE: most props are METHODS ON THE SHARED BASE, so
# one drifting up into `Widget` leaves the template zone silently, while
# `inset` is a CONSTRUCTOR KEYWORD whose three-link chain (kwarg ->
# passed -> zone-agnostic `_widget`) can be cut anywhere and leave the
# live zone working. The dynamic setters are deliberately NOT wanted on
# `Node`: a blueprint is declared once and never mutated.
import ast
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "bindings/python/kaya/__init__.py"
WANT = ("a11y_id", "a11y_label", "a11y_hint", "accepts", "on_paste", "role")
# Every container kind — the kinds `inset` is legal on at the root.
CONTAINERS = ("row", "column", "grid")

tree = ast.parse(open(path).read())
classes = {n.name: n for n in tree.body if isinstance(n, ast.ClassDef)}
funcs = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
if "Node" not in classes:
    print(f"{path}: no `class Node` — the template-node handle is gone")
    sys.exit(1)

# Walk Node and its bases (Python's handles are one shallow chain; a
# base named outside this module would be a different defect).
seen, todo, reach = set(), ["Node"], set()
while todo:
    name = todo.pop()
    if name in seen or name not in classes:
        continue
    seen.add(name)
    node = classes[name]
    reach |= {f.name for f in node.body
              if isinstance(f, (ast.FunctionDef, ast.AsyncFunctionDef))}
    todo += [b.id for b in node.bases if isinstance(b, ast.Name)]

missing = [w for w in WANT if w not in reach]
if missing:
    print(f"{path}: a template node cannot spell {', '.join(missing)} — "
          "the template-zone props live on the handle base both Widget "
          "and Node inherit (docs/tpl-props-plan.md P1)")
    sys.exit(1)


def called(fn):
    """The plain names this function calls."""
    return {c.func.id for c in ast.walk(fn)
            if isinstance(c, ast.Call) and isinstance(c.func, ast.Name)}


def takes(fn, arg):
    a = fn.args
    return arg in [p.arg for p in a.posonlyargs + a.args + a.kwonlyargs]


# THE ALLOCATOR CHAIN FIRST: a reader that cannot find it has read the
# wrong file and must refuse rather than report props it never looked
# for (tools/tpl-surfaces.py's rule).
broken = []
for name in ("_widget", "_alloc_widget_or_node"):
    if name not in funcs:
        print(f"{path}: no `{name}` — this is not the binding's "
              "constructor surface, so nothing below was measured")
        sys.exit(1)

if "_alloc_widget_or_node" not in called(funcs["_widget"]):
    broken.append("`_widget` no longer allocates through "
                  "`_alloc_widget_or_node`, so a constructor inside a For "
                  "hands back a live widget")

# ...and that allocator answers a template with a Node. Only the branch
# guarded by `_tpl_depth` counts: a `return Node(...)` on the live path
# would be the same defect wearing the right word.
hands_back_a_node = False
for stmt in ast.walk(funcs["_alloc_widget_or_node"]):
    if not isinstance(stmt, ast.If):
        continue
    if "_tpl_depth" not in {n.id for n in ast.walk(stmt.test)
                            if isinstance(n, ast.Name)}:
        continue
    for inner in stmt.body:
        for got in ast.walk(inner):
            if (isinstance(got, ast.Return)
                    and isinstance(got.value, ast.Call)
                    and isinstance(got.value.func, ast.Name)
                    and got.value.func.id == "Node"):
                hands_back_a_node = True
if not hands_back_a_node:
    broken.append("`_alloc_widget_or_node` no longer returns a `Node` on "
                  "its `_tpl_depth` branch — the one line in the binding "
                  "that tells the zones apart")

if "_set_inset" not in funcs:
    print(f"{path}: no `_set_inset` — the container kwarg's write is gone")
    sys.exit(1)

# AND THE WRITE ITSELF IS ZONE-BLIND — the cut the three links above
# cannot see: every link can hold while `_set_inset` grows an early
# return on `_tpl_depth`. Nothing that WRITES a prop may ask which zone
# it is in.
for who, fn in (("`_set_inset`", funcs["_set_inset"]),
                ("`_Handle.role`", next(
                    (f for f in classes["_Handle"].body
                     if isinstance(f, ast.FunctionDef) and f.name == "role"),
                    None))):
    if fn is None:  # role reached Node some other way; the WANT check passed
        continue
    if "_tpl_depth" in {n.id for n in ast.walk(fn) if isinstance(n, ast.Name)}:
        broken.append(f"{who} reads `_tpl_depth` — a prop write that asks "
                      "which zone it is in can answer only one of them")

for name in CONTAINERS:
    fn = funcs.get(name)
    if fn is None:
        broken.append(f"`kaya.{name}` is gone")
        continue
    if not takes(fn, "inset"):
        broken.append(f"`kaya.{name}` no longer takes `inset=` — the "
                      "template zone has no other spelling for it")
    elif "_set_inset" not in called(fn):
        broken.append(f"`kaya.{name}` takes `inset=` and never writes it")
    if "_widget" not in called(fn):
        broken.append(f"`kaya.{name}` no longer allocates through "
                      "`_widget`, so its `inset=` cannot name a template "
                      "node")

if broken:
    print(f"{path}: a stamped container cannot carry `inset` — "
          + "; ".join(broken))
    sys.exit(1)

print(f"python template-node props: {', '.join(WANT)} reachable via "
      f"{', '.join(sorted(seen))}; inset via `inset=` on "
      f"{', '.join(f'kaya.{c}' for c in CONTAINERS)}, each writing "
      "`_set_inset` onto `_widget` -> `_alloc_widget_or_node`'s Node")
