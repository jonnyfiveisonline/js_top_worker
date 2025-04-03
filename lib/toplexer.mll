{ }

rule entry = parse
    | (_ # '\n')* "\n" {
        output_line [] lexbuf
    }
    | _ | eof { false, [] }

and output_line acc = parse
    | "  " ((_ # '\n')* as line) "\n" {
        output_line (line :: acc) lexbuf
    }
    | "# " {
        true, List.rev acc
    }
    | eof {
        false, List.rev acc
    }
    | _ {
        false, List.rev acc
    }
