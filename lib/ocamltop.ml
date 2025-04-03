let refill_lexbuf s p buffer len =
  if !p = String.length s then 0
  else
    let len' =
      try (String.index_from s !p '\n' - !p + 1)
      with _ -> (String.length s - !p)
    in
    let len'' = min len len' in
    String.blit s !p buffer 0 len'';
    p := !p + len'';
    len''

let parse_toplevel s =
  let s = s in
  let lexbuf = Lexing.from_string s in
  let rec loop pos =
    let _phr = !Toploop.parse_toplevel_phrase lexbuf in
    let new_pos = Lexing.lexeme_end lexbuf in
    let phr = String.sub s pos (new_pos - pos) in
    let (cont, output) = Toplexer.entry lexbuf in
    let new_pos = Lexing.lexeme_end lexbuf in
    if cont then (phr, output) :: loop new_pos else [(phr, output)]
  in
  loop 0