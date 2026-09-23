items = { $count ->
    [one] ein Element
   *[other] { $count } Elemente
}
greeting = Hallo, { $name }
