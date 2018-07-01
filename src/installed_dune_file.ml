open Import

let parse_sub_systems ~parsing_context sexps =
  List.filter_map sexps ~f:(fun sexp ->
    let name, ver, data =
      Sexp.Of_sexp.(parse (triple string (located Syntax.Version.t) raw)
                      Univ_map.empty) sexp
    in
    match Sub_system_name.get name with
    | None ->
      (* We ignore sub-systems that are not internally known. These
         correspond to plugins that are not in use in the current
         workspace. *)
      None
    | Some name -> Some (name, (Sexp.Ast.loc sexp, ver, data)))
  |> Sub_system_name.Map.of_list
  |> (function
    | Ok x -> x
    | Error (name, _, (loc, _, _)) ->
      Loc.fail loc "%S present twice" (Sub_system_name.to_string name))
  |> Sub_system_name.Map.mapi ~f:(fun name (_, version, data) ->
    let (module M) = Jbuild.Sub_system_info.get name in
    Syntax.check_supported M.syntax version;
    M.T (Sexp.Of_sexp.parse M.parse parsing_context data))

let of_sexp =
  let open Sexp.Of_sexp in
  let version =
    plain_string (fun ~loc -> function
      | "1" -> ()
      | _ ->
        of_sexp_errorf loc
          "Unsupported version, only version 1 is supported")
  in
  sum
    [ "dune",
      (version >>= fun () ->
       get_all >>= fun parsing_context ->
       list raw >>|
       parse_sub_systems ~parsing_context)
    ]

let load fname =
  Io.with_lexbuf_from_file fname ~f:(fun lexbuf ->
    let (version_loc, version) =
      let bad_dune_file = "Unable to read (dune x.y ..) line file" in
      let rec loop = function
        | [_; _; _] as a -> List.rev a
        | acc ->
          begin match (Sexp.Lexer.token lexbuf : Sexp.Lexer.Token.t) with
          | Eof ->
            Loc.fail (Loc.in_file (Path.to_string fname)) "%s" bad_dune_file
          | t -> loop (t :: acc)
          end
      in
      let loc = Sexp.Loc.of_lexbuf lexbuf in
      match loop [] with
      | [Lparen; Atom (A "dune"); Atom s] -> (loc, Sexp.Atom.to_string s)
      | _ -> Loc.fail loc "%s" bad_dune_file
    in
    let (lexer, syntax) =
      match version with
      | "1" -> (Sexp.Lexer.jbuild_token, (0, 0))
      | "2" -> (Sexp.Lexer.token, (1, 0))
      | _   -> Loc.fail version_loc "unknown version %S" version
    in
    Sexp.Of_sexp.parse of_sexp
      (Univ_map.singleton (Syntax.key Stanza.syntax) syntax)
      (Io.Sexp.load ~lexer ~mode:Single fname))

let gen confs =
  let sexps =
    Sub_system_name.Map.to_list confs
    |> List.map ~f:(fun (name, (ver, conf)) ->
      let (module M) = Jbuild.Sub_system_info.get name in
      Sexp.List [ Sexp.atom (Sub_system_name.to_string name)
                ; Syntax.Version.sexp_of_t ver
                ; conf
                ])
  in
  Sexp.List
    [ Sexp.unsafe_atom_of_string "dune"
    ; Sexp.unsafe_atom_of_string "1"
    ; List sexps
    ]
