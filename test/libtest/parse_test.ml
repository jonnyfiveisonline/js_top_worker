
let fmt = Fmt.Dump.(list (pair string (list string)))

let _ =
  let phr = Js_top_worker.Ocamltop.parse_toplevel "# foo;;\n  bar\n# baz;;\n  moo\n" in
  Format.printf "%a" fmt phr;
