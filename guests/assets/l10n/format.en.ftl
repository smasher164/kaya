# The formatter door's conformance scene (tools/scenes/format.steps).
items = { $count ->
    [one] one item
   *[other] { $count } items
}
greeting = Hello, { $name }
