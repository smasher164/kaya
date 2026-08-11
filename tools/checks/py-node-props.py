# The python clause docs/tpl-props-plan.md P2 owes, ready to paste into
# tools/check-sugar-surface.sh. Reads the CLASS STRUCTURE with `ast` —
# a file-scoped grep cannot tell a method on `Widget` from one a node
# can reach, which is exactly the defect this slice fixed, and an import
# probe would need the built dylib (kaya/runtime.py loads it at import)
# and could go green against a stale one.
#
#   tpl_props_py=$(python3 tools/checks/py-node-props.py) || { ... }
#
# Argument: the binding path, so the gate keeps its one list of paths.
import ast
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "bindings/python/kaya/__init__.py"
WANT = ("a11y_id", "a11y_label", "a11y_hint", "accepts", "on_paste")

tree = ast.parse(open(path).read())
classes = {n.name: n for n in tree.body if isinstance(n, ast.ClassDef)}
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
print(f"python template-node props: {', '.join(WANT)} reachable via "
      f"{', '.join(sorted(seen))}")
