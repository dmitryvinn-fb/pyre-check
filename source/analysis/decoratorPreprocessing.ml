(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* This module defines an AST preprocessing step that can be used to inline
 * or remove python decorators from decorated functions. This is generally
 * unsound, but is used in the taint analysis (Pysa) to improve the precision
 * of the analysis. *)

open Ast
open Core
open Pyre
open Statement
open Expression

module Action = struct
  module T = struct
    type t =
      (* Do not try to inline that decorator, keep it as-is. *)
      | DoNotInline
      (* Remove that decorator from decorated function, assuming it is a no-op. *)
      | Discard
    [@@deriving eq, show, compare]

    let to_mode = function
      | DoNotInline -> "SkipDecoratorWhenInlining"
      | Discard -> "IgnoreDecorator"
  end

  include T
  module Set = Stdlib.Set.Make (T)
end

module Configuration = struct
  type t = {
    actions: Action.t Reference.SerializableMap.t;
    enable_inlining: bool;
    enable_discarding: bool;
  }
  [@@deriving eq]

  let disable_preprocessing =
    {
      actions = Reference.SerializableMap.empty;
      enable_inlining = false;
      enable_discarding = false;
    }
end

module ConfigurationSharedMemory =
  Memory.WithCache.Make
    (Memory.SingletonKey)
    (struct
      type t = Configuration.t

      let prefix = Hack_parallel.Std.Prefix.make ()

      let description = "Configuration for decorator preprocessing."
    end)

module OptionsSharedMemory =
  Memory.WithCache.Make
    (SharedMemoryKeys.StringKey)
    (struct
      type t = bool

      let prefix = Hack_parallel.Std.Prefix.make ()

      let description = "Options for decorator preprocessing."
    end)

module DecoratorActionsSharedMemory =
  Memory.WithCache.Make
    (SharedMemoryKeys.ReferenceKey)
    (struct
      type t = Action.t

      let prefix = Hack_parallel.Std.Prefix.make ()

      let description = "What action to take on a given decorator."
    end)

let setup_preprocessing
    ({ Configuration.actions; enable_inlining; enable_discarding } as configuration)
  =
  ConfigurationSharedMemory.add Memory.SingletonKey.key configuration;
  OptionsSharedMemory.add "enable_inlining" enable_inlining;
  OptionsSharedMemory.add "enable_discarding" enable_discarding;
  Reference.SerializableMap.iter DecoratorActionsSharedMemory.add actions


let get_configuration () = ConfigurationSharedMemory.get Memory.SingletonKey.key

let inlined_original_function_name = "_original_function"

let make_wrapper_function_name decorator_reference =
  Reference.delocalize decorator_reference
  |> Reference.last
  |> Format.asprintf "_inlined_%s"
  |> Reference.create


let args_local_variable_name = "_args"

let kwargs_local_variable_name = "_kwargs"

module DecoratorModuleValue = struct
  type t = Ast.Reference.t

  let prefix = Hack_parallel.Std.Prefix.make ()

  let description = "Module for a decorator that has been inlined."
end

(** Mapping from an inlined decorator function name to its original name. *)
module InlinedNameToOriginalName =
  Memory.WithCache.Make (SharedMemoryKeys.ReferenceKey) (DecoratorModuleValue)

let add_function_decorator_module_mapping
    ~qualifier
    ~outer_decorator_reference
    { Define.signature = { name; _ }; _ }
  =
  let qualified_inlined_name = Reference.combine qualifier name in
  InlinedNameToOriginalName.add qualified_inlined_name outer_decorator_reference


let original_name_from_inlined_name = InlinedNameToOriginalName.get

module DecoratorListValue = struct
  type t = Ast.Expression.t list

  let prefix = Hack_parallel.Std.Prefix.make ()

  let description = "Original decorators for a decorated function that has been preprocessed."
end

(** Mapping from a decorated function to its original decorator list. *)
module DecoratedCallableToOriginalDecorators =
  Memory.WithCache.Make (SharedMemoryKeys.ReferenceKey) (DecoratorListValue)

let get_define_decorators { Define.signature = { decorators; _ }; _ } = decorators

let add_original_decorators_mapping ~original_define ~new_define =
  if
    (List.length (get_define_decorators original_define)
    != List.length (get_define_decorators new_define)) [@alert "-deprecated"]
  then
    DecoratedCallableToOriginalDecorators.add
      (Define.name new_define)
      (get_define_decorators original_define)


let original_decorators_from_preprocessed_signature ~define_name ~decorators =
  DecoratedCallableToOriginalDecorators.get define_name |> Option.value ~default:decorators


(* Pysa doesn't care about metadata like `unbound_names`. So, strip them. *)
let sanitize_define
    ?(strip_decorators = true)
    ?(strip_parent = false)
    ({ Define.signature = { decorators; legacy_parent; _ } as signature; _ } as define)
  =
  {
    define with
    signature =
      {
        signature with
        decorators = (if strip_decorators then [] else decorators);
        legacy_parent = legacy_parent >>= Option.some_if (not strip_parent);
      };
    unbound_names = [];
  }


let sanitize_defines ~strip_decorators source =
  let module SanitizeDefines = Transform.MakeStatementTransformer (struct
    type t = unit

    let statement _ = function
      | { Node.value = Statement.Define define; location } ->
          ( (),
            [{ Node.value = Statement.Define (sanitize_define ~strip_decorators define); location }]
          )
      | statement -> (), [statement]
  end)
  in
  let { SanitizeDefines.source; _ } = SanitizeDefines.transform () source in
  source


(* Rename [my_decorator] to [my_decoratorN] if it appears multiple times in the list. *)
let uniquify_names ~get_reference ~set_reference input_list =
  let number_if_needed (sofar, seen_map) input =
    let reference = get_reference input in
    let seen_map = Map.add_multi seen_map ~key:reference ~data:reference in
    let count = Map.find_multi seen_map reference |> List.length in
    let updated_input =
      set_reference
        (Reference.map_last reference ~f:(fun s ->
             s ^ if count = 1 then "" else Format.asprintf "%d" count))
        input
    in
    updated_input :: sofar, seen_map
  in
  List.rev input_list |> List.fold ~init:([], Reference.Map.empty) ~f:number_if_needed |> fst


let rename_local_variables ~pairs define =
  let rename_map = Identifier.Map.of_alist pairs in
  match rename_map with
  | `Duplicate_key _ -> define
  | `Ok rename_map -> (
      let rename_identifier = function
        | Expression.Name (Name.Identifier identifier) ->
            let renamed_identifier =
              Map.find rename_map identifier |> Option.value ~default:identifier
            in
            Expression.Name (Name.Identifier renamed_identifier)
        | expression -> expression
      in
      match
        Transform.transform_in_statement ~transform:rename_identifier (Statement.Define define)
      with
      | Statement.Define define -> define
      | _ -> failwith "impossible")


let rename_local_variable ~from ~to_ define = rename_local_variables ~pairs:[from, to_] define

let rename_define ~new_name ({ Define.signature; _ } as define) =
  { define with Define.signature = { signature with name = new_name } }


let rec set_parent
    ~new_parent
    ({ Define.signature = { name = define_name; _ } as signature; body; _ } as define)
  =
  let signature = { signature with parent = new_parent } in
  (* We also need to recursively update the parent of nested defines. *)
  let define_function_name = Reference.last (Reference.delocalize define_name) in
  let transform_statement = function
    | { Node.value = Statement.Define define; location } ->
        define
        |> set_parent
             ~new_parent:(NestingContext.create_function ~parent:new_parent define_function_name)
        |> (fun define -> Statement.Define define)
        |> Node.create ~location
    | { Node.value = Statement.Class _; _ } as statement ->
        (* TODO: We should also reparent defines nested within classes *)
        statement
    | statement -> statement
  in
  let module ReparentTransform = Transform.Make (struct
    type t = unit

    let transform_expression_children _ _ = false

    let expression _ = Fn.id

    let transform_children _ _ = (), true

    let statement _ statement = (), [transform_statement statement]
  end)
  in
  let body =
    ReparentTransform.transform () (Source.create body)
    |> (fun { ReparentTransform.source; _ } -> source)
    |> Source.statements
  in
  { define with Define.signature; body }


let requalify_identifier ~old_qualifier ~new_qualifier identifier =
  let reference = Reference.create identifier in
  if Reference.is_local reference then
    match
      Reference.delocalize reference
      |> Reference.drop_prefix ~prefix:old_qualifier
      |> Reference.as_list
    with
    | [name] -> Some (Preprocessing.get_qualified_local_identifier ~qualifier:new_qualifier name)
    | _ -> None
  else
    None


let requalify_reference ~old_qualifier ~new_qualifier reference =
  reference
  |> Reference.show
  |> requalify_identifier ~old_qualifier ~new_qualifier
  >>| Reference.create


let requalify_name ~old_qualifier ~new_qualifier = function
  (* TODO(T69755379): Handle Name.Attribute too. *)
  | Name.Identifier identifier as name -> (
      match requalify_identifier ~old_qualifier ~new_qualifier identifier with
      | Some new_identifier -> Name.Identifier new_identifier
      | None -> name)
  | name -> name


let rec requalify_define ~old_qualifier ~new_qualifier ~relative_path define =
  let transform_expression = function
    | Expression.Name name -> Expression.Name (requalify_name ~old_qualifier ~new_qualifier name)
    | expression -> expression
  in
  let transform_statement = function
    | {
        Node.value =
          Statement.Define ({ Define.signature = { name = define_name; _ }; _ } as define);
        location;
      } as statement -> (
        (* This define has a nested define, it also needs to be requalified recursively. *)
        match requalify_reference ~old_qualifier ~new_qualifier define_name with
        | Some new_name ->
            rename_define ~new_name define
            |> requalify_define
                 ~old_qualifier:(Reference.delocalize define_name)
                 ~new_qualifier:(Reference.delocalize new_name)
                 ~relative_path
            |> fun define -> Statement.Define define |> Node.create ~location
        | None -> statement)
    | statement -> statement
  in
  let module RequalifyTransform = Transform.Make (struct
    type t = unit

    let transform_expression_children _ _ = true

    let expression _ { Node.value; location } =
      { Node.value = transform_expression value; location }


    let transform_children _ _ = (), true

    let statement _ statement = (), [transform_statement statement]
  end)
  in
  RequalifyTransform.transform
    ()
    (Source.create [Node.create_with_default_location (Statement.Define define)])
  |> (fun { RequalifyTransform.source; _ } -> source)
  |> Source.statements
  |> function
  | [{ Node.value = Statement.Define define; _ }] -> define
  | _ -> failwith "expected single define"


let convert_parameter_to_argument ~location { Node.value = { Parameter.name; _ }; _ } =
  let name_expression name =
    Expression.Name
      (create_name ~location ~create_origin:(fun _ -> Some Origin.DecoratorInlining) name)
    |> Node.create ~location
  in
  let argument_value =
    if String.is_prefix ~prefix:"**" name then
      Expression.Starred (Twice (name_expression (String.drop_prefix name 2)))
      |> Node.create ~location
    else if String.is_prefix ~prefix:"*" name then
      Expression.Starred (Once (name_expression (String.drop_prefix name 1)))
      |> Node.create ~location
    else
      name_expression name
  in
  { Call.Argument.name = None; value = argument_value }


let create_function_call ~should_await ~location ~callee_name arguments =
  let call =
    Expression.Call
      {
        callee =
          Expression.Name
            (create_name_from_reference
               ~location
               ~create_origin:(fun _ -> Some Origin.DecoratorInlining)
               callee_name)
          |> Node.create ~location;
        arguments;
        origin = Some (Origin.create ~location Origin.DecoratorInlining);
      }
  in
  if should_await then Expression.Await (Node.create ~location call) else call


let create_function_call_to ~location ~callee_name { Define.Signature.parameters; async; _ } =
  List.map parameters ~f:(convert_parameter_to_argument ~location)
  |> create_function_call ~location ~callee_name ~should_await:async


let set_first_parameter_type
    ~original_define:({ Define.signature = { legacy_parent; _ }; _ } as original_define)
    ({ Define.signature = { parameters; _ } as signature; _ } as define)
  =
  match parameters, legacy_parent with
  | { Node.value = { annotation; _ } as first_parameter; location } :: rest, Some parent
    when not (Define.is_static_method original_define) ->
      let new_annotation =
        if Define.is_class_method original_define then
          subscript
            ~location
            ~create_origin:(fun _ -> None)
            "typing.Type"
            [from_reference ~location ~create_origin:(fun _ -> None) parent]
          |> Node.create ~location
        else
          from_reference ~location ~create_origin:(fun _ -> None) parent
      in
      {
        define with
        Define.signature =
          {
            signature with
            parameters =
              {
                Node.location;
                value =
                  {
                    first_parameter with
                    annotation = Option.first_some annotation (Some new_annotation);
                  };
              }
              :: rest;
          };
      }
  | _ -> define


type decorator_data = {
  wrapper_define: Define.t;
  helper_defines: Define.t list;
  higher_order_function_parameter_name: Identifier.t;
  decorator_reference: Reference.t;
  outer_decorator_reference: Reference.t;
  decorator_call_location: Location.t;
}

let extract_decorator_data
    ~decorator_call_location
    ~is_decorator_factory
    ({ Define.signature = { name = outer_decorator_reference; _ }; body; _ } as decorator_define)
  =
  let get_nested_defines body =
    List.filter_map body ~f:(function
        | { Node.value = Statement.Define wrapper_define; _ } -> Some wrapper_define
        | _ -> None)
  in
  let wrapper_function_name body =
    match List.last body with
    | Some
        {
          Node.value =
            Statement.Return
              {
                expression =
                  Some { Node.value = Expression.Name (Name.Identifier wrapper_function_name); _ };
                _;
              };
          _;
        } ->
        Some wrapper_function_name
    | _ -> None
  in
  let extract_decorator_data
      { Define.signature = { parameters; name = decorator_reference; _ }; body; _ }
    =
    let partition_wrapper_helpers body =
      match wrapper_function_name body with
      | Some wrapper_name ->
          let define_name_matches { Define.signature = { name; _ }; _ } =
            Identifier.equal (Reference.show name) wrapper_name
          in
          get_nested_defines body |> List.partition_tf ~f:define_name_matches |> Option.some
      | None -> None
    in
    match partition_wrapper_helpers body, parameters with
    | ( Some ([wrapper_define], helper_defines),
        [{ Node.value = { Parameter.name = higher_order_function_parameter_name; _ }; _ }] ) ->
        let calls_to_decorated_function =
          Statement.Define decorator_define
          |> Node.create_with_default_location
          |> Visit.collect_calls
          |> List.filter_map ~f:(fun { Node.value = { Call.callee; _ } as call; _ } ->
                 Option.some_if (name_is ~name:higher_order_function_parameter_name callee) call)
        in
        let all_identical ~equal items =
          match items with
          | [] -> true
          | head :: tail -> List.for_all tail ~f:(equal head)
        in
        Option.some_if
          (all_identical
             ~equal:(fun left right -> Call.location_insensitive_compare left right = 0)
             calls_to_decorated_function)
          {
            wrapper_define;
            helper_defines;
            higher_order_function_parameter_name;
            decorator_reference;
            outer_decorator_reference;
            decorator_call_location;
          }
    | _ -> None
  in
  if is_decorator_factory then
    match get_nested_defines body with
    | [decorator_define] -> extract_decorator_data decorator_define
    | _ -> None
  else
    extract_decorator_data decorator_define


let make_args_assignment_from_parameters ~args_local_variable_name parameters =
  let location = Location.any in
  let elements =
    List.map parameters ~f:(convert_parameter_to_argument ~location)
    |> List.filter_map ~f:(function
           | { Call.Argument.value = { Node.value = Expression.Starred (Twice _); _ }; _ } -> None
           | { Call.Argument.value; _ } -> Some value)
  in
  Statement.Assign
    {
      target =
        Expression.Name
          (create_name_from_reference
             ~location
             ~create_origin:(fun _ -> Some Origin.DecoratorInlining)
             (Reference.create args_local_variable_name))
        |> Node.create ~location;
      annotation = None;
      value = Some (Expression.Tuple elements |> Node.create ~location);
    }
  |> Node.create ~location


let make_kwargs_assignment_from_parameters ~kwargs_local_variable_name parameters =
  let location = Location.any in
  let parameter_to_keyword_or_entry parameter =
    let open Dictionary.Entry in
    match convert_parameter_to_argument ~location parameter with
    | { Call.Argument.value = { Node.value = Expression.Starred (Twice keyword); _ }; _ } ->
        First (Splat keyword)
    | { Call.Argument.value = { Node.value = Expression.Starred (Once _); _ }; _ } -> Second ()
    | { Call.Argument.value = argument; _ } ->
        let raw_argument_string = Expression.show argument in
        let argument_string =
          String.chop_prefix ~prefix:"$parameter$" raw_argument_string
          |> Option.value ~default:raw_argument_string
        in
        First
          (KeyValue
             {
               key =
                 Expression.Constant (Constant.String (StringLiteral.create argument_string))
                 |> Node.create_with_default_location;
               value = argument;
             })
  in
  let entries, _ = List.partition_map parameters ~f:parameter_to_keyword_or_entry in
  Statement.Assign
    {
      target =
        Expression.Name
          (create_name_from_reference
             ~location
             ~create_origin:(fun _ -> Some Origin.DecoratorInlining)
             (Reference.create kwargs_local_variable_name))
        |> Node.create ~location;
      annotation = None;
      value = Some (Expression.Dictionary entries |> Node.create ~location);
    }
  |> Node.create ~location


let call_function_with_precise_parameters
    ~callee_name
    ~callee_prefix_parameters
    ~new_signature:{ Define.Signature.parameters = new_parameters; _ }
    ({ Define.signature = wrapper_signature; _ } as define)
  =
  let wraps_original_function =
    Define.Signature.has_decorator ~match_prefix:true wrapper_signature "functools.wraps"
  in
  let inferred_args_kwargs_parameters = ref None in
  let pass_precise_arguments_instead_of_args_kwargs = function
    | Expression.Call
        {
          Call.callee = { Node.value = Name (Identifier given_callee_name); location };
          arguments;
          _;
        } as expression
      when Identifier.equal callee_name given_callee_name -> (
        match List.rev arguments with
        | {
            Call.Argument.name = None;
            value =
              {
                Node.value =
                  Starred (Twice { Node.value = Name (Identifier given_kwargs_variable); _ });
                _;
              };
          }
          :: {
               Call.Argument.name = None;
               value =
                 {
                   Node.value =
                     Starred (Once { Node.value = Name (Identifier given_args_variable); _ });
                   _;
                 };
             }
          :: prefix_arguments
          when Identifier.equal args_local_variable_name given_args_variable
               && Identifier.equal kwargs_local_variable_name given_kwargs_variable ->
            let prefix_arguments = List.rev prefix_arguments in
            let parameter_matches_argument
                { Node.value = { Parameter.name = parameter_name; _ }; _ }
              = function
              | {
                  Call.Argument.name = None;
                  value = { Node.value = Name (Identifier given_argument); _ };
                } ->
                  Identifier.equal parameter_name given_argument
              | _ -> false
            in
            let all_arguments_match =
              match
                List.for_all2
                  callee_prefix_parameters
                  prefix_arguments
                  ~f:parameter_matches_argument
              with
              | Ok all_arguments_match -> all_arguments_match
              | Unequal_lengths -> false
            in
            if all_arguments_match || wraps_original_function then (
              let suffix_parameters = List.drop new_parameters (List.length prefix_arguments) in
              inferred_args_kwargs_parameters := Some suffix_parameters;
              create_function_call
                ~location
                ~callee_name:(Reference.create callee_name)
                ~should_await:false
                (prefix_arguments
                @ List.map suffix_parameters ~f:(convert_parameter_to_argument ~location)))
            else (
              inferred_args_kwargs_parameters := None;
              expression)
        | _ ->
            (* The wrapper is calling the original function as something other than `original( <some
               arguments>, *args, **kwargs)`. This means it probably has a different signature from
               the original function, so give up on making it have the same signature. *)
            inferred_args_kwargs_parameters := None;
            expression)
    | expression -> expression
  in
  match
    ( Transform.transform_in_statement
        ~transform:pass_precise_arguments_instead_of_args_kwargs
        (Statement.Define define),
      !inferred_args_kwargs_parameters )
  with
  | Statement.Define define, Some inferred_args_kwargs_parameters ->
      Some (define, inferred_args_kwargs_parameters)
  | _ -> None


(* If a function always passes on its `args` and `kwargs` to `callee_name`, then replace its broad
   signature `def foo( *args, **kwargs) -> None` with the precise signature `def foo(x: int, y: str)
   -> None`. Pass precise arguments to any calls to `callee_name`.

   In order to support uses of `args` and `kwargs` within `wrapper_define`, we create synthetic
   local variables `_args` and `_kwargs` that contain all the arguments. *)
let replace_signature_if_always_passing_on_arguments
    ~callee_name
    ~new_signature:({ Define.Signature.parameters = new_parameters; _ } as new_signature)
    ({ Define.signature = { parameters = wrapper_parameters; _ }; _ } as wrapper_define)
  =
  match List.rev wrapper_parameters with
  | { Node.value = { name = kwargs_parameter; _ }; _ }
    :: { Node.value = { name = args_parameter; _ }; _ }
    :: remaining_parameters
    when String.is_prefix ~prefix:"*" args_parameter
         && (not (String.is_prefix ~prefix:"**" args_parameter))
         && String.is_prefix ~prefix:"**" kwargs_parameter ->
      let args_parameter = String.drop_prefix args_parameter 1 in
      let kwargs_parameter = String.drop_prefix kwargs_parameter 2 in
      let prefix_parameters = List.rev remaining_parameters in
      let callee_prefix_parameters = List.take new_parameters (List.length prefix_parameters) in

      (* We have to rename `args` and `kwargs` to `_args` and `_kwargs` before transforming calls to
         `callee`. We also have to rename any prefix parameters.

         Otherwise, if we rename them after replacing calls to `callee`, we might inadvertently
         rename any `args` or `kwargs` present in `callee`'s parameters. *)
      let define_with_renamed_parameters ({ Define.signature; _ } as define) =
        let define_with_original_signature =
          { define with signature = { signature with parameters = new_parameters } }
        in
        let make_parameter_name_pair
            { Node.value = { Parameter.name = current_name; _ }; _ }
            { Node.value = { Parameter.name = original_name; _ }; _ }
          =
          current_name, original_name
        in
        match List.map2 prefix_parameters callee_prefix_parameters ~f:make_parameter_name_pair with
        | Ok pairs ->
            let pairs =
              (args_parameter, args_local_variable_name)
              :: (kwargs_parameter, kwargs_local_variable_name)
              :: pairs
            in
            Some (rename_local_variables ~pairs define_with_original_signature)
        | Unequal_lengths -> None
      in
      let add_local_assignments_for_args_kwargs
          (({ Define.body; _ } as define), inferred_args_kwargs_parameters)
        =
        let args_local_assignment =
          make_args_assignment_from_parameters
            ~args_local_variable_name
            inferred_args_kwargs_parameters
        in
        let kwargs_local_assignment =
          make_kwargs_assignment_from_parameters
            ~kwargs_local_variable_name
            inferred_args_kwargs_parameters
        in
        { define with Define.body = args_local_assignment :: kwargs_local_assignment :: body }
      in
      define_with_renamed_parameters wrapper_define
      >>= call_function_with_precise_parameters
            ~callee_name
            ~callee_prefix_parameters
            ~new_signature
      >>| add_local_assignments_for_args_kwargs
  | _ -> None


let make_wrapper_define
    ~location
    ~relative_path
    ~qualifier
    ~parent_for_inner_defines
    ~define:
      ({
         Define.signature =
           { parent; legacy_parent; return_annotation = original_return_annotation; _ } as
           original_signature;
         _;
       } as define)
    ~function_to_call
    {
      wrapper_define =
        {
          Define.signature =
            { name = wrapper_define_name; return_annotation; _ } as wrapper_signature;
          _;
        } as wrapper_define;
      helper_defines;
      higher_order_function_parameter_name;
      decorator_reference;
      outer_decorator_reference;
      _;
    }
  =
  let decorator_reference = Reference.delocalize decorator_reference in
  let ({ Define.signature = wrapper_signature; _ } as wrapper_define) =
    let return_annotation =
      if Define.Signature.has_decorator ~match_prefix:true wrapper_signature "functools.wraps" then
        original_return_annotation
      else
        return_annotation
    in
    { wrapper_define with signature = { wrapper_signature with return_annotation } }
  in
  let ({ Define.body = wrapper_body; _ } as wrapper_define), outer_signature =
    match
      replace_signature_if_always_passing_on_arguments
        ~callee_name:higher_order_function_parameter_name
        ~new_signature:original_signature
        wrapper_define
    with
    | Some ({ Define.signature; _ } as wrapper_define) -> wrapper_define, signature
    | None -> wrapper_define, wrapper_signature
  in
  let inlined_wrapper_define_name = make_wrapper_function_name outer_decorator_reference in
  let wrapper_function_name = Reference.last inlined_wrapper_define_name in
  let outer_signature =
    { outer_signature with parent; legacy_parent; name = inlined_wrapper_define_name }
  in
  let wrapper_qualifier = Reference.create ~prefix:qualifier wrapper_function_name in
  let make_helper_define
      ({ Define.signature = { name = helper_function_name; _ }; _ } as helper_define)
    =
    let helper_function_reference = Reference.delocalize helper_function_name in
    let new_helper_function_reference =
      Reference.combine
        wrapper_qualifier
        (Reference.drop_prefix ~prefix:decorator_reference helper_function_reference)
    in
    sanitize_define ~strip_parent:true helper_define
    |> rename_define ~new_name:(Reference.create (Reference.last helper_function_reference))
    |> set_parent
         ~new_parent:
           (NestingContext.create_function ~parent:parent_for_inner_defines wrapper_function_name)
    |> requalify_define
         ~old_qualifier:helper_function_reference
         ~new_qualifier:new_helper_function_reference
         ~relative_path
    (* Requalify references to other nested functions within the decorator. *)
    |> requalify_define
         ~old_qualifier:decorator_reference
         ~new_qualifier:wrapper_qualifier
         ~relative_path
  in
  let helper_defines = List.map helper_defines ~f:make_helper_define in
  let helper_define_statements =
    List.map helper_defines ~f:(fun define -> Statement.Define define |> Node.create ~location)
  in
  let wrapper_define =
    sanitize_define
      ~strip_parent:true
      { wrapper_define with body = helper_define_statements @ wrapper_body }
    |> set_first_parameter_type ~original_define:define
    |> rename_define ~new_name:inlined_wrapper_define_name
    |> set_parent ~new_parent:parent_for_inner_defines
    |> requalify_define
         ~old_qualifier:(Reference.delocalize wrapper_define_name)
         ~new_qualifier:(Reference.create ~prefix:qualifier wrapper_function_name)
         ~relative_path
    (* Requalify references to other nested functions within the decorator. *)
    |> requalify_define
         ~old_qualifier:decorator_reference
         ~new_qualifier:wrapper_qualifier
         ~relative_path
    |> rename_local_variable
         ~from:higher_order_function_parameter_name
         ~to_:(Preprocessing.get_qualified_local_identifier ~qualifier function_to_call)
  in
  List.iter
    helper_defines
    ~f:
      (add_function_decorator_module_mapping
         ~qualifier:wrapper_qualifier
         ~outer_decorator_reference);
  add_function_decorator_module_mapping ~qualifier ~outer_decorator_reference wrapper_define;
  wrapper_define, outer_signature


let inline_decorators_at_same_scope
    ~location
    ~head_decorator:
      ({
         outer_decorator_reference = head_outer_decorator_reference;
         decorator_call_location = head_decorator_call_location;
         _;
       } as head_decorator)
    ~tail_decorators
    ~relative_path
    ({ Define.signature = { name; parent; _ }; _ } as define)
  =
  let inlinable_decorators = head_decorator :: tail_decorators in
  let qualifier = Reference.delocalize name in
  let parent_for_inner_defines =
    NestingContext.create_function ~parent (Reference.last qualifier)
  in
  let ({ Define.signature = inlined_original_define_signature; _ } as inlined_original_define) =
    sanitize_define ~strip_parent:true define
    |> set_first_parameter_type ~original_define:define
    |> rename_define ~new_name:(Reference.create inlined_original_function_name)
    |> set_parent ~new_parent:parent_for_inner_defines
    |> requalify_define
         ~old_qualifier:qualifier
         ~new_qualifier:(Reference.create ~prefix:qualifier inlined_original_function_name)
         ~relative_path
  in
  let wrapper_defines, outer_signature =
    let inline_wrapper_and_call_previous_wrapper
        (wrapper_defines, { Define.Signature.name = previous_inlined_wrapper; _ })
        decorator_data
      =
      let wrapper_define, new_signature =
        make_wrapper_define
          ~location
          ~relative_path
          ~qualifier
          ~parent_for_inner_defines
          ~define
          ~function_to_call:(Reference.last (Reference.delocalize previous_inlined_wrapper))
          decorator_data
      in
      wrapper_define :: wrapper_defines, new_signature
    in
    List.fold
      (List.rev inlinable_decorators)
      ~init:([], inlined_original_define_signature)
      ~f:inline_wrapper_and_call_previous_wrapper
  in
  let wrapper_define_statements =
    List.map wrapper_defines ~f:(fun define -> Statement.Define define |> Node.create ~location)
    |> List.rev
  in
  let return_call_to_wrapper =
    Statement.Return
      {
        is_implicit = false;
        expression =
          Some
            (create_function_call_to
               ~location:head_decorator_call_location
               ~callee_name:(make_wrapper_function_name head_outer_decorator_reference)
               outer_signature
            |> Node.create ~location);
      }
    |> Node.create ~location
  in
  let inlined_original_define_statement =
    Statement.Define inlined_original_define |> Node.create ~location
  in
  let body =
    [inlined_original_define_statement] @ wrapper_define_statements @ [return_call_to_wrapper]
  in
  { define with body; signature = outer_signature }
  |> sanitize_define
  |> rename_define ~new_name:qualifier


let postprocess
    ~relative_path
    ~define
    ~location
    ({ Define.signature = { decorators; _ } as signature; _ } as decorated_define)
  =
  let signature =
    if Define.is_class_method define then
      {
        signature with
        decorators =
          Node.create_with_default_location (Expression.Name (Name.Identifier "classmethod"))
          :: decorators;
      }
    else if Define.is_static_method define then
      {
        signature with
        decorators =
          Node.create_with_default_location (Expression.Name (Name.Identifier "staticmethod"))
          :: decorators;
      }
    else
      signature
  in
  let statement = { Node.location; value = Statement.Define { decorated_define with signature } } in
  Source.create ~relative:relative_path [statement]
  |> Preprocessing.qualify
  |> Preprocessing.populate_captures
  |> Source.statements
  |> function
  | [{ Node.value = Statement.Define define; _ }] -> Some define
  | _ -> None


module Decorators = struct
  type t = Define.t list

  let prefix = Hack_parallel.Std.Prefix.make ()

  let description = "Decorators from a module."
end

(** Mapping from a module reference to all decorators defined within it. *)
module ModuleDecorators = Memory.WithCache.Make (SharedMemoryKeys.ReferenceKey) (Decorators)

let find_decorator_body ~get_source decorator_reference =
  let module DecoratorCollector = Visit.StatementCollector (struct
    type t = Define.t

    let visit_children _ = false

    let predicate = function
      | { Node.value = Statement.Define ({ body; _ } as define); _ } ->
          if
            List.exists body ~f:(function
                | { Node.value = Statement.Define _; _ } -> true
                | _ -> false)
          then
            Some define
          else
            None
      | _ -> None
  end)
  in
  let module_decorators module_reference =
    match ModuleDecorators.get module_reference with
    | Some decorators -> Some decorators
    | None ->
        get_source module_reference
        >>| Preprocessing.qualify
        >>| DecoratorCollector.collect
        >>| fun decorators ->
        ModuleDecorators.add module_reference decorators;
        decorators
  in
  Reference.prefix decorator_reference
  >>= module_decorators
  >>= List.find ~f:(fun define -> Reference.equal (Define.name define) decorator_reference)


let has_decorator_action decorator_name action =
  Option.equal Action.equal (DecoratorActionsSharedMemory.get decorator_name) (Some action)


let has_any_decorator_action ~actions decorator =
  match Decorator.from_expression decorator with
  | None -> true
  | Some { Decorator.name = { Node.value = decorator_name; _ }; _ } ->
      Action.Set.exists (fun action -> has_decorator_action decorator_name action) actions


let discard_decorators_for_define define =
  let actions = Action.Set.singleton Action.Discard in
  let decorators =
    define
    |> get_define_decorators
    |> List.filter ~f:(fun decorator -> not (has_any_decorator_action ~actions decorator))
  in
  { define with Define.signature = { define.signature with decorators } }


let inline_decorators_for_define ~get_source ~location ~relative_path define =
  let uniquify_decorator_data_list =
    uniquify_names
      ~get_reference:(fun { outer_decorator_reference; _ } -> outer_decorator_reference)
      ~set_reference:(fun reference decorator_data ->
        { decorator_data with outer_decorator_reference = reference })
  in
  let find_decorator_data decorator =
    match Decorator.from_expression decorator with
    | None -> None
    | Some { Decorator.name = { Node.value = decorator_name; _ }; _ }
      when has_decorator_action decorator_name Action.DoNotInline ->
        None
    | Some
        {
          Decorator.name = { Node.value = decorator_name; location = decorator_call_location };
          arguments;
          original_expression = _;
        } ->
        find_decorator_body ~get_source decorator_name
        >>= extract_decorator_data
              ~decorator_call_location
              ~is_decorator_factory:(Option.is_some arguments)
  in
  let inlinable_decorators =
    define
    |> get_define_decorators
    |> List.filter_map ~f:find_decorator_data
    |> uniquify_decorator_data_list
  in
  match inlinable_decorators with
  | [] -> define
  | head_decorator :: tail_decorators ->
      inline_decorators_at_same_scope
        ~location
        ~head_decorator
        ~tail_decorators
        ~relative_path
        define
      |> postprocess ~relative_path ~define ~location
      |> Option.value ~default:define


let preprocess_source ~get_source source =
  let should_inline = OptionsSharedMemory.get "enable_inlining" |> Option.value ~default:false in
  let should_discard = OptionsSharedMemory.get "enable_discarding" |> Option.value ~default:false in
  let {
    Source.module_path = { ModulePath.raw = { ModulePath.Raw.relative = relative_path; _ }; _ };
    _;
  }
    =
    source
  in
  let module Transform = Transform.Make (struct
    type t = unit

    let transform_expression_children _ _ = true

    let transform_children state _ = state, true

    let expression _ expression = expression

    let statement _ statement =
      let statement =
        match statement with
        | { Node.value = Statement.Define original_define; location } ->
            let define =
              if should_discard then
                discard_decorators_for_define original_define
              else
                original_define
            in
            let define =
              if should_inline then
                inline_decorators_for_define ~get_source ~location ~relative_path define
              else
                define
            in
            let () = add_original_decorators_mapping ~original_define ~new_define:define in
            { statement with value = Statement.Define define }
        | _ -> statement
      in
      (), [statement]
  end)
  in
  if should_inline || should_discard then
    Transform.transform () source |> Transform.source
  else
    source
