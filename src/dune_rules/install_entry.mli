(** Install entries are written install stanzas and are used to describe file
    bindings. *)

open Import

module File : sig
  (** File Bindings. *)

  type t

  val decode : t Dune_lang.Decoder.t

  val to_file_bindings_unexpanded
    :  t list
    -> expand_str:(String_with_vars.t -> string Memo.t)
    -> dir:Path.Build.t
    -> File_binding.Unexpanded.t list Memo.t

  val to_file_bindings_expanded
    :  t list
    -> expand_str:(String_with_vars.t -> string Memo.t)
    -> dir:Path.Build.t
    -> File_binding.Expanded.t list Memo.t

  val of_file_binding : File_binding.Unexpanded.t -> t
end

module Dir : sig
  (** Directory Bindings.t *)

  type t

  val decode : t Dune_lang.Decoder.t

  val to_file_bindings_expanded
    :  t list
    -> expand_str:(String_with_vars.t -> string Memo.t)
    -> dir:Path.Build.t
    -> File_binding.Expanded.t list Memo.t
end
