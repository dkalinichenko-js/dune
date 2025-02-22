(** Compilation contexts *)

(** Dune supports two different kind of contexts:

    - the default context, which correspond to the environment Dune is run, i.e.
      it takes [ocamlc] and other tools from the [PATH] and the ocamlfind
      configuration where it can find it

    - opam switch contexts, where one opam switch correspond to one context

    each context is built into a sub-directory of [Path.build_dir] (usually
    _build):

    - _build/default for the default context

    - _build/<switch> for other contexts

    Dune is able to build simultaneously against several contexts. In particular
    this allow for simple cross-compilation: when an executable running on the
    host is needed, it is obtained by looking in another context. *)

open Import

module Kind : sig
  module Opam : sig
    type t =
      { root : string option
      ; switch : string
      }
  end

  type t =
    | Default
    | Opam of Opam.t
end

module Env_nodes : sig
  type t =
    { context : Dune_env.Stanza.t
    ; workspace : Dune_env.Stanza.t
    }
end

type t = private
  { name : Context_name.t
  ; kind : Kind.t
  ; profile : Profile.t (** [true] if this context is used for the .merlin files *)
  ; merlin : bool
      (** [Some path/to/foo.exe] if this contexts is for feedback-directed
          optimization of target path/to/foo.exe *)
  ; fdo_target_exe : Path.t option
      (** By default Dune builds and installs dynamically linked foreign
          archives (usually named [dll*.so]). It is possible to disable this
          by adding (disable_dynamically_linked_foreign_archives true) to the
          workspace file, in which case bytecode executables will be built
          with all foreign archives statically linked into the runtime system. *)
  ; dynamically_linked_foreign_archives : bool
      (** If this context is a cross-compilation context, you need another
          context for building tools used for the compilation that run on the
          host. *)
  ; for_host : t option
      (** [false] if a user explicitly listed this context in the workspace.
          Controls whether we add artifacts from this context \@install *)
  ; implicit : bool
      (** Directory where artifact are stored, for instance "_build/default" *)
  ; build_dir : Path.Build.t (** env node that this context was initialized with *)
  ; env_nodes : Env_nodes.t
  ; path : Path.t list (** [PATH] *)
  ; ocaml : Ocaml_toolchain.t
  ; env : Env.t
  ; findlib_paths : Path.t list
  ; findlib_toolchain : Context_name.t option (** Misc *)
  ; default_ocamlpath : Path.t list
  ; supports_shared_libraries : Dynlink_supported.By_the_os.t
  ; lib_config : Lib_config.t
  ; build_context : Build_context.t
  }

val which : t -> string -> Path.t option Memo.t
val equal : t -> t -> bool
val hash : t -> int
val to_dyn : t -> Dyn.t
val to_dyn_concise : t -> Dyn.t

(** Compare the context names *)
val compare : t -> t -> Ordering.t

val name : t -> Context_name.t
val lib_config : t -> Lib_config.t

(** [map_exe t exe] returns a version of [exe] that is suitable for being
    executed on the current machine. For instance, if [t] is a cross-compilation
    build context, [map_exe t exe] returns the version of [exe] that lives in
    the host build context. Otherwise, it just returns [exe]. *)
val map_exe : t -> Path.t -> Path.t

val build_context : t -> Build_context.t

(** Query where build artifacts should be installed if the user doesn't specify
    an explicit installation directory. *)
val roots : t -> Path.t option Install.Roots.t

val host : t -> t

module DB : sig
  val get : Context_name.t -> t Memo.t
  val all : unit -> t list Memo.t
  val by_dir : Path.Build.t -> t Memo.t
end
