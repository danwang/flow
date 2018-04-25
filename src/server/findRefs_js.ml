(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Utils_js
open ServerEnv

module Result = Core_result
let (>>=) = Result.(>>=)
let (>>|) = Result.(>>|)

(* The problem with Core_result's >>= and >>| is that the function second argument cannot return
 * an Lwt.t. These helper infix operators handle that case *)
let (%>>=) (result: ('ok, 'err) Result.t) (f: 'ok -> ('a, 'err) Result.t Lwt.t) : ('a, 'err) Result.t Lwt.t =
  match result with
  | Error e -> Lwt.return (Error e)
  | Ok x -> f x

let (%>>|) (result: ('ok, 'err) Result.t) (f: 'ok -> 'a Lwt.t) : ('a, 'err) Result.t Lwt.t =
  match result with
  | Error e -> Lwt.return (Error e)
  | Ok x ->
    let%lwt new_x = f x in
    Lwt.return (Ok new_x)

let compute_docblock file content =
  let open Parsing_service_js in
  let max_tokens = docblock_max_tokens in
  let _errors, docblock = parse_docblock ~max_tokens file content in
  docblock

(* We use compute_ast_result (as opposed to get_ast_result) when the file contents we have might be
 * different from what's on disk (and what is therefore stored in shared memory). This can be the
 * case for local find-refs requests, where the client may pipe in file contents rather than just
 * specifying a filename. For global find-refs, we assume that all dependent files are the same as
 * what's on disk, so we can grab the AST from the heap instead. *)
let compute_ast_result file content =
  let docblock = compute_docblock file content in
  let open Parsing_service_js in
  let types_mode = TypesAllowed in
  let use_strict = true in
  let result = do_parse ~fail:false ~types_mode ~use_strict ~info:docblock content file in
  match result with
    | Parse_ok (ast, file_sig) -> Ok (ast, file_sig, docblock)
    (* The parse should not fail; we have passed ~fail:false *)
    | Parse_fail _ -> Error "Parse unexpectedly failed"
    | Parse_skip _ -> Error "Parse unexpectedly skipped"

let get_ast_result file : (Loc.t Ast.program * File_sig.t * Docblock.t, string) result =
  let open Parsing_service_js in
  let get_result f kind =
    let error =
      Printf.sprintf "Expected %s to be available for %s"
        kind
        (File_key.to_string file)
    in
    Result.of_option ~error (f file)
  in
  let ast_result = get_result get_ast "AST" in
  let file_sig_result = get_result get_file_sig "file sig" in
  let docblock_result = get_result get_docblock "docblock" in
  ast_result >>= fun ast ->
  file_sig_result >>= fun file_sig ->
  docblock_result >>= fun docblock ->
  Ok (ast, file_sig, docblock)

let get_dependents options workers env file_key content =
  let docblock = compute_docblock file_key content in
  let modulename = Module_js.exported_module options file_key docblock in
  Dep_service.dependent_files
    workers
    (* Surprisingly, creating this set doesn't seem to cause horrible performance but it's
    probably worth looking at if you are searching for optimizations *)
    ~unchanged:ServerEnv.(CheckedSet.all !env.checked_files)
    ~new_or_changed:(FilenameSet.singleton file_key)
    ~changed_modules:(Modulename.Set.singleton modulename)

let lazy_mode_focus genv env path =
  let%lwt env, _ = Lazy_mode_utils.focus_and_check genv env (Nel.one path) in
  Lwt.return env

module VariableRefs: sig
  val find_refs:
    ServerEnv.genv ->
    ServerEnv.env ref ->
    File_key.t ->
    content: string ->
    Loc.t ->
    global: bool ->
    ((string * Loc.t list * int option) option, string) result Lwt.t
end = struct

  (* Sometimes we want to find a specific symbol in a dependent file, but other
   * times we know that we want whatever symbol the import is assigned to. *)
  type import_query =
    | Symbol of string
    | CJSIdent

  let get_imported_locations (query: import_query) file_key (dep_file_key: File_key.t) : (Loc.t list, string) result =
    let open File_sig in
    get_ast_result dep_file_key >>| fun (_, file_sig, _) ->
    let is_relevant mref =
      let resolved = Module_js.find_resolved_module
        ~audit:Expensive.warn
        dep_file_key
        mref
      in
      match Module_js.get_file ~audit:Expensive.warn resolved with
      | None -> false
      | Some x -> x = file_key
    in
    let locs = List.fold_left (fun acc require ->
      match require with
      | Require { source = (_, mref); bindings = Some bindings; _ } ->
        if not (is_relevant mref) then acc else
        begin match bindings with
        | BindIdent (loc, _) ->
          if query = CJSIdent
          then loc::acc
          else acc
        | BindNamed bindings ->
          SMap.fold (fun _ (local_loc, (_, remote)) acc ->
            if query = Symbol remote
            then local_loc::acc
            else acc
          ) bindings acc
        end
      | Require _
      | ImportDynamic _
      | Import0 _ -> acc
      | Import { source = (_, mref); named; _ } ->
        if not (is_relevant mref) then acc else
        match query with
        | Symbol symbol -> begin match SMap.get symbol named with
          | None -> acc
          | Some local_name_to_locs ->
            SMap.fold (fun _ locs acc ->
              List.rev_append (Nel.to_list locs) acc
            ) local_name_to_locs acc
          end
        | _ -> acc
    ) [] file_sig.module_sig.requires in
    List.fast_sort Loc.compare locs


  let local_find_refs file_key ~content loc =
    let open File_sig in
    let open Scope_api in
    compute_ast_result file_key content >>= fun (ast, file_sig, _) ->
    let scope_info = Scope_builder.program ast in
    let all_uses = all_uses scope_info in
    let matching_uses = LocSet.filter (fun use -> Loc.contains use loc) all_uses in
    let num_matching_uses = LocSet.cardinal matching_uses in
    if num_matching_uses = 0 then begin match file_sig.module_sig.module_kind with
    | CommonJS { exports = Some (CJSExportIdent (id_loc, id_name)) }
      when Loc.contains id_loc loc -> Ok (Some (id_name, [id_loc]))
    | CommonJS { exports = Some (CJSExportProps props) } ->
      let props = SMap.filter (fun _ (CJSExport prop) -> Loc.contains prop.loc loc) props in
      begin match SMap.choose props with
      | Some (prop_name, CJSExport prop) -> Ok (Some (prop_name, [prop.loc]))
      | None -> Ok None
      end
    | _ -> Ok None
    end
    else if num_matching_uses > 1 then Error "Multiple identifiers were unexpectedly matched"
    else
      let use = LocSet.choose matching_uses in
      let def = def_of_use scope_info use in
      let sorted_locs = LocSet.elements @@ uses_of_def scope_info ~exclude_def:false def in
      let name = Def.(def.actual_name) in
      Ok (Some (name, sorted_locs))

  let find_external_refs genv env file_key ~content ~query local_refs =
    let {options; workers} = genv in
    File_key.to_path file_key %>>= fun path ->
    let%lwt new_env = lazy_mode_focus genv !env path in
    env := new_env;
    let%lwt _, direct_dependents = get_dependents options workers env file_key content in
    (* Get a map from dependent file path to locations where the symbol in question is imported in
    that file *)
    let imported_locations_result: (Loc.t list, string) result =
      FilenameSet.elements direct_dependents |>
        List.map (get_imported_locations query file_key) |>
        Result.all >>= fun loc_lists ->
        Ok (List.concat loc_lists)
    in
    Lwt.return (
      imported_locations_result >>= fun imported_locations ->
      let all_external_locations =
        imported_locations |>
        List.map begin fun imported_loc ->
          let filekey_result =
            Result.of_option
              Loc.(imported_loc.source)
              ~error:"local_find_refs should return locs with sources"
          in
          filekey_result >>= fun filekey ->
          File_key.to_path filekey >>= fun path ->
          let file_input = File_input.FileName path in
          File_input.content_of_file_input file_input >>= fun content ->
          local_find_refs filekey ~content imported_loc >>= fun refs_option ->
          Result.of_option refs_option ~error:"Expected results from local_find_refs" >>= fun (_name, locs) ->
          Ok locs
        end |>
        Result.all >>= fun locs ->
        Ok (List.concat locs)
      in
      all_external_locations >>= fun all_external_locations ->
      Ok (all_external_locations @ local_refs, FilenameSet.cardinal direct_dependents)
    )

  let find_refs genv env file_key ~content loc ~global =
    (* TODO right now we assume that the symbol was defined in the given file. do a get-def or similar
    first *)
    local_find_refs file_key content loc %>>= function
      | None -> Lwt.return (Ok None)
      | Some (name, refs) ->
          if global then
            compute_ast_result file_key content %>>= fun (_, file_sig, _) ->
            let open File_sig in
            let find_exported_loc loc query =
              if List.mem loc refs then
                let%lwt all_refs_result = find_external_refs genv env file_key content query refs in
                all_refs_result %>>= fun (all_refs, num_deps) ->
                Lwt.return (Ok (Some (name, all_refs, Some num_deps)))
              else
                Lwt.return (Ok (Some (name, refs, None))) in
            begin match file_sig.module_sig.module_kind with
              | CommonJS { exports = None } -> Lwt.return (Ok (Some (name, refs, None)))
              | CommonJS { exports = Some (CJSExportIdent (id_loc, id_name)) } ->
                if id_name = name
                then find_exported_loc id_loc CJSIdent
                else Lwt.return (Ok (Some (name, refs, None)))
              | CommonJS { exports = Some CJSExportOther } ->
                Lwt.return (Ok (Some (name, refs, None)))
              | CommonJS { exports = Some (CJSExportProps props) } ->
                begin match SMap.get name props with
                  | None -> Lwt.return (Ok (Some (name, refs, None)))
                  | Some (CJSExport { loc; _ }) -> find_exported_loc loc (Symbol name)
                end
              | ES {named; _} -> begin match SMap.get name named with
                  | None -> Lwt.return (Ok (Some (name, refs, None)))
                  | Some (File_sig.ExportDefault _) -> Lwt.return (Ok (Some (name, refs, None)))
                  | Some (File_sig.ExportNamed { loc; _ } | File_sig.ExportNs { loc; _ }) ->
                      find_exported_loc loc (Symbol name)
                end
            end
          else
            Lwt.return (Ok (Some (name, refs, None)))
end

module PropertyRefs: sig
  val find_refs:
    ServerEnv.genv ->
    ServerEnv.env ref ->
    profiling: Profiling_js.running ->
    content: string ->
    File_key.t ->
    Loc.t ->
    global: bool ->
    ((string * Loc.t list * int option) option, string) result Lwt.t

end = struct

  (* The default visitor does not provide all of the context we need when visiting an object key. In
   * particular, we need the location of the enclosing object literal. *)
  class ['acc] object_key_visitor ~init = object(this)
    inherit ['acc] Flow_ast_visitor.visitor ~init as super

    method! expression (exp: Loc.t Ast.Expression.t) =
      let open Ast.Expression in
      begin match exp with
      | loc, Object x ->
        this#visit_object_literal loc x
      | _ -> ()
      end;
      super#expression exp

    method private visit_object_literal (loc: Loc.t) (obj: Loc.t Ast.Expression.Object.t) =
      let open Ast.Expression.Object in
      let get_prop_key =
        let open Property in
        function Init { key; _ } | Method { key; _ } | Get { key; _ } | Set { key; _ } -> key
      in
      let { properties } = obj in
      properties
      |> List.iter begin function
        | SpreadProperty _ -> ()
        | Property (_, prop) -> prop |> get_prop_key |> this#visit_object_key loc
      end

    method private visit_object_key
        (_literal_loc: Loc.t)
        (_key: Loc.t Ast.Expression.Object.Property.key) =
      ()
  end

  module ObjectKeyAtLoc : sig
    (* Given a location, returns Some (enclosing_literal_loc, name) if the given location points to
     * an object literal key. The location returned is the location for the entire enclosing object
     * literal. This is because later, we need to figure out which types are related to this object
     * literal which is easier to do when we have the location of the actual object literal than if
     * we only had the location of a single key. *)
    val get: Loc.t Ast.program -> Loc.t -> (Loc.t * string) option
  end = struct
    class object_key_finder target_loc = object(this)
      inherit [(Loc.t * string) option] object_key_visitor ~init:None
      method! private visit_object_key
          (literal_loc: Loc.t)
          (key: Loc.t Ast.Expression.Object.Property.key) =
        let open Ast.Expression.Object in
        match key with
        | Property.Identifier (prop_loc, name) when Loc.contains prop_loc target_loc ->
          this#set_acc (Some (literal_loc, name))
        | _ -> ()
    end

    let get ast target_loc =
      let finder = new object_key_finder target_loc in
      finder#eval finder#program ast
  end

  module LiteralToPropLoc : sig
    (* Returns a map from object_literal_loc to prop_loc, for all object literals which contain the
     * given property name. *)
    val make: Loc.t Ast.program -> prop_name: string -> Loc.t LocMap.t
  end = struct
    class locmap_builder prop_name = object(this)
      inherit [Loc.t LocMap.t] object_key_visitor ~init:LocMap.empty
      method! private visit_object_key
          (literal_loc: Loc.t)
          (key: Loc.t Ast.Expression.Object.Property.key) =
        let open Ast.Expression.Object in
        match key with
        | Property.Identifier (prop_loc, name) when name = prop_name ->
            this#update_acc (fun map -> LocMap.add literal_loc prop_loc map)
          (* TODO consider supporting other property keys (e.g. literals). Also update the
           * optimization in property_access_searcher below when this happens. *)
        | _ -> ()
    end

    let make ast ~prop_name =
      let builder = new locmap_builder prop_name in
      builder#eval builder#program ast
  end

  class property_access_searcher name = object(this)
    inherit [bool] Flow_ast_visitor.visitor ~init:false as super
    method! member expr =
      let open Ast.Expression.Member in
      begin match expr.property with
        | PropertyIdentifier (_, x) when x = name ->
            this#set_acc true
        | _ -> ()
      end;
      super#member expr
    method! object_key (key: Loc.t Ast.Expression.Object.Property.key) =
      let open Ast.Expression.Object.Property in
      begin match key with
      | Identifier (_, x) when x = name ->
        this#set_acc true
      | _ -> ()
      end;
      super#object_key key
  end

  (* Returns true iff the given AST contains an access to a property with the given name *)
  let check_for_matching_prop name ast =
    let checker = new property_access_searcher name in
    checker#eval checker#program ast

  (* If the given type refers to an object literal, return the location of the object literal.
   * Otherwise return None *)
  let get_object_literal_loc ty : Loc.t option =
    let open Type in
    let open Reason in
    let reason_desc =
      reason_of_t ty
      (* TODO look into unwrap *)
      |> desc_of_reason ~unwrap:false
    in
    match reason_desc with
    | RObjectLit -> Some (Type.def_loc_of_t ty)
    | _ -> None

  type def_kind =
    (* Use of a property, e.g. `foo.bar`. Includes type of receiver (`foo`) and name of the property
     * `bar` *)
    | Use of Type.t * string
    (* In a class, where a property/method is defined. Includes the type of the class and the name
    of the property. *)
    | Class_def of Type.t * string (* name *)
    (* In an object type. Includes the location of the property definition and its name. *)
    | Obj_def of Loc.t * string (* name *)
    (* List of types that the object literal flows into directly, as well as the name of the
     * property. *)
    | Use_in_literal of Type.t Nel.t * string (* name *)

  let set_def_loc_hook prop_access_info literal_key_info target_loc =
    let set_prop_access_info new_info =
      let set_ok info = prop_access_info := Ok (Some info) in
      let set_err err = prop_access_info := Error err in
      match !prop_access_info with
        | Error _ -> ()
        | Ok None -> prop_access_info := Ok (Some new_info)
        | Ok (Some info) -> begin match info, new_info with
          | Use _, Use _
          | Class_def _, Class_def _
          | Obj_def _, Obj_def _ ->
            (* Due to generate_tests, we sometimes see hooks firing multiple times for the same
             * location. This is innocuous and we should take the last result. *)
            set_ok new_info
          (* Literals can flow into multiple types. Include them all. *)
          | Use_in_literal (types, name), Use_in_literal (new_types, new_name) ->
            if name = new_name then
              set_ok (Use_in_literal (Nel.rev_append new_types types, name))
            else
              set_err "Names did not match"
          (* We should not see mismatches. *)
          |  Use _, _ | Class_def _, _ | Obj_def _, _ | Use_in_literal _, _ ->
            set_err "Unexpected mismatch between definition kind"
        end
    in
    let use_hook ret _ctxt name loc ty =
      begin if Loc.contains loc target_loc then
        set_prop_access_info (Use (ty, name))
      end;
      ret
    in
    let class_def_hook _ctxt ty name loc =
      if Loc.contains loc target_loc then
        set_prop_access_info (Class_def (ty, name))
    in
    let obj_def_hook _ctxt name loc =
      if Loc.contains loc target_loc then
        set_prop_access_info (Obj_def (loc, name))
    in
    let obj_to_obj_hook _ctxt obj1 obj2 =
      match get_object_literal_loc obj1, literal_key_info with
      | Some loc, Some (target_loc, name) when loc = target_loc ->
        let open Type in
        begin match obj2 with
        | UseT (_, (DefT (_, ObjT _) as t2)) ->
          set_prop_access_info (Use_in_literal (Nel.one t2, name))
        | _ -> ()
        end
      | _ -> ()
    in

    Type_inference_hooks_js.set_member_hook (use_hook false);
    Type_inference_hooks_js.set_call_hook (use_hook ());
    Type_inference_hooks_js.set_class_member_decl_hook class_def_hook;
    Type_inference_hooks_js.set_obj_prop_decl_hook obj_def_hook;
    Type_inference_hooks_js.set_obj_to_obj_hook obj_to_obj_hook

  let set_get_refs_hook potential_refs potential_matching_literals target_name =
    let hook ret _ctxt name loc ty =
      begin if name = target_name then
        (* Replace previous bindings of `loc`. We should always use the result of the last call to
         * the hook for a given location. For details see the comment on the generate_tests function
         * in flow_js.ml *)
        potential_refs := LocMap.add loc ty !potential_refs
      end;
      ret
    in
    let obj_to_obj_hook _ctxt obj1 obj2 =
      let open Type in
      match get_object_literal_loc obj1, obj2 with
      | Some loc, UseT (_, (DefT (_, ObjT _) as t2)) ->
        let entry = (loc, t2) in
        potential_matching_literals := entry:: !potential_matching_literals
      | _ -> ()
    in

    Type_inference_hooks_js.set_member_hook (hook false);
    Type_inference_hooks_js.set_call_hook (hook ());
    Type_inference_hooks_js.set_obj_to_obj_hook obj_to_obj_hook

  let unset_hooks () =
    Type_inference_hooks_js.reset_hooks ()

  type def_info =
    (* Superclass implementations are also included. The list is ordered such that subclass
     * implementations are first and superclass implementations are last. *)
    | Class of Loc.t Nel.t
    (* An object was found. If there are multiple relevant definition locations
     * (e.g. the request was issued on an object literal which is associated
     * with multiple types) then there will be multiple locations in no
     * particular order. *)
    | Object of Loc.t Nel.t

  let all_locs_of_def_info = function
    | Class locs
    | Object locs -> locs

  type def_loc =
    (* We found a class property. Include all overridden implementations. Superclass implementations
     * are listed last. *)
    | FoundClass of Loc.t Nel.t
    (* We found an object property. *)
    | FoundObject of Loc.t
    (* This means we resolved the receiver type but did not find the definition. If this happens
     * there must be a type error (which may be suppresssed) *)
    | NoDefFound
    (* This means it's a known type that we deliberately do not currently support. *)
    | UnsupportedType
    (* This means it's not well-typed, and could be anything *)
    | AnyType

  let debug_string_of_locs locs =
    locs |> Nel.to_list |> List.map Loc.to_string |> String.concat ", "

  (* Disable the unused value warning -- we want to keep this around for debugging *)
  [@@@warning "-32"]
  let debug_string_of_def_info = function
    | Class locs -> spf "Class (%s)" (debug_string_of_locs locs)
    | Object locs -> spf "Object (%s)" (debug_string_of_locs locs)

  let debug_string_of_def_loc = function
    | FoundClass locs -> spf "FoundClass (%s)" (debug_string_of_locs locs)
    | FoundObject loc -> spf "FoundObject (%s)" (Loc.to_string loc)
    | NoDefFound -> "NoDefFound"
    | UnsupportedType -> "UnsupportedType"
    | AnyType -> "AnyType"
  (* Re-enable the unused value warning *)
  [@@@warning "+32"]

  let extract_instancet cx ty : (Type.t, string) result =
    let open Type in
    let resolved = Flow_js.resolve_type cx ty in
    match resolved with
      | ThisClassT (_, t)
      | DefT (_, PolyT (_, ThisClassT (_, t), _)) -> Ok t
      | _ ->
        let type_string = string_of_ctor resolved in
        Error ("Expected a class type to extract an instance type from, got " ^ type_string)

  (* Must be called with the result from Flow_js.Members.extract_type *)
  let get_def_loc_from_extracted_type cx extracted_type name =
    extracted_type
    |> Flow_js.Members.extract_members cx
    |> Flow_js.Members.to_command_result
    >>| fun map -> match SMap.get name map with
      | None -> None
      (* Currently some types (e.g. spreads) do not contain locations for their properties. For now
       * we'll just treat them as if the properties do not exist, but once this is fixed this case
       * should be promoted to an error *)
      | Some (None, _) -> None
      | Some (Some loc, _) -> Some loc

  let rec extract_def_loc cx ty name : (def_loc, string) result =
    let resolved = Flow_js.resolve_type cx ty in
    extract_def_loc_resolved cx resolved name

  (* The same as get_def_loc_from_extracted_type except it recursively checks for overridden
   * definitions of the member in superclasses and returns those as well *)
  and extract_def_loc_from_instancet cx extracted_type super name : (def_loc, string) result =
    let current_class_def_loc = get_def_loc_from_extracted_type cx extracted_type name in
    current_class_def_loc
    >>= begin function
      | None -> Ok NoDefFound
      | Some loc ->
        extract_def_loc cx super name
        >>= begin function
          | FoundClass lst ->
              (* Avoid duplicate entries. This can happen if a class does not override a method,
               * so the definition points to the method definition in the parent class. Then we
               * look at the parent class and find the same definition. *)
              let lst =
                if Nel.hd lst = loc then
                  lst
                else
                  Nel.cons loc lst
              in
              Ok (FoundClass lst)
          | FoundObject _ -> Error "A superclass should be a class, not an object"
          (* If the superclass does not have a definition for this method, or it is for some reason
           * not a class type, or we don't know its type, just return the location we already know
           * about. *)
          | NoDefFound | UnsupportedType | AnyType -> Ok (FoundClass (Nel.one loc))
        end
    end

  and extract_def_loc_resolved cx ty name : (def_loc, string) result =
    let open Flow_js.Members in
    let open Type in
    match Flow_js.Members.extract_type cx ty with
      | Success (DefT (_, InstanceT (_, super, _, _))) as extracted_type ->
          extract_def_loc_from_instancet cx extracted_type super name
      | Success (DefT (_, ObjT _)) as extracted_type ->
          get_def_loc_from_extracted_type cx extracted_type name
          >>| begin function
            | None -> NoDefFound
            | Some loc -> FoundObject loc
          end
      | Success _
      | SuccessModule _
      | FailureNullishType
      | FailureUnhandledType _ ->
          Ok UnsupportedType
      | FailureAnyType ->
          Ok AnyType

  (* Returns `true` iff the given type is a reference to the symbol we are interested in *)
  let type_matches_locs cx ty def_info name =
    extract_def_loc cx ty name >>| function
      | FoundClass ty_def_locs ->
        begin match def_info with
          | Object _ -> false
          | Class def_locs ->
            (* Only take the first extracted def loc -- that is, the one for the actual definition
             * and not overridden implementations, and compare it to the list of def locs we are
             * interested in *)
            let loc = Nel.hd ty_def_locs in
            Nel.mem loc def_locs
        end
      | FoundObject loc ->
        begin match def_info with
        | Class _ -> false
        | Object def_locs -> Nel.mem loc def_locs
        end
      (* TODO we may want to surface AnyType results somehow since we can't be sure whether they
       * are references or not. For now we'll leave them out. *)
      | NoDefFound | UnsupportedType | AnyType -> false

  let filter_refs cx potential_refs file_key local_defs def_locs name =
    potential_refs |>
      LocMap.bindings |>
      (* The location where a shadow prop is introduced is considered both a definition and a use.
       * Make sure we include it only once despite that. *)
      List.filter (fun (loc, _) -> not (List.mem loc local_defs)) |>
      List.map begin fun (ref_loc, ty) ->
        type_matches_locs cx ty def_locs name
        >>| function
        | true -> Some ref_loc
        | false -> None
      end
      |> Result.all
      |> Result.map_error ~f:(fun err ->
          Printf.sprintf
            "Encountered while finding refs in `%s`: %s"
            (File_key.to_string file_key)
            err
        )
      >>|
      List.fold_left (fun acc -> function None -> acc | Some loc -> loc::acc) []

  let find_refs_in_file options ast_info file_key def_info name =
    let potential_refs: Type.t LocMap.t ref = ref LocMap.empty in
    let potential_matching_literals: (Loc.t * Type.t) list ref = ref [] in
    let (ast, file_sig, info) = ast_info in
    let local_defs =
      let all_def_locs = match def_info with Class locs | Object locs -> locs in
      Nel.to_list all_def_locs
      |> List.filter (fun loc -> loc.Loc.source = Some file_key)
    in
    let has_symbol = check_for_matching_prop name ast in
    if not has_symbol then
      Ok local_defs
    else begin
      set_get_refs_hook potential_refs potential_matching_literals name;
      let cx = Merge_service.merge_contents_context_without_ensure_checked_dependencies
        options file_key ast info file_sig
      in
      unset_hooks ();
      let literal_prop_refs_result =
        (* Lazy to avoid this computation if there are no potentially-relevant object literals to
         * examine *)
        let prop_loc_map = lazy (LiteralToPropLoc.make ast name) in
        let get_prop_loc_if_relevant (obj_loc, into_type) =
          type_matches_locs cx into_type def_info name
          >>| function
          | false -> None
          | true -> LocMap.get obj_loc (Lazy.force prop_loc_map)
        in
        !potential_matching_literals
        |> List.map get_prop_loc_if_relevant
        |> Result.all
        >>| ListUtils.cat_maybes
      in
      literal_prop_refs_result
      >>= begin fun literal_prop_refs_result ->
        filter_refs cx !potential_refs file_key local_defs def_info name
        >>| (@) local_defs
        >>| (@) literal_prop_refs_result
      end
    end

  let find_refs_in_multiple_files genv all_deps def_info name =
    let {options; workers} = genv in
    let dep_list: File_key.t list = FilenameSet.elements all_deps in
    let node_modules_containers = !Files.node_modules_containers in
    let%lwt result = MultiWorkerLwt.call workers
      ~job: begin fun _acc deps ->
        (* Yay for global mutable state *)
        Files.node_modules_containers := node_modules_containers;
        deps |> List.map begin fun dep ->
          get_ast_result dep >>= fun ast_info ->
          find_refs_in_file options ast_info dep def_info name
        end
      end
      ~merge: (fun refs acc -> List.rev_append refs acc)
      ~neutral: []
      ~next: (MultiWorkerLwt.next workers dep_list)
    in
    (* The types got a little too complicated here. Writing out the intermediate types makes it a
     * bit clearer. *)
    let result: (Loc.t list list, string) Result.t = Result.all result in
    let result: (Loc.t list, string) Result.t = result >>| List.concat in
    Lwt.return result

  (* Returns the file(s) at which we should begin looking downstream for references. *)
  let roots_of_def_info def_info : (File_key.t Nel.t, string) result =
    let root_locs = all_locs_of_def_info def_info in
    let file_keys =
      Nel.map (fun loc -> loc.Loc.source) root_locs
      |> Nel.map (Result.of_option ~error:"Expected a location with a source file")
    in
    Nel.result_all file_keys

  let deps_of_file_key genv env (file_key: File_key.t) : (FilenameSet.t, string) result Lwt.t =
    let {options; workers} = genv in
    File_key.to_path file_key %>>= fun path ->
    let fileinput = File_input.FileName path in
    File_input.content_of_file_input fileinput %>>| fun content ->
    let%lwt all_deps, _ = get_dependents options workers env file_key content in
    Lwt.return all_deps

  let deps_of_file_keys genv env (file_keys: File_key.t list) : (FilenameSet.t, string) result Lwt.t =
    (* We need to use map_s (rather than map_p) because we cannot interleave calls into
     * MultiWorkers. *)
    let%lwt deps_result = Lwt_list.map_s (deps_of_file_key genv env) file_keys in
    Result.all deps_result %>>| fun (deps: FilenameSet.t list) ->
    Lwt.return @@ List.fold_left FilenameSet.union FilenameSet.empty deps

  let find_refs genv env ~profiling ~content file_key loc ~global =
    let options, workers = genv.options, genv.workers in
    let get_def_info: unit -> ((def_info * string) option, string) result Lwt.t = fun () ->
      let props_access_info = ref (Ok None) in
      let%lwt cx_result =
        compute_ast_result file_key content
        %>>| fun (ast, file_sig, info) ->
          let literal_key_info: (Loc.t * string) option = ObjectKeyAtLoc.get ast loc in
          set_def_loc_hook props_access_info literal_key_info loc;
          Profiling_js.with_timer_lwt profiling ~timer:"MergeContents" ~f:(fun () ->
            let ensure_checked =
              Types_js.ensure_checked_dependencies ~options ~profiling ~workers ~env in
            Merge_service.merge_contents_context options file_key ast info file_sig ensure_checked
          )
      in
      unset_hooks ();
      Lwt.return (
        cx_result >>= fun cx ->
        let def_info_of_type name ty =
          extract_def_loc cx ty name >>| function
            | FoundClass locs -> Some (Class locs, name)
            | FoundObject loc -> Some (Object (Nel.one loc), name)
            | NoDefFound
            | UnsupportedType
            | AnyType -> None
        in
        !props_access_info >>= function
          | None -> Ok None
          | Some (Obj_def (loc, name)) ->
              Ok (Some (Object (Nel.one loc), name))
          | Some (Class_def (ty, name)) ->
              (* We get the type of the class back here, so we need to extract the type of an instance *)
              extract_instancet cx ty >>= fun ty ->
              begin extract_def_loc_resolved cx ty name >>= function
                | FoundClass locs -> Ok (Some (Class locs, name))
                | FoundObject _ -> Error "Expected to extract class def info from a class"
                | _ -> Error "Unexpectedly failed to extract definition from known type"
              end
          | Some (Use (ty, name)) ->
              def_info_of_type name ty
          | Some (Use_in_literal (types, name)) ->
              let def_info_result =
                let def_infos =
                  Nel.map (def_info_of_type name) types
                  |> Nel.result_all
                in
                let def_locs: (Loc.t Nel.t option Nel.t, string) result =
                  def_infos >>= fun def_infos ->
                  Nel.map begin function
                    | None -> Ok None
                    | Some (Object locs, _) -> Ok (Some locs)
                    | Some (Class _, _) -> Error "Expected object literals to only flow into object types"
                  end def_infos
                  |> Nel.result_all
                in
                def_locs >>| Nel.fold_left begin fun acc elt -> match acc, elt with
                  | None, None -> None
                  | Some locs, None
                  | None, Some locs -> Some locs
                  | Some locs, Some new_locs -> Some (Nel.rev_append new_locs locs)
                end None
              in
              def_info_result >>| Option.map ~f:(fun locs -> Object locs, name)
      )
    in
    let%lwt def_info = get_def_info () in
    def_info %>>= fun def_info_opt ->
    match def_info_opt with
      | None -> Lwt.return (Ok None)
      | Some (def_info, name) ->
          if global then
            roots_of_def_info def_info %>>= fun root_file_keys ->
            let root_file_paths_result =
              Nel.map File_key.to_path root_file_keys
              |> Nel.result_all
            in
            root_file_paths_result %>>= fun root_file_paths ->
            let%lwt () =
              let%lwt new_env =
                Lwt_list.fold_left_s
                  (lazy_mode_focus genv)
                  !env
                  (Nel.to_list root_file_paths)
              in
              env := new_env;
              Lwt.return_unit
            in
            let%lwt deps_result = deps_of_file_keys genv env (Nel.to_list root_file_keys) in
            deps_result %>>= fun deps ->
            let dependent_file_count = FilenameSet.cardinal deps in
            let relevant_files =
              Nel.to_list root_file_keys
              |> FilenameSet.of_list
              |> FilenameSet.union deps
            in
            Hh_logger.info
              "find-refs: searching %d dependent modules for references"
              dependent_file_count;
            let%lwt refs = find_refs_in_multiple_files genv relevant_files def_info name in
            refs %>>| fun refs ->
            Lwt.return (Some (name, refs, Some dependent_file_count))
          else
            Lwt.return (
              compute_ast_result file_key content >>= fun ast_info ->
              find_refs_in_file options ast_info file_key def_info name >>= fun refs ->
              Ok (Some (name, refs, None))
            )
end

let sort_find_refs_result = function
  | Ok (Some (name, locs)) ->
      let locs = List.fast_sort Loc.compare locs in
      Ok (Some (name, locs))
  | x -> x

let find_refs ~genv ~env ~profiling ~file_input ~line ~col ~global =
  let filename = File_input.filename_of_file_input file_input in
  let file_key = File_key.SourceFile filename in
  let loc = Loc.make file_key line col in
  match File_input.content_of_file_input file_input with
  | Error err -> Lwt.return (Error err, None)
  | Ok content ->
    let%lwt result =
      let%lwt refs = VariableRefs.find_refs genv env file_key ~content loc ~global in
      refs %>>= function
        | Some _ as result -> Lwt.return (Ok result)
        | None -> PropertyRefs.find_refs genv env ~profiling ~content file_key loc ~global
    in
    let json_data = match result with
      | Ok (Some (_, _, Some count)) -> ["deps", Hh_json.JSON_Number (string_of_int count)]
      | _ -> []
    in
    (* Drop the dependent file count  from the result *)
    let result = result >>| Option.map ~f:(fun (name, locs, _) -> (name, locs)) in
    let result = sort_find_refs_result result in
    let json_data =
      ("result", Hh_json.JSON_String (match result with Ok _ -> "SUCCESS" | _ -> "FAILURE"))
      :: ("global", Hh_json.JSON_Bool global)
      :: json_data
    in
    Lwt.return (result, Some (Hh_json.JSON_Object json_data))
