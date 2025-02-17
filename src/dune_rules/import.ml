include Stdune
include Dune_vcs
module Console = Dune_console
module Digest = Dune_digest
module Section = Install.Section

include struct
  open Dune_util
  module Execution_env = Execution_env
  module Log = Log
  module Persistent = Persistent
  module Stringlike = Stringlike

  module type Stringlike = Stringlike
end

include Dune_config_file

include struct
  open Dune_engine
  module Dir_set = Dir_set
  module Rule = Rule
  module Rules = Rules
  module Action_builder = Action_builder
  module Build_system = Build_system
  module Context_name = Context_name
  module Dpath = Dpath
  module Alias = Alias
  module File_selector = File_selector
  module Dep = Dep
  module Build_config = Build_config
  module Fs_memo = Fs_memo
  module Sandbox_config = Sandbox_config
  module Sandbox_mode = Sandbox_mode
  module Action = Action
  module Compound_user_error = Compound_user_error
  module Fs_cache = Fs_cache
  module Process = Process
  module Execution_parameters = Execution_parameters
  module Build_context = Build_context
  module Targets = Targets
  module Utils = Utils
  module Load_rules = Load_rules
  module Response_file = Response_file
  module Subdir_set = Subdir_set
end

include struct
  open Ocaml
  module Cm_kind = Cm_kind
  module Mode = Mode
  module Ml_kind = Ml_kind
  module Variant = Variant
  module Version = Version
end

module Re = Dune_re
module Syntax = Dune_sexp.Syntax

include struct
  open Dune_lang
  module Lib_name = Lib_name
  module Wrapped = Wrapped
  module Targets_spec = Targets_spec
  module Profile = Profile
  module Locks = Locks
  module Subst_config = Subst_config
  module Bindings = Bindings
  module Format_config = Format_config
  module Ordered_set_lang = Ordered_set_lang
  module Stanza = Stanza
  module String_with_vars = String_with_vars
  module Pform = Pform
  module Glob = Glob
  module Diff = Action.Diff
  module Outputs = Action.Outputs
  module Value = Value
  module Blang = Blang
  module Binary_kind = Binary_kind
end

include Dune_engine.No_io

module Build_config = struct
  module Gen_rules = struct
    module Build_only_sub_dirs = Build_config.Rules.Build_only_sub_dirs
    module Context_or_install = Build_config.Context_or_install

    module Rules = struct
      include Build_config.Rules

      let create
        ?(build_dir_only_sub_dirs = empty.build_dir_only_sub_dirs)
        ?(directory_targets = empty.directory_targets)
        rules
        =
        { rules; build_dir_only_sub_dirs; directory_targets }
      ;;
    end

    let make
      ?(build_dir_only_sub_dirs = Rules.empty.build_dir_only_sub_dirs)
      ?(directory_targets = Rules.empty.directory_targets)
      rules
      =
      let rules =
        { Build_config.Rules.build_dir_only_sub_dirs; directory_targets; rules }
      in
      Build_config.Rules rules
    ;;

    let redirect_to_parent rules = Build_config.Redirect_to_parent rules
    let rules_here rules = Build_config.Rules rules
    let unknown_context_or_install = Build_config.Unknown_context_or_install
    let no_rules = make (Memo.return Dune_engine.Rules.empty)

    type result = Build_config.gen_rules_result

    module type Generator = Build_config.Rule_generator

    let set = Build_config.set
  end

  let set = Build_config.set
end
