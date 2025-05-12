
let triple f1 f2 f3 ppf (v1, v2, v3) =
  Format.fprintf ppf "(%a,%a,%a)" f1 v1 f2 v2 f3 v3
let fmt = Fmt.Dump.(list (triple string string (list string)))

let _ =
  let phr = Js_top_worker.Ocamltop.parse_toplevel "# foo;; junk\n  bar\n# baz;;\n  moo\n# unterminated;; foo" in
  Format.printf "%a" fmt phr;
