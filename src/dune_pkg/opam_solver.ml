open Stdune
open Dune_lang

module type CONTEXT = Opam_0install.S.CONTEXT

(* Helper module for working with [OpamTypes.filter] *)
module Filter : sig
  type filter := OpamTypes.filter

  (** Substitute variables with their values.

      Comparisons with unset system environment variables resolve to true,
      treating them as wildcards. This creates a formula which is as permissive
      as possible within the constraints for system environment variables
      specified by the user. The intention is to generate lockdirs which will
      work on as many systems as possible, but to allow the user to constrain
      this by setting environment variables to handle situations where the most
      permissive solve is not possible or otherwise produces undesirable
      outcomes (e.g. when there are mutually-incompatible os-specific packages
      for different operating systems). *)
  val resolve_solver_env_treating_unset_sys_variables_as_wildcards
    :  Solver_env.t
    -> filter
    -> filter

  val eval_to_bool : filter -> (bool, [ `Not_a_bool of string ]) result
end = struct
  open OpamTypes

  (* Returns true iff a variable is an opam system environment variable *)
  let is_variable_sys variable =
    Solver_env.Variable.Sys.of_string_opt (OpamVariable.to_string variable)
    |> Option.is_some
  ;;

  let resolve_solver_env_treating_unset_sys_variables_as_wildcards solver_env =
    OpamFilter.map_up (function
      | FIdent ([], variable, None) as filter ->
        (match Solver_env.Variable.of_string_opt (OpamVariable.to_string variable) with
         | None -> filter
         | Some variable ->
           (match Solver_env.get solver_env variable with
            | Unset_sys -> filter
            | String string -> FString string
            | Bool bool -> FBool bool))
      | (FOp (FIdent (_, variable, _), _, _) | FOp (_, _, FIdent (_, variable, _))) as
        filter ->
        if is_variable_sys variable
        then
          (* Comparisons with unset system environment variables resolve to
             true. This is so that we add dependencies guarded by filters on
             unset system variables. For example if a package has a linux-only
             and a macos-only dependency and the user hasn't specified that they
             only want to solve for a specific os, then we should add both the
             linux-only and macos-only dependencies to the solution.

             Note that this branch is only followed for unset variables as
             [OpamFilter.map_up] traverses the formula bottom up, so variables
             with values in [solver_env] will have been substituted for those
             values already by the time control gets here.*)
          FBool true
        else filter
      | other -> other)
  ;;

  let eval_to_bool filter =
    try Ok (OpamFilter.eval_to_bool ~default:false (Fun.const None) filter) with
    | Invalid_argument msg -> Error (`Not_a_bool msg)
  ;;
end

(* Helper module for working with [OpamTypes.filtered_formula] *)
module Filtered_formula : sig
  open OpamTypes

  (** Transform the filter applied to each formula according to a function [g] *)
  val map_filters : f:(filter -> filter) -> filtered_formula -> filtered_formula
end = struct
  open OpamTypes

  let map_filters ~f =
    OpamFilter.gen_filter_formula
      (OpamFormula.partial_eval (function
        | Filter flt -> `Formula (Atom (Filter (f flt)))
        | Constraint _ as constraint_ -> `Formula (Atom constraint_)))
  ;;
end

module Context_for_dune = struct
  let local_package_default_version =
    OpamPackage.Version.of_string Lock_dir.Pkg_info.default_version
  ;;

  type t =
    { repo : Opam_repo.t
    ; version_preference : Version_preference.t
    ; local_packages : OpamFile.OPAM.t OpamPackage.Name.Map.t
    ; solver_env : Solver_env.t
    }

  let create ~solver_env ~repo ~local_packages ~version_preference =
    { repo; version_preference; local_packages; solver_env }
  ;;

  type rejection = Unavailable

  let pp_rejection f = function
    | Unavailable -> Fmt.string f "Availability condition not satisfied"
  ;;

  let opam_version_compare t =
    let opam_package_version_compare a b =
      OpamPackage.Version.compare a b |> Ordering.of_int
    in
    let opam_file_compare_by_version a b =
      opam_package_version_compare (OpamFile.OPAM.version a) (OpamFile.OPAM.version b)
    in
    match t.version_preference with
    | Oldest -> opam_file_compare_by_version
    | Newest -> Ordering.reverse opam_file_compare_by_version
  ;;

  let is_opam_available =
    (* The solver can call this function several times on the same package. If
       the package contains an invalid `available` filter we want to print a
       warning, but only once per package. This variable will keep track of the
       packages for which we've printed a warning. *)
    let warned_packages = ref OpamPackage.Set.empty in
    fun t opam ->
      let available = OpamFile.OPAM.available opam in
      let available_vars_resolved =
        Filter.resolve_solver_env_treating_unset_sys_variables_as_wildcards
          t.solver_env
          available
      in
      match Filter.eval_to_bool available_vars_resolved with
      | Ok available -> available
      | Error error ->
        let package = OpamFile.OPAM.package opam in
        if not (OpamPackage.Set.mem package !warned_packages)
        then (
          warned_packages := OpamPackage.Set.add package !warned_packages;
          let package_string = OpamFile.OPAM.package opam |> OpamPackage.to_string in
          let available_string = OpamFilter.to_string available in
          match error with
          | `Not_a_bool msg ->
            User_warning.emit
              [ Pp.textf
                  "Ignoring package %s as its `available` filter can't be resolved to a \
                   boolean value."
                  package_string
              ; Pp.textf "available: %s" available_string
              ; Pp.text msg
              ]);
        false
  ;;

  let candidates t name =
    match OpamPackage.Name.Map.find_opt name t.local_packages with
    | Some opam_file ->
      let version =
        Option.value opam_file.version ~default:local_package_default_version
      in
      [ version, Ok opam_file ]
    | None ->
      (match Opam_repo.load_all_versions t.repo name with
       | Error `Package_not_found ->
         (* The CONTEXT interface doesn't give us a way to report this type of
            error and there's not enough context to give a helpful error message
            so just tell opam_0install that there are no versions of this
            package available (technically true) and let it produce the error
            message. *)
         []
       | Ok opam_files ->
         let opam_files_in_priority_order =
           List.sort opam_files ~compare:(opam_version_compare t)
         in
         List.map opam_files_in_priority_order ~f:(fun opam_file ->
           let opam_file_result =
             if is_opam_available t opam_file then Ok opam_file else Error Unavailable
           in
           OpamFile.OPAM.version opam_file, opam_file_result))
  ;;

  let user_restrictions _ _ = None

  let filter_deps t package filtered_formula =
    let package_is_local =
      OpamPackage.Name.Map.mem (OpamPackage.name package) t.local_packages
    in
    let solver_env =
      if package_is_local
      then t.solver_env
      else
        (* Flag variables pertain only to local packages. This is because these
           variables enable dependencies on test and documentation packages and
           we don't want to pull in test and doc dependencies for dependencies
           of local packages. *)
        Solver_env.clear_flags t.solver_env
    in
    Filtered_formula.map_filters
      filtered_formula
      ~f:(Filter.resolve_solver_env_treating_unset_sys_variables_as_wildcards solver_env)
    |> OpamFilter.filter_deps
         ~build:true
         ~post:true
         ~dev:false
         ~default:false
         ~test:false
         ~doc:false
  ;;
end

module Solver = Opam_0install.Solver.Make (Context_for_dune)

module Summary = struct
  type t = { opam_packages_to_lock : OpamPackage.t list }

  let selected_packages_message t ~lock_dir_path =
    let parts =
      match t.opam_packages_to_lock with
      | [] -> [ Pp.tag User_message.Style.Success (Pp.text "(no dependencies to lock)") ]
      | opam_packages_to_lock ->
        List.map opam_packages_to_lock ~f:(fun package ->
          Pp.text (OpamPackage.to_string package))
    in
    User_message.make
      (Pp.textf "Solution for %s:" (Path.Source.to_string_maybe_quoted lock_dir_path)
       :: parts)
  ;;
end

let opam_command_to_string_debug (args, _filter_opt) =
  List.map args ~f:(fun (simple_arg, _filter_opt) ->
    match simple_arg with
    | OpamTypes.CString s -> String.quoted s
    | CIdent ident -> ident)
  |> String.concat ~sep:" "
;;

let opam_commands_to_actions package (commands : OpamTypes.command list) =
  let pform_of_ident_opt ident =
    let `Self, variable =
      match String.split ident ~on:':' with
      | [ variable ] | [ "_"; variable ] -> `Self, variable
      | _ ->
        (* TODO *)
        Code_error.raise
          "Evaluating package variables for non-self packages not yet implemented"
          [ "While processing package:", Dyn.string (OpamPackage.to_string package)
          ; "Variable:", Dyn.string ident
          ]
    in
    match Pform.Var.Pkg.of_opam_variable_name_opt variable with
    | Some pkg_var -> Ok Pform.(Var (Var.Pkg pkg_var))
    | None -> Error (`Unknown_variable variable)
  in
  List.filter_map commands ~f:(fun ((args, _filter_opt) as command) ->
    let terms =
      List.map args ~f:(fun (simple_arg, _filter_opt) ->
        match simple_arg with
        | OpamTypes.CString s ->
          (* TODO: apply replace string interpolation variables with pforms *)
          String_with_vars.make_text Loc.none s
        | CIdent ident ->
          (match pform_of_ident_opt ident with
           | Ok pform -> String_with_vars.make_pform Loc.none pform
           | Error (`Unknown_variable variable) ->
             (* Note that the variable name is always quoted to clarify
                the error message in cases where the grammar of the
                sentence would otherwise be unclear, such as:

                - Encountered unknown variable type while processing...
                - Encountered unknown variable name while processing...

                In these examples, the words "type" and "name" are variable
                names but it would be easy for users to misunderstand those
                error messages without quotes. *)
             User_error.raise
               [ Pp.textf
                   "Encountered unknown variable %S while processing commands for \
                    package %s."
                   variable
                   (OpamPackage.to_string package)
               ; Pp.text "The full command:"
               ; Pp.text (opam_command_to_string_debug command)
               ]))
    in
    match terms with
    | program :: args -> Some (Action.run program args)
    | [] -> None)
;;

(* returns:
   [None] if the command list is empty
   [Some (Action.Run ...)] if there is a single command
   [Some (Action.Progn [Action.Run ...; ...])] if there are multiple commands *)
let opam_commands_to_action package (commands : OpamTypes.command list) =
  match opam_commands_to_actions package commands with
  | [] -> None
  | [ action ] -> Some action
  | actions -> Some (Action.Progn actions)
;;

let opam_package_to_lock_file_pkg ~repo ~local_packages opam_package =
  let name = OpamPackage.name opam_package in
  let version = OpamPackage.version opam_package |> OpamPackage.Version.to_string in
  let dev = OpamPackage.Name.Map.mem name local_packages in
  let info =
    { Lock_dir.Pkg_info.name = Package_name.of_string (OpamPackage.Name.to_string name)
    ; version
    ; dev
    ; source = None
    ; extra_sources = []
    }
  in
  let opam_file =
    match OpamPackage.Name.Map.find_opt name local_packages with
    | None -> Opam_repo.load_opam_package repo opam_package
    | Some local_package -> local_package
  in
  (* This will collect all the atoms from the package's dependency formula regardless of conditions *)
  let deps =
    OpamFormula.fold_right
      (fun acc (name, _condition) -> name :: acc)
      []
      opam_file.depends
    |> List.map ~f:(fun name ->
      Loc.none, Package_name.of_string (OpamPackage.Name.to_string name))
  in
  let build_command =
    opam_commands_to_action opam_package (OpamFile.OPAM.build opam_file)
  in
  let install_command =
    opam_commands_to_action opam_package (OpamFile.OPAM.install opam_file)
  in
  { Lock_dir.Pkg.build_command; install_command; deps; info; exported_env = [] }
;;

let solve_package_list local_packages context =
  let result =
    try
      (* [Solver.solve] returns [Error] when it's unable to find a solution to
         the dependencies, but can also raise exceptions, for example if opam
         is unable to parse an opam file in the package repository. To prevent
         an unexpected opam exception from crashing dune, we catch all
         exceptions raised by the solver and report them as [User_error]s
         instead. *)
      Solver.solve context (OpamPackage.Name.Map.keys local_packages)
    with
    | OpamPp.(Bad_format _ | Bad_format_list _ | Bad_version _) as bad_format ->
      User_error.raise [ Pp.text (OpamPp.string_of_bad_format bad_format) ]
    | unexpected_exn ->
      Code_error.raise
        "Unexpected exception raised while solving dependencies"
        [ "exception", Exn.to_dyn unexpected_exn ]
  in
  match result with
  | Error e -> Error (`Diagnostic_message (Solver.diagnostics e |> Pp.text))
  | Ok packages -> Ok (Solver.packages_of_result packages)
;;

let solve_lock_dir solver_env version_preference repo ~local_packages =
  let is_local_package package =
    OpamPackage.Name.Map.mem (OpamPackage.name package) local_packages
  in
  let context =
    Context_for_dune.create ~solver_env ~repo ~version_preference ~local_packages
  in
  solve_package_list local_packages context
  |> Result.map ~f:(fun solution ->
    (* don't include local packages in the lock dir *)
    let opam_packages_to_lock = List.filter solution ~f:(Fun.negate is_local_package) in
    let summary = { Summary.opam_packages_to_lock } in
    let lock_dir =
      match
        Package_name.Map.of_list_map opam_packages_to_lock ~f:(fun opam_package ->
          let pkg = opam_package_to_lock_file_pkg ~repo ~local_packages opam_package in
          pkg.info.name, pkg)
      with
      | Error (name, _pkg1, _pkg2) ->
        Code_error.raise
          (sprintf
             "Solver selected multiple packages named \"%s\""
             (Package_name.to_string name))
          []
      | Ok pkgs_by_name -> Lock_dir.create_latest_version pkgs_by_name ~ocaml:None
    in
    summary, lock_dir)
;;
